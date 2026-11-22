//! A FIFO that a test's hook writes its pid to. The test waits for that write
//! instead of polling a file. Test-only: no product code reaches it.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

pub const Signal = struct {
    path: [:0]u8,
    file: std.Io.File,

    /// Makes the FIFO `dir/name` and opens it for reading and writing. That open keeps a writer
    /// reference, so the reader never sees a hang-up before the hook writes. `deinit` frees it.
    pub fn create(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !Signal {
        const path = try std.Io.Dir.path.joinZ(alloc, &.{ dir, name });
        errdefer alloc.free(path);
        if (mkfifo(path.ptr, 0o600) != 0) return error.MkfifoFailed;
        const file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .mode = .read_write });
        return .{ .path = path, .file = file };
    }

    /// Closes the FIFO and deletes it.
    pub fn deinit(self: *Signal, alloc: std.mem.Allocator) void {
        const io = io_mod.getIo();
        self.file.close(io);
        // A failed delete leaves the FIFO in the test's tmp dir, which the test removes.
        std.Io.Dir.deleteFileAbsolute(io, self.path) catch {};
        alloc.free(self.path);
    }

    /// Waits up to `limit_ms` for one line the hook wrote, and returns it without its newline.
    /// Returns error.Timeout when no line arrives in time.
    pub fn waitLine(self: *Signal, buf: []u8, limit_ms: u32) ![]const u8 {
        const io = io_mod.getIo();
        const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + @as(i64, limit_ms);
        var filled: usize = 0;
        while (true) {
            if (std.mem.indexOfScalar(u8, buf[0..filled], '\n')) |end| return buf[0..end];
            if (filled == buf.len) return error.LineTooLong;
            const left = deadline - std.Io.Clock.awake.now(io).toMilliseconds();
            if (left <= 0) return error.Timeout;
            var fds = [_]std.posix.pollfd{.{ .fd = self.file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, @intCast(left)) == 0) return error.Timeout;
            const n = try std.posix.read(self.file.handle, buf[filled..]);
            if (n == 0) return error.EndOfStream;
            filled += n;
        }
    }
};

test "a signal returns the line its writer sends, without the newline" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var signal = try Signal.create(alloc, dir, "pid");
    defer signal.deinit(alloc);

    const writer = try std.Io.Dir.openFileAbsolute(io, signal.path, .{ .mode = .write_only });
    defer writer.close(io);
    try writer.writeStreamingAll(io, "4242\n");

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("4242", try signal.waitLine(&buf, 5000));
}

test "a signal with no writer times out" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var signal = try Signal.create(alloc, dir, "pid");
    defer signal.deinit(alloc);

    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.Timeout, signal.waitLine(&buf, 10));
}
