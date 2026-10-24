//! Bounded UTF-8 output retention and the small kernel JSONL vocabulary.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const max_frame_bytes = 32 * 1024 * 1024;
pub const version = 3;

pub const Event = struct {
    event: []const u8,
    id: ?[]const u8 = null,
    text: []const u8 = "",
    protocol: i64 = -1,
    status: []const u8 = "",
    ename: []const u8 = "",
    evalue: []const u8 = "",
    traceback: []const []const u8 = &.{},
    reason: ?[]const u8 = null,
    failed: []const std.json.Value = &.{},
};

pub const Buffer = struct {
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    head_chars: usize = 0,
    tail_chars: usize = 0,
    omitted: usize = 0,

    pub fn deinit(self: *Buffer, alloc: Allocator) void {
        self.head.deinit(alloc);
        self.tail.deinit(alloc);
        self.* = .{};
    }

    pub fn clear(self: *Buffer) void {
        self.head.clearRetainingCapacity();
        self.tail.clearRetainingCapacity();
        self.head_chars = 0;
        self.tail_chars = 0;
        self.omitted = 0;
    }

    pub fn append(self: *Buffer, alloc: Allocator, text: []const u8, cap: usize) !void {
        const tail_cap = cap / 4;
        const head_cap = cap - tail_cap;
        const take = prefix(text, head_cap -| self.head_chars);
        try self.head.appendSlice(alloc, text[0..take.bytes]);
        self.head_chars += take.chars;
        const rest = text[take.bytes..];
        const count = chars(rest);
        if (count >= tail_cap) {
            self.omitted += self.tail_chars + count - tail_cap;
            const skip = prefix(rest, count - tail_cap).bytes;
            self.tail.clearRetainingCapacity();
            try self.tail.appendSlice(alloc, rest[skip..]);
            self.tail_chars = tail_cap;
        } else {
            try self.tail.appendSlice(alloc, rest);
            self.tail_chars += count;
            if (self.tail_chars > tail_cap * 2) self.trimTail(tail_cap);
        }
    }

    fn trimTail(self: *Buffer, cap: usize) void {
        if (self.tail_chars <= cap) return;
        const dropped = self.tail_chars - cap;
        const bytes = prefix(self.tail.items, dropped).bytes;
        @memmove(self.tail.items[0 .. self.tail.items.len - bytes], self.tail.items[bytes..]);
        self.tail.items.len -= bytes;
        self.tail_chars = cap;
        self.omitted += dropped;
    }

    /// Caller owns the returned string.
    pub fn finish(self: *Buffer, alloc: Allocator, cap: usize) ![]u8 {
        self.trimTail(cap / 4);
        if (self.omitted == 0) return std.mem.concat(alloc, u8, &.{ self.head.items, self.tail.items });
        return alloc.print("{s}\n[... {d} chars omitted ...]\n{s}", .{ self.head.items, self.omitted, self.tail.items });
    }
};

fn chars(text: []const u8) usize {
    var n: usize = 0;
    for (text) |byte| if (byte & 0xc0 != 0x80) {
        n += 1;
    };
    return n;
}

fn prefix(text: []const u8, count: usize) struct { bytes: usize, chars: usize } {
    var n: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte & 0xc0 != 0x80) {
            if (n == count) return .{ .bytes = i, .chars = n };
            n += 1;
        }
    }
    return .{ .bytes = text.len, .chars = n };
}

test "kernel output keeps UTF-8 head and tail with bounded storage" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);
    try buffer.append(std.testing.allocator, "αβγδεζηθικλμ", 8);
    const text = try buffer.finish(std.testing.allocator, 8);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("αβγδεζ\n[... 4 chars omitted ...]\nλμ", text);
}
