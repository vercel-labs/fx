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
const file_hold = @import("file_hold.zig");

/// How long a message waits for a starting work's turn to begin before it
/// goes to the child's next turn. A start takes milliseconds; the limit only
/// keeps the parent's call from waiting on a start that never comes.
pub const default_wait_limit_ms: u64 = 10_000;

var start_hold = file_hold.Hold{ .held_env = "FX_TEST_SUBAGENT_START_HELD", .release_env = "FX_TEST_SUBAGENT_START_RELEASE" };
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

/// Test builds only: an inline test sets it to make the next works fail to
/// bind to their agent, before their workers attach.
pub var test_fail_bind: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

/// Whether a work fails to bind to its agent. No file control sets it, so
/// only an inline test fails a bind.
pub fn bindFails() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_fail_bind;
    return false;
}

/// Whether a work's start may be held, so the slot checks only when a test
/// asked.
pub fn armed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold != null;
    return start_hold.armed();
}

/// Called by the slot of `child_id` once the work's turn is built, before its
/// worker attaches. `cancel` is the work's cancel flag.
pub fn holdStart(child_id: []const u8, cancel: *const std.atomic.Value(bool)) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(child_id);
        return;
    }
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "start child={s}", .{child_id}) catch return;
    start_hold.wait(contents, cancel, null);
}

/// How long a message waits for a starting work's turn to begin.
pub fn waitLimitMs() u64 {
    if (comptime build_options.libfx) return default_wait_limit_ms;
    if (builtin.is_test) return test_wait_limit_ms orelse default_wait_limit_ms;
    const raw = io_mod.getenv("FX_TEST_SUBAGENT_START_WAIT_MS") orelse return default_wait_limit_ms;
    return std.fmt.parseInt(u64, raw, 10) catch default_wait_limit_ms;
}

test "a test build holds a work's start and sets the wait limit only through its hooks" {
    // Without a hook nothing is armed, a hold returns at once, and the file
    // controls are never read.
    try std.testing.expect(!armed());
    var cancel = std.atomic.Value(bool).init(false);
    holdStart("child", &cancel);
    try std.testing.expectEqual(@as(u32, 0), start_hold.count.load(.seq_cst));
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

test "the start hold ignores variables that are empty or not absolute" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    io_mod.setEnvironMap(&environ);
    defer io_mod.resetEnvironForTest();
    var cancel = std.atomic.Value(bool).init(false);
    for ([_][]const u8{ "relative/path", "./path", "" }) |value| {
        try environ.put("FX_TEST_SUBAGENT_START_HELD", value);
        try environ.put("FX_TEST_SUBAGENT_START_RELEASE", value);
        try std.testing.expect(!start_hold.armed());
        start_hold.wait("child=none", &cancel, null);
        try std.testing.expectEqual(@as(u32, 0), start_hold.count.load(.seq_cst));
    }
}
