//! Accepting the connection that `poll` found on a listener, without
//! blocking when it is gone.

const std = @import("std");
const net_connect = @import("net_connect.zig");

const posix = std.posix;
const Threaded = std.Io.Threaded;

pub const AcceptError = std.Io.net.Server.AcceptError;

/// Accepts the connection that `poll` found waiting on `server`, or returns
/// null when it is gone, as when another thread took it first. A blocking
/// `accept` would wait for the next connection instead, and a server waiting
/// there never reads its stop or cancel flag. This leaves the listener
/// non-blocking, so accept on it only through this function from then on:
/// the standard `accept` treats a listener with nothing to accept as a bug.
/// Like a stream the standard `accept` returns, the stream blocks and is
/// closed on exec from the moment it exists, through `accept4` where std
/// uses it. macOS has no `accept4` and gives the stream the listener's
/// non-blocking flag, so there both are set after the accept, as std does.
/// The caller owns the returned stream.
pub fn acceptIfWaiting(server: *std.Io.net.Server, io: std.Io) AcceptError!?std.Io.net.Stream {
    const listener = server.socket.handle;
    try net_connect.setNonblocking(listener);
    var storage: Threaded.PosixAddress = undefined;
    var length: posix.socklen_t = @sizeOf(Threaded.PosixAddress);
    const fd: posix.fd_t = while (true) {
        const rc = if (Threaded.socket_flags_unsupported)
            posix.system.accept(listener, &storage.any, &length)
        else
            posix.system.accept4(listener, &storage.any, &length, posix.SOCK.CLOEXEC);
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
    if (Threaded.socket_flags_unsupported) {
        errdefer stream.close(io);
        try net_connect.setCloexec(fd);
        try net_connect.setBlocking(fd);
    }
    return stream;
}

fn listenOnLoopback(io: std.Io) !std.Io.net.Server {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    return address.listen(io, .{ .reuse_address = true });
}

test "a waiting accept returns null when no connection is waiting" {
    var backend: std.Io.Threaded = .init_single_threaded;
    const io = backend.io();
    var server = try listenOnLoopback(io);
    defer server.deinit(io);
    try std.testing.expectEqual(@as(?std.Io.net.Stream, null), try acceptIfWaiting(&server, io));
}

test "a stream the waiting accept returns blocks and is closed on exec" {
    // The listener does not block, and macOS gives an accepted socket the
    // listener's file status flags.
    var backend: std.Io.Threaded = .init_single_threaded;
    const io = backend.io();
    var server = try listenOnLoopback(io);
    defer server.deinit(io);
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(server.socket.address.getPort()) };
    const client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const stream = (try acceptIfWaiting(&server, io)).?;
    defer stream.close(io);
    const flags = posix.system.fcntl(stream.socket.handle, posix.F.GETFL, @as(usize, 0));
    try std.testing.expect(flags >= 0);
    const nonblock: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    try std.testing.expectEqual(@as(usize, 0), @as(usize, @intCast(flags)) & nonblock);
    const fd_flags = posix.system.fcntl(stream.socket.handle, posix.F.GETFD, @as(usize, 0));
    try std.testing.expect(fd_flags >= 0);
    try std.testing.expect(@as(usize, @intCast(fd_flags)) & posix.FD_CLOEXEC != 0);
}
