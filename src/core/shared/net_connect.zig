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
const debug_trace = @import("debug_trace.zig");

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
    return connectWith(startConnect, io, address, options);
}

/// The call that starts the kernel's connect on `fd`. Tests give `connectWith`
/// a stand-in, to make a connect that fails at once or never ends.
fn startConnect(fd: posix.fd_t, address: *const posix.sockaddr, length: posix.socklen_t) posix.E {
    return posix.errno(posix.system.connect(fd, address, length));
}

/// `connect` with `start` as the call that starts the kernel's connect.
fn connectWith(
    comptime start: anytype,
    io: std.Io,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    try io.checkCancel();
    const fd = try openSocket(Threaded.posixAddressFamily(address), options);
    traceConnect(io, fd, "start", null);
    const socket = connectOpened(start, io, fd, address) catch |err| {
        // The line comes before the close: a closed descriptor's number can go to
        // another thread's connect, whose lines would then mix with these.
        traceConnect(io, fd, "done", resultName(err));
        Threaded.closeFd(fd);
        return err;
    };
    traceConnect(io, fd, "done", "ok");
    return socket;
}

/// Connects the open socket `fd` and returns it blocking. The caller closes
/// `fd` when this fails.
fn connectOpened(
    comptime start: anytype,
    io: std.Io,
    fd: posix.fd_t,
    address: *const net.IpAddress,
) net.IpAddress.ConnectError!net.Socket {
    try setNonblocking(fd);
    var storage: Threaded.PosixAddress = undefined;
    const length = Threaded.addressToPosix(address, &storage);
    switch (start(fd, &storage.any, length)) {
        .SUCCESS => {},
        // Interrupted or not, the connection goes on in the kernel.
        .INTR => {
            traceConnect(io, fd, "intr", null);
            try awaitConnected(io, fd);
        },
        .INPROGRESS => try awaitConnected(io, fd),
        else => |err| return connectError(err),
    }
    try setBlocking(fd);
    return .{ .handle = fd, .address = try localAddress(fd) };
}

/// One FX_TRACE line per event under the scope `net`: the descriptor and the
/// outcome, never an address. tests/tla/drivers/mcp_host/connect.test.ts reads
/// them and has TLC check each socket against tests/tla/mcp_host/Connect.tla.
///
/// `debug_trace` writes its file with an Io call that is a cancelation point,
/// and drops the line when that call ends `error.Canceled`. That would take the
/// cancel that this connect is waiting for, so the write runs with cancelation
/// blocked and the cancel stays for the next `io.checkCancel`.
fn traceConnect(io: std.Io, fd: posix.fd_t, comptime event: []const u8, result: ?[]const u8) void {
    const before = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(before);
    if (result) |name| {
        debug_trace.logf("net", "connect fd={d} event=" ++ event ++ " result={s}", .{ fd, name });
    } else {
        debug_trace.logf("net", "connect fd={d} event=" ++ event, .{fd});
    }
}

fn resultName(err: net.IpAddress.ConnectError) []const u8 {
    return switch (err) {
        error.Canceled => "canceled",
        error.ConnectionRefused => "refused",
        else => "other",
    };
}

fn awaitConnected(io: std.Io, fd: posix.fd_t) net.IpAddress.ConnectError!void {
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
        const ready = posix.system.poll(&fds, fds.len, cancel_check_ms);
        switch (posix.errno(ready)) {
            .SUCCESS => if (ready > 0) return socketError(fd),
            .INTR => traceConnect(io, fd, "intr", null),
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

const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");

fn setCloexec(fd: posix.fd_t) error{Unexpected}!void {
    _ = try fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC);
}

fn setNonblocking(fd: posix.fd_t) error{Unexpected}!void {
    const flags = try fcntl(fd, posix.F.GETFL, 0);
    _ = try fcntl(fd, posix.F.SETFL, flags | nonblock_flag);
}

fn setBlocking(fd: posix.fd_t) error{Unexpected}!void {
    const flags = try fcntl(fd, posix.F.GETFL, 0);
    _ = try fcntl(fd, posix.F.SETFL, flags & ~nonblock_flag);
}

/// fcntl(2), called again when a signal interrupts it.
fn fcntl(fd: posix.fd_t, command: c_int, arg: usize) error{Unexpected}!usize {
    while (true) {
        const rc = posix.system.fcntl(fd, command, arg);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
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
const io_mod = @import("io.zig");

fn loopback(port: u16) net.IpAddress {
    return .{ .ip4 = .loopback(port) };
}

fn isNonblocking(fd: posix.fd_t) !bool {
    return try fcntl(fd, posix.F.GETFL, 0) & nonblock_flag != 0;
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

/// The SIGIO signals that reached any thread since `SigioHandler.install`.
var sigio_count: std.atomic.Value(u32) = .init(0);

fn countSignal(_: posix.SIG) callconv(.c) void {
    _ = sigio_count.fetchAdd(1, .monotonic);
}

/// Makes SIGIO interrupt blocking calls without killing the process, as
/// `std.Io.Threaded` does, and counts each one in `sigio_count`, until
/// `restore`.
const SigioHandler = struct {
    previous: posix.Sigaction,

    fn install() SigioHandler {
        sigio_count.store(0, .monotonic);
        const action: posix.Sigaction = .{
            .handler = .{ .handler = countSignal },
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

/// A connected socket pair whose `fds[0]` is not writable because its peer
/// reads nothing: a stand-in for a socket whose connect is still going on.
/// `drain` makes it writable, as the connect finishing does.
const StalledPair = struct {
    fds: [2]posix.fd_t,

    fn open() !StalledPair {
        var fds: [2]posix.fd_t = undefined;
        if (posix.errno(posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds)) != .SUCCESS) return error.Unexpected;
        errdefer for (fds) |fd| Threaded.closeFd(fd);
        for (fds) |fd| try setNonblocking(fd);
        const chunk: [4096]u8 = @splat(0);
        for ([_]usize{ chunk.len, 1 }) |size| {
            while (posix.errno(posix.system.write(fds[0], &chunk, size)) == .SUCCESS) {}
        }
        return .{ .fds = fds };
    }

    /// Reads everything `fds[0]` sent, so it is writable again.
    fn drain(p: StalledPair) !void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const rc = posix.system.read(p.fds[1], &buffer, buffer.len);
            switch (posix.errno(rc)) {
                .SUCCESS => if (rc == 0) return error.Unexpected,
                .INTR => {},
                .AGAIN => return,
                else => return error.Unexpected,
            }
        }
    }

    fn close(p: StalledPair) void {
        for (p.fds) |fd| Threaded.closeFd(fd);
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
    const pair = try StalledPair.open();
    defer pair.close();
    const handler = SigioHandler.install();
    defer handler.restore();

    // This drives the wait that `connect` runs after connect(2), on a stand-in
    // for a pending connect: macOS resets a loopback connect past a full
    // accept queue instead of holding it pending, so a real one cannot be set
    // up on every host. The SIGIO test below covers `connect` itself.
    // `fds[0]` is connected already, as a socket is once the kernel finishes
    // an interrupted connect, so a wait that called connect(2) again, as std
    // does after EINTR, would fail with EISCONN.
    const Wait = struct {
        fd: posix.fd_t,
        result: net.IpAddress.ConnectError!void = error.Unexpected,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(w: *@This()) void {
            w.result = awaitConnected(testing.io, w.fd);
            w.finished.store(true, .release);
        }
    };
    var wait: Wait = .{ .fd = pair.fds[0] };
    const thread = try std.Thread.spawn(.{}, Wait.run, .{&wait});
    // Each signal reaches the waiting thread before the next one is sent.
    for (1..6) |sent| {
        if (wait.finished.load(.acquire)) break;
        _ = std.c.pthread_kill(thread.getHandle(), .IO);
        for (0..1000) |_| {
            if (sigio_count.load(.monotonic) >= sent) break;
            try io.sleep(.fromMilliseconds(1), .awake);
        } else return error.SignalNotDelivered;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    const waited_through_signals = !wait.finished.load(.acquire);
    try pair.drain();
    thread.join();

    try testing.expect(waited_through_signals);
    try wait.result;
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
    if (first_error != 0) return @errorFromInt(first_error);
    try testing.expectEqual(@as(u32, 0), shared.failed.load(.monotonic));
    try testing.expectEqual(@as(u32, workers * connects_per_worker), shared.connected.load(.monotonic));
}

test "waiting for a connect ends promptly when its task is canceled" {
    const io = testing.io;
    const pair = try StalledPair.open();
    defer pair.close();

    var task = try io.concurrent(awaitConnected, .{ io, pair.fds[0] });
    try io.sleep(.fromMilliseconds(100), .awake);
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const result = task.cancel(io);
    const waited = started.untilNow(io);

    try testing.expectError(error.Canceled, result);
    try testing.expect(waited.raw.toMilliseconds() < 1000);
}

/// CPU time the process has used so far, user and system, in microseconds.
fn cpuMicroseconds() i64 {
    const usage = posix.getrusage(0);
    return (@as(i64, usage.utime.sec) + usage.stime.sec) * std.time.us_per_s + usage.utime.usec + usage.stime.usec;
}

/// The descriptor of the socket the last stand-in start call was given.
var started_fd: std.atomic.Value(posix.fd_t) = .init(-1);

/// Starts the real connect and remembers the descriptor.
fn recordingStart(fd: posix.fd_t, address: *const posix.sockaddr, length: posix.socklen_t) posix.E {
    started_fd.store(fd, .release);
    return startConnect(fd, address, length);
}

/// A connect that fails at once.
fn failAtOnceStart(fd: posix.fd_t, _: *const posix.sockaddr, _: posix.socklen_t) posix.E {
    started_fd.store(fd, .release);
    return .NETUNREACH;
}

/// A connect that never ends: a listening socket never becomes writable, on
/// macOS and on Linux, so the wait goes on until a cancel.
fn holdStart(fd: posix.fd_t, _: *const posix.sockaddr, _: posix.socklen_t) posix.E {
    started_fd.store(fd, .release);
    _ = posix.system.listen(fd, 1);
    return .INPROGRESS;
}

/// Whether `fd` is still a stream socket that is not connected: what a
/// connect that failed leaves behind if it does not close its socket. A closed
/// descriptor is not, and neither is one that another thread of the test
/// process reused for a file or a connected socket, so this does not depend on
/// how many descriptors the process has open.
fn looksLeaked(fd: posix.fd_t) bool {
    if (posix.errno(posix.system.fcntl(fd, posix.F.GETFD, @as(usize, 0))) != .SUCCESS) return false;
    var kind: c_int = 0;
    var kind_length: posix.socklen_t = @sizeOf(c_int);
    if (posix.errno(posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.TYPE, @ptrCast(&kind), &kind_length)) != .SUCCESS) return false;
    if (kind != posix.SOCK.STREAM) return false;
    var storage: Threaded.PosixAddress = undefined;
    var length: posix.socklen_t = @sizeOf(Threaded.PosixAddress);
    // Which errno a socket that never connected, or whose connect failed, gives
    // differs between macOS and Linux; only a peer means it is in use.
    return posix.errno(posix.system.getpeername(fd, &storage.any, &length)) != .SUCCESS;
}

/// Each connect of `start` that must fail with `expected` closes its socket.
fn expectFailureClosesSocket(comptime start: anytype, expected: anyerror, address: *const net.IpAddress) !void {
    for (0..20) |_| {
        started_fd.store(-1, .release);
        try testing.expectError(expected, connectWith(start, testing.io, address, .{ .mode = .stream }));
        const fd = started_fd.load(.acquire);
        try testing.expect(fd >= 0);
        try testing.expect(!looksLeaked(fd));
    }
}

test "a refused connect closes its socket" {
    // macOS reports the refusal through SO_ERROR after EINPROGRESS; Linux may
    // report it from connect itself. Both end in the cleanup of `connectWith`.
    const io = testing.io;
    var server = try loopback(0).listen(io, .{});
    const closed = server.socket.address;
    server.deinit(io);
    try expectFailureClosesSocket(recordingStart, error.ConnectionRefused, &closed);
}

test "a connect that fails at once closes its socket" {
    const address = loopback(9);
    try expectFailureClosesSocket(failAtOnceStart, error.NetworkUnreachable, &address);
}

fn holdConnect(io: std.Io, address: net.IpAddress) net.IpAddress.ConnectError!net.Socket {
    return connectWith(holdStart, io, &address, .{ .mode = .stream });
}

test "a cancel while a connect waits closes its socket and ends within 100 ms" {
    const io = testing.io;
    var task = try io.concurrent(holdConnect, .{ io, loopback(9) });
    try io.sleep(.fromMilliseconds(100), .awake);
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const result = task.cancel(io);
    const waited = started.untilNow(io);

    try testing.expectError(error.Canceled, result);
    try testing.expect(waited.raw.toMilliseconds() < 100);
    const fd = started_fd.load(.acquire);
    try testing.expect(fd >= 0);
    try testing.expect(!looksLeaked(fd));
}

var gate_ready: std.atomic.Value(bool) = .init(false);
var gate_open: std.atomic.Value(bool) = .init(false);

/// Waits, without any Io call, until the test has asked this task to cancel,
/// then writes a trace line and checks for the cancel.
fn traceWhileCancelRequested(io: std.Io) error{Canceled}!void {
    gate_ready.store(true, .release);
    while (!gate_open.load(.acquire)) std.Thread.yield() catch {};
    traceConnect(io, 3, "start", null);
    try io.checkCancel();
}

fn openGateSoon(io: std.Io) void {
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    gate_open.store(true, .release);
}

test "a trace line does not swallow the cancel that a connect is waiting for" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "net.log" });
    defer alloc.free(path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, path, "net");

    gate_ready.store(false, .release);
    gate_open.store(false, .release);
    var task = try io.concurrent(traceWhileCancelRequested, .{io});
    var opener = try io.concurrent(openGateSoon, .{io});
    while (!gate_ready.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    // The cancel is requested while the task is still between Io calls: it is
    // delivered at the task's next cancelation point.
    const result = task.cancel(io);
    opener.await(io);
    try testing.expectError(error.Canceled, result);
}

test "a connect writes one start and one done line to the net trace, and no address" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.Io.Dir.path.join(alloc, &.{ root, "net.log" });
    defer alloc.free(path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, path, "net");

    var server = try loopback(0).listen(io, .{});
    const listening = server.socket.address;
    const socket = try connect(io, &listening, .{ .mode = .stream });
    Threaded.closeFd(socket.handle);
    const accepted = try server.accept(io);
    accepted.close(io);
    server.deinit(io);
    try testing.expectError(error.ConnectionRefused, connect(io, &listening, .{ .mode = .stream }));

    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(alloc, &file, 8192);
    defer alloc.free(text);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "event=start"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "event=done result=ok"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "event=done result=refused"));
    try testing.expect(std.mem.find(u8, text, "127.0.0.1") == null);
}

test "waiting for a connect uses no CPU while it waits" {
    // A slice of 20 ms wakes the waiting thread 50 times a second; a loop that
    // spun would use the whole interval.
    const io = testing.io;
    const pair = try StalledPair.open();
    defer pair.close();

    var task = try io.concurrent(awaitConnected, .{ io, pair.fds[0] });
    const cpu_start = cpuMicroseconds();
    try io.sleep(.fromMilliseconds(1500), .awake);
    const cpu_ms = @divTrunc(cpuMicroseconds() - cpu_start, std.time.us_per_ms);
    try testing.expectError(error.Canceled, task.cancel(io));
    try testing.expect(cpu_ms < 150);
}
