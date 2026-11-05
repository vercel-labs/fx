//! fx's TCP connect for the process `std.Io`.
//!
//! Zig 0.17's `std.Io.Threaded` calls connect(2) again when a blocking
//! connect returns EINTR (`posixConnect` in lib/std/Io/Threaded.zig). An
//! interrupted connect keeps going in the kernel, so the second call returns
//! EALREADY, which std reports as `error.ConnectionPending`, or EISCONN, which
//! std treats as a programmer bug: a panic in Debug builds and
//! `error.Unexpected` in release builds. The EINTR comes from std itself: it
//! cancels a task by sending SIGIO to the thread that runs it, and a late
//! signal can reach that thread's next task. `HostName.connect` cancels a task
//! on every connect, so many HTTP connects at once hit this, as when fx starts
//! many HTTP MCP servers together.
//!
//! This connect calls connect(2) once per socket. The socket is non-blocking
//! while it connects: fx waits for it with poll(2) in short slices, checks for
//! cancelation between them, reads the result with SO_ERROR, and returns a
//! blocking socket, as std's own connect does.
//!
//! Remove this file and its use in `io.zig` once fx builds with a Zig whose
//! `posixConnect` no longer calls connect(2) after EINTR
//! (https://codeberg.org/ziglang/zig/issues/31391).
const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const net = std.Io.net;
const Threaded = std.Io.Threaded;

const supported = switch (builtin.target.os.tag) {
    .macos, .linux => true,
    else => false,
};

/// How long one poll(2) waits before the connect checks for cancelation.
const cancel_check_ms = 20;

// Installed before threads start, like the Darwin process adapter.
var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_inner: ?*const std.Io.VTable = null;

/// `inner` with fx's connect in place of its `netConnectIp`. The vtable is
/// process storage, so every call must pass the same `inner` vtable.
pub fn wrap(inner: std.Io) std.Io {
    if (comptime !supported) return inner;
    if (wrapped_inner) |vtable| {
        std.debug.assert(vtable == inner.vtable);
    } else {
        wrapped_vtable = inner.vtable.*;
        wrapped_vtable.netConnectIp = netConnectIp;
        wrapped_inner = inner.vtable;
    }
    return .{ .userdata = inner.userdata, .vtable = &wrapped_vtable };
}

fn netConnectIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    const inner = wrapped_inner.?;
    // std doesn't implement connect timeouts yet; those stay with std.
    if (options.timeout != .none or !std.options.networking) return inner.netConnectIp(userdata, address, options);
    return connect(.{ .userdata = userdata, .vtable = inner }, address, options);
}

/// Connects a new socket to `address`. Waits until the connection is made,
/// fails, or the task is canceled, and ends with `error.Canceled` within about
/// `cancel_check_ms` of a cancel request. The caller owns the socket.
fn connect(
    io: std.Io,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    try io.checkCancel();
    const fd = try openSocket(Threaded.posixAddressFamily(address), options);
    errdefer Threaded.closeFd(fd);
    try setNonblocking(fd, true);
    var storage: Threaded.PosixAddress = undefined;
    const length = Threaded.addressToPosix(address, &storage);
    switch (posix.errno(posix.system.connect(fd, &storage.any, length))) {
        .SUCCESS => {},
        // Interrupted or not, the connection goes on in the kernel.
        .INPROGRESS, .INTR => try awaitConnected(io, fd),
        else => |err| return connectError(err),
    }
    try setNonblocking(fd, false);
    return .{ .handle = fd, .address = try localAddress(fd) };
}

fn awaitConnected(io: std.Io, fd: posix.fd_t) net.IpAddress.ConnectError!void {
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
        const ready = posix.system.poll(&fds, fds.len, cancel_check_ms);
        switch (posix.errno(ready)) {
            .SUCCESS => if (ready > 0) return socketError(fd),
            .INTR => {},
            .AGAIN, .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
        try io.checkCancel();
    }
}

/// The result of the finished connect on `fd`.
fn socketError(fd: posix.fd_t) net.IpAddress.ConnectError!void {
    var value: c_int = 0;
    var length: posix.socklen_t = @sizeOf(c_int);
    switch (posix.errno(posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&value), &length))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    if (value == 0) return;
    return connectError(@fromBackingInt(@intCast(value)));
}

/// The errors std's `posixConnect` reports for a failed connect. EPERM, which
/// Linux returns for a firewall rule, is `error.AccessDenied` here.
fn connectError(err: posix.E) net.IpAddress.ConnectError {
    return switch (err) {
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .AGAIN => error.WouldBlock,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .ACCES, .PERM => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => posix.unexpectedErrno(err),
    };
}

/// A socket like the one std's connect opens: close-on-exec, blocking.
fn openSocket(family: posix.sa_family_t, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!posix.fd_t {
    const mode, const protocol = try Threaded.posixSocketModeProtocol(family, options.mode, options.protocol);
    const flags: u32 = mode | if (Threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
    while (true) {
        const rc = posix.system.socket(family, flags, protocol);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.fd_t = @intCast(rc);
                errdefer Threaded.closeFd(fd);
                if (Threaded.socket_flags_unsupported) try setCloexec(fd);
                return fd;
            },
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn setCloexec(fd: posix.fd_t) error{Unexpected}!void {
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return posix.unexpectedErrno(err),
    };
}

fn setNonblocking(fd: posix.fd_t, on: bool) error{Unexpected}!void {
    const current: usize = while (true) {
        const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    const nonblock: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    const next = if (on) current | nonblock else current & ~nonblock;
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, next))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return posix.unexpectedErrno(err),
    };
}

fn localAddress(fd: posix.fd_t) error{Unexpected}!net.IpAddress {
    var storage: Threaded.PosixAddress = undefined;
    var length: posix.socklen_t = @sizeOf(Threaded.PosixAddress);
    while (true) switch (posix.errno(posix.system.getsockname(fd, &storage.any, &length))) {
        .SUCCESS => return Threaded.addressFromPosix(&storage),
        .INTR => continue,
        else => |err| return posix.unexpectedErrno(err),
    };
}

const testing = std.testing;

fn loopback(port: u16) net.IpAddress {
    return .{ .ip4 = .loopback(port) };
}

fn isNonblocking(fd: posix.fd_t) !bool {
    const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(rc) != .SUCCESS) return error.Unexpected;
    const flags: usize = @intCast(rc);
    return flags & (@as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK")) != 0;
}

/// Closes with a reset, so a test that connects many times leaves no
/// TIME_WAIT sockets behind.
fn closeWithReset(fd: posix.fd_t) void {
    const linger: std.c.linger = .{ .onoff = 1, .linger = 0 };
    _ = posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.LINGER, @ptrCast(&linger), @sizeOf(std.c.linger));
    Threaded.closeFd(fd);
}

/// Reads until the peer closes `fd` or the read fails.
fn waitForClose(fd: posix.fd_t) void {
    var byte: [1]u8 = undefined;
    while (true) {
        const rc = posix.system.read(fd, &byte, byte.len);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc == 0) return,
            .INTR => {},
            else => return,
        }
    }
}

fn ignoreSignal(_: posix.SIG) callconv(.c) void {}

/// Makes SIGIO interrupt blocking calls without killing the process, as
/// `std.Io.Threaded` does, until `restore`.
const SigioHandler = struct {
    previous: posix.Sigaction,

    fn install() SigioHandler {
        const action: posix.Sigaction = .{
            .handler = .{ .handler = ignoreSignal },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        var previous: posix.Sigaction = undefined;
        posix.sigaction(.IO, &action, &previous);
        return .{ .previous = previous };
    }

    fn restore(h: SigioHandler) void {
        posix.sigaction(.IO, &h.previous, null);
    }
};

/// A listener whose accept queue is full, so the next connect to it waits in
/// the kernel until the queue has room. Null when the kernel would not hold a
/// connect pending.
const FullListener = struct {
    server: net.Server,
    queued: [64]posix.fd_t = undefined,
    queued_len: usize = 0,

    fn open(io: std.Io) !?FullListener {
        const any_port = loopback(0);
        var l: FullListener = .{ .server = try any_port.listen(io, .{ .kernel_backlog = 0 }) };
        errdefer l.close(io);
        while (l.queued_len < l.queued.len) {
            const fd = try openSocket(posix.AF.INET, .{ .mode = .stream });
            l.queued[l.queued_len] = fd;
            l.queued_len += 1;
            try setNonblocking(fd, true);
            var storage: Threaded.PosixAddress = undefined;
            const length = Threaded.addressToPosix(&l.server.socket.address, &storage);
            switch (posix.errno(posix.system.connect(fd, &storage.any, length))) {
                .SUCCESS => continue,
                .INPROGRESS => {},
                else => return error.Unexpected,
            }
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            if (posix.system.poll(&fds, fds.len, 200) == 0) return l;
        }
        l.close(io);
        return null;
    }

    fn address(l: *const FullListener) net.IpAddress {
        return l.server.socket.address;
    }

    fn close(l: *FullListener, io: std.Io) void {
        for (l.queued[0..l.queued_len]) |fd| closeWithReset(fd);
        l.server.deinit(io);
    }
};

/// Accepts and closes every connection to `server` on its own thread until
/// `stop`.
const Acceptor = struct {
    server: *net.Server,
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn start(a: *Acceptor) !void {
        a.thread = try std.Thread.spawn(.{}, run, .{a});
    }

    fn run(a: *Acceptor) void {
        while (!a.done.load(.acquire)) {
            const stream = a.server.accept(testing.io) catch continue;
            stream.close(testing.io);
        }
    }

    /// One last connect wakes the accept so the thread sees `done`.
    fn stop(a: *Acceptor) void {
        a.done.store(true, .release);
        if (connect(testing.io, &a.server.socket.address, .{ .mode = .stream })) |socket| closeWithReset(socket.handle) else |_| {}
        a.thread.join();
    }
};

test "connect reaches a local listener and returns a blocking socket" {
    const io = testing.io;
    const address = loopback(0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const socket = try connect(io, &server.socket.address, .{ .mode = .stream });
    defer Threaded.closeFd(socket.handle);
    const accepted = try server.accept(io);
    defer accepted.close(io);

    try testing.expect(!try isNonblocking(socket.handle));
    try testing.expect(socket.address.getPort() != 0);
    try testing.expect(socket.address.getPort() != server.socket.address.getPort());
}

test "connect reports a port nobody listens on as refused" {
    const io = testing.io;
    const address = loopback(0);
    var server = try address.listen(io, .{});
    const closed = server.socket.address;
    server.deinit(io);

    try testing.expectError(error.ConnectionRefused, connect(io, &closed, .{ .mode = .stream }));
}

test "a connect that SIGIO interrupts while it waits still connects" {
    const io = testing.io;
    var listener = (try FullListener.open(io)) orelse return error.SkipZigTest;
    defer listener.close(io);
    const handler = SigioHandler.install();
    defer handler.restore();

    const Attempt = struct {
        address: net.IpAddress,
        result: net.IpAddress.ConnectError!net.Socket = error.Unexpected,
        fn run(a: *@This()) void {
            a.result = connect(testing.io, &a.address, .{ .mode = .stream });
        }
    };
    var attempt: Attempt = .{ .address = listener.address() };
    const thread = try std.Thread.spawn(.{}, Attempt.run, .{&attempt});
    // The connect waits for room in the queue while these signals arrive.
    for (0..5) |_| {
        try io.sleep(.fromMilliseconds(20), .awake);
        _ = std.c.pthread_kill(thread.getHandle(), .IO);
    }
    // Makes room; the waiting connect lands when the kernel retries its
    // handshake.
    var acceptor: Acceptor = .{ .server = &listener.server };
    try acceptor.start();
    thread.join();
    acceptor.stop();

    const socket = try attempt.result;
    Threaded.closeFd(socket.handle);
}

test "connects on worker threads all succeed while another thread sends SIGIO" {
    const io = testing.io;
    const address = loopback(0);
    var server = try address.listen(io, .{ .kernel_backlog = 128 });
    defer server.deinit(io);
    const handler = SigioHandler.install();
    defer handler.restore();

    const workers = 8;
    const connects_per_worker = 300;
    const Shared = struct {
        address: net.IpAddress,
        connected: std.atomic.Value(u32) = .init(0),
        failed: std.atomic.Value(u32) = .init(0),
        first_error: std.atomic.Value(u16) = .init(0),

        fn work(s: *@This()) void {
            for (0..connects_per_worker) |_| {
                const socket = connect(testing.io, &s.address, .{ .mode = .stream }) catch |err| {
                    _ = s.failed.fetchAdd(1, .monotonic);
                    _ = s.first_error.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);
                    continue;
                };
                _ = s.connected.fetchAdd(1, .monotonic);
                // The acceptor closes it once accepted. Waiting for that keeps
                // the accept queue short: macOS resets connects past it.
                waitForClose(socket.handle);
                closeWithReset(socket.handle);
            }
        }
    };
    var shared: Shared = .{ .address = server.socket.address };
    var acceptor: Acceptor = .{ .server = &server };
    try acceptor.start();
    var threads: [workers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.work, .{&shared});

    var signals: usize = 0;
    while (shared.connected.load(.monotonic) + shared.failed.load(.monotonic) < workers * connects_per_worker) {
        for (threads) |t| _ = std.c.pthread_kill(t.getHandle(), .IO);
        signals += 1;
        try io.sleep(.fromMicroseconds(50), .awake);
    }
    for (threads) |t| t.join();
    acceptor.stop();

    try testing.expect(signals > 0);
    const first_error = shared.first_error.load(.monotonic);
    if (first_error != 0) std.debug.print("first connect error: {t}\n", .{@errorFromInt(first_error)});
    try testing.expectEqual(@as(u32, 0), shared.failed.load(.monotonic));
    try testing.expectEqual(@as(u32, workers * connects_per_worker), shared.connected.load(.monotonic));
}

test "waiting for a connect ends promptly when its task is canceled" {
    const io = testing.io;
    var pair: [2]posix.fd_t = undefined;
    if (posix.errno(posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair)) != .SUCCESS) return error.Unexpected;
    defer for (pair) |fd| Threaded.closeFd(fd);
    // A socket whose peer reads nothing stops being writable, as a connect
    // that never finishes does.
    try setNonblocking(pair[0], true);
    const chunk: [4096]u8 = @splat(0);
    for ([_]usize{ chunk.len, 1 }) |size| {
        while (posix.errno(posix.system.write(pair[0], &chunk, size)) == .SUCCESS) {}
    }

    var task = try io.concurrent(awaitConnected, .{ io, pair[0] });
    try io.sleep(.fromMilliseconds(100), .awake);
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const result = task.cancel(io);
    const waited = started.untilNow(io);

    try testing.expectError(error.Canceled, result);
    try testing.expect(waited.raw.toMilliseconds() < 1000);
}
