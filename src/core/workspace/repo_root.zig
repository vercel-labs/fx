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
