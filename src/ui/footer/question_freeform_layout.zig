const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");

pub const Direction = enum {
    up,
    down,
};

pub const Line = struct {
    start: usize,
    content_end: usize,
    next_start: usize,
    hard_break: bool,
    synthetic: bool = false,
};

pub const CursorMove = struct {
    cursor: usize,
    preferred_column: usize,
    moved: bool,
};

/// Panel indent shared by every option row; selection is signalled by style
/// alone, so no marker column exists.
pub const option_row_indent = "    ";

pub fn optionPrefixWidth(index: usize) usize {
    var ordinal_buf: [16]u8 = undefined;
    const ordinal = std.mem.print(&ordinal_buf, "{d}) ", .{index + 1}) catch "";
    return display_width.visibleWidth(option_row_indent) + display_width.visibleWidth(ordinal);
}

pub fn contentWidth(choice_index: usize, row_budget: usize) usize {
    return @max(row_budget -| optionPrefixWidth(choice_index), 1);
}

pub fn normalizedCursor(buffer: []const u8, cursor: usize) usize {
    var safe_cursor = @min(cursor, buffer.len);
    while (safe_cursor > 0 and safe_cursor < buffer.len and
        (buffer[safe_cursor] & 0b1100_0000) == 0b1000_0000)
    {
        safe_cursor -= 1;
    }
    return safe_cursor;
}

pub fn nextLine(buffer: []const u8, start: usize, content_width: usize) Line {
    std.debug.assert(content_width > 0);
    if (start >= buffer.len) {
        return .{
            .start = buffer.len,
            .content_end = buffer.len,
            .next_start = buffer.len,
            .hard_break = false,
            .synthetic = true,
        };
    }

    const newline = std.mem.findScalar(u8, buffer[start..], '\n');
    const segment_end = if (newline) |relative| start + relative else buffer.len;
    const segment = buffer[start..segment_end];
    const prefix = display_width.prefixByWidth(segment, content_width);
    if (prefix.len < segment.len) {
        if (prefix.len > 0) {
            const end = start + prefix.len;
            return .{
                .start = start,
                .content_end = end,
                .next_start = end,
                .hard_break = false,
            };
        }

        const unit = display_width.displayUnitAt(buffer, start);
        const end = @min(start + unit.byte_len, segment_end);
        return .{
            .start = start,
            .content_end = end,
            .next_start = end,
            .hard_break = false,
        };
    }

    const hard_break = segment_end < buffer.len;
    return .{
        .start = start,
        .content_end = segment_end,
        .next_start = if (hard_break) segment_end + 1 else segment_end,
        .hard_break = hard_break,
    };
}

pub fn lineCount(buffer: []const u8, cursor: usize, content_width: usize) usize {
    if (buffer.len == 0) return 1;

    var count: usize = 0;
    var start: usize = 0;
    var last_width: usize = 0;
    var trailing_hard_break = false;
    while (start < buffer.len) {
        const line = nextLine(buffer, start, content_width);
        count += 1;
        last_width = display_width.visibleWidth(buffer[line.start..line.content_end]);
        trailing_hard_break = line.hard_break and line.next_start == buffer.len;
        start = line.next_start;
    }

    const safe_cursor = normalizedCursor(buffer, cursor);
    if (trailing_hard_break or
        (safe_cursor == buffer.len and last_width == content_width))
    {
        count += 1;
    }
    return count;
}

pub fn moveCursor(
    buffer: []const u8,
    cursor: usize,
    content_width: usize,
    direction: Direction,
    preferred_column: ?usize,
) CursorMove {
    const safe_cursor = normalizedCursor(buffer, cursor);
    var previous: ?Line = null;
    var line = nextLine(buffer, 0, content_width);

    while (true) {
        if (lineOwnsCursor(buffer, line, safe_cursor, content_width)) {
            const column = preferred_column orelse cursorColumn(buffer, line, safe_cursor);
            const target = switch (direction) {
                .up => previous,
                .down => advanceLine(buffer, line, content_width),
            };
            if (target) |target_line| {
                return .{
                    .cursor = cursorAtColumn(buffer, target_line, column, content_width),
                    .preferred_column = column,
                    .moved = true,
                };
            }
            return .{
                .cursor = safe_cursor,
                .preferred_column = column,
                .moved = false,
            };
        }

        const next = advanceLine(buffer, line, content_width) orelse break;
        previous = line;
        line = next;
    }

    return .{
        .cursor = safe_cursor,
        .preferred_column = preferred_column orelse 0,
        .moved = false,
    };
}

fn advanceLine(buffer: []const u8, line: Line, content_width: usize) ?Line {
    if (line.synthetic) return null;
    if (line.next_start < buffer.len) return nextLine(buffer, line.next_start, content_width);
    if (line.hard_break and line.next_start == buffer.len) {
        return nextLine(buffer, buffer.len, content_width);
    }
    if (!line.hard_break and
        line.content_end == buffer.len and
        display_width.visibleWidth(buffer[line.start..line.content_end]) == content_width)
    {
        return nextLine(buffer, buffer.len, content_width);
    }
    return null;
}

fn lineOwnsCursor(
    buffer: []const u8,
    line: Line,
    cursor: usize,
    content_width: usize,
) bool {
    if (line.synthetic) return cursor == line.start;
    if (cursor < line.start or cursor > line.content_end) return false;
    if (cursor < line.content_end) return true;
    if (line.hard_break) return true;
    return advanceLine(buffer, line, content_width) == null;
}

fn cursorColumn(buffer: []const u8, line: Line, cursor: usize) usize {
    if (line.synthetic) return 0;
    return display_width.visibleWidth(buffer[line.start..cursor]);
}

fn cursorAtColumn(
    buffer: []const u8,
    line: Line,
    target_column: usize,
    content_width: usize,
) usize {
    if (line.synthetic or target_column == 0) return line.start;

    var cursor = line.start;
    var column: usize = 0;
    var last_owned = line.start;
    while (cursor < line.content_end) {
        const unit = display_width.displayUnitAt(buffer, cursor);
        if (column + unit.cell_width > target_column) break;
        cursor += unit.byte_len;
        column += unit.cell_width;
        if (lineOwnsCursor(buffer, line, cursor, content_width)) {
            last_owned = cursor;
        }
        if (column >= target_column) break;
    }
    return last_owned;
}

test "vertical movement preserves preferred column across hard lines" {
    const buffer = "abcd\nef\nghij";

    const first = moveCursor(buffer, 11, 20, .up, null);
    try std.testing.expectEqual(@as(usize, 7), first.cursor);
    try std.testing.expectEqual(@as(usize, 3), first.preferred_column);

    const second = moveCursor(buffer, first.cursor, 20, .up, first.preferred_column);
    try std.testing.expectEqual(@as(usize, 3), second.cursor);

    const third = moveCursor(buffer, second.cursor, 20, .down, second.preferred_column);
    try std.testing.expectEqual(@as(usize, 7), third.cursor);
}

test "vertical movement follows soft wrapped rows" {
    const buffer = "abcdefghijkl";

    const first = moveCursor(buffer, 10, 4, .up, null);
    try std.testing.expectEqual(@as(usize, 6), first.cursor);
    const second = moveCursor(buffer, first.cursor, 4, .up, first.preferred_column);
    try std.testing.expectEqual(@as(usize, 2), second.cursor);
}

test "vertical movement stays within utf8 display-unit boundaries" {
    const buffer = "a🙂b\nxy";

    const moved = moveCursor(buffer, buffer.len, 20, .up, null);
    try std.testing.expectEqual(@as(usize, 1), moved.cursor);
    try std.testing.expect(std.unicode.utf8ValidateSlice(buffer[0..moved.cursor]));
}

test "vertical movement preserves a combining sequence boundary" {
    const buffer = "e\u{301}x\nab";

    const moved = moveCursor(buffer, buffer.len, 20, .up, null);
    try std.testing.expectEqual(@as(usize, 4), moved.cursor);
    try std.testing.expect(std.unicode.utf8ValidateSlice(buffer[0..moved.cursor]));
}

test "vertical movement is inert beyond the first and last row" {
    const buffer = "one\ntwo";

    const up = moveCursor(buffer, 2, 20, .up, null);
    try std.testing.expectEqual(@as(usize, 2), up.cursor);
    try std.testing.expect(!up.moved);

    const down = moveCursor(buffer, buffer.len, 20, .down, null);
    try std.testing.expectEqual(buffer.len, down.cursor);
    try std.testing.expect(!down.moved);
}

test "line count includes trailing and exact-width cursor rows" {
    try std.testing.expectEqual(@as(usize, 2), lineCount("one\n", 4, 20));
    try std.testing.expectEqual(@as(usize, 2), lineCount("four", 4, 4));
}
