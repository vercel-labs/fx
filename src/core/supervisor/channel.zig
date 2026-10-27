//! One framed duplex connection between the supervisor and a client, run by
//! one pump thread on each end.
//!
//! A frame is one JSON object on one line. Any thread may queue a frame with
//! `send`; the pump writes queued bytes only when the socket can take them
//! and hands each complete line it reads to its handler. A slow peer
//! therefore never blocks a sender, and a pending read never delays a write.
//! A wake pipe tells the pump that frames are queued or the channel closed.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const max_frame_bytes = 8 * 1024 * 1024;
/// Queued bytes past this mean the peer stopped reading. The channel closes
/// rather than buffer without bound.
const max_queued_bytes = 64 * 1024 * 1024;

pub const Channel = struct {
    alloc: Allocator,
    wake: [2]posix.fd_t,
    mutex: std.Io.Mutex = .init,
    /// Frames waiting for the pump, each followed by a newline.
    queued: std.ArrayList(u8) = .empty,
    /// The current connection ends at the pump's next turn.
    closed: bool = false,
    /// The current connection ends once everything queued is written.
    finishing: bool = false,
    /// `reset` no longer reopens the channel.
    shut: bool = false,

    pub fn init(alloc: Allocator) !Channel {
        var fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        for (fds) |fd| _ = std.c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        return .{ .alloc = alloc, .wake = fds };
    }

    pub fn deinit(self: *Channel) void {
        for (self.wake) |fd| _ = std.c.close(fd);
        self.queued.deinit(self.alloc);
        self.* = undefined;
    }

    /// Queues one frame. Fails once the connection ended or is ending.
    pub fn send(self: *Channel, frame: []const u8) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed or self.finishing) return error.ChannelClosed;
        if (self.queued.items.len + frame.len + 1 > max_queued_bytes) {
            self.closed = true;
            self.signal();
            return error.PeerNotReading;
        }
        const was_empty = self.queued.items.len == 0;
        try self.queued.ensureUnusedCapacity(self.alloc, frame.len + 1);
        self.queued.appendSliceAssumeCapacity(frame);
        self.queued.appendAssumeCapacity('\n');
        if (was_empty) self.signal();
    }

    /// Ends the current connection at once, dropping unsent frames.
    pub fn close(self: *Channel) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.closed = true;
        self.signal();
    }

    /// Ends the current connection after its queued frames are written.
    pub fn finish(self: *Channel) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.finishing = true;
        self.signal();
    }

    /// Closes the channel for good: `reset` keeps it closed and `waitWake`
    /// returns at once.
    pub fn shutDown(self: *Channel) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.shut = true;
        self.closed = true;
        self.signal();
    }

    pub fn isClosed(self: *Channel) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.closed or self.finishing;
    }

    /// Prepares for a new connection: drops frames queued for the old one.
    /// Returns false once the channel is shut.
    pub fn reset(self: *Channel) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.queued.clearRetainingCapacity();
        if (self.shut) return false;
        self.closed = false;
        self.finishing = false;
        return true;
    }

    /// Waits up to `timeout_ms` for a wake, such as `shutDown`.
    pub fn waitWake(self: *Channel, timeout_ms: i32) void {
        var fds = [_]posix.pollfd{.{ .fd = self.wake[0], .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout_ms) catch return;
        if (ready > 0) self.drainWake();
    }

    /// Holds `mutex`.
    fn signal(self: *Channel) void {
        const byte = [_]u8{1};
        _ = std.c.write(self.wake[1], &byte, 1);
    }

    fn drainWake(self: *Channel) void {
        var bytes: [64]u8 = undefined;
        _ = std.c.read(self.wake[0], &bytes, bytes.len);
    }

    /// Runs one connection until the peer hangs up or the channel closes or
    /// finishes. Calls `handler.frame(bytes)` for each line it reads; the
    /// bytes live only during the call, which may `send` on this channel.
    pub fn pump(self: *Channel, stream: std.Io.net.Stream, handler: anytype) !void {
        const alloc = self.alloc;
        var inbound: std.ArrayList(u8) = .empty;
        defer inbound.deinit(alloc);
        var outbound: std.ArrayList(u8) = .empty;
        defer outbound.deinit(alloc);
        var written: usize = 0;
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const ending = ending: {
                self.mutex.lockUncancelable(io_mod.getIo());
                defer self.mutex.unlock(io_mod.getIo());
                if (self.closed) return;
                try outbound.appendSlice(alloc, self.queued.items);
                self.queued.clearRetainingCapacity();
                break :ending self.finishing;
            };
            if (ending and written == outbound.items.len) return;
            const writing = written < outbound.items.len;
            const out_events: i16 = if (writing) posix.POLL.OUT else 0;
            var fds = [_]posix.pollfd{
                .{ .fd = stream.socket.handle, .events = posix.POLL.IN | out_events, .revents = 0 },
                .{ .fd = self.wake[0], .events = posix.POLL.IN, .revents = 0 },
            };
            _ = try posix.poll(&fds, -1);
            if (fds[1].revents != 0) self.drainWake();
            const socket_events = fds[0].revents;
            if (writing and socket_events & posix.POLL.OUT != 0) {
                written += try sendSome(stream, outbound.items[written..]);
                if (written == outbound.items.len) {
                    outbound.clearRetainingCapacity();
                    written = 0;
                }
            }
            if (socket_events & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
            var buffers = [_][]u8{&buffer};
            const count = (try stream.readWithControl(io_mod.getIo(), &buffers, &.{})).data_len;
            if (count == 0) return;
            // The bytes held before this read have no newline, so only the
            // new ones are searched: a frame of many reads scans once.
            const scanned = inbound.items.len;
            try inbound.appendSlice(alloc, buffer[0..count]);
            var start: usize = 0;
            var from = scanned;
            while (std.mem.findScalarPos(u8, inbound.items, from, '\n')) |end| {
                handler.frame(inbound.items[start..end]);
                start = end + 1;
                from = start;
            }
            if (start > 0) {
                const rest = inbound.items.len - start;
                @memmove(inbound.items[0..rest], inbound.items[start..]);
                inbound.shrinkRetainingCapacity(rest);
            }
            if (inbound.items.len > max_frame_bytes) return error.FrameTooLarge;
        }
    }
};

/// Writes what the socket takes now without waiting. A closed peer is an
/// error, never a signal.
fn sendSome(stream: std.Io.net.Stream, bytes: []const u8) !usize {
    const rc = std.c.send(stream.socket.handle, bytes.ptr, bytes.len, std.c.MSG.DONTWAIT | std.c.MSG.NOSIGNAL);
    if (rc >= 0) return @intCast(rc);
    return switch (posix.errno(rc)) {
        .AGAIN, .INTR, .NOBUFS => 0,
        else => error.ConnectionClosed,
    };
}

const TestCollector = struct {
    alloc: Allocator,
    frames: std.ArrayList([]u8) = .empty,
    echo: ?*Channel = null,
    count: std.atomic.Value(usize) = .init(0),

    fn frame(self: *TestCollector, bytes: []const u8) void {
        const copy = self.alloc.dupe(u8, bytes) catch return;
        self.frames.append(self.alloc, copy) catch self.alloc.free(copy);
        _ = self.count.fetchAdd(1, .release);
        if (self.echo) |channel| channel.send(bytes) catch {};
    }

    fn deinit(self: *TestCollector) void {
        for (self.frames.items) |bytes| self.alloc.free(bytes);
        self.frames.deinit(self.alloc);
    }
};

fn testPump(channel: *Channel, stream: std.Io.net.Stream, collector: *TestCollector) void {
    channel.pump(stream, collector) catch {};
}

test "a channel carries frames both ways and finishes after flushing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    // Socket paths are short; a test tmp dir is too deep.
    const path = try alloc.print("/tmp/proto-fx-channel-{d}-{d}.sock", .{ std.c.getpid(), io_mod.milliTimestamp() });
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const address = try std.Io.net.UnixAddress.init(path);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const client_stream = try address.connect(io);
    defer client_stream.close(io);
    const server_stream = try listener.accept(io);
    defer server_stream.close(io);

    var server = try Channel.init(alloc);
    defer server.deinit();
    var client = try Channel.init(alloc);
    defer client.deinit();
    var server_seen: TestCollector = .{ .alloc = alloc, .echo = &server };
    defer server_seen.deinit();
    var client_seen: TestCollector = .{ .alloc = alloc };
    defer client_seen.deinit();

    const server_thread = try std.Thread.spawn(.{}, testPump, .{ &server, server_stream, &server_seen });
    const client_thread = try std.Thread.spawn(.{}, testPump, .{ &client, client_stream, &client_seen });
    // A frame larger than one socket buffer still arrives whole.
    const large = try alloc.alloc(u8, 300 * 1024);
    defer alloc.free(large);
    @memset(large, 'x');
    try client.send("{\"a\":1}");
    try client.send(large);
    try client.send("{\"b\":2}");
    const deadline = io_mod.milliTimestamp() + 5_000;
    while (client_seen.count.load(.acquire) < 3 and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    server.finish();
    server_thread.join();
    client.close();
    client_thread.join();
    try std.testing.expectEqual(@as(usize, 3), server_seen.frames.items.len);
    try std.testing.expectEqual(@as(usize, 3), client_seen.frames.items.len);
    try std.testing.expectEqualStrings("{\"a\":1}", client_seen.frames.items[0]);
    try std.testing.expectEqual(large.len, client_seen.frames.items[1].len);
    try std.testing.expectEqualStrings("{\"b\":2}", client_seen.frames.items[2]);
    try std.testing.expectError(error.ChannelClosed, server.send("late"));
    try std.testing.expect(client.reset());
    client.shutDown();
    try std.testing.expect(!client.reset());
}
