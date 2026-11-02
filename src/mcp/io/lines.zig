//! Reading lines under a size limit: newline-delimited for the stdio reader,
//! and CR, LF, or CRLF for the SSE reader.

const std = @import("std");

pub const Line = struct {
    /// The line without its newline and one trailing CR. Valid until
    /// the next read into the same buffer.
    bytes: []const u8,
    /// Longer than the limit: `bytes` is its start, and the rest is still
    /// unread, so a caller that stops never waits for a newline that may not
    /// come. `skipRest` reads past it.
    too_long: bool,
    /// The stream ended without a newline after this line.
    at_end: bool,
};

/// Reads the next line into `line`, which is cleared first.
pub fn read(reader: *std.Io.Reader, line: *std.Io.Writer.Allocating, limit: usize) error{ReadFailed}!Line {
    line.clearRetainingCapacity();
    if (reader.streamDelimiterLimit(&line.writer, '\n', .limited(limit))) |_| {} else |err| switch (err) {
        error.StreamTooLong => return .{ .bytes = line.written(), .too_long = true, .at_end = false },
        error.ReadFailed, error.WriteFailed => return error.ReadFailed,
    }
    const at_end = if (reader.discardDelimiterInclusive('\n')) |_| false else |err| switch (err) {
        error.EndOfStream => true,
        error.ReadFailed => return error.ReadFailed,
    };
    var bytes = line.written();
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\r') bytes.len -= 1;
    return .{ .bytes = bytes, .too_long = false, .at_end = at_end };
}

/// The lines of an event stream, which the SSE standard lets end at CR, LF,
/// or CRLF. A line ends at its CR at once, and a LF right after it is skipped when
/// it comes, so an event that ends with bare CRs is read without waiting
/// for a LF that may never come.
pub const SseLines = struct {
    /// The last line ended at a CR, so a LF that comes next ends it too.
    after_cr: bool = false,

    /// Reads the next line onto the end of `buf`. One past `limit`, for
    /// `buf` as a whole, is `too_long`, and the stream is then of no further
    /// use. `counter.grow(held)` runs before `buf` grows to `held` bytes, a
    /// read's worth at a time, so its owner can count them.
    pub fn read(s: *SseLines, reader: *std.Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), limit: usize, counter: anytype) !Line {
        const mark = buf.items.len;
        while (true) {
            const buffered = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return .{ .bytes = buf.items[mark..], .too_long = false, .at_end = true },
                error.ReadFailed => return error.ReadFailed,
            };
            const skip: usize = @intFromBool(s.after_cr and buffered[0] == '\n');
            s.after_cr = false;
            const rest = buffered[skip..];
            const end = std.mem.findAny(u8, rest, "\r\n");
            const part = rest[0 .. end orelse rest.len];
            if (buf.items.len + part.len > limit) return .{ .bytes = buf.items[mark..], .too_long = true, .at_end = false };
            try counter.grow(buf.items.len + part.len);
            try buf.appendSlice(gpa, part);
            reader.toss(skip + part.len);
            if (end) |i| {
                s.after_cr = rest[i] == '\r';
                reader.toss(1);
                return .{ .bytes = buf.items[mark..], .too_long = false, .at_end = false };
            }
        }
    }
};

/// Reads past the rest of an over-long line. Returns true at the end of the stream.
pub fn skipRest(reader: *std.Io.Reader) error{ReadFailed}!bool {
    _ = reader.discardDelimiterInclusive('\n') catch |err| return switch (err) {
        error.EndOfStream => true,
        error.ReadFailed => error.ReadFailed,
    };
    return false;
}

const testing = std.testing;

test "reads lines, strips one CR, and stops at an over-long line without reading on" {
    var reader: std.Io.Reader = .fixed("one\r\n\ntwo\r\r\nxxxxxxxxxxxxxxxx\nlast");
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    try testing.expectEqualStrings("one", (try read(&reader, &line, 8)).bytes);
    try testing.expectEqualStrings("", (try read(&reader, &line, 8)).bytes);
    try testing.expectEqualStrings("two\r", (try read(&reader, &line, 8)).bytes);
    const long = try read(&reader, &line, 8);
    try testing.expect(long.too_long);
    try testing.expectEqualStrings("xxxxxxxx", long.bytes);
    try testing.expect(!try skipRest(&reader));
    const last = try read(&reader, &line, 8);
    try testing.expect(last.at_end);
    try testing.expectEqualStrings("last", last.bytes);
}

/// Counts nothing, for the tests.
const NoCount = struct {
    pub fn grow(_: *NoCount, _: usize) error{}!void {}
};

test "event stream lines end at CR, LF, or CRLF at once, and a LF after a CR read earlier is skipped" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var none: NoCount = .{};
    var s: SseLines = .{};
    var mixed: std.Io.Reader = .fixed("a\r\rb\r\n\r\nc\n\nxxxxxxxxx\n");
    for ([_][]const u8{ "a", "", "b", "", "c", "" }) |want| {
        buf.clearRetainingCapacity();
        const got = try s.read(&mixed, testing.allocator, &buf, 8, &none);
        try testing.expect(!got.at_end and !got.too_long);
        try testing.expectEqualStrings(want, got.bytes);
    }
    buf.clearRetainingCapacity();
    try testing.expect((try s.read(&mixed, testing.allocator, &buf, 8, &none)).too_long);
    // A line ends at its CR with nothing after it buffered yet; the LF that
    // comes later belongs to that ending.
    buf.clearRetainingCapacity();
    var first: std.Io.Reader = .fixed("data: x\r");
    try testing.expectEqualStrings("data: x", (try s.read(&first, testing.allocator, &buf, 64, &none)).bytes);
    // Read onto the end: the limit is for the buffer as a whole.
    var second: std.Io.Reader = .fixed("\ndata: y\r\n");
    try testing.expectEqualStrings("data: y", (try s.read(&second, testing.allocator, &buf, 64, &none)).bytes);
    try testing.expectEqualStrings("data: xdata: y", buf.items);
    const end = try s.read(&second, testing.allocator, &buf, 64, &none);
    try testing.expect(end.at_end);
    try testing.expectEqualStrings("", end.bytes);
}
