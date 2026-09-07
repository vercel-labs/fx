//! Label normalization, wrapping, and display-width clipping.
//!
//!     Mermaid label -> strip wrappers / tags -> decode entities -> owned text
//!                                                               │
//!                                             display-cell wrap / fit

const std = @import("std");
const display_width = @import("../../../core/shared/display_width.zig");

const Allocator = std.mem.Allocator;

pub const wrap_width = 24;
const max_label_lines = 4;

pub const Wrapped = struct {
    lines: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Wrapped, alloc: Allocator) void {
        for (self.lines.items) |line| alloc.free(line);
        self.lines.deinit(alloc);
        self.* = undefined;
    }
};

pub fn wrap(alloc: Allocator, label: []const u8) Allocator.Error!Wrapped {
    var result: Wrapped = .{};
    errdefer result.deinit(alloc);
    var rest = std.mem.trim(u8, label, " \t\r\n");
    while (rest.len > 0 and result.lines.items.len < max_label_lines) {
        var prefix = display_width.prefixByWidth(rest, wrap_width);
        if (prefix.len == 0) {
            const unit = display_width.displayUnitAt(rest, 0);
            prefix = rest[0..@max(@as(usize, 1), unit.byte_len)];
        }
        if (prefix.len < rest.len) {
            if (std.mem.lastIndexOfScalar(u8, prefix, ' ')) |space| {
                if (space > 0) prefix = prefix[0..space];
            }
        }
        const line = std.mem.trim(u8, prefix, " \t");
        const owned = try alloc.dupe(u8, line);
        errdefer alloc.free(owned);
        try result.lines.append(alloc, owned);
        rest = std.mem.trimStart(u8, rest[prefix.len..], " \t");
    }
    if (result.lines.items.len == 0) {
        const empty = try alloc.dupe(u8, "");
        errdefer alloc.free(empty);
        try result.lines.append(alloc, empty);
    }
    if (rest.len > 0) {
        const last = result.lines.items.len - 1;
        const fitted = try fitOwned(alloc, result.lines.items[last], wrap_width - 1);
        defer alloc.free(fitted);
        const truncated = try std.fmt.allocPrint(alloc, "{s}…", .{fitted});
        alloc.free(result.lines.items[last]);
        result.lines.items[last] = truncated;
    }
    return result;
}

pub fn fit(label: []const u8, width: usize) []const u8 {
    if (width == 0) return "";
    return display_width.prefixByWidth(label, width);
}

fn fitOwned(alloc: Allocator, label: []const u8, width: usize) Allocator.Error![]u8 {
    return alloc.dupe(u8, fit(label, width));
}

pub fn clean(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
        (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        value = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    }
    if (value.len >= 2 and value[0] == '`' and value[value.len - 1] == '`') {
        value = value[1 .. value.len - 1];
    }
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '<') {
            if (std.mem.findScalarPos(u8, value, index + 1, '>')) |close| {
                const tag = std.mem.trim(u8, value[index + 1 .. close], " /\t");
                const name = firstWord(tag);
                if (std.ascii.eqlIgnoreCase(name, "br")) {
                    try output.append(alloc, ' ');
                    index = close + 1;
                    continue;
                }
                if (isFormattingTag(name)) {
                    index = close + 1;
                    continue;
                }
            }
        }
        if (value[index] == '&') {
            if (decodeEntity(value[index..])) |entity| {
                try appendCodepoint(alloc, &output, entity.codepoint);
                index += entity.bytes;
                continue;
            }
        }
        const byte = value[index];
        if (byte < 0x20 or byte == 0x7f) {
            index += 1;
            continue;
        }
        if ((byte == '*' or byte == '`') or
            (byte == '_' and (index == 0 or index + 1 == value.len or !std.ascii.isAlphanumeric(value[index - 1]) or !std.ascii.isAlphanumeric(value[index + 1]))))
        {
            index += 1;
            continue;
        }
        const unit = display_width.displayUnitAt(value, index);
        const length = @max(@as(usize, 1), unit.byte_len);
        try output.appendSlice(alloc, value[index..@min(value.len, index + length)]);
        index += length;
    }
    return output.toOwnedSlice(alloc);
}

fn isFormattingTag(name: []const u8) bool {
    const tags = [_][]const u8{
        "b",    "strong", "i",     "em",   "u",    "s",   "strike", "del",
        "ins",  "mark",   "small", "big",  "sub",  "sup", "code",   "kbd",
        "samp", "var",    "tt",    "span", "font", "q",   "abbr",   "cite",
        "pre",
    };
    for (tags) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}

const Entity = struct { codepoint: u21, bytes: usize };

fn decodeEntity(source: []const u8) ?Entity {
    const end = std.mem.findScalarPos(u8, source, 1, ';') orelse return null;
    if (end > 10) return null;
    const body = source[1..end];
    const codepoint: u21 = if (std.mem.eql(u8, body, "lt")) '<' else if (std.mem.eql(u8, body, "gt")) '>' else if (std.mem.eql(u8, body, "amp")) '&' else if (std.mem.eql(u8, body, "quot")) '"' else if (std.mem.eql(u8, body, "apos")) '\'' else blk: {
        if (!std.mem.startsWith(u8, body, "#")) return null;
        const number = body[1..];
        const parsed: u21 = if (number.len > 1 and (number[0] == 'x' or number[0] == 'X'))
            std.fmt.parseInt(u21, number[1..], 16) catch return null
        else
            std.fmt.parseInt(u21, number, 10) catch return null;
        if (parsed < 0x20 or (parsed >= 0x7f and parsed < 0xa0)) return null;
        break :blk parsed;
    };
    return .{ .codepoint = codepoint, .bytes = end + 1 };
}

fn appendCodepoint(alloc: Allocator, output: *std.ArrayList(u8), codepoint: u21) Allocator.Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch return;
    try output.appendSlice(alloc, buffer[0..length]);
}

fn firstWord(source: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, source, " \t\r\n");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and trimmed[end] != '\r' and trimmed[end] != '\n') : (end += 1) {}
    return trimmed[0..end];
}
