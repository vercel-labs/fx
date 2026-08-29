//! Minimal RFC 6455 client-side WebSocket codec.
//!
//! This module is transport-policy free: it encodes and decodes frames over
//! caller-provided `std.Io` reader/writer streams and computes handshake keys.
//! Connection management, control-frame policy, and message semantics belong
//! to the caller.

const std = @import("std");

pub const handshake_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
pub const sec_key_len = 24;
pub const accept_key_len = 28;
/// Control frames are never allowed a payload above 125 bytes (RFC 6455 5.5).
pub const max_control_payload_bytes: usize = 125;

/// Encodes 16 random bytes as the `Sec-WebSocket-Key` request header value.
pub fn secKey(random_bytes: [16]u8) [sec_key_len]u8 {
    var out: [sec_key_len]u8 = undefined;
    const written = std.base64.standard.Encoder.encode(&out, &random_bytes);
    std.debug.assert(written.len == sec_key_len);
    return out;
}

/// Computes the `Sec-WebSocket-Accept` value the server must echo for `key`.
pub fn acceptKey(key: []const u8) [accept_key_len]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(handshake_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var out: [accept_key_len]u8 = undefined;
    const written = std.base64.standard.Encoder.encode(&out, &digest);
    std.debug.assert(written.len == accept_key_len);
    return out;
}

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) >= 0x8;
    }
};

pub const FrameHead = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    mask: [4]u8,
    len: u64,
};

pub const ReadFrameError = error{
    WebSocketProtocolError,
    WebSocketFrameTooLarge,
    ReadFailed,
    EndOfStream,
};

/// Reads one frame header. `max_payload_bytes` bounds the declared payload
/// length before the caller allocates anything for it.
pub fn readFrameHead(reader: *std.Io.Reader, max_payload_bytes: u64) ReadFrameError!FrameHead {
    const b0 = takeByte(reader) catch |err| return err;
    const b1 = takeByte(reader) catch |err| return err;
    // RSV bits must be zero: no extension was negotiated.
    if (b0 & 0x70 != 0) return error.WebSocketProtocolError;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0f)));
    const fin = b0 & 0x80 != 0;
    const masked = b1 & 0x80 != 0;
    var len: u64 = b1 & 0x7f;
    if (opcode.isControl() and (!fin or len > max_control_payload_bytes)) {
        return error.WebSocketProtocolError;
    }
    if (len == 126) {
        var ext: [2]u8 = undefined;
        readAll(reader, &ext) catch |err| return err;
        len = std.mem.readInt(u16, &ext, .big);
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        readAll(reader, &ext) catch |err| return err;
        len = std.mem.readInt(u64, &ext, .big);
        if (len & (1 << 63) != 0) return error.WebSocketProtocolError;
    }
    if (len > max_payload_bytes) return error.WebSocketFrameTooLarge;
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) readAll(reader, &mask) catch |err| return err;
    return .{ .fin = fin, .opcode = opcode, .masked = masked, .mask = mask, .len = len };
}

/// Appends the frame payload described by `head` to `out`, unmasking when the
/// sender masked it. The caller has already bounded `head.len`.
pub fn readPayloadInto(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    head: FrameHead,
    out: *std.ArrayList(u8),
) !void {
    const len = std.math.cast(usize, head.len) orelse return error.WebSocketFrameTooLarge;
    if (len == 0) return;
    const start = out.items.len;
    try out.resize(alloc, start + len);
    errdefer out.shrinkRetainingCapacity(start);
    reader.readSliceAll(out.items[start..]) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };
    if (head.masked) {
        for (out.items[start..], 0..) |*byte, index| {
            byte.* ^= head.mask[index % 4];
        }
    }
}

/// Writes one complete client frame. Client frames are always masked
/// (RFC 6455 5.1); the caller supplies the mask so the codec stays
/// deterministic under test.
pub fn writeClientFrame(
    writer: *std.Io.Writer,
    opcode: Opcode,
    payload: []const u8,
    mask: [4]u8,
) !void {
    if (opcode.isControl() and payload.len > max_control_payload_bytes) {
        return error.WebSocketProtocolError;
    }
    var head: [14]u8 = undefined;
    var head_len: usize = 2;
    head[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    if (payload.len <= 125) {
        head[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        head[1] = 0x80 | 126;
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        head_len += 2;
    } else {
        head[1] = 0x80 | 127;
        std.mem.writeInt(u64, head[2..10], payload.len, .big);
        head_len += 8;
    }
    @memcpy(head[head_len..][0..4], &mask);
    head_len += 4;
    try writer.writeAll(head[0..head_len]);

    var chunk: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const take = @min(chunk.len, payload.len - offset);
        for (payload[offset..][0..take], 0..) |byte, index| {
            chunk[index] = byte ^ mask[(offset + index) % 4];
        }
        try writer.writeAll(chunk[0..take]);
        offset += take;
    }
}

fn takeByte(reader: *std.Io.Reader) ReadFrameError!u8 {
    return reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.ReadFailed => error.ReadFailed,
    };
}

fn readAll(reader: *std.Io.Reader, buffer: []u8) ReadFrameError!void {
    reader.readSliceAll(buffer) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };
}

test "WebSocket accept key matches the RFC 6455 vector" {
    const accept = acceptKey("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "WebSocket sec key is 24 base64 bytes" {
    const key = secKey(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    try std.testing.expectEqual(@as(usize, sec_key_len), key.len);
    var decoded: [16]u8 = undefined;
    try std.base64.standard.Decoder.decode(&decoded, &key);
    try std.testing.expectEqual(@as(u8, 16), decoded[15]);
}

test "WebSocket client frames round-trip through the frame reader" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "short",
        "x" ** 126,
        "y" ** 70_000,
    };
    for (cases) |payload| {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try writeClientFrame(&out.writer, .text, payload, .{ 0x11, 0x22, 0x33, 0x44 });

        var reader: std.Io.Reader = .fixed(out.written());
        const head = try readFrameHead(&reader, 1 << 20);
        try std.testing.expect(head.fin);
        try std.testing.expect(head.masked);
        try std.testing.expectEqual(Opcode.text, head.opcode);
        try std.testing.expectEqual(@as(u64, payload.len), head.len);

        var collected: std.ArrayList(u8) = .empty;
        defer collected.deinit(alloc);
        try readPayloadInto(alloc, &reader, head, &collected);
        try std.testing.expectEqualStrings(payload, collected.items);
    }
}

test "WebSocket frame reader decodes unmasked server frames" {
    const alloc = std.testing.allocator;
    // FIN text frame, no mask, payload "ok".
    const bytes = [_]u8{ 0x81, 0x02, 'o', 'k' };
    var reader: std.Io.Reader = .fixed(&bytes);
    const head = try readFrameHead(&reader, 1024);
    try std.testing.expect(head.fin);
    try std.testing.expect(!head.masked);
    try std.testing.expectEqual(@as(u64, 2), head.len);
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(alloc);
    try readPayloadInto(alloc, &reader, head, &collected);
    try std.testing.expectEqualStrings("ok", collected.items);
}

test "WebSocket frame reader rejects reserved bits oversized declarations and long control frames" {
    // RSV1 set.
    {
        const bytes = [_]u8{ 0xC1, 0x00 };
        var reader: std.Io.Reader = .fixed(&bytes);
        try std.testing.expectError(error.WebSocketProtocolError, readFrameHead(&reader, 1024));
    }
    // Declared length above the caller's bound.
    {
        const bytes = [_]u8{ 0x81, 0x7E, 0xFF, 0xFF };
        var reader: std.Io.Reader = .fixed(&bytes);
        try std.testing.expectError(error.WebSocketFrameTooLarge, readFrameHead(&reader, 1024));
    }
    // Fragmented ping.
    {
        const bytes = [_]u8{ 0x09, 0x00 };
        var reader: std.Io.Reader = .fixed(&bytes);
        try std.testing.expectError(error.WebSocketProtocolError, readFrameHead(&reader, 1024));
    }
    // Control frame with an oversized payload declaration.
    {
        const bytes = [_]u8{ 0x89, 0x7E, 0x00, 0x80 };
        var reader: std.Io.Reader = .fixed(&bytes);
        try std.testing.expectError(error.WebSocketProtocolError, readFrameHead(&reader, 1024));
    }
}
