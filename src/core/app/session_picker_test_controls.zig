//! A test control for the session picker's initial catalog load. With
//! `FX_TEST_SESSION_PICKER_LOAD_RELEASE` set (and optionally
//! `FX_TEST_SESSION_PICKER_LOAD_HELD`), the background loader writes `<held>`
//! when set, then waits until `<release>` exists, `cancel_requested` becomes
//! true, or a minute passes before listing sessions. Only tests set the
//! controls, so test builds and libfx artifacts leave them out.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const debug_trace = @import("../shared/debug_trace.zig");
const hold_marker = @import("../shared/hold_marker.zig");
const io_mod = @import("../shared/io.zig");

const max_hold_ms = 60_000;

/// Called on the `SessionPickerLoad` background thread before listing sessions.
pub fn holdCatalogLoad(cancel_requested: *const std.atomic.Value(bool)) void {
    if (comptime build_options.libfx or builtin.is_test) return;
    const release = io_mod.getenvAbsolutePath("FX_TEST_SESSION_PICKER_LOAD_RELEASE") orelse return;
    if (io_mod.getenvAbsolutePath("FX_TEST_SESSION_PICKER_LOAD_HELD")) |held| {
        // A marker that cannot be written skips the hold; the test that set the
        // controls then fails on the missing marker.
        hold_marker.write(held, "session_picker_load held") catch return;
    }
    debug_trace.logf("core", "session picker load hold started", .{});
    const deadline = io_mod.milliTimestamp() + max_hold_ms;
    var reason: []const u8 = "timeout";
    while (io_mod.milliTimestamp() < deadline) {
        if (cancel_requested.load(.acquire)) {
            reason = "cancelled";
            break;
        }
        if (pathExists(release)) {
            reason = "released";
            break;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
    debug_trace.logf("core", "session picker load hold ended reason={s}", .{reason});
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

test "a test build skips the session picker load hold" {
    var cancel_requested = std.atomic.Value(bool).init(false);
    holdCatalogLoad(&cancel_requested);
}
