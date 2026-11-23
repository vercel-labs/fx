//! Test controls for the slot of a subagent's work that has ended. With
//! `FX_TEST_SUBAGENT_PUBLISH_HELD` and `FX_TEST_SUBAGENT_PUBLISH_RELEASE`
//! set, the slot writes `<held>.<n>` for the n-th end in the process, naming
//! the child, once the host's end hook has returned, then waits until
//! `<release>` or `<release>.<n>` exists, for at most a minute, before it
//! takes its next work or publishes that it is done. The work has ended and
//! the host has chosen what follows, but the slot has not gone on, so a test
//! can send a stop or a close into that gap every time
//! (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a stop right after a
//! subagent's turn ended finds it not working" and "a close right after a
//! subagent's turn ended closes it as an idle one"). Only those tests set the
//! controls, so the libfx artifacts leave them out. A build that sets neither
//! control reads one environment variable per end and does nothing more.
//!
//! An inline test sets `test_hold` in place of the file controls; a test
//! build without it does nothing at all.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const end_test_controls = @import("end_test_controls.zig");

var holds = std.atomic.Value(u32).init(0);

/// Test builds only: an inline test sets it to hold a slot after its end.
pub var test_hold: if (builtin.is_test) ?*const fn (child_id: []const u8) void else void = if (builtin.is_test) null else {};

/// Called by the slot of `child_id` once the host's end hook has returned,
/// before the slot goes on to its next work or publishes its completion.
pub fn holdPublish(child_id: []const u8) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(child_id);
        return;
    }
    const held = io_mod.getenvAbsolutePath("FX_TEST_SUBAGENT_PUBLISH_HELD") orelse return;
    const release = io_mod.getenvAbsolutePath("FX_TEST_SUBAGENT_PUBLISH_RELEASE") orelse return;
    const n = holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
    var contents_buf: [256]u8 = undefined;
    const contents = std.mem.print(&contents_buf, "publish child={s}", .{child_id}) catch return;
    end_test_controls.writeMarker(marker, contents) catch return;
    const deadline = io_mod.milliTimestamp() + end_test_controls.max_hold_ms;
    while (!end_test_controls.pathExists(release) and !end_test_controls.pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}
