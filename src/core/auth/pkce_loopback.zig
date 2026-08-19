const std = @import("std");
const builtin = @import("builtin");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const callback_timeout_ms: i32 = 5 * 60 * 1000;
const callback_poll_ms: i32 = 50;
const callback_io_timeout_seconds: i64 = 30;

pub const Callback = struct {
    code: []u8,
    state: []u8,
    issuer: ?[]u8 = null,
    error_code: ?[]u8 = null,
    error_description: ?[]u8 = null,

    pub fn deinit(self: *Callback, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.code);
        secret.zeroAndFree(alloc, self.state);
        if (self.issuer) |value| alloc.free(value);
        if (self.error_code) |value| alloc.free(value);
        if (self.error_description) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub fn bind(preferred_port: u16) !std.Io.net.Server {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.InteractiveAuthorizationUnsupported;
    }
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", preferred_port);
    return address.listen(io_mod.getIo(), .{ .reuse_address = true });
}

pub fn bindEphemeral() !std.Io.net.Server {
    return bind(0);
}

pub fn redirectUriAlloc(
    alloc: Allocator,
    listener: *const std.Io.net.Server,
    host: []const u8,
    path: []const u8,
) ![]u8 {
    const port = listener.socket.address.getPort();
    return std.fmt.allocPrint(alloc, "http://{s}:{d}{s}", .{ host, port, path });
}

pub fn waitForConnection(
    listener: *std.Io.net.Server,
    cancel_flag: ?*const std.atomic.Value(bool),
) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = listener.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var remaining_ms = callback_timeout_ms;
    while (remaining_ms > 0) {
        try checkCancellation(cancel_flag);
        fds[0].revents = 0;
        const wait_ms = @min(remaining_ms, callback_poll_ms);
        const ready = try std.posix.poll(&fds, wait_ms);
        if (ready > 0) {
            if ((fds[0].revents & std.posix.POLL.IN) == 0) {
                return error.AuthorizationCallbackTimedOut;
            }
            try checkCancellation(cancel_flag);
            return;
        }
        remaining_ms -= wait_ms;
    }
    return error.AuthorizationCallbackTimedOut;
}

pub fn acceptCallback(
    alloc: Allocator,
    listener: *std.Io.net.Server,
    callback_path: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) !Callback {
    try waitForConnection(listener, cancel_flag);

    var stream = try listener.accept(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    setSocketTimeouts(stream.socket.handle, callback_io_timeout_seconds);
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var request_len: usize = 0;
    while (request_len < request_bytes.len) {
        request_bytes[request_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.InvalidAuthorizationCallback,
            else => return err,
        };
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) break;
    }
    if (request_len == request_bytes.len) return error.AuthorizationCallbackTooLarge;
    const line_end = std.mem.indexOf(u8, request_bytes[0..request_len], "\r\n") orelse
        return error.InvalidAuthorizationCallback;
    const request_line = request_bytes[0..line_end];
    if (!std.mem.startsWith(u8, request_line, "GET ")) {
        return error.InvalidAuthorizationCallback;
    }
    const target_end = std.mem.indexOfScalarPos(u8, request_line, 4, ' ') orelse
        return error.InvalidAuthorizationCallback;
    const target = request_line[4..target_end];
    if (!pathMatches(target, callback_path)) {
        return error.InvalidAuthorizationCallback;
    }

    var writer_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &writer_buffer);
    try writer.interface.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: 49\r\n" ++
            "Connection: close\r\n\r\n" ++
            "Authorization received. You can return to fx now.",
    );
    try writer.interface.flush();
    return parseCallbackTarget(alloc, target);
}

pub fn parseCallbackTarget(alloc: Allocator, target: []const u8) !Callback {
    const question = std.mem.indexOfScalar(u8, target, '?') orelse
        return error.InvalidAuthorizationCallback;
    const fragment = std.mem.indexOfScalarPos(u8, target, question + 1, '#') orelse target.len;
    const query = target[question + 1 .. fragment];
    if (queryValueAlloc(alloc, query, "error")) |error_code| {
        errdefer alloc.free(error_code);
        const error_description = queryValueAlloc(alloc, query, "error_description") catch null;
        return .{
            .code = try alloc.dupe(u8, ""),
            .state = queryValueAlloc(alloc, query, "state") catch try alloc.dupe(u8, ""),
            .error_code = error_code,
            .error_description = error_description,
        };
    } else |_| {}
    const code = try queryValueAlloc(alloc, query, "code");
    errdefer secret.zeroAndFree(alloc, code);
    const state = try queryValueAlloc(alloc, query, "state");
    errdefer secret.zeroAndFree(alloc, state);
    const issuer = queryValueAlloc(alloc, query, "iss") catch |err| switch (err) {
        error.MissingQueryParameter => null,
        else => return err,
    };
    return .{
        .code = code,
        .state = state,
        .issuer = issuer,
    };
}

fn pathMatches(target: []const u8, callback_path: []const u8) bool {
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse
        std.mem.indexOfScalar(u8, target, '#') orelse target.len;
    const path = target[0..path_end];
    return std.mem.eql(u8, path, callback_path);
}

fn queryValueAlloc(alloc: Allocator, query: []const u8, key: []const u8) ![]u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], key)) continue;
        return percentDecodeAlloc(alloc, pair[equals + 1 ..]);
    }
    return error.MissingQueryParameter;
}

fn percentDecodeAlloc(alloc: Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '%') {
            if (index + 2 >= value.len) return error.InvalidPercentEncoding;
            const high = std.fmt.charToDigit(value[index + 1], 16) catch return error.InvalidPercentEncoding;
            const low = std.fmt.charToDigit(value[index + 2], 16) catch return error.InvalidPercentEncoding;
            try out.writer.writeByte((high << 4) | low);
            index += 3;
        } else {
            try out.writer.writeByte(if (value[index] == '+') ' ' else value[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice();
}

fn checkCancellation(cancel_flag: ?*const std.atomic.Value(bool)) !void {
    if (cancel_flag) |flag| {
        if (flag.load(.acquire)) return error.Cancelled;
    }
}

fn setSocketTimeouts(socket: std.posix.socket_t, seconds: i64) void {
    if (comptime host_target.is_wasm) return;
    const timeout = std.posix.timeval{ .sec = seconds, .usec = 0 };
    const bytes = std.mem.asBytes(&timeout);
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

test "callback parser reads code state and issuer" {
    var callback = try parseCallbackTarget(
        std.testing.allocator,
        "/auth/callback?code=abc%2F1&state=xyz&iss=https%3A%2F%2Fauth.openai.com",
    );
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc/1", callback.code);
    try std.testing.expectEqualStrings("xyz", callback.state);
    try std.testing.expectEqualStrings("https://auth.openai.com", callback.issuer.?);
    try std.testing.expect(callback.error_code == null);
}

test "callback parser surfaces authorization errors" {
    var callback = try parseCallbackTarget(
        std.testing.allocator,
        "/auth/callback?error=access_denied&error_description=nope&state=s",
    );
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("access_denied", callback.error_code.?);
    try std.testing.expectEqualStrings("nope", callback.error_description.?);
    try std.testing.expectEqualStrings("s", callback.state);
}

test "callback parser rejects a missing query" {
    try std.testing.expectError(
        error.InvalidAuthorizationCallback,
        parseCallbackTarget(std.testing.allocator, "/auth/callback"),
    );
}
