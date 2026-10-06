const std = @import("std");

pub const protocol_version = "agent-cast/0.1";
pub const default_frame_bytes = 64 * 1024;
pub const hard_frame_bytes = 1024 * 1024;
const max_json_depth = 32;

pub const Limits = struct { frame_bytes: usize = default_frame_bytes };

// One owned, bounded payload buffer. A returned frame borrows it until release().
// The caller must release a complete frame before feeding more data. Errors poison
// the framer, so an attacker cannot resynchronize after an invalid length.
pub const Framer = struct {
    payload: []u8,
    header: [4]u8 = @splat(0),
    header_used: usize = 0,
    payload_expected: usize = 0,
    payload_used: usize = 0,
    ready: bool = false,
    poisoned: bool = false,

    pub fn init(alloc: std.mem.Allocator, limits: Limits) !Framer {
        if (limits.frame_bytes == 0 or limits.frame_bytes > hard_frame_bytes) return error.InvalidFrameLimit;
        return .{ .payload = try alloc.alloc(u8, limits.frame_bytes) };
    }

    pub fn deinit(self: *Framer, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
        self.* = undefined;
    }

    pub const Feed = struct { consumed: usize, frame: ?[]const u8 };

    pub fn push(self: *Framer, input: []const u8) !Feed {
        if (self.poisoned) return error.FramerPoisoned;
        if (self.ready) return error.FrameNotReleased;
        var consumed: usize = 0;
        if (self.header_used < self.header.len) {
            const count = @min(self.header.len - self.header_used, input.len);
            @memcpy(self.header[self.header_used..][0..count], input[0..count]);
            self.header_used += count;
            consumed += count;
            if (self.header_used < self.header.len) return .{ .consumed = consumed, .frame = null };
            self.payload_expected = std.mem.readInt(u32, &self.header, .big);
            if (self.payload_expected == 0 or self.payload_expected > self.payload.len) {
                self.poisoned = true;
                return error.InvalidFrameLength;
            }
        }
        const count = @min(self.payload_expected - self.payload_used, input.len - consumed);
        @memcpy(self.payload[self.payload_used..][0..count], input[consumed..][0..count]);
        self.payload_used += count;
        consumed += count;
        self.ready = self.payload_used == self.payload_expected;
        return .{ .consumed = consumed, .frame = if (self.ready) self.payload[0..self.payload_expected] else null };
    }

    pub fn release(self: *Framer) !void {
        if (!self.ready) return error.NoCompleteFrame;
        self.header_used = 0;
        self.payload_used = 0;
        self.payload_expected = 0;
        self.ready = false;
    }

    pub fn finish(self: *const Framer) !void {
        if (self.poisoned) return error.FramerPoisoned;
        if (self.header_used != 0 or self.payload_used != 0 or self.ready) return error.TruncatedFrame;
    }
};

// Caller owns the encoded frame. Header is an unsigned big-endian byte length.
pub fn encode_frame(alloc: std.mem.Allocator, body: []const u8, limits: Limits) ![]u8 {
    if (limits.frame_bytes == 0 or limits.frame_bytes > hard_frame_bytes) return error.InvalidFrameLimit;
    if (body.len == 0 or body.len > limits.frame_bytes) return error.InvalidFrameLength;
    const output = try alloc.alloc(u8, body.len + 4);
    std.mem.writeInt(u32, output[0..4], @intCast(body.len), .big);
    @memcpy(output[4..], body);
    return output;
}

// JSON-RPC calls use bounded string IDs. Missing IDs are notifications; the
// broker restricts notifications to permitted event methods. Params are objects.
pub const Request = struct {
    jsonrpc: []const u8,
    id: ?[]const u8 = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const ParsedRequest = struct {
    storage: std.json.Parsed(std.json.Value),
    value: Request,

    pub fn deinit(self: ParsedRequest) void {
        self.storage.deinit();
    }
};

// Parsed strings and nested values are owned by ParsedRequest; caller deinitializes it.
// Duplicate fields are rejected at every object depth, including params.
// Field presence is preserved: absent id denotes notification; explicit null rejects.
pub fn parse_request(alloc: std.mem.Allocator, body: []const u8, limits: Limits) !ParsedRequest {
    if (limits.frame_bytes == 0 or limits.frame_bytes > hard_frame_bytes) return error.InvalidFrameLimit;
    if (body.len == 0 or body.len > limits.frame_bytes) return error.InvalidFrameLength;
    try preflight_json(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .max_value_len = limits.frame_bytes,
    });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEnvelope;
    const object = parsed.value.object;
    for (object.keys()) |key| {
        if (!std.mem.eql(u8, key, "jsonrpc") and !std.mem.eql(u8, key, "id") and
            !std.mem.eql(u8, key, "method") and !std.mem.eql(u8, key, "params")) return error.UnknownField;
    }
    const rpc = object.get("jsonrpc") orelse return error.MissingField;
    if (rpc != .string or !std.mem.eql(u8, rpc.string, "2.0")) return error.InvalidRpcVersion;
    const method = object.get("method") orelse return error.MissingField;
    if (method != .string or !identifier(method.string, 64)) return error.InvalidMethod;
    var id: ?[]const u8 = null;
    if (object.get("id")) |field| {
        if (field != .string or !identifier(field.string, 96)) return error.InvalidRequestId;
        id = field.string;
    }
    const params = object.get("params");
    if (params) |field| {
        if (field != .object) return error.InvalidParams;
    }
    return .{ .storage = parsed, .value = .{ .jsonrpc = rpc.string, .id = id, .method = method.string, .params = params } };
}

fn identifier(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-' and byte != ':') return false;
    }
    return true;
}

fn preflight_json(body: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    var in_string = false;
    var escaped = false;
    var depth: usize = 0;
    for (body) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
        } else switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_json_depth) return error.JsonTooDeep;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJsonNesting;
                depth -= 1;
            },
            else => {},
        }
    }
    if (depth != 0 or in_string) return error.InvalidJsonNesting;
}

test "every header and body split reconstructs the exact frame" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"hello\"}";
    const frame = try encode_frame(std.testing.allocator, body, .{});
    defer std.testing.allocator.free(frame);
    for (0..frame.len + 1) |split| {
        var framer = try Framer.init(std.testing.allocator, .{});
        defer framer.deinit(std.testing.allocator);
        const first = try framer.push(frame[0..split]);
        try std.testing.expectEqual(split, first.consumed);
        const value = if (first.frame) |complete| complete else (try framer.push(frame[split..])).frame.?;
        try std.testing.expectEqualStrings(body, value);
        try std.testing.expectError(error.FrameNotReleased, framer.push(""));
        try framer.release();
        try framer.finish();
    }
}

test "concatenated frames consume only one message and EOF rejects truncation" {
    const bytes = [_]u8{ 0, 0, 0, 2, '{', '}', 0, 0, 0, 2, '[', ']' };
    var framer = try Framer.init(std.testing.allocator, .{ .frame_bytes = 4 });
    defer framer.deinit(std.testing.allocator);
    const first = try framer.push(&bytes);
    try std.testing.expectEqual(@as(usize, 6), first.consumed);
    try std.testing.expectEqualStrings("{}", first.frame.?);
    try framer.release();
    const second = try framer.push(bytes[first.consumed..]);
    try std.testing.expectEqualStrings("[]", second.frame.?);
    try framer.release();
    _ = try framer.push(bytes[0..3]);
    try std.testing.expectError(error.TruncatedFrame, framer.finish());
}

test "invalid lengths poison the connection before payload growth" {
    for ([_][4]u8{ .{ 0, 0, 0, 0 }, .{ 0xff, 0xff, 0xff, 0xff } }) |header| {
        var framer = try Framer.init(std.testing.allocator, .{ .frame_bytes = 8 });
        defer framer.deinit(std.testing.allocator);
        const pointer = framer.payload.ptr;
        try std.testing.expectError(error.InvalidFrameLength, framer.push(&header));
        try std.testing.expectEqual(pointer, framer.payload.ptr);
        try std.testing.expectEqual(@as(usize, 8), framer.payload.len);
        try std.testing.expectError(error.FramerPoisoned, framer.push("{}"));
    }
    try std.testing.expectError(error.InvalidFrameLimit, Framer.init(std.testing.allocator, .{ .frame_bytes = hard_frame_bytes + 1 }));
}

test "JSON-RPC parsing rejects duplicate nested fields and owns its input" {
    try std.testing.expectError(error.DuplicateField, parse_request(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"method\":\"read\"}", .{}));
    try std.testing.expectError(error.DuplicateField, parse_request(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"read\",\"params\":{\"agent\":\"a\",\"agent\":\"b\"}}", .{}));
    var input = "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"hello\",\"params\":{}}".*;
    const parsed = try parse_request(std.testing.allocator, &input, .{});
    defer parsed.deinit();
    @memset(&input, 'X');
    try std.testing.expectEqualStrings("hello", parsed.value.method);
    try std.testing.expectEqualStrings("r1", parsed.value.id.?);
}

test "invalid RPC identity params UTF8 and excessive nesting fail" {
    try std.testing.expectError(error.InvalidRpcVersion, parse_request(std.testing.allocator, "{\"jsonrpc\":\"1.0\",\"method\":\"hello\"}", .{}));
    try std.testing.expectError(error.InvalidRequestId, parse_request(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"../oops\",\"method\":\"hello\"}", .{}));
    try std.testing.expectError(error.InvalidParams, parse_request(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":[]}", .{}));
    try std.testing.expectError(error.InvalidUtf8, parse_request(std.testing.allocator, "\xff", .{}));
    const too_deep = "[" ** 33 ++ "]" ** 33;
    try std.testing.expectError(error.JsonTooDeep, parse_request(std.testing.allocator, too_deep, .{}));
}

test "absent ID is a notification but present null ID or params rejects" {
    const notification = try parse_request(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"event\"}", .{});
    defer notification.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), notification.value.id);
    try std.testing.expectError(error.InvalidRequestId, parse_request(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"hello\"}", .{}));
    try std.testing.expectError(error.InvalidParams, parse_request(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"params\":null}", .{}));
}
