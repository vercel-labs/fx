const std = @import("std");
const builtin = @import("builtin");
const glob_pattern = @import("../../core/workspace/glob_pattern.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const workspace_files = @import("../../core/workspace/workspace_files.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

const OutputMode = enum {
    matches,
    count,
};

/// Typed input for the built-in glob_files tool.
pub const Input = struct {
    pattern: []u8,
    path: []u8,
    mode: OutputMode = .matches,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.pattern);
        alloc.free(self.path);
        self.* = .{ .pattern = &.{}, .path = &.{}, .mode = .matches };
    }
};

/// Decodes glob_files JSON into an owned Input released by ToolInput.deinit.
pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files arguments must be an object") };
    }

    const pattern_value = parsed.value.object.get("pattern") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files requires string field \"pattern\"") };
    };
    if (pattern_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files field \"pattern\" must be a string") };
    }

    const path_value = parsed.value.object.get("path");
    const path_string: ?[]const u8 = if (path_value) |value| switch (value) {
        .string => |path| path,
        else => null,
    } else null;

    const mode_value = parsed.value.object.get("mode");
    const mode: OutputMode = if (mode_value) |value| switch (value) {
        .string => |raw| if (std.mem.eql(u8, raw, "count")) .count else .matches,
        else => .matches,
    } else .matches;

    const owned_pattern = try ctx.allocator.dupe(u8, pattern_value.string);
    errdefer ctx.allocator.free(owned_pattern);
    const effective_path = if (path_string) |path|
        if (path.len == 0) "." else path
    else
        ".";
    const owned_path = try ctx.allocator.dupe(u8, effective_path);
    errdefer ctx.allocator.free(owned_path);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .pattern = owned_pattern,
        .path = owned_path,
        .mode = mode,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

/// Searches the resolved root and returns an owned tool result body.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callWithWorkspaceOptions(ctx, erased, .{});
}

fn callWithWorkspaceOptions(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput, workspace_options: workspace_files.Options) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const requested_root = resolveSearchRoot(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", input.path, err) };
        }
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve glob search root: {s} ({s})", .{ input.path, @errorName(err) }) };
    };
    const static_base = if (requested_root.is_directory)
        extractStaticGlobBase(input.pattern)
    else
        StaticGlobBase{ .base = "", .pattern = input.pattern };
    const maybe_root = if (requested_root.is_directory)
        resolveStaticBaseRoot(arena, requested_root.absolute, static_base.base) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (tool_result_errors.isFilesystemAccessDenied(err)) {
                return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", requested_root.absolute, err) };
            }
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve glob search root: {s} ({s})", .{ input.path, @errorName(err) }) };
        }
    else
        requested_root;
    const root = maybe_root orelse {
        if (input.mode == .count) {
            return .{ .success = try formatCount(ctx.allocator, input.pattern, 0, false, workspace_files.default_candidate_cap, 0) };
        }
        return .{ .success = try formatMatches(ctx.allocator, input.pattern, &.{}, false, false, workspace_files.default_candidate_cap, 0, ctx.max_list_entries) };
    };
    const root_relative = try pathing.workspaceRelativePath(arena, ctx.workspace_root, root.absolute);
    var compiled_pattern = glob_pattern.Pattern.compile(arena, static_base.pattern) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PatternTooLong => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "glob_files field \"pattern\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes}) },
    };
    defer compiled_pattern.deinit(arena);

    var matches: std.ArrayList([]u8) = .empty;
    defer matches.deinit(arena);
    var match_count: usize = 0;
    var output_truncated = false;
    var candidate_incomplete = false;
    var candidate_cap: usize = workspace_files.default_candidate_cap;
    var skipped_overlong: usize = 0;
    const is_scoped_search_root = root_relative.len > 0 and !std.mem.eql(u8, root_relative, ".");
    var discovery_options = workspace_options;
    discovery_options.include_untracked = is_scoped_search_root;
    discovery_options.force_fallback = discovery_options.force_fallback or is_scoped_search_root;
    discovery_options.include_hidden = discovery_options.include_hidden or shouldIncludeHidden(root_relative, input.pattern);
    discovery_options.sort_paths = true;

    if (root.is_directory) {
        const discovered = discoverWorkspaceFiles(arena, root.absolute, ctx.ignored_list_entries, discovery_options) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (tool_result_errors.isFilesystemAccessDenied(err)) {
                return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", root.absolute, err) };
            }
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to discover glob candidates: {s} ({s})", .{ root.absolute, @errorName(err) }) };
        };
        var candidate_files = discovered.files;
        candidate_incomplete = discovered.incomplete;
        candidate_cap = discovered.candidate_cap;
        skipped_overlong = discovered.skipped_overlong;
        if (shouldMergeRootUntracked(root_relative, discovered, discovery_options)) {
            const merged = mergeRootUntrackedCandidates(arena, root.absolute, ctx.ignored_list_entries, discovered) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (tool_result_errors.isFilesystemAccessDenied(err)) {
                    return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", root.absolute, err) };
                }
                return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to discover glob candidates: {s} ({s})", .{ root.absolute, @errorName(err) }) };
            };
            candidate_files = merged.files;
            candidate_incomplete = candidate_incomplete or merged.incomplete;
            skipped_overlong += merged.skipped_overlong;
        }

        for (candidate_files) |candidate| {
            if (!compiled_pattern.matchesPath(candidate)) continue;

            match_count += 1;
            if (input.mode == .count) continue;

            if (matches.items.len >= ctx.max_list_entries) {
                output_truncated = true;
                break;
            }

            try matches.append(arena, try joinRelativeSearchPath(arena, root_relative, candidate));
        }
    } else {
        const basename = std.fs.path.basename(root_relative);
        if (compiled_pattern.matchesPath(basename)) {
            match_count += 1;
            if (input.mode == .matches) {
                try matches.append(arena, try arena.dupe(u8, root_relative));
            }
        }
    }

    if (input.mode == .count) {
        return .{ .success = try formatCount(ctx.allocator, input.pattern, match_count, candidate_incomplete, candidate_cap, skipped_overlong) };
    }
    return .{ .success = try formatMatches(ctx.allocator, input.pattern, matches.items, output_truncated, candidate_incomplete, candidate_cap, skipped_overlong, ctx.max_list_entries) };
}

fn formatCount(
    alloc: Allocator,
    pattern: []const u8,
    match_count: usize,
    candidate_incomplete: bool,
    candidate_cap: usize,
    skipped_overlong: usize,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("[glob] count {d} matches for {s}\n", .{ match_count, pattern }) catch return error.OutOfMemory;
    try writeCandidateNotes(&out.writer, candidate_incomplete, candidate_cap, skipped_overlong);
    return try out.toOwnedSlice();
}

fn formatMatches(
    alloc: Allocator,
    pattern: []const u8,
    matches: []const []const u8,
    output_truncated: bool,
    candidate_incomplete: bool,
    candidate_cap: usize,
    skipped_overlong: usize,
    max_list_entries: usize,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (matches.len == 0) {
        out.writer.print("[glob] no matches for {s}\n", .{pattern}) catch return error.OutOfMemory;
        try writeCandidateNotes(&out.writer, candidate_incomplete, candidate_cap, skipped_overlong);
        return try out.toOwnedSlice();
    }

    out.writer.print("[glob] {d} matches for {s}\n", .{ matches.len, pattern }) catch return error.OutOfMemory;
    for (matches) |match| {
        out.writer.print(" - {s}\n", .{match}) catch return error.OutOfMemory;
    }
    if (output_truncated) {
        out.writer.print("... truncated to first {d} matches\n", .{max_list_entries}) catch return error.OutOfMemory;
    }
    try writeCandidateNotes(&out.writer, candidate_incomplete, candidate_cap, skipped_overlong);

    return try out.toOwnedSlice();
}

fn writeCandidateNotes(writer: anytype, candidate_incomplete: bool, candidate_cap: usize, skipped_overlong: usize) tool_dispatch.DispatchError!void {
    if (candidate_incomplete) {
        writer.print("... candidate list may be incomplete; candidate cap {d} reached before all files were discovered\n", .{candidate_cap}) catch return error.OutOfMemory;
    }
    if (skipped_overlong > 0) {
        writer.print("... skipped {d} overlong candidate path{s}\n", .{ skipped_overlong, if (skipped_overlong == 1) "" else "s" }) catch return error.OutOfMemory;
    }
}

const SearchRoot = struct {
    absolute: []const u8,
    is_directory: bool,
};

fn resolveSearchRoot(arena: Allocator, workspace_root: []const u8, requested: []const u8) !SearchRoot {
    const absolute = try pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, requested);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return .{ .absolute = absolute, .is_directory = false },
        else => return err,
    };
    dir.close(io_mod.getIo());
    return .{ .absolute = absolute, .is_directory = true };
}

fn resolveStaticBaseRoot(arena: Allocator, requested_root: []const u8, static_base: []const u8) !?SearchRoot {
    if (static_base.len == 0 or std.mem.eql(u8, static_base, ".")) {
        return .{ .absolute = requested_root, .is_directory = true };
    }
    const absolute = pathing.resolveWorkspacePath(arena, requested_root, static_base, .existing) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return null,
        else => return err,
    };
    dir.close(io_mod.getIo());
    return .{ .absolute = absolute, .is_directory = true };
}

const StaticGlobBase = struct {
    base: []const u8,
    pattern: []const u8,
};

fn extractStaticGlobBase(pattern: []const u8) StaticGlobBase {
    const first_glob = firstGlobChar(pattern) orelse {
        const dirname = std.fs.path.dirname(pattern) orelse return .{ .base = "", .pattern = pattern };
        return .{ .base = dirname, .pattern = std.fs.path.basename(pattern) };
    };
    const static_prefix = pattern[0..first_glob];
    const last_sep = lastPathSeparator(static_prefix) orelse return .{ .base = "", .pattern = pattern };
    if (last_sep == 0 and isPathSeparator(static_prefix[0])) {
        return .{ .base = static_prefix[0..1], .pattern = pattern[1..] };
    }
    return .{ .base = static_prefix[0..last_sep], .pattern = pattern[last_sep + 1 ..] };
}

fn firstGlobChar(pattern: []const u8) ?usize {
    for (pattern, 0..) |ch, index| {
        switch (ch) {
            '*', '?', '[', '{' => return index,
            else => {},
        }
    }
    return null;
}

fn lastPathSeparator(path: []const u8) ?usize {
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (isPathSeparator(path[index])) return index;
    }
    return null;
}

fn isPathSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn joinRelativeSearchPath(arena: Allocator, root_relative: []const u8, child_relative: []const u8) ![]u8 {
    if (std.mem.eql(u8, root_relative, ".") or root_relative.len == 0) {
        return arena.dupe(u8, child_relative);
    }
    return std.fs.path.join(arena, &.{ root_relative, child_relative });
}

fn shouldIncludeHidden(root_relative: []const u8, pattern: []const u8) bool {
    return workspace_files.pathContainsHiddenDirectoryComponent(root_relative) or patternContainsHiddenDirectoryComponent(pattern);
}

const MergedRootCandidates = struct {
    files: []const []const u8,
    incomplete: bool = false,
    skipped_overlong: usize = 0,
};

fn discoverWorkspaceFiles(arena: Allocator, absolute_root: []const u8, ignored: []const []const u8, options: workspace_files.Options) !workspace_files.Result {
    var discover_options = options;
    discover_options.ignored_names = ignored;
    return workspace_files.discover(arena, absolute_root, discover_options);
}

fn shouldMergeRootUntracked(root_relative: []const u8, result: workspace_files.Result, options: workspace_files.Options) bool {
    return result.source == .git and !options.include_untracked and !options.force_fallback and (root_relative.len == 0 or std.mem.eql(u8, root_relative, "."));
}

fn mergeRootUntrackedCandidates(
    arena: Allocator,
    absolute_root: []const u8,
    ignored: []const []const u8,
    discovered: workspace_files.Result,
) !MergedRootCandidates {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(arena);
    try files.appendSlice(arena, discovered.files);

    var seen = std.StringHashMap(void).init(arena);
    defer seen.deinit();
    for (discovered.files) |path| {
        try seen.put(path, {});
    }

    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute_root, .{ .iterate = true }) catch {
        return .{ .files = try files.toOwnedSlice(arena) };
    };
    defer dir.close(io_mod.getIo());

    var incomplete = false;
    var skipped_overlong: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io_mod.getIo())) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (rootNameIgnored(ignored, entry.name)) continue;
        if (seen.contains(entry.name)) continue;
        if (entry.name.len > workspace_files.max_relative_path_bytes) {
            skipped_overlong += 1;
            continue;
        }
        if (files.items.len >= discovered.candidate_cap) {
            incomplete = true;
            break;
        }
        const owned = try arena.dupe(u8, entry.name);
        try seen.put(owned, {});
        try files.append(arena, owned);
    }

    sortCandidatePaths(files.items);
    return .{
        .files = try files.toOwnedSlice(arena),
        .incomplete = incomplete,
        .skipped_overlong = skipped_overlong,
    };
}

fn rootNameIgnored(ignored: []const []const u8, name: []const u8) bool {
    for (ignored) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn sortCandidatePaths(paths: [][]const u8) void {
    sort_utils.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn patternContainsHiddenDirectoryComponent(pattern: []const u8) bool {
    return workspace_files.pathContainsHiddenDirectoryComponent(pattern);
}

/// Reports that glob_files only observes filesystem names and metadata.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

/// Reports that glob_files has no irreversible side effects.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const glob_files_dispatch_tool = tool_dispatch.Tool{
    .name = "glob_files",
    .description = "Glob files dispatch test fixture.",
    .model_schema = .{
        .name = "glob_files",
        .description = "Glob files dispatch test fixture.",
    },
    .executor_kind = .glob_files,
    .activity_kind = .list,
    .permission_target_kind = .path_optional_existing,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

fn validateStackInput(alloc: Allocator, input: *Input, workspace_root: []const u8) !?[]u8 {
    return validate(.{ .allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = input, .deinit_fn = noopInputDeinit });
}

fn expectDecodeFailure(args_json: []const u8, reason: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(reason, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

fn expectDecodeInput(args_json: []const u8, pattern: []const u8, input_path: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expectEqualStrings(pattern, input.pattern);
            try std.testing.expectEqualStrings(input_path, input.path);
        },
    }
}

fn globArgsJson(alloc: Allocator, pattern: []const u8, maybe_path: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"pattern\":");
    try std.json.Stringify.value(pattern, .{}, &out.writer);
    if (maybe_path) |path| {
        try out.writer.writeAll(",\"path\":");
        try std.json.Stringify.value(path, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchGlobFiles(alloc: Allocator, workspace_root: []const u8, pattern: []const u8, maybe_path: ?[]const u8) !tool_dispatch.DispatchResult {
    const args = try globArgsJson(alloc, pattern, maybe_path);
    defer alloc.free(args);

    return dispatchGlobFilesRaw(alloc, workspace_root, args);
}

fn dispatchGlobFilesRaw(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{glob_files_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "glob_files",
        .arguments_json = args_json,
    });
}

fn runGitForTest(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.appendSlice(alloc, args);

    const result = std.process.run(alloc, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

fn writeTempFile(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) ![]u8 {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn writeTempFileWithMtime(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
    content: []const u8,
    mtime_ns: i96,
) ![]u8 {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    try file.setTimestamps(io_mod.getIo(), .{
        .access_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
    });
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn countEmittedResultLines(body: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, " - ")) count += 1;
    }
    return count;
}

fn createNumberedFiles(tmp: *std.testing.TmpDir, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "many/file-{d:0>4}.txt", .{i});
        if (std.fs.path.dirname(name)) |parent| {
            try tmp.dir.createDirPath(io_mod.getIo(), parent);
        }
        {
            var file = try tmp.dir.createFile(std.testing.io, name, .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), "x\n");
        }
    }
}

test "glob_files decodes invalid argument shapes as failures" {
    try expectDecodeFailure("{", "glob_files arguments must be valid JSON");
    try expectDecodeFailure("[]", "glob_files arguments must be an object");
    try expectDecodeFailure("{\"path\":\".\"}", "glob_files requires string field \"pattern\"");
    try expectDecodeFailure("{\"pattern\":1}", "glob_files field \"pattern\" must be a string");
}

test "glob_files decodes omitted path and valid input" {
    try expectDecodeInput("{\"pattern\":\"*.zig\"}", "*.zig", ".");
    try expectDecodeInput("{\"pattern\":\"*.zig\",\"path\":\"\"}", "*.zig", ".");
    try expectDecodeInput("{\"pattern\":\"*.zig\",\"path\":\"src\"}", "*.zig", "src");
    try expectDecodeInput("{\"pattern\":\"*.zig\",\"path\":1}", "*.zig", ".");
}

test "glob_files validate preserves active raw pattern and path values" {
    const alloc = std.testing.allocator;
    var empty = Input{
        .pattern = try alloc.dupe(u8, " \t\n "),
        .path = try alloc.dupe(u8, "   "),
    };
    defer empty.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty, "/tmp/workspace")) == null);
    try std.testing.expectEqualStrings(" \t\n ", empty.pattern);
    try std.testing.expectEqualStrings("   ", empty.path);

    var valid = Input{
        .pattern = try alloc.dupe(u8, "  **/*.zig  "),
        .path = try alloc.dupe(u8, "  src  "),
    };
    defer valid.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &valid, "/tmp/workspace")) == null);
    try std.testing.expectEqualStrings("  **/*.zig  ", valid.pattern);
    try std.testing.expectEqualStrings("  src  ", valid.path);
}

test "glob_files reports overlong patterns during matching" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const pattern = try alloc.alloc(u8, glob_pattern.max_pattern_bytes + 1);
    defer alloc.free(pattern);
    @memset(pattern, '*');

    var input = Input{
        .pattern = try alloc.dupe(u8, pattern),
        .path = try alloc.dupe(u8, "."),
    };
    defer input.deinit(alloc);

    const result = try call(.{ .allocator = alloc, .workspace_root = workspace }, .{ .ptr = &input, .deinit_fn = noopInputDeinit });
    defer result.deinit(alloc);
    const expected = try std.fmt.allocPrint(alloc, "glob_files field \"pattern\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes});
    defer alloc.free(expected);
    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| try std.testing.expectEqualStrings(expected, body),
        .success => try std.testing.expect(false),
    }
}

test "glob_files Input ownership duplicates and frees under testing allocator" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"pattern\":\"*.zig\",\"path\":\"src\"}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            const input = erased.as(Input);
            try std.testing.expectEqualStrings("*.zig", input.pattern);
            try std.testing.expectEqualStrings("src", input.path);
            erased.deinit(alloc);
        },
    }
}

test "glob_files regular-file search root matches basename only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const file_path = try writeTempFile(alloc, &tmp, "single.txt", "one\n");
    defer alloc.free(file_path);

    var one = try dispatchGlobFiles(alloc, workspace, "*.txt", file_path);
    defer one.deinit(alloc);
    try std.testing.expectEqual(.success, one.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for *.txt\n - single.txt\n", one.body);

    var segmented = try dispatchGlobFiles(alloc, workspace, "dir/*.txt", file_path);
    defer segmented.deinit(alloc);
    try std.testing.expectEqual(.success, segmented.status);
    try std.testing.expectEqualStrings("[glob] no matches for dir/*.txt\n", segmented.body);
}

test "glob_files regular-file root follows active basename behavior inside ignored directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const ignored_file = try writeTempFile(alloc, &tmp, "node_modules/pkg/file.zig", "ignored\n");
    defer alloc.free(ignored_file);

    var result = try dispatchGlobFiles(alloc, workspace, "*.zig", ignored_file);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for *.zig\n - node_modules/pkg/file.zig\n", result.body);
}

test "glob_files explicit ignored directory root follows active behavior" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const ignored_file = try writeTempFile(alloc, &tmp, "node_modules/pkg/file.zig", "ignored\n");
    defer alloc.free(ignored_file);

    var result = try dispatchGlobFiles(alloc, workspace, "**/*.zig", "node_modules");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for **/*.zig\n - node_modules/pkg/file.zig\n", result.body);
}

test "glob_files resolver error for missing path returns failure result" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    var result = try dispatchGlobFiles(alloc, workspace, "*.zig", "missing");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve glob search root: missing (FileNotFound)", result.body);
}

test "glob_files permission denied directory returns structured recovery" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const root = try std.fmt.allocPrint(alloc, "/tmp/fx-glob-files-access-{d}", .{io_mod.nanoTimestamp()});
    defer alloc.free(root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), root) catch {};
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), root);
    const workspace = try io_mod.realpathAlloc(alloc, root);
    defer alloc.free(workspace);
    const blocked = try std.fs.path.join(alloc, &.{ workspace, "blocked" });
    defer alloc.free(blocked);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), blocked);

    std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), blocked, std.Io.File.Permissions.fromMode(0), .{}) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), blocked, std.Io.File.Permissions.fromMode(0o700), .{}) catch {};

    var result = try dispatchGlobFiles(alloc, workspace, "**/*.zig", blocked);
    defer result.deinit(alloc);
    if (result.status == .success) return error.SkipZigTest;

    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(result.body));
    try std.testing.expect(std.mem.find(u8, result.body, "\"tool_name\":\"glob_files\"") != null);
    try std.testing.expect(std.mem.find(u8, result.body, blocked) != null);
    try std.testing.expect(std.mem.find(u8, result.body, "AccessDenied") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "symlink") != null);
}

test "glob_files formats zero, one, and multiple results" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const one_path = try writeTempFileWithMtime(alloc, &tmp, "one.txt", "one\n", 1_000_000_000);
    defer alloc.free(one_path);
    const two_path = try writeTempFileWithMtime(alloc, &tmp, "two.txt", "two\n", 2_000_000_000);
    defer alloc.free(two_path);

    var zero = try dispatchGlobFiles(alloc, workspace, "*.zig", null);
    defer zero.deinit(alloc);
    try std.testing.expectEqual(.success, zero.status);
    try std.testing.expectEqualStrings("[glob] no matches for *.zig\n", zero.body);

    var one = try dispatchGlobFiles(alloc, workspace, "one.txt", null);
    defer one.deinit(alloc);
    try std.testing.expectEqual(.success, one.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for one.txt\n - one.txt\n", one.body);

    var multiple = try dispatchGlobFiles(alloc, workspace, "*.txt", null);
    defer multiple.deinit(alloc);
    try std.testing.expectEqual(.success, multiple.status);
    try std.testing.expect(std.mem.startsWith(u8, multiple.body, "[glob] 2 matches for *.txt\n"));
    try std.testing.expect(std.mem.find(u8, multiple.body, " - one.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, multiple.body, " - two.txt\n") != null);
}

test "glob_files truncates output to active max list entries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 150);

    const result = try dispatchGlobFiles(alloc, workspace, "**/*.txt", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[glob] 100 matches for **/*.txt\n"));
    try std.testing.expectEqual(tool_dispatch.default_max_list_entries, countEmittedResultLines(result.body));
    const expected_tail = try std.fmt.allocPrint(
        std.testing.allocator,
        "... truncated to first {d} matches\n",
        .{tool_dispatch.default_max_list_entries},
    );
    defer std.testing.allocator.free(expected_tail);
    try std.testing.expect(std.mem.find(u8, result.body, expected_tail) != null);
}

test "glob_files count mode reports exact matches without rendering entries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 150);

    var result = try dispatchGlobFilesRaw(alloc, workspace, "{\"pattern\":\"**/*.txt\",\"mode\":\"count\"}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[glob] count 150 matches for **/*.txt\n", result.body);
    try std.testing.expectEqual(@as(usize, 0), countEmittedResultLines(result.body));
}

test "glob_files formatter uses active truncation wording" {
    const alloc = std.testing.allocator;
    const matches = [_][]const u8{ "a.txt", "b.txt" };
    const body = try formatMatches(alloc, "*.txt", &matches, true, false, workspace_files.default_candidate_cap, 0, 2);
    defer alloc.free(body);

    try std.testing.expectEqualStrings("[glob] 2 matches for *.txt\n - a.txt\n - b.txt\n... truncated to first 2 matches\n", body);
}

test "glob_files path narrowing applies before candidate cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const outside = try writeTempFile(alloc, &tmp, "aaa/outside.txt", "outside\n");
    defer alloc.free(outside);
    const target = try writeTempFile(alloc, &tmp, "src/core/workspace/target.zig", "target\n");
    defer alloc.free(target);

    var input = Input{
        .pattern = try alloc.dupe(u8, "target.zig"),
        .path = try alloc.dupe(u8, "src/core/workspace"),
    };
    defer input.deinit(alloc);

    const erased = tool_dispatch.ToolInput{ .ptr = &input, .deinit_fn = noopInputDeinit };
    var result = try callWithWorkspaceOptions(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace,
        .max_list_entries = 10,
    }, erased, .{
        .candidate_cap = 1,
        .force_fallback = true,
    });
    defer result.deinit(alloc);

    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => |body| try std.testing.expectEqualStrings("[glob] 1 matches for target.zig\n - src/core/workspace/target.zig\n", body),
        .failure => try std.testing.expect(false),
    }
}

test "glob_files extracts static base before candidate cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const outside = try writeTempFile(alloc, &tmp, "aaa/outside.zig", "outside\n");
    defer alloc.free(outside);
    const target = try writeTempFile(alloc, &tmp, "src/tools/target.zig", "target\n");
    defer alloc.free(target);

    var input = Input{
        .pattern = try alloc.dupe(u8, "src/tools/**/*.zig"),
        .path = try alloc.dupe(u8, "."),
    };
    defer input.deinit(alloc);

    const erased = tool_dispatch.ToolInput{ .ptr = &input, .deinit_fn = noopInputDeinit };
    var result = try callWithWorkspaceOptions(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace,
        .max_list_entries = 10,
    }, erased, .{
        .candidate_cap = 1,
        .force_fallback = true,
    });
    defer result.deinit(alloc);

    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => |body| try std.testing.expectEqualStrings("[glob] 1 matches for src/tools/**/*.zig\n - src/tools/target.zig\n", body),
        .failure => try std.testing.expect(false),
    }
}

test "glob_files root git discovery includes untracked files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    try runGitForTest(alloc, workspace, &.{"init"});
    const tracked = try writeTempFile(alloc, &tmp, "tracked.txt", "tracked\n");
    defer alloc.free(tracked);
    try runGitForTest(alloc, workspace, &.{ "add", "tracked.txt" });
    const untracked = try writeTempFile(alloc, &tmp, "untracked-target.txt", "untracked\n");
    defer alloc.free(untracked);

    var result = try dispatchGlobFiles(alloc, workspace, "untracked-*.txt", ".");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[glob] 1 matches for untracked-*.txt\n - untracked-target.txt\n", result.body);
}

test "glob_files static base extraction handles literal and wildcard patterns" {
    var base = extractStaticGlobBase("src/core/**/*.zig");
    try std.testing.expectEqualStrings("src/core", base.base);
    try std.testing.expectEqualStrings("**/*.zig", base.pattern);

    base = extractStaticGlobBase("src/main.zig");
    try std.testing.expectEqualStrings("src", base.base);
    try std.testing.expectEqualStrings("main.zig", base.pattern);

    base = extractStaticGlobBase("*.zig");
    try std.testing.expectEqualStrings("", base.base);
    try std.testing.expectEqualStrings("*.zig", base.pattern);
}

test "glob_files finds match beyond former traversal cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try createNumberedFiles(&tmp, 2050);
    const late = try writeTempFile(alloc, &tmp, "zzzz/target.zig", "target\n");
    defer alloc.free(late);

    var result = try dispatchGlobFiles(alloc, workspace, "**/*.zig", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "zzzz/target.zig") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "traversal cap") == null);
}

test "glob_files distinguishes candidate cap from output cap" {
    const alloc = std.testing.allocator;
    const matches = [_][]const u8{ "a.txt", "b.txt" };
    const body = try formatMatches(alloc, "*.txt", &matches, true, true, 2, 0, 2);
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "... truncated to first 2 matches\n") != null);
    try std.testing.expect(std.mem.find(u8, body, "candidate cap 2 reached") != null);
}

test "glob_files allows external absolute path search roots" {
    const alloc = std.testing.allocator;
    // Keep the external root out of std.testing.tmpDir(), whose generated path
    // may contain ignored component names and invalidate this absolute-path case.
    const root = try std.fmt.allocPrint(alloc, "/tmp/fx-glob-external-{d}", .{io_mod.nanoTimestamp()});
    defer alloc.free(root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), root) catch {};
    const workspace_dir = try std.fs.path.join(alloc, &.{ root, "workspace" });
    defer alloc.free(workspace_dir);
    const external_dir = try std.fs.path.join(alloc, &.{ root, "external" });
    defer alloc.free(external_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), workspace_dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), external_dir);

    const workspace = try io_mod.realpathAlloc(alloc, workspace_dir);
    defer alloc.free(workspace);
    const external = try io_mod.realpathAlloc(alloc, external_dir);
    defer alloc.free(external);
    const external_file = try std.fs.path.join(alloc, &.{ external, "outside.txt" });
    defer alloc.free(external_file);
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), external_file, .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "outside\n");
    }

    const result = try dispatchGlobFiles(alloc, workspace, "*.txt", external);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    const expected = try std.fmt.allocPrint(alloc, "[glob] 1 matches for *.txt\n - {s}\n", .{external_file});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, result.body);
}

test "glob_files pattern static base cannot escape the approved search root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const outside = try writeTempFile(alloc, &tmp, "external/outside.txt", "outside\n");
    defer alloc.free(outside);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const absolute_pattern = try std.fs.path.join(alloc, &.{ external, "*.txt" });
    defer alloc.free(absolute_pattern);

    const patterns = [_][]const u8{
        "../external/*.txt",
        absolute_pattern,
    };
    for (patterns) |pattern| {
        var result = try dispatchGlobFiles(alloc, workspace, pattern, ".");
        defer result.deinit(alloc);

        try std.testing.expectEqual(.failure, result.status);
        try std.testing.expect(std.mem.find(u8, result.body, "PathOutsideWorkspace") != null);
    }
}

test "glob_files classifiers are read-only and reversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{
        .pattern = try std.testing.allocator.dupe(u8, "*.zig"),
        .path = try std.testing.allocator.dupe(u8, ""),
    };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}
