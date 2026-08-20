const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");

pub const Config = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_line_len: usize,
};

const walk_entry_cap: usize = 2000;

pub const Input = struct {
    query: []u8,
    path: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: std.mem.Allocator) void {
        alloc.free(self.query);
        if (self.path) |path| alloc.free(path);
        self.* = .{ .query = &.{}, .path = null };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return error.InvalidToolArguments;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidToolArguments;

    const query_value = parsed.value.object.get("query") orelse return error.InvalidToolArguments;
    if (query_value != .string) return error.InvalidToolArguments;

    const path_value = parsed.value.object.get("path");
    if (path_value) |value| {
        if (value != .string) return error.InvalidToolArguments;
    }

    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);

    const path: ?[]u8 = if (path_value) |value|
        try ctx.allocator.dupe(u8, value.string)
    else
        null;
    errdefer if (path) |owned| ctx.allocator.free(owned);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .query = query, .path = path };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const requested = input.path orelse ".";

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const output = runSearch(configFromContext(ctx), arena_state.allocator(), input.query, requested) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return error.InvalidPath,
        error.FileNotFound => return error.FileNotFound,
        error.PathOutsideWorkspace => return error.PathOutsideWorkspace,
        error.WorkspaceUnavailable => return error.WorkspaceUnavailable,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "semantic_search failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = try ctx.allocator.dupe(u8, output) };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn runSearch(cfg: Config, arena: std.mem.Allocator, query: []const u8, requested: []const u8) ![]u8 {
    const root = try resolveSearchRoot(cfg, arena, requested);

    var keywords_buf: [16][]const u8 = undefined;
    const keyword_count = splitSearchKeywords(query, &keywords_buf);
    if (keyword_count == 0) {
        return std.fmt.allocPrint(arena, "[search] empty query\n", .{});
    }
    const keywords = keywords_buf[0..keyword_count];

    var results: std.ArrayList(FileScore) = .empty;
    defer results.deinit(arena);
    var walk_capped = false;
    var result_capped = false;
    const retained_result_cap = retainedResultCap(cfg.max_list_entries);

    if (root.is_directory) {
        var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), root.absolute, .{ .iterate = true });
        defer dir.close(io_mod.getIo());

        var walker = try dir.walk(arena);
        defer walker.deinit();

        var walked_entries: usize = 0;
        while (true) {
            if (walked_entries >= walk_entry_cap) {
                walk_capped = true;
                debug_trace.logf("core", "semantic_search traversal cap reached root={s} walked_entries={d}", .{ root.absolute, walked_entries });
                break;
            }
            const entry = (try walker.next(io_mod.getIo())) orelse break;
            walked_entries += 1;

            const ignored = pathContainsIgnoredDir(cfg.ignored_list_entries, entry.path);
            if (entry.kind == .directory) {
                if (ignored) walker.leave(io_mod.getIo());
                continue;
            }
            if (ignored) continue;

            const file_abs = try std.fs.path.join(arena, &.{ root.absolute, entry.path });
            const display_rel = try joinRelativeSearchPath(arena, root.relative, entry.path);

            const maybe_read_abs = resolveDirectoryEntryTarget(arena, root.scope_root, file_abs, entry.kind) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                logSemanticScanError(file_abs, err);
                continue;
            };
            const read_abs = maybe_read_abs orelse continue;
            const file_score = scoreFileForKeywords(arena, file_abs, read_abs, keywords, cfg.max_read_file_bytes * 2) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                logSemanticScanError(file_abs, err);
                continue;
            };
            if (file_score.score > 0) {
                if (results.items.len >= retained_result_cap) {
                    result_capped = true;
                    debug_trace.logf("core", "semantic_search result cap reached root={s} retained_results={d}", .{ root.absolute, results.items.len });
                    break;
                }
                try results.append(arena, .{
                    .path = display_rel,
                    .score = file_score.score,
                    .sample_line = file_score.sample_line,
                    .sample_line_number = file_score.sample_line_number,
                });
            }
        }
    } else {
        if (scoreFileForKeywords(
            arena,
            root.absolute,
            root.absolute,
            keywords,
            cfg.max_read_file_bytes * 2,
        )) |file_score| {
            if (file_score.score > 0) {
                try results.append(arena, .{
                    .path = root.relative,
                    .score = file_score.score,
                    .sample_line = file_score.sample_line,
                    .sample_line_number = file_score.sample_line_number,
                });
            }
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            logSemanticScanError(root.absolute, err);
        }
    }

    sort_utils.sort(FileScore, results.items, {}, struct {
        fn cmp(_: void, a: FileScore, b: FileScore) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.cmp);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    const shown = @min(results.items.len, cfg.max_list_entries);
    if (shown == 0) {
        try out.writer.print("[search] no results for: {s}\n", .{query});
        try writeIncompleteSearchNotes(&out.writer, walk_capped, result_capped);
        return try out.toOwnedSlice();
    }

    try out.writer.print("[search] {d} results for: {s}\n", .{ shown, query });
    for (results.items[0..shown]) |entry| {
        const clipped = entry.sample_line[0..@min(entry.sample_line.len, cfg.max_read_file_line_len)];
        try out.writer.print("{s}:{d}: {s}\n", .{ entry.path, entry.sample_line_number, clipped });
    }

    if (results.items.len > shown) {
        try out.writer.print("... and {d} more\n", .{results.items.len - shown});
    }
    try writeIncompleteSearchNotes(&out.writer, walk_capped, result_capped);

    return try out.toOwnedSlice();
}

fn retainedResultCap(max_list_entries: usize) usize {
    if (max_list_entries == 0) return 1;
    if (max_list_entries > std.math.maxInt(usize) / 2) return std.math.maxInt(usize);
    return max_list_entries * 2;
}

fn writeIncompleteSearchNotes(writer: anytype, walk_capped: bool, result_capped: bool) !void {
    if (walk_capped) {
        try writer.writeAll("... results may be incomplete; traversal cap reached before all files were searched\n");
    }
    if (result_capped) {
        try writer.writeAll("... results may be incomplete; result cap reached before all matching files were scored\n");
    }
}

fn configFromContext(ctx: tool_dispatch.DispatchContext) Config {
    return .{
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.access_scope,
        .ignored_list_entries = ctx.ignored_list_entries,
        .max_list_entries = ctx.max_list_entries,
        .max_read_file_bytes = ctx.max_read_file_bytes,
        .max_read_file_line_len = ctx.max_read_file_line_len,
    };
}

const SearchRoot = struct {
    absolute: []const u8,
    relative: []const u8,
    is_directory: bool,
    scope_root: []const u8,
};

const FileScore = struct {
    path: []const u8,
    score: u32,
    sample_line: []const u8,
    sample_line_number: usize,
};

const ScoreResult = struct {
    score: u32,
    sample_line: []const u8,
    sample_line_number: usize,
};

fn resolveSearchRoot(cfg: Config, arena: std.mem.Allocator, requested: []const u8) !SearchRoot {
    const scope = cfg.access_scope orelse workspace_access.AccessScope.primaryOnly(cfg.workspace_root);
    const absolute = try scope.resolvePath(arena, requested, .existing);
    const scope_root = scope.rootForPath(absolute) orelse return error.PathOutsideWorkspace;
    const relative = if (std.mem.eql(u8, scope_root, cfg.workspace_root))
        try pathing.workspaceRelativePath(arena, cfg.workspace_root, absolute)
    else
        absolute;

    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return .{ .absolute = absolute, .relative = relative, .is_directory = false, .scope_root = scope_root },
        else => return err,
    };
    dir.close(io_mod.getIo());

    return .{ .absolute = absolute, .relative = relative, .is_directory = true, .scope_root = scope_root };
}

fn joinRelativeSearchPath(arena: std.mem.Allocator, root_relative: []const u8, child_relative: []const u8) ![]u8 {
    if (std.mem.eql(u8, root_relative, ".") or root_relative.len == 0) {
        return arena.dupe(u8, child_relative);
    }
    return std.fs.path.join(arena, &.{ root_relative, child_relative });
}

fn resolveDirectoryEntryTarget(arena: std.mem.Allocator, workspace_root: []const u8, absolute_path: []const u8, entry_kind: std.Io.File.Kind) !?[]const u8 {
    const resolved = try io_mod.realpathAlloc(arena, absolute_path);
    if (entry_kind == .sym_link and !pathing.pathInside(workspace_root, resolved)) {
        debug_trace.logf("core", "semantic_search skipped external symlink target path={s} target={s}", .{ absolute_path, resolved });
        return null;
    }
    return resolved;
}

fn scoreFileForKeywords(arena: std.mem.Allocator, display_abs: []const u8, read_abs: []const u8, keywords: []const []const u8, max_bytes: usize) !ScoreResult {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), read_abs, .{});
    defer file.close(io_mod.getIo());

    const content = try io_mod.readFileToEnd(arena, &file, max_bytes);
    if (!text_utils.isModelSafeText(content)) {
        debug_trace.logf("core", "semantic_search skipped non-text file path={s} reason={s}", .{ display_abs, modelUnsafeReason(content) });
        return .{ .score = 0, .sample_line = "", .sample_line_number = 0 };
    }

    var total_score: u32 = 0;
    var best_line: []const u8 = "";
    var best_line_number: usize = 0;
    var best_line_score: u32 = 0;

    var line_number: usize = 1;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_number += 1) {
        var line_score: u32 = 0;
        for (keywords) |kw| {
            if (text_utils.containsIgnoreCase(line, kw)) {
                line_score += 1;
            }
        }
        if (line_score > 0) {
            total_score += line_score;
            if (line_score > best_line_score) {
                best_line_score = line_score;
                best_line = line;
                best_line_number = line_number;
            }
        }
    }

    for (keywords) |kw| {
        if (text_utils.containsIgnoreCase(std.fs.path.basename(display_abs), kw)) {
            total_score += 3;
        }
    }

    return .{ .score = total_score, .sample_line = best_line, .sample_line_number = best_line_number };
}

fn logSemanticScanError(path: []const u8, err: anyerror) void {
    if (err == error.StreamTooLong) {
        debug_trace.logf("core", "semantic_search skipped oversized file path={s}", .{path});
        return;
    }
    debug_trace.logf("core", "semantic_search scan skipped path={s} err={s}", .{ path, @errorName(err) });
}

fn modelUnsafeReason(content: []const u8) []const u8 {
    if (std.mem.findScalar(u8, content, 0) != null) return "contains_nul";
    if (!std.unicode.utf8ValidateSlice(content)) return "invalid_utf8";
    return "not_model_safe";
}

fn splitSearchKeywords(query: []const u8, out: *[16][]const u8) usize {
    const stop_words = [_][]const u8{ "a", "an", "the", "is", "are", "was", "were", "in", "on", "at", "to", "for", "of", "and", "or", "not", "it", "this", "that", "with", "from", "by", "as", "do", "does", "how", "what", "where", "when", "why", "which" };
    var count: usize = 0;
    var i: usize = 0;
    while (i < query.len and count < 16) {
        while (i < query.len and isSearchSplitter(query[i])) : (i += 1) {}
        const start = i;
        while (i < query.len and !isSearchSplitter(query[i])) : (i += 1) {}
        if (i > start and i - start >= 2) {
            const word = query[start..i];
            var is_stop = false;
            for (stop_words) |sw| {
                if (std.ascii.eqlIgnoreCase(word, sw)) {
                    is_stop = true;
                    break;
                }
            }
            if (!is_stop) {
                out[count] = word;
                count += 1;
            }
        }
    }
    return count;
}

fn isSearchSplitter(c: u8) bool {
    return c == ' ' or c == '\t' or c == ',' or c == '.' or c == ';' or c == ':' or c == '?' or c == '!';
}

fn shouldIgnoreListedEntry(ignored: []const []const u8, name: []const u8) bool {
    for (ignored) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn pathContainsIgnoredDir(ignored: []const []const u8, path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (shouldIgnoreListedEntry(ignored, component.name)) return true;
    }
    return false;
}

fn testConfig(workspace_root: []const u8) Config {
    return .{
        .workspace_root = workspace_root,
        .ignored_list_entries = &.{},
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_line_len = 200,
    };
}

test "semantic search config uses dispatch context limits" {
    const ignored = [_][]const u8{"ignored"};
    const cfg = configFromContext(.{
        .allocator = std.testing.allocator,
        .workspace_root = "/workspace",
        .ignored_list_entries = &ignored,
        .max_list_entries = 7,
        .max_read_file_bytes = 11,
        .max_read_file_line_len = 17,
    });

    try std.testing.expectEqualStrings("/workspace", cfg.workspace_root);
    try std.testing.expectEqualSlices([]const u8, &ignored, cfg.ignored_list_entries);
    try std.testing.expectEqual(@as(usize, 7), cfg.max_list_entries);
    try std.testing.expectEqual(@as(usize, 11), cfg.max_read_file_bytes);
    try std.testing.expectEqual(@as(usize, 17), cfg.max_read_file_line_len);
}

test "semantic search resolves active added roots and rejects removed roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "shared");
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    const entries = [_]workspace_access.Entry{.{
        .path = @constCast(shared),
        .saved = true,
        .command_line = false,
        .available = true,
        .active = true,
    }};
    var cfg = testConfig(primary);
    cfg.access_scope = .{
        .primary_directory = primary,
        .additional_directories = &entries,
    };

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const resolved = try resolveSearchRoot(cfg, arena_state.allocator(), shared);
    try std.testing.expectEqualStrings(shared, resolved.absolute);
    try std.testing.expectEqualStrings(shared, resolved.relative);
    try std.testing.expectEqualStrings(shared, resolved.scope_root);

    cfg.access_scope = workspace_access.AccessScope.primaryOnly(primary);
    try std.testing.expectError(error.PathOutsideWorkspace, resolveSearchRoot(cfg, arena_state.allocator(), shared));
}

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn createSymlinkOrSkip(dir: std.Io.Dir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    dir.symLink(io_mod.getIo(), target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) return error.SkipZigTest;
        return err;
    };
}

fn readTrace(alloc: std.mem.Allocator, trace_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(io_mod.getIo());
    var read_buf: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    return reader.interface.allocRemaining(alloc, std.Io.Limit.limited(4096));
}

fn contentWithPrefix(alloc: std.mem.Allocator, len: usize, prefix: []const u8) ![]u8 {
    const content = try alloc.alloc(u8, len);
    @memset(content, 'x');
    const prefix_len = @min(prefix.len, content.len);
    @memcpy(content[0..prefix_len], prefix[0..prefix_len]);
    return content;
}

fn workspaceRoot(alloc: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
}

fn searchArgsJson(alloc: std.mem.Allocator, query: []const u8, maybe_path: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"query\":");
    try std.json.Stringify.value(query, .{}, &out.writer);
    if (maybe_path) |path| {
        try out.writer.writeAll(",\"path\":");
        try std.json.Stringify.value(path, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn noopInputDeinit(_: *anyopaque, _: std.mem.Allocator) void {}

const semantic_search_dispatch_tool = tool_dispatch.Tool{
    .name = "semantic_search",
    .description = "Semantic search dispatch test fixture.",
    .descriptor = .{
        .name = "semantic_search",
        .description = "Semantic search dispatch test fixture.",
    },
    .executor_kind = .semantic_search,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Searching",
    .completed_action_label = "Searched",
    .label_arg_kind = .query,
    .label_arg_default = "query",
    .permission_target_kind = .path_optional_existing,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

fn dispatchSemanticSearch(alloc: std.mem.Allocator, workspace: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{semantic_search_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .workspace_root = workspace,
    }, registry, .{
        .id = "semantic_1",
        .name = "semantic_search",
        .arguments_json = args_json,
    });
}

test "semantic_search tool input keeps read-only classification" {
    var input = Input{ .query = try std.testing.allocator.dupe(u8, "alpha") };
    defer input.deinit(std.testing.allocator);
    const erased = tool_dispatch.ToolInput{ .ptr = &input, .deinit_fn = noopInputDeinit };

    try std.testing.expect(readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}

test "semantic_search tool dispatch preserves raw query in result header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/docs/guide.txt", "alpha topic line\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var result = try dispatchSemanticSearch(alloc, workspace, "{\"query\":\"  alpha  \"}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "[search] 1 results for:   alpha  \n"));
}

test "semantic_search tool dispatch defaults omitted path to workspace root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/readme.txt", "needle appears here\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var result = try dispatchSemanticSearch(alloc, workspace, "{\"query\":\"needle\"}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "readme.txt:1: needle appears here") != null);
}

test "semantic_search tool dispatch preserves stopword-only search output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var result = try dispatchSemanticSearch(alloc, workspace, "{\"query\":\"the and it\"}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[search] empty query\n", result.body);
}

test "semantic_search tool dispatch preserves invalid path errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    try std.testing.expectError(error.InvalidPath, dispatchSemanticSearch(alloc, workspace, "{\"query\":\"needle\",\"path\":\"   \"}"));
}

test "semantic_search tool dispatch rejects external absolute roots before execution" {
    var workspace_tmp = std.testing.tmpDir(.{});
    defer workspace_tmp.cleanup();
    try workspace_tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var external_tmp = std.testing.tmpDir(.{});
    defer external_tmp.cleanup();
    try writeTestFile(external_tmp.dir, "outside.txt", "needle external\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, workspace_tmp);
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, external_tmp.dir, ".");
    defer alloc.free(external);

    const args = try searchArgsJson(alloc, "needle", external);
    defer alloc.free(args);
    const result = dispatchSemanticSearch(alloc, workspace, args);
    if (result) |ok| {
        var owned = ok;
        defer owned.deinit(alloc);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.PathOutsideWorkspace, err);
    }
}

test "semantic_search tool dispatch rejects non-string path as invalid arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    try std.testing.expectError(error.InvalidToolArguments, dispatchSemanticSearch(alloc, workspace, "{\"query\":\"needle\",\"path\":3}"));
}

test "semantic search returns empty query for stopword-only input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try runSearch(testConfig(workspace), arena, "the and it", ".");
    try std.testing.expectEqualStrings("[search] empty query\n", result);
}

test "semantic search finds directory content matches and clips active output lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/docs/guide.txt", "alpha topic line continues\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = testConfig(workspace);
    cfg.max_read_file_line_len = 11;

    const result = try runSearch(cfg, arena, "alpha", ".");
    try std.testing.expectEqualStrings("[search] 1 results for: alpha\ndocs/guide.txt:1: alpha topic\n", result);
}

test "semantic search basename scoring affects deterministic ordering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/beta.txt", "alpha\n");
    try writeTestFile(tmp.dir, "workspace/alpha-name.txt", "alpha\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try runSearch(testConfig(workspace), arena, "alpha", ".");
    try std.testing.expect(std.mem.startsWith(u8, result, "[search] 2 results for: alpha\nalpha-name.txt:1: alpha\n"));
    try std.testing.expect(std.mem.find(u8, result, "\nbeta.txt:1: alpha\n") != null);
}

test "semantic search returns no results when content does not match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/readme.txt", "nothing useful here\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try runSearch(testConfig(workspace), arena, "missing", ".");
    try std.testing.expectEqualStrings("[search] no results for: missing\n", result);
}

test "semantic search finds direct-file root content matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/direct.txt", "needle is here\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try runSearch(testConfig(workspace), arena, "needle", "direct.txt");
    try std.testing.expectEqualStrings("[search] 1 results for: needle\ndirect.txt:1: needle is here\n", result);
}

test "semantic search returns no results for direct-file root no match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/direct.txt", "needle is here\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try runSearch(testConfig(workspace), arena, "missing", "direct.txt");
    try std.testing.expectEqualStrings("[search] no results for: missing\n", result);
}

test "semantic search traces non-text and oversized direct-file roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/binary.bin", "needle\x00binary\n");
    const alloc = std.testing.allocator;
    const oversized_content = try contentWithPrefix(alloc, 2049, "needle hidden\n");
    defer alloc.free(oversized_content);
    try writeTestFile(tmp.dir, "workspace/huge.txt", oversized_content);

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = testConfig(workspace);
    cfg.max_read_file_bytes = 1024;

    const binary_result = try runSearch(cfg, arena, "needle", "binary.bin");
    try std.testing.expectEqualStrings("[search] no results for: needle\n", binary_result);
    const oversized_result = try runSearch(cfg, arena, "needle", "huge.txt");
    try std.testing.expectEqualStrings("[search] no results for: needle\n", oversized_result);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "semantic_search skipped non-text file path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "binary.bin") != null);
    try std.testing.expect(std.mem.find(u8, trace, "reason=contains_nul") != null);
    try std.testing.expect(std.mem.find(u8, trace, "semantic_search skipped oversized file path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "huge.txt") != null);
}

test "semantic search directory traversal cap reports incomplete results and trace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var i: usize = 0;
    while (i < walk_entry_cap + 50) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "workspace/many/file-{d:0>4}.txt", .{i});
        try writeTestFile(tmp.dir, name, "not here\n");
    }

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try runSearch(testConfig(workspace), arena, "needle", ".");
    try std.testing.expectEqualStrings(
        "[search] no results for: needle\n... results may be incomplete; traversal cap reached before all files were searched\n",
        result,
    );

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "semantic_search traversal cap reached root=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "walked_entries=2000") != null);
}

test "semantic search honors ignored directories and max result cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/a.txt", "needle one\n");
    try writeTestFile(tmp.dir, "workspace/b.txt", "needle two\n");
    try writeTestFile(tmp.dir, "workspace/c.txt", "needle three\n");
    try writeTestFile(tmp.dir, "workspace/skip/ignored.txt", "needle ignored\n");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = testConfig(workspace);
    cfg.ignored_list_entries = &.{"skip"};
    cfg.max_list_entries = 1;

    const result = try runSearch(cfg, arena, "needle", ".");
    try std.testing.expect(std.mem.startsWith(u8, result, "[search] 1 results for: needle\n"));
    try std.testing.expect(std.mem.find(u8, result, "skip/ignored.txt") == null);
    try std.testing.expect(std.mem.find(u8, result, "... and 1 more\n") != null);
}

test "semantic search directory traversal skips external symlink targets with trace" {
    var workspace_tmp = std.testing.tmpDir(.{});
    defer workspace_tmp.cleanup();
    var external_tmp = std.testing.tmpDir(.{});
    defer external_tmp.cleanup();

    try writeTestFile(workspace_tmp.dir, "workspace/target/internal.txt", "needle internal\n");
    try writeTestFile(external_tmp.dir, "outside.txt", "needle external\n");
    try workspace_tmp.dir.createDirPath(io_mod.getIo(), "workspace/links");
    try createSymlinkOrSkip(workspace_tmp.dir, "../target/internal.txt", "workspace/links/internal.txt");

    const alloc = std.testing.allocator;
    const workspace = try workspaceRoot(alloc, workspace_tmp);
    defer alloc.free(workspace);
    const external_target = try io_mod.dirRealpathAlloc(alloc, external_tmp.dir, "outside.txt");
    defer alloc.free(external_target);
    try createSymlinkOrSkip(workspace_tmp.dir, external_target, "workspace/links/external.txt");

    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = testArena();
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try runSearch(testConfig(workspace), arena, "needle", "links");

    try std.testing.expect(std.mem.find(u8, result, "links/internal.txt:1: needle internal") != null);
    try std.testing.expect(std.mem.find(u8, result, "external") == null);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "semantic_search skipped external symlink target path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "links/external.txt") != null);
    try std.testing.expect(std.mem.find(u8, trace, external_target) != null);
}
