const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
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
    const in_git_repo = isGitRepository(alloc);
    const branch = try runGit(alloc, &.{ "branch", "--show-current" });
    defer if (branch) |text| alloc.free(text);
    const status = try runGit(alloc, &.{ "status", "--short", "--branch" });
    defer if (status) |text| alloc.free(text);
    const log = try runGit(alloc, &.{ "log", "--oneline", "-5" });
    defer if (log) |text| alloc.free(text);
    const staged = try runGit(alloc, &.{ "diff", "--stat", "--cached" });
    defer if (staged) |text| alloc.free(text);
    const unstaged = try runGit(alloc, &.{ "diff", "--stat" });
    defer if (unstaged) |text| alloc.free(text);

    return .{
        .in_git_repo = in_git_repo,
        .text = try formatSnapshot(alloc, branch, status, log, staged, unstaged),
    };
}

fn buildGitArgv(alloc: Allocator, args: []const []const u8) !std.ArrayList([]const u8) {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.append(alloc, "--no-optional-locks");
    try argv.appendSlice(alloc, args);
    return argv;
}

pub fn isGitRepository(alloc: Allocator) bool {
    const result = runGit(alloc, &.{ "rev-parse", "--is-inside-work-tree" }) catch return false;
    defer if (result) |text| alloc.free(text);
    return if (result) |text| std.mem.eql(u8, text, "true") else false;
}

fn runGit(alloc: Allocator, args: []const []const u8) !?[]u8 {
    var argv = try buildGitArgv(alloc, args);
    defer argv.deinit(alloc);

    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv.items,
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

test "git argv: read-only commands disable optional locks" {
    var argv = try buildGitArgv(std.testing.allocator, &.{ "status", "--short", "--branch" });
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), argv.items.len);
    try std.testing.expectEqualStrings("git", argv.items[0]);
    try std.testing.expectEqualStrings("--no-optional-locks", argv.items[1]);
    try std.testing.expectEqualStrings("status", argv.items[2]);
    try std.testing.expectEqualStrings("--short", argv.items[3]);
    try std.testing.expectEqualStrings("--branch", argv.items[4]);
}

test "git repository detection treats allocation failure as unavailable" {
    var failing = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{ .fail_index = 0 });
    try std.testing.expect(!isGitRepository(failing.allocator()));
}

test "snapshot returns owned Git status text" {
    const state = try snapshot(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.find(u8, state.text, "Git snapshot") != null);
    try std.testing.expect(std.mem.find(u8, state.text, "Branch:") != null);
}
