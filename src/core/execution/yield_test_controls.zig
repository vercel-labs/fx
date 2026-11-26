//! A test control for the timed yield of a captured run. With
//! `FX_TEST_SHELL_YIELD_HELD` and `FX_TEST_SHELL_YIELD_RELEASE` set, a run
//! whose yield time has passed writes `<held>`, then waits until `<release>`
//! exists, for at most a minute, before it returns its command running. A
//! test then knows the command's row cannot change until it lets the yield go
//! (`tests/e2e/tui-gateway-stream-lifecycle.test.ts`, "multiline steering
//! survives retained history recovery after tool completion"). Only that test
//! sets the controls, so the libfx artifacts leave them out.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_hold_ms = 60_000;

/// Test builds only: an inline test sets it to hold a run's timed yield, in
/// place of the file controls.
pub var test_hold: if (builtin.is_test) ?*const fn () void else void = if (builtin.is_test) null else {};

/// Called by a captured run once its yield time has passed, before it
/// returns its command running.
pub fn holdTimedYield() void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold();
        return;
    }
    const held = io_mod.getenvAbsolutePath("FX_TEST_SHELL_YIELD_HELD") orelse return;
    const release = io_mod.getenvAbsolutePath("FX_TEST_SHELL_YIELD_RELEASE") orelse return;
    // A marker that cannot be written skips the hold; the test that set the
    // controls then fails on the missing marker.
    writeMarker(held) catch return;
    // The release file is the only signal a test can send this process, so
    // the hold polls for it, as the other test holds do.
    const deadline = io_mod.milliTimestamp() + max_hold_ms;
    while (!pathExists(release) and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn writeMarker(path: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .truncate = true,
        .permissions = private_file_permissions,
    });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "timed_yield held");
    try file.sync(io_mod.getIo());
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

test "a test build holds a run's timed yield only through its hook" {
    // Without a hook a hold returns at once, and the file controls are
    // never read.
    try std.testing.expect(test_hold == null);
    holdTimedYield();
}
