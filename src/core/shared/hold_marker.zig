//! The marker file a test hold writes to tell its test that fx is held there.
//! A hold reads the marker's path from the environment, so the marker is
//! always a new file. fx never opens what already sits at that path: opening
//! a FIFO for writing would block fx until something reads it, and a stale
//! file or a symlink would be written through.
const std = @import("std");
const io_mod = @import("io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

/// Creates `path` with owner-only permissions, writes `contents`, and syncs
/// it. Fails with `error.PathAlreadyExists` when anything is at `path`.
pub fn write(path: []const u8, contents: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .exclusive = true,
        .truncate = false,
        .permissions = private_file_permissions,
    });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), contents);
    try file.sync(io_mod.getIo());
}

test "a hold marker is never opened where a FIFO already sits" {
    const fifo_c = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(dir);
    const fifo = try std.Io.Dir.path.joinZ(std.testing.allocator, &.{ dir, "held" });
    defer std.testing.allocator.free(fifo);
    try std.testing.expectEqual(@as(c_int, 0), fifo_c.mkfifo(fifo, 0o600));
    // With a reader open, an open of the FIFO for writing returns instead of
    // blocking, so an open that does not refuse the FIFO fails this test
    // instead of hanging it.
    const reader = std.c.open(fifo, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
    try std.testing.expect(reader >= 0);
    defer _ = std.c.close(reader);

    try std.testing.expectError(error.PathAlreadyExists, write(fifo, "held"));
    var unread: [8]u8 = undefined;
    try std.testing.expect(std.c.read(reader, &unread, unread.len) <= 0);
}

test "a hold marker is written once and then refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(dir);
    const marker = try std.Io.Dir.path.join(std.testing.allocator, &.{ dir, "held.1" });
    defer std.testing.allocator.free(marker);

    try write(marker, "first");
    try std.testing.expectError(error.PathAlreadyExists, write(marker, "second"));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("first", try tmp.dir.readFile(std.testing.io, "held.1", &buffer));
}
