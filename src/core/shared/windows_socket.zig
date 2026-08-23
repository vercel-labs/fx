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
