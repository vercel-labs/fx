const std = @import("std");
const builtin = @import("builtin");
const testing_allocator = @import("../shared/testing_allocator.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const safe_git = @import("../shell_command/safe_git.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const direct_command = @import("../permissions/direct_command.zig");

const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    in_git_repo: bool,
    text: []u8,

    pub fn deinit(self: Snapshot, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

/// What one git query reports.
pub const Part = enum { inside, branch, log, status, staged, unstaged };

const Query = struct {
    part: Part,
    subcommand: safe_git.Subcommand,
    args: []const []const u8,
};

const inside_query: Query = .{ .part = .inside, .subcommand = .rev_parse, .args = &.{"--is-inside-work-tree"} };
const branch_query: Query = .{ .part = .branch, .subcommand = .branch, .args = &.{"--show-current"} };
const log_query: Query = .{ .part = .log, .subcommand = .log, .args = &.{ "--oneline", "-5" } };
const status_query: Query = .{ .part = .status, .subcommand = .status, .args = &.{ "--short", "--branch" } };
const staged_query: Query = .{ .part = .staged, .subcommand = .diff, .args = &.{ "--stat", "--cached" } };
const unstaged_query: Query = .{ .part = .unstaged, .subcommand = .diff, .args = &.{"--stat"} };
/// Every git command the snapshot runs. The ones that read the index come
/// last, so a slow or blocked index still leaves the branch and the commits.
const queries = [_]Query{ inside_query, branch_query, log_query, status_query, staged_query, unstaged_query };

/// The most output `queryParts` reads from one query; a query that prints
/// more is left out.
const trace_output_limit: usize = 1024 * 1024;

/// Captures the working directory's git state through safe git. When fx
/// cannot run git safely there, every section reads as unavailable and the
/// snapshot does not claim the directory is outside a repository, so `fx pr`
/// still starts and its agent can inspect the files directly.
pub fn snapshot(alloc: Allocator) !Snapshot {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var parts = try partsFrom(alloc, try prepareHere(arena_state.allocator()));
    defer parts.deinit(alloc);
    return snapshotFromParts(alloc, parts);
}

/// A refusal does not claim the directory is outside a repository.
fn snapshotFromParts(alloc: Allocator, parts: Parts) !Snapshot {
    return .{
        .in_git_repo = parts.refused != null or parts.in_git_repo,
        .text = try formatSnapshot(alloc, parts.branch, parts.status, parts.log, parts.staged, parts.unstaged),
    };
}

/// Why `queryParts` has no value for a part it asked git for.
pub const Unfinished = enum {
    /// The deadline passed before the query finished or started.
    timeout,
    /// A signal ended the query's git.
    signal,
};

/// What each git query printed, or null when it failed or printed nothing:
/// trimmed for the snapshot, and without the line breaks at its end for
/// `queryParts`. Owned by the allocator given to `queryParts`.
pub const Parts = struct {
    /// Why safe git refused to run; every query is then null.
    refused: ?safe_git.Refusal = null,
    in_git_repo: bool = false,
    branch: ?[]u8 = null,
    status: ?[]u8 = null,
    log: ?[]u8 = null,
    staged: ?[]u8 = null,
    unstaged: ?[]u8 = null,
    /// The parts that git did not finish, and why. Set only by `queryParts`.
    unfinished: std.enums.EnumMap(Part, Unfinished) = .{},
    /// Whether `queryParts`'s deadline passed.
    timed_out: bool = false,
    /// The signal that ended a query's git, when one did.
    signal: ?u32 = null,

    pub fn deinit(self: *Parts, alloc: Allocator) void {
        for ([_]?[]u8{ self.branch, self.status, self.log, self.staged, self.unstaged }) |part| {
            if (part) |text| alloc.free(text);
        }
        self.* = undefined;
    }

    /// Keeps what the query for `part` printed; `self` then owns `text`.
    fn set(self: *Parts, alloc: Allocator, part: Part, text: ?[]u8) void {
        switch (part) {
            .inside => {
                defer if (text) |value| alloc.free(value);
                self.in_git_repo = if (text) |value| std.mem.eql(u8, value, "true") else false;
            },
            .branch => self.branch = text,
            .log => self.log = text,
            .status => self.status = text,
            .staged => self.staged = text,
            .unstaged => self.unstaged = text,
        }
    }
};

/// Runs the snapshot's git queries in `cwd`, an absolute path, through safe
/// git, for `/trace`, within `budget_ms` in all: safe git's own checks and
/// every query share it. Each command runs in its own process group, which
/// the deadline terminates and reaps, and the queries after it do not
/// start. `/trace` runs on the terminal's thread, so this bounds how long
/// the terminal waits.
pub fn queryParts(alloc: Allocator, cwd: []const u8, budget_ms: u32) Allocator.Error!Parts {
    const deadline_ms: i64 = io_mod.milliTimestamp() + budget_ms;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const checks: safe_git.CheckRunner = .{ .context = &deadline_ms, .run = runCheckBefore };
    const prepared = safe_git.prepareWith(arena, cwd, checks) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimeoutExpired => {
            var parts: Parts = .{ .timed_out = true };
            for (queries) |query| parts.unfinished.put(query.part, .timeout);
            logUnfinished(parts, budget_ms);
            return parts;
        },
    };
    const ready = switch (prepared) {
        .ready => |ready| ready,
        .refused => |refusal| return .{ .refused = refusal },
    };
    var result: Parts = .{};
    errdefer result.deinit(alloc);
    for (queries) |query| {
        if (result.timed_out) {
            result.unfinished.put(query.part, .timeout);
            continue;
        }
        const argv = try buildGitArgv(arena, ready, query);
        const outcome = runBefore(alloc, argv, cwd, deadline_ms, trace_output_limit) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TimeoutExpired => {
                result.timed_out = true;
                result.unfinished.put(query.part, .timeout);
                continue;
            },
        };
        switch (outcome) {
            .output => |stdout| result.set(alloc, query.part, try withoutTrailingNewline(alloc, stdout)),
            .failed => {},
            .signal => |signal| {
                if (result.signal == null) result.signal = signal;
                result.unfinished.put(query.part, .signal);
            },
        }
    }
    if (result.unfinished.count() > 0) logUnfinished(result, budget_ms);
    return result;
}

/// Names each part `/trace` leaves out of its git record because git did not
/// finish it.
fn logUnfinished(parts: Parts, budget_ms: u32) void {
    var buffer: [160]u8 = undefined;
    var dropped: std.Io.Writer = .fixed(&buffer);
    for (std.enums.values(Part)) |part| {
        const reason = parts.unfinished.get(part) orelse continue;
        dropped.print("{s}{s}:{s}", .{ if (dropped.end == 0) "" else ",", @tagName(part), @tagName(reason) }) catch break;
    }
    debug_trace.logf("core", "trace git left out parts git did not finish limit_ms={d} timed_out={s} signal={d} dropped={s}", .{
        budget_ms,
        if (parts.timed_out) "true" else "false",
        parts.signal orelse 0,
        dropped.buffered(),
    });
}

/// How a git command run for `/trace` ended.
const Outcome = union(enum) {
    /// What it wrote to stdout when it exited 0. Owned by the caller.
    output: []u8,
    /// It could not start, exited with an error, or printed more than its
    /// limit.
    failed,
    /// A signal ended it.
    signal: u32,
};

/// Runs `argv`, a safe git command, in `cwd` through the direct read-only
/// executor with safe git's environment. The command runs in its own process
/// group, which the executor terminates and reaps when `deadline_ms` passes;
/// then this returns `error.TimeoutExpired`.
fn runBefore(
    alloc: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    deadline_ms: i64,
    output_limit: usize,
) error{ OutOfMemory, TimeoutExpired }!Outcome {
    const now = io_mod.milliTimestamp();
    if (now >= deadline_ms) return error.TimeoutExpired;
    const stages = [_]command_effect.DirectStage{.{
        .executable = argv[0],
        .argv = argv,
        .environment_profile = .git_read_only,
    }};
    const captured = direct_command.captureDirectReadOnly(.{
        .max_command_output_bytes = output_limit,
        .timeout_ms = @intCast(deadline_ms - now),
        .timeout_started_ms = now,
    }, alloc, .{ .command = "git", .cwd = cwd, .stages = &stages }, output_limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimeoutExpired => return error.TimeoutExpired,
        else => {
            debug_trace.logf("core", "trace git command left out err={s} limit_bytes={d}", .{ @errorName(err), output_limit });
            return .failed;
        },
    };
    switch (captured.status) {
        .exit_code => |code| if (code == 0) return .{ .output = captured.stdout },
        .signal => |signal| {
            alloc.free(captured.stdout);
            return .{ .signal = signal };
        },
        .finished, .indeterminate => {},
    }
    alloc.free(captured.stdout);
    return .failed;
}

/// Runs one of safe git's own checks before the deadline `context` points
/// to.
fn runCheckBefore(
    context: ?*const anyopaque,
    arena: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    output_limit: usize,
) safe_git.CheckError!?[]const u8 {
    const deadline_ms: *const i64 = @ptrCast(@alignCast(context.?));
    return switch (try runBefore(arena, argv, cwd, deadline_ms.*, output_limit)) {
        .output => |stdout| stdout,
        .failed, .signal => null,
    };
}

/// `stdout` without the line breaks at its end, or null when nothing is
/// left, so its first line keeps the spaces git starts it with. Takes
/// ownership of `stdout`; the caller owns the result.
fn withoutTrailingNewline(alloc: Allocator, stdout: []u8) Allocator.Error!?[]u8 {
    const kept = std.mem.trimEnd(u8, stdout, "\r\n");
    if (kept.len > 0 and kept.len == stdout.len) return stdout;
    defer alloc.free(stdout);
    if (kept.len == 0) return null;
    return try alloc.dupe(u8, kept);
}

/// `stdout` without the whitespace around it, or null when nothing is left.
/// Takes ownership of `stdout`; the caller owns the result.
fn trimmedOwned(alloc: Allocator, stdout: []u8) Allocator.Error!?[]u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len > 0 and trimmed.len == stdout.len) return stdout;
    defer alloc.free(stdout);
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

/// The snapshot's queries, run in the process's directory with no deadline.
fn partsFrom(alloc: Allocator, prepared: safe_git.Prepared) !Parts {
    const ready = switch (prepared) {
        .ready => |ready| ready,
        .refused => |refusal| return .{ .refused = refusal },
    };
    var result: Parts = .{};
    errdefer result.deinit(alloc);
    for (queries) |query| {
        if (query.part == .inside) {
            result.in_git_repo = isGitRepository(alloc, ready);
            continue;
        }
        result.set(alloc, query.part, try runGit(alloc, ready, query));
    }
    return result;
}

fn prepareHere(arena: Allocator) Allocator.Error!safe_git.Prepared {
    const cwd = io_mod.realpathAlloc(arena, ".") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("core", "git snapshot unavailable reason=cwd_unresolved error={s}", .{@errorName(err)});
            return .{ .refused = .repo_config_unavailable };
        },
    };
    return safe_git.prepare(arena, cwd);
}

/// Memory belongs to `arena`.
fn buildGitArgv(arena: Allocator, ready: safe_git.Ready, query: Query) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try safe_git.appendCommand(arena, &argv, ready, query.subcommand);
    try argv.appendSlice(arena, query.args);
    return argv.items;
}

fn isGitRepository(alloc: Allocator, ready: safe_git.Ready) bool {
    const result = runGit(alloc, ready, inside_query) catch return false;
    defer if (result) |text| alloc.free(text);
    return if (result) |text| std.mem.eql(u8, text, "true") else false;
}

fn runGit(alloc: Allocator, ready: safe_git.Ready, query: Query) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environment = try safe_git.environment(arena);

    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = try buildGitArgv(arena, ready, query),
        .environ_map = &environment,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(result.stderr);

    // A git that a signal ended has no exit code.
    if (!result.term.success()) {
        alloc.free(result.stdout);
        return null;
    }
    return trimmedOwned(alloc, result.stdout);
}

fn formatSnapshot(
    alloc: Allocator,
    branch: ?[]const u8,
    status: ?[]const u8,
    log: ?[]const u8,
    staged: ?[]const u8,
    unstaged: ?[]const u8,
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
    try writeBody(&out.writer, unstaged, "none");

    return try out.toOwnedSlice();
}

fn writeBody(writer: *std.Io.Writer, value: ?[]const u8, fallback: []const u8) !void {
    const body = value orelse fallback;
    try writer.writeAll(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try writer.writeByte('\n');
}

test "snapshot formatting: null git values match core fallback text exactly" {
    const text = try formatSnapshot(std.testing.allocator, null, null, null, null, null);
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

test "git argv: every snapshot command is built by the safe-git helper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready: safe_git.Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{"x"} };

    for (queries) |query| {
        var prefix: std.ArrayList([]const u8) = .empty;
        try safe_git.appendCommand(arena, &prefix, ready, query.subcommand);
        const argv = try buildGitArgv(arena, ready, query);
        try std.testing.expectEqual(prefix.items.len + query.args.len, argv.len);
        for (prefix.items, argv[0..prefix.items.len]) |want, have| try std.testing.expectEqualStrings(want, have);
        for (query.args, argv[prefix.items.len..]) |want, have| try std.testing.expectEqualStrings(want, have);
    }
}

test "git repository detection treats allocation failure as unavailable" {
    var failing = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{ .fail_index = 0 });
    const ready: safe_git.Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{} };
    try std.testing.expect(!isGitRepository(failing.allocator(), ready));
}

test "snapshot returns owned Git status text" {
    const state = try snapshot(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, state.text, "Git snapshot") != null);
    try std.testing.expect(std.mem.find(u8, state.text, "Branch:") != null);
}

test "a refused safe git reads as unavailable and still claims a repository" {
    var refused = try partsFrom(std.testing.allocator, .{ .refused = .git_too_old });
    defer refused.deinit(std.testing.allocator);
    try std.testing.expectEqual(safe_git.Refusal.git_too_old, refused.refused.?);
    try std.testing.expect(refused.branch == null and refused.status == null and refused.log == null);
    const shown = try snapshotFromParts(std.testing.allocator, refused);
    defer shown.deinit(std.testing.allocator);
    try std.testing.expect(shown.in_git_repo);
    try std.testing.expect(std.mem.startsWith(u8, shown.text, "Git snapshot\nBranch: unavailable\n"));

    const outside = try snapshotFromParts(std.testing.allocator, .{});
    defer outside.deinit(std.testing.allocator);
    try std.testing.expect(!outside.in_git_repo);
}

/// A repository on `trace-probe` with one commit and an unstaged change to
/// `tracked.txt`. With `.fifo`, its index is a FIFO that nothing writes, so
/// `git status` and `git diff` wait on it for good while `git log` and `git
/// branch` do not read it. Skips without git or `mkfifo`.
fn testRepo(arena: Allocator, dir: std.Io.Dir, index: enum { file, fifo }) ![]const u8 {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const root = try io_mod.dirRealpathAlloc(arena, dir, ".");
    var env = std.process.Environ.Map.init(arena);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", root);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    const git = struct {
        fn run(a: Allocator, cwd: []const u8, environ: *const std.process.Environ.Map, argv: []const []const u8) !void {
            const result = std.process.run(a, io_mod.getIo(), .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = environ }) catch return error.SkipZigTest;
            if (!result.term.success()) return error.SkipZigTest;
        }
    }.run;
    try git(arena, root, &env, &.{ "git", "init", "-q", "--template=", "-b", "trace-probe" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "tracked.txt", .data = "one\n" });
    try git(arena, root, &env, &.{ "git", "add", "tracked.txt" });
    try git(arena, root, &env, &.{ "git", "-c", "user.name=Example", "-c", "user.email=example@example.com", "commit", "-q", "-m", "Add tracked file" });
    try dir.writeFile(std.testing.io, .{ .sub_path = "tracked.txt", .data = "two\n" });
    if (index == .fifo) {
        try dir.deleteFile(std.testing.io, ".git/index");
        try git(arena, root, &env, &.{ "mkfifo", ".git/index" });
    }
    return root;
}

test "trace git keeps the spaces git starts its first line with" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const repo = try testRepo(arena_state.allocator(), tmp.dir, .file);

    var parts = try queryParts(std.testing.allocator, repo, 10_000);
    defer parts.deinit(std.testing.allocator);
    if (parts.refused != null) return error.SkipZigTest;
    try std.testing.expect(!parts.timed_out);
    try std.testing.expectEqual(@as(usize, 0), parts.unfinished.count());
    try std.testing.expect(parts.in_git_repo);
    try std.testing.expectEqualStrings("trace-probe", parts.branch.?);
    try std.testing.expect(std.mem.startsWith(u8, parts.status.?, "## trace-probe\n M tracked.txt"));
    // `git diff --stat` starts each file's line with a space.
    try std.testing.expect(std.mem.startsWith(u8, parts.unstaged.?, " tracked.txt | 2 +-\n"));
    try std.testing.expect(parts.staged == null);
}

test "trace git stops at its deadline, ends the waiting query, and keeps what finished" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const repo = try testRepo(arena_state.allocator(), tmp.dir, .fifo);

    const budget_ms: u32 = 500;
    const started = io_mod.milliTimestamp();
    var parts = try queryParts(std.testing.allocator, repo, budget_ms);
    defer parts.deinit(std.testing.allocator);
    const elapsed = io_mod.milliTimestamp() - started;
    // No trusted git at a fixed system path.
    if (parts.refused != null) return error.SkipZigTest;

    try std.testing.expect(parts.timed_out);
    try std.testing.expect(parts.in_git_repo);
    try std.testing.expectEqualStrings("trace-probe", parts.branch.?);
    try std.testing.expect(std.mem.find(u8, parts.log.?, "Add tracked file") != null);
    try std.testing.expect(parts.status == null and parts.staged == null and parts.unstaged == null);
    for ([_]Part{ .status, .staged, .unstaged }) |part| {
        try std.testing.expectEqual(Unfinished.timeout, parts.unfinished.get(part).?);
    }
    for ([_]Part{ .inside, .branch, .log }) |part| try std.testing.expect(!parts.unfinished.contains(part));
    try std.testing.expect(parts.signal == null);
    // SIGTERM ends the git waiting on the FIFO at once, and the executor
    // reaps it before it returns; SIGKILL would follow 800 ms later.
    try std.testing.expect(elapsed < budget_ms + 2_000);
}

test "trace git with no time left starts no git and says so" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cwd = try io_mod.dirRealpathAlloc(arena_state.allocator(), tmp.dir, ".");

    var parts = try queryParts(std.testing.allocator, cwd, 0);
    defer parts.deinit(std.testing.allocator);
    if (parts.refused != null) return error.SkipZigTest;
    try std.testing.expect(parts.timed_out);
    try std.testing.expect(!parts.in_git_repo);
    for (std.enums.values(Part)) |part| try std.testing.expectEqual(Unfinished.timeout, parts.unfinished.get(part).?);
}

test "a trace git command that a signal ends reports the signal" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const outcome = try runBefore(std.testing.allocator, &.{ "/bin/sh", "-c", "kill -KILL $$" }, "/tmp", io_mod.milliTimestamp() + 10_000, 1024);
    try std.testing.expectEqual(@as(u32, @backingInt(std.posix.SIG.KILL)), outcome.signal);
}
