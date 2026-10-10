const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const git_command = @import("../workspace/git_command.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    in_git_repo: bool,
    text: []u8,

    pub fn deinit(self: Snapshot, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

pub fn snapshot(alloc: Allocator) !Snapshot {
    return snapshotAt(alloc, ".");
}

fn snapshotAt(alloc: Allocator, cwd: []const u8) !Snapshot {
    const git: Git = .{ .executable = git_command.trustedExecutable(), .cwd = cwd };
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    // Worktree status and the unstaged diff compare file contents, which runs
    // filter drivers, so they are omitted when the drivers cannot be disabled.
    const content_overrides = try git.filterOverrides(arena_state.allocator());

    const in_git_repo = git.isRepository(alloc);
    const branch = try git.run(alloc, &.{}, &.{ "branch", "--show-current" });
    defer if (branch) |text| alloc.free(text);
    const status = if (content_overrides) |overrides|
        try git.run(alloc, overrides, &.{ "status", "--short", "--branch", "--ignore-submodules=dirty" })
    else
        null;
    defer if (status) |text| alloc.free(text);
    const log = try git.run(alloc, &.{}, &.{ "log", "--no-show-signature", "--oneline", "-5" });
    defer if (log) |text| alloc.free(text);
    const staged = try git.run(alloc, &.{}, &(diff_stat_args ++ [_][]const u8{"--cached"}));
    defer if (staged) |text| alloc.free(text);
    const unstaged = if (content_overrides) |overrides|
        try git.run(alloc, overrides, &diff_stat_args)
    else
        null;
    defer if (unstaged) |text| alloc.free(text);

    return .{
        .in_git_repo = in_git_repo,
        .text = try formatSnapshot(alloc, branch, status, log, staged, unstaged, content_overrides != null),
    };
}

const diff_stat_args = [_][]const u8{ "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty", "--submodule=short", "--stat" };

const Git = struct {
    executable: ?[]const u8,
    cwd: []const u8,

    /// Returns filter overrides owned by `arena`, or null when git is
    /// unavailable or repository filters cannot be verified.
    fn filterOverrides(self: Git, arena: Allocator) Allocator.Error!?[]const []const u8 {
        const executable = self.executable orelse return null;
        return git_command.repositoryFilterOverrides(arena, executable, self.cwd, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RepositoryFiltersUnverified, error.TimeoutExpired, error.Cancelled => {
                debug_trace.logf("core", "git snapshot omitted worktree status and diff: repository filters unverified", .{});
                return null;
            },
        };
    }

    fn isRepository(self: Git, alloc: Allocator) bool {
        const result = self.run(alloc, &.{}, &.{ "rev-parse", "--is-inside-work-tree" }) catch return false;
        defer if (result) |text| alloc.free(text);
        return if (result) |text| std.mem.eql(u8, text, "true") else false;
    }

    /// Returns trimmed stdout owned by `alloc`, or null when git is
    /// unavailable, fails, or prints nothing.
    fn run(
        self: Git,
        alloc: Allocator,
        overrides: []const []const u8,
        args: []const []const u8,
    ) Allocator.Error!?[]u8 {
        const executable = self.executable orelse return null;
        var argv = try buildGitArgv(alloc, executable, overrides, args);
        defer argv.deinit(alloc);
        var environment = git_command.readOnlyEnvironment(alloc, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer environment.deinit();

        const result = std.process.run(alloc, io_mod.getIo(), .{
            .argv = argv.items,
            .cwd = .{ .path = self.cwd },
            .environ_map = &environment,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer alloc.free(result.stderr);
        errdefer alloc.free(result.stdout);

        const succeeded = switch (result.term) {
            .exited => |code| code == 0,
            .signal, .stopped, .unknown => false,
        };
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (!succeeded or trimmed.len == 0) {
            alloc.free(result.stdout);
            return null;
        }
        if (trimmed.len == result.stdout.len) return result.stdout;

        const owned = try alloc.dupe(u8, trimmed);
        alloc.free(result.stdout);
        return owned;
    }
};

fn buildGitArgv(
    alloc: Allocator,
    executable: []const u8,
    overrides: []const []const u8,
    args: []const []const u8,
) Allocator.Error!std.ArrayList([]const u8) {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(alloc);
    try git_command.appendPrefix(alloc, &argv, executable);
    try argv.appendSlice(alloc, overrides);
    try argv.appendSlice(alloc, args);
    return argv;
}

fn formatSnapshot(
    alloc: Allocator,
    branch: ?[]const u8,
    status: ?[]const u8,
    log: ?[]const u8,
    staged: ?[]const u8,
    unstaged: ?[]const u8,
    filters_verified: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("Git snapshot\n");
    try out.writer.print("Branch: {s}\n", .{branch orelse "unavailable"});
    try out.writer.writeAll("\nStatus:\n");
    try writeBody(&out.writer, status, "unavailable");
    try out.writer.writeAll("\nRecent commits:\n");
    try writeBody(&out.writer, log, "unavailable");
    try out.writer.writeAll("\nStaged diff stat:\n");
    try writeBody(&out.writer, staged, "none");
    try out.writer.writeAll("\nUnstaged diff stat:\n");
    try writeBody(&out.writer, unstaged, if (filters_verified) "none" else "unavailable");

    return try out.toOwnedSlice();
}

fn writeBody(writer: *std.Io.Writer, value: ?[]const u8, fallback: []const u8) !void {
    const body = value orelse fallback;
    try writer.writeAll(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try writer.writeByte('\n');
}

test "snapshot formatting: null git values match core fallback text exactly" {
    const text = try formatSnapshot(std.testing.allocator, null, null, null, null, null, true);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Git snapshot
        \\Branch: unavailable
        \\
        \\Status:
        \\unavailable
        \\
        \\Recent commits:
        \\unavailable
        \\
        \\Staged diff stat:
        \\none
        \\
        \\Unstaged diff stat:
        \\none
        \\
    , text);
}

test "snapshot formatting: populated sections preserve layout exactly" {
    const text = try formatSnapshot(
        std.testing.allocator,
        "main",
        "## main\n M src/main.zig",
        "abc123 first\n",
        " src/main.zig | 2 ++",
        " src/core/github/git_context.zig | 5 +++++",
        true,
    );
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Git snapshot
        \\Branch: main
        \\
        \\Status:
        \\## main
        \\ M src/main.zig
        \\
        \\Recent commits:
        \\abc123 first
        \\
        \\Staged diff stat:
        \\ src/main.zig | 2 ++
        \\
        \\Unstaged diff stat:
        \\ src/core/github/git_context.zig | 5 +++++
        \\
    , text);
}

test "git argv: hardening options and filter overrides precede the subcommand" {
    const overrides = [_][]const u8{ "-c", "filter.trap.clean=" };
    var argv = try buildGitArgv(std.testing.allocator, "/usr/bin/git", &overrides, &.{ "status", "--short" });
    defer argv.deinit(std.testing.allocator);

    const tail_start = 1 + git_command.global_options.len;
    try std.testing.expectEqualStrings("/usr/bin/git", argv.items[0]);
    try std.testing.expectEqualSlices([]const u8, &git_command.global_options, argv.items[1..tail_start]);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "-c", "filter.trap.clean=", "status", "--short" },
        argv.items[tail_start..],
    );
}

test "git repository detection treats allocation failure as unavailable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const git: Git = .{ .executable = git_command.trustedExecutable(), .cwd = "." };
    try std.testing.expect(!git.isRepository(failing.allocator()));
}

test "snapshot returns owned Git status text" {
    const state = try snapshot(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, state.text, "Git snapshot") != null);
    try std.testing.expect(std.mem.find(u8, state.text, "Branch:") != null);
}

test "snapshot marks worktree details unavailable when repository filter keys cannot be overridden" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const trap = try git_command.createTrapRepositoryForTest(alloc, &tmp);
    defer trap.deinit(alloc);
    const executable = git_command.trustedExecutable() orelse return error.SkipZigTest;
    const configured = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ executable, "config", "filter.a=b.clean", "cat" },
        .cwd = .{ .path = trap.root },
    });
    defer alloc.free(configured.stdout);
    defer alloc.free(configured.stderr);
    try std.testing.expect(configured.term == .exited and configured.term.exited == 0);

    const state = try snapshotAt(alloc, trap.root);
    defer state.deinit(alloc);
    try std.testing.expect(state.in_git_repo);
    try std.testing.expect(std.mem.find(u8, state.text, "Status:\nunavailable\n") != null);
    try std.testing.expect(std.mem.find(u8, state.text, "Unstaged diff stat:\nunavailable\n") != null);
    try std.testing.expect(!trap.markerExists());
}

test "snapshot does not run programs named by repository config" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const trap = try git_command.createTrapRepositoryForTest(alloc, &tmp);
    defer trap.deinit(alloc);
    try git_command.TrapRepositoryForTest.touchTrackedFile(&tmp, "needle edited\n");

    const state = try snapshotAt(alloc, trap.root);
    defer state.deinit(alloc);

    try std.testing.expect(state.in_git_repo);
    // The branch header proves worktree status ran, and the commit subject proves log ran.
    try std.testing.expect(std.mem.find(u8, state.text, "Status:\n## ") != null);
    try std.testing.expect(std.mem.find(u8, state.text, "trap") != null);
    try std.testing.expect(!trap.markerExists());
}
