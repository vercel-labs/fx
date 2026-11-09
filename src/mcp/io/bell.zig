//! A doorbell for several I/O queues: each HTTP client and server
//! process rings it after posting, so the engine can sleep until any of its
//! servers has something, then read each with `poll`. One pending ring is
//! enough, since the engine reads every server when it wakes: a ring while
//! one is pending changes nothing, and none is ever lost. A timed wait starts
//! no task: the waiting thread itself sleeps until a ring or the deadline.

const std = @import("std");

pub const Bell = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    rung: bool = false,

    pub fn init(b: *Bell, io: std.Io) void {
        b.* = .{ .io = io };
    }

    /// From any task; holds the lock only to set the flag.
    pub fn ring(b: *Bell) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.rung = true;
        b.cond.signal(b.io);
    }

    /// Waits for a ring, at most `timeout_ms` (forever when null). A wake-up
    /// may come early or late; the caller checks its own clock.
    pub fn wait(b: *Bell, timeout_ms: ?u32) error{Canceled}!void {
        const timeout: std.Io.Timeout = if (timeout_ms) |ms|
            .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }
        else
            .none;
        const deadline = timeout.toDeadline(b.io);
        try b.mutex.lock(b.io);
        defer b.mutex.unlock(b.io);
        while (!b.rung) b.cond.waitTimeout(b.io, &b.mutex, deadline) catch |err| switch (err) {
            error.Timeout => return,
            error.Canceled => return error.Canceled,
        };
        b.rung = false;
    }
};

/// Milliseconds `wait` took, for the tests.
fn timed(b: *Bell, timeout_ms: ?u32) !i64 {
    const started = std.Io.Clock.awake.now(b.io).toMilliseconds();
    try b.wait(timeout_ms);
    return std.Io.Clock.awake.now(b.io).toMilliseconds() - started;
}

test "a ring is kept for the next wait, a second pending ring is the same one, and a timeout ends a wait" {
    var b: Bell = undefined;
    b.init(std.testing.io);
    b.ring();
    b.ring();
    try std.testing.expect(try timed(&b, 2_000) < 1_000);
    try std.testing.expect(try timed(&b, 20) >= 15);
}

test "a timed wait starts no task, so it works where none can run" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var b: Bell = undefined;
    b.init(threaded.io());
    try std.testing.expect(try timed(&b, 20) >= 15);
    b.ring();
    try std.testing.expect(try timed(&b, 2_000) < 1_000);
}

test "a ring from another thread ends a long timed wait early" {
    const Ringer = struct {
        fn run(b: *Bell) void {
            std.Io.sleep(b.io, .fromMilliseconds(30), .awake) catch {};
            b.ring();
        }
    };
    var b: Bell = undefined;
    b.init(std.testing.io);
    const thread = try std.Thread.spawn(.{}, Ringer.run, .{&b});
    defer thread.join();
    try std.testing.expect(try timed(&b, 3_000) < 2_000);
}
