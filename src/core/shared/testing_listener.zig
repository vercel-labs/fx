//! Accepting on a test server's listener so its thread can always be stopped.

const std = @import("std");

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

/// A thread waiting in `acceptUnlessStopping`, for the tests below.
const Waiter = struct {
    backend: std.Io.Threaded = .init_single_threaded,
    server: *std.Io.net.Server,
    stopping: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    accepted: bool = false,
    failure: ?AcceptError = null,

    fn run(self: *Waiter) void {
        defer self.done.store(true, .seq_cst);
        const zio = self.backend.io();
        self.started.store(true, .seq_cst);
        const stream = acceptUnlessStopping(self.server, zio, &self.stopping) catch |err| {
            self.failure = err;
            return;
        };
        if (stream) |accepted| {
            self.accepted = true;
            accepted.close(zio);
        }
    }

    /// Gives the thread at least `limit_ms` to finish. When it does not,
    /// connects once so a wait that ignored the stop flag still ends and the
    /// test fails instead of hanging. Returns whether it finished in time.
    fn finish(self: *Waiter, thread: std.Thread, limit_ms: u32) bool {
        var waited_ms: u32 = 0;
        while (!self.done.load(.seq_cst) and waited_ms < limit_ms) : (waited_ms += 1) sleepMs(1);
        const finished = self.done.load(.seq_cst);
        if (!finished) connectOnce(self.server) catch {};
        thread.join();
        return finished;
    }
};

fn sleepMs(ms: u64) void {
    var backend: std.Io.Threaded = .init_single_threaded;
    backend.io().sleep(.fromMilliseconds(@intCast(ms)), .real) catch {};
}

fn connectOnce(server: *std.Io.net.Server) !void {
    var backend: std.Io.Threaded = .init_single_threaded;
    const zio = backend.io();
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(server.socket.address.getPort()) };
    const stream = try address.connect(zio, .{ .mode = .stream });
    stream.close(zio);
}

fn listenOnLoopback(zio: std.Io) !std.Io.net.Server {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    return address.listen(zio, .{ .reuse_address = true });
}

test "a waiting accept ends when it is stopped though no client connects" {
    var backend: std.Io.Threaded = .init_single_threaded;
    const zio = backend.io();
    var server = try listenOnLoopback(zio);
    defer server.deinit(zio);
    var waiter: Waiter = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    while (!waiter.started.load(.seq_cst)) sleepMs(1);
    // Give the thread time to settle into its wait before stopping it.
    sleepMs(50);
    waiter.stopping.store(true, .seq_cst);
    if (!waiter.finish(thread, 5_000)) return error.TestAcceptIgnoredStop;
    try std.testing.expect(!waiter.accepted);
    try std.testing.expectEqual(@as(?AcceptError, null), waiter.failure);
}

test "a waiting accept returns the client that connects" {
    var backend: std.Io.Threaded = .init_single_threaded;
    const zio = backend.io();
    var server = try listenOnLoopback(zio);
    defer server.deinit(zio);
    var waiter: Waiter = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    connectOnce(&server) catch |err| {
        waiter.stopping.store(true, .seq_cst);
        _ = waiter.finish(thread, 5_000);
        return err;
    };
    if (!waiter.finish(thread, 5_000)) return error.TestAcceptMissedClient;
    try std.testing.expect(waiter.accepted);
    try std.testing.expectEqual(@as(?AcceptError, null), waiter.failure);
}
