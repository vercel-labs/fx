//! A TCP connect on macOS that a stray SIG.IO cannot fail. The model is
//! tests/tla/mcp_host/Connect.tla; it checks NoFalseFailure, NoFalseSuccess,
//! CancelWins, NoReissue and CanceledNeedsCancel, and the `Std` findings show
//! std's loop failing the first and the fourth.
//!
//! std's `HostName.connect` cancels its helper task on every exit, and the
//! cancel sends SIG.IO to a worker thread that may already run another
//! connect. `Io.Threaded.posixConnect` sees EINTR, asks whether this connect
//! was canceled, hears "no", and calls `connect` again on the same socket.
//! macOS answers ISCONN, which std treats as a bug: error.Unexpected in a
//! release build and an abort in a debug build.
//!
//! This wrapper replaces only `netConnectIp`. It opens the socket the way std
//! does, connects without blocking, and waits for the socket with `poll` in
//! short slices. A signal that ends a wait early only makes the loop go on:
//! `connect` is never called twice. The cancel check between two slices is
//! the public `Io.checkCancel`, which std documents for code that is neither
//! in a syscall nor entering one. A cancel therefore takes effect within one
//! slice, and the socket is closed on every error path.
//!
//! Linux keeps std's connect: a second blocking `connect` on a socket that is
//! still connecting waits there, so the failure has not been seen (this was
//! read in the kernel, not run).

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

const net = std.Io.net;
const c = std.c;
const posix = std.posix;
const Threaded = std.Io.Threaded;

/// Longest wait in `poll` before the cancel check runs again.
const wait_slice_ms: c_int = 25;

var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_original_vtable: ?*const std.Io.VTable = null;

/// Returns `original` with `netConnectIp` replaced. The vtable copy lives in
/// static storage, and every call must pass the same original, as in
/// `darwin_process_spawn.wrap`. Other targets get `original` back.
pub fn wrap(original: std.Io) std.Io {
    if (comptime builtin.os.tag != .macos) return original;
    if (wrapped_original_vtable) |original_vtable| {
        std.debug.assert(original_vtable == original.vtable);
    } else {
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.netConnectIp = netConnectIp;
        wrapped_original_vtable = original.vtable;
    }
    return .{
        .userdata = original.userdata,
        .vtable = &wrapped_vtable,
    };
}

const ConnectError = net.IpAddress.ConnectError;
const StartFn = *const fn (fd: c.fd_t, addr: *const posix.sockaddr, len: posix.socklen_t) callconv(.c) c_int;

fn netConnectIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) ConnectError!net.Socket {
    const original = wrapped_original_vtable.?;
    // std has no timeout for a POSIX connect and stops with a TODO panic; the
    // wrapper must not change what a caller with a timeout gets today.
    if (options.timeout != .none) return original.netConnectIp(userdata, address, options);
    return connectWith(.{ .userdata = userdata, .vtable = original }, address, options, c.connect);
}

/// `start` is `connect`; tests pass a stand-in to make a connect that waits.
fn connectWith(io: std.Io, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions, start: StartFn) ConnectError!net.Socket {
    // As std's `Syscall.start`: a connect that is already canceled opens nothing.
    try io.checkCancel();
    const family = Threaded.posixAddressFamily(address);
    const mode, const protocol = try Threaded.posixSocketModeProtocol(family, options.mode, options.protocol);
    const fd = try openSocket(io, family, mode, protocol);
    trace(fd, "start", null);
    const socket = connectOpened(io, fd, address, start) catch |err| {
        Threaded.closeFd(fd);
        trace(fd, "done", resultName(err));
        return err;
    };
    trace(fd, "done", "ok");
    return socket;
}

/// One line per event under the FX_TRACE scope `net`, read by
/// tests/tla/drivers/mcp_host/connect.test.ts. It holds the descriptor and the
/// outcome and never the address.
fn trace(fd: c.fd_t, comptime event: []const u8, result: ?[]const u8) void {
    if (result) |name| {
        debug_trace.logf("net", "connect fd={d} event=" ++ event ++ " result={s}", .{ fd, name });
    } else {
        debug_trace.logf("net", "connect fd={d} event=" ++ event, .{fd});
    }
}

fn resultName(err: ConnectError) []const u8 {
    return switch (err) {
        error.Canceled => "canceled",
        error.ConnectionRefused => "refused",
        else => "other",
    };
}

/// Opens the socket as `openSocketPosix` does on macOS: the socket call with
/// the mode and protocol std derives, then FD_CLOEXEC through `fcntl` (macOS
/// has no SOCK_CLOEXEC). std sets no other option.
fn openSocket(io: std.Io, family: posix.sa_family_t, mode: u32, protocol: u32) ConnectError!c.fd_t {
    while (true) {
        const rc = posix.system.socket(family, mode, protocol);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: c.fd_t = @intCast(rc);
                if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS) {
                    Threaded.closeFd(fd);
                    return error.Unexpected;
                }
                return fd;
            },
            .INTR => try io.checkCancel(),
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => return error.Unexpected,
        }
    }
}

/// Connects the open socket `fd` and leaves it blocking, as std's connect
/// returns it, with the local address that `getsockname` reports. The caller
/// closes `fd` when this fails.
fn connectOpened(io: std.Io, fd: c.fd_t, address: *const net.IpAddress, start: StartFn) ConnectError!net.Socket {
    try setNonBlocking(fd, true);
    var storage: Threaded.PosixAddress = undefined;
    var addr_len = Threaded.addressToPosix(address, &storage);
    switch (posix.errno(start(fd, &storage.any, addr_len))) {
        .SUCCESS => {},
        // EINTR leaves the connect running in the kernel, as EINPROGRESS does.
        // Calling `connect` again is what std does and what macOS refuses.
        .INTR => {
            trace(fd, "intr", null);
            try awaitConnected(io, fd);
        },
        .INPROGRESS => try awaitConnected(io, fd),
        else => |err| return connectError(err),
    }
    try setNonBlocking(fd, false);
    if (posix.errno(c.getsockname(fd, &storage.any, &addr_len)) != .SUCCESS) return error.Unexpected;
    return .{ .handle = fd, .address = Threaded.addressFromPosix(&storage) };
}

/// Waits until the kernel has finished the connect and reads its outcome from
/// SO_ERROR. A signal that ends a `poll` early only repeats the wait.
fn awaitConnected(io: std.Io, fd: c.fd_t) ConnectError!void {
    while (true) {
        try io.checkCancel();
        var pfd: c.pollfd = .{ .fd = fd, .events = c.POLL.OUT, .revents = 0 };
        const rc = c.poll(@ptrCast(&pfd), 1, wait_slice_ms);
        if (rc > 0) break;
        if (rc == 0) continue;
        switch (posix.errno(rc)) {
            .INTR => trace(fd, "intr", null),
            .AGAIN, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
    var so_error: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    if (posix.errno(c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &so_error, &len)) != .SUCCESS) return error.Unexpected;
    if (so_error != 0) return connectError(@fromBackingInt(@intCast(so_error)));
}

fn setNonBlocking(fd: c.fd_t, on: bool) ConnectError!void {
    const got = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(got) != .SUCCESS) return error.Unexpected;
    var flags: usize = @intCast(got);
    const bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    if (on) flags |= bit else flags &= ~bit;
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, flags)) != .SUCCESS) return error.Unexpected;
}

/// The errors of `posixConnect`, with the same names. Errnos that std treats
/// as programmer bugs (and panics on in a debug build) become
/// error.Unexpected here.
fn connectError(err: posix.E) ConnectError {
    return switch (err) {
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .AGAIN, .INPROGRESS => error.WouldBlock,
        .ALREADY => error.ConnectionPending,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .ACCES => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        else => error.Unexpected,
    };
}

/// Accepts and closes every connection on `listener_fd` until `stop` is set.
fn acceptLoop(listener_fd: c.fd_t, stop: *std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        var pfd: c.pollfd = .{ .fd = listener_fd, .events = c.POLL.IN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, 20) <= 0) continue;
        const fd = c.accept(listener_fd, null, null);
        if (fd >= 0) _ = c.close(fd);
    }
}

/// Sends SIG.IO to `target` as fast as it can until `stop` is set.
fn stormLoop(target: c.pthread_t, stop: *std.atomic.Value(bool), sent: *std.atomic.Value(u32)) void {
    while (!stop.load(.acquire)) {
        _ = c.pthread_kill(target, .IO);
        _ = sent.fetchAdd(1, .monotonic);
        std.Thread.yield() catch {};
    }
}

const Loop = struct {
    connects: usize = 0,
    err: ?anyerror = null,
};

/// Connects and closes at least `count` times, and goes on until the storm has
/// sent `min_signals`, so that the signals land on connects in flight in any
/// build mode.
fn connectLoop(io: std.Io, address: net.IpAddress, count: usize, min_signals: u32, sent: *const std.atomic.Value(u32), out: *Loop) void {
    while (out.connects < count or sent.load(.monotonic) < min_signals) {
        const stream = address.connect(io, .{ .mode = .stream }) catch |err| {
            out.err = err;
            return;
        };
        stream.close(io);
        out.connects += 1;
    }
}

fn openDescriptors() usize {
    var count: usize = 0;
    var fd: c_int = 0;
    while (fd < 512) : (fd += 1) {
        if (c.fcntl(fd, c.F.GETFD) != -1) count += 1;
    }
    return count;
}

fn connectOnce(io: std.Io, address: net.IpAddress) net.IpAddress.ConnectError!net.Stream {
    return address.connect(io, .{ .mode = .stream });
}

test "a storm of SIG.IO does not fail connects" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const address: net.IpAddress = .{ .ip4 = .loopback(server.socket.address.getPort()) };

    var stop: std.atomic.Value(bool) = .init(false);
    var sent: std.atomic.Value(u32) = .init(0);
    const acceptor = try std.Thread.spawn(.{}, acceptLoop, .{ server.socket.handle, &stop });
    var loop: Loop = .{};
    const connector = try std.Thread.spawn(.{}, connectLoop, .{ io, address, 3000, 2000, &sent, &loop });
    const storm = try std.Thread.spawn(.{}, stormLoop, .{ connector.getHandle(), &stop, &sent });

    connector.join();
    stop.store(true, .release);
    storm.join();
    acceptor.join();
    try std.testing.expectEqual(@as(?anyerror, null), loop.err);
    try std.testing.expect(loop.connects >= 3000);
}

test "a canceled connect ends connected or canceled and leaves no descriptor" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const address: net.IpAddress = .{ .ip4 = .loopback(server.socket.address.getPort()) };
    var stop: std.atomic.Value(bool) = .init(false);
    const acceptor = try std.Thread.spawn(.{}, acceptLoop, .{ server.socket.handle, &stop });

    const before = openDescriptors();
    var canceled: usize = 0;
    var connected: usize = 0;
    for (0..400) |i| {
        var future = io.async(connectOnce, .{ io, address });
        // Cancel at many points: at once, after a yield, after a short sleep.
        if (i % 3 == 1) std.Thread.yield() catch {};
        if (i % 3 == 2) io_mod.sleep(20 * std.time.ns_per_us);
        const started = io_mod.nanoTimestamp();
        if (future.cancel(io)) |stream| {
            stream.close(io);
            connected += 1;
        } else |err| {
            try std.testing.expectEqual(error.Canceled, err);
            canceled += 1;
        }
        const elapsed_ms = @divTrunc(io_mod.nanoTimestamp() - started, std.time.ns_per_ms);
        try std.testing.expect(elapsed_ms < 100);
    }
    stop.store(true, .release);
    acceptor.join();
    try std.testing.expectEqual(@as(usize, 400), canceled + connected);
    try std.testing.expectEqual(before, openDescriptors());
}

// macOS answers a non-blocking connect to a closed loopback port with
// EINPROGRESS, then POLLHUP and SO_ERROR = ECONNREFUSED. This test is the
// SO_ERROR path.
test "a refused connect reports a refused connection and leaves no descriptor" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    const before = openDescriptors();
    // A port nothing listens on: listen, read the port, close.
    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var probe = try any.listen(io, .{});
    const dead: net.IpAddress = .{ .ip4 = .loopback(probe.socket.address.getPort()) };
    probe.deinit(io);
    try std.testing.expectError(error.ConnectionRefused, connectOnce(io, dead));
    try std.testing.expectEqual(before, openDescriptors());
}

/// Stands in for `connect`: the kernel is still connecting and never ends.
/// A socket that is not connected never reports POLLOUT, so the wait goes on.
fn holdConnect(_: c.fd_t, _: *const posix.sockaddr, _: posix.socklen_t) callconv(.c) c_int {
    c._errno().* = @backingInt(posix.E.INPROGRESS);
    return -1;
}

/// Stands in for `connect`: it fails at once.
fn failConnect(_: c.fd_t, _: *const posix.sockaddr, _: posix.socklen_t) callconv(.c) c_int {
    c._errno().* = @backingInt(posix.E.NETUNREACH);
    return -1;
}

fn connectWithStub(io: std.Io, address: net.IpAddress, start: StartFn) ConnectError!net.Socket {
    return connectWith(io, &address, .{ .mode = .stream }, start);
}

fn cpuMicroseconds() i64 {
    var usage: c.rusage = undefined;
    const rc = c.getrusage(c.rusage.SELF, &usage);
    std.debug.assert(rc == 0);
    const user = @as(i64, usage.utime.sec) * std.time.us_per_s + usage.utime.usec;
    const system = @as(i64, usage.stime.sec) * std.time.us_per_s + usage.stime.usec;
    return user + system;
}

test "the Io of these tests connects through the wrapper" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    try std.testing.expect(io.vtable.netConnectIp == &netConnectIp);
    try std.testing.expect(io.vtable.netConnectIp != std.testing.io.vtable.netConnectIp);
}

test "a connect that waits ends within one slice of a cancel, uses no CPU while it waits, and leaves no descriptor" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    const address: net.IpAddress = .{ .ip4 = .loopback(9) };
    const before = openDescriptors();

    var future = io.async(connectWithStub, .{ io, address, holdConnect });
    const cpu_start = cpuMicroseconds();
    const wall_start = io_mod.nanoTimestamp();
    io_mod.sleep(1500 * std.time.ns_per_ms);
    const waited_ms = @divTrunc(io_mod.nanoTimestamp() - wall_start, std.time.ns_per_ms);
    const cpu_ms = @divTrunc(cpuMicroseconds() - cpu_start, std.time.us_per_ms);
    // A 25 ms slice wakes the thread about 60 times in 1.5 s. A spin would
    // burn the whole interval.
    try std.testing.expect(waited_ms >= 1400);
    try std.testing.expect(cpu_ms < 150);

    const started = io_mod.nanoTimestamp();
    try std.testing.expectError(error.Canceled, future.cancel(io));
    const elapsed_ms = @divTrunc(io_mod.nanoTimestamp() - started, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 100);
    try std.testing.expectEqual(before, openDescriptors());
}

test "a connect that fails at once leaves no descriptor" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    const address: net.IpAddress = .{ .ip4 = .loopback(9) };
    const before = openDescriptors();
    for (0..50) |_| try std.testing.expectError(error.NetworkUnreachable, connectWithStub(io, address, failConnect));
    try std.testing.expectEqual(before, openDescriptors());
}

test "a connected socket is blocking, close-on-exec, and carries its local address" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    const any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const address: net.IpAddress = .{ .ip4 = .loopback(server.socket.address.getPort()) };
    var stop: std.atomic.Value(bool) = .init(false);
    const acceptor = try std.Thread.spawn(.{}, acceptLoop, .{ server.socket.handle, &stop });
    defer {
        stop.store(true, .release);
        acceptor.join();
    }

    const stream = try connectOnce(io, address);
    defer stream.close(io);
    const handle = stream.socket.handle;
    const status = posix.system.fcntl(handle, posix.F.GETFL, @as(usize, 0));
    try std.testing.expect(status >= 0);
    try std.testing.expectEqual(@as(usize, 0), @as(usize, @intCast(status)) & (1 << @bitOffsetOf(posix.O, "NONBLOCK")));
    const fd_flags = posix.system.fcntl(handle, posix.F.GETFD, @as(usize, 0));
    try std.testing.expect(fd_flags >= 0);
    try std.testing.expect(@as(usize, @intCast(fd_flags)) & posix.FD_CLOEXEC != 0);
    // The address is the one `getsockname` reports: loopback with a port.
    try std.testing.expect(stream.socket.address.getPort() != 0);
    try std.testing.expect(stream.socket.address.getPort() != server.socket.address.getPort());
}
