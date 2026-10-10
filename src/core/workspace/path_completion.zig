const std = @import("std");
const builtin = @import("builtin");
const file_picker_path = @import("../input/file_picker_path.zig");
const file_index = @import("file_index.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("pathing.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const QueryMode = enum {
    workspace_index,
    explicit_path,
};

pub const Error = error{
    NoSpaceLeft,
    PathUnavailable,
};

const ParsedQuery = struct {
    parent: []const u8,
    display_prefix: []const u8,
    basename_query: []const u8,
};

pub fn queryMode(query: []const u8) QueryMode {
    return if (parseExplicitQuery(query) != null) .explicit_path else .workspace_index;
}

pub fn complete(
    workspace_root: []const u8,
    query: []const u8,
    out: []file_index.SearchResult,
    match_spans: []file_index.MatchSpan,
    path_storage: []u8,
) Error!usize {
    return completeCancellable(workspace_root, io_mod.getenv("HOME"), query, null, out, match_spans, path_storage) catch |err| switch (err) {
        error.Cancelled => unreachable,
        else => |failure| return failure,
    };
}

/// Blocking directory operation. Inputs and output storage belong to the caller;
/// cancellation is cooperative and cannot interrupt an in-flight filesystem call.
pub fn completeCancellable(
    workspace_root: []const u8,
    home_dir: ?[]const u8,
    query: []const u8,
    cancel: ?*const std.atomic.Value(bool),
    out: []file_index.SearchResult,
    match_spans: []file_index.MatchSpan,
    path_storage: []u8,
) (Error || error{Cancelled})!usize {
    try checkCancellation(cancel);
    if (out.len == 0) return 0;
    const parsed = parseExplicitQuery(query) orelse return 0;
    const matcher = file_index.NameQuery.init(parsed.basename_query) orelse return 0;
    var scores: [file_index.max_search_results]file_index.NameQuery.Score = undefined;
    const slot_len: usize = file_index.max_path_len;
    if (out.len > scores.len or out.len > path_storage.len / slot_len) return error.NoSpaceLeft;

    var resolve_storage: [file_index.max_path_len * 4]u8 = undefined;
    var resolve_fba = std.heap.FixedBufferAllocator.init(&resolve_storage);
    try checkCancellation(cancel);
    const resolved = pathing.resolve_workspace_or_external_literal_path_with_home(
        resolve_fba.allocator(),
        workspace_root,
        parsed.parent,
        home_dir,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.NoSpaceLeft,
        else => return error.PathUnavailable,
    };

    const io = io_mod.getIo();
    try checkCancellation(cancel);
    var dir = std.Io.Dir.openDirAbsolute(io, resolved, .{ .iterate = true }) catch return error.PathUnavailable;
    defer dir.close(io);

    // Listing a folder's contents: the folder itself is the first row, so it
    // can be selected and not only opened.
    const folder = listedFolder(parsed);
    const reserved: usize = @intFromBool(folder != null);
    const entries = out[reserved..];
    const entry_storage = path_storage[reserved * slot_len ..];

    var count: usize = 0;
    var iterator = dir.iterate();
    while (true) {
        try checkCancellation(cancel);
        const entry = (iterator.next(io) catch return error.PathUnavailable) orelse break;
        try checkCancellation(cancel);
        if (!text_utils.isTerminalSafe(entry.name)) continue;
        const score = matcher.score(entry.name) orelse continue;
        // candidateKind may stat symlinks or unknown kinds.
        try checkCancellation(cancel);
        const kind = candidateKind(&dir, entry.name, entry.kind) orelse continue;

        var candidate_storage: [file_index.max_path_len]u8 = undefined;
        const candidate_len = parsed.display_prefix.len + entry.name.len;
        if (candidate_len > candidate_storage.len) continue;
        @memcpy(candidate_storage[0..parsed.display_prefix.len], parsed.display_prefix);
        @memcpy(candidate_storage[parsed.display_prefix.len..candidate_len], entry.name);
        const candidate = candidate_storage[0..candidate_len];
        if (!text_utils.isTerminalSafe(candidate)) continue;
        if (!file_picker_path.isRepresentable(candidate)) continue;
        count = insertCandidate(entries, entry_storage, &scores, &matcher, count, candidate, kind, score);
    }

    var spans_used: usize = 0;
    for (entries[0..count]) |*result| {
        try checkCancellation(cancel);
        const span_count = matcher.match_spans(result.path[parsed.display_prefix.len..], match_spans[spans_used..]) catch |err| switch (err) {
            error.NoSpaceLeft => return error.NoSpaceLeft,
            error.InvalidIndexData => return error.PathUnavailable,
        };
        const spans = match_spans[spans_used..][0..span_count];
        for (spans) |*span| {
            span.byte_start += @intCast(parsed.display_prefix.len);
            span.byte_end += @intCast(parsed.display_prefix.len);
        }
        result.matched_spans = spans;
        spans_used += span_count;
    }
    if (folder) |path| {
        const slot = pathSlot(path_storage, 0);
        @memcpy(slot[0..path.len], path);
        out[0] = .{ .path = slot[0..path.len], .kind = .directory, .matched_spans = &.{} };
    }
    try checkCancellation(cancel);
    return reserved + count;
}

/// The folder whose contents a query lists (`src/` lists `src`, `~` lists
/// `~`), or null when the query names a partial entry or the root.
fn listedFolder(parsed: ParsedQuery) ?[]const u8 {
    if (parsed.basename_query.len != 0) return null;
    const prefix = parsed.display_prefix;
    if (prefix.len < 2 or !std.fs.path.isSep(prefix[prefix.len - 1])) return null;
    const folder = prefix[0 .. prefix.len - 1];
    if (std.fs.path.isSep(folder[folder.len - 1])) return null;
    if (!text_utils.isTerminalSafe(folder) or !file_picker_path.isRepresentable(folder)) return null;
    return folder;
}

fn checkCancellation(cancel: ?*const std.atomic.Value(bool)) error{Cancelled}!void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
}

pub fn isCurrentCandidateKind(
    workspace_root: []const u8,
    path: []const u8,
    expected_kind: file_index.CandidateKind,
) bool {
    if (!text_utils.isTerminalSafe(path)) return false;

    var resolve_storage: [file_index.max_path_len * 4]u8 = undefined;
    var resolve_fba = std.heap.FixedBufferAllocator.init(&resolve_storage);
    const resolved = pathing.resolve_workspace_or_external_literal_path(
        resolve_fba.allocator(),
        workspace_root,
        path,
    ) catch return false;
    const stat = std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        resolved,
        .{ .follow_symlinks = true },
    ) catch return false;
    return kindMatchesStat(expected_kind, stat.kind);
}

fn parseExplicitQuery(query: []const u8) ?ParsedQuery {
    inline for (.{ "~", ".", ".." }) |shortcut| {
        if (std.mem.eql(u8, query, shortcut)) return .{
            .parent = query,
            .display_prefix = shortcut ++ "/",
            .basename_query = "",
        };
    }
    var separator_index: ?usize = null;
    for (query, 0..) |byte, index| {
        if (std.fs.path.isSep(byte)) separator_index = index;
    }
    const separator = separator_index orelse return null;
    const parent = if (separator == 0) query[0..1] else query[0..separator];
    return .{
        .parent = parent,
        .display_prefix = query[0 .. separator + 1],
        .basename_query = query[separator + 1 ..],
    };
}

fn candidateKind(
    dir: *std.Io.Dir,
    name: []const u8,
    observed_kind: std.Io.File.Kind,
) ?file_index.CandidateKind {
    return switch (observed_kind) {
        .file => .file,
        .directory => .directory,
        .sym_link, .unknown => {
            const stat = dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = true }) catch return null;
            return kindFromStat(stat.kind);
        },
        else => null,
    };
}

fn kindFromStat(kind: std.Io.File.Kind) ?file_index.CandidateKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        else => null,
    };
}

fn kindMatchesStat(expected: file_index.CandidateKind, actual: std.Io.File.Kind) bool {
    return switch (expected) {
        .file => actual == .file,
        .directory => actual == .directory,
    };
}

fn insertCandidate(
    out: []file_index.SearchResult,
    path_storage: []u8,
    scores: []file_index.NameQuery.Score,
    matcher: *const file_index.NameQuery,
    count: usize,
    path: []const u8,
    kind: file_index.CandidateKind,
    score: file_index.NameQuery.Score,
) usize {
    var insertion_index: usize = 0;
    while (insertion_index < count and !matcher.better(score, path, scores[insertion_index], out[insertion_index].path)) : (insertion_index += 1) {}
    if (insertion_index >= out.len) return count;

    const next_count = @min(count + 1, out.len);
    var index = next_count - 1;
    while (index > insertion_index) : (index -= 1) {
        const previous = out[index - 1];
        scores[index] = scores[index - 1];
        const slot = pathSlot(path_storage, index);
        @memcpy(slot[0..previous.path.len], previous.path);
        out[index] = .{
            .path = slot[0..previous.path.len],
            .kind = previous.kind,
            .matched_spans = &.{},
        };
    }

    const slot = pathSlot(path_storage, insertion_index);
    scores[insertion_index] = score;
    @memcpy(slot[0..path.len], path);
    out[insertion_index] = .{
        .path = slot[0..path.len],
        .kind = kind,
        .matched_spans = &.{},
    };
    return next_count;
}

fn pathSlot(storage: []u8, index: usize) []u8 {
    const slot_len: usize = file_index.max_path_len;
    const start = index * slot_len;
    return storage[start .. start + slot_len];
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    file.close(std.testing.io);
}

test "path completion classifies and splits only path-shaped queries" {
    try std.testing.expectEqual(QueryMode.workspace_index, queryMode("main"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("~"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("~/Dow"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("/tmp/fi"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("./src/"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("../shared/"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("src/core/"));

    const parsed = parseExplicitQuery("../shared/na").?;
    try std.testing.expectEqualStrings("../shared", parsed.parent);
    try std.testing.expectEqualStrings("../shared/", parsed.display_prefix);
    try std.testing.expectEqualStrings("na", parsed.basename_query);
}

test "path completion treats only exact directory shortcuts as roots" {
    inline for (.{ "~", ".", ".." }) |shortcut| {
        try std.testing.expectEqual(QueryMode.explicit_path, queryMode(shortcut));
        const parsed = parseExplicitQuery(shortcut).?;
        const with_slash = parseExplicitQuery(shortcut ++ "/").?;
        try std.testing.expectEqualStrings(shortcut, parsed.parent);
        try std.testing.expectEqualStrings(shortcut ++ "/", parsed.display_prefix);
        try std.testing.expectEqualStrings("", parsed.basename_query);
        try std.testing.expectEqualStrings(with_slash.parent, parsed.parent);
        try std.testing.expectEqualStrings(with_slash.display_prefix, parsed.display_prefix);
        try std.testing.expectEqualStrings(with_slash.basename_query, parsed.basename_query);
    }
    for ([_][]const u8{ "", ".gitignore", "...", "..notes", "~notes", "main", "readme.md" }) |query| {
        try std.testing.expectEqual(QueryMode.workspace_index, queryMode(query));
        try std.testing.expect(parseExplicitQuery(query) == null);
    }
}

test "path completion browses bare current and parent directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/local.txt");
    try writeTestFile(tmp.dir, "parent.txt");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    var results: [4]file_index.SearchResult = undefined;
    var spans: [4]file_index.MatchSpan = undefined;
    var paths: [4 * file_index.max_path_len]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 2), try complete(root, ".", &results, &spans, &paths));
    try std.testing.expectEqualStrings(".", results[0].path);
    try std.testing.expectEqual(file_index.CandidateKind.directory, results[0].kind);
    try std.testing.expectEqualStrings("./local.txt", results[1].path);
    try std.testing.expectEqual(@as(usize, 0), results[1].matched_spans.len);
    try std.testing.expect(isCurrentCandidateKind(root, results[1].path, .file));

    try std.testing.expectEqual(@as(usize, 3), try complete(root, "..", &results, &spans, &paths));
    try std.testing.expectEqualStrings("..", results[0].path);
    try std.testing.expectEqualStrings("../parent.txt", results[1].path);
    try std.testing.expectEqualStrings("../workspace", results[2].path);
    try std.testing.expect(isCurrentCandidateKind(root, results[2].path, .directory));
}

test "path completion enumerates immediate entries with deterministic bounded order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/src/empty");
    try tmp.dir.createDirPath(std.testing.io, "workspace/src/nested/deeper");
    try writeTestFile(tmp.dir, "workspace/src/zeta.txt");
    try writeTestFile(tmp.dir, "workspace/src/Alpha.txt");
    try writeTestFile(tmp.dir, "workspace/src/beta.txt");
    try writeTestFile(tmp.dir, "workspace/src/.hidden.txt");
    try writeTestFile(tmp.dir, "workspace/src/space \" file.txt");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    var results: [4]file_index.SearchResult = undefined;
    var spans: [4]file_index.MatchSpan = undefined;
    var paths: [4 * file_index.max_path_len]u8 = undefined;

    const count = try complete(root, "./src/", &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqualStrings("./src", results[0].path);
    try std.testing.expectEqualStrings("./src/.hidden.txt", results[1].path);
    try std.testing.expectEqualStrings("./src/Alpha.txt", results[2].path);
    try std.testing.expectEqualStrings("./src/beta.txt", results[3].path);

    const filtered_count = try complete(root, "src/al", &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 2), filtered_count);
    try std.testing.expectEqualStrings("src/Alpha.txt", results[0].path);
    try std.testing.expectEqualStrings("src/space \" file.txt", results[1].path);
    try std.testing.expectEqual(file_index.CandidateKind.file, results[0].kind);
    try std.testing.expectEqual(@as(usize, 1), results[0].matched_spans.len);
    try std.testing.expectEqual(@as(u16, "src/".len), results[0].matched_spans[0].byte_start);
    try std.testing.expectEqual(@as(u16, "src/al".len), results[0].matched_spans[0].byte_end);
    try std.testing.expectEqual(@as(usize, 1), try complete(root, "src/space", &results, &spans, &paths));
    try std.testing.expectEqualStrings("src/space \" file.txt", results[0].path);
}

test "path completion resolves parent and absolute forms without recursive traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.createDirPath(std.testing.io, "outside/empty");
    try writeTestFile(tmp.dir, "outside/external.txt");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside");
    defer alloc.free(outside);

    var results: [8]file_index.SearchResult = undefined;
    var spans: [8]file_index.MatchSpan = undefined;
    var paths: [8 * file_index.max_path_len]u8 = undefined;
    const parent_count = try complete(root, "../outside/", &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 3), parent_count);
    try std.testing.expectEqualStrings("../outside", results[0].path);
    try std.testing.expectEqualStrings("../outside/empty", results[1].path);
    try std.testing.expectEqual(file_index.CandidateKind.directory, results[1].kind);
    try std.testing.expectEqualStrings("../outside/external.txt", results[2].path);

    var absolute_query_storage: [file_index.max_path_len]u8 = undefined;
    const absolute_query = try std.fmt.bufPrint(&absolute_query_storage, "{s}/ex", .{outside});
    const absolute_count = try complete(root, absolute_query, &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 1), absolute_count);
    var expected_storage: [file_index.max_path_len]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_storage, "{s}/external.txt", .{outside});
    try std.testing.expectEqualStrings(expected, results[0].path);
}

test "path completion lists a folder first so it can be selected" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/src/main.zig");
    try writeTestFile(tmp.dir, "home/notes.txt");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var results: [4]file_index.SearchResult = undefined;
    var spans: [4]file_index.MatchSpan = undefined;
    var paths: [4 * file_index.max_path_len]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 2), try complete(root, "src/", &results, &spans, &paths));
    try std.testing.expectEqualStrings("src", results[0].path);
    try std.testing.expectEqual(file_index.CandidateKind.directory, results[0].kind);
    try std.testing.expectEqual(@as(usize, 0), results[0].matched_spans.len);
    try std.testing.expectEqualStrings("src/main.zig", results[1].path);
    try std.testing.expect(isCurrentCandidateKind(root, results[0].path, .directory));

    // A partial name lists matching entries only.
    try std.testing.expectEqual(@as(usize, 1), try complete(root, "src/ma", &results, &spans, &paths));
    try std.testing.expectEqualStrings("src/main.zig", results[0].path);

    var cancel: std.atomic.Value(bool) = .init(false);
    try std.testing.expectEqual(@as(usize, 2), try completeCancellable(root, home, "~", &cancel, &results, &spans, &paths));
    try std.testing.expectEqualStrings("~", results[0].path);
    try std.testing.expectEqualStrings("~/notes.txt", results[1].path);

    // With room for one row, the folder itself is kept.
    try std.testing.expectEqual(@as(usize, 1), try complete(root, "src/", results[0..1], &spans, paths[0..file_index.max_path_len]));
    try std.testing.expectEqualStrings("src", results[0].path);
}

test "path completion follows listed symlinks and filters unsafe names" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/target-dir");
    try writeTestFile(tmp.dir, "workspace/target.txt");
    try writeTestFile(tmp.dir, "workspace/unsafe-\x1b.txt");
    try tmp.dir.symLink(std.testing.io, "target-dir", "workspace/linked-dir", .{ .is_directory = true });
    try tmp.dir.symLink(std.testing.io, "target.txt", "workspace/linked-file", .{ .is_directory = false });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var results: [4]file_index.SearchResult = undefined;
    var spans: [4]file_index.MatchSpan = undefined;
    var paths: [4 * file_index.max_path_len]u8 = undefined;
    const count = try complete(root, "./linked", &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(file_index.CandidateKind.directory, results[0].kind);
    try std.testing.expectEqual(file_index.CandidateKind.file, results[1].kind);
    try std.testing.expectEqual(@as(usize, 0), try complete(root, "./unsafe", &results, &spans, &paths));
}

test "path completion reports bounded storage and unavailable parents" {
    var results: [1]file_index.SearchResult = undefined;
    var spans: [1]file_index.MatchSpan = undefined;
    var too_small: [file_index.max_path_len - 1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, complete("/", "./", &results, &spans, &too_small));

    var paths: [file_index.max_path_len]u8 = undefined;
    try std.testing.expectError(error.PathUnavailable, complete("/", "/definitely/missing/fx-path/", &results, &spans, &paths));
}

test "path completion fuzzy names stay within the exact parent and highlight suffixes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "Desktop");
    try writeTestFile(tmp.dir, "unrelated/Desktop.txt");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var results: [4]file_index.SearchResult = undefined;
    var spans: [16]file_index.MatchSpan = undefined;
    var paths: [4 * file_index.max_path_len]u8 = undefined;
    for ([_][]const u8{ "~/ktop", "~/dsktp" }) |query| {
        const count = try completeCancellable(home, home, query, null, &results, &spans, &paths);
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expectEqualStrings("~/Desktop", results[0].path);
        try std.testing.expectEqual(file_index.CandidateKind.directory, results[0].kind);
    }
    _ = try completeCancellable(home, home, "~/ktop", null, &results, &spans, &paths);
    try std.testing.expectEqualSlices(file_index.MatchSpan, &.{.{ .byte_start = 5, .byte_end = 9 }}, results[0].matched_spans);
    _ = try completeCancellable(home, home, "~/dsktp", null, &results, &spans, &paths);
    try std.testing.expectEqualSlices(file_index.MatchSpan, &.{
        .{ .byte_start = 2, .byte_end = 3 },
        .{ .byte_start = 4, .byte_end = 7 },
        .{ .byte_start = 8, .byte_end = 9 },
    }, results[0].matched_spans);
}

test "path completion fuzzy ranking retains the best bounded result and checks span capacity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "Desktop");
    try tmp.dir.createDirPath(std.testing.io, "ktop");
    try tmp.dir.createDirPath(std.testing.io, "OtherDesktop");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var results: [1]file_index.SearchResult = undefined;
    var spans: [4]file_index.MatchSpan = undefined;
    var paths: [file_index.max_path_len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try complete(root, "./ktop", &results, &spans, &paths));
    try std.testing.expectEqualStrings("./ktop", results[0].path);
    try std.testing.expectError(error.NoSpaceLeft, complete(root, "./dsktp", &results, spans[0..1], &paths));
    try std.testing.expectEqual(@as(usize, 1), try complete(root, "./dsktp", &results, &spans, &paths));
    try std.testing.expectEqualStrings("./Desktop", results[0].path);
}

test "path completion validates the current explicit candidate kind" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/folder");
    try writeTestFile(tmp.dir, "workspace/file.txt");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    try std.testing.expect(isCurrentCandidateKind(root, "./folder", .directory));
    try std.testing.expect(!isCurrentCandidateKind(root, "./folder", .file));
    try std.testing.expect(isCurrentCandidateKind(root, "./file.txt", .file));
    try std.testing.expect(!isCurrentCandidateKind(root, "./missing", .file));
}

test "path completion cancellable operation uses captured HOME and literal parent bytes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "dir /chosen.txt");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var results: [2]file_index.SearchResult = undefined;
    var spans: [2]file_index.MatchSpan = undefined;
    var paths: [2 * file_index.max_path_len]u8 = undefined;
    var cancel: std.atomic.Value(bool) = .init(false);
    try std.testing.expectEqual(@as(usize, 1), try completeCancellable("/unused-workspace", root, "~/dir /ch", &cancel, &results, &spans, &paths));
    try std.testing.expectEqualStrings("~/dir /chosen.txt", results[0].path);
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, completeCancellable(root, null, "./missing/", &cancel, &results, &spans, &paths));
}
