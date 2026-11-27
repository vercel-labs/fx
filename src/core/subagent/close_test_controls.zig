//! Test controls for the write of a closing subagent's close
//! (`Runtime.settleClose`). With `FX_TEST_SUBAGENT_CLOSE_HELD` and
//! `FX_TEST_SUBAGENT_CLOSE_RELEASE` set, the thread that settles a close
//! writes `<held>.<n>` for the n-th close in the process, naming the child,
//! then waits until `<release>` or `<release>.<n>` exists, for at most a
//! minute, before it writes the close. The child is closing and the registry
//! still holds it, so a test can look at the list, the trace, and message
//! admission in that gap every time
//! (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a message to a subagent
//! whose close is not written yet is refused"). Only tests set the
//! controls, so the libfx artifacts leave them out. A build that sets neither
//! control reads one environment variable per close and does nothing more.
//!
//! An inline test sets `test_hold` and `test_write_error` in place of the
//! file controls; a test build without them does nothing at all.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const end_test_controls = @import("end_test_controls.zig");
const hold_marker = @import("../shared/hold_marker.zig");

var holds = std.atomic.Value(u32).init(0);

/// Test builds only: an inline test sets it to hold a close's write.
pub var test_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Test builds only: an inline test sets it to make each close's write fail
/// with this error, as a registry that refuses it would.
pub var test_write_error: if (builtin.is_test) ?anyerror else void = if (builtin.is_test) null else {};

/// Called by the thread that settles the close of `child_id`, after the child
/// is marked as being written and before the registry's lock is taken.
pub fn holdWrite(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(child_id);
        return;
    }
    const held = io_mod.getenvAbsolutePath("FX_TEST_SUBAGENT_CLOSE_HELD") orelse return;
    const release = io_mod.getenvAbsolutePath("FX_TEST_SUBAGENT_CLOSE_RELEASE") orelse return;
    const n = holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "close_write child={s}", .{child_id}) catch return;
    hold_marker.write(marker, contents) catch return;
    const deadline = io_mod.milliTimestamp() + end_test_controls.max_hold_ms;
    while (!end_test_controls.pathExists(release) and !end_test_controls.pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

/// The error an inline test asked each close's write to fail with, or null.
pub fn failedWrite() ?anyerror {
    if (comptime build_options.libfx) return null;
    if (builtin.is_test) return test_write_error;
    return null;
}
