const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_max_frame_bytes: usize = 1 * 1024 * 1024;

pub const Error = error{
    Incomplete,
    LspFrameTooLarge,
    LspMissingContentLength,
    LspInvalidContentLength,
    LspInvalidHeader,
};

pub fn encode(alloc: Allocator, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try write(&out.writer, body);
    return out.toOwnedSlice();
}

pub fn write(writer: *std.Io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}

const Header = struct {
    content_length: usize,
    header_end: usize,
};

pub const Decoder = struct {
    alloc: Allocator,
    buf: std.ArrayList(u8) = .empty,
    max_frame_bytes: usize = default_max_frame_bytes,

    pub fn init(alloc: Allocator) Decoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Decoder) void {
        self.buf.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc };
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        const next_len = self.buf.items.len + bytes.len;
        if (next_len > self.max_frame_bytes + 64) return error.LspFrameTooLarge;
        try self.buf.appendSlice(self.alloc, bytes);
    }

    pub fn next(self: *Decoder) !?[]u8 {
        const header = parseHeader(self.buf.items) catch |err| switch (err) {
            error.Incomplete => return null,
            else => return err,
        };
        if (header.content_length > self.max_frame_bytes) return error.LspFrameTooLarge;
        const total = header.header_end + header.content_length;
        if (self.buf.items.len < total) return null;
        const body = try self.alloc.dupe(u8, self.buf.items[header.header_end..total]);
        const remaining = self.buf.items[total..];
        if (remaining.len > 0) {
            std.mem.copyForwards(u8, self.buf.items[0..remaining.len], remaining);
        }
        self.buf.shrinkRetainingCapacity(remaining.len);
        return body;
    }
};

fn parseHeader(bytes: []const u8) Error!Header {
    const header_end = findHeaderEnd(bytes) orelse return error.Incomplete;
    const headers = bytes[0..header_end];
    var content_length: ?usize = null;
    var start: usize = 0;
    while (start < headers.len) {
        const rel = std.mem.findScalarPos(u8, headers, start, '\n') orelse headers.len;
        var line = headers[start..rel];
        start = if (rel < headers.len) rel + 1 else headers.len;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.LspInvalidHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.LspInvalidContentLength;
        }
    }
    const length = content_length orelse return error.LspMissingContentLength;
    return .{
        .content_length = length,
        .header_end = header_end,
    };
}

fn findHeaderEnd(bytes: []const u8) ?usize {
    if (std.mem.find(u8, bytes, "\r\n\r\n")) |index| return index + 4;
    if (std.mem.find(u8, bytes, "\n\n")) |index| return index + 2;
    return null;
}

test "encode writes Content-Length framing" {
    const alloc = std.testing.allocator;
    const frame = try encode(alloc, "{\"id\":1}");
    defer alloc.free(frame);
    try std.testing.expectEqualStrings("Content-Length: 8\r\n\r\n{\"id\":1}", frame);
}

test "decoder round-trips a single frame" {
    const alloc = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const frame = try encode(alloc, body);
    defer alloc.free(frame);

    var decoder = Decoder.init(alloc);
    defer decoder.deinit();
    try decoder.feed(frame);
    const got = (try decoder.next()) orelse return error.TestExpectedEqual;
    defer alloc.free(got);
    try std.testing.expectEqualStrings(body, got);
    try std.testing.expect((try decoder.next()) == null);
}

test "decoder accepts split feeds and extra headers" {
    const alloc = std.testing.allocator;
    const prefix = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 5\r\n\r\nhello";
    var decoder = Decoder.init(alloc);
    defer decoder.deinit();
    try decoder.feed(prefix[0..12]);
    try std.testing.expect((try decoder.next()) == null);
    try decoder.feed(prefix[12..40]);
    try std.testing.expect((try decoder.next()) == null);
    try decoder.feed(prefix[40..]);
    const got = (try decoder.next()) orelse return error.TestExpectedEqual;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("hello", got);
}

test "decoder extracts multiple frames and lf-only headers" {
    const alloc = std.testing.allocator;
    var decoder = Decoder.init(alloc);
    defer decoder.deinit();
    try decoder.feed("Content-Length: 1\n\naContent-Length: 2\n\nbc");
    const first = (try decoder.next()) orelse return error.TestExpectedEqual;
    defer alloc.free(first);
    const second = (try decoder.next()) orelse return error.TestExpectedEqual;
    defer alloc.free(second);
    try std.testing.expectEqualStrings("a", first);
    try std.testing.expectEqualStrings("bc", second);
}

test "decoder rejects missing and oversized frames" {
    const alloc = std.testing.allocator;
    var missing = Decoder.init(alloc);
    defer missing.deinit();
    try missing.feed("Content-Type: application/json\r\n\r\n{}");
    try std.testing.expectError(error.LspMissingContentLength, missing.next());

    var oversized = Decoder.init(alloc);
    defer oversized.deinit();
    oversized.max_frame_bytes = 4;
    try oversized.feed("Content-Length: 5\r\n\r\nhello");
    try std.testing.expectError(error.LspFrameTooLarge, oversized.next());
}
