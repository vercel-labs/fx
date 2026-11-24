//! The `clientInfo` that a client sends at `initialize`, kept as the JSON object
//! that the sessions' client list writes. Each string is cut to a fixed size.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

const Allocator = std.mem.Allocator;

/// The most bytes that one string of a client's info keeps. A longer string is cut.
pub const max_string_bytes: usize = 256;

/// The string fields a client may send, in the order the list writes them.
const fields = [_][]const u8{ "name", "version", "title" };

/// A client's info as JSON, owned by `alloc`.
pub const Info = struct {
    alloc: Allocator,
    json: []u8,

    pub fn deinit(self: *Info) void {
        self.alloc.free(self.json);
    }

    /// A copy of this info, owned by `alloc`.
    pub fn dupe(self: Info, alloc: Allocator) !Info {
        return .{ .alloc = alloc, .json = try alloc.dupe(u8, self.json) };
    }
};

/// The longest prefix of `text` that is at most `max_string_bytes` long and ends on a
/// character boundary. A byte of the form 10xxxxxx continues the character before it, so
/// the cut moves back past it.
pub fn cutString(text: []const u8) []const u8 {
    if (text.len <= max_string_bytes) return text;
    var end: usize = max_string_bytes;
    while (end > 0 and isContinuation(text[end])) end -= 1;
    return text[0..end];
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

/// Keeps the string fields of `value`, each cut by `cutString`, as a JSON object. Null when
/// the client sent no object, so the client's entry leaves the field out.
pub fn fromValue(alloc: Allocator, value: ?std.json.Value) !?Info {
    const object = switch (value orelse return null) {
        .object => |object| object,
        else => return null,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    var first = true;
    for (fields) |field| {
        const text = stringField(object, field) orelse continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try jsonrpc.writeJsonStr(field, &out.writer);
        try out.writer.writeByte(':');
        try jsonrpc.writeJsonStr(cutString(text), &out.writer);
    }
    try out.writer.writeByte('}');
    return .{ .alloc = alloc, .json = try out.toOwnedSlice() };
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

fn repeatByte(comptime count: usize, byte: u8) [count]u8 {
    return @splat(byte);
}

test "a string of 256 bytes or fewer is kept whole" {
    const exact = repeatByte(max_string_bytes, 'a');
    try std.testing.expectEqualStrings(&exact, cutString(&exact));
}

test "a longer ASCII string is cut to 256 bytes" {
    const long = repeatByte(300, 'n');
    try std.testing.expectEqual(@as(usize, 256), cutString(&long).len);
}

test "a cut never splits a multi-byte character: the 256th byte inside a four-byte character" {
    var text: [259]u8 = undefined;
    @memset(text[0..254], 'a');
    @memcpy(text[254..258], "\u{1F642}");
    text[258] = 'b';
    try std.testing.expectEqualSlices(u8, text[0..254], cutString(&text));
}

test "a cut moves back past a two-byte character that straddles byte 256" {
    var text: [257]u8 = undefined;
    @memset(text[0..255], 'a');
    @memcpy(text[255..257], "\u{E9}");
    try std.testing.expectEqual(@as(usize, 255), cutString(&text).len);
}

test "a missing or non-object clientInfo keeps nothing" {
    try std.testing.expect((try fromValue(std.testing.allocator, null)) == null);
    try std.testing.expect((try fromValue(std.testing.allocator, .null)) == null);
}

test "a clientInfo keeps its string fields, each cut to 256 bytes, and drops the others" {
    const alloc = std.testing.allocator;
    const long_name = repeatByte(300, 'n');
    const text = try alloc.print(
        "{{\"clientInfo\":{{\"name\":\"{s}\",\"version\":\"1.0\",\"title\":\"T\",\"extra\":5}}}}",
        .{&long_name},
    );
    defer alloc.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    var info = (try fromValue(alloc, parsed.value.object.get("clientInfo"))) orelse return error.TestUnexpectedResult;
    defer info.deinit();
    const expected = try alloc.print("{{\"name\":\"{s}\",\"version\":\"1.0\",\"title\":\"T\"}}", .{cutString(&long_name)});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, info.json);
}
