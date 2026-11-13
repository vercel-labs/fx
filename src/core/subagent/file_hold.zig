//! The file protocol of the subagent test controls
//! (`end_test_controls.zig`, `start_test_controls.zig`). A control holds a
//! slot at one point: it writes `<held>.<n>` for the n-th hold of its kind in
//! the process, with a line that names the child, then waits until
//! `<release>` or `<release>.<n>` exists, for at most a minute. A test that
//! sets the two environment variables of a control finds the marker and lets
//! the slot go when it chooses. Only such tests set them, so the libfx
//! artifacts leave the controls out.
const std = @import("std");
const io_mod = @import("../shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_hold_ms = 60_000;

pub const Hold = struct {
    /// The environment variables that name the marker and the release file.
    held_env: []const u8,
    release_env: []const u8,
    count: std.atomic.Value(u32) = .init(0),

    /// Whether a test set both variables.
    pub fn armed(self: *const Hold) bool {
        return io_mod.getenv(self.held_env) != null and io_mod.getenv(self.release_env) != null;
    }

    /// Holds the caller: writes the marker with `contents`, then waits for the
    /// release. A set `cancel` ends the wait early, so a stop or quit never
    /// waits on a hold.
    pub fn wait(self: *Hold, contents: []const u8, cancel: ?*const std.atomic.Value(bool)) void {
        const held = io_mod.getenv(self.held_env) orelse return;
        const release = io_mod.getenv(self.release_env) orelse return;
        const n = self.count.fetchAdd(1, .seq_cst) + 1;
        var marker_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const marker = std.mem.print(&marker_buf, "{s}.{d}", .{ held, n }) catch return;
        var own_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const own_release = std.mem.print(&own_buf, "{s}.{d}", .{ release, n }) catch return;
        writeMarker(marker, contents) catch return;
        const deadline = io_mod.milliTimestamp() + max_hold_ms;
        while (!cancelled(cancel) and !pathExists(release) and !pathExists(own_release) and io_mod.milliTimestamp() < deadline) {
            io_mod.sleep(std.time.ns_per_ms);
        }
    }
};

fn cancelled(cancel: ?*const std.atomic.Value(bool)) bool {
    const flag = cancel orelse return false;
    return flag.load(.seq_cst);
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

test "a hold whose variables are not set is not armed and waits for nothing" {
    var hold = Hold{ .held_env = "FX_TEST_FILE_HOLD_UNSET_HELD", .release_env = "FX_TEST_FILE_HOLD_UNSET_RELEASE" };
    try std.testing.expect(!hold.armed());
    hold.wait("child=none", null);
    try std.testing.expectEqual(@as(u32, 0), hold.count.load(.seq_cst));
}
