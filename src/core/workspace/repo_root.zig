//! Finds the Git worktree that holds a folder by reading names and small
//! metadata files only. It never runs git and never follows a symlinked
//! `.git`, so a repository's configuration cannot make it run a program and
//! a planted link cannot point it elsewhere.
//!
//! The nearest folder at or above the start whose `.git` entry exists is the
//! worktree root. That entry must be a directory or a regular file holding a
//! `gitdir:` line. Any other entry, such as a symlink, a FIFO, an unreadable
//! or oversized file, or a file without `gitdir:`, ends the walk with no
//! repository instead of looking further up.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

/// A `.git` file larger than this is not a gitdir file.
pub const max_metadata_bytes: usize = 4096;

pub const Found = struct {
    /// The worktree root: the start folder or one of its ancestors, as a
    /// slice of the start path.
    root: []const u8,
    /// The repository's git directory: `<root>/.git`, or the folder a
    /// `.git` file names, resolved against `root` when relative. Owned by
    /// the allocator passed to `find`.
    git_dir: []u8,
};

const Resolution = union(enum) {
    missing,
    invalid,
    found: []u8,
};

/// The worktree holding `start`, which need not exist yet: a folder a
/// mutation is about to create counts as its nearest existing ancestor's.
/// Null outside a repository or at an invalid `.git` entry.
pub fn find(alloc: std.mem.Allocator, start: []const u8) error{OutOfMemory}!?Found {
    var candidate = start;
    while (true) {
        switch (try resolveAt(alloc, candidate)) {
            .found => |git_dir| return .{ .root = candidate, .git_dir = git_dir },
            .invalid => return null,
            .missing => {},
        }
        const parent = std.Io.Dir.path.dirname(candidate) orelse return null;
        if (std.mem.eql(u8, parent, candidate)) return null;
        candidate = parent;
    }
}

/// The main repository's worktree root when `found` is a linked worktree that
/// the repository registered, else null. Caller owns the returned path.
pub fn registeredMainRoot(alloc: std.mem.Allocator, found: Found) error{OutOfMemory}!?[]u8 {
    const dot_git = try std.Io.Dir.path.join(alloc, &.{ found.root, ".git" });
    defer alloc.free(dot_git);
    if (std.mem.eql(u8, found.git_dir, dot_git)) return null;

    const common_dir = try readPathFile(alloc, found.git_dir, "commondir") orelse return null;
    defer alloc.free(common_dir);
    if (!std.mem.eql(u8, std.Io.Dir.path.basename(common_dir), ".git")) return null;

    // The worktree folder must sit in the repository's worktree list, and git's back-link in it must name this folder.
    const in_list = try isInWorktreeList(alloc, found.git_dir, common_dir);
    if (!in_list) return null;

    const back_link = try readPathFile(alloc, found.git_dir, "gitdir") orelse return null;
    defer alloc.free(back_link);
    const registered = try isRegisteredBackLink(alloc, back_link, dot_git);
    if (!registered) return null;

    return mainRootOf(alloc, common_dir);
}

fn readPathFile(alloc: std.mem.Allocator, git_dir: []const u8, file_name: []const u8) error{OutOfMemory}!?[]u8 {
    const file_path = try std.Io.Dir.path.join(alloc, &.{ git_dir, file_name });
    defer alloc.free(file_path);
    const content = try readMetadataFile(alloc, file_path) orelse return null;
    defer alloc.free(content);
    const text = std.mem.trim(u8, content, " \t\r\n");
    if (text.len == 0) return null;
    if (std.Io.Dir.path.isAbsolute(text)) return try alloc.dupe(u8, text);
    return try std.Io.Dir.path.resolveAlloc(alloc, &.{ git_dir, text });
}

fn isInWorktreeList(alloc: std.mem.Allocator, git_dir: []const u8, common_dir: []const u8) error{OutOfMemory}!bool {
    const parent = std.Io.Dir.path.dirname(git_dir) orelse return false;
    const list_dir = try std.Io.Dir.path.join(alloc, &.{ common_dir, "worktrees" });
    defer alloc.free(list_dir);
    const real_parent = (try realpathOrNull(alloc, parent)) orelse return false;
    defer alloc.free(real_parent);
    const real_list = (try realpathOrNull(alloc, list_dir)) orelse return false;
    defer alloc.free(real_list);
    return std.mem.eql(u8, real_parent, real_list);
}

fn isRegisteredBackLink(alloc: std.mem.Allocator, back_link: []const u8, dot_git: []const u8) error{OutOfMemory}!bool {
    const registered = (try realpathOrNull(alloc, back_link)) orelse return false;
    defer alloc.free(registered);
    const actual = (try realpathOrNull(alloc, dot_git)) orelse return false;
    defer alloc.free(actual);
    return std.mem.eql(u8, registered, actual);
}

fn mainRootOf(alloc: std.mem.Allocator, common_dir: []const u8) error{OutOfMemory}!?[]u8 {
    const parent = std.Io.Dir.path.dirname(common_dir) orelse return null;
    const main_root = (try realpathOrNull(alloc, parent)) orelse return null;
    errdefer alloc.free(main_root);
    const has_git_dir = try hasGitDirectory(alloc, main_root);
    if (!has_git_dir) {
        alloc.free(main_root);
        return null;
    }
    return main_root;
}

fn hasGitDirectory(alloc: std.mem.Allocator, root: []const u8) error{OutOfMemory}!bool {
    const dot_git = try std.Io.Dir.path.join(alloc, &.{ root, ".git" });
    defer alloc.free(dot_git);
    const stat = std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        dot_git,
        .{ .follow_symlinks = false },
    ) catch return false;
    return stat.kind == .directory;
}

fn realpathOrNull(alloc: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]u8 {
    return io_mod.realpathAlloc(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn resolveAt(alloc: std.mem.Allocator, candidate: []const u8) error{OutOfMemory}!Resolution {
    const dot_git = try std.Io.Dir.path.join(alloc, &.{ candidate, ".git" });
    defer alloc.free(dot_git);
    const stat = std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        dot_git,
        .{ .follow_symlinks = false },
    ) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => .invalid,
    };
    if (stat.kind == .directory) return .{ .found = try alloc.dupe(u8, dot_git) };
    if (stat.kind != .file or stat.size > max_metadata_bytes) return .invalid;

    const content = try readMetadataFile(alloc, dot_git) orelse return .invalid;
    defer alloc.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return .invalid;
    const raw = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (raw.len == 0) return .invalid;
    return .{ .found = if (std.Io.Dir.path.isAbsolute(raw))
        try alloc.dupe(u8, raw)
    else
        try std.Io.Dir.path.resolveAlloc(alloc, &.{ candidate, raw }) };
}

fn readMetadataFile(alloc: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]u8 {
    var file = io_mod.openExistingReadOnlyRegularFile(
        std.Io.Dir.cwd(),
        path,
        .no_follow,
    ) catch return null;
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_metadata_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

fn expectRoot(base: []const u8, sub: []const u8, want: ?[]const u8) !void {
    const alloc = std.testing.allocator;
    const start = try std.Io.Dir.path.join(alloc, &.{ base, sub });
    defer alloc.free(start);
    const found = try find(alloc, start);
    defer if (found) |value| alloc.free(value.git_dir);
    if (want) |rel| {
        const expected = try std.Io.Dir.path.join(alloc, &.{ base, rel });
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, found.?.root);
    } else {
        // The temporary folder may itself sit inside a repository; only a
        // root inside it would be wrong.
        if (found) |value| try std.testing.expect(!std.mem.startsWith(u8, value.root, base));
    }
}

test "the nearest folder with a .git directory or gitdir file is the worktree root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.createDirPath(std.testing.io, "repo/nested/.git");
    try tmp.dir.createDirPath(std.testing.io, "plain");
    try tmp.dir.createDirPath(std.testing.io, "linked/src");
    try writeTestFile(tmp.dir, "linked/.git", "gitdir: ../repo/.git\n");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);

    try expectRoot(base, "repo", "repo");
    try expectRoot(base, "repo/src", "repo");
    // A folder a mutation is about to create counts as its parent's.
    try expectRoot(base, "repo/src/new/deeper", "repo");
    try expectRoot(base, "repo/nested/x", "repo/nested");
    try expectRoot(base, "plain", null);
    try expectRoot(base, "linked/src", "linked");

    const start = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "linked/src" });
    defer std.testing.allocator.free(start);
    const found = (try find(std.testing.allocator, start)).?;
    defer std.testing.allocator.free(found.git_dir);
    const expected = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo/.git" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, found.git_dir);
}

test "a symlinked, malformed, or oversized .git ends the walk with no repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "outer/.git");
    try tmp.dir.createDirPath(std.testing.io, "outer/link/src");
    try tmp.dir.symLink(std.testing.io, "../.git", "outer/link/.git", .{ .is_directory = true });
    try tmp.dir.createDirPath(std.testing.io, "outer/junk/src");
    try writeTestFile(tmp.dir, "outer/junk/.git", "not a gitdir line\n");
    try tmp.dir.createDirPath(std.testing.io, "outer/huge/src");
    const huge = try std.testing.allocator.alloc(u8, max_metadata_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    try writeTestFile(tmp.dir, "outer/huge/.git", huge);
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);

    // Each invalid entry stops the walk rather than reaching `outer`.
    try expectRoot(base, "outer/link/src", null);
    try expectRoot(base, "outer/junk/src", null);
    try expectRoot(base, "outer/huge/src", null);
    try expectRoot(base, "outer", "outer");
}

fn expectMainRoot(base: []const u8, sub: []const u8, want: ?[]const u8) !void {
    const alloc = std.testing.allocator;
    const start = try std.Io.Dir.path.join(alloc, &.{ base, sub });
    defer alloc.free(start);
    const found = (try find(alloc, start)).?;
    defer alloc.free(found.git_dir);
    const main_root = try registeredMainRoot(alloc, found);
    defer if (main_root) |value| alloc.free(value);
    if (want) |rel| {
        const expected = try std.Io.Dir.path.join(alloc, &.{ base, rel });
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, main_root.?);
    } else {
        try std.testing.expect(main_root == null);
    }
}

test "a registered linked worktree resolves to its main repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "main/.git/HEAD", "ref: refs/heads/main\n");
    try writeTestFile(tmp.dir, "main/.git/worktrees/wt/commondir", "../..\n");
    try tmp.dir.createDirPath(std.testing.io, "wt/src");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);

    const back_link = try std.testing.allocator.print("{s}/wt/.git\n", .{base});
    defer std.testing.allocator.free(back_link);
    try writeTestFile(tmp.dir, "main/.git/worktrees/wt/gitdir", back_link);
    const link = try std.testing.allocator.print("gitdir: {s}/main/.git/worktrees/wt\n", .{base});
    defer std.testing.allocator.free(link);
    try writeTestFile(tmp.dir, "wt/.git", link);

    try expectMainRoot(base, "wt/src", "main");
}

test "a worktree link the repository never registered keeps no main root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "main/.git/HEAD", "ref: refs/heads/main\n");
    try writeTestFile(tmp.dir, "other/.git", "gitdir: ../main/.git\n");
    try writeTestFile(tmp.dir, "main/.git/worktrees/wt/commondir", "../..\n");
    try tmp.dir.createDirPath(std.testing.io, "wt/src");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);

    const other_link = try std.testing.allocator.print("{s}/other/.git\n", .{base});
    defer std.testing.allocator.free(other_link);
    try writeTestFile(tmp.dir, "main/.git/worktrees/wt/gitdir", other_link);
    const link = try std.testing.allocator.print("gitdir: {s}/main/.git/worktrees/wt\n", .{base});
    defer std.testing.allocator.free(link);
    try writeTestFile(tmp.dir, "wt/.git", link);
    try expectMainRoot(base, "wt/src", null);

    try writeTestFile(tmp.dir, "main/.git/worktrees/wt2/commondir", "../..\n");
    const link2 = try std.testing.allocator.print("gitdir: {s}/main/.git/worktrees/wt2\n", .{base});
    defer std.testing.allocator.free(link2);
    try writeTestFile(tmp.dir, "wt2/.git", link2);
    try expectMainRoot(base, "wt2", null);
}

test "a worktree link outside the repository's worktree list keeps no main root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "main/.git/HEAD", "ref: refs/heads/main\n");
    try tmp.dir.createDirPath(std.testing.io, "main/.git/worktrees/real");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);

    const commondir = try std.testing.allocator.print("{s}/main/.git\n", .{base});
    defer std.testing.allocator.free(commondir);
    try writeTestFile(tmp.dir, "evil/fake/commondir", commondir);
    const back_link = try std.testing.allocator.print("{s}/evil/.git\n", .{base});
    defer std.testing.allocator.free(back_link);
    try writeTestFile(tmp.dir, "evil/fake/gitdir", back_link);
    const link = try std.testing.allocator.print("gitdir: {s}/evil/fake\n", .{base});
    defer std.testing.allocator.free(link);
    try writeTestFile(tmp.dir, "evil/.git", link);

    try expectMainRoot(base, "evil", null);
}

test "a plain repository and a submodule have no main root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "plain/.git");
    try writeTestFile(tmp.dir, "super/.git/modules/sub/HEAD", "ref: refs/heads/main\n");
    try tmp.dir.createDirPath(std.testing.io, "sub");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);

    const link = try std.testing.allocator.print("gitdir: {s}/super/.git/modules/sub\n", .{base});
    defer std.testing.allocator.free(link);
    try writeTestFile(tmp.dir, "sub/.git", link);

    try expectMainRoot(base, "plain", null);
    try expectMainRoot(base, "sub", null);
}

const max_fuzzed_file_bytes: usize = 8 * 1024;

// fuzz_seed.slices encodes one input per string, so a seed pair is the
// encoding of each file's bytes in a row.
fn linkPairSeed(comptime commondir: []const u8, comptime gitdir: []const u8) []const u8 {
    const seed = @import("fuzz_seed");
    return comptime seed.slices(.{commondir})[0] ++ seed.slices(.{gitdir})[0];
}

const worktree_link_seeds = [_][]const u8{
    linkPairSeed("../..\n", "../../../../wt/.git\n"),
    linkPairSeed("", ""),
    linkPairSeed(text_utils.repeat("\x00", 64), text_utils.repeat("\x00", 64)),
    linkPairSeed("\n\n../..", "../../../../wt/.git\n"),
    linkPairSeed(text_utils.repeat("../", 2000), text_utils.repeat("../", 2000)),
};

test "a worktree link's commondir and gitdir files never break the main root lookup on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzWorktreeLinkFiles, .{
        .corpus = &(worktree_link_seeds ++ @import("fuzz_corpus").worktree_links.*),
    });
}

fn fuzzWorktreeLinkFiles(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "main/.git/HEAD", "ref: refs/heads/main\n");
    try tmp.dir.createDirPath(std.testing.io, "main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io, "wt");
    const base = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(base);

    const link = try alloc.print("gitdir: {s}/main/.git/worktrees/wt\n", .{base});
    defer alloc.free(link);
    try writeTestFile(tmp.dir, "wt/.git", link);

    var commondir_buffer: [max_fuzzed_file_bytes]u8 = undefined;
    const commondir = commondir_buffer[0..@intCast(smith.slice(&commondir_buffer))];
    try writeTestFile(tmp.dir, "main/.git/worktrees/wt/commondir", commondir);
    var gitdir_buffer: [max_fuzzed_file_bytes]u8 = undefined;
    const gitdir = gitdir_buffer[0..@intCast(smith.slice(&gitdir_buffer))];
    try writeTestFile(tmp.dir, "main/.git/worktrees/wt/gitdir", gitdir);

    const start = try std.Io.Dir.path.join(alloc, &.{ base, "wt" });
    defer alloc.free(start);
    const found = (try find(alloc, start)).?;
    defer alloc.free(found.git_dir);
    const main_root = try registeredMainRoot(alloc, found);
    defer if (main_root) |value| alloc.free(value);

    // In this layout the only folder that can be a registered main root is base/main.
    if (main_root) |value| {
        const expected = try std.Io.Dir.path.join(alloc, &.{ base, "main" });
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, value);
    }
}
