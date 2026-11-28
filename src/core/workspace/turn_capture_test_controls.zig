//! A test control for a turn's start capture, which runs beside the turn's
//! first request (D98). With `FX_TEST_WORKSPACE_CAPTURE_START_HELD` and
//! `FX_TEST_WORKSPACE_CAPTURE_START_RELEASE` set, a start capture writes
//! `<held>`, then waits until `<release>` exists, for at most a minute,
//! before it captures. A test then knows the capture cannot be saved until
//! it lets it go (`tests/e2e/sessions.test.ts`, "fx ask sends the turn's
//! request while its start capture runs, and saves that capture before the
//! tool writes, with experimental.workspace_capture"). Only tests set the
//! controls, so test builds and the libfx artifacts leave them out.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const hold_marker = @import("../shared/hold_marker.zig");

const max_hold_ms = 60_000;

/// Called by a turn's start capture before it captures.
pub fn holdStartCapture() void {
    if (comptime build_options.libfx or builtin.is_test) return;
    const held = io_mod.getenvAbsolutePath("FX_TEST_WORKSPACE_CAPTURE_START_HELD") orelse return;
    const release = io_mod.getenvAbsolutePath("FX_TEST_WORKSPACE_CAPTURE_START_RELEASE") orelse return;
    // A marker that cannot be written skips the hold; the test that set the
    // controls then fails on the missing marker.
    hold_marker.write(held, "start_capture held") catch return;
    const deadline = io_mod.milliTimestamp() + max_hold_ms;
    while (!pathExists(release) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}
