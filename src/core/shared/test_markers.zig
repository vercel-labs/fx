const std = @import("std");
const io_mod = @import("io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub fn writeMarker(path: []const u8, contents: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .truncate = true,
        .permissions = private_file_permissions,
    });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), contents);
    try file.sync(io_mod.getIo());
}

pub fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

/// Writes `ready_path` and sleeps until `release_path` appears. Keeps waiting
/// after signals (`io_mod.sleep` ignores `EINTR`/cancellation), so tests can
/// block a worker thread the way an uninterruptible syscall does.
pub fn pauseUntilRelease(ready_path: []const u8, marker: []const u8, release_path: []const u8) void {
    writeMarker(ready_path, marker) catch return;
    while (!pathExists(release_path)) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}
