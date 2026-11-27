const std = @import("std");
const debug_trace = @import("debug_trace.zig");
const display_width = @import("display_width.zig");
const ascii_case = @import("ascii_case.zig");

pub const containsIgnoreCase = ascii_case.containsIgnoreCase;
pub const hasMajorVersionAtLeast = ascii_case.hasMajorVersionAtLeast;

/// Returns `text` repeated `count` times as a comptime string literal.
pub inline fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count:0]u8 {
    return comptime blk: {
        const units: [count][text.len]u8 = @splat(text[0..text.len].*);
        var bytes: [text.len * count:0]u8 = @splat(0);
        @memcpy(bytes[0 .. text.len * count], @as(*const [text.len * count]u8, @ptrCast(&units)));
        const final = bytes;
        break :blk &final;
    };
}

pub fn isModelSafeText(text: []const u8) bool {
    if (std.mem.findScalar(u8, text, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(text);
}

pub fn utf8BackwardBoundary(text: []const u8, index: usize) usize {
    var len = @min(index, text.len);
    while (len > 0 and len < text.len and (text[len] & 0b1100_0000) == 0b1000_0000) {
        len -= 1;
    }
    return len;
}

pub fn utf8ForwardBoundary(text: []const u8, index: usize) usize {
    var len = @min(index, text.len);
    while (len < text.len and (text[len] & 0b1100_0000) == 0b1000_0000) {
        len += 1;
    }
    return len;
}

pub const HeadRounding = enum { down, up };

/// Writes text truncated to max_content_bytes as head + marker + tail with
/// rune-safe cut points. The caller chooses how the retained budget splits
/// between head and tail when it is odd.
pub fn writeHeadTailBounded(
    writer: *std.Io.Writer,
    text: []const u8,
    max_content_bytes: usize,
    marker: []const u8,
    head_rounding: HeadRounding,
) !void {
    if (text.len <= max_content_bytes) return writer.writeAll(text);
    if (max_content_bytes <= marker.len) {
        return writer.writeAll(marker[0..max_content_bytes]);
    }
    const retained_bytes = max_content_bytes - marker.len;
    const head_bytes = switch (head_rounding) {
        .down => retained_bytes / 2,
        .up => (retained_bytes + 1) / 2,
    };
    const tail_bytes = retained_bytes - head_bytes;
    const head_end = utf8BackwardBoundary(text, head_bytes);
    const tail_start = utf8ForwardBoundary(text, text.len - tail_bytes);
    try writer.writeAll(text[0..head_end]);
    try writer.writeAll(marker);
    try writer.writeAll(text[tail_start..]);
}

pub fn utf8PrefixByBytes(text: []const u8, max_bytes: usize) []const u8 {
    return text[0..utf8BackwardBoundary(text, max_bytes)];
}

pub fn normalizeLineEndingsInPlace(bytes: []u8) []u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < bytes.len) {
        if (bytes[read] == '\r') {
            bytes[write] = '\n';
            write += 1;
            read += 1;
            if (read < bytes.len and bytes[read] == '\n') read += 1;
            continue;
        }
        bytes[write] = bytes[read];
        write += 1;
        read += 1;
    }
    return bytes[0..write];
}

pub const EncodedText = struct {
    bytes: []u8,
    truncated: bool,

    pub fn deinit(self: *EncodedText, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

/// Incrementally applies the same terminal-safe token policy as
/// `encodeTerminalSafe`. It retains at most one unfinished UTF-8 token so a
/// caller can process bounded file pages without exposing raw bytes.
pub const IncrementalTerminalSafeEncoder = struct {
    pending: [4]u8 = undefined,
    pending_len: usize = 0,

    pub fn append(
        self: *IncrementalTerminalSafeEncoder,
        writer: *std.Io.Writer,
        raw: []const u8,
    ) !void {
        var index: usize = 0;
        while (self.pending_len > 0) {
            if (try self.writePendingToken(writer)) continue;
            if (index == raw.len) return;
            self.pending[self.pending_len] = raw[index];
            self.pending_len += 1;
            index += 1;
        }

        while (index < raw.len) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(raw[index]) catch 1;
            if (raw.len - index < sequence_len) {
                const remaining = raw[index..];
                @memcpy(self.pending[0..remaining.len], remaining);
                self.pending_len = remaining.len;
                return;
            }
            try writeTerminalSafeToken(writer, raw, index);
            var token_buf: [12]u8 = undefined;
            index += terminalSafeToken(raw, index, &token_buf).source_len;
        }
    }

    pub fn finish(self: *IncrementalTerminalSafeEncoder, writer: *std.Io.Writer) !void {
        while (self.pending_len > 0) {
            try self.emitPendingToken(writer);
        }
    }

    fn writePendingToken(self: *IncrementalTerminalSafeEncoder, writer: *std.Io.Writer) !bool {
        const sequence_len = std.unicode.utf8ByteSequenceLength(self.pending[0]) catch 1;
        if (self.pending_len < sequence_len) return false;

        try self.emitPendingToken(writer);
        return true;
    }

    fn emitPendingToken(self: *IncrementalTerminalSafeEncoder, writer: *std.Io.Writer) !void {
        var token_buf: [12]u8 = undefined;
        const token = terminalSafeToken(self.pending[0..self.pending_len], 0, &token_buf);
        try writer.writeAll(token.bytes);
        const remaining = self.pending_len - token.source_len;
        if (remaining > 0) {
            @memmove(
                self.pending[0..remaining],
                self.pending[token.source_len..self.pending_len],
            );
        }
        self.pending_len = remaining;
    }
};

/// Validates UTF-8 across arbitrary chunks and rejects an incomplete final sequence.
pub const IncrementalUtf8Validator = struct {
    pending: [4]u8 = undefined,
    pending_len: usize = 0,

    pub fn append(self: *IncrementalUtf8Validator, bytes: []const u8) error{InvalidUtf8}!void {
        var index: usize = 0;
        if (self.pending_len > 0) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(self.pending[0]) catch return error.InvalidUtf8;
            const copied = @min(sequence_len - self.pending_len, bytes.len);
            @memcpy(self.pending[self.pending_len .. self.pending_len + copied], bytes[0..copied]);
            self.pending_len += copied;
            index += copied;
            if (self.pending_len < sequence_len) return;
            _ = display_width.decodeUtf8Sequence(self.pending[0..sequence_len]) catch return error.InvalidUtf8;
            self.pending_len = 0;
        }

        while (index < bytes.len) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return error.InvalidUtf8;
            if (bytes.len - index < sequence_len) {
                const remaining = bytes[index..];
                @memcpy(self.pending[0..remaining.len], remaining);
                self.pending_len = remaining.len;
                return;
            }
            _ = display_width.decodeUtf8Sequence(bytes[index .. index + sequence_len]) catch return error.InvalidUtf8;
            index += sequence_len;
        }
    }

    pub fn finish(self: *IncrementalUtf8Validator) error{InvalidUtf8}!void {
        if (self.pending_len != 0) return error.InvalidUtf8;
    }
};

pub const EncodedPathTail = struct {
    bytes: []u8,
    basename_start: usize,
    source_truncated: bool,

    pub fn deinit(self: *EncodedPathTail, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

pub fn encodeTerminalSafePathTail(
    alloc: std.mem.Allocator,
    raw: []const u8,
    max_encoded_bytes: usize,
) error{ OutOfMemory, PathBasenameTooLong }!EncodedPathTail {
    const basename = std.Io.Dir.path.basename(raw);
    if (basename.len == 0) return error.PathBasenameTooLong;
    const basename_source_start = raw.len - basename.len;

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(alloc);
    var boundaries: std.ArrayList(usize) = .empty;
    defer boundaries.deinit(alloc);
    try boundaries.append(alloc, 0);

    var encoded_basename_start: ?usize = null;
    var source_index: usize = 0;
    while (source_index < raw.len) {
        if (source_index == basename_source_start) {
            encoded_basename_start = encoded.items.len;
        }
        var token_buf: [12]u8 = undefined;
        const token = terminalSafeToken(raw, source_index, &token_buf);
        try encoded.appendSlice(alloc, token.bytes);
        source_index += token.source_len;
        try boundaries.append(alloc, encoded.items.len);
    }
    const basename_start = encoded_basename_start orelse
        return error.PathBasenameTooLong;
    const basename_bytes = encoded.items.len - basename_start;
    if (basename_bytes > max_encoded_bytes) return error.PathBasenameTooLong;

    if (encoded.items.len <= max_encoded_bytes) {
        return .{
            .bytes = try encoded.toOwnedSlice(alloc),
            .basename_start = basename_start,
            .source_truncated = false,
        };
    }

    const marker = "…";
    if (marker.len + basename_bytes > max_encoded_bytes) {
        return error.PathBasenameTooLong;
    }
    const suffix_budget = max_encoded_bytes - marker.len;
    var suffix_start: ?usize = null;
    for (boundaries.items) |boundary| {
        if (encoded.items.len - boundary <= suffix_budget) {
            suffix_start = boundary;
            break;
        }
    }
    const start = suffix_start orelse return error.PathBasenameTooLong;
    if (start > basename_start) return error.PathBasenameTooLong;

    const output = try alloc.alloc(
        u8,
        marker.len + encoded.items.len - start,
    );
    @memcpy(output[0..marker.len], marker);
    @memcpy(output[marker.len..], encoded.items[start..]);
    return .{
        .bytes = output,
        .basename_start = marker.len + basename_start - start,
        .source_truncated = true,
    };
}

pub fn suffixTerminalSafeByWidth(
    encoded: []const u8,
    max_width: usize,
) []const u8 {
    var width = display_width.visibleWidth(encoded);
    if (width <= max_width) return encoded;

    var start: usize = 0;
    while (start < encoded.len and width > max_width) {
        const token_len = terminalSafeEncodedTokenLen(encoded[start..]);
        const token = encoded[start .. start + token_len];
        width -|= display_width.visibleWidth(token);
        start += token_len;
    }
    return encoded[start..];
}

pub fn prefixTerminalSafeByWidth(
    encoded: []const u8,
    max_width: usize,
) []const u8 {
    var width: usize = 0;
    var end: usize = 0;
    while (end < encoded.len) {
        const token_len = terminalSafeEncodedTokenLen(encoded[end..]);
        const token_end = @min(encoded.len, end + token_len);
        const token = encoded[end..token_end];
        const token_width = display_width.visibleWidth(token);
        if (width + token_width > max_width) break;
        width += token_width;
        end = token_end;
    }
    return encoded[0..end];
}

fn terminalSafeEncodedTokenLen(encoded: []const u8) usize {
    if (encoded.len >= 4 and
        encoded[0] == '\\' and
        encoded[1] == 'x' and
        std.ascii.isHex(encoded[2]) and
        std.ascii.isHex(encoded[3]))
    {
        return 4;
    }
    if (encoded.len >= 5 and
        encoded[0] == '\\' and
        encoded[1] == 'u' and
        encoded[2] == '{')
    {
        var index: usize = 3;
        var saw_hex = false;
        while (index < encoded.len and index < 12) : (index += 1) {
            if (encoded[index] == '}') {
                if (saw_hex) return index + 1;
                break;
            }
            if (!std.ascii.isHex(encoded[index])) break;
            saw_hex = true;
        }
    }
    return @min(
        encoded.len,
        std.unicode.utf8ByteSequenceLength(encoded[0]) catch 1,
    );
}

pub fn encodeTerminalSafe(
    alloc: std.mem.Allocator,
    raw: []const u8,
    max_encoded_bytes: usize,
) error{OutOfMemory}!EncodedText {
    const marker = "...";
    const marker_len = @min(marker.len, max_encoded_bytes);
    const content_limit = max_encoded_bytes - marker_len;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);

    var marker_boundary: usize = 0;
    var truncated = false;
    var index: usize = 0;
    while (index < raw.len) {
        var token_buf: [12]u8 = undefined;
        const token = terminalSafeToken(raw, index, &token_buf);
        const next_len = std.math.add(usize, bytes.items.len, token.bytes.len) catch {
            truncated = true;
            break;
        };
        if (next_len > max_encoded_bytes) {
            truncated = true;
            break;
        }
        try bytes.appendSlice(alloc, token.bytes);
        index += token.source_len;
        if (next_len <= content_limit) marker_boundary = next_len;
    }
    if (truncated) {
        bytes.items.len = marker_boundary;
        try bytes.appendSlice(alloc, marker[0..marker_len]);
    }
    return .{
        .bytes = try bytes.toOwnedSlice(alloc),
        .truncated = truncated,
    };
}

/// Like `encodeTerminalSafe`, but first flattens every run of ASCII
/// whitespace (including line breaks and tabs) into a single space and trims
/// the ends, so multi-line human-readable text stays readable inside a
/// one-line summary. Non-whitespace control bytes and invalid UTF-8 still get
/// visible `\xNN` escapes.
pub fn encodeTerminalSafeInline(
    alloc: std.mem.Allocator,
    raw: []const u8,
    max_encoded_bytes: usize,
) error{OutOfMemory}!EncodedText {
    var flattened: std.ArrayList(u8) = .empty;
    defer flattened.deinit(alloc);
    var pending_space = false;
    for (raw) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = flattened.items.len > 0;
            continue;
        }
        if (pending_space) {
            try flattened.append(alloc, ' ');
            pending_space = false;
        }
        try flattened.append(alloc, byte);
    }
    return encodeTerminalSafe(alloc, flattened.items, max_encoded_bytes);
}

/// `raw` as a `{f}` format argument, written with the visible escapes
/// `encodeTerminalSafe` uses, without allocating or shortening it. Messages
/// use it to quote a word from the command line, the environment, or a file,
/// so the terminal shows the word instead of acting on its escape sequences.
pub fn terminalSafe(raw: []const u8) TerminalSafe {
    return .{ .raw = raw };
}

const TerminalSafe = struct {
    raw: []const u8,

    pub fn format(self: TerminalSafe, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var index: usize = 0;
        while (index < self.raw.len) {
            var token_buf: [12]u8 = undefined;
            const token = terminalSafeToken(self.raw, index, &token_buf);
            try writer.writeAll(token.bytes);
            index += token.source_len;
        }
    }
};

test "terminalSafe writes what encodeTerminalSafe returns" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "plain --model", "dark\x1b]0;owned\x07\x1b[2J", "tab\there\r\n", "caf\xc3\xa9 \xff\xfe", "\x7f\xc2\x9b" }) |raw| {
        var encoded = try encodeTerminalSafe(alloc, raw, std.math.maxInt(usize));
        defer encoded.deinit(alloc);
        const formatted = try alloc.print("{f}", .{terminalSafe(raw)});
        defer alloc.free(formatted);
        try std.testing.expectEqualStrings(encoded.bytes, formatted);
        try std.testing.expect(isTerminalSafe(formatted));
    }
}

/// Appends one line of file text ready to draw. Tabs stay, since they only
/// move along the row, and a trailing carriage return from a CRLF line ending
/// is dropped. Every other control byte, C1 control, and invalid UTF-8 byte
/// becomes the visible escape `encodeTerminalSafe` writes, so the terminal
/// never acts on the file's own sequences.
pub fn appendTerminalSafeLine(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw: []const u8,
) error{OutOfMemory}!void {
    const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
    var index: usize = 0;
    while (index < line.len) {
        if (line[index] == '\t') {
            try out.append(alloc, '\t');
            index += 1;
            continue;
        }
        var token_buf: [12]u8 = undefined;
        const token = terminalSafeToken(line, index, &token_buf);
        try out.appendSlice(alloc, token.bytes);
        index += token.source_len;
    }
}

/// A copy of `raw` that is valid UTF-8. Each byte outside a valid sequence
/// becomes the `\xNN` escape `encodeTerminalSafe` writes for it; everything
/// else, control bytes included, is kept for the renderer to handle. Caller
/// owns the result.
pub fn dupeValidUtf8(alloc: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]u8 {
    if (std.unicode.utf8ValidateSlice(raw)) return alloc.dupe(u8, raw);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 0;
    while (index < raw.len) {
        const sequence_len = validUtf8SequenceLength(raw, index) orelse {
            var buf: [12]u8 = undefined;
            try out.appendSlice(alloc, writeByteEscape(&buf, raw[index]));
            index += 1;
            continue;
        };
        try out.appendSlice(alloc, raw[index .. index + sequence_len]);
        index += sequence_len;
    }
    return out.toOwnedSlice(alloc);
}

/// The length of the valid UTF-8 sequence at `index`, or null when the byte
/// there does not start one, by the same rule `terminalSafeToken` applies.
fn validUtf8SequenceLength(raw: []const u8, index: usize) ?usize {
    if (raw[index] < 0x80) return 1;
    const sequence_len = std.unicode.utf8ByteSequenceLength(raw[index]) catch return null;
    if (index + sequence_len > raw.len) return null;
    _ = display_width.decodeUtf8Sequence(raw[index .. index + sequence_len]) catch return null;
    return sequence_len;
}

/// Returns true when `raw` is valid printable terminal text and
/// `encodeTerminalSafe` would preserve it byte-for-byte.
pub fn isTerminalSafe(raw: []const u8) bool {
    var index: usize = 0;
    while (index < raw.len) {
        var token_buf: [12]u8 = undefined;
        const token = terminalSafeToken(raw, index, &token_buf);
        if (token.source_len != token.bytes.len) return false;
        if (!std.mem.eql(u8, raw[index .. index + token.source_len], token.bytes)) return false;
        index += token.source_len;
    }
    return true;
}

/// Returns true when `raw` draws as it is under `appendTerminalSafeText`:
/// line breaks and tabs are its only control bytes, and the rest is valid
/// UTF-8 with no C1 control.
pub fn isTerminalSafeText(raw: []const u8) bool {
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '\n' or raw[index] == '\t') {
            index += 1;
            continue;
        }
        var token_buf: [12]u8 = undefined;
        const token = escapedToken(raw, index, &token_buf, .controls);
        if (token.source_len != token.bytes.len) return false;
        if (!std.mem.eql(u8, raw[index .. index + token.source_len], token.bytes)) return false;
        index += token.source_len;
    }
    return true;
}

/// Appends prose of any number of lines, such as a prompt or a model's reply,
/// ready to draw: line breaks and tabs stay, a carriage return before a line
/// break is dropped, and every other control byte, C1 control, and invalid
/// UTF-8 byte becomes the visible escape `encodeTerminalSafe` writes. Unlike
/// `appendTerminalSafeLine`, it keeps zero-width joiners, direction marks,
/// and other invisible format characters, which emoji sequences and some
/// scripts need.
pub fn appendTerminalSafeText(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw: []const u8,
) error{OutOfMemory}!void {
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte == '\n' or byte == '\t') {
            try out.append(alloc, byte);
            index += 1;
            continue;
        }
        if (byte == '\r' and index + 1 < raw.len and raw[index + 1] == '\n') {
            index += 1;
            continue;
        }
        var token_buf: [12]u8 = undefined;
        const token = escapedToken(raw, index, &token_buf, .controls);
        try out.appendSlice(alloc, token.bytes);
        index += token.source_len;
    }
}

test "terminal-safe text keeps its lines and tabs and shows every other control as an escape" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendTerminalSafeText(alloc, &out, "one\ttab\r\ntwo \x1b]2;pwned\x07 \xc2\x9b2J caf\xc3\xa9 \xff");
    try std.testing.expectEqualStrings("one\ttab\ntwo \\x1b]2;pwned\\x07 \\u{009b}2J caf\xc3\xa9 \\xff", out.items);
    try std.testing.expect(isTerminalSafeText(out.items));

    try std.testing.expect(isTerminalSafeText("one\ttwo\nthree caf\xc3\xa9"));

    // A joined emoji, a zero-width non-joiner, and a right-to-left mark stay.
    const joined = "team \u{1f469}\u{200d}\u{1f4bb} \u{200c}\u{200f}";
    try std.testing.expect(isTerminalSafeText(joined));
    out.clearRetainingCapacity();
    try appendTerminalSafeText(alloc, &out, joined);
    try std.testing.expectEqualStrings(joined, out.items);
    for ([_][]const u8{ "a\x1bb", "a\xc2\x9bb", "a\r\nb", "a\x7fb", "a\xffb" }) |raw| {
        try std.testing.expect(!isTerminalSafeText(raw));
    }
}

/// Returns true when `url` can be an OSC 8 link target as it is: printable
/// ASCII with no space, so nothing in it can end the sequence. Show any other
/// address as text instead.
pub fn isLinkTarget(url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

test "a link target is printable ASCII with no space" {
    try std.testing.expect(isLinkTarget("https://mcp.example.com/authorize?state=a%20b&x=1#y"));
    for ([_][]const u8{ "", "https://h/a b", "https://h/a\x1b\\\x1b]8;;evil", "https://h/a\x07", "https://h/\xc3\xa9", "https://h/\x7f" }) |odd| {
        try std.testing.expect(!isLinkTarget(odd));
    }
}

pub fn terminalSafeVisibleWidth(raw: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < raw.len) {
        var token_buf: [12]u8 = undefined;
        const token = terminalSafeToken(raw, index, &token_buf);
        width += display_width.visibleWidth(token.bytes);
        index += token.source_len;
    }
    return width;
}

pub fn clippedLabel(buf: []u8, text: []const u8, max_len: usize) []const u8 {
    if (buf.len == 0 or max_len == 0) return "";
    if (display_width.visibleWidth(text) <= max_len) return text;

    const keep_limit = if (max_len > 3) max_len - 3 else 0;
    const prefix = display_width.prefixByWidth(text, keep_limit);
    const keep = @min(prefix.len, buf.len);
    if (keep == 0) return display_width.prefixByWidth(text, max_len);

    @memcpy(buf[0..keep], prefix[0..keep]);
    if (keep + 3 <= buf.len) {
        @memcpy(buf[keep .. keep + 3], "...");
        return buf[0 .. keep + 3];
    }
    return buf[0..keep];
}

pub fn sanitizeModelText(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (isModelSafeText(text)) return text;
    return arena.print("binary or non-utf8 tool output omitted ({d} bytes)", .{text.len});
}

/// Overwrites every occurrence of `secret` in `text` with `*`, in place, so
/// the text keeps its length. An empty secret masks nothing.
pub fn maskLiteral(text: []u8, secret: []const u8) void {
    if (secret.len == 0) return;
    var rest = text;
    while (std.mem.find(u8, rest, secret)) |at| {
        @memset(rest[at..][0..secret.len], '*');
        rest = rest[at + secret.len ..];
    }
}

test "maskLiteral masks every occurrence in place" {
    var text = "key abc, abcabc, and abc".*;
    maskLiteral(&text, "abc");
    try std.testing.expectEqualStrings("key ***, ******, and ***", &text);
    var unchanged = "abc".*;
    maskLiteral(&unchanged, "");
    try std.testing.expectEqualStrings("abc", &unchanged);
    var shorter = "ab".*;
    maskLiteral(&shorter, "abc");
    try std.testing.expectEqualStrings("ab", &shorter);
}

pub fn maskSecrets(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    return maskSecretsWith(arena, text, null);
}

/// `maskSecrets`, which also puts each secret value it masks in `values` when
/// one is given. The values are slices of `text`, not copies, so `text` must
/// outlive them.
fn maskSecretsWith(arena: std.mem.Allocator, text: []const u8, values: ?*SecretValues) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var spans: SecretSpans = .{ .text = text };
    var written: usize = 0;
    var modified = false;
    while (spans.next()) |span| {
        modified = true;
        if (values) |collected| try collected.put(arena, text[span.prefix_end..][0..span.value_len]);
        try out.writer.writeAll(text[written..span.prefix_end]);
        try out.writer.writeAll("[redacted]");
        debug_trace.logf("core", "secret redacted kind={s} bytes={d}", .{ span.kind, span.value_len });
        written = span.prefix_end + span.value_len;
    }
    if (!modified) return text;
    try out.writer.writeAll(text[written..]);
    return try out.toOwnedSlice();
}

/// Whether `c` can be part of a run of secret bytes. Keys and tokens are
/// runs of letters, digits, `-`, `_`, and `.`, and an assignment's value
/// can also hold symbols such as `/`, `+`, and `=`. Whitespace, quotes, and
/// the brackets and separators of JSON and shell text end every such run,
/// and so do bytes that are not ASCII, which no key or token holds.
fn inSecretRun(c: u8) bool {
    if (c >= 0x80 or std.ascii.isWhitespace(c)) return false;
    return switch (c) {
        '"', '\'', '`', '\\', ',', ';', '(', ')', '[', ']', '{', '}', '<', '>', '|' => false,
        else => true,
    };
}

/// The secret spans of a text in order, as `findSecretSpan` finds them. The
/// masking walk and `SecretValues.collect` both use it, so they find the same
/// secrets. A caller writes or keeps the bytes between spans itself.
const SecretSpans = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *SecretSpans) ?SecretSpan {
        while (self.at < self.text.len) {
            if (findSecretSpan(self.text, self.at)) |span| {
                self.at = span.prefix_end + span.value_len;
                return span;
            }
            self.at += 1;
        }
        return null;
    }
};

/// The public prefix of a `Bearer` token, which holds a space.
const bearer_prefix = "Bearer ";

/// The whole secret values that `maskSecretsCutShortCollect` masks, each kept
/// once, so a later pass can mask the pieces that a wrap leaves of them. A
/// value is a slice of the text it was found in, not a copy, and `arena` holds
/// only the set's own storage, so that text must outlive the set.
pub const SecretValues = struct {
    /// Past this many distinct values, `overflow` is set and no more are
    /// kept, so a transcript full of keys cannot make masking slow.
    pub const max_values = 1024;

    values: std.ArrayList([]const u8) = .empty,
    seen: std.array_hash_map.String(void) = .empty,
    overflow: bool = false,

    /// Keeps `value` once. A distinct value past `max_values` sets `overflow`
    /// and is not kept. A `Bearer` value also keeps its token, the part after
    /// the prefix: a row that wraps at the space holds the token alone, which
    /// the whole value would never match.
    fn put(self: *SecretValues, arena: std.mem.Allocator, value: []const u8) !void {
        try self.keep(arena, value);
        if (value.len > bearer_prefix.len and std.mem.startsWith(u8, value, bearer_prefix)) {
            try self.keep(arena, value[bearer_prefix.len..]);
        }
    }

    /// `put` without the `Bearer` split.
    fn keep(self: *SecretValues, arena: std.mem.Allocator, value: []const u8) !void {
        // `[redacted]` is what masking writes, and a bare `Bearer` is a word, not
        // a token: `TOKEN=Bearer xoxb-...` collects it. Keeping either would make
        // every occurrence of it a piece of a secret.
        if (std.mem.eql(u8, value, "[redacted]") or std.mem.eql(u8, value, "Bearer")) return;
        if (self.overflow or self.seen.contains(value)) return;
        if (self.values.items.len == max_values) {
            self.overflow = true;
            return;
        }
        try self.seen.put(arena, value, {});
        try self.values.append(arena, value);
    }

    /// Puts every secret value that `maskSecretsWith` would mask in `text`, and
    /// masks nothing. A caller uses it for text it shows in pieces, where the
    /// masked copy would be thrown away. Like `put`, the values are slices of
    /// `text`.
    pub fn collect(self: *SecretValues, arena: std.mem.Allocator, text: []const u8) !void {
        var spans: SecretSpans = .{ .text = text };
        while (spans.next()) |span| try self.put(arena, text[span.prefix_end..][0..span.value_len]);
    }
};

/// The fewest bytes of a secret value that `maskSecretPieces` masks at the start
/// or the end of a row. A piece of one to three bytes is a documented limit at
/// those edges: an overlap that short occurs in too many ordinary words, so the
/// row keeps it.
const min_secret_piece_bytes = 4;

/// The fewest bytes of a lone run that `maskSecretPieces` masks as a piece of a
/// secret. A table column can shrink to the narrowest width, `table_min_column_width`
/// in transcript_blocks.zig, which is three cells, so one row of a narrow cell can
/// show three bytes of a token. A lone run wholly inside the value's public prefix
/// is still common text, whatever its length.
pub const min_secret_cell_piece_bytes = 3;

/// The most bytes that `maskSecretPieces` may compare across one trace. A crafted
/// set of values or a long row would otherwise make the comparison slow. A trace
/// shares one budget over all of its rows. At about five nanoseconds a byte,
/// this bounds the comparison work of a trace to about 20 milliseconds.
pub const max_piece_compare_bytes = 4 * 1024 * 1024;

/// `row` with each piece of a known secret value replaced by `[redacted]`.
/// A row splits into segments at bytes that are not ASCII, such as box-drawing
/// borders and CJK text, and at `|`. A wrap cuts a value where a row ends, so
/// its pieces sit at the edges of a segment: the last run of secret bytes, when
/// the run's end is the value's start; the first run, when the run's start is
/// the value's end; and a segment's only run, when a value holds all of it. A
/// whole value in the middle of a segment is left to `maskSecrets`. A start or
/// end piece must be at least `min_secret_piece_bytes` long, and a lone run at
/// least `min_secret_cell_piece_bytes`. A lone run is a piece only where
/// it runs past the value's public prefix, such as `sk-` or `Bearer `, since a
/// run wholly inside that prefix is common text. A start piece is that case at
/// the value's start. The first run's end piece is the value's own tail, so it
/// has no such rule.
/// Every comparison is charged to `budget`, the bytes that a trace may still
/// compare. When the budget would go below zero, the call returns
/// `error.SecretPieceBudgetSpent` and masks nothing: the caller decides what to
/// show in its place.
/// Returns `row` itself when nothing is masked or `values` is empty; otherwise
/// the result is allocated in `arena`.
pub fn maskSecretPieces(arena: std.mem.Allocator, row: []const u8, values: []const []const u8, budget: *usize) ![]const u8 {
    if (values.len == 0) return row;
    var marks: ?[]bool = null;
    var segment_start: usize = 0;
    for (row, 0..) |byte, at| {
        if (!isSegmentBreak(byte)) continue;
        try markSegmentPieces(arena, row, segment_start, at, values, &marks, budget);
        segment_start = at + 1;
    }
    try markSegmentPieces(arena, row, segment_start, row.len, values, &marks, budget);

    const masked = marks orelse return row;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < row.len) {
        const is_masked = masked[index];
        var end = index + 1;
        while (end < row.len and masked[end] == is_masked) end += 1;
        if (is_masked) {
            try out.appendSlice(arena, "[redacted]");
        } else {
            try out.appendSlice(arena, row[index..end]);
        }
        index = end;
    }
    return out.items;
}

/// Whether `byte` ends a segment for `maskSecretPieces`. A byte that is not
/// ASCII belongs to a glyph such as a border or CJK text, which no secret
/// holds, and `|` is the ASCII table border.
fn isSegmentBreak(byte: u8) bool {
    return byte >= 0x80 or byte == '|';
}

/// A half-open byte range of a row.
const ByteRange = struct {
    start: usize,
    end: usize,
};

/// The first and the last run of secret bytes in a segment.
const SegmentRunEdges = struct {
    first: ByteRange,
    last: ByteRange,
};

/// The first and the last runs of `inSecretRun` bytes in `row[start..end]`, or
/// null when the segment has none.
fn secretRunEdges(row: []const u8, start: usize, end: usize) ?SegmentRunEdges {
    var edges: ?SegmentRunEdges = null;
    var index = start;
    while (index < end) {
        if (!inSecretRun(row[index])) {
            index += 1;
            continue;
        }
        const run_start = index;
        while (index < end and inSecretRun(row[index])) index += 1;
        const run: ByteRange = .{ .start = run_start, .end = index };
        if (edges) |*found| {
            found.last = run;
        } else {
            edges = .{ .first = run, .last = run };
        }
    }
    return edges;
}

/// The length of the longest public prefix that `value` starts with: the longest
/// key or token start that `maskSecrets` finds, such as `sk-`, `ghp_`, or
/// `Bearer `. Such a prefix is common text, so a run that lies wholly inside it
/// is not masked.
fn publicPrefixLen(value: []const u8) usize {
    var longest: usize = 0;
    for (token_prefixes ++ [_][]const u8{bearer_prefix}) |prefix| {
        if (prefix.len > longest and std.mem.startsWith(u8, value, prefix)) longest = prefix.len;
    }
    return longest;
}

/// The number of leading bytes that `a` and `b` share.
fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const limit = @min(a.len, b.len);
    var index: usize = 0;
    while (index < limit and a[index] == b[index]) index += 1;
    return index;
}

/// Charges `budget` for one comparison of `a` with `b`: the bytes they share,
/// plus one for the step that decides the comparison. When the budget cannot pay
/// for it, the call fails with `error.SecretPieceBudgetSpent` and leaves zero.
fn chargeComparison(budget: *usize, a: []const u8, b: []const u8) !void {
    const cost = commonPrefixLen(a, b) + 1;
    if (cost > budget.*) {
        budget.* = 0;
        return error.SecretPieceBudgetSpent;
    }
    budget.* -= cost;
}

/// Whether `piece` occurs in `value` at a position where it runs past the first
/// `public_len` bytes, the value's public prefix. A piece wholly inside that
/// prefix is common text, so the search starts at the first position where the
/// piece reaches past it. Each position it tries is a comparison that the
/// budget pays for, so a long value cannot make the search unbounded.
fn containsPastPrefix(value: []const u8, piece: []const u8, public_len: usize, budget: *usize) !bool {
    // A piece at `at` runs past the prefix once `at + piece.len > public_len`.
    var at: usize = (public_len + 1) -| piece.len;
    while (at + piece.len <= value.len) : (at += 1) {
        try chargeComparison(budget, piece, value[at..]);
        if (std.mem.startsWith(u8, value[at..], piece)) return true;
    }
    return false;
}

/// The offset of the longest suffix of `run` that is a prefix of `value`, when
/// that suffix is longer than the value's public prefix and at least
/// `min_secret_piece_bytes` long. The last run of a row ends in a value's start
/// when a wrap cut the value there.
fn lastRunPieceStart(run: []const u8, value: []const u8, budget: *usize) !?usize {
    const shortest = @max(min_secret_piece_bytes, publicPrefixLen(value) + 1);
    // A piece longer than the value cannot start it, so the search begins at the
    // first offset whose piece fits.
    var offset: usize = run.len -| value.len;
    while (run.len - offset >= shortest) : (offset += 1) {
        const piece = run[offset..];
        try chargeComparison(budget, piece, value);
        if (std.mem.startsWith(u8, value, piece)) return offset;
    }
    return null;
}

/// The length of the longest prefix of `run` that is a suffix of `value`, when
/// that prefix is at least `min_secret_piece_bytes` long. The first run of a
/// row starts with a value's end when a wrap cut the value there.
fn firstRunPieceLen(run: []const u8, value: []const u8, budget: *usize) !?usize {
    var len = @min(run.len, value.len);
    while (len >= min_secret_piece_bytes) : (len -= 1) {
        const piece = run[0..len];
        const tail = value[value.len - len ..];
        try chargeComparison(budget, piece, tail);
        if (std.mem.eql(u8, piece, tail)) return len;
    }
    return null;
}

/// Marks in `marks` the pieces of `values` that `row[start..end]` holds, as
/// `maskSecretPieces` describes. Runs between the first and the last are not
/// looked at, so `maskSecrets` keeps the job of masking a whole value there.
fn markSegmentPieces(
    arena: std.mem.Allocator,
    row: []const u8,
    start: usize,
    end: usize,
    values: []const []const u8,
    marks: *?[]bool,
    budget: *usize,
) !void {
    const edges = secretRunEdges(row, start, end) orelse return;
    const first = edges.first;
    const last = edges.last;
    const only_run = first.start == last.start;
    const first_len = first.end - first.start;
    for (values) |value| {
        // A lone run is a piece of the value where it runs past the value's
        // public prefix. Where it lies wholly inside the prefix, it is common text.
        const only_run_in_value = only_run and
            first_len >= min_secret_cell_piece_bytes and
            (try containsPastPrefix(value, row[first.start..first.end], publicPrefixLen(value), budget));
        if (only_run_in_value) {
            try markRange(arena, row.len, marks, first.start, first.end);
            continue;
        }
        if (try lastRunPieceStart(row[last.start..last.end], value, budget)) |offset| {
            try markRange(arena, row.len, marks, last.start + offset, last.end);
        }
        if (try firstRunPieceLen(row[first.start..first.end], value, budget)) |len| {
            try markRange(arena, row.len, marks, first.start, first.start + len);
        }
    }
}

/// Marks `row[from..to]` in `marks`. The marks are allocated on the first mark,
/// so a row that holds no piece costs no memory.
fn markRange(arena: std.mem.Allocator, row_len: usize, marks: *?[]bool, from: usize, to: usize) !void {
    if (marks.* == null) {
        const fresh = try arena.alloc(bool, row_len);
        @memset(fresh, false);
        marks.* = fresh;
    }
    @memset(marks.*.?[from..to], true);
}

/// Length of the longest prefix of `value` no longer than `limit` bytes that
/// ends on a UTF-8 boundary and keeps no part of a secret the cut splits.
/// `maskSecrets` finds a secret only whole, so a cut inside one would leave
/// its kept part unmasked. A cut inside a run of secret bytes leaves out the
/// whole run, or in a run longer than `max_split_secret_run` only a key or
/// token that starts near the cut, and when what is left ends inside a URL's
/// authority, which can hold a credential in any bytes before its `@`, the
/// URL is left out from its scheme. Assignments and quoted values need
/// neither: `maskSecrets` masks them even when they are cut short.
pub fn secretSafePrefixLen(value: []const u8, limit: usize) usize {
    if (value.len <= limit) return value.len;
    var end = withoutSplitSecretRun(value, utf8PrefixByBytes(value, limit).len);
    var word_start = end;
    while (word_start > 0 and !std.ascii.isWhitespace(value[word_start - 1])) word_start -= 1;
    if (std.mem.findLast(u8, value[word_start..end], "://")) |relative| {
        const scheme_end = word_start + relative;
        if (std.mem.findAny(u8, value[scheme_end + 3 .. end], "/?#@") == null) {
            var scheme_start = scheme_end;
            while (scheme_start > word_start and std.ascii.isAlphabetic(value[scheme_start - 1])) scheme_start -= 1;
            end = withoutSplitSecretRun(value, scheme_start);
        }
    }
    return end;
}

/// Longest run of secret bytes that a cut leaves out whole. A key or token
/// in a longer run keeps its start, which `maskSecrets` matches on, and
/// enough of itself to match, unless it starts in the last
/// `secret_prefix_window` bytes before the cut; then it is left out from
/// its start.
const max_split_secret_run = 512;
const secret_prefix_window = 64;
/// The starts of the keys and tokens `maskSecrets` finds without a space.
const token_prefixes = inline_key_prefixes ++ github_token_prefixes ++ aws_key_prefixes;

/// `end`, moved back past the run of secret bytes it splits, if any; in a
/// run longer than `max_split_secret_run`, only past a key or token that
/// starts within `secret_prefix_window` bytes of it.
fn withoutSplitSecretRun(value: []const u8, end: usize) usize {
    if (end == 0 or end >= value.len or !inSecretRun(value[end]) or !inSecretRun(value[end - 1])) return end;
    var start = end;
    while (start > 0 and inSecretRun(value[start - 1])) : (start -= 1) {
        if (end - start == max_split_secret_run) break;
    }
    if (start == 0 or !inSecretRun(value[start - 1])) return start;
    const window_start = end - secret_prefix_window;
    var cut = end;
    for (token_prefixes) |prefix| {
        if (std.mem.findLast(u8, value[window_start..end], prefix)) |relative| cut = @min(cut, window_start + relative);
    }
    return cut;
}

/// How far back `secretSafeSuffixStart` walks for a secret the start falls
/// inside: longer than a private key or a service account's JSON.
const max_secret_lookback = 16 * 1024;

/// Where a tail of `value` that would start at `start`, a UTF-8 boundary,
/// starts instead so it holds no part of a secret the start splits: past the
/// rest of a run of secret bytes it splits, and then past the `@` of a URL
/// credential whose scheme the tail no longer holds. `maskSecrets` could find
/// neither, because each lacks the start it matches on. A token after
/// `Bearer `, which `maskSecrets` finds only with that prefix, is left out
/// when the tail does not hold all of the prefix. A start inside a secret
/// that `maskSecrets` finds in the whole value moves past that secret first.
/// It applies its rules again wherever a step ends, until the start stays put.
pub fn secretSafeSuffixStart(value: []const u8, start: usize) usize {
    var at = start;
    while (true) {
        const next = suffixStartStep(value, at);
        if (next <= at) return at;
        at = next;
    }
}

/// `secretSafeSuffixStart`'s rules, applied once.
fn suffixStartStep(value: []const u8, start: usize) usize {
    if (start == 0 or start >= value.len) return start;
    // Walk the start's line the way `maskSecrets` does, from at most
    // `max_secret_lookback` bytes back: a start inside a secret it would find
    // in the whole value moves past that secret, because the tail alone lacks
    // the start the mask matches on, such as an assignment's key or a quoted
    // value's opening quote. No secret crosses a line break. Inside a word,
    // only a URL credential can start, so the walk skips the rest.
    const window = start -| max_secret_lookback;
    var at = if (std.mem.findScalarLast(u8, value[window..start], '\n')) |line_break| window + line_break + 1 else window;
    while (at < start) {
        if (at > 0 and isAssignmentKeyChar(value[at - 1]) and !std.mem.startsWith(u8, value[at..], "https://")) {
            at += 1;
            continue;
        }
        const span = findSecretSpan(value, at) orelse {
            at += 1;
            continue;
        };
        const span_end = span.prefix_end + span.value_len;
        if (span_end > start) return @min(span_end, value.len);
        at = @max(span_end, at + 1);
    }
    var begin = start;
    if (!std.ascii.isWhitespace(value[start - 1])) {
        if (inSecretRun(value[start - 1]) and inSecretRun(value[start])) {
            while (begin < value.len and inSecretRun(value[begin])) begin += 1;
        }
        var i = begin;
        while (i < value.len and !std.ascii.isWhitespace(value[i]) and value[i] != '/' and value[i] != '?' and value[i] != '#') : (i += 1) {
            if (value[i] == '@') {
                begin = i + 1;
                break;
            }
        }
    }
    var token = begin;
    while (token < value.len and std.ascii.isWhitespace(value[token])) token += 1;
    const bearer = "Bearer ";
    if (token >= bearer.len and begin > token - bearer.len and std.mem.eql(u8, value[token - bearer.len .. token], bearer)) {
        begin = token;
        while (begin < value.len and inSecretRun(value[begin])) begin += 1;
    }
    return begin;
}

/// How far back from a cut marker `maskSecretsCutShort` looks for the start
/// of a secret: longer than any key or token `maskSecrets` needs whole.
const max_cut_short_secret_len = 512;

/// `text` with `maskSecrets` applied, and also with a key, a token, or a
/// URL credential masked when a cut marker (`...` or `…`) ends it. A
/// display that cuts text short marks the cut, and `maskSecrets` finds a
/// secret only whole, so it would leave the start of one that the cut
/// shortened unmasked. Returns `text` when nothing is masked; otherwise the
/// result is allocated in `arena`.
pub fn maskSecretsCutShort(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    return maskCutShortMarkers(arena, try maskSecrets(arena, text));
}

/// `maskSecretsCutShort`, and each whole secret value it masks is put in
/// `values`, for `maskSecretPieces` to find the pieces a wrap leaves of them.
pub fn maskSecretsCutShortCollect(arena: std.mem.Allocator, text: []const u8, values: *SecretValues) ![]const u8 {
    return maskCutShortMarkers(arena, try maskSecretsWith(arena, text, values));
}

/// The cut-marker pass of `maskSecretsCutShort`, over text that `maskSecrets`
/// has already masked. It is kept apart so the collecting entry point shares it.
fn maskCutShortMarkers(arena: std.mem.Allocator, masked: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    var changed = false;
    var last_marker_end: usize = 0;
    var i: usize = 0;
    while (i < masked.len) {
        const marker_len: usize = if (std.mem.startsWith(u8, masked[i..], "...") or std.mem.startsWith(u8, masked[i..], "\u{2026}")) 3 else 0;
        if (marker_len == 0) {
            i += 1;
            continue;
        }
        if (cutShortSecretStart(masked, @max(@max(copied, last_marker_end), i -| max_cut_short_secret_len), i)) |start| {
            try out.appendSlice(arena, masked[copied..start]);
            try out.appendSlice(arena, "[redacted]");
            copied = i;
            changed = true;
        }
        i += marker_len;
        while (i < masked.len and masked[i] == '.') i += 1;
        last_marker_end = i;
    }
    if (!changed) return masked;
    try out.appendSlice(arena, masked[copied..]);
    return out.items;
}

/// Where a secret that a cut marker at `end` cut short starts, or null. It
/// looks no further back than `floor`.
fn cutShortSecretStart(text: []const u8, floor: usize, end: usize) ?usize {
    var word_start = end;
    while (word_start > floor and !std.ascii.isWhitespace(text[word_start - 1])) word_start -= 1;
    if (std.mem.findLast(u8, text[word_start..end], "://")) |relative| {
        const credential_start = word_start + relative + 3;
        const authority = text[credential_start..end];
        if (std.mem.findAny(u8, authority, "/?#@") == null and std.mem.findScalar(u8, authority, ':') != null) return credential_start;
    }
    var run_start = end;
    while (run_start > floor and inSecretRun(text[run_start - 1])) run_start -= 1;
    if (run_start == end) return null;
    const bearer = "Bearer ";
    if (run_start >= floor + bearer.len and std.mem.eql(u8, text[run_start - bearer.len .. run_start], bearer)) return run_start;
    var earliest: ?usize = null;
    for (token_prefixes) |prefix| {
        var search = run_start;
        while (std.mem.find(u8, text[search..end], prefix)) |relative| {
            const at = search + relative;
            if (at == run_start or !isTokenChar(text[at - 1])) {
                if (earliest == null or at < earliest.?) earliest = at;
                break;
            }
            search = at + 1;
        }
    }
    return earliest;
}

pub fn redactUrlForDisplay(alloc: std.mem.Allocator, raw_url: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    const scheme_end = std.mem.find(u8, raw_url, "://");
    var query_search_start: usize = 0;
    if (scheme_end) |end| {
        const authority_start = end + "://".len;
        const authority_end = firstDelimiter(raw_url, authority_start, "/?#");
        if (std.mem.findScalar(u8, raw_url[authority_start..authority_end], '@')) |at| {
            out.writer.writeAll(raw_url[0..authority_start]) catch return error.OutOfMemory;
            out.writer.writeAll("[redacted]@") catch return error.OutOfMemory;
            out.writer.writeAll(raw_url[authority_start + at + 1 .. authority_end]) catch return error.OutOfMemory;
        } else {
            out.writer.writeAll(raw_url[0..authority_end]) catch return error.OutOfMemory;
        }
        query_search_start = authority_end;
    }

    if (scheme_end == null) query_search_start = 0;
    const query_marker = std.mem.findScalarPos(u8, raw_url, query_search_start, '?') orelse {
        if (scheme_end == null) {
            out.writer.writeAll(raw_url) catch return error.OutOfMemory;
        } else {
            out.writer.writeAll(raw_url[query_search_start..]) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice() catch return error.OutOfMemory;
    };
    if (scheme_end == null) {
        out.writer.writeAll(raw_url[0 .. query_marker + 1]) catch return error.OutOfMemory;
    } else {
        out.writer.writeAll(raw_url[query_search_start .. query_marker + 1]) catch return error.OutOfMemory;
    }

    const query_end = std.mem.findScalarPos(u8, raw_url, query_marker + 1, '#') orelse raw_url.len;
    var segment_start = query_marker + 1;
    while (segment_start < query_end) {
        const segment_end = std.mem.findScalarPos(u8, raw_url, segment_start, '&') orelse query_end;
        const equals = std.mem.findScalarPos(u8, raw_url, segment_start, '=') orelse segment_end;
        out.writer.writeAll(raw_url[segment_start..equals]) catch return error.OutOfMemory;
        if (equals < segment_end) {
            out.writer.writeByte('=') catch return error.OutOfMemory;
            if (sensitiveUrlQueryKey(raw_url[segment_start..equals])) {
                out.writer.writeAll("[redacted]") catch return error.OutOfMemory;
            } else {
                out.writer.writeAll(raw_url[equals + 1 .. segment_end]) catch return error.OutOfMemory;
            }
        }
        if (segment_end < query_end) out.writer.writeByte('&') catch return error.OutOfMemory;
        segment_start = segment_end + 1;
    }
    out.writer.writeAll(raw_url[query_end..]) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn sanitizeAssistantText(text: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return trimmed;

    const first_break = std.mem.findScalar(u8, trimmed, '\n') orelse return trimmed;
    const first_line = std.mem.trim(u8, trimmed[0..first_break], " \r\n\t");

    const is_intro = containsIgnoreCase(first_line, "i'm fx") or
        containsIgnoreCase(first_line, "i am fx") or
        containsIgnoreCase(first_line, "local coding assistant");
    if (!is_intro) return trimmed;

    trimmed = std.mem.trimStart(u8, trimmed[first_break + 1 ..], " \r\n\t");
    return trimmed;
}

const SecretSpan = struct {
    prefix_end: usize,
    value_len: usize,
    kind: []const u8,
};

const TerminalSafeToken = struct {
    source_len: usize,
    bytes: []const u8,
};

/// The code points a token writes as an escape: every non-printing one, or
/// only the C1 controls a terminal acts on.
const EscapedCodepoints = enum { non_printing, controls };

fn terminalSafeToken(raw: []const u8, index: usize, buf: *[12]u8) TerminalSafeToken {
    return escapedToken(raw, index, buf, .non_printing);
}

fn escapedToken(
    raw: []const u8,
    index: usize,
    buf: *[12]u8,
    comptime codepoints: EscapedCodepoints,
) TerminalSafeToken {
    const byte = raw[index];
    if (byte < 0x20 or byte == 0x7f) {
        return .{ .source_len = 1, .bytes = writeByteEscape(buf, byte) };
    }
    if (byte < 0x80) {
        return .{ .source_len = 1, .bytes = raw[index .. index + 1] };
    }

    const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
        return .{ .source_len = 1, .bytes = writeByteEscape(buf, byte) };
    };
    if (index + sequence_len > raw.len) {
        return .{ .source_len = 1, .bytes = writeByteEscape(buf, byte) };
    }

    const sequence = raw[index .. index + sequence_len];
    const codepoint = display_width.decodeUtf8Sequence(sequence) catch {
        return .{ .source_len = 1, .bytes = writeByteEscape(buf, byte) };
    };
    const escape = switch (codepoints) {
        .non_printing => isNonPrintingCodepoint(codepoint),
        .controls => codepoint >= 0x80 and codepoint <= 0x9f,
    };
    if (escape) {
        return .{ .source_len = sequence_len, .bytes = writeCodepointEscape(buf, codepoint) };
    }
    return .{ .source_len = sequence_len, .bytes = sequence };
}

fn writeTerminalSafeToken(writer: *std.Io.Writer, raw: []const u8, index: usize) !void {
    var token_buf: [12]u8 = undefined;
    const token = terminalSafeToken(raw, index, &token_buf);
    try writer.writeAll(token.bytes);
}

fn writeByteEscape(buf: *[12]u8, byte: u8) []const u8 {
    buf[0] = '\\';
    buf[1] = 'x';
    const end = 2 + std.fmt.printInt(
        buf[2..],
        byte,
        16,
        .lower,
        .{ .width = 2, .fill = '0' },
    );
    return buf[0..end];
}

fn writeCodepointEscape(buf: *[12]u8, codepoint: u21) []const u8 {
    buf[0] = '\\';
    buf[1] = 'u';
    buf[2] = '{';
    const digit_end = 3 + std.fmt.printInt(
        buf[3 .. buf.len - 1],
        codepoint,
        16,
        .lower,
        .{ .width = 4, .fill = '0' },
    );
    buf[digit_end] = '}';
    return buf[0 .. digit_end + 1];
}

fn isNonPrintingCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x80 and codepoint <= 0x9f) or
        (codepoint >= 0x200b and codepoint <= 0x200f) or
        (codepoint >= 0x2028 and codepoint <= 0x202e) or
        (codepoint >= 0x2060 and codepoint <= 0x206f) or
        codepoint == 0xfeff;
}

const secret_prefixes = [_][]const u8{
    "OPENAI_API_KEY=",
    "ANTHROPIC_API_KEY=",
    "AI_GATEWAY_API_KEY=",
    "VERCEL_OIDC_TOKEN=",
    "GITHUB_TOKEN=",
    "AWS_SECRET_ACCESS_KEY=",
    "DATABASE_URL=",
    "SECRET_KEY=",
    "API_KEY=",
    "TOKEN=",
    "PASSWORD=",
    "PRIVATE_KEY=",
};

fn findSecretSpan(text: []const u8, start: usize) ?SecretSpan {
    if (matchesBasicAuthUrl(text, start)) |span| return span;
    if (matchesAwsAccessKey(text, start)) |span| return span;
    if (matchesSensitiveAssignment(text, start)) |span| return span;
    for (secret_prefixes) |prefix| {
        if ((start == 0 or !isAssignmentKeyChar(text[start - 1])) and
            start + prefix.len < text.len and
            eqlIgnoreCase(text[start .. start + prefix.len], prefix))
        {
            const value_start = start + prefix.len;
            if (secretAssignmentValueSpan(text, start, value_start)) |value| {
                return .{ .prefix_end = value.prefix_end, .value_len = value.value_len, .kind = "assignment" };
            }
        }
    }
    if (start + 3 < text.len) {
        if (matchesInlineKey(text, start)) |span| return span;
    }
    return null;
}

/// The starts of the keys and tokens `matchesInlineKey` finds, without
/// `Bearer `, which holds a space.
const inline_key_prefixes = [_][]const u8{ "sk-", "sk_live_", "pk_live_", "github_pat_", "xoxb-", "xoxp-" };
const github_token_prefixes = [_][]const u8{ "ghp_", "gho_", "ghu_", "ghs_", "ghr_" };
const aws_key_prefixes = [_][]const u8{ "AKIA", "ASIA", "AIDA", "AGPA", "AROA", "ANPA" };

fn matchesInlineKey(text: []const u8, start: usize) ?SecretSpan {
    if (start > 0 and isTokenChar(text[start - 1])) return null;
    const prefixes = inline_key_prefixes ++ [_][]const u8{"Bearer "};
    for (prefixes) |prefix| {
        if (start + prefix.len < text.len and std.mem.startsWith(u8, text[start..], prefix)) {
            var end = start + prefix.len;
            while (end < text.len and isTokenChar(text[end])) : (end += 1) {}
            const total = end - start;
            if (total >= 16) return .{ .prefix_end = start, .value_len = total, .kind = "token" };
        }
    }
    if (matchesGithubToken(text, start)) |span| return span;
    return null;
}

fn matchesGithubToken(text: []const u8, start: usize) ?SecretSpan {
    if (start + 40 > text.len) return null;
    var found = false;
    for (github_token_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text[start..], prefix)) {
            found = true;
            break;
        }
    }
    if (!found) return null;
    var end = start + 4;
    while (end < text.len and isTokenChar(text[end])) : (end += 1) {}
    if (end - (start + 4) < 36) return null;
    return .{ .prefix_end = start, .value_len = end - start, .kind = "github_token" };
}

fn matchesAwsAccessKey(text: []const u8, start: usize) ?SecretSpan {
    for (aws_key_prefixes) |prefix| {
        if (start + 20 > text.len or !std.mem.startsWith(u8, text[start..], prefix)) continue;
        const candidate = text[start .. start + 20];
        for (candidate) |c| {
            if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return null;
        }
        if (start > 0 and isTokenChar(text[start - 1])) return null;
        if (start + 20 < text.len and isTokenChar(text[start + 20])) return null;
        return .{ .prefix_end = start, .value_len = 20, .kind = "aws_access_key" };
    }
    return null;
}

fn matchesBasicAuthUrl(text: []const u8, start: usize) ?SecretSpan {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, text[start..], prefix)) return null;
    const credential_start = start + prefix.len;
    var i = credential_start;
    var colon: ?usize = null;
    while (i < text.len and text[i] != '\n' and text[i] != '\r' and !std.ascii.isWhitespace(text[i])) : (i += 1) {
        if (text[i] == '/' or text[i] == '?' or text[i] == '#') return null;
        if (text[i] == ':' and colon == null) colon = i;
        if (text[i] == '@') {
            if (colon != null and i > credential_start) {
                return .{ .prefix_end = credential_start, .value_len = i - credential_start, .kind = "url_credentials" };
            }
            return null;
        }
    }
    return null;
}

fn matchesSensitiveAssignment(text: []const u8, start: usize) ?SecretSpan {
    if (start > 0 and isAssignmentKeyChar(text[start - 1])) return null;
    if (!isAssignmentKeyChar(text[start])) return null;

    var eq = start;
    while (eq < text.len and isAssignmentKeyChar(text[eq])) : (eq += 1) {}
    if (eq == start or eq >= text.len or text[eq] != '=') return null;
    const key = text[start..eq];
    if (!sensitiveAssignmentKey(key)) return null;

    const value_start = eq + 1;
    if (secretAssignmentValueSpan(text, start, value_start)) |value| {
        return .{ .prefix_end = value.prefix_end, .value_len = value.value_len, .kind = "assignment" };
    }
    return null;
}

const AssignmentValueSpan = struct {
    prefix_end: usize,
    value_len: usize,
};

fn secretAssignmentValueSpan(
    text: []const u8,
    assignment_start: usize,
    value_start: usize,
) ?AssignmentValueSpan {
    const value = assignmentValueSpan(text, assignment_start, value_start) orelse return null;
    if (isPureSymbolicAssignment(text, assignment_start, value_start, value)) return null;
    return value;
}

fn isPureSymbolicAssignment(
    text: []const u8,
    assignment_start: usize,
    value_start: usize,
    value: AssignmentValueSpan,
) bool {
    if (text[value_start] == '\'') return false;
    if (!isPureShellVariableReference(
        text[value.prefix_end .. value.prefix_end + value.value_len],
    )) return false;
    const value_end = value.prefix_end + value.value_len;
    const outer_double_quoted = assignment_start > 0 and
        text[assignment_start - 1] == '"';
    if (text[value_start] != '"' and !outer_double_quoted) {
        return value_end == text.len or isShellWordBoundary(text, value_end);
    }

    const closing_quote = value_end;
    if (closing_quote >= text.len or text[closing_quote] != '"') return false;
    const next = closing_quote + 1;
    return next == text.len or isShellWordBoundary(text, next);
}

fn isShellWordBoundary(text: []const u8, index: usize) bool {
    return switch (text[index]) {
        ' ', '\t', '\n', ';', '&', '|', ')' => true,
        '<', '>' => index + 1 == text.len or text[index + 1] != '(',
        else => false,
    };
}

fn isPureShellVariableReference(value: []const u8) bool {
    if (value.len < 2 or value[0] != '$') return false;
    if (value[1] == '{') {
        if (value.len < 4 or value[value.len - 1] != '}') return false;
        return isShellVariableName(value[2 .. value.len - 1]);
    }
    return isShellVariableName(value[1..]);
}

fn isShellVariableName(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) {
        return false;
    }
    for (value[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn assignmentValueSpan(
    text: []const u8,
    assignment_start: usize,
    value_start: usize,
) ?AssignmentValueSpan {
    if (value_start >= text.len) return null;

    if (text[value_start] == '"' or text[value_start] == '\'') {
        const quote = text[value_start];
        const content_start = value_start + 1;
        var end = content_start;
        while (end < text.len and text[end] != '\n' and text[end] != '\r' and text[end] != quote) : (end += 1) {}
        const value_len = end - content_start;
        if (value_len >= 1) return .{ .prefix_end = content_start, .value_len = value_len };
        return null;
    }

    if (assignment_start > 0 and text[assignment_start - 1] == '"') {
        var end = value_start;
        while (end < text.len and text[end] != '\n' and text[end] != '\r' and
            text[end] != '"') : (end += 1)
        {}
        const value_len = end - value_start;
        if (value_len >= 1) return .{ .prefix_end = value_start, .value_len = value_len };
        return null;
    }

    var end = value_start;
    while (end < text.len and text[end] != '\n' and text[end] != '\r' and !std.ascii.isWhitespace(text[end]) and text[end] != '"' and text[end] != '\'') : (end += 1) {}
    if (end == value_start) return null;
    return .{ .prefix_end = value_start, .value_len = end - value_start };
}

fn sensitiveAssignmentKey(key: []const u8) bool {
    const exact = [_][]const u8{
        "password",
        "passwd",
        "api_key",
        "apikey",
        "secret",
        "token",
        "private_key",
        "access_key",
    };
    for (exact) |needle| {
        if (eqlIgnoreCase(key, needle)) return true;
    }
    return containsIgnoreCase(key, "password") or
        containsIgnoreCase(key, "api_key") or
        containsIgnoreCase(key, "apikey") or
        containsIgnoreCase(key, "secret") or
        containsIgnoreCase(key, "token") or
        containsIgnoreCase(key, "private_key") or
        containsIgnoreCase(key, "access_key");
}

fn sensitiveUrlQueryKey(key: []const u8) bool {
    if (percentDecodedEqlIgnoreCase(key, "sig")) return true;
    const needles = [_][]const u8{
        "password",
        "passwd",
        "token",
        "api_key",
        "apikey",
        "secret",
        "authorization",
        "cookie",
        "signature",
        "credential",
        "access_key",
        "private_key",
    };
    for (needles) |needle| {
        if (percentDecodedContainsIgnoreCase(key, needle)) return true;
    }
    return false;
}

fn percentDecodedEqlIgnoreCase(text: []const u8, expected: []const u8) bool {
    var text_index: usize = 0;
    for (expected) |expected_byte| {
        const byte = nextPercentDecodedByte(text, &text_index) orelse return false;
        if (std.ascii.toLower(byte) != std.ascii.toLower(expected_byte)) return false;
    }
    return text_index == text.len;
}

fn percentDecodedContainsIgnoreCase(text: []const u8, needle: []const u8) bool {
    var start: usize = 0;
    while (start < text.len) : (start += 1) {
        var text_index = start;
        var needle_index: usize = 0;
        while (needle_index < needle.len) : (needle_index += 1) {
            const char = nextPercentDecodedByte(text, &text_index) orelse break;
            if (std.ascii.toLower(char) != std.ascii.toLower(needle[needle_index])) break;
        } else return true;
    }
    return false;
}

fn nextPercentDecodedByte(text: []const u8, index: *usize) ?u8 {
    if (index.* >= text.len) return null;
    if (text[index.*] == '%' and index.* + 2 < text.len) {
        const high = std.fmt.charToDigit(text[index.* + 1], 16) catch null;
        const low = std.fmt.charToDigit(text[index.* + 2], 16) catch null;
        if (high != null and low != null) {
            index.* += 3;
            return @intCast(high.? * 16 + low.?);
        }
    }
    defer index.* += 1;
    return text[index.*];
}

/// Where a URL's authority is, from after "://" to the first '/', '?', or
/// '#', and where its host starts (`urlUserInfoEnd`).
pub const UrlAuthority = struct {
    start: usize,
    host_start: usize,
    end: usize,
};

/// Null for text with no "://".
pub fn urlAuthority(url: []const u8) ?UrlAuthority {
    const scheme_end = std.mem.find(u8, url, "://") orelse return null;
    const start = scheme_end + "://".len;
    const end = firstDelimiter(url, start, "/?#");
    return .{ .start = start, .host_start = urlUserInfoEnd(url, start, end), .end = end };
}

/// Where a user name and password that start at `start` end, in a URL whose
/// authority may end at `end`: after the last '@' before it, as a browser
/// reads them, so a password with an unescaped '@' stays in them. `start`
/// when there is no '@'.
fn urlUserInfoEnd(url: []const u8, start: usize, end: usize) usize {
    return if (std.mem.findScalarLast(u8, url[start..end], '@')) |at| start + at + 1 else start;
}

fn firstDelimiter(text: []const u8, start: usize, delimiters: []const u8) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (std.mem.findScalar(u8, delimiters, text[index]) != null) return index;
    }
    return text.len;
}

fn isAssignmentKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test "containsIgnoreCase handles empty needles and oversized needles" {
    try std.testing.expect(containsIgnoreCase("Haystack", ""));
    try std.testing.expect(!containsIgnoreCase("short", "longer needle"));
    try std.testing.expect(containsIgnoreCase("Local Coding Assistant", "coding"));
}

test "isModelSafeText rejects nul bytes and invalid utf-8" {
    try std.testing.expect(isModelSafeText("hello"));
    try std.testing.expect(!isModelSafeText("hello\x00world"));
    try std.testing.expect(!isModelSafeText("\xff"));
}

test "sanitizeModelText returns replacement text for unsafe input" {
    const alloc = std.testing.allocator;

    const safe = try sanitizeModelText(alloc, "plain text");
    try std.testing.expectEqualStrings("plain text", safe);

    const unsafe = try sanitizeModelText(alloc, "bad\xff");
    defer alloc.free(unsafe);
    try std.testing.expectEqualStrings("binary or non-utf8 tool output omitted (4 bytes)", unsafe);
}

test "maskSecrets masks env-style secrets" {
    const alloc = std.testing.allocator;
    const input = "AI_GATEWAY_API_KEY=abcdefghijklmnop end";

    const masked = try maskSecrets(alloc, input);
    defer if (masked.ptr != input.ptr) alloc.free(masked);

    try std.testing.expectEqualStrings("AI_GATEWAY_API_KEY=[redacted] end", masked);
}

test "maskSecrets masks quoted sensitive assignments" {
    const alloc = std.testing.allocator;
    const input =
        "API_KEY=\"double-secret\"\n" ++
        "PASSWORD='single-secret'\n" ++
        "ACCESS_TOKEN=\"access-secret\"";

    const masked = try maskSecrets(alloc, input);
    defer if (masked.ptr != input.ptr) alloc.free(masked);

    try std.testing.expectEqualStrings(
        "API_KEY=\"[redacted]\"\n" ++
            "PASSWORD='[redacted]'\n" ++
            "ACCESS_TOKEN=\"[redacted]\"",
        masked,
    );
    try std.testing.expect(std.mem.find(u8, masked, "double-secret") == null);
    try std.testing.expect(std.mem.find(u8, masked, "single-secret") == null);
    try std.testing.expect(std.mem.find(u8, masked, "access-secret") == null);
}

test "maskSecrets preserves pure symbolic sensitive assignments" {
    const alloc = std.testing.allocator;
    const input =
        "AI_GATEWAY_API_KEY=\"$key\"\n" ++
        "sandbox -e \"AI_GATEWAY_API_KEY=$key\" \"$@\"\n" ++
        "GITHUB_TOKEN=$token\n" ++
        "DATABASE_URL=\"${database_url}\"\n" ++
        "TOKEN=\"$token\"; run-next\n" ++
        "PASSWORD=\"$password\"\tcheck-next\n" ++
        "ACCESS_TOKEN=\"$token\">token.out\n" ++
        "SECRET_KEY=\"$key\")";

    const masked = try maskSecrets(alloc, input);
    defer if (masked.ptr != input.ptr) alloc.free(masked);

    try std.testing.expectEqualStrings(input, masked);
}

test "maskSecrets masks compound or literal sensitive assignments" {
    const alloc = std.testing.allocator;
    const input =
        "AI_GATEWAY_API_KEY=\"literal-value\"\n" ++
        "sandbox -e \"AI_GATEWAY_API_KEY=literal-value\"\n" ++
        "sandbox -e \"AI_GATEWAY_API_KEY=$key literal-suffix\"\n" ++
        "sandbox -e \"GITHUB_TOKEN=$token;literal-suffix\"\n" ++
        "sandbox -e \"ACCESS_TOKEN=$token>token.out\"\n" ++
        "sandbox -e \"SECRET_KEY=$key$tail\"\n" ++
        "sandbox -e \"GITHUB_TOKEN=$token-suffix\"\n" ++
        "sandbox -e \"API_KEY=$(load-key)\"\n" ++
        "GITHUB_TOKEN=\"$token-suffix\"\n" ++
        "DATABASE_URL=\"${database_url:-fallback}\"\n" ++
        "API_KEY=\"$(load-key)\"\n" ++
        "VERCEL_OIDC_TOKEN=\"$token\"literal-suffix\n" ++
        "OPENAI_API_KEY=$key\"literal-suffix\"\n" ++
        "PASSWORD=\"$password\"\x0bliteral-suffix\n" ++
        "ACCESS_TOKEN=\"$token\"\x0cliteral-suffix\n" ++
        "SECRET=\"$secret\"\rliteral-suffix\n" ++
        "AI_GATEWAY_API_KEY=\"$key\"(literal-suffix)\n" ++
        "GITHUB_TOKEN=\"$token\"<(literal-suffix)\n" ++
        "ACCESS_TOKEN=\"$token\">(literal-suffix)\n" ++
        "SECRET_KEY=\"$key";

    const masked = try maskSecrets(alloc, input);
    defer if (masked.ptr != input.ptr) alloc.free(masked);

    try std.testing.expectEqualStrings(
        "AI_GATEWAY_API_KEY=\"[redacted]\"\n" ++
            "sandbox -e \"AI_GATEWAY_API_KEY=[redacted]\"\n" ++
            "sandbox -e \"AI_GATEWAY_API_KEY=[redacted]\"\n" ++
            "sandbox -e \"GITHUB_TOKEN=[redacted]\"\n" ++
            "sandbox -e \"ACCESS_TOKEN=[redacted]\"\n" ++
            "sandbox -e \"SECRET_KEY=[redacted]\"\n" ++
            "sandbox -e \"GITHUB_TOKEN=[redacted]\"\n" ++
            "sandbox -e \"API_KEY=[redacted]\"\n" ++
            "GITHUB_TOKEN=\"[redacted]\"\n" ++
            "DATABASE_URL=\"[redacted]\"\n" ++
            "API_KEY=\"[redacted]\"\n" ++
            "VERCEL_OIDC_TOKEN=\"[redacted]\"literal-suffix\n" ++
            "OPENAI_API_KEY=[redacted]\"literal-suffix\"\n" ++
            "PASSWORD=\"[redacted]\"\x0bliteral-suffix\n" ++
            "ACCESS_TOKEN=\"[redacted]\"\x0cliteral-suffix\n" ++
            "SECRET=\"[redacted]\"\rliteral-suffix\n" ++
            "AI_GATEWAY_API_KEY=\"[redacted]\"(literal-suffix)\n" ++
            "GITHUB_TOKEN=\"[redacted]\"<(literal-suffix)\n" ++
            "ACCESS_TOKEN=\"[redacted]\">(literal-suffix)\n" ++
            "SECRET_KEY=\"[redacted]",
        masked,
    );
}

test "maskSecrets preserves non-sensitive quoted assignments" {
    const alloc = std.testing.allocator;
    const input = "PROJECT_NAME=\"secret-service\"\nGREETING='hello world'";

    const masked = try maskSecrets(alloc, input);
    defer if (masked.ptr != input.ptr) alloc.free(masked);

    try std.testing.expectEqualStrings(input, masked);
}

test "maskSecrets masks inline tokens" {
    const alloc = std.testing.allocator;
    const input = "token sk-abcdefghijklmnop now";

    const masked = try maskSecrets(alloc, input);
    defer if (masked.ptr != input.ptr) alloc.free(masked);

    try std.testing.expectEqualStrings("token [redacted] now", masked);
}

test "maskSecrets preserves inline-key substrings inside ordinary tokens" {
    const alloc = std.testing.allocator;
    const input = "printf output > ask-turn-default-auto.txt";

    const masked = try maskSecrets(alloc, input);
    defer if (masked.ptr != input.ptr) alloc.free(masked);

    try std.testing.expectEqualStrings(input, masked);
}

test "maskSecrets masks expanded model-facing secret patterns" {
    const alloc = std.testing.allocator;
    const input =
        "aws=AKIA0123456789ABCDEF\n" ++
        "github=ghs_abcdefghijklmnopqrstuvwxyz0123456789AB\n" ++
        "url=https://user:token@example.com/path\n" ++
        "password=hunter2\n" ++
        "CUSTOM_API_KEY=abc123";

    const masked = try maskSecrets(alloc, input);
    defer if (masked.ptr != input.ptr) alloc.free(masked);

    try std.testing.expectEqualStrings(
        "aws=[redacted]\n" ++
            "github=[redacted]\n" ++
            "url=https://[redacted]@example.com/path\n" ++
            "password=[redacted]\n" ++
            "CUSTOM_API_KEY=[redacted]",
        masked,
    );
    try std.testing.expect(std.mem.find(u8, masked, "AKIA0123456789ABCDEF") == null);
}

test "secretSafePrefixLen keeps text that fits or a cut between words" {
    const text = "alpha beta gamma";
    try std.testing.expectEqual(text.len, secretSafePrefixLen(text, text.len));
    try std.testing.expectEqual(text.len, secretSafePrefixLen(text, text.len + 8));

    // Byte 11 is the `g` of `gamma`, right after the space, so no run splits.
    try std.testing.expectEqual(@as(usize, 11), secretSafePrefixLen(text, 11));

    // Byte 7 is the `e` of `beta`, so the whole word goes.
    try std.testing.expectEqual(@as(usize, 6), secretSafePrefixLen("alpha beta", 7));
}

test "secretSafePrefixLen never keeps part of a key or token the cut splits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct {
        value: []const u8,
        secret_start: usize,
        probe: []const u8,
    }{
        .{
            .value = "export KEY_ID " ++ "ghp_" ++ repeat("A", 36),
            .secret_start = "export KEY_ID ".len,
            .probe = "AAAAAA",
        },
        .{
            .value = "export KEY_ID " ++ "sk-proj-" ++ repeat("b", 40),
            .secret_start = "export KEY_ID ".len,
            .probe = "bbbbbb",
        },
        .{
            .value = "export KEY_ID " ++ "AKIA" ++ repeat("Q", 16),
            .secret_start = "export KEY_ID ".len,
            .probe = "QQQQQQ",
        },
        .{
            .value = "export KEY_ID " ++ "xoxb-" ++ repeat("1", 30),
            .secret_start = "export KEY_ID ".len,
            .probe = "111111",
        },
        .{
            .value = "run curl -H \"Authorization: " ++ "Bearer " ++ repeat("t", 40),
            .secret_start = "run curl -H \"Authorization: ".len,
            .probe = "tttttt",
        },
    };

    for (cases) |case| {
        for (case.secret_start..case.value.len) |cut| {
            const kept = case.value[0..secretSafePrefixLen(case.value, cut)];
            try std.testing.expect(std.mem.startsWith(u8, case.value, kept));
            const masked = try maskSecrets(arena, kept);
            try std.testing.expect(std.mem.find(u8, masked, case.probe) == null);
        }
        _ = arena_state.reset(.retain_capacity);
    }
}

test "secretSafePrefixLen leaves out a URL whose credential the cut splits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = "clone https://admin:P\u{e4}ss1234@example.com/repo now";
    const credential_start = "clone https://".len;
    const at = std.mem.findScalar(u8, value, '@').?;

    for (credential_start..at) |cut| {
        if ((value[cut] & 0xc0) == 0x80) continue;
        try std.testing.expectEqualStrings("clone ", value[0..secretSafePrefixLen(value, cut)]);
    }

    // A cut inside the host leaves the credential whole for `maskSecrets`.
    const kept = value[0..secretSafePrefixLen(value, at + 4)];
    const masked = try maskSecrets(arena, kept);
    try std.testing.expect(std.mem.find(u8, masked, "admin:P") == null);
}

test "secretSafePrefixLen keeps CJK text before a cut and minified JSON up to a delimiter" {
    try std.testing.expectEqual(
        @as(usize, 6),
        secretSafePrefixLen("\u{4e2d}\u{6587}\u{4e2d}\u{6587}", 7),
    );

    const value = "{\"a\":\"xyz\",\"b\":\"" ++ "ghp_" ++ repeat("A", 36) ++ "\"}";
    const token_start = "{\"a\":\"xyz\",\"b\":\"".len;
    const kept = value[0..secretSafePrefixLen(value, token_start + 10)];
    try std.testing.expect(std.mem.endsWith(u8, kept, "\"b\":\""));
}

test "secretSafePrefixLen keeps a long run but not a token that starts near its cut" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A run with no delimiter keeps the bytes before the cut.
    try std.testing.expectEqual(@as(usize, 1200), secretSafePrefixLen(repeat("a", 2200), 1200));

    // A token that starts within the window before the cut goes.
    const near = repeat("x", 600) ++ "ghp_" ++ repeat("A", 36) ++ " end";
    var cut: usize = 601;
    while (cut <= 639) : (cut += 1) {
        const kept = secretSafePrefixLen(near, cut);
        if (cut >= 600 + "ghp_".len) {
            try std.testing.expectEqual(@as(usize, 600), kept);
        } else {
            // The window holds no whole `ghp_` yet, so only the prefix bytes
            // the cut keeps go.
            try std.testing.expectEqual(cut, kept);
        }
    }

    // A cut well past the token keeps the run, and `maskSecrets` still finds
    // the whole token.
    const long = repeat("x", 600) ++ " ghp_" ++ repeat("A", 36) ++ repeat("y", 600);
    const long_cut = 600 + " ghp_".len + 36 + 520;
    try std.testing.expectEqual(long_cut, secretSafePrefixLen(long, long_cut));
    const masked = try maskSecrets(arena, long[0..long_cut]);
    try std.testing.expect(std.mem.find(u8, masked, "[redacted]") != null);
    try std.testing.expect(std.mem.find(u8, masked, "AAAAAA") == null);
}

test "secretSafeSuffixStart skips the rest of a split token or a URL credential" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token_value = "start " ++ "ghp_" ++ repeat("A", 36) ++ " end";
    const token_start = "start ".len;
    const token_end_space = std.mem.findScalarLast(u8, token_value, ' ').?;
    const token_end_start = token_end_space + 1;

    try std.testing.expectEqual(@as(usize, 0), secretSafeSuffixStart(token_value, 0));
    try std.testing.expectEqual(token_start, secretSafeSuffixStart(token_value, token_start));
    try std.testing.expectEqual(token_end_start, secretSafeSuffixStart(token_value, token_end_start));
    for (token_start + "ghp_".len..token_start + "ghp_".len + 36) |start| {
        try std.testing.expectEqual(token_end_space, secretSafeSuffixStart(token_value, start));
    }

    const url_value = "go https://admin:P\u{e4}ss1234@example.com/x end";
    const credential_start = "go https://".len;
    const at = std.mem.findScalar(u8, url_value, '@').?;
    for (credential_start..at) |start| {
        if ((url_value[start] & 0xc0) == 0x80) continue;
        const result = secretSafeSuffixStart(url_value, start);
        try std.testing.expect(result >= at + 1);
        const masked = try maskSecrets(arena, url_value[result..]);
        try std.testing.expect(std.mem.find(u8, masked, "admin") == null);
        try std.testing.expect(std.mem.find(u8, masked, "ss1234") == null);
    }

    const bearer_value = "curl -H \"Authorization: Bearer " ++ repeat("t", 40) ++ "\" end";
    const bearer_start = std.mem.find(u8, bearer_value, "Bearer ").?;
    for (bearer_start + "B".len..bearer_start + "Bearer t".len) |start| {
        const masked = try maskSecrets(arena, bearer_value[secretSafeSuffixStart(bearer_value, start)..]);
        try std.testing.expect(std.mem.find(u8, masked, "tttttt") == null);
    }

    const assignment = "set AWS_SECRET_ACCESS_KEY=wJalr/XUtnF+EMIK7=MDENG end";
    const value_start = std.mem.findScalar(u8, assignment, '=').? + 1;
    const end_space = std.mem.findScalarLast(u8, assignment, ' ').?;
    for (value_start..end_space) |start| {
        try std.testing.expectEqual(end_space, secretSafeSuffixStart(assignment, start));
    }

    // A quoted value holds a space, so the run skip stops inside it; the mask
    // finds the whole value, so the tail moves past the closing quote.
    const quoted = "run PASSWORD=\"hunter2 topsecretvalue\" next";
    const key_start = std.mem.find(u8, quoted, "PASSWORD").?;
    const closing_quote = std.mem.findScalarLast(u8, quoted, '"').?;
    var start = key_start;
    while (start <= closing_quote) : (start += 1) {
        const masked = try maskSecrets(arena, quoted[secretSafeSuffixStart(quoted, start)..]);
        try std.testing.expect(std.mem.find(u8, masked, "hunter2") == null);
        try std.testing.expect(std.mem.find(u8, masked, "topsecret") == null);
        try std.testing.expect(std.mem.find(u8, masked, "secretvalue") == null);
    }

    // A quoted value can run far past the 1024 bytes a token needs: only the
    // `=` on its line finds it.
    const long_quoted = "run export GCP_SECRET='" ++ repeat("MIIEvQ key part ", 150) ++ "' && gcloud auth; exit 1";
    var long_start: usize = 1100;
    while (long_start < long_quoted.len) : (long_start += 97) {
        const masked = try maskSecrets(arena, long_quoted[secretSafeSuffixStart(long_quoted, long_start)..]);
        try std.testing.expect(std.mem.find(u8, masked, "MIIEvQ") == null);
    }

    // A quoted value can hold more `=` pairs than any candidate cap.
    var capped: std.Io.Writer.Allocating = .init(arena);
    try capped.writer.writeAll("export APP_SECRET=\"");
    for (0..20) |index| try capped.writer.print("x{d}_token=v ", .{index});
    try capped.writer.writeAll(repeat("hidden part of the value ", 70));
    try capped.writer.writeAll("\" && run");
    const capped_value = capped.written();
    long_start = 1100;
    while (long_start < capped_value.len) : (long_start += 61) {
        const masked = try maskSecrets(arena, capped_value[secretSafeSuffixStart(capped_value, long_start)..]);
        try std.testing.expect(std.mem.find(u8, masked, "hidden") == null);
    }

    // A key only the assignment prefix list names, not `sensitiveAssignmentKey`.
    var database: std.Io.Writer.Allocating = .init(arena);
    try database.writer.writeAll("export DATABASE_URL=\"postgres://u:p@h/db?options=dbsecret ");
    try database.writer.writeAll(repeat("part of the value ", 70));
    try database.writer.writeAll("\" && run");
    const database_value = database.written();
    long_start = 1100;
    while (long_start < database_value.len) : (long_start += 61) {
        const masked = try maskSecrets(arena, database_value[secretSafeSuffixStart(database_value, long_start)..]);
        try std.testing.expect(std.mem.find(u8, masked, "dbsecret") == null);
    }
}

test "secretSafeSuffixStart skips many adjacent secrets without a deep stack" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `K` is no sensitive key, so `K="a b"` holds no secret and the rules
    // leave its value alone.
    const plain = "K=\"a b\" ";
    const plain_value = try arena.alloc(u8, plain.len * 20000 + "end".len);
    var index: usize = 0;
    while (index < 20000) : (index += 1) @memcpy(plain_value[index * plain.len ..][0..plain.len], plain);
    @memcpy(plain_value[plain.len * 20000 ..], "end");
    try std.testing.expectEqual(@as(usize, "K=\"".len), secretSafeSuffixStart(plain_value, "K=\"".len));

    // 20000 adjacent secrets, each with a space that stops the run skip, so
    // every step lands on the next one.
    const repeat_text = "PASSWORD=\"a b\" ";
    const value = try arena.alloc(u8, repeat_text.len * 20000 + "end".len);
    index = 0;
    while (index < 20000) : (index += 1) @memcpy(value[index * repeat_text.len ..][0..repeat_text.len], repeat_text);
    @memcpy(value[repeat_text.len * 20000 ..], "end");

    const tail_start = secretSafeSuffixStart(value, "PASSWORD=\"".len);
    // The tail starts at the first value's closing quote: the rules move past
    // the secret the start is inside, not past the whole next one, and every
    // value after it is whole, so `maskSecrets` still finds them.
    try std.testing.expectEqual("PASSWORD=\"a b\"".len - 1, tail_start);
    const masked = try maskSecrets(arena, value[tail_start..]);
    try std.testing.expect(std.mem.find(u8, masked, "a b") == null);
}

test "secretSafeSuffixStart stays cheap on a line of many equals signs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A wall of `=` signs: the matcher is asked about none of them.
    const equals = try arena.alloc(u8, 16000 + " end".len);
    @memset(equals[0..16000], '=');
    @memcpy(equals[16000..], " end");
    var back: usize = 1;
    while (back <= 4) : (back += 1) {
        try std.testing.expect(secretSafeSuffixStart(equals, 16000 - back) <= 16000);
    }

    // 3000 sensitive assignments: the walk jumps past each span, so it stays
    // linear.
    const assignment = "TOKEN=a ";
    const repeated = try arena.alloc(u8, assignment.len * 3000 + "end".len);
    var index: usize = 0;
    while (index < 3000) : (index += 1) @memcpy(repeated[index * assignment.len ..][0..assignment.len], assignment);
    @memcpy(repeated[assignment.len * 3000 ..], "end");
    back = 1;
    while (back <= 4) : (back += 1) {
        _ = secretSafeSuffixStart(repeated, repeated.len - back);
    }
}

test "secretSafePrefixLen and secretSafeSuffixStart leave no part of a planted secret" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const planted = [_]struct {
        secret: []const u8,
        probes: []const []const u8,
    }{
        .{ .secret = "ghp_" ++ repeat("A", 36), .probes = &[_][]const u8{"AAAAAA"} },
        .{ .secret = "sk-proj-" ++ repeat("b", 40), .probes = &[_][]const u8{"bbbbbb"} },
        .{ .secret = "AKIA" ++ repeat("Q", 16), .probes = &[_][]const u8{"QQQQQQ"} },
        .{ .secret = "xoxb-" ++ repeat("1", 30), .probes = &[_][]const u8{"111111"} },
        .{ .secret = "Bearer " ++ repeat("t", 40), .probes = &[_][]const u8{"tttttt"} },
        .{
            .secret = "https://admin:P\u{e4}ss1234@example.com/repo",
            .probes = &[_][]const u8{ "admin:", "ss1234" },
        },
        .{
            .secret = "PASSWORD=\"hunter2 topsecretvalue\"",
            .probes = &[_][]const u8{ "hunter2", "topsecret" },
        },
        .{
            .secret = "GCP_SECRET='" ++ repeat("MIIEvQ key part ", 150) ++ "'",
            .probes = &[_][]const u8{"MIIEvQ"},
        },
        .{
            .secret = "APP_SECRET=\"x0_token=v x1_token=v x2_token=v x3_token=v x4_token=v x5_token=v x6_token=v x7_token=v x8_token=v x9_token=v x10_token=v x11_token=v x12_token=v x13_token=v x14_token=v x15_token=v x16_token=v x17_token=v x18_token=v x19_token=v " ++ repeat("hidden part of the value ", 70) ++ "\"",
            .probes = &[_][]const u8{"hidden"},
        },
        .{
            .secret = "DATABASE_URL=\"postgres://u:p@h/db?options=dbsecret " ++ repeat("part of the value ", 70) ++ "\"",
            .probes = &[_][]const u8{"dbsecret"},
        },
    };

    const filler = [_][]const u8{ "alpha", "run", "42", "{", "\"", ":", ",", " ", "\u{4e2d}", "x" };

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var value_buf: [4 * 1024]u8 = undefined;
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        var len: usize = 0;
        for (0..random.intRangeAtMost(usize, 1, 6)) |_| {
            const word = filler[random.uintLessThan(usize, filler.len)];
            @memcpy(value_buf[len..][0..word.len], word);
            len += word.len;
        }
        const choice = planted[random.uintLessThan(usize, planted.len)];
        @memcpy(value_buf[len..][0..choice.secret.len], choice.secret);
        len += choice.secret.len;
        for (0..random.intRangeAtMost(usize, 1, 6)) |_| {
            const word = filler[random.uintLessThan(usize, filler.len)];
            @memcpy(value_buf[len..][0..word.len], word);
            len += word.len;
        }
        const value = value_buf[0..len];

        // Filler with no space next to the secret glues a preceding letter or
        // digit to it, and `maskSecrets` finds no token there even whole, so
        // only a value it masks says anything about where the cut may fall.
        const masked_value = try maskSecrets(arena, value);
        var maskable = true;
        for (choice.probes) |probe| {
            if (std.mem.find(u8, masked_value, probe) != null) maskable = false;
        }
        if (!maskable) {
            _ = arena_state.reset(.retain_capacity);
            continue;
        }

        const cut = random.intRangeAtMost(usize, 1, value.len - 1);
        const kept = value[0..secretSafePrefixLen(value, cut)];

        var tail = random.intRangeAtMost(usize, 0, value.len);
        while (tail > 0 and tail < value.len and (value[tail] & 0xc0) == 0x80) tail -= 1;
        const rest = value[secretSafeSuffixStart(value, tail)..];

        const masked_kept = try maskSecrets(arena, kept);
        const masked_rest = try maskSecrets(arena, rest);
        for (choice.probes) |probe| {
            try std.testing.expect(std.mem.find(u8, masked_kept, probe) == null);
            try std.testing.expect(std.mem.find(u8, masked_rest, probe) == null);
        }
        _ = arena_state.reset(.retain_capacity);
    }
}

/// Texts with a cut marker, and what `maskSecretsCutShort` makes of each. The
/// tests share them, so the collecting entry point is checked on the same
/// inputs.
const cut_short_cases = [_]struct { text: []const u8, masked: []const u8 }{
    .{
        .text = "sent to keeper · deploy with ghp_AAAAAAAAAAAA...",
        .masked = "sent to keeper · deploy with [redacted]...",
    },
    .{
        .text = "curl -H \"Authorization: Bearer abc...",
        .masked = "curl -H \"Authorization: Bearer [redacted]...",
    },
    // With a longer body the dots join the token, so `maskSecrets` masks
    // it whole, marker and all.
    .{
        .text = "curl -H \"Authorization: Bearer abcdefgh...",
        .masked = "curl -H \"Authorization: [redacted]",
    },
    .{
        .text = "clone https://admin:P\u{e4}ss...",
        .masked = "clone https://[redacted]...",
    },
    .{ .text = "aws AKIA1234\u{2026} done", .masked = "aws [redacted]\u{2026} done" },
    .{
        .text = "key sk-proj-abc... and xoxb-12... end",
        .masked = "key [redacted]... and [redacted]... end",
    },
    .{ .text = "x ghp_AAAA........ y", .masked = "x [redacted]........ y" },
    .{ .text = "and so on...", .masked = "and so on..." },
    .{ .text = "see https://example.com/docs...", .masked = "see https://example.com/docs..." },
    .{ .text = "it costs 3.50...", .masked = "it costs 3.50..." },
    .{ .text = "ghp_ is a prefix", .masked = "ghp_ is a prefix" },
    .{ .text = "wait...", .masked = "wait..." },
    .{ .text = "", .masked = "" },
};

test "maskSecretsCutShort masks a secret a cut marker ends and leaves other text alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (cut_short_cases) |case| {
        try std.testing.expectEqualStrings(case.masked, try maskSecretsCutShort(arena, case.text));
    }

    // A whole secret before a marker is masked by `maskSecrets` already.
    const whole = try maskSecretsCutShort(arena, "t ghp_" ++ repeat("A", 36) ++ "...");
    try std.testing.expect(std.mem.find(u8, whole, "AAAAAA") == null);

    // A long run of dots stays one cut marker, so the scan stays linear.
    const dots = "a " ++ repeat(".", 20000);
    try std.testing.expectEqualStrings(dots, try maskSecretsCutShort(arena, dots));

    // A long line of markers scans back no further than the marker before it.
    const long_a = try arena.alloc(u8, "a...".len * 50000);
    for (long_a, 0..) |*byte, index| byte.* = "a..."[index % "a...".len];
    const masked_a = try maskSecretsCutShort(arena, long_a);
    try std.testing.expect(std.mem.find(u8, masked_a, "[redacted]") == null);

    const long_partial = try arena.alloc(u8, "xsk-...".len * 30000);
    for (long_partial, 0..) |*byte, index| byte.* = "xsk-..."[index % "xsk-...".len];
    _ = try maskSecretsCutShort(arena, long_partial);
}

test "maskSecretsCutShortCollect matches maskSecretsCutShort and collects each whole value in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (cut_short_cases) |case| {
        var values: SecretValues = .{};
        try std.testing.expectEqualStrings(
            try maskSecretsCutShort(arena, case.text),
            try maskSecretsCutShortCollect(arena, case.text, &values),
        );
    }

    const token = "ghp_" ++ repeat("A", 36);
    const assignment = "hunter2hunter2";
    const bearer = "Bearer " ++ repeat("B", 20);
    const text = "push " ++ token ++ " then API_KEY=" ++ assignment ++ " and Authorization: " ++ bearer ++ " done";
    var values: SecretValues = .{};
    const masked = try maskSecretsCutShortCollect(arena, text, &values);
    try std.testing.expectEqualStrings(
        "push [redacted] then API_KEY=[redacted] and Authorization: [redacted] done",
        masked,
    );
    // The Bearer value is kept whole, and so is its token after the prefix.
    try std.testing.expectEqual(@as(usize, 4), values.values.items.len);
    try std.testing.expectEqualStrings(token, values.values.items[0]);
    try std.testing.expectEqualStrings(assignment, values.values.items[1]);
    try std.testing.expectEqualStrings(bearer, values.values.items[2]);
    try std.testing.expectEqualStrings(repeat("B", 20), values.values.items[3]);
}

test "SecretValues keeps a repeated value once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var values: SecretValues = .{};
    try values.put(arena, "ghp_" ++ repeat("A", 36));
    try values.put(arena, "ghp_" ++ repeat("A", 36));
    try std.testing.expectEqual(@as(usize, 1), values.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), values.seen.count());
    try std.testing.expect(!values.overflow);
}

test "SecretValues sets overflow past max_values and keeps no more" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var values: SecretValues = .{};
    for (0..SecretValues.max_values + 1) |index| {
        try values.put(arena, try arena.print("token-{d}", .{index}));
    }
    try std.testing.expect(values.overflow);
    try std.testing.expectEqual(@as(usize, SecretValues.max_values), values.values.items.len);
    try std.testing.expectEqual(@as(usize, SecretValues.max_values), values.seen.count());

    // Once overflowed, a kept value is still a no-op and a new one is not kept.
    try values.put(arena, "token-0");
    try values.put(arena, "token-late");
    try std.testing.expectEqual(@as(usize, SecretValues.max_values), values.values.items.len);
}

test "SecretValues collect puts each secret value of a text in order and none for plain text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token = "ghp_" ++ repeat("A", 36);
    const assignment = "hunter2hunter2";
    const bearer = "Bearer " ++ repeat("B", 20);
    const text = "push " ++ token ++ " then API_KEY=" ++ assignment ++ " and Authorization: " ++ bearer ++ " done";
    var values: SecretValues = .{};
    try values.collect(arena, text);
    try std.testing.expectEqual(@as(usize, 4), values.values.items.len);
    try std.testing.expectEqualStrings(token, values.values.items[0]);
    try std.testing.expectEqualStrings(assignment, values.values.items[1]);
    try std.testing.expectEqualStrings(bearer, values.values.items[2]);
    try std.testing.expectEqualStrings(repeat("B", 20), values.values.items[3]);

    var none: SecretValues = .{};
    try none.collect(arena, "ordinary words, and a token mention without a value");
    try std.testing.expectEqual(@as(usize, 0), none.values.items.len);
}

/// `maskSecretPieces` with a full compare budget, for tests that do not test the budget.
fn maskPieces(arena: std.mem.Allocator, row: []const u8, values: []const []const u8) ![]const u8 {
    var budget: usize = max_piece_compare_bytes;
    return maskSecretPieces(arena, row, values, &budget);
}

/// Expects `maskSecretPieces` to turn `row` into `expected` for `values`.
fn expectSecretPieces(expected: []const u8, row: []const u8, values: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(expected, try maskPieces(arena_state.allocator(), row, values));
}

test "maskSecretPieces returns the row itself when no value is known" {
    const token = "ghp_" ++ repeat("A", 40);
    const row: []const u8 = "  ghp_AAAAAAAAAAAA";
    const unchanged = try maskPieces(std.testing.allocator, row, &[_][]const u8{});
    try std.testing.expect(unchanged.ptr == row.ptr);

    const empty: []const u8 = "";
    const empty_out = try maskPieces(std.testing.allocator, empty, &[_][]const u8{token});
    try std.testing.expect(empty_out.ptr == empty.ptr);
}

test "maskSecretPieces masks a row end that starts a value and keeps the text before it" {
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    try expectSecretPieces("token: [redacted]", "token: " ++ "ghp_" ++ repeat("A", 8), &values);
    // The longest end that starts a value is masked; the `x` before it stays.
    try expectSecretPieces("token: x[redacted]", "token: xghp_" ++ repeat("A", 8), &values);
}

test "maskSecretPieces masks a value's tail after a gutter and keeps the words after it" {
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    try expectSecretPieces("  [redacted] here.", "  " ++ repeat("A", 10) ++ " here.", &values);
}

test "maskSecretPieces masks a row that is a whole middle piece of a value" {
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    try expectSecretPieces("[redacted]", repeat("A", 20), &values);
}

test "maskSecretPieces masks pieces across table rows with box-drawing and ASCII borders" {
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    // The first row holds the value's start, and the next row a middle piece.
    try expectSecretPieces("│ [redacted]   │", "│ ghp_" ++ repeat("A", 8) ++ "   │", &values);
    try expectSecretPieces("│ [redacted]  │", "│ " ++ repeat("A", 20) ++ "  │", &values);
    try expectSecretPieces("| [redacted]   |", "| ghp_" ++ repeat("A", 8) ++ "   |", &values);
    try expectSecretPieces("| [redacted]  |", "| " ++ repeat("A", 20) ++ "  |", &values);
}

test "maskSecretPieces leaves ordinary words alone while a value is present" {
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    const row: []const u8 = "the quick brown fox jumps over the lazy dog";
    const out = try maskPieces(std.testing.allocator, row, &values);
    try std.testing.expect(out.ptr == row.ptr);
}

test "maskSecretPieces leaves one- and two-byte pieces alone and masks three-byte and four-byte ones" {
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    // A lone run under three bytes occurs in too many words to be a piece of a
    // secret, so the row keeps it. A three-byte lone run is a piece in a narrow
    // cell, and a start or end piece needs four bytes.
    try expectSecretPieces("token g", "token g", &values);
    try expectSecretPieces("  AA", "  AA", &values);
    try expectSecretPieces("   [redacted]", "   AAA", &values);
    try expectSecretPieces("  [redacted]", "  AAAA", &values);
}

test "maskSecretPieces masks a piece glued to a period" {
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    try expectSecretPieces("  [redacted].", "  " ++ repeat("A", 10) ++ ".", &values);
}

test "maskSecretPieces keeps the Bearer prefix and masks the token after it" {
    // `SecretValues` keeps the token after `Bearer ` as a value of its own, so a
    // row that wraps at the space shows the token alone. The prefix is public.
    const values = [_][]const u8{ "Bearer " ++ repeat("A", 20), repeat("A", 20) };
    try expectSecretPieces("Authorization: Bearer", "Authorization: Bearer", &values);
    try expectSecretPieces("[redacted]", repeat("A", 20), &values);
}

test "maskSecretPieces keeps non-ASCII bytes and stays valid UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    const out = try maskPieces(arena_state.allocator(), "日本語 ghp_AAAAAAAA字", &values);
    try std.testing.expectEqualStrings("日本語 [redacted]字", out);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "maskSecretPieces leaves a whole value in the middle of a segment to maskSecrets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token = "ghp_" ++ repeat("A", 40);
    const values = [_][]const u8{token};
    const row: []const u8 = "x " ++ token ++ " y";
    const pieces = try maskPieces(arena, row, &values);
    try std.testing.expect(pieces.ptr == row.ptr);
    try std.testing.expectEqualStrings("x [redacted] y", try maskSecretsCutShort(arena, row));
}

/// Values shaped like real keys and tokens. The piece tests use them, not
/// repeated letters, so that a short overlap is a real overlap with prose.
const realistic_sk_key = "sk-" ++ "Q7xk2Pz9LmR4vT1nB8cD" ++ "wE3fG6hJ0kS5";
const realistic_github_pat = "github_pat_" ++ "11ABCDEFG0hIjKlMnOpQrS_tUvWxYz0123456789abcdef";
const realistic_ghp = "ghp_" ++ "x9Q2mN7pL4kR8sT1vW3yZ6aB5cD0eF2gH4jK";
/// A token that holds `42` and `ok`, so a short cell or row of either is a piece of it.
const realistic_cell_token = "gho_42ok9Qw2Er7Ty3Ui5Op8As";

test "maskSecretPieces leaves ordinary words, short cells, and short rows alone beside realistic tokens" {
    const values = [_][]const u8{ realistic_sk_key, realistic_github_pat, realistic_ghp, realistic_cell_token };
    try expectSecretPieces("  run the task", "  run the task", &values);
    try expectSecretPieces("  see git", "  see git", &values);
    try expectSecretPieces("  open github", "  open github", &values);
    try expectSecretPieces("  through", "  through", &values);
    try expectSecretPieces("│ github │", "│ github │", &values);
    try expectSecretPieces("│ 42 │", "│ 42 │", &values);
    try expectSecretPieces("  ok", "  ok", &values);
}

test "maskSecretPieces masks a realistic token's four-byte end piece and keeps its three-byte one" {
    const values = [_][]const u8{realistic_ghp};
    try expectSecretPieces("  [redacted] here.", "  H4jK here.", &values);
    try expectSecretPieces("  4jK here.", "  4jK here.", &values);
}

test "maskSecretPieces masks a start piece only past the value's public prefix" {
    const values = [_][]const u8{realistic_ghp};
    try expectSecretPieces("  ghp_", "  ghp_", &values);
    try expectSecretPieces("  [redacted]", "  ghp_x9Q2", &values);
}

test "maskSecretPieces masks an eight-byte middle piece of a token's random part in a narrow cell" {
    // The random part starts after the public prefix `github_pat_`. This piece
    // starts 20 bytes into the random part and is shorter than the prefix, yet
    // it runs past the prefix, so it is a piece of the token.
    const values = [_][]const u8{realistic_github_pat};
    try expectSecretPieces(
        "  │      │ [redacted] │",
        "  │      │ " ++ realistic_github_pat["github_pat_".len + 20 ..][0..8] ++ " │",
        &values,
    );
}

test "maskSecretPieces masks a four-byte middle piece of a token's random part in a narrow cell" {
    const values = [_][]const u8{realistic_github_pat};
    try expectSecretPieces(
        "  │      │ [redacted] │",
        "  │      │ " ++ realistic_github_pat["github_pat_".len + 20 ..][0..4] ++ " │",
        &values,
    );
}

test "maskSecretPieces keeps a lone run that lies wholly inside the public prefix" {
    const values = [_][]const u8{realistic_github_pat};
    try expectSecretPieces("│ github │", "│ github │", &values);
    try expectSecretPieces("│ github_p │", "│ github_p │", &values);
}

test "maskSecretPieces masks a lone run that starts inside the public prefix and runs past it" {
    const values = [_][]const u8{realistic_github_pat};
    try expectSecretPieces("│ [redacted] │", "│ pat_11AB │", &values);
}

test "maskSecretPieces masks every three-byte slice of a token past its prefix in a narrow table cell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A 42-byte token. A table column can shrink to three cells, so one row of
    // its cell can hold any three bytes of the token.
    const token = "ghp_" ++ "x9Q2mN7pL4kR8sT1vW3yZ6aB5cD0eF2gH4jKLm";
    comptime std.debug.assert(token.len == 42);
    const values = [_][]const u8{token};
    for (0..token.len - 2) |start| {
        const row = try arena.print("  │ {s} │ some │", .{token[start..][0..3]});
        // A slice that lies wholly inside the public prefix `ghp_` is common text.
        const expected: []const u8 = if (start < 2) row else "  │ [redacted] │ some │";
        try expectSecretPieces(expected, row, &values);
    }
}

test "SecretValues keeps no bare Bearer word as a value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var values: SecretValues = .{};
    // The assignment's value is the word `Bearer`, which is not a token.
    try values.collect(arena, "TOKEN=Bearer xoxb-77Hh");
    for (values.values.items) |value| try std.testing.expect(!std.mem.eql(u8, value, "Bearer"));
    const before = values.values.items.len;
    try values.put(arena, "Bearer");
    try std.testing.expectEqual(before, values.values.items.len);
}

test "maskSecretPieces masks a bearer token that a wrap splits, once collected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var values: SecretValues = .{};
    try values.collect(arena, "Authorization: Bearer Q7xk2Pz9LmR4vT1nB8cDwE3f");
    try std.testing.expectEqualStrings(
        "  Authorization: Bearer [redacted]",
        try maskPieces(arena, "  Authorization: Bearer Q7xk2Pz9", values.values.items),
    );
}

test "SecretValues never keeps the redaction marker as a secret value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var values: SecretValues = .{};
    try values.collect(arena, "API_KEY=[redacted]");
    try values.put(arena, "[redacted]");
    try std.testing.expectEqual(@as(usize, 0), values.values.items.len);
}

test "SecretValues keeps the part of a Bearer value after its prefix as a value of its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token = repeat("B", 20);
    var values: SecretValues = .{};
    try values.put(arena, "Bearer " ++ token);
    try std.testing.expectEqual(@as(usize, 2), values.values.items.len);
    try std.testing.expectEqualStrings("Bearer " ++ token, values.values.items[0]);
    try std.testing.expectEqualStrings(token, values.values.items[1]);
}

test "SecretValues counts the Bearer token toward max_values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var values: SecretValues = .{};
    for (0..SecretValues.max_values - 1) |index| {
        try values.put(arena, try arena.print("token-{d}", .{index}));
    }
    try values.put(arena, "Bearer " ++ repeat("B", 20));
    // The Bearer value fills the last slot, so its token is the 1025th distinct value.
    try std.testing.expect(values.overflow);
    try std.testing.expectEqual(@as(usize, SecretValues.max_values), values.values.items.len);
}

test "maskSecretPieces stops with an error once its compare budget is spent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const values = [_][]const u8{"ghp_" ++ repeat("A", 40)};
    var budget: usize = 8;
    // The first run is compared with the value's tail, which costs more than 8 bytes.
    try std.testing.expectError(
        error.SecretPieceBudgetSpent,
        maskSecretPieces(arena_state.allocator(), "  " ++ repeat("A", 20) ++ "  Q9", &values, &budget),
    );
}

test "maskSecretPieces charges the compare budget for the bytes it compares" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const values = [_][]const u8{realistic_ghp};
    var budget: usize = max_piece_compare_bytes;
    _ = try maskSecretPieces(arena_state.allocator(), "word", &values, &budget);
    // "word" is a lone run, so it is compared at each of the 36 positions past
    // the 4-byte public prefix `ghp_`. None of them shares a byte with it, so
    // each costs one byte. Its end-piece comparison with the value's last four
    // bytes costs one more: 37 bytes in all.
    try std.testing.expectEqual(max_piece_compare_bytes - 37, budget);
}

/// One fuzz input's bytes, read in order. A read past the end gives zero, so an
/// input of any length decides the whole fuzz test.
const PieceFuzzInput = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(self: *PieceFuzzInput) u8 {
        if (self.at == self.bytes.len) return 0;
        self.at += 1;
        return self.bytes[self.at - 1];
    }

    /// The next byte, taken modulo `len`, which must be at least 1.
    fn pick(self: *PieceFuzzInput, len: usize) usize {
        return @as(usize, self.next()) % len;
    }

    fn fill(self: *PieceFuzzInput, out: []u8) void {
        for (out) |*byte| byte.* = self.next();
    }
};

/// Room for one fuzz input: four values of up to 64 bytes, a row of up to 256,
/// and a wrapped value of up to 80, with their choices.
const piece_input_capacity = 1024;
/// Room for every allocation that one fuzz input makes.
const piece_arena_bytes = 64 * 1024;
/// The gutters, words, and tails that a wrapped value is laid out with.
const piece_gutters = [_][]const u8{ "", "  ", "  │ ", "│ ", "| " };
const piece_words = [_][]const u8{ "", "see " };
const piece_tails = [_][]const u8{ " here.", " │", "" };
/// The bytes a wrapped value is built from. Each is a secret-run byte.
const piece_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

/// Checks `maskSecretPieces` on a fuzzed row and values, then on one fuzzed
/// value that a wrap has split across rows. The input is read in this order:
/// the number of values (up to 4), then each value's length (up to 64) and
/// bytes; the row's length (up to 256) and bytes; the wrapped value's gutter,
/// word, length (8 to 80), and bytes; its split, which leaves a start piece and
/// an end piece of at least `min_secret_piece_bytes` each, a flag and a choice
/// for a middle piece, its tail, and the gutters of the next two rows. The
/// budget is large, so the fuzzed inputs never spend it.
fn fuzzMaskSecretPieces(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [piece_input_capacity]u8 = undefined;
    var input: PieceFuzzInput = .{ .bytes = input_buf[0..smith.slice(&input_buf)] };
    var storage: [piece_arena_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&storage);
    const arena = fba.allocator();

    // Any row and values: no error, valid UTF-8 stays valid, and the bytes at
    // or above 0x80 keep their order.
    var value_bufs: [4][64]u8 = undefined;
    var values: [4][]const u8 = undefined;
    const value_count = input.pick(5);
    for (0..value_count) |index| {
        const len = input.pick(65);
        input.fill(value_bufs[index][0..len]);
        values[index] = value_bufs[index][0..len];
    }
    var row_buf: [256]u8 = undefined;
    const row_len = input.pick(257);
    input.fill(row_buf[0..row_len]);
    const row = row_buf[0..row_len];
    const row_out = try maskPieces(arena, row, values[0..value_count]);
    if (std.unicode.utf8ValidateSlice(row)) try std.testing.expect(std.unicode.utf8ValidateSlice(row_out));
    try expectSameHighBytes(row, row_out);

    // One value, split into a start piece and an end piece of at least four
    // bytes (`min_secret_piece_bytes`), and a middle piece when it splits in
    // three. The start piece ends
    // its row, the end piece starts the next, and the middle piece stands alone,
    // so the masked row must show the marker where each piece was.
    const gutter = piece_gutters[input.pick(piece_gutters.len)];
    const word = piece_words[input.pick(piece_words.len)];
    const value_len = 2 * min_secret_piece_bytes + input.pick(81 - 2 * min_secret_piece_bytes);
    var value_buf: [80]u8 = undefined;
    for (value_buf[0..value_len]) |*byte| byte.* = piece_alphabet[input.pick(piece_alphabet.len)];
    const value = value_buf[0..value_len];
    const split = min_secret_piece_bytes + input.pick(value_len - 2 * min_secret_piece_bytes + 1);
    const three = input.pick(2) == 1 and split + 2 * min_secret_piece_bytes <= value_len;
    const split_end = if (three)
        split + min_secret_piece_bytes + input.pick(value_len - split - 2 * min_secret_piece_bytes + 1)
    else
        split;
    const tail = piece_tails[input.pick(piece_tails.len)];
    const gutter_after = piece_gutters[input.pick(piece_gutters.len)];
    const gutter_middle = piece_gutters[input.pick(piece_gutters.len)];
    const one: []const []const u8 = &.{value};

    const start_row = try std.mem.concat(arena, u8, &.{ gutter, word, value[0..split] });
    const start_out = try maskPieces(arena, start_row, one);
    // A start piece is masked once it is longer than the value's public prefix.
    if (split > publicPrefixLen(value)) try std.testing.expect(std.mem.endsWith(u8, start_out, "[redacted]"));

    const end_row = try std.mem.concat(arena, u8, &.{ gutter_after, value[split_end..], tail });
    const end_out = try maskPieces(arena, end_row, one);
    try std.testing.expectEqualStrings(
        try std.mem.concat(arena, u8, &.{ gutter_after, "[redacted]", tail }),
        end_out,
    );

    // A middle piece sits at `split` in the value, so it is masked whole once it
    // runs past the public prefix, that is once `split_end` is past the prefix.
    if (three and split_end > publicPrefixLen(value)) {
        const middle_row = try std.mem.concat(arena, u8, &.{ gutter_middle, value[split..split_end] });
        const middle_out = try maskPieces(arena, middle_row, one);
        try std.testing.expectEqualStrings(
            try std.mem.concat(arena, u8, &.{ gutter_middle, "[redacted]" }),
            middle_out,
        );
    }
}

/// Expects the bytes of `row` at or above 0x80 to be the bytes of `out` at or
/// above 0x80, in the same order: masking never drops or moves a non-ASCII byte.
fn expectSameHighBytes(row: []const u8, out: []const u8) !void {
    var row_at: usize = 0;
    var out_at: usize = 0;
    while (true) {
        const want = nextHighByte(row, &row_at);
        try std.testing.expectEqual(want, nextHighByte(out, &out_at));
        if (want == null) return;
    }
}

/// The next byte at or above 0x80 in `bytes` from `at`, moving `at` past it.
fn nextHighByte(bytes: []const u8, at: *usize) ?u8 {
    while (at.* < bytes.len) : (at.* += 1) {
        if (bytes[at.*] >= 0x80) {
            at.* += 1;
            return bytes[at.* - 1];
        }
    }
    return null;
}

/// An inline seed for the fuzz test: a row with a `ghp_` value, then a 34-byte
/// value (of `q`s) that splits in three. Its length byte, 26, reads as a value of
/// 8 + 26 = 34 bytes. Its first row has gutter `gutter`, its words `word`, and its
/// tail `tail`.
fn pieceSeed(comptime gutter: u8, comptime word: u8, comptime tail: u8) []const u8 {
    return "\x01\x04ghp_" ++ "\x0ax ghp_AAAA" ++
        &[_]u8{ gutter, word, 26 } ++
        repeat("\x2a", 34) ++
        &[_]u8{ 5, 1, 3, tail, (gutter + 1) % 5, (gutter + 2) % 5 };
}

test "maskSecretPieces masks every piece of a wrapped value and keeps other bytes on fuzzed rows" {
    try std.testing.fuzz({}, fuzzMaskSecretPieces, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            pieceSeed(0, 0, 0),
            pieceSeed(1, 1, 1),
            pieceSeed(2, 0, 2),
            pieceSeed(3, 1, 0),
            pieceSeed(4, 0, 1),
        }) ++ @import("fuzz_corpus").secret_pieces.*),
    });
}

test "redactUrlForDisplay masks credential-like query values" {
    const alloc = std.testing.allocator;
    const redacted = try redactUrlForDisplay(
        alloc,
        "https://user:pass@example.com/docs?safe=ok&token=abc123&X-Amz-%43redential=credential-value&X-Amz-Signature=signature-value",
    );
    defer alloc.free(redacted);

    try std.testing.expectEqualStrings(
        "https://[redacted]@example.com/docs?safe=ok&token=[redacted]&X-Amz-%43redential=[redacted]&X-Amz-Signature=[redacted]",
        redacted,
    );
}

test "redactUrlForDisplay preserves benign keys containing sig" {
    const alloc = std.testing.allocator;
    const redacted = try redactUrlForDisplay(alloc, "https://example.com/docs?design=blue&sig=secret");
    defer alloc.free(redacted);

    try std.testing.expectEqualStrings("https://example.com/docs?design=blue&sig=[redacted]", redacted);
}

test "sanitizeAssistantText strips first-line assistant intro" {
    const cleaned = sanitizeAssistantText(" \tI'm Fx, your local coding assistant.\n\n  Here is the answer.\n");
    try std.testing.expectEqualStrings("Here is the answer.", cleaned);

    const unchanged = sanitizeAssistantText("I'm Fx, your local coding assistant.");
    try std.testing.expectEqualStrings("I'm Fx, your local coding assistant.", unchanged);
}

test "clippedLabel clips by display width with an ellipsis" {
    var buf: [16]u8 = undefined;

    const label = clippedLabel(&buf, "ab\xf0\x9f\x98\x80cd", 5);
    try std.testing.expectEqualStrings("ab...", label);

    const fits = clippedLabel(&buf, "short", 5);
    try std.testing.expectEqualStrings("short", fits);
}

test "encodeTerminalSafe visibly escapes controls line breaks and invalid UTF-8" {
    const raw = "A\x1b[31m\n\r\x07\x7fB\xff";
    var encoded = try encodeTerminalSafe(std.testing.allocator, raw, 128);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "A\\x1b[31m\\x0a\\x0d\\x07\\x7fB\\xff",
        encoded.bytes,
    );
    try std.testing.expect(std.mem.findScalar(u8, encoded.bytes, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, encoded.bytes, '\n') == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded.bytes));
    try std.testing.expect(!encoded.truncated);
}

test "encodeTerminalSafeInline flattens whitespace runs and trims the ends" {
    const raw = "  {\n  \"success\": false,\r\n\t\"info\": \"nope\"}\n";
    var encoded = try encodeTerminalSafeInline(std.testing.allocator, raw, 256);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "{ \"success\": false, \"info\": \"nope\"}",
        encoded.bytes,
    );
    try std.testing.expect(!encoded.truncated);
}

test "encodeTerminalSafeInline still escapes dangerous controls and invalid UTF-8" {
    const raw = "a\x1b[31m\nb\x07\xff";
    var encoded = try encodeTerminalSafeInline(std.testing.allocator, raw, 256);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a\\x1b[31m b\\x07\\xff", encoded.bytes);
    try std.testing.expect(std.mem.findScalar(u8, encoded.bytes, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, encoded.bytes, '\n') == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded.bytes));
}

test "encodeTerminalSafeInline collapses whitespace-only input to empty" {
    var encoded = try encodeTerminalSafeInline(std.testing.allocator, " \n\t\r\n ", 256);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("", encoded.bytes);
    try std.testing.expect(!encoded.truncated);
}

test "encodeTerminalSafeInline applies the byte budget after flattening" {
    var encoded = try encodeTerminalSafeInline(std.testing.allocator, "one  two\nthree", 8);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("one t...", encoded.bytes);
    try std.testing.expect(encoded.truncated);
}

test "isTerminalSafe matches byte-preserving terminal encoding" {
    const cases = [_][]const u8{
        "src/main.zig",
        "Ärger-file.txt",
        "emoji-😀.txt",
        "escape-\x1b[2J.txt",
        "line\nbreak",
        "c1-\u{0080}",
        "invalid-\xff",
    };

    for (cases) |raw| {
        var encoded = try encodeTerminalSafe(std.testing.allocator, raw, std.math.maxInt(usize));
        defer encoded.deinit(std.testing.allocator);
        try std.testing.expectEqual(
            std.mem.eql(u8, raw, encoded.bytes),
            isTerminalSafe(raw),
        );
    }
}

test "incremental terminal-safe encoding matches the whole-slice policy at every split" {
    const raw = "head\xf0\x9f\x98\x80\x1b[31m\n\xc2\x80\xfftail";
    var expected = try encodeTerminalSafe(std.testing.allocator, raw, std.math.maxInt(usize));
    defer expected.deinit(std.testing.allocator);

    for (0..raw.len + 1) |split| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var encoder = IncrementalTerminalSafeEncoder{};
        try encoder.append(&out.writer, raw[0..split]);
        try encoder.append(&out.writer, raw[split..]);
        try encoder.finish(&out.writer);
        try std.testing.expectEqualStrings(expected.bytes, out.written());
        try std.testing.expect(std.mem.findScalar(u8, out.written(), 0x1b) == null);
    }
}

test "incremental UTF-8 validation handles split sequences and rejects invalid input" {
    var valid: IncrementalUtf8Validator = .{};
    try valid.append(&.{ 'a', 0xe2 });
    try valid.append(&.{0x82});
    try valid.append(&.{ 0xac, '\n' });
    try valid.finish();

    var invalid: IncrementalUtf8Validator = .{};
    try std.testing.expectError(error.InvalidUtf8, invalid.append(&.{0x80}));

    var incomplete: IncrementalUtf8Validator = .{};
    try incomplete.append(&.{ 0xe2, 0x82 });
    try std.testing.expectError(error.InvalidUtf8, incomplete.finish());
}

test "encodeTerminalSafe makes every byte value terminal-safe UTF-8" {
    var raw: [256]u8 = undefined;
    for (&raw, 0..) |*byte, value| byte.* = @intCast(value);

    var encoded = try encodeTerminalSafe(std.testing.allocator, &raw, 2048);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded.bytes));
    for (encoded.bytes) |byte| {
        try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    }
    try std.testing.expect(std.mem.findScalar(u8, encoded.bytes, 0x1b) == null);
    try std.testing.expect(!encoded.truncated);
}

test "encodeTerminalSafe escapes UTF-8 C1 controls" {
    var encoded = try encodeTerminalSafe(std.testing.allocator, "\u{0080}", 64);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\\u{0080}", encoded.bytes);
    try std.testing.expectEqual(@as(usize, 8), display_width.visibleWidth(encoded.bytes));
}

test "encodeTerminalSafe reserves a marker when source encoding is truncated" {
    var encoded = try encodeTerminalSafe(std.testing.allocator, "abcdef", 5);
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ab...", encoded.bytes);
    try std.testing.expectEqual(@as(usize, 5), display_width.visibleWidth(encoded.bytes));
    try std.testing.expect(encoded.truncated);
}

test "encodeTerminalSafePathTail preserves a complete basename from a long source" {
    const prefix = try std.testing.allocator.alloc(u8, 5 * 1024);
    defer std.testing.allocator.free(prefix);
    @memset(prefix, 'a');
    const raw = try std.testing.allocator.print(
        "/{s}/note.txt",
        .{prefix},
    );
    defer std.testing.allocator.free(raw);

    var encoded = try encodeTerminalSafePathTail(
        std.testing.allocator,
        raw,
        64,
    );
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expect(encoded.source_truncated);
    try std.testing.expect(std.mem.startsWith(u8, encoded.bytes, "…"));
    try std.testing.expectEqualStrings(
        "note.txt",
        encoded.bytes[encoded.basename_start..],
    );
    try std.testing.expect(encoded.bytes.len <= 64);
}

test "encodeTerminalSafePathTail fills the exact retained capacity on token boundaries" {
    var encoded = try encodeTerminalSafePathTail(
        std.testing.allocator,
        "/abcdef/note.txt",
        "…".len + "def/note.txt".len,
    );
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        "…".len + "def/note.txt".len,
        encoded.bytes.len,
    );
    try std.testing.expectEqualStrings("…def/note.txt", encoded.bytes);
    try std.testing.expectEqualStrings(
        "note.txt",
        encoded.bytes[encoded.basename_start..],
    );
}

test "encodeTerminalSafePathTail rejects an unrepresentable basename" {
    try std.testing.expectError(
        error.PathBasenameTooLong,
        encodeTerminalSafePathTail(
            std.testing.allocator,
            "/dir/very-long-name.txt",
            8,
        ),
    );
}

test "encodeTerminalSafePathTail accepts exact retained maximum and rejects one over" {
    const exact = try std.testing.allocator.alloc(
        u8,
        4 * 1024,
    );
    defer std.testing.allocator.free(exact);
    @memset(exact, 'x');
    var encoded = try encodeTerminalSafePathTail(
        std.testing.allocator,
        exact,
        4 * 1024,
    );
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4 * 1024), encoded.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), encoded.basename_start);
    try std.testing.expect(!encoded.source_truncated);

    const over = try std.testing.allocator.alloc(
        u8,
        4 * 1024 + 1,
    );
    defer std.testing.allocator.free(over);
    @memset(over, 'y');
    try std.testing.expectError(
        error.PathBasenameTooLong,
        encodeTerminalSafePathTail(
            std.testing.allocator,
            over,
            4 * 1024,
        ),
    );
}

test "encodeTerminalSafePathTail keeps hostile UTF-8 and escape tokens whole" {
    var encoded = try encodeTerminalSafePathTail(
        std.testing.allocator,
        "/prefix/\x1b\xf0\x28\x8c\x28.txt",
        24,
    );
    defer encoded.deinit(std.testing.allocator);

    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded.bytes));
    try std.testing.expect(std.mem.findScalar(u8, encoded.bytes, 0x1b) == null);
    try std.testing.expect(
        std.mem.find(u8, encoded.bytes, "\\x1b") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, encoded.bytes, "\\xf0") != null,
    );
    try std.testing.expectEqualStrings(
        "\\x1b\\xf0(\\x8c(.txt",
        encoded.bytes[encoded.basename_start..],
    );
}

test "suffixTerminalSafeByWidth preserves escape and UTF-8 token boundaries" {
    try std.testing.expectEqualStrings(
        "/name.txt",
        suffixTerminalSafeByWidth(
            "prefix/\\x1b/name.txt",
            "/name.txt".len,
        ),
    );
    try std.testing.expectEqualStrings(
        "\\u{0080}/name",
        suffixTerminalSafeByWidth(
            "prefix/\\u{0080}/name",
            "\\u{0080}/name".len,
        ),
    );
    try std.testing.expectEqualStrings(
        "😀/x",
        suffixTerminalSafeByWidth(
            "prefix/😀/x",
            4,
        ),
    );
}

test "prefixTerminalSafeByWidth preserves escape and UTF-8 token boundaries" {
    try std.testing.expectEqualStrings(
        "prefix/\\x1b",
        prefixTerminalSafeByWidth("prefix/\\x1b/name.txt", 11),
    );
    try std.testing.expectEqualStrings(
        "\\u{0080}",
        prefixTerminalSafeByWidth("\\u{0080}/name", 8),
    );
    try std.testing.expectEqualStrings(
        "😀/x",
        prefixTerminalSafeByWidth("😀/xyz", 4),
    );
}

test "utf8PrefixByBytes keeps complete codepoints" {
    const text = "ab\xc3\xa9z";
    try std.testing.expectEqualStrings("", utf8PrefixByBytes(text, 0));
    try std.testing.expectEqualStrings("ab", utf8PrefixByBytes(text, 3));
    try std.testing.expectEqualStrings("ab\xc3\xa9", utf8PrefixByBytes(text, 4));
    try std.testing.expectEqualStrings(text, utf8PrefixByBytes(text, text.len));
}

test "normalizeLineEndingsInPlace compacts crlf and normalizes lone cr" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "", .expected = "" },
        .{ .input = "alpha\nbeta", .expected = "alpha\nbeta" },
        .{ .input = "alpha\r\nbeta", .expected = "alpha\nbeta" },
        .{ .input = "alpha\rbeta", .expected = "alpha\nbeta" },
        .{ .input = "\r\n\r\n", .expected = "\n\n" },
        .{ .input = "\r\r\n\n", .expected = "\n\n\n" },
        .{ .input = "é\r\n🙂\r尾", .expected = "é\n🙂\n尾" },
    };

    for (cases) |case| {
        var storage: [64]u8 = undefined;
        @memcpy(storage[0..case.input.len], case.input);
        const normalized = normalizeLineEndingsInPlace(storage[0..case.input.len]);
        try std.testing.expectEqualStrings(case.expected, normalized);
    }
}

test "utf8BackwardBoundary snaps to the codepoint start" {
    const text = "ab\xc3\xa9z";
    try std.testing.expectEqual(@as(usize, 0), utf8BackwardBoundary(text, 0));
    try std.testing.expectEqual(@as(usize, 2), utf8BackwardBoundary(text, 2));
    try std.testing.expectEqual(@as(usize, 2), utf8BackwardBoundary(text, 3));
    try std.testing.expectEqual(@as(usize, 4), utf8BackwardBoundary(text, 4));
    try std.testing.expectEqual(@as(usize, text.len), utf8BackwardBoundary(text, text.len + 3));
}

test "utf8ForwardBoundary snaps past the codepoint tail" {
    const text = "ab\xc3\xa9z";
    try std.testing.expectEqual(@as(usize, 0), utf8ForwardBoundary(text, 0));
    try std.testing.expectEqual(@as(usize, 2), utf8ForwardBoundary(text, 2));
    try std.testing.expectEqual(@as(usize, 4), utf8ForwardBoundary(text, 3));
    try std.testing.expectEqual(@as(usize, 4), utf8ForwardBoundary(text, 4));
    try std.testing.expectEqual(@as(usize, text.len), utf8ForwardBoundary(text, text.len + 3));
}

test "appendTerminalSafeLine keeps tabs and shows a file's control sequences as text" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try appendTerminalSafeLine(alloc, &out, "a\tb\x1b[2J\x1b[Hc\u{9b}31md\xffe\r");
    try std.testing.expectEqualStrings("a\tb\\x1b[2J\\x1b[Hc\\u{009b}31md\\xffe", out.items);

    // Only a trailing carriage return ends a line; one inside it would return
    // to the start of the row and draw over its gutter.
    out.clearRetainingCapacity();
    try appendTerminalSafeLine(alloc, &out, "good\rbad\r");
    try std.testing.expectEqualStrings("good\\x0dbad", out.items);
}

test "dupeValidUtf8 escapes only bytes outside valid sequences" {
    const alloc = std.testing.allocator;
    const kept = try dupeValidUtf8(alloc, "tab\tesc\x1b ok ⋯");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("tab\tesc\x1b ok ⋯", kept);

    // A truncated sequence and an encoded surrogate are invalid byte by byte,
    // as `encodeTerminalSafe` sees them.
    const fixed = try dupeValidUtf8(alloc, "a\xff\xfe\x00\xc3(b\xed\xa0\x80");
    defer alloc.free(fixed);
    try std.testing.expectEqualStrings("a\\xff\\xfe\x00\\xc3(b\\xed\\xa0\\x80", fixed);
    try std.testing.expect(std.unicode.utf8ValidateSlice(fixed));
}
