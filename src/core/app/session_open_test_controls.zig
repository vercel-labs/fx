//! A test control for the session picker's open, which runs off the UI
//! thread (`SessionPickerOpen`). With `FX_TEST_SESSION_OPEN_HELD` and
//! `FX_TEST_SESSION_OPEN_RELEASE` set, the n-th open in the process writes
//! `<held>.<n>` once it holds the session open, then waits until
//! `<release>` or `<release>.<n>` exists, or the open is cancelled, for at
//! most a minute. A test then knows the row shows its loading state, and
//! when Esc lands with the session's lock held (`tests/e2e/tui-resume.test.ts`,
//! "Enter on a slow session shows Opening… on its row"). Only tests set the
//! controls, so test builds and the libfx artifacts leave them out.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const hold_marker = @import("../shared/hold_marker.zig");

const max_hold_ms = 60_000;

var holds = std.atomic.Value(u32).init(0);

/// Called by the open's worker once the session is open and decoded.
pub fn holdOpen(cancel: *const std.atomic.Value(bool)) void {
    if (comptime build_options.libfx or builtin.is_test) return;
    const held = io_mod.getenvAbsolutePath("FX_TEST_SESSION_OPEN_HELD") orelse return;
    const release = io_mod.getenvAbsolutePath("FX_TEST_SESSION_OPEN_RELEASE") orelse return;
    const n = holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
    // A marker that cannot be written skips the hold; the test that set the
    // controls then fails on the missing marker.
    hold_marker.write(marker, "session_open held") catch return;
    const deadline = io_mod.milliTimestamp() + max_hold_ms;
    while (!pathExists(release) and !pathExists(own_release) and
        !cancel.load(.acquire) and io_mod.milliTimestamp() < deadline)
    {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}
