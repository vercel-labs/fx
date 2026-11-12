//! Accepting on a test server's listener so its thread can always be stopped.

const std = @import("std");
const io_mod = @import("io.zig");
const net_connect = @import("net_connect.zig");

const posix = std.posix;
const Threaded = std.Io.Threaded;

/// How long one wait for a connection lasts before the stop flag is read
/// again.
const stop_check_ms = 10;

pub const AcceptError = posix.PollError || std.Io.net.Server.AcceptError;

/// Accepts the next connection on `server`, or returns null once `stopping`
/// is set. A test server's thread uses this in place of a blocking `accept`,
/// so the test can stop the thread whether or not a client ever connects.
/// Nothing wakes a blocked `accept` on every platform: `shutdown` on a
/// listening socket wakes it on Linux but fails with `ENOTCONN` on macOS, and
/// a connection opened only to wake it can fail like any other. The caller
/// owns the returned stream.
///
/// A connection that is gone by the time `accept` runs sends the loop back
/// to waiting, through `acceptIfWaiting`, so the stop is still read.
pub fn acceptUnlessStopping(
    server: *std.Io.net.Server,
    io: std.Io,
    stopping: *const std.atomic.Value(bool),
) AcceptError!?std.Io.net.Stream {
    var fds = [_]posix.pollfd{.{
        .fd = server.socket.handle,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    while (!stopping.load(.seq_cst)) {
        fds[0].revents = 0;
        if (try posix.poll(&fds, stop_check_ms) == 0) continue;
        if (try acceptIfWaiting(server, io)) |stream| return stream;
    }
    return null;
}

/// Accepts the connection that `poll` found waiting on `server`, or returns
/// null when it is gone, as when another thread took it first. A blocking
/// `accept` would wait for the next connection instead, and a thread waiting
/// there never reads its stop flag. This leaves the listener non-blocking,
/// so accept on it only through this function from then on:
/// the standard `accept` treats a listener with nothing to accept as a bug.
/// Like a stream the standard `accept` returns, the stream blocks and is
/// closed on exec; macOS gives it the listener's non-blocking flag. The
/// caller owns the returned stream.
pub fn acceptIfWaiting(server: *std.Io.net.Server, io: std.Io) AcceptError!?std.Io.net.Stream {
    const listener = server.socket.handle;
    try net_connect.setNonblocking(listener);
    var storage: Threaded.PosixAddress = undefined;
    var length: posix.socklen_t = @sizeOf(Threaded.PosixAddress);
    const fd: posix.fd_t = while (true) {
        const rc = posix.system.accept(listener, &storage.any, &length);
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .AGAIN, .CONNABORTED => return null,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    const stream: std.Io.net.Stream = .{ .socket = .{
        .handle = fd,
        .address = Threaded.addressFromPosix(&storage),
    } };
    errdefer stream.close(io);
    try net_connect.setCloexec(fd);
    try net_connect.setBlocking(fd);
    return stream;
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

/// Two threads that wait on one loopback listener through
/// `acceptUnlessStopping`, for the test of a connection only one of them
/// can take.
const Rivals = struct {
    backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    threads: [2]?std.Thread = @splat(null),
    started: [2]std.atomic.Value(bool) = @splat(.init(false)),
    done: [2]std.atomic.Value(bool) = @splat(.init(false)),
    taken: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    /// Listens on a free loopback port and starts both threads. The rivals
    /// must not move until `finish` returns.
    fn start(self: *Rivals) !void {
        const zio = self.backend.io();
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = try address.listen(zio, .{ .reuse_address = true });
        errdefer self.server.deinit(zio);
        for (&self.threads, 0..) |*thread, index| {
            thread.* = std.Thread.spawn(.{}, run, .{ self, index }) catch |err| {
                self.stopping.store(true, .seq_cst);
                for (self.threads[0..index]) |started| started.?.join();
                return err;
            };
        }
    }

    fn run(self: *Rivals, index: usize) void {
        defer self.done[index].store(true, .seq_cst);
        var backend: std.Io.Threaded = .init_single_threaded;
        const zio = backend.io();
        self.started[index].store(true, .seq_cst);
        const stream = acceptUnlessStopping(&self.server, zio, &self.stopping) catch {
            self.failed.store(true, .seq_cst);
            return;
        } orelse return;
        _ = self.accepted.fetchAdd(1, .seq_cst);
        self.taken.store(true, .seq_cst);
        stream.close(zio);
    }

    fn waitUntilStarted(self: *Rivals) void {
        for (&self.started) |*started| {
            while (!started.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        }
        // Give both threads time to settle into their wait.
        io_mod.sleep(20 * std.time.ns_per_ms);
    }

    /// Stops both threads and joins them, then closes the listener. A thread
    /// still running after `limit_ms` is woken by one more connection, so the
    /// test fails instead of hanging.
    fn finish(self: *Rivals, limit_ms: u32) error{TestThreadStillWaiting}!void {
        defer self.server.deinit(self.backend.io());
        self.stopping.store(true, .seq_cst);
        var still_waiting = false;
        for (&self.threads, &self.done) |*slot, *done| {
            const thread = slot.* orelse continue;
            slot.* = null;
            if (!waitFor(done, limit_ms)) {
                still_waiting = true;
                connectOnce(&self.server) catch {};
            }
            thread.join();
        }
        if (still_waiting) return error.TestThreadStillWaiting;
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

test "a waiting accept ends at the stop when another thread takes the connection it saw" {
    // Both threads can see the one connection as ready, and only one accept
    // gets it. The other must go back to waiting for the stop: an accept that
    // blocks there never reads the flag again.
    for (0..10) |_| {
        var rivals: Rivals = .{};
        try rivals.start();
        rivals.waitUntilStarted();
        connectOnce(&rivals.server) catch |err| {
            rivals.finish(5_000) catch {};
            return err;
        };
        const taken = waitFor(&rivals.taken, 5_000);
        try rivals.finish(2_000);
        try std.testing.expect(taken);
        try std.testing.expectEqual(@as(usize, 1), rivals.accepted.load(.seq_cst));
        try std.testing.expect(!rivals.failed.load(.seq_cst));
    }
}

test "a stream the waiting accept returns blocks on its reads" {
    // The listener does not block, and macOS gives an accepted socket the
    // listener's file status flags.
    var backend: std.Io.Threaded = .init_single_threaded;
    const zio = backend.io();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    try connectOnce(&server);
    var stopping = std.atomic.Value(bool).init(false);
    const stream = (try acceptUnlessStopping(&server, zio, &stopping)).?;
    defer stream.close(zio);
    const flags = std.posix.system.fcntl(stream.socket.handle, std.posix.F.GETFL, @as(usize, 0));
    try std.testing.expect(flags >= 0);
    const nonblock: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    try std.testing.expectEqual(@as(usize, 0), @as(usize, @intCast(flags)) & nonblock);
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
