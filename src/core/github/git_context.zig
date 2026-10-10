const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const safe_git = @import("../shell_command/safe_git.zig");

const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    in_git_repo: bool,
    text: []u8,

    pub fn deinit(self: Snapshot, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

const Query = struct {
    subcommand: safe_git.Subcommand,
    args: []const []const u8,
};

const branch_query: Query = .{ .subcommand = .branch, .args = &.{"--show-current"} };
const status_query: Query = .{ .subcommand = .status, .args = &.{ "--short", "--branch" } };
const log_query: Query = .{ .subcommand = .log, .args = &.{ "--oneline", "-5" } };
const staged_query: Query = .{ .subcommand = .diff, .args = &.{ "--stat", "--cached" } };
const unstaged_query: Query = .{ .subcommand = .diff, .args = &.{"--stat"} };
const inside_query: Query = .{ .subcommand = .rev_parse, .args = &.{"--is-inside-work-tree"} };
/// Every git command the snapshot runs.
const queries = [_]Query{ branch_query, status_query, log_query, staged_query, unstaged_query, inside_query };

/// Captures the working directory's git state through safe git. When fx
/// cannot run git safely there, every section reads as unavailable and the
/// snapshot does not claim the directory is outside a repository, so `fx pr`
/// still starts and its agent can inspect the files directly.
pub fn snapshot(alloc: Allocator) !Snapshot {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const ready = switch (try prepareHere(arena_state.allocator())) {
        .ready => |ready| ready,
        .refused => return .{
            .in_git_repo = true,
            .text = try formatSnapshot(alloc, null, null, null, null, null),
        },
    };

    const branch = try runGit(alloc, ready, branch_query);
    defer if (branch) |text| alloc.free(text);
    const status = try runGit(alloc, ready, status_query);
    defer if (status) |text| alloc.free(text);
    const log = try runGit(alloc, ready, log_query);
    defer if (log) |text| alloc.free(text);
    const staged = try runGit(alloc, ready, staged_query);
    defer if (staged) |text| alloc.free(text);
    const unstaged = try runGit(alloc, ready, unstaged_query);
    defer if (unstaged) |text| alloc.free(text);

    return .{
        .in_git_repo = isGitRepository(alloc, ready),
        .text = try formatSnapshot(alloc, branch, status, log, staged, unstaged),
    };
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
    errdefer alloc.free(result.stdout);

    if (result.term.exited != 0) {
        alloc.free(result.stdout);
        return null;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        alloc.free(result.stdout);
        return null;
    }
    if (trimmed.len == result.stdout.len) return result.stdout;

    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(result.stdout);
    return owned;
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
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const ready: safe_git.Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{} };
    try std.testing.expect(!isGitRepository(failing.allocator(), ready));
}

test "snapshot returns owned Git status text" {
    const state = try snapshot(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, state.text, "Git snapshot") != null);
    try std.testing.expect(std.mem.find(u8, state.text, "Branch:") != null);
}
