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
//! With `FX_TEST_SUBAGENT_NEXT_HELD` and `FX_TEST_SUBAGENT_NEXT_RELEASE` set,
//! the slot of a work whose end hook has installed the child's next work
//! writes `<held>.<n>` for the n-th such install in the process, naming the
//! child, then waits until `<release>` or `<release>.<n>` exists, for at most
//! a minute, before it takes that work up. The next work is in the log and
//! has not begun, and a stop or close that lands now must take it, as one
//! that lands before it is installed drops the message that made it. An
//! inline test's hook is called after every end hook, with whether it
//! installed a next work.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_hold_ms = 60_000;

var holds = std.atomic.Value(u32).init(0);
var next_holds = std.atomic.Value(u32).init(0);

/// Test builds only: an inline test sets it to hold a stopped work's end, in
/// place of the file controls.
pub var test_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Test builds only: an inline test sets it to hold the slot of a work whose
/// end hook has returned, `next` saying whether it installed the child's next
/// work, in place of the file controls.
pub var test_hold_next: if (builtin.is_test) ?*const fn (child_id: []const u8, next: bool) void else void = if (builtin.is_test) null else {};

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

/// Whether the next work's install may be held, so the slot checks only when
/// a test asked.
pub fn nextArmed() bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) return test_hold_next != null;
    return io_mod.getenv("FX_TEST_SUBAGENT_NEXT_HELD") != null and io_mod.getenv("FX_TEST_SUBAGENT_NEXT_RELEASE") != null;
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
    const held = io_mod.getenv("FX_TEST_SUBAGENT_NEXT_HELD") orelse return;
    const release = io_mod.getenv("FX_TEST_SUBAGENT_NEXT_RELEASE") orelse return;
    const n = next_holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "installed_next child={s}", .{child_id}) catch return;
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

test "a test build holds the install of a next work only through its hook" {
    try std.testing.expect(!nextArmed());
    holdAfterEndHook("child", true);
    try std.testing.expectEqual(@as(u32, 0), next_holds.load(.seq_cst));
}
