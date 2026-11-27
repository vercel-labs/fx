const std = @import("std");
const repo_root = @import("../workspace/repo_root.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const workspace_trust = @import("workspace_trust.zig");

/// The folder whose saved answer covers `start`: the repository root that holds
/// it (the main repository's root for a registered linked worktree), unless
/// `workspace_trust.keyFor` refuses that root, then `start`. The caller owns the
/// returned path.
pub fn resolveKey(
    alloc: std.mem.Allocator,
    start: []const u8,
    places: workspace_trust.Places,
) error{OutOfMemory}![]u8 {
    const candidate = try repositoryRoot(alloc, start);
    defer if (candidate) |root| alloc.free(root);
    return alloc.dupe(u8, workspace_trust.keyFor(start, candidate, places));
}

fn repositoryRoot(alloc: std.mem.Allocator, start: []const u8) error{OutOfMemory}!?[]u8 {
    const found = (try repo_root.find(alloc, start)) orelse return null;
    defer alloc.free(found.git_dir);
    if (try repo_root.registeredMainRoot(alloc, found)) |main_root| return main_root;
    return try alloc.dupe(u8, found.root);
}

/// Real paths of the home and profile folders. Owns both slices; free them
/// with `deinit`.
pub const OwnedPlaces = struct {
    home: ?[]u8 = null,
    profile: ?[]u8 = null,

    pub fn places(self: OwnedPlaces) workspace_trust.Places {
        return .{ .home = self.home, .profile = self.profile };
    }

    pub fn deinit(self: *OwnedPlaces, alloc: std.mem.Allocator) void {
        if (self.home) |path| alloc.free(path);
        if (self.profile) |path| alloc.free(path);
        self.* = .{};
    }
};

/// Resolves `home` and fx's profile folder to real paths. A field is null when
/// its folder cannot be resolved, such as a profile folder that does not exist
/// yet. The caller frees the result with `deinit`.
pub fn resolvePlaces(alloc: std.mem.Allocator, home: ?[]const u8) error{OutOfMemory}!OwnedPlaces {
    const home_path = home orelse return .{};
    var result: OwnedPlaces = .{};
    errdefer result.deinit(alloc);
    result.home = try repo_root.realpathOrNull(alloc, home_path);
    result.profile = try profileRealPath(alloc, home_path);
    return result;
}

fn profileRealPath(alloc: std.mem.Allocator, home: []const u8) error{OutOfMemory}!?[]u8 {
    const unresolved = profile_paths.rootDir(alloc, home) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return null;
    };
    defer alloc.free(unresolved);
    return repo_root.realpathOrNull(alloc, unresolved);
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

fn expectKeyAt(base: []const u8, start_sub: []const u8, want_sub: []const u8) !void {
    const alloc = std.testing.allocator;
    const start = try std.Io.Dir.path.join(alloc, &.{ base, start_sub });
    defer alloc.free(start);
    const want = try std.Io.Dir.path.join(alloc, &.{ base, want_sub });
    defer alloc.free(want);
    const key = try resolveKey(alloc, start, .{});
    defer alloc.free(key);
    try std.testing.expectEqualStrings(want, key);
}

// The temporary folder may itself sit inside a repository, so a plain folder
// keys to itself or to a root outside `base`, never to a root inside it.
fn expectPlainKey(base: []const u8, sub: []const u8) !void {
    const alloc = std.testing.allocator;
    const start = try std.Io.Dir.path.join(alloc, &.{ base, sub });
    defer alloc.free(start);
    const key = try resolveKey(alloc, start, .{});
    defer alloc.free(key);
    if (std.mem.eql(u8, key, start)) return;
    try std.testing.expect(!std.mem.startsWith(u8, key, base));
}

test "a plain folder is its own key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "plain");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);

    try expectPlainKey(base, "plain");
}

test "a folder inside a repository uses the repository root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src/deep");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);

    try expectKeyAt(base, "repo/src/deep", "repo");
}

test "a registered linked worktree uses its main repository" {
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

    try expectKeyAt(base, "wt/src", "main");
}

test "a worktree link outside the repository's list uses its own folder" {
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

    try expectKeyAt(base, "evil", "evil");
}

test "places resolve real paths and leave a missing profile null" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");
    const base = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(base);
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const profile = try std.Io.Dir.path.join(alloc, &.{ base, "home", ".fx" });
    defer alloc.free(profile);

    var without_profile = try resolvePlaces(alloc, home);
    defer without_profile.deinit(alloc);
    try std.testing.expectEqualStrings(home, without_profile.home.?);
    try std.testing.expect(without_profile.profile == null);

    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    var with_profile = try resolvePlaces(alloc, home);
    defer with_profile.deinit(alloc);
    try std.testing.expectEqualStrings(profile, with_profile.profile.?);
    try std.testing.expectEqualStrings(home, with_profile.places().home.?);

    var none = try resolvePlaces(alloc, null);
    defer none.deinit(alloc);
    try std.testing.expect(none.home == null);
    try std.testing.expect(none.profile == null);
}

test "a repository in the home folder does not cover a plain folder under it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.git");
    try tmp.dir.createDirPath(std.testing.io, "home/Downloads/x");
    const base = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(base);
    const home = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    const start = try std.Io.Dir.path.join(alloc, &.{ base, "home", "Downloads", "x" });
    defer alloc.free(start);

    const key = try resolveKey(alloc, start, .{ .home = home });
    defer alloc.free(key);
    try std.testing.expectEqualStrings(start, key);
}
