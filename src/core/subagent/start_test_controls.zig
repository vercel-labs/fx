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
//! failed is idle and takes the next message"). Only tests set the
//! controls, so the libfx artifacts leave them out.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const end_test_controls = @import("end_test_controls.zig");
const hold_marker = @import("../shared/hold_marker.zig");

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

/// Test builds only: while an inline test sets it, the host cannot save a
/// waiting message as its subagent's next work, as when the registry cannot be
/// written. No file control sets it.
pub var test_fail_next_work: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

/// Whether the waiting message that is about to be saved as a subagent's next
/// work fails to be saved instead.
pub fn nextWorkFails() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_fail_next_work;
    return false;
}

/// Test builds only: an inline test sets it to the index of a leftover message
/// that the host cannot queue again, as when it runs out of memory. No file
/// control sets it.
pub var test_fail_leftover_at: if (builtin.is_test) ?usize else void = if (builtin.is_test) null else {};

/// Whether the leftover at `index` of an ended work fails to be queued again.
pub fn leftoverInsertFails(index: usize) bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return if (test_fail_leftover_at) |at| at == index else false;
    return false;
}

/// Test builds only: an inline test sets it to run code where a waiting
/// message's failed start has been ended and its report is not yet built, as a
/// close of the child can land there.
pub var test_failed_start_ended: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Called by `Runtime.endUserWork` between the end of a waiting message's
/// failed start and the building of its report.
pub fn failedStartEnded(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_failed_start_ended) |hook| hook(child_id);
    }
}

/// Whether a work's start may be held, so the slot checks only when a test
/// asked.
pub fn armed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold != null;
    return end_test_controls.holdFiles("FX_TEST_SUBAGENT_START_HELD", "FX_TEST_SUBAGENT_START_RELEASE") != null;
}

/// Called by the slot of `child_id` once the work's turn is built, before its
/// worker attaches. `cancel` is the work's cancel flag.
pub fn holdStart(child_id: []const u8, cancel: *const std.atomic.Value(bool)) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(child_id);
        return;
    }
    const files = end_test_controls.holdFiles("FX_TEST_SUBAGENT_START_HELD", "FX_TEST_SUBAGENT_START_RELEASE") orelse return;
    const n = holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ files.held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ files.release, n }) catch return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "start child={s}", .{child_id}) catch return;
    hold_marker.write(marker, contents) catch return;
    const deadline = io_mod.milliTimestamp() + end_test_controls.max_hold_ms;
    while (!cancel.load(.seq_cst) and !end_test_controls.pathExists(files.release) and !end_test_controls.pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
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
    // Without a hook a failed start's report is built at once.
    try std.testing.expect(test_failed_start_ended == null);
    failedStartEnded("child");
    // Starts fail only while a test asks, and never from the file controls.
    try std.testing.expect(!spawnFails());
    test_fail_spawn = true;
    defer test_fail_spawn = false;
    try std.testing.expect(spawnFails());
}

test "a test build fails the save of a waiting message's work only through its hook" {
    // Without a hook the save is not failed.
    try std.testing.expect(!nextWorkFails());
    test_fail_next_work = true;
    defer test_fail_next_work = false;
    try std.testing.expect(nextWorkFails());
}

test "a test build fails the queueing of a leftover message only through its hook" {
    // Without a hook no leftover fails to be queued, and the hook names one index.
    try std.testing.expect(!leftoverInsertFails(0));
    test_fail_leftover_at = 1;
    defer test_fail_leftover_at = null;
    try std.testing.expect(!leftoverInsertFails(0));
    try std.testing.expect(leftoverInsertFails(1));
}
