//! A test control for writes of one session that run at the same time. With
//! `FX_TEST_SESSION_WRITE_HELD` and `FX_TEST_SESSION_WRITE_RELEASE` set, a
//! write that has compactor records due (D50) writes `<held>.<n>` for the
//! n-th such write in the process, holding how many records it took, then
//! waits until `<release>` or
//! `<release>.<n>` exists, for at most a minute. A test then knows how many
//! writes took the due records, and when to let them go
//! (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a compaction commit while
//! a subagent finishes lists each record once";
//! `tests/tla/drivers/session/write.test.ts`). Only those tests set the
//! controls, so the libfx artifacts leave them out.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_hold_ms = 60_000;

var holds = std.atomic.Value(u32).init(0);

/// Test builds only: an inline test sets it to hold a write where it took
/// its due records, in place of the file controls.
pub var test_hold: if (builtin.is_test) ?*const fn (count: usize) void else void = if (builtin.is_test) null else {};

/// Called by a write that took `count` due records, before it appends them.
pub fn holdDueRecords(count: usize) void {
    if (comptime build_options.libfx) return;
    if (builtin.is_test) {
        if (test_hold) |hold| hold(count);
        return;
    }
    const held = io_mod.getenv("FX_TEST_SESSION_WRITE_HELD") orelse return;
    const release = io_mod.getenv("FX_TEST_SESSION_WRITE_RELEASE") orelse return;
    const n = holds.fetchAdd(1, .seq_cst) + 1;
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
    var count_buf: [32]u8 = undefined;
    const contents = std.mem.print(&count_buf, "records_due count={d}", .{count}) catch return;
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

test "a test build holds only through its hook" {
    // Without a hook a hold returns at once, and the file controls are
    // never read.
    holdDueRecords(3);
    try std.testing.expectEqual(@as(u32, 0), holds.load(.seq_cst));
}
