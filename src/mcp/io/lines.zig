//! Reading newline-delimited lines under a size limit, shared by the stdio
//! reader and the SSE reader.

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
