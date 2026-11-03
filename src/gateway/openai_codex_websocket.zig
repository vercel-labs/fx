//! RFC 6455 transport used by the stateful OpenAI Codex Responses route.
//!
//! The browser WebSocket client cannot be reused here because Codex is a TLS
//! endpoint and its connection must remain owned by the provider session. This
//! module keeps the wire framing deliberately small and uses std.http.Client
//! only for its TCP/TLS connection and certificate handling.
const std = @import("std");
const browser_websocket = @import("../core/browser/websocket.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const Header = std.http.Header;

pub const max_handshake_bytes: usize = 64 * 1024;
pub const max_message_bytes: usize = browser_websocket.max_message_bytes;
pub const default_connect_timeout_ms: i64 = 10_000;
pub const default_idle_reuse_ms: i64 = 30_000;
pub const default_ping_interval_ms: i64 = 10_000;
pub const default_pong_timeout_ms: i64 = 60_000;

pub const Error = error{
    InvalidUrl,
    HandshakeFailed,
    ConnectionClosed,
    ProtocolViolation,
    MessageTooLarge,
    Cancelled,
    Timeout,
    WriteFailed,
    ReadFailed,
    OutOfMemory,
    RequestInProgress,
};

const Endpoint = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    protocol: std.http.Client.Protocol,
};

fn parseEndpoint(url: []const u8) ?Endpoint {
    const uri = std.Uri.parse(url) catch return null;
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
    if (protocol != .plain and protocol != .tls) return null;
    if (!std.mem.eql(u8, uri.scheme, "ws") and !std.mem.eql(u8, uri.scheme, "wss")) return null;
    const host_component = uri.host orelse return null;
    const host = switch (host_component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    if (host.len == 0) return null;
    const port: u16 = if (uri.port) |value| value else if (protocol == .tls) 443 else 80;
    const path = switch (uri.path) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    return .{
        .host = host,
        .port = port,
        .path = if (path.len == 0) "/" else path,
        .protocol = protocol,
    };
}

pub const Client = struct {
    alloc: Allocator,
    url: []const u8,
    headers: []const Header,
    http: std.http.Client,
    connection: ?*std.http.Client.Connection = null,
    assembler: browser_websocket.Assembler = .{},
    handshake: std.ArrayList(u8) = .empty,
    last_inbound_ms: i64 = 0,
    last_ping_ms: i64 = 0,
    active_request: bool = false,

    pub fn init(alloc: Allocator, url: []const u8, headers: []const Header) Client {
        return .{
            .alloc = alloc,
            .url = url,
            .headers = headers,
            .http = .{ .allocator = alloc, .io = io_mod.getIo() },
        };
    }

    pub fn deinit(self: *Client) void {
        self.close();
        self.assembler.deinit(self.alloc);
        self.handshake.deinit(self.alloc);
        self.http.deinit();
        self.* = undefined;
    }

    pub fn isOpen(self: *const Client) bool {
        return self.connection != null;
    }

    pub fn isHealthyForReuse(self: *const Client, now_ms: i64, max_idle_ms: i64) bool {
        if (!self.isOpen()) return false;
        if (max_idle_ms <= 0) return true;
        if (self.last_inbound_ms == 0) return false;
        return now_ms - self.last_inbound_ms <= max_idle_ms;
    }

    pub fn connect(
        self: *Client,
        cancel: ?*std.atomic.Value(bool),
        timeout_ms: i64,
    ) Error!void {
        if (self.connection != null) return;
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        const endpoint = parseEndpoint(self.url) orelse return error.InvalidUrl;
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const uri = std.Uri.parse(self.url) catch return error.InvalidUrl;
        const host = std.Io.net.HostName.fromUri(uri, &host_buffer) catch return error.InvalidUrl;
        if (endpoint.protocol == .tls) self.http.now = std.Io.Clock.real.now(io_mod.getIo());
        const connection = self.http.connectTcpOptions(.{
            .host = host,
            .port = endpoint.port,
            .protocol = endpoint.protocol,
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
        }) catch |err| return mapConnectError(err);
        self.connection = connection;
        errdefer self.close();
        try self.sendHandshake(endpoint, cancel, timeout_ms);
        self.last_inbound_ms = io_mod.monotonicMilliTimestamp();
        self.last_ping_ms = self.last_inbound_ms;
    }

    fn mapConnectError(err: anyerror) Error {
        return switch (err) {
            error.Canceled => error.Cancelled,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.NetworkUnreachable,
            error.HostUnreachable,
            => error.HandshakeFailed,
            else => error.HandshakeFailed,
        };
    }

    fn sendHandshake(self: *Client, endpoint: Endpoint, cancel: ?*std.atomic.Value(bool), timeout_ms: i64) Error!void {
        var nonce: [16]u8 = undefined;
        io_mod.getIo().random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);

        var request: std.Io.Writer.Allocating = .init(self.alloc);
        defer request.deinit();
        const target = if (endpoint.path.len == 0) "/" else endpoint.path;
        try request.writer.print("GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n", .{ target, endpoint.host, endpoint.port, key });
        for (self.headers) |header| {
            if (header.name.len == 0 or std.mem.findScalar(u8, header.name, ':') != null) continue;
            if (std.mem.find(u8, header.value, "\r") != null or std.mem.find(u8, header.value, "\n") != null) continue;
            try request.writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        try request.writer.writeAll("\r\n");
        const connection = self.connection orelse return error.HandshakeFailed;
        connection.writer().writeAll(request.written()) catch return error.WriteFailed;
        connection.flush() catch return error.WriteFailed;

        self.handshake.clearRetainingCapacity();
        const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
        const reader = connection.reader();
        while (std.mem.find(u8, self.handshake.items, "\r\n\r\n") == null) {
            if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
            const remaining = deadline - io_mod.monotonicMilliTimestamp();
            if (remaining <= 0) return error.Timeout;
            const ready = browser_websocket.waitReadable(connection.stream_reader.stream.socket.handle, remaining, cancel) catch |err| return err;
            if (!ready) return error.Timeout;
            var buf: [8192]u8 = undefined;
            var chunks = [_][]u8{buf[0..]};
            const count = reader.readVec(&chunks) catch |err| switch (err) {
                error.EndOfStream => return error.HandshakeFailed,
                error.ReadFailed => return error.ReadFailed,
            };
            if (count == 0) return error.HandshakeFailed;
            if (self.handshake.items.len + count > max_handshake_bytes) return error.HandshakeFailed;
            self.handshake.appendSlice(self.alloc, buf[0..count]) catch return error.OutOfMemory;
        }
        const delimiter = std.mem.find(u8, self.handshake.items, "\r\n\r\n") orelse return error.HandshakeFailed;
        const response = self.handshake.items[0..delimiter];
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101") and !std.mem.startsWith(u8, response, "HTTP/2 101")) return error.HandshakeFailed;
        const expected = browser_websocket.acceptKey(&key);
        const accept = findHeader(response, "sec-websocket-accept") orelse return error.HandshakeFailed;
        if (!std.mem.eql(u8, std.mem.trim(u8, accept, " \t"), &expected)) return error.HandshakeFailed;
        const rest = self.handshake.items[delimiter + 4 ..];
        self.assembler.pending.appendSlice(self.alloc, rest) catch return error.OutOfMemory;
    }

    pub fn handshakeHeader(self: *const Client, name: []const u8) ?[]const u8 {
        return findHeader(self.handshake.items, name);
    }

    pub fn sendText(self: *Client, payload: []const u8) Error!void {
        return self.sendFrame(.text, payload);
    }

    fn sendFrame(self: *Client, opcode: browser_websocket.Opcode, payload: []const u8) Error!void {
        const connection = self.connection orelse return error.ConnectionClosed;
        var mask: [4]u8 = undefined;
        io_mod.getIo().random(&mask);
        const frame = browser_websocket.encodeFrame(self.alloc, opcode, payload, mask) catch return error.OutOfMemory;
        defer self.alloc.free(frame);
        connection.writer().writeAll(frame) catch return error.WriteFailed;
        connection.flush() catch return error.WriteFailed;
    }

    pub fn receive(
        self: *Client,
        alloc: Allocator,
        timeout_ms: i64,
        cancel: ?*std.atomic.Value(bool),
    ) Error!?[]u8 {
        const connection = self.connection orelse return error.ConnectionClosed;
        const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
        while (true) {
            if (try self.assembler.next(alloc)) |event| switch (event) {
                .message => |message| {
                    self.last_inbound_ms = io_mod.monotonicMilliTimestamp();
                    return message;
                },
                .ping => |payload| {
                    defer alloc.free(payload);
                    try self.sendFrame(.pong, payload);
                    self.last_inbound_ms = io_mod.monotonicMilliTimestamp();
                    continue;
                },
                .closed => return error.ConnectionClosed,
            };
            if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
            const now = io_mod.monotonicMilliTimestamp();
            if (self.last_ping_ms == 0 or now - self.last_ping_ms >= default_ping_interval_ms) {
                try self.sendFrame(.ping, &.{});
                self.last_ping_ms = now;
            }
            const remaining = deadline - now;
            if (remaining <= 0) return null;
            const wait_ms = @min(remaining, @max(@as(i64, 1), default_ping_interval_ms -| (now - self.last_ping_ms)));
            const ready = browser_websocket.waitReadable(connection.stream_reader.stream.socket.handle, wait_ms, cancel) catch |err| return err;
            if (!ready) continue;
            var buf: [64 * 1024]u8 = undefined;
            var chunks = [_][]u8{buf[0..]};
            const count = connection.reader().readVec(&chunks) catch |err| switch (err) {
                error.EndOfStream => return error.ConnectionClosed,
                error.ReadFailed => return error.ReadFailed,
            };
            if (count == 0) continue;
            if (self.assembler.pending.items.len + count > max_message_bytes + 16) return error.MessageTooLarge;
            self.assembler.pending.appendSlice(self.alloc, buf[0..count]) catch return error.OutOfMemory;
        }
    }

    pub fn close(self: *Client) void {
        if (self.connection) |connection| {
            self.connection = null;
            self.sendFrameOn(connection, .close, &.{}) catch {};
            connection.closing = true;
            self.http.connection_pool.release(connection, io_mod.getIo());
        }
        self.active_request = false;
    }

    fn sendFrameOn(self: *Client, connection: *std.http.Client.Connection, opcode: browser_websocket.Opcode, payload: []const u8) Error!void {
        var mask: [4]u8 = undefined;
        io_mod.getIo().random(&mask);
        const frame = browser_websocket.encodeFrame(self.alloc, opcode, payload, mask) catch return error.OutOfMemory;
        defer self.alloc.free(frame);
        connection.writer().writeAll(frame) catch return error.WriteFailed;
        connection.flush() catch return error.WriteFailed;
    }
};

fn findHeader(bytes: []const u8, wanted: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), wanted)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

test "Codex websocket frame handshake accepts websocket upgrade" {
    const response = "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: token\r\n\r\n";
    try std.testing.expectEqualStrings("token", findHeader(response, "SEC-WEBSOCKET-ACCEPT").?);
    try std.testing.expect(parseEndpoint("https://chatgpt.com/backend-api/codex/responses") == null);
    const endpoint = parseEndpoint("wss://chatgpt.com/backend-api/codex/responses").?;
    try std.testing.expectEqual(@as(u16, 443), endpoint.port);
    try std.testing.expectEqualStrings("/backend-api/codex/responses", endpoint.path);
}
