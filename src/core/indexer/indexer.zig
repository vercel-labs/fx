//! Native workspace indexer: which files and folders exist under a set of
//! roots, decided by git's ignore rules read as data. It never starts a
//! process, so a repository's configuration cannot make it run a program.
//! Outside code imports only this file; `scripts/check-indexer-boundary.sh`
//! enforces that, the import allowlist and the no-process rule in CI.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const git_config = @import("git_config.zig");
const layout = @import("layout.zig");
const scan_mod = @import("scan.zig");
const snapshot_mod = @import("snapshot.zig");
const tree_mod = @import("tree.zig");

const Allocator = std.mem.Allocator;

pub const Kind = scan_mod.Kind;
pub const Entry = scan_mod.Entry;
pub const ScanResult = scan_mod.Result;
pub const ScanError = scan_mod.Error;
pub const default_skipped_names = scan_mod.default_skipped_names;
/// The environment variables that locate git config. A saved listing is valid
/// only under the values it was built with.
pub const config_environment_names = git_config.environment_names;

/// Lists the files and folders under the absolute `root`: inside a git
/// repository exactly what git shows, elsewhere everything except `.gitignore`
/// matches and `options.skipped_names`. See `scan.zig` for the rules. `alloc`
/// must be safe to use from several threads.
pub const scan = scan_mod.scan;

pub const Tree = tree_mod.Tree;
pub const FolderStamp = tree_mod.FolderStamp;
/// Whether a tree from `scan` or a snapshot still describes its root under
/// the same skipped names, checked through its folder and source stamps
/// without reading any folder. With a subtree, only folders at or below it
/// are checked. A stamp recorded within the granularity margin of its scan is
/// never trusted, so a change in the same clock tick always forces a scan.
pub const isCurrent = tree_mod.isCurrent;

pub const Snapshot = snapshot_mod.Snapshot;
/// Loads the saved trees for exactly `roots` from the absolute path the
/// caller chose, or null when missing or not admissible.
pub const loadSnapshot = snapshot_mod.load;
/// Saves trees atomically to the absolute path; an all-empty save deletes it.
pub const saveSnapshot = snapshot_mod.save;

/// What a repository's own config lets it ask git to start: the filter and diff
/// drivers with a program, the signature verifiers it names, and whether a
/// remote is a promisor whose transport git starts when an object is missing.
pub const RepoPrograms = struct {
    /// Absolute git directory of the repository containing the root, found
    /// the way git discovers one, or null outside a repository.
    git_dir: ?[]const u8,
    /// Filter driver names with a `clean`, `smudge` or `process` command.
    names: []const []const u8,
    /// The config marks a remote as a promisor, so git fetches a missing
    /// object from it on demand.
    promisor: bool,
    /// The config names a program git starts to reach a remote: an
    /// `uploadpack`, `receivepack`, ssh command, proxy, credential helper or
    /// protocol allowance.
    transport_program: bool = false,
    /// Diff driver names with a `textconv` program.
    textconv_driver_names: []const []const u8 = &.{},
    /// Diff driver names with an external diff `command`.
    diff_command_driver_names: []const []const u8 = &.{},
    /// Whether the config names `diff.external`.
    external_diff: bool = false,
    /// Whether the config sets `format.pretty`, which can ask for a signature
    /// check.
    format_pretty: bool = false,
    /// Full keys of the signature verifiers the config names, such as
    /// `gpg.program` or `gpg.ssh.program`.
    gpg_program_keys: []const []const u8 = &.{},

    /// Frees memory owned by the allocator passed to `repoPrograms`.
    pub fn deinit(self: RepoPrograms, alloc: Allocator) void {
        if (self.git_dir) |git_dir| alloc.free(git_dir);
        freeNames(alloc, self.names);
        freeNames(alloc, self.textconv_driver_names);
        freeNames(alloc, self.diff_command_driver_names);
        freeNames(alloc, self.gpg_program_keys);
    }
};

fn freeNames(alloc: Allocator, names: []const []const u8) void {
    for (names) |name| alloc.free(name);
    alloc.free(names);
}

/// Copies `names` into memory owned by `alloc`.
fn dupeNames(alloc: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    const owned = try alloc.alloc([]const u8, names.len);
    var copied: usize = 0;
    errdefer {
        for (owned[0..copied]) |name| alloc.free(name);
        alloc.free(owned);
    }
    for (names) |name| {
        owned[copied] = try alloc.dupe(u8, name);
        copied += 1;
    }
    return owned;
}

pub const RepoProgramsError = error{ OutOfMemory, RepoConfigUnavailable };

/// Finds the repository containing the absolute `workspace_root`, the drivers
/// and verifiers its own config names, and whether a remote is a promisor:
/// `config`, `config.worktree` and the files they include, counting every
/// `includeIf` as included so no condition can hide a driver. A repository
/// config file that cannot be read within bounds, a malformed one, or an
/// invalid `.git` file fails closed with `error.RepoConfigUnavailable`.
pub fn repoPrograms(alloc: Allocator, workspace_root: []const u8) RepoProgramsError!RepoPrograms {
    if (!std.Io.Dir.path.isAbsolute(workspace_root)) return error.RepoConfigUnavailable;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = layout.discover(arena, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidGitFile => {
            debug_trace.logf("indexer", "filter names unavailable reason=invalid_git_file root={s}", .{workspace_root});
            return error.RepoConfigUnavailable;
        },
    };
    const context = try git_config.Context.fromEnvironment(arena, found);
    const loaded = try git_config.loadRepositoryEveryInclude(arena, &context);
    if (loaded.unavailable.len > 0) {
        for (loaded.unavailable) |source| {
            debug_trace.logf("indexer", "filter names unavailable reason={s} path={s}", .{ source.reason, source.path });
        }
        return error.RepoConfigUnavailable;
    }

    const git_dir: ?[]const u8 = if (found) |repository| try alloc.dupe(u8, repository.git_dir) else null;
    errdefer if (git_dir) |path| alloc.free(path);
    const names = try dupeNames(alloc, try git_config.filterDriverNames(arena, loaded));
    errdefer freeNames(alloc, names);
    const textconv_driver_names = try dupeNames(alloc, try git_config.textconvDriverNames(arena, loaded));
    errdefer freeNames(alloc, textconv_driver_names);
    const diff_command_driver_names = try dupeNames(alloc, try git_config.diffCommandDriverNames(arena, loaded));
    errdefer freeNames(alloc, diff_command_driver_names);
    const gpg_program_keys = try dupeNames(alloc, try git_config.gpgProgramKeys(arena, loaded));
    return .{
        .git_dir = git_dir,
        .names = names,
        .promisor = git_config.usesPromisorRemote(loaded),
        .transport_program = git_config.namesTransportProgram(loaded),
        .textconv_driver_names = textconv_driver_names,
        .diff_command_driver_names = diff_command_driver_names,
        .external_diff = git_config.namesExternalDiff(loaded),
        .format_pretty = git_config.setsFormatPretty(loaded),
        .gpg_program_keys = gpg_program_keys,
    };
}

test {
    _ = @import("bounded_read.zig");
    _ = @import("wildmatch.zig");
    _ = @import("ignore.zig");
    _ = @import("sources.zig");
    _ = @import("git_index.zig");
    _ = tree_mod;
    _ = snapshot_mod;
    _ = scan_mod;
    _ = layout;
    _ = git_config;
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

fn makeTestRepo(dir: std.Io.Dir, name: []const u8) !void {
    var buffer: [64]u8 = undefined;
    try writeTestFile(dir, try std.mem.print(&buffer, "{s}/.git/HEAD", .{name}), "ref: refs/heads/main\n");
    try dir.createDirPath(std.testing.io, try std.mem.print(&buffer, "{s}/.git/objects", .{name}));
    try dir.createDirPath(std.testing.io, try std.mem.print(&buffer, "{s}/.git/refs", .{name}));
}

test "repoPrograms returns the repository, its drivers and a promisor remote" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeTestRepo(tmp.dir, "repo");
    try writeTestFile(tmp.dir, "repo/.git/config", "[includeIf \"gitdir:/nowhere/\"]\npath = extra\n");
    try writeTestFile(tmp.dir, "repo/.git/extra", "[filter \"x\"]\nclean = /tmp/run-me\n");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try makeTestRepo(tmp.dir, "promisor");
    try writeTestFile(tmp.dir, "promisor/.git/config", "[remote \"origin\"]\nurl = /tmp/origin\npromisor = true\n");
    try makeTestRepo(tmp.dir, "bad");
    try tmp.dir.createDirPath(std.testing.io, "bad/.git/config");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    const repo_src = try std.Io.Dir.path.join(alloc, &.{ root, "repo/src" });
    defer alloc.free(repo_src);
    const programs = try repoPrograms(alloc, repo_src);
    defer programs.deinit(alloc);
    const expected_git_dir = try std.Io.Dir.path.join(alloc, &.{ root, "repo/.git" });
    defer alloc.free(expected_git_dir);
    try std.testing.expectEqualStrings(expected_git_dir, programs.git_dir.?);
    try std.testing.expectEqual(@as(usize, 1), programs.names.len);
    try std.testing.expectEqualStrings("x", programs.names[0]);
    try std.testing.expect(!programs.promisor);

    const promisor_dir = try std.Io.Dir.path.join(alloc, &.{ root, "promisor" });
    defer alloc.free(promisor_dir);
    const promisor = try repoPrograms(alloc, promisor_dir);
    defer promisor.deinit(alloc);
    try std.testing.expect(promisor.promisor);

    const bad = try std.Io.Dir.path.join(alloc, &.{ root, "bad" });
    defer alloc.free(bad);
    try std.testing.expectError(error.RepoConfigUnavailable, repoPrograms(alloc, bad));
    try std.testing.expectError(error.RepoConfigUnavailable, repoPrograms(alloc, "relative"));
}
