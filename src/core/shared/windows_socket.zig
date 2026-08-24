const std = @import("std");

const windows = std.os.windows;

pub const poll_read: i16 = 0x0100 | 0x0200;
pub const poll_write: i16 = 0x0010;
pub const poll_error: i16 = 0x0001;
pub const poll_hangup: i16 = 0x0002;
pub const poll_invalid: i16 = 0x0004;

const socket_error = -1;
const sol_socket: c_int = 0xffff;
const so_send_timeout: c_int = 0x1005;
const so_receive_timeout: c_int = 0x1006;

pub const PollFd = extern struct {
    fd: windows.HANDLE,
    events: i16,
    revents: i16,
};

extern "ws2_32" fn WSAPoll(
    fds: [*]PollFd,
    count: windows.ULONG,
    timeout_ms: c_int,
) callconv(.winapi) c_int;

extern "ws2_32" fn setsockopt(
    socket: windows.HANDLE,
    level: c_int,
    option_name: c_int,
    option_value: *const anyopaque,
    option_length: c_int,
) callconv(.winapi) c_int;

pub const PollResult = struct {
    ready: bool = false,
    hung_up: bool = false,
    has_error: bool = false,
    invalid: bool = false,
};

const AcceptEvent = union(enum) {
    connection: anyerror!std.Io.net.Stream,
    timeout: anyerror!void,
};

fn acceptConnection(
    io: std.Io,
    server: *std.Io.net.Server,
) anyerror!std.Io.net.Stream {
    return server.accept(io);
}

fn waitAcceptTimeout(io: std.Io, timeout_ms: u32) anyerror!void {
    try io.sleep(.fromMilliseconds(timeout_ms), .awake);
}

fn cancelAccept(io: std.Io, select: *std.Io.Select(AcceptEvent)) void {
    while (select.cancel()) |event| switch (event) {
        .connection => |result| {
            const stream = result catch continue;
            stream.close(io);
        },
        .timeout => {},
    };
}

pub fn acceptWithTimeout(
    io: std.Io,
    server: *std.Io.net.Server,
    timeout_ms: u32,
) !?std.Io.net.Stream {
    var buffer: [2]AcceptEvent = undefined;
    var select: std.Io.Select(AcceptEvent) = .init(io, &buffer);
    try select.concurrent(.connection, acceptConnection, .{ io, server });
    select.concurrent(.timeout, waitAcceptTimeout, .{ io, timeout_ms }) catch |err| {
        cancelAccept(io, &select);
        return err;
    };
    const event = select.await() catch |err| {
        cancelAccept(io, &select);
        return err;
    };
    return switch (event) {
        .connection => |result| blk: {
            select.cancelDiscard();
            break :blk try result;
        },
        .timeout => |result| blk: {
            result catch |err| {
                cancelAccept(io, &select);
                return err;
            };
            cancelAccept(io, &select);
            break :blk null;
        },
    };
}

pub fn poll(socket: windows.HANDLE, events: i16, timeout_ms: i32) !PollResult {
    var fds = [_]PollFd{.{ .fd = socket, .events = events, .revents = 0 }};
    const ready = WSAPoll(&fds, 1, timeout_ms);
    if (ready == socket_error) return error.SocketPollFailed;
    if (ready == 0) return .{};
    const revents = fds[0].revents;
    return .{
        .ready = revents & events != 0,
        .hung_up = revents & poll_hangup != 0,
        .has_error = revents & poll_error != 0,
        .invalid = revents & poll_invalid != 0,
    };
}

pub fn setTimeouts(socket: windows.HANDLE, timeout_ms: u32) !void {
    if (setsockopt(socket, sol_socket, so_receive_timeout, &timeout_ms, @sizeOf(u32)) == socket_error or
        setsockopt(socket, sol_socket, so_send_timeout, &timeout_ms, @sizeOf(u32)) == socket_error)
    {
        return error.SocketOptionFailed;
    }
}

test "Windows AFD listener accepts with a bounded timeout" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    try std.testing.expect((try acceptWithTimeout(io, &server, 10)) == null);

    const ConnectState = struct {
        io: std.Io,
        address: std.Io.net.IpAddress,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.io.sleep(.fromMilliseconds(20), .awake) catch {
                self.failed.store(true, .release);
                return;
            };
            var stream = self.address.connect(self.io, .{ .mode = .stream }) catch {
                self.failed.store(true, .release);
                return;
            };
            stream.close(self.io);
        }
    };
    var state = ConnectState{ .io = io, .address = server.socket.address };
    const connector = try std.Thread.spawn(.{}, ConnectState.run, .{&state});
    defer connector.join();

    var accepted = (try acceptWithTimeout(io, &server, 1000)) orelse
        return error.TestExpectedConnection;
    accepted.close(io);
    try std.testing.expect(!state.failed.load(.acquire));
}
