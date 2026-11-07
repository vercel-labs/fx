//! Files under a search root for `glob_files` and `grep_files`, listed by the
//! native indexer and current at the time of the call. A search of the
//! workspace or of an ordinary folder in it reuses the saved `@`-completion
//! snapshot when the folders and rule files it depended on are unchanged; a
//! folder search never reuses a snapshot cut at the candidate cap. Any other
//! search scans its root.
//! Nothing here saves a snapshot, so searches outside the workspace leave no
//! trace under `~/.fx/file-index/`.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const file_index = @import("file_index.zig");
const indexer = @import("../indexer/indexer.zig");
const pathing = @import("pathing.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

pub const default_candidate_cap: usize = 100_000;
const max_relative_path_bytes: usize = 2048;
pub const default_skipped_names: []const []const u8 = &indexer.default_skipped_names;

pub const Options = struct {
    candidate_cap: usize = default_candidate_cap,
    /// Folder and file names skipped outside repositories and below an
    /// ignored root. Never applied inside a repository.
    skipped_names: []const []const u8 = default_skipped_names,
    include_hidden: bool = false,
    /// Keep hidden folders inside a repository, where git's rules alone
    /// decide, as `git grep` did. Outside one, `include_hidden` decides.
    include_hidden_in_repository: bool = false,
};

pub const Listing = struct {
    /// Relative to the search root, sorted bytewise. Owned by the arena.
    files: []const []const u8,
    candidate_cap: usize,
    /// The cap or an unreadable folder or rule file left files out.
    incomplete: bool,
    /// The candidate cap stopped the listing.
    cap_reached: bool,
    skipped_overlong: usize,
    skipped_by_name: SkippedByName,
};

/// The entries a listing left out because of their name, which happens
/// outside a git repository and below an ignored root.
pub const SkippedByName = struct {
    count: usize = 0,
    /// Their distinct names, sorted bytewise. Owned by the listing's arena.
    names: []const []const u8 = &.{},
};

pub const Error = Allocator.Error || error{FileNotFound};

/// Lists the files under `absolute_root`. `alloc` must be thread-safe; the
/// result is owned by `arena`.
pub fn list(alloc: Allocator, arena: Allocator, workspace_root: []const u8, absolute_root: []const u8, options: Options) Error!Listing {
    if (relativeInside(workspace_root, absolute_root)) |subtree| {
        if (try listFromSnapshot(alloc, arena, workspace_root, subtree, options)) |listing| return listing;
    }
    var result = indexer.scan(alloc, absolute_root, .{
        .candidate_cap = options.candidate_cap,
        .max_path_bytes = max_relative_path_bytes,
        .skipped_names = options.skipped_names,
    }, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RootUnavailable => return error.FileNotFound,
        error.Canceled => unreachable,
    };
    defer result.deinit();
    debug_trace.logf("core", "tool files scanned entries={d} incomplete={} cap_reached={}", .{ result.tree.entries.len, result.tree.incomplete, result.tree.cap_reached });
    return collect(arena, &result.tree, "", options);
}

/// `absolute_root` relative to `workspace_root`, "" for the root itself, or
/// null when it lies outside.
fn relativeInside(workspace_root: []const u8, absolute_root: []const u8) ?[]const u8 {
    if (workspace_root.len == 0 or !pathing.pathInside(workspace_root, absolute_root)) return null;
    return std.mem.trimStart(u8, absolute_root[workspace_root.len..], "/");
}

/// Whether the workspace tree's entries below `subtree` are exactly what a
/// scan of that folder would list: the walk entered it as an ordinary folder
/// of the workspace, not as a nested repository's boundary and not below an
/// ignored folder, where a direct scan applies the plain rules instead.
fn subtreeFromSnapshot(tree: *const indexer.Tree, subtree: []const u8) bool {
    if (subtree.len == 0) return true;
    for (tree.folders) |folder| {
        if (std.mem.eql(u8, folder.rel, subtree)) return !folder.boundary and !folder.excluded;
    }
    return false;
}

/// Whether the cap lets `tree` answer a search of `subtree`. A tree cut at
/// the cap holds only the sorted prefix with its first files: a folder past
/// the cut lost its files, and another cap would cut elsewhere. Only a search
/// of the whole workspace with the same cap gets that list from a new scan.
fn capAllowsReuse(tree: *const indexer.Tree, subtree: []const u8, candidate_cap: usize) bool {
    var files: usize = 0;
    for (tree.entries) |entry| files += @intFromBool(entry.kind == .file);
    if (files > candidate_cap) return false;
    return !tree.cap_reached or (subtree.len == 0 and files == candidate_cap);
}

fn listFromSnapshot(alloc: Allocator, arena: Allocator, workspace_root: []const u8, subtree: []const u8, options: Options) Allocator.Error!?Listing {
    const roots = [_][]const u8{workspace_root};
    const path = (try file_index.snapshotPath(arena, &roots)) orelse return null;
    var snapshot = (try indexer.loadSnapshot(alloc, path, &roots)) orelse return null;
    defer snapshot.deinit();
    const tree = &snapshot.trees[0];
    if (!capAllowsReuse(tree, subtree, options.candidate_cap)) return null;
    if (!subtreeFromSnapshot(tree, subtree)) return null;
    if (!indexer.isCurrent(tree, workspace_root, options.skipped_names, if (subtree.len == 0) null else subtree)) return null;
    debug_trace.logf("core", "tool files reused snapshot entries={d} subtree_bytes={d}", .{ tree.entries.len, subtree.len });
    return try collect(arena, tree, subtree, options);
}

/// The path of a file entry relative to `subtree`, or null when the entry is
/// not a file or is outside the subtree.
fn subtreePath(entry: indexer.Entry, subtree: []const u8) ?[]const u8 {
    if (entry.kind != .file) return null;
    return belowSubtree(entry.path, subtree);
}

/// `path` relative to `subtree`, or null when it is not below it.
fn belowSubtree(path: []const u8, subtree: []const u8) ?[]const u8 {
    if (subtree.len == 0) return path;
    if (path.len <= subtree.len + 1 or !std.mem.startsWith(u8, path, subtree) or path[subtree.len] != '/') return null;
    return path[subtree.len + 1 ..];
}

/// The entries `tree` skipped by name below `subtree` whose files the listing
/// would otherwise have shown. Unless hidden folders are kept, that leaves out
/// a skip below a hidden folder and a hidden name such as `.next`, whose files
/// the hidden filter drops anyway (`tests/tla/indexer/SkipNote.tla`
/// NoteHonest). Only names in `skipped_names` count, so a snapshot can never
/// put other text in the note.
fn skippedByName(arena: Allocator, tree: *const indexer.Tree, subtree: []const u8, skipped_names: []const []const u8, keep_hidden: bool) Allocator.Error!SkippedByName {
    var count: usize = 0;
    var names: std.ArrayList([]const u8) = .empty;
    for (tree.skipped) |entry| {
        const path = belowSubtree(entry, subtree) orelse continue;
        const name = std.Io.Dir.path.basename(path);
        if (!isSkippedName(skipped_names, name)) continue;
        if (!keep_hidden and (pathContainsHiddenDirectoryComponent(path) or isHiddenName(name))) continue;
        count += 1;
        if (!isSkippedName(names.items, name)) try names.append(arena, try arena.dupe(u8, name));
    }
    sort_utils.sort([]const u8, names.items, {}, nameLessThan);
    return .{ .count = count, .names = names.items };
}

fn isSkippedName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn isHiddenName(name: []const u8) bool {
    return name.len > 1 and name[0] == '.';
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn collect(arena: Allocator, tree: *const indexer.Tree, subtree: []const u8, options: Options) Allocator.Error!Listing {
    const keep_hidden = options.include_hidden or (options.include_hidden_in_repository and tree.repository);
    // Reserve once for every file in the subtree, so the list never grows.
    // Only the cheap checks run here; hidden paths are left out while filling.
    var upper: usize = 0;
    for (tree.entries) |entry| upper += @intFromBool(subtreePath(entry, subtree) != null);
    const files = try arena.alloc([]const u8, upper);
    var count: usize = 0;
    for (tree.entries) |entry| {
        const path = subtreePath(entry, subtree) orelse continue;
        if (!keep_hidden and pathContainsHiddenDirectoryComponent(path)) continue;
        files[count] = try arena.dupe(u8, path);
        count += 1;
    }
    return .{
        // The unused tail belongs to the arena like the rest of the listing.
        .files = files[0..count],
        .candidate_cap = options.candidate_cap,
        .incomplete = tree.incomplete or tree.cap_reached,
        .cap_reached = tree.cap_reached,
        .skipped_overlong = tree.skipped_overlong,
        .skipped_by_name = try skippedByName(arena, tree, subtree, options.skipped_names, keep_hidden),
    };
}

/// What a candidate list may have left out, for the notes a file tool appends.
pub const Completeness = struct {
    /// The cap or an unreadable folder or git file left files out.
    incomplete: bool = false,
    /// The candidate cap stopped the listing.
    cap_reached: bool = false,
    candidate_cap: usize = default_candidate_cap,
    skipped_overlong: usize = 0,
    skipped_by_name: SkippedByName = .{},

    pub fn of(listing: Listing) Completeness {
        return .{
            .incomplete = listing.incomplete,
            .cap_reached = listing.cap_reached,
            .candidate_cap = listing.candidate_cap,
            .skipped_overlong = listing.skipped_overlong,
            .skipped_by_name = listing.skipped_by_name,
        };
    }

    /// Names the reason files may be missing: the cap, folders and git files
    /// fx could not read, overlong paths, or entries skipped by name.
    pub fn writeNotes(self: Completeness, writer: *std.Io.Writer) error{OutOfMemory}!void {
        if (self.cap_reached) {
            writer.print("... candidate list may be incomplete; candidate cap {d} reached before all files were discovered\n", .{self.candidate_cap}) catch return error.OutOfMemory;
        } else if (self.incomplete) {
            writer.writeAll("... candidate list may be incomplete; some folders or git files could not be read\n") catch return error.OutOfMemory;
        }
        if (self.skipped_overlong > 0) {
            writer.print("... skipped {d} overlong candidate path{s}\n", .{ self.skipped_overlong, if (self.skipped_overlong == 1) "" else "s" }) catch return error.OutOfMemory;
        }
        const skipped = self.skipped_by_name;
        if (skipped.count > 0) {
            writer.print("... skipped {d} entr{s} named ", .{ skipped.count, if (skipped.count == 1) "y" else "ies" }) catch return error.OutOfMemory;
            for (skipped.names, 0..) |name, index| {
                writer.print("{s}{s}", .{ if (index == 0) "" else ", ", name }) catch return error.OutOfMemory;
            }
            writer.writeAll(" outside a git repository; pass path to search one\n") catch return error.OutOfMemory;
        }
    }
};

/// Whether a folder in `path` (not its last component) is hidden.
pub fn pathContainsHiddenDirectoryComponent(path: []const u8) bool {
    var rest = path;
    while (std.mem.findScalar(u8, rest, '/')) |slash| {
        const component = rest[0..slash];
        if (component.len > 1 and component[0] == '.') return true;
        rest = rest[slash + 1 ..];
    }
    return false;
}

test "hidden directory components exclude descendants but not hidden files" {
    try std.testing.expect(pathContainsHiddenDirectoryComponent(".github/workflows/ci.yml"));
    try std.testing.expect(pathContainsHiddenDirectoryComponent("src/.cache/item"));
    try std.testing.expect(!pathContainsHiddenDirectoryComponent(".gitignore"));
    try std.testing.expect(!pathContainsHiddenDirectoryComponent("src/.env"));
    try std.testing.expect(!pathContainsHiddenDirectoryComponent("./src/main.zig"));
}

test "listing sees a file created a moment earlier and honors hidden and custom names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    for ([_][]const u8{ "root/a.txt", "root/.hidden/h.txt", "root/build/out.o", "root/vendor/v.txt", "root/sub/s.txt" }) |sub_path| {
        try tmp.dir.createDirPath(io, std.Io.Dir.path.dirname(sub_path).?);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "x" });
    }
    const root = try @import("../shared/io.zig").dirRealpathAlloc(arena, tmp.dir, "root");

    // The temporary folder sits below an ignored path, so the skipped names
    // apply; `build` is skipped by default.
    const first = try list(std.testing.allocator, arena, root, root, .{});
    try std.testing.expectEqual(@as(usize, 3), first.files.len);
    try std.testing.expectEqualStrings("a.txt", first.files[0]);
    try std.testing.expectEqualStrings("sub/s.txt", first.files[1]);
    try std.testing.expectEqualStrings("vendor/v.txt", first.files[2]);

    try tmp.dir.writeFile(io, .{ .sub_path = "root/sub/new.txt", .data = "x" });
    const custom = try list(std.testing.allocator, arena, root, root, .{ .skipped_names = &.{"vendor"}, .include_hidden = true });
    const want = [_][]const u8{ ".hidden/h.txt", "a.txt", "build/out.o", "sub/new.txt", "sub/s.txt" };
    try std.testing.expectEqual(want.len, custom.files.len);
    for (want, custom.files) |expected, actual| try std.testing.expectEqualStrings(expected, actual);

    const sub = try list(std.testing.allocator, arena, root, try std.Io.Dir.path.join(arena, &.{ root, "sub" }), .{});
    try std.testing.expectEqual(@as(usize, 2), sub.files.len);
    try std.testing.expectEqualStrings("new.txt", sub.files[0]);

    try std.testing.expectError(error.FileNotFound, list(std.testing.allocator, arena, root, try std.Io.Dir.path.join(arena, &.{ root, "missing" }), .{}));
}

fn testNotes(arena: Allocator, listing: Listing) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try Completeness.of(listing).writeNotes(&out.writer);
    return out.written();
}

test "a listing outside a repository notes the entries it skipped by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    // `tools/build` is a file: the names skip files too.
    for ([_][]const u8{ "root/src/app.py", "root/build/config.py", "root/build/dist/deep.py", "root/dist/old.py", "root/app/build/gen.py", "root/tools/build", "root/.next/cache.js", "root/.cache/coverage/c.js" }) |sub_path| {
        try tmp.dir.createDirPath(io, std.Io.Dir.path.dirname(sub_path).?);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "x" });
    }
    const root = try @import("../shared/io.zig").dirRealpathAlloc(arena, tmp.dir, "root");

    // The temporary folder sits below an ignored path, so the skipped names
    // apply as they do outside a repository. `build/dist` is inside a skipped
    // folder and was never read. `.next` and `.cache/coverage` are left out
    // with the hidden folders.
    const whole = try list(std.testing.allocator, arena, root, root, .{});
    try std.testing.expectEqualStrings("... skipped 4 entries named build, dist outside a git repository; pass path to search one\n", try testNotes(arena, whole));

    const hidden = try list(std.testing.allocator, arena, root, root, .{ .include_hidden = true });
    try std.testing.expectEqualStrings("... skipped 6 entries named .next, build, coverage, dist outside a git repository; pass path to search one\n", try testNotes(arena, hidden));

    const app = try list(std.testing.allocator, arena, root, try std.Io.Dir.path.join(arena, &.{ root, "app" }), .{});
    try std.testing.expectEqual(@as(usize, 0), app.files.len);
    try std.testing.expectEqualStrings("... skipped 1 entry named build outside a git repository; pass path to search one\n", try testNotes(arena, app));

    // Passing the skipped folder as the path searches it.
    const build = try list(std.testing.allocator, arena, root, try std.Io.Dir.path.join(arena, &.{ root, "build" }), .{});
    try std.testing.expectEqual(@as(usize, 1), build.files.len);
    try std.testing.expectEqualStrings("config.py", build.files[0]);
    try std.testing.expectEqualStrings("... skipped 1 entry named dist outside a git repository; pass path to search one\n", try testNotes(arena, build));

    const src = try list(std.testing.allocator, arena, root, try std.Io.Dir.path.join(arena, &.{ root, "src" }), .{});
    try std.testing.expectEqualStrings("", try testNotes(arena, src));

    const none = try list(std.testing.allocator, arena, root, root, .{ .skipped_names = &.{} });
    try std.testing.expectEqualStrings("", try testNotes(arena, none));
}

test "a reused tree reports only the skipped entries below the searched folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]indexer.Entry{
        .{ .path = "app", .kind = .directory },
        .{ .path = "app/main.py", .kind = .file },
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/a.py", .kind = .file },
    };
    // As a snapshot holds them: sorted, and one name no option skips, which
    // must never reach the note.
    const skipped = [_][]const u8{ ".cache/dist", "app/.next", "app/build", "build", "odd\nname", "web/node_modules" };
    const names = [_][]const u8{ ".next", "build", "dist", "node_modules" };
    const tree: indexer.Tree = .{ .root = "/w", .root_inode = 1, .scan_started_ns = 0, .repository = false, .incomplete = false, .cap_reached = false, .skipped_overlong = 0, .skipped_names = &names, .skipped = &skipped, .entries = &entries, .folders = &.{}, .sources = &.{} };

    const whole = try collect(arena, &tree, "", .{ .skipped_names = &names });
    try std.testing.expectEqualStrings("... skipped 3 entries named build, node_modules outside a git repository; pass path to search one\n", try testNotes(arena, whole));
    const app = try collect(arena, &tree, "app", .{ .skipped_names = &names });
    try std.testing.expectEqualStrings("... skipped 1 entry named build outside a git repository; pass path to search one\n", try testNotes(arena, app));
    const app_hidden = try collect(arena, &tree, "app", .{ .skipped_names = &names, .include_hidden = true });
    try std.testing.expectEqualStrings("... skipped 2 entries named .next, build outside a git repository; pass path to search one\n", try testNotes(arena, app_hidden));
    const src = try collect(arena, &tree, "src", .{ .skipped_names = &names });
    try std.testing.expectEqualStrings("", try testNotes(arena, src));
}

test "a saved file-index snapshot loads or is refused on fuzzed bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../shared/io.zig").dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(dir);
    try std.testing.fuzz(SnapshotFuzz{ .dir = dir }, fuzzSnapshot, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "build",
            "app/build\x00web/node_modules\x00.next",
            "odd\nname\x00/\x00dist/",
            "\xff\xfe\x01",
            "",
        }) ++ @import("fuzz_corpus").file_index_snapshot.*),
    });
}

const SnapshotFuzz = struct { dir: []const u8 };

/// Saves a tree whose skipped entries come from the input and loads it back,
/// then writes more input over the saved payload under a digest that matches
/// it and loads again. Whatever loads must collect without failing, and its
/// note may name only the skipped names the listing was given.
fn fuzzSnapshot(context: SnapshotFuzz, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    const io_mod = @import("../shared/io.zig");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [512]u8 = undefined;
    const bytes = buffer[0..smith.slice(&buffer)];
    var skipped: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, bytes, 0);
    while (parts.next()) |part| if (part.len > 0) try skipped.append(arena, part);
    const roots = [_][]const u8{"/w"};
    const entries = [_]indexer.Entry{.{ .path = "a.txt", .kind = .file }};
    const tree: indexer.Tree = .{ .root = roots[0], .root_inode = 1, .scan_started_ns = 0, .repository = false, .incomplete = false, .cap_reached = false, .skipped_overlong = 0, .skipped_names = default_skipped_names, .skipped = skipped.items, .entries = &entries, .folders = &.{}, .sources = &.{} };
    const path = try std.Io.Dir.path.join(arena, &.{ context.dir, "fuzz.idx" });
    try indexer.saveSnapshot(arena, path, &.{tree});
    {
        var loaded = (try indexer.loadSnapshot(alloc, path, &roots)) orelse return error.TestUnexpectedResult;
        defer loaded.deinit();
        try std.testing.expectEqual(skipped.items.len, loaded.trees[0].skipped.len);
        for (skipped.items, loaded.trees[0].skipped) |want, have| try std.testing.expectEqualStrings(want, have);
        try expectConfiguredNote(arena, &loaded.trees[0]);
    }

    // The file is the format's first line, a SHA-256 of the payload, and the
    // payload (src/core/indexer/snapshot.zig).
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    const saved = io_mod.readFileToEnd(arena, &file, 1024 * 1024) catch |err| {
        file.close(io_mod.getIo());
        return err;
    };
    file.close(io_mod.getIo());
    const digest_at = (std.mem.findScalar(u8, saved, '\n') orelse return error.TestUnexpectedResult) + 1;
    const payload_at = digest_at + std.crypto.hash.sha2.Sha256.digest_length;
    var noise: [64]u8 = undefined;
    const noise_bytes = noise[0..smith.slice(&noise)];
    if (payload_at < saved.len) {
        const at = payload_at + smith.index(saved.len - payload_at);
        for (noise_bytes, at..) |byte, index| {
            if (index >= saved.len) break;
            saved[index] = byte;
        }
    }
    std.crypto.hash.sha2.Sha256.hash(saved[payload_at..], saved[digest_at..payload_at][0..std.crypto.hash.sha2.Sha256.digest_length], .{});
    try std.Io.Dir.cwd().writeFile(io_mod.getIo(), .{ .sub_path = path, .data = saved, .flags = .{ .permissions = .fromMode(0o600) } });
    var garbled = (try indexer.loadSnapshot(alloc, path, &roots)) orelse return;
    defer garbled.deinit();
    for (garbled.trees) |*loaded_tree| try expectConfiguredNote(arena, loaded_tree);
}

fn expectConfiguredNote(arena: Allocator, tree: *const indexer.Tree) !void {
    for ([_]bool{ false, true }) |include_hidden| {
        const listing = try collect(arena, tree, "", .{ .include_hidden = include_hidden });
        const skipped = listing.skipped_by_name;
        try std.testing.expect(skipped.count <= tree.skipped.len);
        try std.testing.expect(skipped.names.len <= skipped.count);
        for (skipped.names) |name| try std.testing.expect(isSkippedName(default_skipped_names, name));
    }
}

test "subfolder searches reuse the workspace tree only for ordinary folders" {
    const folders = [_]indexer.FolderStamp{
        .{ .rel = "", .inode = 1, .mtime_ns = 0, .ctime_ns = 0, .reusable = true },
        .{ .rel = "src", .inode = 2, .mtime_ns = 0, .ctime_ns = 0, .reusable = true },
        .{ .rel = "inner", .inode = 3, .mtime_ns = 0, .ctime_ns = 0, .reusable = true, .boundary = true },
        .{ .rel = "build", .inode = 4, .mtime_ns = 0, .ctime_ns = 0, .reusable = true, .excluded = true },
    };
    const tree: indexer.Tree = .{ .root = "/w", .root_inode = 1, .scan_started_ns = 0, .repository = true, .incomplete = false, .cap_reached = false, .skipped_overlong = 0, .skipped_names = &.{}, .entries = &.{}, .folders = &folders, .sources = &.{} };
    try std.testing.expect(subtreeFromSnapshot(&tree, ""));
    try std.testing.expect(subtreeFromSnapshot(&tree, "src"));
    try std.testing.expect(!subtreeFromSnapshot(&tree, "inner"));
    try std.testing.expect(!subtreeFromSnapshot(&tree, "build"));
    try std.testing.expect(!subtreeFromSnapshot(&tree, "vendor"));
    try std.testing.expectEqualStrings("src/core", relativeInside("/w", "/w/src/core").?);
    try std.testing.expectEqualStrings("", relativeInside("/w", "/w").?);
    try std.testing.expect(relativeInside("/w", "/workspace") == null);
    try std.testing.expect(relativeInside("/w", "/other") == null);
}

test "a tree cut at the cap answers only a whole-workspace search with the same cap" {
    const entries = [_]indexer.Entry{
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/a.zig", .kind = .file },
        .{ .path = "src/b.zig", .kind = .file },
        .{ .path = "tools", .kind = .directory },
    };
    var tree: indexer.Tree = .{ .root = "/w", .root_inode = 1, .scan_started_ns = 0, .repository = true, .incomplete = false, .cap_reached = false, .skipped_overlong = 0, .skipped_names = &.{}, .entries = &entries, .folders = &.{}, .sources = &.{} };
    // Folder rows do not count: two files fit a cap of two.
    try std.testing.expect(capAllowsReuse(&tree, "", 2));
    try std.testing.expect(capAllowsReuse(&tree, "src", 2));
    try std.testing.expect(!capAllowsReuse(&tree, "", 1));

    tree.cap_reached = true;
    try std.testing.expect(capAllowsReuse(&tree, "", 2));
    try std.testing.expect(!capAllowsReuse(&tree, "", 3));
    try std.testing.expect(!capAllowsReuse(&tree, "src", 2));
    try std.testing.expect(!capAllowsReuse(&tree, "tools", 2));
}
