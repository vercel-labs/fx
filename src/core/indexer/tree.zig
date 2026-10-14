//! The listing of one root together with the stamps that prove it is still
//! current: one per folder that was read, and one per ignore, config, index or
//! repository-marker file the rules depended on. A stamp is reusable only when
//! its times are older than the scan's start by the granularity margin, so a
//! change in the same clock tick as the scan, which a later stamp comparison
//! could not see, always forces a new scan.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// Covers coarse filesystem timestamps (FAT and some network filesystems use
/// one or two seconds) and small clock differences.
pub const granularity_margin_ns: i64 = 2 * std.time.ns_per_s;

pub const Kind = enum(u8) { file, directory };

pub const Entry = struct {
    /// Relative to the root, `/`-separated.
    path: []const u8,
    kind: Kind,
};

pub const FolderStamp = struct {
    /// Relative to the root; empty for the root itself.
    rel: []const u8,
    inode: u64,
    mtime_ns: i64,
    ctime_ns: i64,
    reusable: bool,
    /// A folder with its own repository, listed but not entered.
    boundary: bool = false,
    /// Ignored, so only its tracked files are listed.
    excluded: bool = false,
};

pub const SourceStamp = struct {
    /// Absolute path of a file the rules read or looked for.
    path: []const u8,
    exists: bool,
    /// Only existence and identity matter, as for a `.git` directory whose
    /// times change with every git command.
    identity_only: bool,
    inode: u64 = 0,
    size: u64 = 0,
    mtime_ns: i64 = 0,
    ctime_ns: i64 = 0,
    reusable: bool,
    /// Stamped through a final symlink, as the file was read.
    follow_symlinks: bool = false,
};

pub const Tree = struct {
    root: []const u8,
    root_inode: u64,
    scan_started_ns: i64,
    repository: bool,
    /// An unreadable source or folder, or a walk stopped at its reading limit,
    /// left something out. An incomplete tree is never reused.
    incomplete: bool,
    /// The entries were cut to the cap. The walk still read everything, so for
    /// unchanged stamps the cut is the same and the tree can be reused.
    cap_reached: bool,
    skipped_overlong: usize,
    skipped_names: []const []const u8,
    /// Sorted by path, files before folders with the same path.
    entries: []const Entry,
    folders: []const FolderStamp,
    sources: []const SourceStamp,
};

pub fn nowNs() i64 {
    return clampNs(io_mod.nanoTimestamp());
}

fn clampNs(value: anytype) i64 {
    return std.math.cast(i64, value) orelse if (value < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

fn reusableTimes(mtime_ns: i64, ctime_ns: i64, scan_started_ns: i64) bool {
    const limit = scan_started_ns -| granularity_margin_ns;
    return mtime_ns < limit and ctime_ns < limit;
}

pub fn folderStamp(rel: []const u8, stat: std.Io.File.Stat, scan_started_ns: i64) FolderStamp {
    const mtime = clampNs(stat.mtime.nanoseconds);
    const ctime = clampNs(stat.ctime.nanoseconds);
    return .{
        .rel = rel,
        .inode = @intCast(stat.inode),
        .mtime_ns = mtime,
        .ctime_ns = ctime,
        .reusable = reusableTimes(mtime, ctime, scan_started_ns),
    };
}

/// Stamps the absolute `path` without following a final symlink.
pub fn sourceStamp(path: []const u8, identity_only: bool, follow_symlinks: bool, scan_started_ns: i64) SourceStamp {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = follow_symlinks }) catch {
        return .{ .path = path, .exists = false, .identity_only = identity_only, .reusable = true, .follow_symlinks = follow_symlinks };
    };
    const mtime = clampNs(stat.mtime.nanoseconds);
    const ctime = clampNs(stat.ctime.nanoseconds);
    // A `.git` file's contents choose the repository, so only a directory is
    // stamped by identity alone.
    const identity = identity_only and stat.kind == .directory;
    return .{
        .path = path,
        .exists = true,
        .identity_only = identity,
        .inode = @intCast(stat.inode),
        .size = if (identity) 0 else stat.size,
        .mtime_ns = if (identity) 0 else mtime,
        .ctime_ns = if (identity) 0 else ctime,
        .reusable = identity or reusableTimes(mtime, ctime, scan_started_ns),
        .follow_symlinks = follow_symlinks,
    };
}

fn sameSource(recorded: SourceStamp, now: SourceStamp) bool {
    if (recorded.exists != now.exists) return false;
    if (!recorded.exists) return true;
    return recorded.inode == now.inode and recorded.size == now.size and
        recorded.mtime_ns == now.mtime_ns and recorded.ctime_ns == now.ctime_ns;
}

/// Whether `tree` still describes `root` under the same options, so it can be
/// answered from without a new scan. With `subtree` (relative to the root),
/// only the folders at, below or above it are checked; every source always
/// is. A folder above it counts because a `.gitignore` it gains changes what
/// the subtree lists, and only that folder's stamp shows the new file.
pub fn isCurrent(tree: *const Tree, root: []const u8, skipped_names: []const []const u8, subtree: ?[]const u8) bool {
    if (tree.incomplete or !std.mem.eql(u8, tree.root, root)) return false;
    if (tree.skipped_names.len != skipped_names.len) return false;
    for (tree.skipped_names, skipped_names) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    const io = io_mod.getIo();
    const now = nowNs();
    var root_dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch return false;
    defer root_dir.close(io);
    const root_stat = root_dir.stat(io) catch return false;
    if (@as(u64, @intCast(root_stat.inode)) != tree.root_inode) return false;

    for (tree.sources) |source| {
        if (!source.reusable) return false;
        const current = sourceStamp(source.path, source.identity_only, source.follow_symlinks, tree.scan_started_ns);
        if (!sameSource(source, current)) return false;
        if (current.mtime_ns > now or current.ctime_ns > now) return false;
    }
    for (tree.folders) |folder| {
        if (subtree) |sub| {
            if (sub.len > 0 and !onSubtreePath(folder.rel, sub)) continue;
        }
        if (!folder.reusable) return false;
        const stat = root_dir.statFile(io, if (folder.rel.len == 0) "." else folder.rel, .{ .follow_symlinks = false }) catch return false;
        if (stat.kind != .directory) return false;
        const current = folderStamp(folder.rel, stat, tree.scan_started_ns);
        if (current.inode != folder.inode or current.mtime_ns != folder.mtime_ns or current.ctime_ns != folder.ctime_ns) return false;
        if (current.mtime_ns > now or current.ctime_ns > now) return false;
    }
    return true;
}

/// Whether folder `rel` is `sub`, below it, or above it (the root included).
fn onSubtreePath(rel: []const u8, sub: []const u8) bool {
    if (rel.len == 0 or std.mem.eql(u8, rel, sub)) return true;
    if (rel.len > sub.len) return std.mem.startsWith(u8, rel, sub) and rel[sub.len] == '/';
    return std.mem.startsWith(u8, sub, rel) and sub[rel.len] == '/';
}

test "a subtree check covers the folder, the folders below it and the folders above it" {
    try std.testing.expect(onSubtreePath("", "a/b"));
    try std.testing.expect(onSubtreePath("a", "a/b"));
    try std.testing.expect(onSubtreePath("a/b", "a/b"));
    try std.testing.expect(onSubtreePath("a/b/c", "a/b"));
    try std.testing.expect(!onSubtreePath("a/bc", "a/b"));
    try std.testing.expect(!onSubtreePath("ab", "a/b"));
    try std.testing.expect(!onSubtreePath("a/c", "a/b"));
    try std.testing.expect(!onSubtreePath("b", "a/b"));
}

test "stamps reuse only times older than the scan start by the margin" {
    const start: i64 = 100 * std.time.ns_per_s;
    try std.testing.expect(reusableTimes(start - 3 * std.time.ns_per_s, start - 3 * std.time.ns_per_s, start));
    try std.testing.expect(!reusableTimes(start - std.time.ns_per_s, start - 3 * std.time.ns_per_s, start));
    try std.testing.expect(!reusableTimes(start - 3 * std.time.ns_per_s, start, start));
    try std.testing.expect(!reusableTimes(start + 1, start - 3 * std.time.ns_per_s, start));
    // A missing source stays missing until it appears.
    const missing = sourceStamp("/nonexistent/fx-indexer-test", false, false, start);
    try std.testing.expect(!missing.exists and missing.reusable);
}

test "a followed source stamps the file its link points at" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "[core]\n" });
    tmp.dir.symLink(std.testing.io, "target", "link", .{}) catch return error.SkipZigTest;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const link = try std.Io.Dir.path.join(alloc, &.{ root, "link" });
    defer alloc.free(link);

    const start = nowNs();
    const followed = sourceStamp(link, false, true, start);
    const unfollowed = sourceStamp(link, false, false, start);
    try std.testing.expect(followed.follow_symlinks and !unfollowed.follow_symlinks);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "[core]\n\tignorecase = true\n" });
    // An edit to the target is seen through the link, never by the link alone.
    try std.testing.expect(!sameSource(followed, sourceStamp(link, false, true, start)));
    try std.testing.expect(sameSource(unfollowed, sourceStamp(link, false, false, start)));
}
