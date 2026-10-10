const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const max_branch_bytes: usize = 255;
const max_metadata_bytes: usize = 4096;

const GitDirResolution = union(enum) {
    missing,
    invalid,
    found: []u8,
};

/// Returns an allocator-owned branch name when `cwd` is inside a Git worktree.
/// Missing, detached, malformed, or unreadable metadata is absent.
pub fn read(
    alloc: std.mem.Allocator,
    cwd: []const u8,
) error{OutOfMemory}!?[]u8 {
    if (!std.Io.Dir.path.isAbsolute(cwd)) return null;
    const git_dir = try resolveGitDir(alloc, cwd);
    defer if (git_dir) |path| alloc.free(path);
    const path = git_dir orelse return null;

    var dir = io_mod.openDirAbsoluteNoFollow(path, .{}) catch return null;
    defer dir.close(io_mod.getIo());
    var head_file = io_mod.openExistingReadOnlyRegularFile(
        dir,
        "HEAD",
        .no_follow,
    ) catch return null;
    defer head_file.close(io_mod.getIo());
    const stat = head_file.stat(io_mod.getIo()) catch return null;
    if (stat.size > max_metadata_bytes) return null;
    const head = io_mod.readFileToEnd(
        alloc,
        &head_file,
        max_metadata_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(head);
    const branch = parseHead(head) orelse return null;
    return try alloc.dupe(u8, branch);
}

fn parseHead(head: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const branch = trimmed[prefix.len..];
    if (branch.len == 0 or branch.len > max_branch_bytes or
        !text_utils.isTerminalSafe(branch))
    {
        return null;
    }
    return branch;
}

fn resolveGitDir(
    alloc: std.mem.Allocator,
    cwd: []const u8,
) error{OutOfMemory}!?[]u8 {
    var candidate = cwd;
    while (true) {
        switch (try resolveGitDirAt(alloc, candidate)) {
            .found => |path| return path,
            .invalid => return null,
            .missing => {},
        }
        const parent = std.Io.Dir.path.dirname(candidate) orelse return null;
        if (std.mem.eql(u8, parent, candidate)) return null;
        candidate = parent;
    }
}

fn resolveGitDirAt(
    alloc: std.mem.Allocator,
    candidate: []const u8,
) error{OutOfMemory}!GitDirResolution {
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
    if (stat.kind == .directory) {
        var dir = io_mod.openDirAbsoluteNoFollow(dot_git, .{}) catch return .invalid;
        dir.close(io_mod.getIo());
        return .{ .found = try alloc.dupe(u8, dot_git) };
    }
    if (stat.kind != .file or stat.size > max_metadata_bytes) return .invalid;

    const content = try readMetadataFile(alloc, dot_git) orelse return .invalid;
    defer alloc.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return .invalid;
    const raw = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (raw.len == 0) return .invalid;
    const git_dir = if (std.Io.Dir.path.isAbsolute(raw))
        try alloc.dupe(u8, raw)
    else
        try std.Io.Dir.path.resolveAlloc(alloc, &.{ candidate, raw });
    var dir = io_mod.openDirAbsoluteNoFollow(git_dir, .{}) catch {
        alloc.free(git_dir);
        return .invalid;
    };
    dir.close(io_mod.getIo());
    return .{ .found = git_dir };
}

fn readMetadataFile(
    alloc: std.mem.Allocator,
    path: []const u8,
) error{OutOfMemory}!?[]u8 {
    var file = io_mod.openExistingReadOnlyRegularFile(
        std.Io.Dir.cwd(),
        path,
        .no_follow,
    ) catch return null;
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(
        alloc,
        &file,
        max_metadata_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn writeTestFile(
    dir: std.Io.Dir,
    path: []const u8,
    content: []const u8,
) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| {
        try dir.createDirPath(std.testing.io, parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

test "current branch parses only bounded local branch refs" {
    try std.testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n").?);
    try std.testing.expectEqualStrings(
        "feature/media-ui",
        parseHead("ref: refs/heads/feature/media-ui\n").?,
    );
    try std.testing.expect(parseHead("0123456789abcdef0123456789abcdef01234567\n") == null);
    try std.testing.expect(parseHead("ref: refs/tags/v1\n") == null);
    try std.testing.expect(parseHead("ref: refs/heads/bad\x1b[31m\n") == null);
    try std.testing.expect(parseHead("ref: refs/heads/" ++ text_utils.repeat("x", 256) ++ "\n") == null);
}

test "current branch reads nested worktree head without spawning Git" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "repo/.git/HEAD", "ref: refs/heads/feature/media-ui\n");
    try tmp.dir.createDirPath(std.testing.io, "repo/src/nested");
    const cwd = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo/src/nested");
    defer alloc.free(cwd);

    const branch = (try read(alloc, cwd)) orelse return error.TestExpectedEqual;
    defer alloc.free(branch);
    try std.testing.expectEqualStrings("feature/media-ui", branch);
}

test "current branch follows a linked worktree gitdir file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(
        tmp.dir,
        "workspace/.git",
        "gitdir: ../git-data/worktrees/workspace\n",
    );
    try writeTestFile(
        tmp.dir,
        "git-data/worktrees/workspace/HEAD",
        "ref: refs/heads/worktree-branch\n",
    );
    const cwd = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(cwd);

    const branch = (try read(alloc, cwd)) orelse return error.TestExpectedEqual;
    defer alloc.free(branch);
    try std.testing.expectEqualStrings("worktree-branch", branch);
}

test "current branch rejects missing detached malformed oversized and symlinked metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    const cwd = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(cwd);

    try std.testing.expect(try read(alloc, cwd) == null);
    try writeTestFile(tmp.dir, "repo/.git/HEAD", "0123456789abcdef\n");
    try std.testing.expect(try read(alloc, cwd) == null);
    try writeTestFile(tmp.dir, "repo/.git/HEAD", "ref: refs/tags/v1\n");
    try std.testing.expect(try read(alloc, cwd) == null);
    try writeTestFile(
        tmp.dir,
        "repo/.git/HEAD",
        "ref: refs/heads/" ++ text_utils.repeat("x", max_metadata_bytes + 1),
    );
    try std.testing.expect(try read(alloc, cwd) == null);

    try tmp.dir.createDirPath(std.testing.io, "linked/actual-git");
    try writeTestFile(
        tmp.dir,
        "linked/actual-git/HEAD",
        "ref: refs/heads/symlinked\n",
    );
    try tmp.dir.symLink(
        std.testing.io,
        "actual-git",
        "linked/.git",
        .{ .is_directory = true },
    );
    const linked_cwd = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "linked");
    defer alloc.free(linked_cwd);
    try std.testing.expect(try read(alloc, linked_cwd) == null);
}
