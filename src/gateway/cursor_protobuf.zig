//! The protobuf and Connect pieces the Cursor transport needs (D200): a
//! hand-written wire encoder and field reader, `google.protobuf.Value`
//! conversion to and from JSON text, and Connect envelopes. There is no
//! schema compiler; `cursor_messages.zig` names the field numbers it uses,
//! taken from proto's `packages/ai/src/providers/cursor/proto/agent.proto`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    bytes = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
    _,
};

pub const Error = error{ Truncated, Overflow, UnsupportedWireType, InvalidValue, OutOfMemory };

/// Appends protobuf fields to a growing buffer. Every slice it writes is
/// copied, so callers may pass temporaries.
pub const Writer = struct {
    alloc: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(alloc: Allocator) Writer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.alloc);
    }

    /// The encoded message. Caller owns it.
    pub fn toOwned(self: *Writer) Allocator.Error![]u8 {
        return self.bytes.toOwnedSlice(self.alloc);
    }

    pub fn varint(self: *Writer, value: u64) Allocator.Error!void {
        var rest = value;
        while (rest >= 0x80) : (rest >>= 7) try self.bytes.append(self.alloc, @as(u8, @truncate(rest)) | 0x80);
        try self.bytes.append(self.alloc, @truncate(rest));
    }

    pub fn tag(self: *Writer, field: u32, wire: WireType) Allocator.Error!void {
        try self.varint((@as(u64, field) << 3) | @backingInt(wire));
    }

    pub fn uintField(self: *Writer, field: u32, value: u64) Allocator.Error!void {
        try self.tag(field, .varint);
        try self.varint(value);
    }

    pub fn boolField(self: *Writer, field: u32, value: bool) Allocator.Error!void {
        try self.uintField(field, @intFromBool(value));
    }

    pub fn bytesField(self: *Writer, field: u32, value: []const u8) Allocator.Error!void {
        try self.tag(field, .bytes);
        try self.varint(value.len);
        try self.bytes.appendSlice(self.alloc, value);
    }

    /// A proto3 string, left out when empty as protobuf-es does.
    pub fn stringField(self: *Writer, field: u32, value: []const u8) Allocator.Error!void {
        if (value.len != 0) try self.bytesField(field, value);
    }

    /// An empty embedded message, which selects a oneof case.
    pub fn emptyField(self: *Writer, field: u32) Allocator.Error!void {
        try self.bytesField(field, "");
    }

    pub fn doubleField(self: *Writer, field: u32, value: f64) Allocator.Error!void {
        try self.tag(field, .fixed64);
        try self.bytes.appendSlice(self.alloc, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(value))));
    }
};

pub const Field = struct {
    number: u32,
    wire: WireType,
    /// The value of a varint field, or the raw bits of a fixed field.
    int: u64 = 0,
    /// The payload of a length-delimited field, borrowed from the message.
    data: []const u8 = "",

    pub fn string(self: Field) []const u8 {
        return if (self.wire == .bytes) self.data else "";
    }
};

/// Iterates the fields of one encoded message. Slices borrow the message.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Reader) Error!?Field {
        if (self.pos >= self.bytes.len) return null;
        const key = try self.varint();
        const number: u32 = std.math.cast(u32, key >> 3) orelse return error.Overflow;
        if (number == 0) return error.InvalidValue;
        const wire: WireType = @fromBackingInt(@intCast(@as(u3, @truncate(key))));
        var field: Field = .{ .number = number, .wire = wire };
        switch (wire) {
            .varint => field.int = try self.varint(),
            .fixed64 => field.int = std.mem.readInt(u64, (try self.take(8))[0..8], .little),
            .fixed32 => field.int = std.mem.readInt(u32, (try self.take(4))[0..4], .little),
            .bytes => {
                const len = std.math.cast(usize, try self.varint()) orelse return error.Overflow;
                field.data = try self.take(len);
            },
            else => return error.UnsupportedWireType,
        }
        return field;
    }

    fn take(self: *Reader, len: usize) Error![]const u8 {
        if (len > self.bytes.len - self.pos) return error.Truncated;
        const out = self.bytes[self.pos..][0..len];
        self.pos += len;
        return out;
    }

    fn varint(self: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            if (self.pos >= self.bytes.len) return error.Truncated;
            const byte = self.bytes[self.pos];
            self.pos += 1;
            if (shift >= 64) return error.Overflow;
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
            shift += 7;
        }
    }
};

/// The first length-delimited field `number` in `message`, or null.
pub fn findBytes(message: []const u8, number: u32) Error!?[]const u8 {
    var reader = Reader.init(message);
    while (try reader.next()) |field| if (field.number == number and field.wire == .bytes) return field.data;
    return null;
}

/// The first varint field `number` in `message`, or null.
pub fn findInt(message: []const u8, number: u32) Error!?u64 {
    var reader = Reader.init(message);
    while (try reader.next()) |field| if (field.number == number and field.wire == .varint) return field.int;
    return null;
}

// google.protobuf.Value: 1 null, 2 number (double), 3 string, 4 bool,
// 5 Struct {1: entries {1 key, 2 Value}}, 6 ListValue {1: Value}.

/// Encodes a JSON value as `google.protobuf.Value`. Caller owns the bytes.
pub fn encodeJsonValue(alloc: Allocator, value: std.json.Value) Allocator.Error![]u8 {
    var w = Writer.init(alloc);
    errdefer w.deinit();
    try writeJsonValue(alloc, &w, value);
    return w.toOwned();
}

fn writeJsonValue(alloc: Allocator, w: *Writer, value: std.json.Value) Allocator.Error!void {
    switch (value) {
        .null => try w.uintField(1, 0),
        .bool => |flag| try w.boolField(4, flag),
        .integer => |number| try w.doubleField(2, @floatFromInt(number)),
        .float => |number| try w.doubleField(2, number),
        .number_string => |text| try w.doubleField(2, std.fmt.parseFloat(f64, text) catch 0),
        .string => |text| try w.bytesField(3, text),
        .array => |items| {
            var list = Writer.init(alloc);
            defer list.deinit();
            for (items.items) |item| {
                var inner = Writer.init(alloc);
                defer inner.deinit();
                try writeJsonValue(alloc, &inner, item);
                try list.bytesField(1, inner.bytes.items);
            }
            try w.bytesField(6, list.bytes.items);
        },
        .object => |object| {
            var fields = Writer.init(alloc);
            defer fields.deinit();
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                var inner = Writer.init(alloc);
                defer inner.deinit();
                try writeJsonValue(alloc, &inner, entry.value_ptr.*);
                var pair = Writer.init(alloc);
                defer pair.deinit();
                try pair.bytesField(1, entry.key_ptr.*);
                try pair.bytesField(2, inner.bytes.items);
                try fields.bytesField(1, pair.bytes.items);
            }
            try w.bytesField(5, fields.bytes.items);
        },
    }
}

const max_value_depth = 64;

/// Writes a `google.protobuf.Value` as JSON text. A message with no kind
/// field is JSON null, as protobuf-es reads it.
pub fn writeValueJson(out: *std.Io.Writer, bytes: []const u8) (Error || std.Io.Writer.Error)!void {
    return writeValueJsonDepth(out, bytes, 0);
}

fn writeValueJsonDepth(out: *std.Io.Writer, bytes: []const u8, depth: usize) (Error || std.Io.Writer.Error)!void {
    if (depth > max_value_depth) return error.InvalidValue;
    var kind: ?Field = null;
    var reader = Reader.init(bytes);
    while (try reader.next()) |field| if (field.number >= 1 and field.number <= 6) {
        kind = field;
    };
    const field = kind orelse return out.writeAll("null");
    switch (field.number) {
        1 => try out.writeAll("null"),
        2 => try writeNumber(out, @bitCast(field.int)),
        3 => try std.json.Stringify.value(field.string(), .{}, out),
        4 => try out.writeAll(if (field.int != 0) "true" else "false"),
        5 => {
            try out.writeByte('{');
            var entries = Reader.init(field.data);
            var first = true;
            while (try entries.next()) |entry| {
                if (entry.number != 1 or entry.wire != .bytes) continue;
                const key = (try findBytes(entry.data, 1)) orelse "";
                const inner = (try findBytes(entry.data, 2)) orelse "";
                if (!first) try out.writeByte(',');
                first = false;
                try std.json.Stringify.value(key, .{}, out);
                try out.writeByte(':');
                try writeValueJsonDepth(out, inner, depth + 1);
            }
            try out.writeByte('}');
        },
        6 => {
            try out.writeByte('[');
            var items = Reader.init(field.data);
            var first = true;
            while (try items.next()) |item| {
                if (item.number != 1 or item.wire != .bytes) continue;
                if (!first) try out.writeByte(',');
                first = false;
                try writeValueJsonDepth(out, item.data, depth + 1);
            }
            try out.writeByte(']');
        },
        else => unreachable,
    }
}

fn writeNumber(out: *std.Io.Writer, number: f64) std.Io.Writer.Error!void {
    if (!std.math.isFinite(number)) return out.writeAll("null");
    if (@floor(number) == number and @abs(number) < 9007199254740992.0) return out.print("{d}", .{@as(i64, @intFromFloat(number))});
    return out.print("{d}", .{number});
}

// Connect envelopes: one flag byte, a big-endian u32 length, the message.

pub const end_stream_flag: u8 = 0b10;
pub const compressed_flag: u8 = 0b01;
pub const envelope_header_bytes = 5;

/// One enveloped message. Caller owns it.
pub fn envelope(alloc: Allocator, flags: u8, message: []const u8) Allocator.Error![]u8 {
    const out = try alloc.alloc(u8, envelope_header_bytes + message.len);
    out[0] = flags;
    std.mem.writeInt(u32, out[1..5], @intCast(message.len), .big);
    @memcpy(out[envelope_header_bytes..], message);
    return out;
}

pub const Frame = struct {
    flags: u8,
    /// Borrowed until the next `FrameReader.next` call.
    message: []const u8,

    pub fn endStream(self: Frame) bool {
        return self.flags & end_stream_flag != 0;
    }
};

/// Reads Connect envelopes from a byte stream.
pub const FrameReader = struct {
    alloc: Allocator,
    source: *std.Io.Reader,
    max_message_bytes: usize,
    buffer: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *FrameReader) void {
        self.buffer.deinit(self.alloc);
    }

    /// The next frame, or null at a clean end of stream between frames.
    pub fn next(self: *FrameReader) !?Frame {
        var header: [envelope_header_bytes]u8 = undefined;
        self.source.readSliceAll(header[0..1]) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        try self.source.readSliceAll(header[1..]);
        if (header[0] & compressed_flag != 0) return error.CompressedFrame;
        const len = std.mem.readInt(u32, header[1..5], .big);
        if (len > self.max_message_bytes) return error.FrameTooLarge;
        try self.buffer.resize(self.alloc, len);
        try self.source.readSliceAll(self.buffer.items);
        return .{ .flags = header[0], .message = self.buffer.items };
    }
};

pub const EndStreamError = struct {
    /// Both borrow the parsed JSON.
    code: []const u8,
    message: []const u8,
};

/// The error an end-of-stream envelope reports, or null for a clean end.
/// `arena` holds the parse.
pub fn parseEndStream(arena: Allocator, message: []const u8) !?EndStreamError {
    if (std.mem.trim(u8, message, " \t\r\n").len == 0) return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, message, .{}) catch return .{ .code = "unknown", .message = "Failed to parse Connect end stream" };
    if (root != .object) return null;
    const failure = root.object.get("error") orelse return null;
    if (failure != .object) return .{ .code = "unknown", .message = "Unknown error" };
    const code = failure.object.get("code");
    const text = failure.object.get("message");
    return .{
        .code = if (code != null and code.? == .string) code.?.string else "unknown",
        .message = if (text != null and text.? == .string) text.?.string else "Unknown error",
    };
}

test "varints, tags and nested fields round trip" {
    const alloc = std.testing.allocator;
    var inner = Writer.init(alloc);
    defer inner.deinit();
    try inner.stringField(1, "hello");
    try inner.uintField(2, 300);
    try inner.stringField(3, "");
    var outer = Writer.init(alloc);
    defer outer.deinit();
    try outer.bytesField(7, inner.bytes.items);
    try outer.uintField(57, std.math.maxInt(u64));
    try std.testing.expectEqualSlices(u8, &.{ 0x3a, 0x0a, 0x0a, 0x05, 'h', 'e', 'l', 'l', 'o', 0x10, 0xac, 0x02 }, outer.bytes.items[0..12]);
    const nested = (try findBytes(outer.bytes.items, 7)).?;
    try std.testing.expectEqualStrings("hello", (try findBytes(nested, 1)).?);
    try std.testing.expectEqual(@as(u64, 300), (try findInt(nested, 2)).?);
    try std.testing.expect(try findBytes(nested, 3) == null);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try findInt(outer.bytes.items, 57)).?);
    var truncated = Reader.init(&.{ 0x0a, 0x05, 'h' });
    try std.testing.expectError(error.Truncated, truncated.next());
}

test "JSON values round trip through google.protobuf.Value" {
    const alloc = std.testing.allocator;
    const text =
        \\{"path":"src/main.zig","limit":40,"ratio":0.5,"flags":[true,false,null],"nested":{"a":"b\n\"q\""}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const bytes = try encodeJsonValue(alloc, parsed.value);
    defer alloc.free(bytes);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeValueJson(&out.writer, bytes);
    try std.testing.expectEqualStrings(text, out.written());
    // proto's encodeJsonValue("x") from its own tests: field 3, "x".
    const string_value = try encodeJsonValue(alloc, .{ .string = "x" });
    defer alloc.free(string_value);
    try std.testing.expectEqualSlices(u8, &.{ 0x1a, 0x01, 'x' }, string_value);
    out.clearRetainingCapacity();
    try writeValueJson(&out.writer, "");
    try std.testing.expectEqualStrings("null", out.written());
}

test "Connect envelopes frame messages and report end-stream errors" {
    const alloc = std.testing.allocator;
    const first = try envelope(alloc, 0, "abc");
    defer alloc.free(first);
    const last = try envelope(alloc, end_stream_flag, "{\"error\":{\"code\":\"resource_exhausted\",\"message\":\"slow down\"}}");
    defer alloc.free(last);
    const joined = try std.mem.concat(alloc, u8, &.{ first, last });
    defer alloc.free(joined);
    var source: std.Io.Reader = .fixed(joined);
    var frames: FrameReader = .{ .alloc = alloc, .source = &source, .max_message_bytes = 1024 };
    defer frames.deinit();
    const one = (try frames.next()).?;
    try std.testing.expect(!one.endStream());
    try std.testing.expectEqualStrings("abc", one.message);
    const two = (try frames.next()).?;
    try std.testing.expect(two.endStream());
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const failure = (try parseEndStream(arena_state.allocator(), two.message)).?;
    try std.testing.expectEqualStrings("resource_exhausted", failure.code);
    try std.testing.expectEqualStrings("slow down", failure.message);
    try std.testing.expect(try parseEndStream(arena_state.allocator(), "{}") == null);
    try std.testing.expect(try frames.next() == null);
}
