//! Test controls for the start of a subagent's work. With
//! `FX_TEST_SUBAGENT_START_HELD` and `FX_TEST_SUBAGENT_START_RELEASE` set, the
//! slot of a new work writes `<held>.<n>` for the n-th start in the process,
//! naming the child, then waits until `<release>` or `<release>.<n>` exists,
//! for at most a minute, before the work's worker attaches. A stop or a quit
//! cancels the work, which ends the wait, so a held start never holds them up. The parent's call
//! that started the work has answered by then and the work counts as running,
//! so a test can send a message before the turn begins every time
//! (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a message right after
//! starting a subagent joins its first task";
//! `tests/tla/drivers/subagent/stop-message.test.ts`).
//! `FX_TEST_SUBAGENT_START_WAIT_MS` shortens how long a message waits for such
//! a start before it goes to the subagent's next turn.
//! `FX_TEST_SUBAGENT_START_FAIL=<n>` makes the first n starts in the process
//! fail where the slot's thread would spawn, after the work is saved, so a test
//! can see what a failed start leaves behind
//! (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a subagent whose start
//! failed is idle and takes the next message"). Only those tests set the
//! controls, so the libfx artifacts leave them out.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_hold_ms = 60_000;

/// How long a message waits for a starting work's turn to begin before it
/// goes to the child's next turn. A start takes milliseconds; the limit only
/// keeps the parent's call from waiting on a start that never comes.
pub const default_wait_limit_ms: u64 = 10_000;

var holds = std.atomic.Value(u32).init(0);
var failed_starts = std.atomic.Value(u32).init(0);

/// Test builds only: an inline test sets it to hold a work's start, in place
/// of the file controls.
pub var test_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Test builds only: an inline test sets it to shorten the wait limit.
pub var test_wait_limit_ms: if (builtin.is_test) ?u64 else void = if (builtin.is_test) null else {};

/// Test builds only: while an inline test sets it, every start fails where its
/// thread would spawn.
pub var test_fail_spawn: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

/// Whether the start that is about to spawn its slot's thread fails instead.
pub fn spawnFails() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_fail_spawn;
    const raw = io_mod.getenv("FX_TEST_SUBAGENT_START_FAIL") orelse return false;
    const limit = std.fmt.parseInt(u32, raw, 10) catch return false;
    return failed_starts.fetchAdd(1, .seq_cst) < limit;
}

/// Whether a work's start may be held, so the slot checks only when a test
/// asked.
pub fn armed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold != null;
    return io_mod.getenv("FX_TEST_SUBAGENT_START_HELD") != null and io_mod.getenv("FX_TEST_SUBAGENT_START_RELEASE") != null;
}

/// Called by the slot of `child_id` once the work's turn is built, before its
/// worker attaches. `cancel` is the work's cancel flag.
pub fn holdStart(child_id: []const u8, cancel: *const std.atomic.Value(bool)) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(child_id);
        return;
    }
    const held = io_mod.getenv("FX_TEST_SUBAGENT_START_HELD") orelse return;
    const release = io_mod.getenv("FX_TEST_SUBAGENT_START_RELEASE") orelse return;
    const n = holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "start child={s}", .{child_id}) catch return;
    writeMarker(marker, contents) catch return;
    const deadline = io_mod.milliTimestamp() + max_hold_ms;
    while (!cancel.load(.seq_cst) and !pathExists(release) and !pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

/// How long a message waits for a starting work's turn to begin.
pub fn waitLimitMs() u64 {
    if (comptime build_options.libfx) return default_wait_limit_ms;
    if (builtin.is_test) return test_wait_limit_ms orelse default_wait_limit_ms;
    const raw = io_mod.getenv("FX_TEST_SUBAGENT_START_WAIT_MS") orelse return default_wait_limit_ms;
    return std.fmt.parseInt(u64, raw, 10) catch default_wait_limit_ms;
}

fn writeMarker(path: []const u8, contents: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .truncate = true,
        .permissions = private_file_permissions,
    });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), contents);
    try file.sync(io_mod.getIo());
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

test "a test build holds a work's start and sets the wait limit only through its hooks" {
    // Without a hook nothing is armed, a hold returns at once, and the file
    // controls are never read.
    try std.testing.expect(!armed());
    var cancel = std.atomic.Value(bool).init(false);
    holdStart("child", &cancel);
    try std.testing.expectEqual(@as(u32, 0), holds.load(.seq_cst));
    try std.testing.expectEqual(default_wait_limit_ms, waitLimitMs());
    test_wait_limit_ms = 25;
    defer test_wait_limit_ms = null;
    try std.testing.expectEqual(@as(u64, 25), waitLimitMs());
    // Starts fail only while a test asks, and never from the file controls.
    try std.testing.expect(!spawnFails());
    test_fail_spawn = true;
    defer test_fail_spawn = false;
    try std.testing.expect(spawnFails());
}
