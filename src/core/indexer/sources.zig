//! Ignore sources in git's precedence, lowest first: the user's excludes file,
//! then the repository's `info/exclude`, then `.gitignore` files from the root
//! down, which a walker loads as it enters each directory. Every source is a
//! bounded regular-file read; one that cannot be read is reported so the
//! caller can mark its result incomplete, never replaced by running git.
//!
//! Which of these sources can change a saved listing is modeled in
//! `tests/tla/indexer/SnapshotSources.tla`.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const bounded_read = @import("bounded_read.zig");
const git_config = @import("git_config.zig");
const ignore = @import("ignore.zig");
const layout_mod = @import("layout.zig");

const Allocator = std.mem.Allocator;

pub const Unavailable = struct {
    path: []const u8,
    /// Static string.
    reason: []const u8,
};

pub const RepositoryWide = struct {
    /// Lowest precedence first.
    lists: []const *const ignore.PatternList,
    unavailable: []const Unavailable,
};

/// Loads the excludes file named by `settings` and `info/exclude` from the
/// common git directory. Only an excludes file the user's own config names
/// follows a symlink. Memory belongs to `arena`.
pub fn loadRepositoryWide(arena: Allocator, layout: layout_mod.Layout, settings: git_config.IgnoreSettings) Allocator.Error!RepositoryWide {
    var lists: std.ArrayList(*const ignore.PatternList) = .empty;
    var unavailable: std.ArrayList(Unavailable) = .empty;
    const info_exclude = try std.Io.Dir.path.join(arena, &.{ layout.common_dir, "info", "exclude" });
    const files = [_]struct { path: ?[]const u8, follow_symlinks: bool }{
        .{ .path = settings.excludes_file, .follow_symlinks = settings.excludes_file_follows_symlinks },
        .{ .path = info_exclude, .follow_symlinks = false },
    };
    for (files) |file| {
        const path = file.path orelse continue;
        const outcome = if (file.follow_symlinks)
            try bounded_read.readUserAbsolute(arena, path, ignore.max_pattern_file_bytes)
        else
            try bounded_read.readAbsolute(arena, path, ignore.max_pattern_file_bytes);
        switch (outcome) {
            .content => |content| {
                const list = try arena.create(ignore.PatternList);
                list.* = try ignore.PatternList.parse(arena, "", content);
                try lists.append(arena, list);
            },
            .missing => {},
            .unavailable => |reason| try unavailable.append(arena, .{ .path = path, .reason = reason }),
        }
    }
    return .{
        .lists = try lists.toOwnedSlice(arena),
        .unavailable = try unavailable.toOwnedSlice(arena),
    };
}

pub const DirectoryList = union(enum) {
    absent,
    list: *const ignore.PatternList,
    /// Static string.
    unavailable: []const u8,
};

/// Loads `.gitignore` from the open directory `dir`, whose path relative to
/// the worktree root is `rule_dir` (empty at the root, no trailing `/`). A
/// symlinked `.gitignore` is not followed, as in git. Memory belongs to
/// `arena`.
pub fn loadDirectory(arena: Allocator, dir: std.Io.Dir, rule_dir: []const u8) Allocator.Error!DirectoryList {
    return switch (try bounded_read.readAt(arena, dir, ".gitignore", ignore.max_pattern_file_bytes)) {
        .content => |content| blk: {
            // Built only here, since most folders have no `.gitignore`.
            const base = if (rule_dir.len == 0) "" else try std.mem.concat(arena, u8, &.{ rule_dir, "/" });
            const list = try arena.create(ignore.PatternList);
            list.* = try ignore.PatternList.parse(arena, base, content);
            break :blk .{ .list = list };
        },
        .missing => .absent,
        .unavailable => |reason| .{ .unavailable = reason },
    };
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

test "repository-wide ignore sources load in git's precedence and report unreadable ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "repo/.git/HEAD", "ref: refs/heads/main\n");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git/objects");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git/refs");
    try writeTestFile(tmp.dir, "repo/.git/info/exclude", "!keep.tmp\n");
    try writeTestFile(tmp.dir, "global-ignore", "*.tmp\n");
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const layout = (try layout_mod.discover(arena, try std.Io.Dir.path.join(arena, &.{ root, "repo" }))).?;

    const settings: git_config.IgnoreSettings = .{
        .excludes_file = try std.Io.Dir.path.join(arena, &.{ root, "global-ignore" }),
        .excludes_file_follows_symlinks = true,
        .ignore_case = false,
        .object_format = .sha1,
        .invalid = &.{},
    };
    const wide = try loadRepositoryWide(arena, layout, settings);
    try std.testing.expectEqual(@as(usize, 2), wide.lists.len);
    try std.testing.expectEqual(@as(usize, 0), wide.unavailable.len);
    try std.testing.expectEqual(ignore.Decision.excluded, ignore.decide(wide.lists, "a.tmp", false, false));
    try std.testing.expectEqual(ignore.Decision.included, ignore.decide(wide.lists, "keep.tmp", false, false));

    var unreadable = settings;
    unreadable.excludes_file = root;
    const partial = try loadRepositoryWide(arena, layout, unreadable);
    try std.testing.expectEqual(@as(usize, 1), partial.lists.len);
    try std.testing.expectEqual(@as(usize, 1), partial.unavailable.len);

    // A linked excludes file is followed only when the user's config named it.
    tmp.dir.symLink(std.testing.io, "global-ignore", "linked-ignore", .{}) catch return error.SkipZigTest;
    var linked = settings;
    linked.excludes_file = try std.Io.Dir.path.join(arena, &.{ root, "linked-ignore" });
    const followed = try loadRepositoryWide(arena, layout, linked);
    try std.testing.expectEqual(@as(usize, 2), followed.lists.len);
    try std.testing.expectEqual(ignore.Decision.excluded, ignore.decide(followed.lists, "a.tmp", false, false));
    linked.excludes_file_follows_symlinks = false;
    const refused = try loadRepositoryWide(arena, layout, linked);
    try std.testing.expectEqual(@as(usize, 1), refused.lists.len);
    try std.testing.expectEqual(@as(usize, 1), refused.unavailable.len);
}

test "directory .gitignore loads with its base and refuses symlinks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "sub/.gitignore", "/local\n");
    try writeTestFile(tmp.dir, "target", "x\n");
    try tmp.dir.createDirPath(std.testing.io, "linked");
    var sub = try tmp.dir.openDir(std.testing.io, "sub", .{});
    defer sub.close(std.testing.io);
    const loaded = try loadDirectory(arena, sub, "sub");
    const lists = [_]*const ignore.PatternList{loaded.list};
    try std.testing.expectEqual(ignore.Decision.excluded, ignore.decide(&lists, "sub/local", false, false));
    try std.testing.expectEqual(ignore.Decision.none, ignore.decide(&lists, "local", false, false));
    try std.testing.expect(try loadDirectory(arena, tmp.dir, "") == .absent);

    var linked = try tmp.dir.openDir(std.testing.io, "linked", .{});
    defer linked.close(std.testing.io);
    linked.symLink(std.testing.io, "../target", ".gitignore", .{}) catch return error.SkipZigTest;
    try std.testing.expect(try loadDirectory(arena, linked, "linked") == .unavailable);
}
