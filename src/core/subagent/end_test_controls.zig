//! Test controls for the end of a subagent's work. Each holds the slot at one
//! point of its end, through the file protocol in `file_hold.zig`, so a test
//! can land a stop or close where it could not land before. Only those tests
//! set the controls, so the libfx artifacts leave them out. An inline test
//! sets a hook in place of the files.
//!
//! - `FX_TEST_SUBAGENT_END_HELD` and `FX_TEST_SUBAGENT_END_RELEASE` hold the
//!   slot of a work that its parent or the user stopped, before it finishes
//!   the work. The stop has answered by then and the work still counts as
//!   running, so a test can send a message in that gap every time
//!   (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a message right after a
//!   stop starts the subagent's next turn";
//!   `tests/tla/drivers/subagent/stop-message.test.ts`).
//! - `FX_TEST_SUBAGENT_RUN_HELD` and `FX_TEST_SUBAGENT_RUN_RELEASE` hold the
//!   slot of a work whose turn ended and left parent messages unread, which
//!   the slot keeps for the host. The slot has not finished the work, so a
//!   stop or close that lands now meets the kept messages.
//! - `FX_TEST_SUBAGENT_NEXT_HELD` and `FX_TEST_SUBAGENT_NEXT_RELEASE` hold the
//!   slot of a work whose end hook has installed the child's next work,
//!   before it takes that work up. The next work is in the log and has not
//!   begun, and a stop or close that lands now must take it, as one that
//!   lands before it is installed drops the message that made it. An inline
//!   test's hook is called after every end hook, with whether it installed a
//!   next work.
//!
//! An inline test can also hold the slot between its finishing a work and
//! calling the end hook (`test_hold_hook`), which has no file control.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const file_hold = @import("file_hold.zig");

var stopped_hold = file_hold.Hold{ .held_env = "FX_TEST_SUBAGENT_END_HELD", .release_env = "FX_TEST_SUBAGENT_END_RELEASE" };
var run_hold = file_hold.Hold{ .held_env = "FX_TEST_SUBAGENT_RUN_HELD", .release_env = "FX_TEST_SUBAGENT_RUN_RELEASE" };
var next_hold = file_hold.Hold{ .held_env = "FX_TEST_SUBAGENT_NEXT_HELD", .release_env = "FX_TEST_SUBAGENT_NEXT_RELEASE" };

/// Test builds only: an inline test sets it to hold a stopped work's end, in
/// place of the file controls.
pub var test_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Test builds only: an inline test sets it to hold the slot of a work whose
/// turn ended with parent messages unread.
pub var test_hold_run: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Test builds only: an inline test sets it to hold the slot of a work that
/// is finished, before it calls the end hook.
pub var test_hold_hook: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Test builds only: an inline test sets it to hold the slot of a work whose
/// end hook has returned, `next` saying whether it installed the child's next
/// work, in place of the file controls.
pub var test_hold_next: if (builtin.is_test) ?*const fn (child_id: []const u8, next: bool) void else void = if (builtin.is_test) null else {};

/// Whether a stopped work's end may be held, so the slot reads who stopped
/// it only when a test asked.
pub fn armed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold != null;
    return stopped_hold.armed();
}

/// Called by the slot of `child_id` once a work that `by` stopped has ended,
/// before the slot finishes it. `by` is "parent" or "user".
pub fn holdStoppedEnd(child_id: []const u8, by: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(child_id);
        return;
    }
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "stopped_end child={s} by={s}", .{ child_id, by }) catch return;
    stopped_hold.wait(contents, null);
}

/// Whether a work's end may be held where its turn left messages unread, so
/// the slot looks at its kept messages only when a test asked.
pub fn runArmed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold_run != null;
    return run_hold.armed();
}

/// Called by the slot of `child_id` once its turn ended and left `unread`
/// parent messages that the slot kept, before the slot finishes the work.
pub fn holdAfterRun(child_id: []const u8, unread: usize) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold_run) |hold| hold(child_id);
        return;
    }
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "ended_with_unread child={s} unread={d}", .{ child_id, unread }) catch return;
    run_hold.wait(contents, null);
}

/// Called by the slot of `child_id` once the work is finished, before the end
/// hook runs. An inline test's hook only.
pub fn holdBeforeEndHook(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold_hook) |hold| hold(child_id);
    }
}

/// Whether the slot may be held after a work's end hook, so it checks only
/// when a test asked.
pub fn nextArmed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold_next != null;
    return next_hold.armed();
}

/// Called by the slot of `child_id` once its end hook has returned, before
/// the slot takes up the child's next work. Only a hook that installed one
/// holds a slot through the file controls.
pub fn holdAfterEndHook(child_id: []const u8, next: bool) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold_next) |hold| hold(child_id, next);
        return;
    }
    if (!next) return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "installed_next child={s}", .{child_id}) catch return;
    next_hold.wait(contents, null);
}

test "a test build holds a stopped work's end only through its hook" {
    // Without a hook nothing is armed, a hold returns at once, and the file
    // controls are never read.
    try std.testing.expect(!armed());
    holdStoppedEnd("child", "parent");
    try std.testing.expectEqual(@as(u32, 0), stopped_hold.count.load(.seq_cst));
}

test "a test build holds a work's end around its hook only through hooks" {
    try std.testing.expect(!runArmed());
    try std.testing.expect(!nextArmed());
    holdAfterRun("child", 1);
    holdBeforeEndHook("child");
    holdAfterEndHook("child", true);
    try std.testing.expectEqual(@as(u32, 0), run_hold.count.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 0), next_hold.count.load(.seq_cst));
}
