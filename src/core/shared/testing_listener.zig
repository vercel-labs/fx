//! Accepting on a test server's listener so its thread can always be stopped.

const std = @import("std");
const io_mod = @import("io.zig");

/// How long one wait for a connection lasts before the stop flag is read
/// again.
const stop_check_ms = 10;

pub const AcceptError = std.posix.PollError || std.Io.net.Server.AcceptError;

/// Accepts the next connection on `server`, or returns null once `stopping`
/// is set. A test server's thread uses this in place of a blocking `accept`,
/// so the test can stop the thread whether or not a client ever connects.
/// Nothing wakes a blocked `accept` on every platform: `shutdown` on a
/// listening socket wakes it on Linux but fails with `ENOTCONN` on macOS, and
/// a connection opened only to wake it can fail like any other. The caller
/// owns the returned stream.
pub fn acceptUnlessStopping(
    server: *std.Io.net.Server,
    io: std.Io,
    stopping: *const std.atomic.Value(bool),
) AcceptError!?std.Io.net.Stream {
    var fds = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (!stopping.load(.seq_cst)) {
        fds[0].revents = 0;
        if (try std.posix.poll(&fds, stop_check_ms) == 0) continue;
        return try server.accept(io);
    }
    return null;
}

/// Joins a test server's thread, which sets `done` as it returns, and fails
/// instead of hanging when the thread is still waiting after `limit_ms`. In
/// that case it first connects once to `server`, only so that a thread stuck
/// in `accept` returns and the join ends, then returns
/// `error.TestThreadStillWaiting` after the join.
pub fn joinWithin(
    thread: std.Thread,
    server: *std.Io.net.Server,
    done: *const std.atomic.Value(bool),
    limit_ms: u32,
) error{TestThreadStillWaiting}!void {
    var waited_ms: u32 = 0;
    while (!done.load(.seq_cst) and waited_ms < limit_ms) : (waited_ms += 1) io_mod.sleep(std.time.ns_per_ms);
    const finished = done.load(.seq_cst);
    if (!finished) connectOnce(server) catch {};
    thread.join();
    if (!finished) return error.TestThreadStillWaiting;
}

/// A loopback listener with a thread waiting on it in `acceptUnlessStopping`,
/// for the tests below.
const Waiter = struct {
    backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server = undefined,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    accepted: bool = false,
    failure: ?AcceptError = null,

    /// Listens on a free loopback port and starts the waiting thread. The
    /// waiter must not move until `finish` returns.
    fn start(self: *Waiter) !void {
        const zio = self.backend.io();
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = try address.listen(zio, .{ .reuse_address = true });
        errdefer self.server.deinit(zio);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Waiter) void {
        defer self.done.store(true, .seq_cst);
        const zio = self.backend.io();
        self.started.store(true, .seq_cst);
        const stream = acceptUnlessStopping(&self.server, zio, &self.stopping) catch |err| {
            self.failure = err;
            return;
        };
        if (stream) |accepted| {
            self.accepted = true;
            accepted.close(zio);
        }
    }

    /// Joins the thread through `joinWithin`, then closes the listener.
    fn finish(self: *Waiter, limit_ms: u32) !void {
        defer self.server.deinit(self.backend.io());
        try joinWithin(self.thread, &self.server, &self.done, limit_ms);
    }
};

fn connectOnce(server: *std.Io.net.Server) !void {
    var backend: std.Io.Threaded = .init_single_threaded;
    const zio = backend.io();
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(server.socket.address.getPort()) };
    const stream = try address.connect(zio, .{ .mode = .stream });
    stream.close(zio);
}

test "a waiting accept ends when it is stopped though no client connects" {
    var waiter: Waiter = .{};
    try waiter.start();
    while (!waiter.started.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
    // Give the thread time to settle into its wait before stopping it.
    io_mod.sleep(50 * std.time.ns_per_ms);
    waiter.stopping.store(true, .seq_cst);
    try waiter.finish(5_000);
    try std.testing.expect(!waiter.accepted);
    try std.testing.expectEqual(@as(?AcceptError, null), waiter.failure);
}

test "a waiting accept returns the client that connects" {
    var waiter: Waiter = .{};
    try waiter.start();
    connectOnce(&waiter.server) catch |err| {
        waiter.stopping.store(true, .seq_cst);
        waiter.finish(5_000) catch {};
        return err;
    };
    try waiter.finish(5_000);
    try std.testing.expect(waiter.accepted);
    try std.testing.expectEqual(@as(?AcceptError, null), waiter.failure);
}
