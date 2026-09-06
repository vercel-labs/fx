const std = @import("std");
const glob_pattern = @import("../../core/workspace/glob_pattern.zig");
const grep_search = @import("../../core/workspace/grep_search.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");

const Allocator = std.mem.Allocator;

const output_cap = grep_search.output_cap;
const context_lines_cap: usize = 5;
const context_file_byte_cap: usize = 200 * 1024;

const OutputMode = enum {
    matches,
    files_with_matches,
    count,
};

/// Typed input for the built-in grep_files tool.
pub const Input = struct {
    pattern: []u8,
    path: []u8,
    include: ?[]u8,
    case_insensitive: bool,
    mode: OutputMode = .matches,
    head_limit: usize,
    offset: usize,
    context_lines: usize = 0,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.pattern);
        alloc.free(self.path);
        if (self.include) |include| alloc.free(include);
        self.* = .{
            .pattern = &.{},
            .path = &.{},
            .include = null,
            .case_insensitive = false,
            .mode = .matches,
            .head_limit = output_cap,
            .offset = 0,
            .context_lines = 0,
        };
    }
};

/// Decodes grep_files JSON into an owned Input released by ToolInput.deinit.
pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "grep_files arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "grep_files arguments must be an object") };
    }

    const pattern_value = parsed.value.object.get("pattern") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "grep_files requires string field \"pattern\"") };
    };
    if (pattern_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "grep_files field \"pattern\" must be a string") };
    }

    const path_string = optionalStringField(parsed.value.object, "path");
    const include_string = optionalStringField(parsed.value.object, "include");
    const case_insensitive = if (parsed.value.object.get("case_insensitive")) |value| switch (value) {
        .bool => |enabled| enabled,
        else => false,
    } else false;
    const mode = parseOutputMode(parsed.value.object);

    const head_limit = switch (try parseOptionalInteger(ctx.allocator, parsed.value.object, "head_limit", 1, "positive")) {
        .missing => output_cap,
        .value => |value| @min(value, output_cap),
        .failure => |body| return .{ .failure = body },
    };
    const offset = switch (try parseOptionalInteger(ctx.allocator, parsed.value.object, "offset", 0, "non-negative")) {
        .missing => 0,
        .value => |value| value,
        .failure => |body| return .{ .failure = body },
    };
    const context_lines = switch (try parseOptionalInteger(ctx.allocator, parsed.value.object, "context_lines", 0, "non-negative")) {
        .missing => 0,
        .value => |value| @min(value, context_lines_cap),
        .failure => |body| return .{ .failure = body },
    };

    const owned_pattern = try ctx.allocator.dupe(u8, pattern_value.string);
    errdefer ctx.allocator.free(owned_pattern);
    const effective_path = if (path_string) |path|
        if (path.len == 0) "." else path
    else
        ".";
    const owned_path = try ctx.allocator.dupe(u8, effective_path);
    errdefer ctx.allocator.free(owned_path);
    const owned_include = if (include_string) |value| try ctx.allocator.dupe(u8, value) else null;
    errdefer if (owned_include) |include| ctx.allocator.free(include);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .pattern = owned_pattern,
        .path = owned_path,
        .include = owned_include,
        .case_insensitive = case_insensitive,
        .mode = mode,
        .head_limit = head_limit,
        .offset = offset,
        .context_lines = context_lines,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn optionalStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn parseOutputMode(object: std.json.ObjectMap) OutputMode {
    const raw = optionalStringField(object, "mode") orelse return .matches;
    if (std.mem.eql(u8, raw, "count")) return .count;
    if (std.mem.eql(u8, raw, "files_with_matches")) return .files_with_matches;
    return .matches;
}

const OptionalIntegerParse = union(enum) {
    missing,
    value: usize,
    failure: []u8,
};

fn parseOptionalInteger(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    min_value: i64,
    description: []const u8,
) tool_dispatch.DispatchError!OptionalIntegerParse {
    const value = object.get(key) orelse return .missing;
    if (value != .integer or value.integer < min_value) {
        return .{ .failure = try std.fmt.allocPrint(alloc, "grep_files field \"{s}\" must be a {s} integer", .{ key, description }) };
    }
    return .{ .value = @intCast(value.integer) };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

/// Searches the resolved root and returns an owned tool result body.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callWithOps(ctx, erased, .{});
}

const StatRootFn = *const fn ([]const u8) anyerror!std.Io.File.Stat;
const CollectDirectoryFn = *const fn (
    Allocator,
    []const u8,
    []const u8,
    []const u8,
    bool,
    []const []const u8,
    ?glob_pattern.Pattern,
) anyerror!grep_search.Result;
const CollectFileFn = *const fn (
    Allocator,
    []const u8,
    []const u8,
    []const u8,
    bool,
    ?glob_pattern.Pattern,
) anyerror!grep_search.Result;
const CountDirectoryFn = *const fn (
    Allocator,
    []const u8,
    []const u8,
    []const u8,
    bool,
    []const []const u8,
    ?glob_pattern.Pattern,
) anyerror!grep_search.CountResult;
const CountFileFn = *const fn (
    Allocator,
    []const u8,
    []const u8,
    []const u8,
    bool,
    ?glob_pattern.Pattern,
) anyerror!grep_search.CountResult;

const CallOps = struct {
    stat_root: StatRootFn = statRoot,
    collect_directory: CollectDirectoryFn = grep_search.collectDirectoryMatchesWithIgnored,
    collect_file: CollectFileFn = grep_search.collectRegularFileRoot,
    count_directory: CountDirectoryFn = grep_search.countDirectoryMatchesWithIgnored,
    count_file: CountFileFn = grep_search.countRegularFileRoot,
};

const SearchOutcome = union(enum) {
    matches: grep_search.Result,
    count: grep_search.CountResult,
    failure: []u8,
};

fn callWithOps(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput, ops: CallOps) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const absolute_root = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "grep_files", input.path, err) };
        }
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve grep search root: {s} ({s})", .{ input.path, @errorName(err) }) };
    };

    var include_pattern: ?glob_pattern.Pattern = null;
    if (input.include) |include| {
        include_pattern = glob_pattern.Pattern.compile(arena, include) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PatternTooLong => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "grep_files field \"include\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes}) },
        };
    }

    const root_stat = ops.stat_root(absolute_root) catch |err| {
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "grep_files", absolute_root, err) };
        }
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to stat grep search root: {s} ({s})", .{ absolute_root, @errorName(err) }) };
    };

    return switch (try searchGrepRoot(ctx, arena, input, absolute_root, root_stat, include_pattern, ops)) {
        .failure => |body| .{ .failure = body },
        .count => |count_result| .{ .success = try formatCount(ctx.allocator, input.pattern, count_result) },
        .matches => |search_result| switch (input.mode) {
            .matches => .{ .success = try formatMatches(ctx.allocator, arena, ctx.workspace_root, input.pattern, search_result, input.head_limit, input.offset, input.context_lines, ctx.max_list_entries, ctx.max_read_file_line_len) },
            .files_with_matches => .{ .success = try formatFilesWithMatches(ctx.allocator, arena, ctx.workspace_root, input.pattern, search_result, input.head_limit, input.offset, ctx.max_list_entries) },
            .count => unreachable,
        },
    };
}

fn searchGrepRoot(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    input: *const Input,
    absolute_root: []const u8,
    root_stat: std.Io.File.Stat,
    include_pattern: ?glob_pattern.Pattern,
    ops: CallOps,
) tool_dispatch.DispatchError!SearchOutcome {
    return switch (root_stat.kind) {
        .directory => switch (input.mode) {
            .count => .{ .count = ops.count_directory(arena, ctx.workspace_root, absolute_root, input.pattern, input.case_insensitive, ctx.ignored_list_entries, include_pattern) catch |err| {
                return searchFailure(ctx.allocator, absolute_root, "walk grep search root", err);
            } },
            .matches, .files_with_matches => .{ .matches = ops.collect_directory(arena, ctx.workspace_root, absolute_root, input.pattern, input.case_insensitive, ctx.ignored_list_entries, include_pattern) catch |err| {
                return searchFailure(ctx.allocator, absolute_root, "walk grep search root", err);
            } },
        },
        .file => switch (input.mode) {
            .count => .{ .count = ops.count_file(arena, ctx.workspace_root, absolute_root, input.pattern, input.case_insensitive, include_pattern) catch |err| {
                return searchFailure(ctx.allocator, absolute_root, "scan grep file root", err);
            } },
            .matches, .files_with_matches => .{ .matches = ops.collect_file(arena, ctx.workspace_root, absolute_root, input.pattern, input.case_insensitive, include_pattern) catch |err| {
                return searchFailure(ctx.allocator, absolute_root, "scan grep file root", err);
            } },
        },
        else => .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Not a regular file or directory: {s}", .{absolute_root}) },
    };
}

fn searchFailure(
    alloc: Allocator,
    absolute_root: []const u8,
    action: []const u8,
    err: anyerror,
) tool_dispatch.DispatchError!SearchOutcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (tool_result_errors.isFilesystemAccessDenied(err)) {
        return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(alloc, "grep_files", absolute_root, err) };
    }
    return .{ .failure = try std.fmt.allocPrint(alloc, "Unable to {s}: {s} ({s})", .{ action, absolute_root, @errorName(err) }) };
}

fn statRoot(absolute_root: []const u8) anyerror!std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_root, .{});
}

fn formatMatches(
    alloc: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    pattern: []const u8,
    result: grep_search.Result,
    head_limit: usize,
    offset: usize,
    context_lines: usize,
    max_list_entries: usize,
    max_read_file_line_len: usize,
) tool_dispatch.DispatchError![]u8 {
    const matches = result.matches;
    const effective_limit = @min(head_limit, max_list_entries);
    const start = @min(offset, matches.len);
    const end = @min(start + effective_limit, matches.len);
    const emitted = end - start;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (matches.len == 0) {
        out.writer.print("[grep] no matches for {s}\n", .{pattern}) catch return error.OutOfMemory;
    } else if (emitted == 0) {
        out.writer.print("[grep] no matches for {s} at offset {d} ({d} total matches)\n", .{ pattern, offset, matches.len }) catch return error.OutOfMemory;
    } else {
        if (start == 0 and end == matches.len) {
            out.writer.print("[grep] {d} matches for {s}\n", .{ emitted, pattern }) catch return error.OutOfMemory;
        } else {
            out.writer.print("[grep] {d} matches for {s} (showing {d}-{d} of {d})\n", .{ emitted, pattern, start + 1, end, matches.len }) catch return error.OutOfMemory;
        }
        for (matches[start..end]) |match| {
            const display_path = displayPath(arena, workspace_root, match.absolute_path) catch |err| fallback: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                break :fallback match.absolute_path;
            };
            writeMatchWithContext(arena, &out.writer, match, display_path, context_lines, max_read_file_line_len) catch return error.OutOfMemory;
        }
    }

    if (end < matches.len) {
        out.writer.print("... more matches available; use offset {d} to continue\n", .{end}) catch return error.OutOfMemory;
    }
    try writeGrepResultNotes(&out.writer, result);

    return try out.toOwnedSlice();
}

fn writeMatchWithContext(
    arena: Allocator,
    writer: *std.Io.Writer,
    match: grep_search.Match,
    display_path: []const u8,
    context_lines: usize,
    max_read_file_line_len: usize,
) !void {
    const content = if (context_lines > 0) try readContextContent(arena, match.absolute_path) else null;
    if (content) |text| {
        const first_line = if (match.line_number > context_lines) match.line_number - context_lines else 1;
        try writeContextRange(writer, display_path, text, first_line, match.line_number, max_read_file_line_len);
    }
    try writeMatchLine(writer, display_path, match, max_read_file_line_len);
    if (content) |text| {
        try writeContextRange(writer, display_path, text, match.line_number + 1, match.line_number + context_lines + 1, max_read_file_line_len);
    }
}

fn readContextContent(arena: Allocator, absolute_path: []const u8) !?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), absolute_path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    const content = io_mod.readFileToEnd(arena, &file, context_file_byte_cap + 1) catch return null;
    if (content.len > context_file_byte_cap) return null;
    if (!text_utils.isModelSafeText(content)) return null;
    return content;
}

fn writeContextRange(
    writer: *std.Io.Writer,
    display_path: []const u8,
    content: []const u8,
    start_line: usize,
    end_line_exclusive: usize,
    max_read_file_line_len: usize,
) !void {
    var line_number: usize = 1;
    var cursor: usize = 0;
    while (nextRealLine(content, &cursor)) |line| : (line_number += 1) {
        if (line_number < start_line) continue;
        if (line_number >= end_line_exclusive) break;
        try writer.print("   {s}:{d}- ", .{ display_path, line_number });
        try writeClippedLine(writer, line, max_read_file_line_len);
    }
}

fn nextRealLine(content: []const u8, cursor: *usize) ?[]const u8 {
    if (cursor.* >= content.len) return null;

    const start = cursor.*;
    if (std.mem.findScalar(u8, content[start..], '\n')) |newline_offset| {
        const end = start + newline_offset;
        cursor.* = end + 1;
        return content[start..end];
    }

    cursor.* = content.len;
    return content[start..];
}

fn writeMatchLine(
    writer: *std.Io.Writer,
    display_path: []const u8,
    match: grep_search.Match,
    max_read_file_line_len: usize,
) !void {
    try writer.print(" - {s}:{d}: ", .{ display_path, match.line_number });
    try writeClippedLine(writer, match.line, max_read_file_line_len);
}

fn writeClippedLine(writer: *std.Io.Writer, line: []const u8, max_read_file_line_len: usize) !void {
    const clipped_len = @min(line.len, max_read_file_line_len);
    try writer.writeAll(line[0..clipped_len]);
    if (line.len > max_read_file_line_len) {
        try writer.writeAll("...");
    }
    try writer.writeByte('\n');
}

fn formatFilesWithMatches(
    alloc: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    pattern: []const u8,
    result: grep_search.Result,
    head_limit: usize,
    offset: usize,
    max_list_entries: usize,
) tool_dispatch.DispatchError![]u8 {
    var seen = std.StringHashMap(void).init(arena);
    defer seen.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(arena);

    for (result.matches) |match| {
        if (seen.contains(match.absolute_path)) continue;
        try seen.put(match.absolute_path, {});
        const display_path = displayPath(arena, workspace_root, match.absolute_path) catch |err| fallback: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :fallback match.absolute_path;
        };
        try files.append(arena, display_path);
    }

    const effective_limit = @min(head_limit, max_list_entries);
    const start = @min(offset, files.items.len);
    const end = @min(start + effective_limit, files.items.len);
    const emitted = end - start;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (files.items.len == 0) {
        out.writer.print("[grep] no files with matches for {s}\n", .{pattern}) catch return error.OutOfMemory;
    } else if (emitted == 0) {
        out.writer.print("[grep] no files with matches for {s} at offset {d} ({d} total files)\n", .{ pattern, offset, files.items.len }) catch return error.OutOfMemory;
    } else {
        if (start == 0 and end == files.items.len) {
            out.writer.print("[grep] {d} files with matches for {s}\n", .{ emitted, pattern }) catch return error.OutOfMemory;
        } else {
            out.writer.print("[grep] {d} files with matches for {s} (showing {d}-{d} of {d})\n", .{ emitted, pattern, start + 1, end, files.items.len }) catch return error.OutOfMemory;
        }
        for (files.items[start..end]) |path| {
            out.writer.print(" - {s}\n", .{path}) catch return error.OutOfMemory;
        }
    }
    if (end < files.items.len) {
        out.writer.print("... more files available; use offset {d} to continue\n", .{end}) catch return error.OutOfMemory;
    }
    try writeGrepResultNotes(&out.writer, result);

    return try out.toOwnedSlice();
}

fn writeGrepResultNotes(
    writer: *std.Io.Writer,
    result: grep_search.Result,
) error{OutOfMemory}!void {
    if (result.truncated_reason) |reason| {
        switch (reason) {
            .collection_cap => writer.print("... match collection cap reached at {d} matches before all candidate files were scanned\n", .{grep_search.collection_cap}) catch return error.OutOfMemory,
        }
    }
    try writeCandidateNotes(
        writer,
        result.candidate_incomplete,
        result.candidate_cap,
        result.skipped_overlong,
    );
}

fn writeCandidateNotes(
    writer: *std.Io.Writer,
    candidate_incomplete: bool,
    candidate_cap: usize,
    skipped_overlong: usize,
) error{OutOfMemory}!void {
    if (candidate_incomplete) {
        writer.print("... candidate list may be incomplete; candidate cap {d} reached before all files were discovered\n", .{candidate_cap}) catch return error.OutOfMemory;
    }
    if (skipped_overlong > 0) {
        writer.print("... skipped {d} overlong candidate path{s}\n", .{ skipped_overlong, if (skipped_overlong == 1) "" else "s" }) catch return error.OutOfMemory;
    }
}

fn formatCount(
    alloc: Allocator,
    pattern: []const u8,
    result: grep_search.CountResult,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("[grep] count {d} matching lines in {d} files for {s}\n", .{ result.matching_lines, result.matching_files, pattern }) catch return error.OutOfMemory;
    try writeCandidateNotes(
        &out.writer,
        result.candidate_incomplete,
        result.candidate_cap,
        result.skipped_overlong,
    );
    return try out.toOwnedSlice();
}

fn displayPath(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8) ![]const u8 {
    if (workspace_root.len == 0) return absolute_path;
    return pathing.workspaceRelativePath(arena, workspace_root, absolute_path);
}

/// Reports that grep_files only observes filesystem content.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

/// Reports that grep_files has no irreversible side effects.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const grep_files_dispatch_tool = tool_dispatch.Tool{
    .name = "grep_files",
    .description = "Grep files dispatch test fixture.",
    .model_schema = .{
        .name = "grep_files",
        .description = "Grep files dispatch test fixture.",
    },
    .executor_kind = .grep_files,
    .activity_kind = .read,
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

fn expectDecodeInput(
    args_json: []const u8,
    pattern: []const u8,
    input_path: []const u8,
    include: ?[]const u8,
    case_insensitive: bool,
    head_limit: usize,
    offset: usize,
) !void {
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
            if (include) |expected| {
                try std.testing.expect(input.include != null);
                try std.testing.expectEqualStrings(expected, input.include.?);
            } else {
                try std.testing.expect(input.include == null);
            }
            try std.testing.expectEqual(case_insensitive, input.case_insensitive);
            try std.testing.expectEqual(head_limit, input.head_limit);
            try std.testing.expectEqual(offset, input.offset);
        },
    }
}

fn grepArgsJson(
    alloc: Allocator,
    pattern: []const u8,
    maybe_path: ?[]const u8,
    maybe_include: ?[]const u8,
    case_insensitive: ?bool,
    head_limit: ?usize,
    offset: ?usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"pattern\":");
    try std.json.Stringify.value(pattern, .{}, &out.writer);
    if (maybe_path) |path| {
        try out.writer.writeAll(",\"path\":");
        try std.json.Stringify.value(path, .{}, &out.writer);
    }
    if (maybe_include) |include| {
        try out.writer.writeAll(",\"include\":");
        try std.json.Stringify.value(include, .{}, &out.writer);
    }
    if (case_insensitive) |value| {
        try out.writer.print(",\"case_insensitive\":{}", .{value});
    }
    if (head_limit) |value| {
        try out.writer.print(",\"head_limit\":{d}", .{value});
    }
    if (offset) |value| {
        try out.writer.print(",\"offset\":{d}", .{value});
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchGrepFiles(
    alloc: Allocator,
    workspace_root: []const u8,
    pattern: []const u8,
    maybe_path: ?[]const u8,
    maybe_include: ?[]const u8,
    case_insensitive: ?bool,
    head_limit: ?usize,
    offset: ?usize,
) !tool_dispatch.DispatchResult {
    const args = try grepArgsJson(alloc, pattern, maybe_path, maybe_include, case_insensitive, head_limit, offset);
    defer alloc.free(args);

    return dispatchGrepFilesRaw(alloc, workspace_root, args);
}

fn dispatchGrepFilesRaw(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{grep_files_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "grep_files",
        .arguments_json = args_json,
    });
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

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn countEmittedResultLines(body: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, " - ")) count += 1;
    }
    return count;
}

fn matchingLines(alloc: Allocator, count: usize) ![]grep_search.Match {
    const matches = try alloc.alloc(grep_search.Match, count);
    for (matches, 0..) |*match, i| {
        match.* = .{
            .absolute_path = "many.txt",
            .line_number = i + 1,
            .line = "needle",
        };
    }
    return matches;
}

fn grepFilesFailureWithOps(
    alloc: Allocator,
    workspace_root: []const u8,
    path: []const u8,
    include: ?[]const u8,
    ops: CallOps,
) ![]u8 {
    var input = Input{
        .pattern = try alloc.dupe(u8, "needle"),
        .path = try alloc.dupe(u8, path),
        .include = if (include) |value| try alloc.dupe(u8, value) else null,
        .case_insensitive = false,
        .head_limit = output_cap,
        .offset = 0,
    };
    defer input.deinit(alloc);

    const result = try callWithOps(.{ .allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = &input, .deinit_fn = noopInputDeinit }, ops);
    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| return body,
        .success => |body| {
            defer alloc.free(body);
            return error.ExpectedFailure;
        },
    }
}

fn fakeStat(kind: std.Io.File.Kind) std.Io.File.Stat {
    return .{
        .inode = 0,
        .nlink = 1,
        .size = 0,
        .permissions = .default_file,
        .kind = kind,
        .atime = null,
        .mtime = .{ .nanoseconds = 0 },
        .ctime = .{ .nanoseconds = 0 },
        .block_size = 1,
    };
}

fn failingStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return error.InjectedStatFailure;
}

fn accessDeniedStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return error.AccessDenied;
}

fn directoryStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return fakeStat(.directory);
}

fn fileStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return fakeStat(.file);
}

fn namedPipeStatRoot(_: []const u8) anyerror!std.Io.File.Stat {
    return fakeStat(.named_pipe);
}

fn failingCollectDirectory(
    _: Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
    _: bool,
    _: []const []const u8,
    _: ?glob_pattern.Pattern,
) anyerror!grep_search.Result {
    return error.InjectedWalkFailure;
}

fn failingCollectFile(
    _: Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
    _: bool,
    _: ?glob_pattern.Pattern,
) anyerror!grep_search.Result {
    return error.InjectedScanFailure;
}

test "grep_files decodes invalid argument shapes as failures" {
    try expectDecodeFailure("{", "grep_files arguments must be valid JSON");
    try expectDecodeFailure("[]", "grep_files arguments must be an object");
    try expectDecodeFailure("{\"path\":\".\"}", "grep_files requires string field \"pattern\"");
    try expectDecodeFailure("{\"pattern\":1}", "grep_files field \"pattern\" must be a string");
}

test "grep_files validate preserves active raw pattern and path values" {
    const alloc = std.testing.allocator;
    var empty = Input{
        .pattern = try alloc.dupe(u8, " \t\n "),
        .path = try alloc.dupe(u8, "   "),
        .include = null,
        .case_insensitive = false,
        .head_limit = output_cap,
        .offset = 0,
    };
    defer empty.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty, "/tmp/workspace")) == null);
    try std.testing.expectEqualStrings(" \t\n ", empty.pattern);
    try std.testing.expectEqualStrings("   ", empty.path);
}

test "grep_files decodes defaults and all fields" {
    try expectDecodeInput("{\"pattern\":\"needle\"}", "needle", ".", null, false, output_cap, 0);
    try expectDecodeInput("{\"pattern\":\"needle\",\"path\":\"\"}", "needle", ".", null, false, output_cap, 0);
    try expectDecodeInput(
        "{\"pattern\":\"needle\",\"path\":\"src\",\"include\":\"*.zig\",\"case_insensitive\":true,\"head_limit\":5,\"offset\":2}",
        "needle",
        "src",
        "*.zig",
        true,
        5,
        2,
    );
    try expectDecodeInput("{\"pattern\":\"needle\",\"path\":1,\"include\":1,\"case_insensitive\":\"yes\"}", "needle", ".", null, false, output_cap, 0);
}

test "grep_files decodes context_lines above cap as bounded" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"pattern\":\"needle\",\"context_lines\":99}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expectEqual(context_lines_cap, input.context_lines);
        },
    }
}

test "grep_files Input ownership duplicates and frees under testing allocator" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"pattern\":\"needle\",\"path\":\"src\",\"include\":\"*.zig\"}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            const input = erased.as(Input);
            try std.testing.expectEqualStrings("needle", input.pattern);
            try std.testing.expectEqualStrings("src", input.path);
            try std.testing.expectEqualStrings("*.zig", input.include.?);
            erased.deinit(alloc);
        },
    }
}

test "grep_files reports resolver errors as model-visible failures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", "missing.txt", null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "Unable to resolve grep search root: missing.txt ("));
}

test "grep_files reports overlong include patterns before scanning" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "needle\n");
    defer alloc.free(path);
    const include = try alloc.alloc(u8, glob_pattern.max_pattern_bytes + 1);
    defer alloc.free(include);
    @memset(include, 'a');

    var result = try dispatchGrepFiles(alloc, workspace, "needle", path, include, null, null, null);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "grep_files field \"include\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes});
    defer alloc.free(expected);
    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings(expected, result.body);
}

test "grep_files reports stat failures after root resolution" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "needle\n");
    defer alloc.free(path);

    const body = try grepFilesFailureWithOps(alloc, workspace, path, null, .{ .stat_root = failingStatRoot });
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "Unable to stat grep search root: "));
    try std.testing.expect(std.mem.endsWith(u8, body, "(InjectedStatFailure)"));
}

test "grep_files access denial returns structured recovery" {
    const alloc = std.testing.allocator;
    const root = try std.fmt.allocPrint(alloc, "/tmp/fx-grep-files-access-{d}", .{io_mod.nanoTimestamp()});
    defer alloc.free(root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), root) catch {};
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), root);
    const workspace = try io_mod.realpathAlloc(alloc, root);
    defer alloc.free(workspace);
    const path = try std.fs.path.join(alloc, &.{ workspace, "file.txt" });
    defer alloc.free(path);
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "needle\n");
    }

    const body = try grepFilesFailureWithOps(alloc, workspace, path, null, .{ .stat_root = accessDeniedStatRoot });
    defer alloc.free(body);

    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(body));
    try std.testing.expect(std.mem.find(u8, body, "\"tool_name\":\"grep_files\"") != null);
    try std.testing.expect(std.mem.find(u8, body, path) != null);
    try std.testing.expect(std.mem.find(u8, body, "AccessDenied") != null);
    try std.testing.expect(std.mem.find(u8, body, "symlink") != null);
}

test "grep_files reports walk failures for directory roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const body = try grepFilesFailureWithOps(alloc, workspace, ".", null, .{
        .stat_root = directoryStatRoot,
        .collect_directory = failingCollectDirectory,
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "Unable to walk grep search root: "));
    try std.testing.expect(std.mem.endsWith(u8, body, "(InjectedWalkFailure)"));
}

test "grep_files reports scan failures for regular-file roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "needle\n");
    defer alloc.free(path);

    const body = try grepFilesFailureWithOps(alloc, workspace, path, null, .{
        .stat_root = fileStatRoot,
        .collect_file = failingCollectFile,
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "Unable to scan grep file root: "));
    try std.testing.expect(std.mem.endsWith(u8, body, "(InjectedScanFailure)"));
}

test "grep_files single-file non-text root returns empty matches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "binary.txt", "needle\x00binary\n");
    defer alloc.free(path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", path, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n", result.body);
}

test "grep_files single-file oversized root returns empty matches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const content = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(content);
    @memset(content, 'n');
    const path = try writeTempFile(alloc, &tmp, "large.txt", content);
    defer alloc.free(path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", path, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n", result.body);
}

test "grep_files reports non-file non-directory roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "needle\n");
    defer alloc.free(path);

    const body = try grepFilesFailureWithOps(alloc, workspace, path, null, .{ .stat_root = namedPipeStatRoot });
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "Not a regular file or directory: "));
}

test "grep_files single-file search returns matching lines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const file_path = try writeTempFile(alloc, &tmp, "single.txt", "one\nneedle here\n");
    defer alloc.free(file_path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", file_path, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - single.txt:2: needle here\n", result.body);
}

test "grep_files single-file include applies to basename" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const file_path = try writeTempFile(alloc, &tmp, "src/single.zig", "needle\n");
    defer alloc.free(file_path);

    var basename_match = try dispatchGrepFiles(alloc, workspace, "needle", file_path, "*.zig", null, null, null);
    defer basename_match.deinit(alloc);
    try std.testing.expectEqual(.success, basename_match.status);
    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - src/single.zig:1: needle\n", basename_match.body);

    var path_pattern_miss = try dispatchGrepFiles(alloc, workspace, "needle", file_path, "src/*.zig", null, null, null);
    defer path_pattern_miss.deinit(alloc);
    try std.testing.expectEqual(.success, path_pattern_miss.status);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n", path_pattern_miss.body);
}

test "grep_files walks multiple files without sorting" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const first = try writeTempFile(alloc, &tmp, "src/a.txt", "needle a\n");
    defer alloc.free(first);
    const second = try writeTempFile(alloc, &tmp, "src/nested/b.txt", "needle b\n");
    defer alloc.free(second);
    const miss = try writeTempFile(alloc, &tmp, "src/c.txt", "other\n");
    defer alloc.free(miss);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", null, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[grep] 2 matches for needle\n"));
    try std.testing.expect(std.mem.find(u8, result.body, "src/a.txt:1: needle a") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "src/nested/b.txt:1: needle b") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "src/c.txt") == null);
}

test "grep_files finds match beyond former traversal cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var i: usize = 0;
    while (i < 2050) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "many/file-{d:0>4}.txt", .{i});
        const path = try writeTempFile(alloc, &tmp, name, "not here\n");
        alloc.free(path);
    }
    const late = try writeTempFile(alloc, &tmp, "zzzz/match.txt", "needle late\n");
    defer alloc.free(late);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", null, null, null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "zzzz/match.txt:1: needle late") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "traversal cap") == null);
}

test "grep_files include filters walked files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const kept = try writeTempFile(alloc, &tmp, "src/main.zig", "needle in zig\n");
    defer alloc.free(kept);
    const skipped = try writeTempFile(alloc, &tmp, "src/notes.txt", "needle in text\n");
    defer alloc.free(skipped);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", null, "*.zig", null, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "src/main.zig:1: needle in zig") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "notes.txt") == null);
}

test "grep_files supports ASCII case-insensitive matching" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "case.txt", "Needle Here\n");
    defer alloc.free(path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", null, null, true, null, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] 1 matches for needle\n - case.txt:1: Needle Here\n", result.body);
}

test "grep_files paginates matching line output" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "matches.txt", "needle one\nneedle two\nneedle three\n");
    defer alloc.free(path);

    var result = try dispatchGrepFiles(alloc, workspace, "needle", path, null, null, 1, 1);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle (showing 2-2 of 3)\n" ++
            " - matches.txt:2: needle two\n" ++
            "... more matches available; use offset 2 to continue\n",
        result.body,
    );
}

test "grep_files context_lines includes nearby lines around emitted matches" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "context.txt", "one\ntwo\nneedle here\nfour\nfive\n");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"context.txt\",\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n" ++
            "   context.txt:2- two\n" ++
            " - context.txt:3: needle here\n" ++
            "   context.txt:4- four\n",
        result.body,
    );
}

test "grep_files context_lines skips synthetic trailing line after final newline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "trailing.txt", "before\nneedle\n");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"trailing.txt\",\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n" ++
            "   trailing.txt:1- before\n" ++
            " - trailing.txt:2: needle\n",
        result.body,
    );
}

test "grep_files context_lines skips after-context at EOF without final newline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "no-trailing.txt", "before\nneedle");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"no-trailing.txt\",\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n" ++
            "   no-trailing.txt:1- before\n" ++
            " - no-trailing.txt:2: needle\n",
        result.body,
    );
}

test "grep_files context_lines preserves real blank lines in range" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "blank-context.txt", "before\nneedle\n\nafter\n");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"blank-context.txt\",\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle\n" ++
            "   blank-context.txt:1- before\n" ++
            " - blank-context.txt:2: needle\n" ++
            "   blank-context.txt:3- \n",
        result.body,
    );
}

test "grep_files context_lines follows match pagination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "paged.txt", "before one\nneedle one\nafter one\nbefore two\nneedle two\nafter two\n");
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"paged.txt\",\"head_limit\":1,\"offset\":1,\"context_lines\":1}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(
        "[grep] 1 matches for needle (showing 2-2 of 2)\n" ++
            "   paged.txt:4- before two\n" ++
            " - paged.txt:5: needle two\n" ++
            "   paged.txt:6- after two\n",
        result.body,
    );
}

test "grep_files context_lines does not affect files_with_matches or count modes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "modes.txt", "before\nneedle\nafter\n");
    defer alloc.free(path);

    var files_result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"modes.txt\",\"mode\":\"files_with_matches\",\"context_lines\":1}");
    defer files_result.deinit(alloc);
    try std.testing.expectEqual(.success, files_result.status);
    try std.testing.expectEqualStrings("[grep] 1 files with matches for needle\n - modes.txt\n", files_result.body);

    var count_result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"path\":\"modes.txt\",\"mode\":\"count\",\"context_lines\":1}");
    defer count_result.deinit(alloc);
    try std.testing.expectEqual(.success, count_result.status);
    try std.testing.expectEqualStrings("[grep] count 1 matching lines in 1 files for needle\n", count_result.body);
}

test "grep_files files_with_matches mode returns unique paginated paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const one = try writeTempFile(alloc, &tmp, "one.txt", "needle first\nneedle second\n");
    defer alloc.free(one);
    const two = try writeTempFile(alloc, &tmp, "two.txt", "needle third\n");
    defer alloc.free(two);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"mode\":\"files_with_matches\",\"head_limit\":10}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[grep] 2 files with matches for needle\n"));
    try std.testing.expect(std.mem.find(u8, result.body, " - one.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, result.body, " - two.txt\n") != null);
    try std.testing.expectEqual(@as(usize, 2), countEmittedResultLines(result.body));
}

test "grep_files formatter uses active pagination cap" {
    const alloc = std.testing.allocator;
    const matches = try matchingLines(alloc, 3);
    defer alloc.free(matches);

    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = matches }, 2, 0, 0, 2, 2000);
    defer alloc.free(body);

    try std.testing.expectEqualStrings(
        "[grep] 2 matches for needle (showing 1-2 of 3)\n" ++
            " - many.txt:1: needle\n" ++
            " - many.txt:2: needle\n" ++
            "... more matches available; use offset 2 to continue\n",
        body,
    );
}

test "grep_files formatter does not report output truncation for exactly active cap" {
    const alloc = std.testing.allocator;
    const matches = try matchingLines(alloc, tool_dispatch.default_max_list_entries);
    defer alloc.free(matches);

    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = matches }, output_cap, 0, 0, tool_dispatch.default_max_list_entries, 2000);
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "[grep] 100 matches for needle\n"));
    try std.testing.expectEqual(tool_dispatch.default_max_list_entries, countEmittedResultLines(body));
    try std.testing.expect(std.mem.find(u8, body, "more matches available") == null);
}

test "grep_files formatter reports active truncation when cap hides matches" {
    const alloc = std.testing.allocator;
    const matches = try matchingLines(alloc, tool_dispatch.default_max_list_entries + 1);
    defer alloc.free(matches);

    const body = try formatMatches(alloc, alloc, "", "needle", .{ .matches = matches }, output_cap, 0, 0, tool_dispatch.default_max_list_entries, 2000);
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "[grep] 100 matches for needle (showing 1-100 of 101)\n"));
    try std.testing.expectEqual(tool_dispatch.default_max_list_entries, countEmittedResultLines(body));
    try std.testing.expect(std.mem.endsWith(u8, body, "... more matches available; use offset 100 to continue\n"));
}

test "grep_files formatter reports collection cap separately from output truncation" {
    const alloc = std.testing.allocator;
    const matches = try matchingLines(alloc, grep_search.collection_cap);
    defer alloc.free(matches);

    const body = try formatMatches(alloc, alloc, "", "needle", .{
        .matches = matches,
        .truncated_reason = .collection_cap,
    }, output_cap, 0, 0, tool_dispatch.default_max_list_entries, 2000);
    defer alloc.free(body);

    try std.testing.expect(std.mem.startsWith(u8, body, "[grep] 100 matches for needle (showing 1-100 of 2000)\n"));
    try std.testing.expectEqual(tool_dispatch.default_max_list_entries, countEmittedResultLines(body));
    try std.testing.expect(std.mem.find(u8, body, "... more matches available; use offset 100 to continue\n") != null);
    try std.testing.expect(std.mem.find(u8, body, "match collection cap reached at 2000 matches") != null);
}

test "grep_files count mode reports exact matching lines beyond collection cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    var i: usize = 0;
    while (i < grep_search.collection_cap + 1) : (i += 1) {
        try content.writer.writeAll("needle\n");
    }
    const path = try writeTempFile(alloc, &tmp, "many.txt", content.written());
    defer alloc.free(path);

    var result = try dispatchGrepFilesRaw(alloc, workspace, "{\"pattern\":\"needle\",\"mode\":\"count\"}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[grep] count 2001 matching lines in 1 files for needle\n", result.body);
    try std.testing.expectEqual(@as(usize, 0), countEmittedResultLines(result.body));
}

test "grep_files formatter reports candidate cap without output truncation wording" {
    const alloc = std.testing.allocator;

    const body = try formatMatches(alloc, alloc, "", "needle", .{
        .matches = &.{},
        .candidate_incomplete = true,
        .candidate_cap = 2,
    }, output_cap, 0, 0, tool_dispatch.default_max_list_entries, 2000);
    defer alloc.free(body);

    try std.testing.expectEqualStrings("[grep] no matches for needle\n... candidate list may be incomplete; candidate cap 2 reached before all files were discovered\n", body);
}

test "grep_files classifiers are read-only and reversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{
        .pattern = try std.testing.allocator.dupe(u8, "needle"),
        .path = try std.testing.allocator.dupe(u8, "."),
        .include = null,
        .case_insensitive = false,
        .head_limit = output_cap,
        .offset = 0,
    };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}
