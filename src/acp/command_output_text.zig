//! The text of one stream of a command's output as `fx acp` sends it in
//! progress updates: whole UTF-8 characters, with the unfinished end of a chunk
//! held for the stream's next chunk.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text_utils = @import("../core/shared/text_utils.zig");

/// Command output arrives in chunks cut at byte counts, so a chunk can end
/// partway through a UTF-8 character. Holds that unfinished end, at most
/// `text_utils.max_incomplete_utf8_tail` bytes, until the stream's next chunk,
/// and escapes bytes that are not valid UTF-8, so every progress update is
/// valid JSON text (`tests/tla/acp/AcpCommandOutput.tla` ProgressValidUtf8,
/// NothingLost).
pub const CommandOutputText = struct {
    pending: [text_utils.max_incomplete_utf8_tail]u8 = undefined,
    pending_len: u8 = 0,

    /// The text to send for `chunk` after the bytes held from the chunk
    /// before. Caller owns the result.
    pub fn append(self: *CommandOutputText, alloc: Allocator, chunk: []const u8) ![]u8 {
        const joined: ?[]u8 = if (self.pending_len > 0)
            try std.mem.concat(alloc, u8, &.{ self.pending[0..self.pending_len], chunk })
        else
            null;
        defer if (joined) |bytes| alloc.free(bytes);
        const raw: []const u8 = joined orelse chunk;
        const end = raw.len - text_utils.incompleteUtf8Tail(raw);
        const text = try text_utils.dupeValidUtf8(alloc, raw[0..end]);
        self.pending_len = @intCast(raw.len - end);
        @memcpy(self.pending[0..self.pending_len], raw[end..]);
        return text;
    }

    /// The held bytes, escaped, once the stream ends. Caller owns the result.
    pub fn finish(self: *CommandOutputText, alloc: Allocator) ![]u8 {
        const text = try text_utils.dupeValidUtf8(alloc, self.pending[0..self.pending_len]);
        self.pending_len = 0;
        return text;
    }
};

test "command output text holds a split character until the next chunk and escapes the rest" {
    const alloc = std.testing.allocator;
    var output: CommandOutputText = .{};
    const cases = [_]struct { chunk: []const u8, sent: []const u8 }{
        .{ .chunk = "a\xd0", .sent = "a" },
        .{ .chunk = "\xafb", .sent = "\xd0\xafb" },
        .{ .chunk = "\xf0\x90", .sent = "" },
        .{ .chunk = "\x90\x80", .sent = "\xf0\x90\x90\x80" },
        .{ .chunk = "\xff\xd0", .sent = "\\xff" },
    };
    for (cases) |case| {
        const text = try output.append(alloc, case.chunk);
        defer alloc.free(text);
        try std.testing.expectEqualStrings(case.sent, text);
    }
    // The stream ends with a character unfinished: its bytes go out escaped.
    const tail = try output.finish(alloc);
    defer alloc.free(tail);
    try std.testing.expectEqualStrings("\\xd0", tail);
    try std.testing.expectEqual(@as(u8, 0), output.pending_len);
}

test "command output text holds at most the bytes of an unfinished sequence" {
    const alloc = std.testing.allocator;
    var output: CommandOutputText = .{};
    // Three bytes of a four-byte character are held, and the fourth finishes it.
    const held = try output.append(alloc, "\xf0\x9f\x98");
    defer alloc.free(held);
    try std.testing.expectEqualStrings("", held);
    try std.testing.expectEqual(@as(u8, text_utils.max_incomplete_utf8_tail), output.pending_len);
    const done = try output.append(alloc, "\x80");
    defer alloc.free(done);
    try std.testing.expectEqualStrings("\xf0\x9f\x98\x80", done);
    // A lead byte that cannot start a sequence is not held.
    const stray = try output.append(alloc, "\xff");
    defer alloc.free(stray);
    try std.testing.expectEqualStrings("\\xff", stray);
    try std.testing.expectEqual(@as(u8, 0), output.pending_len);
}

test "command output text is valid UTF-8 and matches the whole output however it is split" {
    try std.testing.fuzz({}, fuzzCommandOutputText, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "a\xd0\xafb",
            "\xf0\x9f\x98\x80\xe2\x82\xac",
            "\xe2\x82",
            "\xff\xd0",
            "\x80\x80\x80\xf0\x90\x80",
            "\xc0\xaf\xed\xa0\x80\xf4\x90\x80\x80",
        }) ++ @import("fuzz_corpus").acp_command_output_utf8.*),
    });
}

fn fuzzCommandOutputText(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    const raw = buffer[0..smith.slice(&buffer)];
    var output: CommandOutputText = .{};
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    var rest = raw;
    while (rest.len > 0) {
        const len = 1 + smith.index(rest.len);
        const text = try output.append(alloc, rest[0..len]);
        defer alloc.free(text);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        try joined.appendSlice(alloc, text);
        rest = rest[len..];
    }
    const tail = try output.finish(alloc);
    defer alloc.free(tail);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tail));
    try joined.appendSlice(alloc, tail);
    const whole = try text_utils.dupeValidUtf8(alloc, raw);
    defer alloc.free(whole);
    try std.testing.expectEqualStrings(whole, joined.items);
}
