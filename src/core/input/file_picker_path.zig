const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const text_utils = @import("../shared/text_utils.zig");

fn needs_quotes(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".")) return true;
    for (path) |byte| {
        if (byte >= 0x80 or std.ascii.isAlphanumeric(byte)) continue;
        if (byte != '_' and byte != '-' and byte != '.' and byte != '/' and byte != '~') return true;
    }
    return false;
}

pub fn isRepresentable(path: []const u8) bool {
    return path.len > 0 and text_utils.isTerminalSafe(path);
}

fn is_separator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn is_start_boundary(byte: u8) bool {
    return is_separator(byte) or switch (byte) {
        '(', '[', '{', '<', '\'', '"', '`' => true,
        else => false,
    };
}

fn is_sentence_punctuation(byte: u8) bool {
    return switch (byte) {
        ',', '.', ';', ':', '!', '?' => true,
        else => false,
    };
}

/// Legacy image token boundaries only, not shell expansion or path decoding.
pub fn token_end(text: []const u8, start: usize) usize {
    var index = start;
    var quote: ?u8 = null;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\\' and index + 1 < text.len) {
            index += 1;
            continue;
        }
        if (quote) |active| {
            if (byte == active) quote = null;
        } else if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (is_separator(byte)) break;
    }
    return index;
}

pub const Status = enum { complete, incomplete, invalid };

/// Source offsets borrow the unchanged input. `end` includes any prose suffix;
/// `path_end` excludes the closing quote, and `quote_end` includes it.
pub const Token = struct {
    start: usize,
    end: usize,
    path_start: usize,
    path_end: usize,
    quote_end: ?usize = null,
    status: Status,
    quoted: bool,
    canonical_escapes: bool = true,
};

pub fn parse_at(text: []const u8, start: usize) ?Token {
    if (start >= text.len or text[start] != '@') return null;
    if (start > 0 and !is_start_boundary(text[start - 1])) return null;
    const quoted = start + 1 < text.len and text[start + 1] == '"';
    const path_start = start + 1 + @intFromBool(quoted);
    if (!quoted) {
        var end = path_start;
        if (end < text.len and text[end] == '\'') {
            end = token_end(text, path_start);
        } else {
            // A quote embedded in a bare filename is data, including a prose
            // quote that follows it. It must not swallow later @ occurrences.
            while (end < text.len and !is_separator(text[end])) : (end += 1) {
                if (text[end] == '\\' and end + 1 < text.len) end += 1;
            }
        }
        return .{ .start = start, .end = end, .path_start = path_start, .path_end = end, .quoted = false, .status = if (end == path_start) .incomplete else .complete };
    }

    var index = path_start;
    var canonical_escapes = true;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\n' or byte == '\r' or byte == '\t') break;
        if (byte == '\\') {
            if (index + 1 == text.len) {
                index = text.len;
                break;
            }
            const next = text[index + 1];
            if (next == '\n' or next == '\r' or next == '\t') break;
            canonical_escapes = canonical_escapes and (next == '\\' or next == '"');
            index += 1;
        } else if (byte == '"') {
            const quote_end = index + 1;
            const end = token_end(text, quote_end);
            var valid = index > path_start and text_utils.isTerminalSafe(text[path_start..index]);
            for (text[quote_end..end]) |suffix| valid = valid and is_sentence_punctuation(suffix);
            return .{
                .start = start,
                .end = end,
                .path_start = path_start,
                .path_end = index,
                .quote_end = quote_end,
                .status = if (valid) .complete else .invalid,
                .quoted = true,
                .canonical_escapes = canonical_escapes,
            };
        }
    }
    return .{ .start = start, .end = index, .path_start = path_start, .path_end = index, .status = .incomplete, .quoted = true, .canonical_escapes = canonical_escapes };
}

pub const Iterator = struct {
    text: []const u8,
    offset: usize = 0,

    pub fn next(self: *Iterator) ?Token {
        while (self.offset < self.text.len) {
            if (parse_at(self.text, self.offset)) |token| {
                self.offset = @max(token.end, self.offset + 1);
                return token;
            }
            self.offset += 1;
        }
        return null;
    }
};

const DecodeError = error{ InvalidPath, NoSpaceLeft };

/// Decodes a quoted payload (without delimiters) into caller-owned storage.
/// Legacy escape-next-byte spelling is retained; no JSON or variable expansion.
pub fn decode_into(payload: []const u8, out: []u8) DecodeError![]const u8 {
    if (!text_utils.isTerminalSafe(payload)) return error.InvalidPath;
    var index: usize = 0;
    var written: usize = 0;
    while (index < payload.len) : (index += 1) {
        if (payload[index] == '\\') {
            index += 1;
            if (index == payload.len) return error.InvalidPath;
        }
        if (written == out.len) return error.NoSpaceLeft;
        out[written] = payload[index];
        written += 1;
    }
    return out[0..written];
}

/// Caller owns the decoded payload.
pub fn decode_alloc(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, payload.len);
    errdefer alloc.free(out);
    const decoded = try decode_into(payload, out);
    return alloc.realloc(out, decoded.len);
}

pub const Query = struct {
    /// Raw payload prefix, not the decoded lookup key.
    query: []const u8,
    at_offset: usize,
    token_start: usize,
    replace_end: usize,
    quoted: bool,

    pub fn decoded_query(self: Query, out: []u8) DecodeError![]const u8 {
        return if (self.quoted) decode_into(self.query, out) else self.query;
    }
};

pub fn query_at(text: []const u8, cursor: usize) ?Query {
    if (cursor > text.len) return null;
    var iterator: Iterator = .{ .text = text };
    while (iterator.next()) |token| {
        if (cursor < token.path_start) return null;
        if (cursor > token.path_end) continue;
        if (token.status == .invalid) return null;
        const prefix = text[token.path_start..cursor];
        if (!text_utils.isTerminalSafe(prefix)) return null;
        if (!token.quoted) {
            // Bare completion has always replaced only the prefix at the caret.
            for (prefix) |byte| if (is_separator(byte)) return null;
        }
        return .{
            .query = prefix,
            .at_offset = token.start,
            .token_start = token.path_start,
            .replace_end = token.quote_end orelse cursor,
            .quoted = token.quoted,
        };
    }
    return null;
}

/// Whether inserting at this cursor edits an existing path payload.
pub fn contains_position(text: []const u8, cursor: usize) bool {
    var paths: Iterator = .{ .text = text };
    while (paths.next()) |path| {
        if (cursor < path.path_start) return false;
        const end = if (path.quoted and path.status == .complete) path.path_end else path.end;
        if (cursor <= end) return true;
    }
    return false;
}

const EncodeOptions = struct {
    quoted: bool = false,
    directory: bool = false,
    workspace_relative: bool = false,
};

/// Returns caller-owned @ text, without a trailing composer separator.
pub fn encode(alloc: std.mem.Allocator, path: []const u8, options: EncodeOptions) ![]u8 {
    if (!isRepresentable(path)) return error.InvalidPath;
    const quote = options.quoted or needs_quotes(path);
    const prefix_relative = options.workspace_relative and path[0] == '~';
    var length = try std.math.add(usize, 1 + @as(usize, @intFromBool(quote)) + @as(usize, @intFromBool(quote and !options.directory)) + @as(usize, @intFromBool(options.directory)) + @as(usize, if (prefix_relative) 2 else 0), path.len);
    if (quote) for (path) |byte| {
        if (byte == '\\' or byte == '"') length = try std.math.add(usize, length, 1);
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, length);
    out.appendAssumeCapacity('@');
    if (quote) out.appendAssumeCapacity('"');
    if (prefix_relative) out.appendSliceAssumeCapacity("./");
    for (path) |byte| {
        if (quote and (byte == '\\' or byte == '"')) out.appendAssumeCapacity('\\');
        out.appendAssumeCapacity(byte);
    }
    if (options.directory) out.appendAssumeCapacity('/');
    if (quote and !options.directory) out.appendAssumeCapacity('"');
    return out.toOwnedSlice(alloc);
}

test "at path codec round trips punctuation quotes backslashes and Unicode" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "src/main.zig", "./photo.png,", "./$review.txt", "./a\\b.png", "./a\"b.png", "\"leading", " leading.png", "tail.png ", "café/文.txt" }) |path| {
        const encoded = try encode(alloc, path, .{});
        defer alloc.free(encoded);
        const token = parse_at(encoded, 0).?;
        try std.testing.expectEqual(Status.complete, token.status);
        const decoded = if (token.quoted) try decode_alloc(alloc, encoded[token.path_start..token.path_end]) else try alloc.dupe(u8, encoded[token.path_start..token.path_end]);
        defer alloc.free(decoded);
        try std.testing.expectEqualStrings(path, decoded);
    }
    try std.testing.expect(!isRepresentable("bad\nname"));
    try std.testing.expect(!isRepresentable("bad\x1bname"));
    try std.testing.expect(!isRepresentable("\xff"));
}

test "at path codec separates raw query range from decoded prefix" {
    const input = "read @\"./a\\\"b.png\" suffix";
    const cursor = "read @\"./a\\\"b".len;
    const query = query_at(input, cursor).?;
    var decoded: [64]u8 = undefined;
    try std.testing.expectEqualStrings("./a\"b", try query.decoded_query(&decoded));
    try std.testing.expectEqual("read @\"./a\\\"b.png\"".len, query.replace_end);
    try std.testing.expect(query_at(input, query.replace_end) == null);
    try std.testing.expectEqual(Status.invalid, parse_at("@\"photo.png\"other.png", 0).?.status);
    try std.testing.expectEqual(Status.incomplete, parse_at("@\"photo.png", 0).?.status);
    try std.testing.expect(!parse_at("@\"a\\.png\"", 0).?.canonical_escapes);
}

test "at path codec follows later mentions after prose quotes" {
    const input = "Compare \"@src/main.zig\" and @other";
    const query = query_at(input, input.len) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("other", query.query);
}

test "at path codec bounds decoding and cleans up failed allocations" {
    var small: [1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, decode_into("ab", &small));
    try std.testing.expectError(error.InvalidPath, decode_into("\\", &small));
    try std.testing.expect(query_at("@\"a\\\"b\"tail", 5) == null);
    try std.testing.expect(contains_position("@\"a\\", 4));
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, struct {
        fn check(alloc: std.mem.Allocator) !void {
            const path = "a\\b\"$c";
            const encoded = try encode(alloc, path, .{});
            defer alloc.free(encoded);
            const token = parse_at(encoded, 0).?;
            const decoded = try decode_alloc(alloc, encoded[token.path_start..token.path_end]);
            defer alloc.free(decoded);
            try std.testing.expectEqualStrings(path, decoded);
        }
    }.check, .{});
}

test "at path codec keeps directory quotes open and workspace tilde literal" {
    const alloc = std.testing.allocator;
    const directory = try encode(alloc, "./dir name", .{ .directory = true });
    defer alloc.free(directory);
    try std.testing.expectEqualStrings("@\"./dir name/", directory);
    const path = try encode(alloc, "~notes", .{ .workspace_relative = true });
    defer alloc.free(path);
    try std.testing.expectEqualStrings("@./~notes", path);
}
