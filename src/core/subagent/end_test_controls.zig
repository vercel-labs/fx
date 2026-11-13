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
//! - `FX_TEST_SUBAGENT_SETTLE_HELD` and `FX_TEST_SUBAGENT_SETTLE_RELEASE` hold
//!   the host after it has told the owner of a work's end and before it clears
//!   the child's busy flag and settles a close (`holdBeforeSettle`). The owner
//!   has been told by then and the child still counts as working, so a test
//!   can start the owner's `wait` in that gap every time
//!   (`tests/e2e/gateway-stream-lifecycle.test.ts` and
//!   `tests/e2e/tui-host-switch.test.ts`, "a wait that starts as a subagent's
//!   work ends with nothing to report still returns").
//!
//! `FX_TEST_SUBAGENT_USER_STOP` names a request file. While a slot is held at
//! the run or next-work hold, the hold takes that file when it appears, which
//! is the user's Esc on a turn of the subagent landing while the slot is held:
//! the host stops the child as the app's `noteUserStop` does
//! (`Runtime.userStopped`), and the hold goes on waiting. The app cannot press
//! Esc in `fx ask`, and `tests/tla/drivers/subagent/stop-message.test.ts`
//! walks that stop through the real binary.
//!
//! An inline test can also hold the slot between its finishing a work and
//! calling the end hook (`test_hold_hook`), which has no file control.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const file_hold = @import("file_hold.zig");
const io_mod = @import("../shared/io.zig");

var stopped_hold = file_hold.Hold{ .held_env = "FX_TEST_SUBAGENT_END_HELD", .release_env = "FX_TEST_SUBAGENT_END_RELEASE" };
var run_hold = file_hold.Hold{ .held_env = "FX_TEST_SUBAGENT_RUN_HELD", .release_env = "FX_TEST_SUBAGENT_RUN_RELEASE" };
var next_hold = file_hold.Hold{ .held_env = "FX_TEST_SUBAGENT_NEXT_HELD", .release_env = "FX_TEST_SUBAGENT_NEXT_RELEASE" };
var settle_hold = file_hold.Hold{ .held_env = "FX_TEST_SUBAGENT_SETTLE_HELD", .release_env = "FX_TEST_SUBAGENT_SETTLE_RELEASE" };

/// The host the user-stop control acts through: `stop_fn` stops a child of
/// `context` as the app's `noteUserStop` does. A host's owner keeps its own
/// (`Owner.user_stop_hook`) and passes it to the holds of its slots, so hosts
/// never share one and a normal run sets nothing global.
pub const UserStopHook = struct {
    context: *anyopaque,
    stop_fn: *const fn (context: *anyopaque, child_id: []const u8) void,
};

/// What a held slot of `child_id` does on each turn of its wait: when the
/// request file `FX_TEST_SUBAGENT_USER_STOP` names appears, it is the user's
/// Esc on a turn of the child, and the host stops the child through `hook`.
const UserStopPoll = struct {
    hook: UserStopHook,
    child_id: []const u8,

    fn poll(raw: *anyopaque) void {
        const self: *UserStopPoll = @ptrCast(@alignCast(raw));
        const path = io_mod.getenv("FX_TEST_SUBAGENT_USER_STOP") orelse return;
        if (!file_hold.takeRequest(path)) return;
        self.hook.stop_fn(self.hook.context, self.child_id);
    }
};

/// The poll of a hold at `child_id`'s slot, in `state`, or none when its host
/// has no user-stop hook.
fn userStopPoll(state: *UserStopPoll, hook: ?UserStopHook, child_id: []const u8) ?file_hold.Poll {
    const own = hook orelse return null;
    state.* = .{ .hook = own, .child_id = child_id };
    return .{ .context = state, .func = UserStopPoll.poll };
}

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
    stopped_hold.wait(contents, null, null);
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
/// `hook` is its host's user-stop hook.
pub fn holdAfterRun(child_id: []const u8, unread: usize, hook: ?UserStopHook) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold_run) |hold| hold(child_id);
        return;
    }
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "ended_with_unread child={s} unread={d}", .{ child_id, unread }) catch return;
    var poll: UserStopPoll = undefined;
    run_hold.wait(contents, null, userStopPoll(&poll, hook, child_id));
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
/// holds a slot through the file controls. `hook` is its host's user-stop
/// hook.
pub fn holdAfterEndHook(child_id: []const u8, next: bool, hook: ?UserStopHook) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold_next) |hold| hold(child_id, next);
        return;
    }
    if (!next) return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "installed_next child={s}", .{child_id}) catch return;
    var poll: UserStopPoll = undefined;
    next_hold.wait(contents, null, userStopPoll(&poll, hook, child_id));
}

/// Test builds only: an inline test sets it to hold the host before it
/// settles a child whose work ended, in place of the file controls.
pub var test_settle_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Whether the host may be held before it settles an ended work, so it
/// reads the controls only when a test asked.
pub fn settleArmed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_settle_hold != null;
    return settle_hold.armed();
}

/// Called by the host for `child_id` once it has told the owner of a work's
/// end, before it clears the child's busy flag.
pub fn holdBeforeSettle(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_settle_hold) |hold| hold(child_id);
        return;
    }
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "settle child={s}", .{child_id}) catch return;
    settle_hold.wait(contents, null, null);
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
    holdAfterRun("child", 1, null);
    holdBeforeEndHook("child");
    holdAfterEndHook("child", true, null);
    try std.testing.expectEqual(@as(u32, 0), run_hold.count.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 0), next_hold.count.load(.seq_cst));
}

test "the end holds and the user-stop request ignore variables that are empty or not absolute" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    io_mod.setEnvironMap(&environ);
    defer io_mod.resetEnvironForTest();
    for ([_][]const u8{ "relative/path", "./path", "" }) |value| {
        for ([_][]const u8{
            "FX_TEST_SUBAGENT_END_HELD",    "FX_TEST_SUBAGENT_END_RELEASE",
            "FX_TEST_SUBAGENT_RUN_HELD",    "FX_TEST_SUBAGENT_RUN_RELEASE",
            "FX_TEST_SUBAGENT_NEXT_HELD",   "FX_TEST_SUBAGENT_NEXT_RELEASE",
            "FX_TEST_SUBAGENT_SETTLE_HELD", "FX_TEST_SUBAGENT_SETTLE_RELEASE",
            "FX_TEST_SUBAGENT_USER_STOP",
        }) |name| try environ.put(name, value);
        const Seen = struct {
            var stops: u32 = 0;
            fn stop(_: *anyopaque, _: []const u8) void {
                stops += 1;
            }
        };
        var context: u8 = 0;
        const hook: UserStopHook = .{ .context = &context, .stop_fn = Seen.stop };
        var state: UserStopPoll = undefined;
        for ([_]*file_hold.Hold{ &stopped_hold, &run_hold, &next_hold, &settle_hold }) |hold| {
            try std.testing.expect(!hold.armed());
            hold.wait("child=none", null, userStopPoll(&state, hook, "child"));
            try std.testing.expectEqual(@as(u32, 0), hold.count.load(.seq_cst));
        }
        UserStopPoll.poll(&state);
        try std.testing.expectEqual(@as(u32, 0), Seen.stops);
    }
}

test "a test build holds the host before it settles an ended work only through its hook" {
    // Without a hook nothing is armed, a hold returns at once, and the file
    // controls are never read.
    try std.testing.expect(!settleArmed());
    holdBeforeSettle("child");
    try std.testing.expectEqual(@as(u32, 0), settle_hold.count.load(.seq_cst));
}

test "a hold is armed only when both of its paths are absolute" {
    try std.testing.expectEqualStrings("/tmp/held", file_hold.usablePath("/tmp/held").?);
    try std.testing.expect(file_hold.usablePath(null) == null);
    try std.testing.expect(file_hold.usablePath("held") == null);
    try std.testing.expect(file_hold.usablePath("./held") == null);
    try std.testing.expect(file_hold.usablePath("../release") == null);
    try std.testing.expect(file_hold.usablePath("") == null);
}
