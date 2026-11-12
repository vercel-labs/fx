//! Pure workspace capture policy. No filesystem, process or session I/O.
const std = @import("std");
const sort_utils = @import("../shared/sort_utils.zig");
const repo_path = @import("../shared/repo_path.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    untracked_file_bytes: u64 = 2 * 1024 * 1024,
    untracked_count: usize = 1000,
};

pub const Candidate = struct {
    /// One candidate per repository-relative path; the caller collapses index
    /// stages for unmerged paths. Paths are borrowed by the selection.
    path: []const u8,
    tracked: bool,
    present: bool = true,
    skip_worktree: bool = false,
    /// lstat size, never the size of a symlink's target.
    bytes: u64 = 0,
    kind: enum { file, symlink, gitlink } = .file,
};

pub const Exclusion = struct {
    path: []const u8,
    reason: enum { sensitive, too_large, file_limit, missing, submodule },
};

pub const Selection = struct {
    /// Paths to refresh from the worktree with Git: file/symlink content or
    /// a gitlink's current HEAD, never a recursive read of its contents. Paths
    /// borrow candidate/previous strings; only the slices are owned.
    read: []const []const u8,
    /// Absent skip-worktree paths whose current index mode/OID must be retained.
    keep_index: []const []const u8,
    remove: []const []const u8,
    excluded: []const Exclusion,

    /// Conservative eligibility, not proof that a later commit will match.
    /// Ignored paths never become candidates, so any exclusion, or differing
    /// conversions, loses it.
    pub fn canCompareTrees(self: Selection, conversions_differ: bool) bool {
        return !conversions_differ and self.excluded.len == 0;
    }

    pub fn deinit(self: Selection, alloc: Allocator) void {
        alloc.free(self.read);
        alloc.free(self.keep_index);
        alloc.free(self.remove);
        alloc.free(self.excluded);
    }
};

pub const SelectError = Allocator.Error || error{ InvalidPath, DuplicatePath };

/// Returns owned slices borrowing input paths. Caller calls deinit.
/// Candidates must include tracked paths absent on disk, not just a listing.
pub fn select(alloc: Allocator, candidates: []const Candidate, previous: []const []const u8, limits: Limits) SelectError!Selection {
    for (candidates) |entry| try validatePath(entry.path);
    for (previous) |path| try validatePath(path);
    const sorted = try alloc.dupe(Candidate, candidates);
    defer alloc.free(sorted);
    sort_utils.sort(Candidate, sorted, {}, candidateLessThan);
    for (sorted, 0..) |entry, i| {
        if (i > 0 and std.mem.eql(u8, sorted[i - 1].path, entry.path)) return error.DuplicatePath;
    }

    var read: std.ArrayList([]const u8) = .empty;
    defer read.deinit(alloc);
    var keep: std.ArrayList([]const u8) = .empty;
    defer keep.deinit(alloc);
    var remove: std.ArrayList([]const u8) = .empty;
    defer remove.deinit(alloc);
    var excluded: std.ArrayList(Exclusion) = .empty;
    defer excluded.deinit(alloc);
    var untracked_count: usize = 0;

    for (sorted) |entry| {
        if (entry.tracked) {
            if (entry.present) {
                try read.append(alloc, entry.path);
                if (entry.kind == .gitlink) try excluded.append(alloc, .{ .path = entry.path, .reason = .submodule });
            } else if (entry.skip_worktree) {
                try keep.append(alloc, entry.path);
            } else {
                try remove.append(alloc, entry.path);
            }
            continue;
        }
        const reason: ?@FieldType(Exclusion, "reason") = if (!entry.present)
            .missing
        else if (isSensitive(entry.path))
            .sensitive
        else if (entry.kind == .gitlink)
            .submodule
        else if (entry.bytes > limits.untracked_file_bytes)
            .too_large
        else if (untracked_count >= limits.untracked_count)
            .file_limit
        else
            null;
        if (reason) |value| {
            try excluded.append(alloc, .{ .path = entry.path, .reason = value });
        } else {
            try read.append(alloc, entry.path);
            untracked_count += 1;
        }
    }
    // read and keep are sorted subsequences of sorted candidates. Previous
    // paths no longer admitted must leave the persistent capture index.
    for (previous) |path| {
        if (!containsPath(read.items, path) and !containsPath(keep.items, path)) try remove.append(alloc, path);
    }
    sort_utils.sort([]const u8, remove.items, {}, pathLessThan);
    var unique: usize = 0;
    for (remove.items) |path| {
        if (unique == 0 or !std.mem.eql(u8, remove.items[unique - 1], path)) {
            remove.items[unique] = path;
            unique += 1;
        }
    }
    remove.shrinkRetainingCapacity(unique);

    const owned_read = try read.toOwnedSlice(alloc);
    errdefer alloc.free(owned_read);
    const owned_keep = try keep.toOwnedSlice(alloc);
    errdefer alloc.free(owned_keep);
    const owned_remove = try remove.toOwnedSlice(alloc);
    errdefer alloc.free(owned_remove);
    return .{ .read = owned_read, .keep_index = owned_keep, .remove = owned_remove, .excluded = try excluded.toOwnedSlice(alloc) };
}

pub const Reason = enum {
    sensitive,
    too_large,
    file_limit,
    submodule,
    /// The untracked listing did not finish before the capture's deadline.
    untracked_timeout,
    timeout,
    not_git,
    git_refused,
    index_sparse,
    capture_locked,
    /// The folder's git directory belongs to another checkout, such as a
    /// `.git` symlink into another repository.
    foreign_git_dir,
    cancelled,
    budget,
    /// The repository's worktree root is the filesystem root, the home
    /// folder, or above it, such as a home kept as a dotfiles repository, so
    /// fx never captures it.
    private_root,
    inconsistent,
    io_error,
    /// The caller passed a malformed session id or repository path.
    invalid_request,
};

fn validatePath(path: []const u8) error{InvalidPath}!void {
    if (!repo_path.isValid(path)) return error.InvalidPath;
}

/// Names that usually hold credentials, compared without case: a disk that
/// ignores case opens `.ENV` as `.env`, and `ID_RSA` is still a key.
fn isSensitive(path: []const u8) bool {
    const slash = std.mem.findScalarLast(u8, path, '/');
    const base = if (slash) |i| path[i + 1 ..] else path;
    const names = [_][]const u8{
        ".env",    ".envrc",    ".netrc",      ".npmrc",           ".pgpass",
        ".pypirc", "auth.json", "credentials", ".git-credentials", "hosts.yml",
    };
    for (names) |name| if (std.ascii.eqlIgnoreCase(base, name)) return true;
    for ([_][]const u8{ ".env.", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(base, prefix)) return true;
    }
    for ([_][]const u8{ ".pem", ".key", ".p12", ".keystore", ".jks" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(base, suffix)) return true;
    }
    // Docker keeps registry logins in `~/.docker/config.json`; any other
    // `config.json` is ordinary.
    if (std.ascii.eqlIgnoreCase(base, "config.json")) {
        const parent_path = path[0 .. slash orelse return false];
        const parent = if (std.mem.findScalarLast(u8, parent_path, '/')) |i| parent_path[i + 1 ..] else parent_path;
        return std.ascii.eqlIgnoreCase(parent, ".docker");
    }
    return false;
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    var low: usize = 0;
    var high = paths.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, paths[mid], path)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return true,
        }
    }
    return false;
}

fn expectPaths(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |a, b| try std.testing.expectEqualStrings(a, b);
}

test "capture selection includes tracked ignored and staged-new files without applying untracked limits" {
    const alloc = std.testing.allocator;
    const entries = [_]Candidate{
        .{ .path = "keep.log", .tracked = true, .bytes = 99_000_000 },
        .{ .path = ".env", .tracked = true },
        .{ .path = "new-staged.txt", .tracked = true },
    };
    const result = try select(alloc, &entries, &.{}, .{ .untracked_count = 0 });
    defer result.deinit(alloc);
    try expectPaths(&.{ ".env", "keep.log", "new-staged.txt" }, result.read);
    try std.testing.expectEqual(@as(usize, 0), result.excluded.len);
}

test "capture selection preserves only sparse paths absent from disk and removes actual deletions" {
    const alloc = std.testing.allocator;
    const entries = [_]Candidate{
        .{ .path = "out/b", .tracked = true, .present = false, .skip_worktree = true },
        .{ .path = "in/a", .tracked = true, .skip_worktree = true },
        .{ .path = "deleted", .tracked = true, .present = false },
    };
    const result = try select(alloc, &entries, &.{ "out/b", "gone-untracked", "deleted" }, .{});
    defer result.deinit(alloc);
    try expectPaths(&.{"in/a"}, result.read);
    try expectPaths(&.{"out/b"}, result.keep_index);
    try expectPaths(&.{ "deleted", "gone-untracked" }, result.remove);
}

test "capture selection excludes sensitive untracked names and respects exact size boundaries" {
    const alloc = std.testing.allocator;
    const entries = [_]Candidate{
        .{ .path = "dir/.envrc", .tracked = false },
        .{ .path = "dir/.env.local", .tracked = false },
        .{ .path = "key.pem", .tracked = false },
        .{ .path = ".env", .tracked = false },
        .{ .path = "id_ed25519.pub", .tracked = false },
        .{ .path = "exact", .tracked = false, .bytes = 10 },
        .{ .path = "large", .tracked = false, .bytes = 11 },
    };
    // A path the previous capture held that is no longer a candidate, such
    // as one that became ignored, leaves the capture index.
    const result = try select(alloc, &entries, &.{"now-ignored"}, .{ .untracked_file_bytes = 10 });
    defer result.deinit(alloc);
    try expectPaths(&.{"exact"}, result.read);
    try expectPaths(&.{"now-ignored"}, result.remove);
    try std.testing.expectEqual(@as(usize, 6), result.excluded.len);
    try std.testing.expectEqual(.sensitive, result.excluded[0].reason);
}

test "capture selection matches sensitive names without case and knows common credential files" {
    const sensitive = [_][]const u8{
        ".ENV",                "ID_RSA",                   "Credentials",          ".aws/credentials",
        ".docker/config.json", "home/.Docker/Config.JSON", ".config/gh/hosts.yml", "auth.json",
        ".pgpass",             "id_ecdsa",                 "id_ecdsa.pub",         "id_dsa",
        "release.keystore",    "app.JKS",                  ".git-credentials",     ".pypirc",
        "Key.PEM",             ".Env.Local",
    };
    for (sensitive) |path| {
        if (!isSensitive(path)) std.debug.print("{s} should be sensitive\n", .{path});
        try std.testing.expect(isSensitive(path));
    }
    for ([_][]const u8{ "config.json", "app/config.json", "docker/config.json", ".docker/other.json", "credentials.md", "environment", "keys/readme" }) |path| {
        if (isSensitive(path)) std.debug.print("{s} should not be sensitive\n", .{path});
        try std.testing.expect(!isSensitive(path));
    }
}

test "capture selection has deterministic untracked count admission and does not count exclusions" {
    const alloc = std.testing.allocator;
    const entries = [_]Candidate{
        .{ .path = "z", .tracked = false },
        .{ .path = ".env", .tracked = false },
        .{ .path = "a", .tracked = false },
        .{ .path = "tracked", .tracked = true },
    };
    const result = try select(alloc, &entries, &.{}, .{ .untracked_count = 1 });
    defer result.deinit(alloc);
    try expectPaths(&.{ "a", "tracked" }, result.read);
    try std.testing.expectEqual(@as(usize, 2), result.excluded.len);
    try std.testing.expectEqual(.file_limit, result.excluded[1].reason);
}

test "capture selection refreshes present gitlinks and removes deleted submodules" {
    const alloc = std.testing.allocator;
    const entries = [_]Candidate{
        .{ .path = "sub", .tracked = true, .kind = .gitlink },
        .{ .path = "deleted-sub", .tracked = true, .kind = .gitlink, .present = false },
        .{ .path = "sparse-sub", .tracked = true, .kind = .gitlink, .present = false, .skip_worktree = true },
        .{ .path = "untracked-repo", .tracked = false, .kind = .gitlink },
    };
    const result = try select(alloc, &entries, &.{ "deleted-sub", "sub" }, .{});
    defer result.deinit(alloc);
    try expectPaths(&.{"sub"}, result.read);
    try expectPaths(&.{"sparse-sub"}, result.keep_index);
    try expectPaths(&.{"deleted-sub"}, result.remove);
    try std.testing.expectEqual(@as(usize, 2), result.excluded.len);
    try std.testing.expectEqual(.submodule, result.excluded[0].reason);
    try std.testing.expectEqual(.submodule, result.excluded[1].reason);
}

test "capture selection rejects traversal git metadata and duplicate paths" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "", "/tmp/a", "../a", "a/../b", "a//b", "a/./b", "a/", ".git/config", "a/.git", "a/.GIT/config", "nul\x00path" }) |path| {
        try std.testing.expectError(error.InvalidPath, select(alloc, &.{.{ .path = path, .tracked = true }}, &.{}, .{}));
    }
    try std.testing.expectError(error.DuplicatePath, select(alloc, &.{ .{ .path = "a", .tracked = true }, .{ .path = "a", .tracked = false } }, &.{}, .{}));
    try std.testing.expectError(error.InvalidPath, select(alloc, &.{}, &.{"../previous"}, .{}));
}

test "capture selection accepts symlinks unicode and control characters without shell quoting" {
    const alloc = std.testing.allocator;
    const entries = [_]Candidate{
        .{ .path = "ñandú.txt", .tracked = true },
        .{ .path = "space name", .tracked = false, .kind = .symlink, .bytes = 5 },
        .{ .path = "tab\tnewline\n", .tracked = false },
    };
    const result = try select(alloc, &entries, &.{}, .{});
    defer result.deinit(alloc);
    try expectPaths(&.{ "space name", "tab\tnewline\n", "ñandú.txt" }, result.read);
}

test "capture selection comparability requires no lost paths or differing conversions" {
    const alloc = std.testing.allocator;
    const complete = try select(alloc, &.{
        .{ .path = "a", .tracked = true },
    }, &.{}, .{});
    defer complete.deinit(alloc);
    try std.testing.expect(complete.canCompareTrees(false));
    try std.testing.expect(!complete.canCompareTrees(true));
    const partial = try select(alloc, &.{.{ .path = ".env", .tracked = false }}, &.{}, .{});
    defer partial.deinit(alloc);
    try std.testing.expect(!partial.canCompareTrees(false));
}

test "capture selection deduplicates removals and handles empty input and vanished untracked paths" {
    const alloc = std.testing.allocator;
    const empty = try select(alloc, &.{}, &.{}, .{});
    defer empty.deinit(alloc);
    try expectPaths(&.{}, empty.read);
    try expectPaths(&.{}, empty.remove);
    const vanished = try select(alloc, &.{.{ .path = "gone", .tracked = false, .present = false }}, &.{ "gone", "gone" }, .{});
    defer vanished.deinit(alloc);
    try expectPaths(&.{"gone"}, vanished.remove);
    try std.testing.expectEqual(.missing, vanished.excluded[0].reason);
}

fn selectionAllocationCase(alloc: Allocator) !void {
    const result = try select(alloc, &.{
        .{ .path = "sparse", .tracked = true, .present = false, .skip_worktree = true },
        .{ .path = "read", .tracked = true },
        .{ .path = ".env", .tracked = false },
        .{ .path = "new", .tracked = false },
    }, &.{ "removed", "removed", ".env" }, .{});
    defer result.deinit(alloc);
    try expectPaths(&.{ "new", "read" }, result.read);
    try expectPaths(&.{"sparse"}, result.keep_index);
    try expectPaths(&.{ ".env", "removed" }, result.remove);
}

test "capture selection releases allocations at every failure point" {
    const allocator = @import("../shared/testing_allocator.zig").no_resize;
    try std.testing.checkAllAllocationFailures(allocator, selectionAllocationCase, .{});
}

test "capture selection never removes an admitted path from the previous index" {
    const alloc = std.testing.allocator;
    const result = try select(alloc, &.{
        .{ .path = "a", .tracked = true },
        .{ .path = "new", .tracked = false },
        .{ .path = "sparse", .tracked = true, .skip_worktree = true, .present = false },
    }, &.{ "a", "new", "sparse" }, .{});
    defer result.deinit(alloc);
    try expectPaths(&.{}, result.remove);
}
