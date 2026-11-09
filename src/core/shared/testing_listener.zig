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

/// Waits up to `limit_ms` for `flag` to be set and returns whether it was.
pub fn waitFor(flag: *const std.atomic.Value(bool), limit_ms: u32) bool {
    const io = io_mod.getIo();
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    while (!flag.load(.seq_cst)) {
        const waited = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
        if (waited.raw.toMilliseconds() >= limit_ms) return false;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return true;
}

/// A test server's thread and what it shares with the test that stops it.
/// The thread accepts through `accept`, closes what it accepted through
/// `close`, and sets `done` as it returns.
pub const ServerThread = struct {
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    /// Guards `connection` and `shut_down`.
    mutex: std.Io.Mutex = .init,
    /// The connection the thread is serving.
    connection: ?std.Io.net.Stream = null,
    /// Set once a stop ran out of time, so that a connection the thread
    /// accepts after that is shut down too.
    shut_down: bool = false,

    /// Accepts through `acceptUnlessStopping` and records the connection.
    pub fn accept(
        self: *ServerThread,
        server: *std.Io.net.Server,
        io: std.Io,
    ) AcceptError!?std.Io.net.Stream {
        const stream = (try acceptUnlessStopping(server, io, &self.stopping)) orelse return null;
        const lock_io = io_mod.getIo();
        self.mutex.lockUncancelable(lock_io);
        defer self.mutex.unlock(lock_io);
        self.connection = stream;
        if (self.shut_down) stream.shutdown(lock_io, .both) catch {};
        return stream;
    }

    /// Forgets the connection that `accept` returned, then closes it. A stop
    /// shuts the connection down only while it holds the same lock, so it
    /// never reaches a closed descriptor or one the system has given out
    /// again.
    pub fn close(self: *ServerThread, io: std.Io, stream: std.Io.net.Stream) void {
        const lock_io = io_mod.getIo();
        self.mutex.lockUncancelable(lock_io);
        self.connection = null;
        self.mutex.unlock(lock_io);
        stream.close(io);
    }

    /// Sets the stop flag, then joins the thread through `join`.
    pub fn stop(
        self: *ServerThread,
        server: *std.Io.net.Server,
        limit_ms: u32,
    ) error{TestThreadStillWaiting}!void {
        self.stopping.store(true, .seq_cst);
        return self.join(server, limit_ms);
    }

    /// Joins the thread, and fails instead of hanging when it is still
    /// running after `limit_ms`. In that case it first wakes the thread: it
    /// shuts down the connection the thread is serving, which ends a read or
    /// write on it, and connects once to `server`, which ends a wait in
    /// `accept`. Then it joins the thread and returns
    /// `error.TestThreadStillWaiting`. A thread blocked on anything else
    /// still holds up the join.
    pub fn join(
        self: *ServerThread,
        server: *std.Io.net.Server,
        limit_ms: u32,
    ) error{TestThreadStillWaiting}!void {
        const thread = self.thread orelse return;
        self.thread = null;
        if (waitFor(&self.done, limit_ms)) {
            thread.join();
            return;
        }
        self.shutDown();
        connectOnce(server) catch {};
        thread.join();
        return error.TestThreadStillWaiting;
    }

    fn shutDown(self: *ServerThread) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.shut_down = true;
        if (self.connection) |stream| stream.shutdown(io, .both) catch {};
    }
};

/// A loopback listener with a thread waiting on it, for the tests below.
const Waiter = struct {
    backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server = undefined,
    serving: ServerThread = .{},
    /// Waits in a plain `accept`, which never reads the stop flag.
    ignores_stop: bool = false,
    started: std.atomic.Value(bool) = .init(false),
    accepted: bool = false,
    failure: ?AcceptError = null,

    /// Listens on a free loopback port and starts the waiting thread. The
    /// waiter must not move until `finish` returns.
    fn start(self: *Waiter) !void {
        const zio = self.backend.io();
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = try address.listen(zio, .{ .reuse_address = true });
        errdefer self.server.deinit(zio);
        self.serving.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Waiter) void {
        defer self.serving.done.store(true, .seq_cst);
        const zio = self.backend.io();
        self.started.store(true, .seq_cst);
        if (self.ignores_stop) {
            const stream = self.server.accept(zio) catch |err| {
                self.failure = err;
                return;
            };
            self.accepted = true;
            stream.close(zio);
            return;
        }
        const stream = self.serving.accept(&self.server, zio) catch |err| {
            self.failure = err;
            return;
        };
        if (stream) |accepted| {
            self.accepted = true;
            self.serving.close(zio, accepted);
        }
    }

    /// Joins the thread through `ServerThread.join`, then closes the
    /// listener.
    fn finish(self: *Waiter, limit_ms: u32) !void {
        defer self.server.deinit(self.backend.io());
        try self.serving.join(&self.server, limit_ms);
    }

    fn waitUntilStarted(self: *Waiter) void {
        while (!self.started.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        // Give the thread time to settle into its wait.
        io_mod.sleep(50 * std.time.ns_per_ms);
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
    waiter.waitUntilStarted();
    waiter.serving.stopping.store(true, .seq_cst);
    try waiter.finish(5_000);
    try std.testing.expect(!waiter.accepted);
    try std.testing.expectEqual(@as(?AcceptError, null), waiter.failure);
}

test "a waiting accept returns the client that connects" {
    var waiter: Waiter = .{};
    try waiter.start();
    connectOnce(&waiter.server) catch |err| {
        waiter.serving.stopping.store(true, .seq_cst);
        waiter.finish(5_000) catch {};
        return err;
    };
    try waiter.finish(5_000);
    try std.testing.expect(waiter.accepted);
    try std.testing.expectEqual(@as(?AcceptError, null), waiter.failure);
}

test "a stop that the thread ignores fails within its limit" {
    const limit_ms = 300;
    var waiter: Waiter = .{ .ignores_stop = true };
    try waiter.start();
    waiter.waitUntilStarted();
    const io = io_mod.getIo();
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    waiter.serving.stopping.store(true, .seq_cst);
    try std.testing.expectError(error.TestThreadStillWaiting, waiter.finish(limit_ms));
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
    try std.testing.expect(elapsed_ms >= limit_ms);
    try std.testing.expect(elapsed_ms < limit_ms + 1_000);
    // The connection the stop opened to wake the thread is the one it took.
    try std.testing.expect(waiter.accepted);
}
