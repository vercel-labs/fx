const std = @import("std");
const debug_trace = @import("debug_trace.zig");
const display_width = @import("display_width.zig");

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    const last_start = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= last_start) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
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
            std.mem.copyForwards(
                u8,
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
            _ = std.unicode.utf8Decode(self.pending[0..sequence_len]) catch return error.InvalidUtf8;
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
            _ = std.unicode.utf8Decode(bytes[index .. index + sequence_len]) catch return error.InvalidUtf8;
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
    const basename = std.fs.path.basename(raw);
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
    return std.fmt.allocPrint(arena, "binary or non-utf8 tool output omitted ({d} bytes)", .{text.len});
}

pub fn maskSecrets(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var modified = false;
    var i: usize = 0;
    while (i < text.len) {
        if (findSecretSpan(text, i)) |span| {
            modified = true;
            try out.writer.writeAll(text[i..span.prefix_end]);
            try out.writer.writeAll("[redacted]");
            debug_trace.logf("core", "model-facing secret redacted kind={s} bytes={d}", .{ span.kind, span.value_len });
            i = span.prefix_end + span.value_len;
        } else {
            try out.writer.writeByte(text[i]);
            i += 1;
        }
    }
    if (!modified) return text;
    return try out.toOwnedSlice();
}

/// Returns true when a secret candidate begins before the retained suffix and
/// cannot be classified until later bytes arrive on the same logical line.
pub fn secretMayCrossBoundary(text: []const u8, retained_suffix_bytes: usize) bool {
    const retained_start = text.len -| retained_suffix_bytes;

    var assignment_end = text.len;
    if (assignment_end > 0 and
        (text[assignment_end - 1] == '"' or text[assignment_end - 1] == '\''))
    {
        assignment_end -= 1;
    }
    if (assignment_end > 0 and text[assignment_end - 1] == '=') {
        const key_end = assignment_end - 1;
        var unfinished_key_start = key_end;
        while (unfinished_key_start > 0 and
            isAssignmentKeyChar(text[unfinished_key_start - 1]))
        {
            unfinished_key_start -= 1;
        }
        if (unfinished_key_start < retained_start and
            sensitiveAssignmentKey(text[unfinished_key_start..key_end]))
        {
            return true;
        }
    }

    var key_start = text.len;
    while (key_start > 0 and isAssignmentKeyChar(text[key_start - 1])) {
        key_start -= 1;
    }
    if (key_start < retained_start and
        sensitiveAssignmentKey(text[key_start..]))
    {
        return true;
    }

    const prefix = "https://";
    var search_start: usize = 0;
    while (std.mem.findPos(u8, text, search_start, prefix)) |url_start| {
        const credential_start = url_start + prefix.len;
        var end = credential_start;
        while (end < text.len and
            text[end] != '\n' and
            text[end] != '\r' and
            !std.ascii.isWhitespace(text[end])) : (end += 1)
        {
            if (text[end] == '/' or text[end] == '?' or text[end] == '#' or text[end] == '@') break;
        }
        if (end == text.len and url_start < retained_start) return true;
        search_start = if (end < text.len) end + 1 else text.len;
    }
    return false;
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

fn terminalSafeToken(raw: []const u8, index: usize, buf: *[12]u8) TerminalSafeToken {
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
    const codepoint = std.unicode.utf8Decode(sequence) catch {
        return .{ .source_len = 1, .bytes = writeByteEscape(buf, byte) };
    };
    if (isNonPrintingCodepoint(codepoint)) {
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

fn matchesInlineKey(text: []const u8, start: usize) ?SecretSpan {
    if (start > 0 and isTokenChar(text[start - 1])) return null;
    const prefixes = [_][]const u8{ "sk-", "sk_live_", "pk_live_", "github_pat_", "xoxb-", "xoxp-", "Bearer " };
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
    if (!(std.mem.startsWith(u8, text[start..], "ghp_") or
        std.mem.startsWith(u8, text[start..], "gho_") or
        std.mem.startsWith(u8, text[start..], "ghu_") or
        std.mem.startsWith(u8, text[start..], "ghs_") or
        std.mem.startsWith(u8, text[start..], "ghr_"))) return null;
    var end = start + 4;
    while (end < text.len and isTokenChar(text[end])) : (end += 1) {}
    if (end - (start + 4) < 36) return null;
    return .{ .prefix_end = start, .value_len = end - start, .kind = "github_token" };
}

fn matchesAwsAccessKey(text: []const u8, start: usize) ?SecretSpan {
    const prefixes = [_][]const u8{ "AKIA", "ASIA", "AIDA", "AGPA", "AROA", "ANPA" };
    for (prefixes) |prefix| {
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

test "secret boundary analysis preserves resolved URLs and catches unfinished candidates" {
    try std.testing.expect(!secretMayCrossBoundary(
        "prefix https://example.com suffix ",
        64,
    ));
    try std.testing.expect(secretMayCrossBoundary(
        "MY_VERY_LONG_TOKEN_KEY",
        4,
    ));
    try std.testing.expect(secretMayCrossBoundary(
        "MY_VERY_LONG_TOKEN_KEY=",
        4,
    ));
    try std.testing.expect(secretMayCrossBoundary(
        "MY_VERY_LONG_TOKEN_KEY=\"",
        4,
    ));
    try std.testing.expect(secretMayCrossBoundary(
        "MY_VERY_LONG_TOKEN_KEY='",
        4,
    ));
    try std.testing.expect(secretMayCrossBoundary(
        "prefix https://user:password",
        4,
    ));
    try std.testing.expect(!secretMayCrossBoundary(
        "prefix ORDINARY_KEY",
        4,
    ));
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
    try std.testing.expect(std.mem.indexOfScalar(u8, encoded.bytes, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, encoded.bytes, '\n') == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded.bytes));
    try std.testing.expect(!encoded.truncated);
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
        try std.testing.expect(std.mem.indexOfScalar(u8, out.written(), 0x1b) == null);
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
    try std.testing.expect(std.mem.indexOfScalar(u8, encoded.bytes, 0x1b) == null);
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
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
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
    try std.testing.expect(std.mem.indexOfScalar(u8, encoded.bytes, 0x1b) == null);
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
