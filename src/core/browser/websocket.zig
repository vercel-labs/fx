//! A small RFC 6455 WebSocket client for the Chrome DevTools Protocol (D195).
//!
//! It speaks plain `ws://` to a local or configured CDP endpoint: one HTTP
//! upgrade, masked client frames, and unmasked server frames reassembled into
//! whole text messages. Reads wait with `poll`, so a caller bounds every wait
//! and checks its cancel flag between slices.
const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// The GUID RFC 6455 section 1.3 appends to the key before hashing.
const accept_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/// The largest message the client assembles. A full-page screenshot or the
/// accessibility tree of a large page stays well under it.
pub const max_message_bytes: usize = 64 * 1024 * 1024;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Error = error{
    HandshakeFailed,
    ConnectionClosed,
    ProtocolViolation,
    MessageTooLarge,
    Cancelled,
    OutOfMemory,
    WriteFailed,
    ReadFailed,
};

/// Writes one client frame: FIN set, masked with `mask` as section 5.3 requires.
/// The caller owns the returned bytes.
pub fn encodeFrame(alloc: Allocator, opcode: Opcode, payload: []const u8, mask: [4]u8) Allocator.Error![]u8 {
    var header: [14]u8 = undefined;
    header[0] = 0x80 | @as(u8, @backingInt(opcode));
    var len: usize = 2;
    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        len = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        len = 10;
    }
    @memcpy(header[len .. len + 4], &mask);
    len += 4;
    const out = try alloc.alloc(u8, len + payload.len);
    @memcpy(out[0..len], header[0..len]);
    for (payload, 0..) |byte, index| out[len + index] = byte ^ mask[index % 4];
    return out;
}

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    /// Offset of the payload in the parsed bytes.
    payload_start: usize,
    payload_len: usize,
    /// Bytes the whole frame takes.
    total: usize,
};

/// Parses one frame from the front of `bytes`, or returns null when more
/// bytes are needed. A masked server frame is unmasked in place.
pub fn parseFrame(bytes: []u8) Error!?Frame {
    if (bytes.len < 2) return null;
    const fin = bytes[0] & 0x80 != 0;
    if (bytes[0] & 0x70 != 0) return error.ProtocolViolation;
    const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(bytes[0]))));
    const masked = bytes[1] & 0x80 != 0;
    var payload_len: u64 = bytes[1] & 0x7F;
    var offset: usize = 2;
    if (payload_len == 126) {
        if (bytes.len < 4) return null;
        payload_len = std.mem.readInt(u16, bytes[2..4], .big);
        offset = 4;
    } else if (payload_len == 127) {
        if (bytes.len < 10) return null;
        payload_len = std.mem.readInt(u64, bytes[2..10], .big);
        offset = 10;
    }
    if (payload_len > max_message_bytes) return error.MessageTooLarge;
    var mask: [4]u8 = undefined;
    if (masked) {
        if (bytes.len < offset + 4) return null;
        @memcpy(&mask, bytes[offset .. offset + 4]);
        offset += 4;
    }
    const len: usize = @intCast(payload_len);
    if (bytes.len < offset + len) return null;
    if (masked) {
        for (bytes[offset .. offset + len], 0..) |*byte, index| byte.* ^= mask[index % 4];
    }
    return .{ .fin = fin, .opcode = opcode, .payload_start = offset, .payload_len = len, .total = offset + len };
}

/// The `Sec-WebSocket-Accept` value a server must answer `key` with.
pub fn acceptKey(key: []const u8) [28]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(accept_guid);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// Reassembles fragmented messages and answers control frames. It holds the
/// bytes read but not yet parsed.
pub const Assembler = struct {
    pending: std.ArrayList(u8) = .empty,
    message: std.ArrayList(u8) = .empty,
    in_message: bool = false,

    pub fn deinit(self: *Assembler, alloc: Allocator) void {
        self.pending.deinit(alloc);
        self.message.deinit(alloc);
    }

    pub const Event = union(enum) {
        /// A whole text or binary message; the caller owns it.
        message: []u8,
        /// The server pinged; answer with this payload.
        ping: []u8,
        closed,
    };

    /// Takes the next event out of the buffered bytes, or null when a frame is
    /// still incomplete.
    pub fn next(self: *Assembler, alloc: Allocator) Error!?Event {
        while (true) {
            const frame = (try parseFrame(self.pending.items)) orelse return null;
            const payload = self.pending.items[frame.payload_start .. frame.payload_start + frame.payload_len];
            defer self.consume(frame.total);
            switch (frame.opcode) {
                .close => return .closed,
                .ping => return .{ .ping = try alloc.dupe(u8, payload) },
                .pong => continue,
                .text, .binary => {
                    if (self.in_message) return error.ProtocolViolation;
                    if (frame.fin) return .{ .message = try alloc.dupe(u8, payload) };
                    self.in_message = true;
                    self.message.clearRetainingCapacity();
                    try self.message.appendSlice(alloc, payload);
                },
                .continuation => {
                    if (!self.in_message) return error.ProtocolViolation;
                    if (self.message.items.len + payload.len > max_message_bytes) return error.MessageTooLarge;
                    try self.message.appendSlice(alloc, payload);
                    if (frame.fin) {
                        self.in_message = false;
                        return .{ .message = try self.message.toOwnedSlice(alloc) };
                    }
                },
                _ => return error.ProtocolViolation,
            }
        }
    }

    fn consume(self: *Assembler, count: usize) void {
        const rest = self.pending.items.len - count;
        if (rest > 0) @memmove(self.pending.items[0..rest], self.pending.items[count..]);
        self.pending.shrinkRetainingCapacity(rest);
    }
};

pub const Endpoint = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Splits `ws://host:port/path`. Only plain ws is supported.
pub fn parseUrl(url: []const u8) ?Endpoint {
    const prefix = "ws://";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const rest = url[prefix.len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    const colon = std.mem.findScalarLast(u8, authority, ':') orelse return .{ .host = authority, .port = 80, .path = path };
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
    if (colon == 0) return null;
    return .{ .host = authority[0..colon], .port = port, .path = path };
}

/// Connects a TCP stream to a numeric or `localhost` host.
pub fn connectTcp(host: []const u8, port: u16) !std.Io.net.Stream {
    const io = io_mod.getIo();
    const literal = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    if (std.Io.net.IpAddress.parse(literal, port)) |address| {
        return address.connect(io, .{ .mode = .stream });
    } else |_| {}
    const name = try std.Io.net.HostName.init(host);
    return name.connect(io, port, .{ .mode = .stream });
}

/// Waits up to `timeout_ms` for `fd` to be readable. A cancelled flag wins.
pub fn waitReadable(fd: std.posix.fd_t, timeout_ms: i64, cancel: ?*std.atomic.Value(bool)) Error!bool {
    const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
    while (true) {
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        const left = deadline - io_mod.monotonicMilliTimestamp();
        if (left <= 0) return false;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(@min(left, 100))) catch return error.ReadFailed;
        if (ready > 0) return true;
    }
}

pub const Client = struct {
    stream: std.Io.net.Stream,
    assembler: Assembler = .{},

    pub fn connect(alloc: Allocator, url: []const u8) !Client {
        const endpoint = parseUrl(url) orelse return error.HandshakeFailed;
        const stream = try connectTcp(endpoint.host, endpoint.port);
        var client: Client = .{ .stream = stream };
        errdefer client.close(alloc);
        try client.handshake(alloc, endpoint);
        return client;
    }

    fn handshake(self: *Client, alloc: Allocator, endpoint: Endpoint) !void {
        const io = io_mod.getIo();
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);
        const request = try alloc.print(
            "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ endpoint.path, endpoint.host, endpoint.port, key },
        );
        defer alloc.free(request);
        try self.writeAll(request);

        // Read the response head; any bytes after it are the first frames.
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(alloc);
        const end = while (true) {
            if (std.mem.find(u8, head.items, "\r\n\r\n")) |index| break index;
            if (head.items.len > 16 * 1024) return error.HandshakeFailed;
            if (!try waitReadable(self.stream.socket.handle, 10_000, null)) return error.HandshakeFailed;
            var buf: [4096]u8 = undefined;
            const n = try self.readSome(&buf);
            if (n == 0) return error.HandshakeFailed;
            try head.appendSlice(alloc, buf[0..n]);
        };
        const response = head.items[0..end];
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) return error.HandshakeFailed;
        const expected = acceptKey(&key);
        var lines = std.mem.splitSequence(u8, response, "\r\n");
        var accepted = false;
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "sec-websocket-accept")) continue;
            accepted = std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), &expected);
        }
        if (!accepted) return error.HandshakeFailed;
        try self.assembler.pending.appendSlice(alloc, head.items[end + 4 ..]);
    }

    fn readSome(self: *Client, buf: []u8) Error!usize {
        return std.posix.read(self.stream.socket.handle, buf) catch |err| switch (err) {
            error.ConnectionResetByPeer => error.ConnectionClosed,
            else => error.ReadFailed,
        };
    }

    fn writeAll(self: *Client, bytes: []const u8) Error!void {
        var buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io_mod.getIo(), &buf);
        writer.interface.writeAll(bytes) catch return error.WriteFailed;
        writer.interface.flush() catch return error.WriteFailed;
    }

    pub fn sendText(self: *Client, alloc: Allocator, payload: []const u8) Error!void {
        return self.sendFrame(alloc, .text, payload);
    }

    fn sendFrame(self: *Client, alloc: Allocator, opcode: Opcode, payload: []const u8) Error!void {
        var mask: [4]u8 = undefined;
        io_mod.getIo().random(&mask);
        const frame = try encodeFrame(alloc, opcode, payload, mask);
        defer alloc.free(frame);
        try self.writeAll(frame);
    }

    /// The next whole message, owned by the caller, or null when none arrives
    /// within `timeout_ms`.
    pub fn receive(self: *Client, alloc: Allocator, timeout_ms: i64, cancel: ?*std.atomic.Value(bool)) Error!?[]u8 {
        const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
        while (true) {
            if (try self.assembler.next(alloc)) |event| switch (event) {
                .message => |message| return message,
                .ping => |payload| {
                    defer alloc.free(payload);
                    try self.sendFrame(alloc, .pong, payload);
                    continue;
                },
                .closed => return error.ConnectionClosed,
            };
            const left = deadline - io_mod.monotonicMilliTimestamp();
            if (left <= 0) return null;
            if (!try waitReadable(self.stream.socket.handle, left, cancel)) return null;
            var buf: [64 * 1024]u8 = undefined;
            const n = try self.readSome(&buf);
            if (n == 0) return error.ConnectionClosed;
            if (self.assembler.pending.items.len + n > max_message_bytes + 16) return error.MessageTooLarge;
            try self.assembler.pending.appendSlice(alloc, buf[0..n]);
        }
    }

    pub fn close(self: *Client, alloc: Allocator) void {
        self.sendFrame(alloc, .close, &.{}) catch {};
        self.stream.close(io_mod.getIo());
        self.assembler.deinit(alloc);
    }
};

test "websocket client frames are masked and size-prefixed per RFC 6455" {
    const alloc = std.testing.allocator;
    const mask = [4]u8{ 1, 2, 3, 4 };
    const small = try encodeFrame(alloc, .text, "Hi", mask);
    defer alloc.free(small);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x82, 1, 2, 3, 4, 'H' ^ 1, 'i' ^ 2 }, small);

    const mid_payload = try alloc.alloc(u8, 300);
    defer alloc.free(mid_payload);
    @memset(mid_payload, 'a');
    const mid = try encodeFrame(alloc, .text, mid_payload, mask);
    defer alloc.free(mid);
    try std.testing.expectEqual(@as(u8, 0x80 | 126), mid[1]);
    try std.testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, mid[2..4], .big));
    try std.testing.expectEqual(@as(usize, 4 + 4 + 300), mid.len);

    const big_payload = try alloc.alloc(u8, 70_000);
    defer alloc.free(big_payload);
    @memset(big_payload, 'b');
    const big = try encodeFrame(alloc, .binary, big_payload, mask);
    defer alloc.free(big);
    try std.testing.expectEqual(@as(u8, 0x80 | 127), big[1]);
    try std.testing.expectEqual(@as(u64, 70_000), std.mem.readInt(u64, big[2..10], .big));
}

test "websocket parses masked frames and waits for incomplete ones" {
    const alloc = std.testing.allocator;
    const frame = try encodeFrame(alloc, .text, "hello", .{ 9, 8, 7, 6 });
    defer alloc.free(frame);
    try std.testing.expect((try parseFrame(frame[0..3])) == null);
    const parsed = (try parseFrame(frame)).?;
    try std.testing.expect(parsed.fin);
    try std.testing.expectEqual(Opcode.text, parsed.opcode);
    try std.testing.expectEqualStrings("hello", frame[parsed.payload_start .. parsed.payload_start + parsed.payload_len]);
    var reserved = [_]u8{ 0xF1, 0x00 };
    try std.testing.expectError(error.ProtocolViolation, parseFrame(&reserved));
}

test "websocket assembler joins fragments, surfaces pings, and reports close" {
    const alloc = std.testing.allocator;
    var assembler: Assembler = .{};
    defer assembler.deinit(alloc);
    // Server frames are unmasked: "ab" (no FIN), ping "p", "cd" (FIN), close.
    try assembler.pending.appendSlice(alloc, &.{ 0x01, 0x02, 'a', 'b', 0x89, 0x01, 'p', 0x80, 0x02, 'c', 'd', 0x88, 0x00 });
    const ping = (try assembler.next(alloc)).?;
    try std.testing.expectEqualStrings("p", ping.ping);
    alloc.free(ping.ping);
    const message = (try assembler.next(alloc)).?;
    defer alloc.free(message.message);
    try std.testing.expectEqualStrings("abcd", message.message);
    try std.testing.expect((try assembler.next(alloc)).? == .closed);
}

test "websocket accept key matches the RFC 6455 example" {
    const accept = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "websocket urls split into host, port and path" {
    const endpoint = parseUrl("ws://127.0.0.1:9222/devtools/browser/abc").?;
    try std.testing.expectEqualStrings("127.0.0.1", endpoint.host);
    try std.testing.expectEqual(@as(u16, 9222), endpoint.port);
    try std.testing.expectEqualStrings("/devtools/browser/abc", endpoint.path);
    try std.testing.expect(parseUrl("wss://example.com/x") == null);
    try std.testing.expect(parseUrl("ws://:9/x") == null);
}
