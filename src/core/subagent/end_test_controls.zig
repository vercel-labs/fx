//! A test control for the end of a subagent's work that a stop ended. With
//! `FX_TEST_SUBAGENT_END_HELD` and `FX_TEST_SUBAGENT_END_RELEASE` set, the
//! slot of a work that its parent or the user stopped writes `<held>.<n>` for
//! the n-th such end in the process, naming the child and who stopped it,
//! then waits until `<release>` or `<release>.<n>` exists, for at most a
//! minute, before it finishes the work. The stop has answered by then and the
//! work still counts as running, so a test can send a message in that gap
//! every time (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a message right
//! after a stop starts the subagent's next turn";
//! `tests/tla/drivers/subagent/stop-message.test.ts`). Only those tests set
//! the controls, so the libfx artifacts leave them out.
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
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_hold_ms = 60_000;

var holds = std.atomic.Value(u32).init(0);

/// Test builds only: an inline test sets it to hold a stopped work's end, in
/// place of the file controls.
pub var test_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Whether a stopped work's end may be held, so the slot reads who stopped
/// it only when a test asked.
pub fn armed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold != null;
    return io_mod.getenv("FX_TEST_SUBAGENT_END_HELD") != null and io_mod.getenv("FX_TEST_SUBAGENT_END_RELEASE") != null;
}

/// Called by the slot of `child_id` once a work that `by` stopped has ended,
/// before the slot finishes it. `by` is "parent" or "user".
pub fn holdStoppedEnd(child_id: []const u8, by: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(child_id);
        return;
    }
    const held = io_mod.getenv("FX_TEST_SUBAGENT_END_HELD") orelse return;
    const release = io_mod.getenv("FX_TEST_SUBAGENT_END_RELEASE") orelse return;
    const n = holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "stopped_end child={s} by={s}", .{ child_id, by }) catch return;
    writeMarker(marker, contents) catch return;
    const deadline = io_mod.milliTimestamp() + max_hold_ms;
    while (!pathExists(release) and !pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
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
    return io_mod.getenv("FX_TEST_SUBAGENT_SETTLE_HELD") != null and io_mod.getenv("FX_TEST_SUBAGENT_SETTLE_RELEASE") != null;
}

/// Called by the host for `child_id` once it has told the owner of a work's
/// end, before it clears the child's busy flag.
pub fn holdBeforeSettle(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_settle_hold) |hold| hold(child_id);
        return;
    }
    const held = io_mod.getenv("FX_TEST_SUBAGENT_SETTLE_HELD") orelse return;
    const release = io_mod.getenv("FX_TEST_SUBAGENT_SETTLE_RELEASE") orelse return;
    const n = settle_holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "settle child={s}", .{child_id}) catch return;
    writeMarker(marker, contents) catch return;
    const deadline = io_mod.milliTimestamp() + max_hold_ms;
    while (!pathExists(release) and !pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
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
