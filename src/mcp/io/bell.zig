//! A doorbell for several I/O queues: each HTTP client and server
//! process rings it after posting, so the engine can sleep until any of its
//! servers has something, then read each with `poll`. One pending ring is
//! enough, since the engine reads every server when it wakes: a ring while
//! one is pending changes nothing, and none is ever lost.

const std = @import("std");

pub const Bell = struct {
    io: std.Io,
    queue: std.Io.Queue(u8),
    buffer: [1]u8 = undefined,
    wakes: std.Io.Group = .init,

    pub fn init(b: *Bell, io: std.Io) void {
        b.* = .{ .io = io, .queue = undefined };
        b.queue = .init(&b.buffer);
    }

    pub fn deinit(b: *Bell) void {
        b.wakes.cancel(b.io);
    }

    /// Never blocks, from any task.
    pub fn ring(b: *Bell) void {
        _ = b.queue.put(b.io, &.{0}, 0) catch {};
    }

    /// Waits for a ring, at most `timeout_ms` (forever when null). A wake-up
    /// may come early or late; the caller checks its own clock.
    pub fn wait(b: *Bell, timeout_ms: ?u32) error{ Canceled, ConcurrencyUnavailable }!void {
        if (timeout_ms) |ms| b.wakes.concurrent(b.io, ringAfter, .{ b, ms }) catch return error.ConcurrencyUnavailable;
        _ = b.queue.getOne(b.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => unreachable, // the queue is never closed
        };
    }

    fn ringAfter(b: *Bell, ms: u32) std.Io.Cancelable!void {
        try b.io.sleep(.fromMilliseconds(ms), .awake);
        b.ring();
    }
};

test "a ring wakes the waiter, a second pending ring is the same one, and a timeout wakes it too" {
    var b: Bell = undefined;
    b.init(std.testing.io);
    defer b.deinit();
    b.ring();
    b.ring();
    try b.wait(null);
    try b.wait(20);
}
