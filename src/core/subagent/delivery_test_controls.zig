//! A test control for the main loop's delivery of a subagent's report to the
//! agent that owns its host (`deliverReports` in
//! `src/core/app/app_agents_runtime.zig`). With
//! `FX_TEST_REPORT_DELIVERY_HELD` and `FX_TEST_REPORT_DELIVERY_RELEASE` set,
//! the first pass that finds a report waiting in the hand-off writes
//! `<held>.<n>` for the n-th such hold in the process, naming the child, and
//! leaves the waiting reports where they are, pass after pass, until
//! `<release>` or `<release>.<n>` exists, for at most a minute. The host has
//! queued the report and the agent's worker has not seen it, so a test can
//! end the agent's step in that gap every time
//! (`tests/e2e/gateway-stream-lifecycle.test.ts`, "a report that waits in the
//! main loop's hand-off as an empty reply ends takes the nudge's place").
//! Only that test sets the controls, so the libfx artifacts leave them out.
//! Unlike the other holds, this one never blocks: the main loop keeps running
//! while it defers.
//!
//! An inline test sets `test_defer` in place of the file controls; a test
//! build without it does nothing at all.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const end_test_controls = @import("end_test_controls.zig");

/// The hold that now defers the delivery. Only the main loop calls
/// `deferred`, so neither it nor `holds` needs a lock.
const Hold = struct { n: u32, deadline_ms: i64 };
var active: ?Hold = null;
var holds: u32 = 0;

/// Test builds only: an inline test sets it to defer a report's delivery, in
/// place of the file controls.
pub var test_defer: if (builtin.is_test) ?*const fn (child_id: []const u8) bool else void = if (builtin.is_test) null else {};

/// Whether the main loop leaves the waiting reports where they are this pass.
/// `child_id` names the child of the first report waiting.
pub fn deferred(child_id: []const u8) bool {
    if (comptime build_options.libfx) return false;
    if (builtin.is_test) {
        const hook = test_defer orelse return false;
        return hook(child_id);
    }
    const files = end_test_controls.holdFiles("FX_TEST_REPORT_DELIVERY_HELD", "FX_TEST_REPORT_DELIVERY_RELEASE") orelse return false;
    return deferOnFiles(files, child_id);
}

/// The file controls' hold. A hold that cannot write its marker is not armed,
/// as in every other seam in this folder (`holdOnFiles` in
/// `end_test_controls.zig`): no test could see it, and it would hold every
/// delivery for `max_hold_ms`.
fn deferOnFiles(files: end_test_controls.HoldFiles, child_id: []const u8) bool {
    const hold = active orelse begin: {
        const started: Hold = .{ .n = holds + 1, .deadline_ms = io_mod.milliTimestamp() + end_test_controls.max_hold_ms };
        writeHeldMarker(files, started.n, child_id) catch return false;
        holds = started.n;
        active = started;
        break :begin started;
    };
    var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ files.release, hold.n }) catch return false;
    const released = end_test_controls.pathExists(files.release) or end_test_controls.pathExists(own_release);
    if (!released and io_mod.milliTimestamp() < hold.deadline_ms) return true;
    active = null;
    return false;
}

fn writeHeldMarker(files: end_test_controls.HoldFiles, n: u32, child_id: []const u8) !void {
    var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const marker = try std.mem.print(&marker_buf, "{s}.{d}", .{ files.held, n });
    var contents_buf: [256]u8 = undefined;
    const contents = try std.mem.print(&contents_buf, "report_delivery child={s}", .{child_id});
    try end_test_controls.writeMarker(marker, contents);
}

fn deferEveryReport(_: []const u8) bool {
    return true;
}

test "a test build defers a report's delivery only through its hook" {
    // Without a hook nothing is deferred and the file controls are never read.
    try std.testing.expect(!deferred("child"));
    try std.testing.expectEqual(@as(u32, 0), holds);
    test_defer = &deferEveryReport;
    defer test_defer = null;
    try std.testing.expect(deferred("child"));
    try std.testing.expectEqual(@as(u32, 0), holds);
}

fn resetState() void {
    active = null;
    holds = 0;
}

test "a delivery hold whose marker cannot be written does not hold" {
    defer resetState();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(dir);
    // Both paths are absolute, but their folder does not exist, so no marker can be written.
    const held = try std.testing.allocator.print("{s}/missing/held", .{dir});
    defer std.testing.allocator.free(held);
    const release = try std.testing.allocator.print("{s}/missing/release", .{dir});
    defer std.testing.allocator.free(release);
    const files: end_test_controls.HoldFiles = .{ .held = held, .release = release };

    // A delivery that nothing can see held, for up to `max_hold_ms`, is the failure.
    try std.testing.expect(!deferOnFiles(files, "child-1"));
    try std.testing.expect(active == null);
    try std.testing.expectEqual(@as(u32, 0), holds);
    try std.testing.expect(!deferOnFiles(files, "child-1"));
}

test "a delivery hold with a marker it can write holds until its release file exists" {
    defer resetState();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(dir);
    const held = try std.testing.allocator.print("{s}/held", .{dir});
    defer std.testing.allocator.free(held);
    const release = try std.testing.allocator.print("{s}/release", .{dir});
    defer std.testing.allocator.free(release);
    const marker = try std.testing.allocator.print("{s}.1", .{held});
    defer std.testing.allocator.free(marker);
    const files: end_test_controls.HoldFiles = .{ .held = held, .release = release };

    // It writes its marker once, and defers pass after pass.
    try std.testing.expect(deferOnFiles(files, "child-1"));
    try std.testing.expect(end_test_controls.pathExists(marker));
    try std.testing.expect(deferOnFiles(files, "child-1"));
    try std.testing.expectEqual(@as(u32, 1), holds);

    // The release file ends it.
    try end_test_controls.writeMarker(release, "");
    try std.testing.expect(!deferOnFiles(files, "child-1"));
    try std.testing.expect(active == null);
}
