//! A test control for the end of a subagent's work that a stop ended. With
//! `FX_TEST_SUBAGENT_END_HELD` and `FX_TEST_SUBAGENT_END_RELEASE` set, the
//! slot of a work that its parent or the user stopped writes `<held>.<n>` for
//! the n-th such end in the process, naming the child and who stopped it,
//! then waits until `<release>` or `<release>.<n>` exists, for at most a
//! minute, before it finishes the work. The stop has answered by then and the
//! work still counts as running, so a test can send a message in that gap
//! every time (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a message right
//! after a stop starts the subagent's next turn";
//! `tests/tla/drivers/subagent/stop-message.test.ts`). Only tests set the
//! controls, so the libfx artifacts leave them out.
//!
//! Every hold reads two paths from the environment and uses them only when
//! both are absolute (`holdFiles`): the file calls take no other kind, and a
//! relative path would otherwise crash fx or put a marker in the workspace.
//!
//! A second hold sits in the host, after it has told the owner of any work's
//! end and before it settles the child's busy flag (`holdBeforeSettle`). With
//! `FX_TEST_SUBAGENT_SETTLE_HELD` and `FX_TEST_SUBAGENT_SETTLE_RELEASE` set,
//! the n-th such end in the process writes `<held>.<n>` naming the child and
//! waits for `<release>` or `<release>.<n>`, for at most a minute. The owner
//! has been told by then and the child still counts as working, so a test can
//! start the owner's `wait` in that gap every time
//! (`tests/e2e/gateway-stream-lifecycle.test.ts` and
//! `tests/e2e/tui-host-switch.test.ts`, "a wait that starts as a subagent's
//! work ends with nothing to report still returns").
//!
//! A third hold sits in the host, after the end of a user's turn has cleared
//! the child's busy flag and before the end settles the child's close
//! (`holdBeforeCloseSettle`). Test builds only: no file control sets it.
//!
//! A fourth hold sits in the host, after it has finished a turn that ended
//! before its work opened, with the lock released, and before it settles the
//! child again (`holdInSettle`). Test builds only: no file control sets it.
//!
//! A note, not a hold, reaches a test from the host's `wait` once it has found
//! that something can still arrive and is about to block (`noteWaitBlocking`).
//! Test builds only: no file control sets it.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const hold_marker = @import("../shared/hold_marker.zig");

/// The longest any hold waits for its release file. Every seam in this folder
/// reads it from here.
pub const max_hold_ms = 60_000;

var holds = std.atomic.Value(u32).init(0);

/// Test builds only: an inline test sets it to hold a stopped work's end, in
/// place of the file controls.
pub var test_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Whether a stopped work's end may be held, so the slot reads who stopped
/// it only when a test asked.
pub fn armed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold != null;
    return holdFiles("FX_TEST_SUBAGENT_END_HELD", "FX_TEST_SUBAGENT_END_RELEASE") != null;
}

/// Called by the slot of `child_id` once a work that `by` stopped has ended,
/// before the slot finishes it. `by` is "parent" or "user".
pub fn holdStoppedEnd(child_id: []const u8, by: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(child_id);
        return;
    }
    const files = holdFiles("FX_TEST_SUBAGENT_END_HELD", "FX_TEST_SUBAGENT_END_RELEASE") orelse return;
    holdOnFiles(&holds, files, "stopped_end child={s} by={s}", .{ child_id, by });
}

var settle_holds = std.atomic.Value(u32).init(0);

/// Test builds only: an inline test sets it to hold the host before it
/// settles a child whose work ended, in place of the file controls.
pub var test_settle_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Whether the host may be held before it settles an ended work, so it
/// reads the controls only when a test asked.
pub fn settleArmed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_settle_hold != null;
    return holdFiles("FX_TEST_SUBAGENT_SETTLE_HELD", "FX_TEST_SUBAGENT_SETTLE_RELEASE") != null;
}

/// Called by the host for `child_id` once it has told the owner of a work's
/// end, before it clears the child's busy flag.
pub fn holdBeforeSettle(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_settle_hold) |hold| hold(child_id);
        return;
    }
    const files = holdFiles("FX_TEST_SUBAGENT_SETTLE_HELD", "FX_TEST_SUBAGENT_SETTLE_RELEASE") orelse return;
    holdOnFiles(&settle_holds, files, "settle child={s}", .{child_id});
}

/// Test builds only: an inline test sets it to hold a slot at the end of a
/// work that its turn has finished, where a stop or close can land while the
/// slot still keeps the messages the turn never took. It is called twice for
/// each work: with `recorded` false after the turn ended and before the slot
/// records the end, and with it true after the end is recorded and before the
/// host's end hook runs. No file control sets it.
pub var test_hold_run: if (builtin.is_test) ?*const fn (child_id: []const u8, recorded: bool) void else void = if (builtin.is_test) null else {};

/// Whether an inline test holds the slot there.
pub fn runArmed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold_run != null;
    return false;
}

/// Called by the slot of `child_id` at the two points `test_hold_run` names.
pub fn holdAfterRun(child_id: []const u8, recorded: bool) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold_run) |hold| hold(child_id, recorded);
    }
}

/// Test builds only: an inline test sets it to hold the host in a parent's stop
/// or close of a child, after the owner stopped the child's turn and before the
/// host reads what the stop dropped, so the slot's end can run first. No file
/// control sets it.
pub var test_hold_stop: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Called by the host for `child_id` in a parent's stop or close, once the
/// owner stopped the turn.
pub fn holdInStop(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold_stop) |hold| hold(child_id);
    }
}

/// Test builds only: an inline test sets it to hold the end of a user's turn
/// after the child's busy flag is clear and before the end settles the child's
/// close, so the test can land a close from another thread there. No file
/// control sets it.
pub var test_hold_close_settle: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Called by the host for `child_id` once the end of a user's turn has cleared
/// the child's busy flag, before the end settles the child's close.
pub fn holdBeforeCloseSettle(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold_close_settle) |hold| hold(child_id);
    }
}

/// Test builds only: an inline test sets it to learn when a `wait` has found
/// that something can still arrive and is about to block. No file control
/// sets it.
pub var test_wait_blocking: if (builtin.is_test) ?*const fn () void else void = if (builtin.is_test) null else {};

/// Called by the host when a `wait` has found that something can still
/// arrive, right before it blocks.
pub fn noteWaitBlocking() void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_wait_blocking) |note| note();
    }
}

/// Test builds only: an inline test sets it to hold the host after it has
/// finished a turn that ended before its work opened, with the lock released
/// and before it settles the child again, so a close or a turn can land in
/// that gap. No file control sets it.
pub var test_in_settle_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Whether an inline test holds the host after a turn's end, before it settles
/// the child again.
pub fn inSettleArmed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_in_settle_hold != null;
    return false;
}

/// Called by the host for `child_id` once it has finished a turn that ended
/// before its work opened, before it settles the child again.
pub fn holdInSettle(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_in_settle_hold) |hold| hold(child_id);
    }
}

/// The two paths of a hold's file controls.
pub const HoldFiles = struct { held: []const u8, release: []const u8 };

/// The paths that `held_var` and `release_var` name, or null unless both are
/// set to absolute paths. A hold with any other value is not armed.
pub fn holdFiles(held_var: []const u8, release_var: []const u8) ?HoldFiles {
    return usableHoldFiles(io_mod.getenv(held_var), io_mod.getenv(release_var));
}

fn usableHoldFiles(held: ?[]const u8, release: ?[]const u8) ?HoldFiles {
    return .{
        .held = io_mod.absolutePath(held) orelse return null,
        .release = io_mod.absolutePath(release) orelse return null,
    };
}

/// Writes `<held>.<n>` with the text `fmt` makes, for the n-th hold counted
/// in `counter`, then waits until `<release>` or `<release>.<n>` exists, for
/// at most `max_hold_ms`.
fn holdOnFiles(counter: *std.atomic.Value(u32), files: HoldFiles, comptime fmt: []const u8, args: anytype) void {
    const n = counter.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ files.held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ files.release, n }) catch return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, fmt, args) catch return;
    hold_marker.write(marker, contents) catch return;
    const deadline = io_mod.milliTimestamp() + max_hold_ms;
    while (!pathExists(files.release) and !pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

/// Whether a hold's release file exists. Every seam in this folder checks it
/// here.
pub fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

test "a test build holds a stopped work's end only through its hook" {
    // Without a hook nothing is armed, a hold returns at once, and the file
    // controls are never read.
    try std.testing.expect(!armed());
    holdStoppedEnd("child", "parent");
    try std.testing.expectEqual(@as(u32, 0), holds.load(.seq_cst));
}

test "a test build holds the host before it settles an ended work only through its hook" {
    try std.testing.expect(!settleArmed());
    holdBeforeSettle("child");
    try std.testing.expectEqual(@as(u32, 0), settle_holds.load(.seq_cst));
}

test "a test build holds the host after a turn ends and before it settles the child again only through its hook" {
    // Without a hook the host's call returns at once.
    try std.testing.expect(!inSettleArmed());
    holdInSettle("child");
}

test "a hold is armed only when both of its paths are absolute" {
    const files = usableHoldFiles("/tmp/held", "/tmp/release").?;
    try std.testing.expectEqualStrings("/tmp/held", files.held);
    try std.testing.expectEqualStrings("/tmp/release", files.release);
    try std.testing.expect(usableHoldFiles(null, "/tmp/release") == null);
    try std.testing.expect(usableHoldFiles("/tmp/held", null) == null);
    try std.testing.expect(usableHoldFiles("held", "/tmp/release") == null);
    try std.testing.expect(usableHoldFiles("/tmp/held", "release") == null);
    try std.testing.expect(usableHoldFiles("./held", "../release") == null);
    try std.testing.expect(usableHoldFiles("", "") == null);
}

test "a test build holds a parent's stop only through its hook" {
    // Without a hook the host's call returns at once.
    try std.testing.expect(test_hold_stop == null);
    holdInStop("child");
}

test "a test build holds the end of a user's turn before it settles a close only through its hook" {
    // Without a hook the host's call returns at once.
    try std.testing.expect(test_hold_close_settle == null);
    holdBeforeCloseSettle("child");
}

test "a test build notes a blocking wait only through its hook" {
    // Without a hook the host's call returns at once.
    try std.testing.expect(test_wait_blocking == null);
    noteWaitBlocking();

    const Notes = struct {
        var count: usize = 0;
        fn note() void {
            count += 1;
        }
    };
    Notes.count = 0;
    test_wait_blocking = Notes.note;
    defer test_wait_blocking = null;
    noteWaitBlocking();
    try std.testing.expectEqual(@as(usize, 1), Notes.count);
}
