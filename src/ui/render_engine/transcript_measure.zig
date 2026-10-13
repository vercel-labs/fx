const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const assistant_wrap = @import("assistant_wrap.zig");
const text_utils = @import("../../core/shared/text_utils.zig");

pub const WalkResult = struct {
    end_row: u32,
    end_col: u16,
};

/// Walks visual rows without capping the result to the viewport. Under
/// DECAWM-OFF, glyphs wrap only when they exceed the right margin.
pub fn walkText(start_row: u32, start_col: u16, bytes: []const u8, cols: u16) WalkResult {
    if (bytes.len == 0 or cols == 0) return .{ .end_row = start_row, .end_col = start_col };

    var row: u32 = start_row;
    var col: u16 = start_col;
    var i: usize = 0;
    while (i < bytes.len) {
        const ch = bytes[i];

        if (ch == 0x1b) {
            i = display_width.ansiSequenceEnd(bytes, i);
            continue;
        }

        switch (ch) {
            '\r' => {
                col = 1;
                i += 1;
                continue;
            },
            '\n' => {
                col = 1;
                row += 1;
                i += 1;
                continue;
            },
            else => {},
        }

        if (ch == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            i += 1;
            continue;
        }

        if (ch < 32) {
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(bytes, i);
        const w_usize = unit.cell_width;
        if (w_usize == 0) {
            i += unit.byte_len;
            continue;
        }

        const w: u16 = @intCast(w_usize);
        if (display_width.shouldWrapAt(col, w, cols)) {
            col = 1;
            row += 1;
        }
        col += w;
        i += unit.byte_len;
    }
    return .{ .end_row = row, .end_col = col };
}

// Transcript rows can carry SGR + OSC-8 + other escape sequences (image
// badges, the user-message bar). ANSI-aware walking skips escape bytes so
// terminal position tracking stays correct whether a row is plain text or styled.
pub fn nextCursorColForLine(line: []const u8, cols: u16) u16 {
    if (cols == 0) return 1;
    return @min(cols, walkText(1, 1, line, cols).end_col);
}

/// Returns the byte offset of visual row `skip_rows + 1` using the same
/// ANSI-aware wrapping rules as `visualRowsForLine`.
pub fn skipVisualRowsInLine(text: []const u8, cols: u16, skip_rows: u16) usize {
    if (skip_rows == 0 or cols == 0 or text.len == 0) return 0;

    var col: u16 = 1;
    var rows_skipped: u16 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == 0x1b) {
            i = display_width.ansiSequenceEnd(text, i);
            continue;
        }
        if (ch == '\r') {
            col = 1;
            i += 1;
            continue;
        }
        if (ch == '\n') {
            col = 1;
            rows_skipped += 1;
            i += 1;
            if (rows_skipped >= skip_rows) return i;
            continue;
        }
        if (ch == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            i += 1;
            continue;
        }
        if (ch < 32) {
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, i);
        const w_usize = unit.cell_width;
        if (w_usize == 0) {
            i += unit.byte_len;
            continue;
        }
        const w: u16 = @intCast(w_usize);

        if (display_width.shouldWrapAt(col, w, cols)) {
            col = 1;
            rows_skipped += 1;
            if (rows_skipped >= skip_rows) return i;
        }
        col += w;
        i += unit.byte_len;
    }
    return text.len;
}

pub fn visualRowsForLine(text: []const u8, cols: u16) u16 {
    if (cols == 0) return 1;
    if (text.len == 0) return 1;

    var col: u16 = 1;
    var rows: u16 = 1;
    var rows_with_content: u16 = 0;
    var wrote_on_current_row = false;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == 0x1b) {
            i = display_width.ansiSequenceEnd(text, i);
            continue;
        }
        switch (ch) {
            '\r' => {
                col = 1;
                i += 1;
                continue;
            },
            '\n' => {
                if (wrote_on_current_row) rows_with_content = rows;
                col = 1;
                rows += 1;
                wrote_on_current_row = false;
                i += 1;
                continue;
            },
            else => {},
        }
        if (ch == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            i += 1;
            continue;
        }
        if (ch < 32) {
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, i);
        i += unit.byte_len;
        const w_usize = unit.cell_width;
        if (w_usize == 0) continue;
        const w: u16 = @intCast(w_usize);

        if (display_width.shouldWrapAt(col, w, cols)) {
            col = 1;
            rows += 1;
            wrote_on_current_row = false;
        }
        col += w;
        wrote_on_current_row = true;
    }

    if (wrote_on_current_row) rows_with_content = rows;
    return if (rows_with_content == 0) 1 else rows_with_content;
}

test "skipVisualRowsInLine skips hard newlines" {
    const offset = skipVisualRowsInLine("a\nb\nc\nd", 80, 2);
    try std.testing.expectEqual(@as(usize, 4), offset);
}

test "skipVisualRowsInLine skips soft-wrap boundaries" {
    const offset = skipVisualRowsInLine("abcdef", 3, 1);
    try std.testing.expectEqual(@as(usize, 3), offset);
}

test "skipVisualRowsInLine with zero skip returns zero" {
    const offset = skipVisualRowsInLine("anything", 40, 0);
    try std.testing.expectEqual(@as(usize, 0), offset);
}

test "skipVisualRowsInLine beyond actual rows returns text length" {
    const offset = skipVisualRowsInLine("abc", 10, 5);
    try std.testing.expectEqual(@as(usize, 3), offset);
}

test "positional tab changes following wrap geometry" {
    const text = "1234567\tXYZ";
    const walked = walkText(1, 1, text, 10);
    try std.testing.expectEqual(@as(u32, 2), walked.end_row);
    try std.testing.expectEqual(@as(u16, 2), walked.end_col);
    try std.testing.expectEqual(@as(u16, 2), visualRowsForLine(text, 10));
    try std.testing.expectEqual(@as(usize, 10), skipVisualRowsInLine(text, 10, 1));
}

test "nextCursorColForLine follows the final wrapped row" {
    const record = text_utils.repeat("a", 249);
    try std.testing.expectEqual(@as(u16, 10), nextCursorColForLine(record, 120));
    try std.testing.expectEqual(@as(u16, 120), nextCursorColForLine(record[0..120], 120));
}

test "walkText, wrapAssistantText, and visualRowsForLine agree" {
    const Case = struct { s: []const u8, min_cols: u16 };
    const corpus = [_]Case{
        .{ .s = "", .min_cols = 1 },
        .{ .s = "a", .min_cols = 1 },
        .{ .s = "abc", .min_cols = 1 },
        .{ .s = "abc\ndef", .min_cols = 1 },
        .{ .s = "漢字", .min_cols = 2 },
        .{ .s = "a漢", .min_cols = 2 },
        .{ .s = "a\u{0301}b", .min_cols = 1 },
        .{ .s = "a\u{2600}\u{FE0E}b", .min_cols = 1 },
        .{ .s = "a\u{1F44D}\u{1F3FD}b", .min_cols = 2 },
        .{ .s = "a\u{1F1FA}\u{1F1F8}b", .min_cols = 2 },
        .{ .s = "a#\u{FE0F}\u{20E3}b", .min_cols = 2 },
        .{ .s = "a\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}b", .min_cols = 2 },
        .{ .s = "a\u{1F469}\u{200D}\u{1F4BB}b", .min_cols = 2 },
        .{ .s = "\r", .min_cols = 1 },
        .{ .s = "a\rb", .min_cols = 1 },
        .{ .s = "\x1b[1;31mabc\x1b[0m", .min_cols = 1 },
        .{ .s = "\x1b]8;;http://x\x07link\x1b]8;;\x07", .min_cols = 1 },
        .{ .s = "\t", .min_cols = 1 },
    };
    const widths = [_]u16{ 1, 2, 4, 8, 10, 40, 80 };
    for (corpus) |case| {
        for (widths) |c| {
            if (c < case.min_cols) continue;
            const wrapped = try assistant_wrap.wrapAssistantText(std.testing.allocator, case.s, c);
            defer std.testing.allocator.free(wrapped);
            try std.testing.expectEqual(
                walkText(1, 1, case.s, c).end_row,
                walkText(1, 1, wrapped, c).end_row,
            );
            if (std.mem.findScalar(u8, case.s, '\n') == null) {
                try std.testing.expectEqual(
                    @as(u32, visualRowsForLine(case.s, c)),
                    walkText(1, 1, case.s, c).end_row,
                );
            }

            const total = visualRowsForLine(case.s, c);
            try std.testing.expectEqual(case.s.len, skipVisualRowsInLine(case.s, c, total));

            var prev: usize = 0;
            var skip: u16 = 1;
            while (skip <= total) : (skip += 1) {
                const offset = skipVisualRowsInLine(case.s, c, skip);
                try std.testing.expect(offset >= prev);
                prev = offset;
            }
        }
    }
}

test "walkText cols=0 is a noop on row/col" {
    const r = walkText(5, 3, "abc\ndef", 0);
    try std.testing.expectEqual(@as(u32, 5), r.end_row);
    try std.testing.expectEqual(@as(u16, 3), r.end_col);
}
