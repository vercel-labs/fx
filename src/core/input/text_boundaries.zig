const std = @import("std");
const display_width = @import("../shared/display_width.zig");

pub fn nextCharacterEnd(text: []const u8, start: usize) usize {
    var end = @min(start, text.len);
    if (end == text.len) return end;

    const first = display_width.displayUnitAt(text, end);
    end += @max(first.byte_len, 1);
    if (isControlBoundary(text, start)) return @min(end, text.len);
    while (end < text.len) {
        const continuation = display_width.displayUnitAt(text, end);
        if (continuation.cell_width != 0 or isControlBoundary(text, end)) break;
        end += @max(continuation.byte_len, 1);
    }
    return @min(end, text.len);
}

pub fn previousCharacterStart(text: []const u8, end: usize) usize {
    const target = @min(end, text.len);
    if (target == 0) return 0;

    var current: usize = 0;
    var previous: usize = 0;
    while (current < target) {
        previous = current;
        const next = nextCharacterEnd(text, current);
        if (next >= target) return previous;
        current = next;
    }
    return previous;
}

pub fn previousWordStart(text: []const u8, cursor: usize) usize {
    var pos = @min(cursor, text.len);
    while (pos > 0) {
        const previous = previousCharacterStart(text, pos);
        if (isWordCharacterAt(text, previous)) break;
        pos = previous;
    }
    while (pos > 0) {
        const previous = previousCharacterStart(text, pos);
        if (!isWordCharacterAt(text, previous)) break;
        pos = previous;
    }
    return pos;
}

pub fn nextWordEnd(text: []const u8, cursor: usize) usize {
    var pos = @min(cursor, text.len);
    while (pos < text.len and !isWordCharacterAt(text, pos)) {
        pos = nextCharacterEnd(text, pos);
    }
    while (pos < text.len and isWordCharacterAt(text, pos)) {
        pos = nextCharacterEnd(text, pos);
    }
    return pos;
}

pub fn nextWordDeleteEnd(text: []const u8, cursor: usize) usize {
    var pos = @min(cursor, text.len);
    while (pos < text.len and isWordCharacterAt(text, pos)) {
        pos = nextCharacterEnd(text, pos);
    }
    while (pos < text.len and !isWordCharacterAt(text, pos)) {
        pos = nextCharacterEnd(text, pos);
    }
    return pos;
}

pub fn isWordCharacter(codepoint: u21) bool {
    if (codepoint == '_') return true;
    if (codepoint >= 'a' and codepoint <= 'z') return true;
    if (codepoint >= 'A' and codepoint <= 'Z') return true;
    if (codepoint >= '0' and codepoint <= '9') return true;
    return codepoint >= 0xC0;
}

pub fn logicalLineStart(text: []const u8, cursor: usize) usize {
    var start = @min(cursor, text.len);
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    return start;
}

pub fn logicalLineEnd(text: []const u8, cursor: usize) usize {
    var end = @min(cursor, text.len);
    while (end < text.len and text[end] != '\n') end += 1;
    return end;
}

fn lineIsBlank(text: []const u8, start: usize, end: usize) bool {
    for (text[start..end]) |byte| switch (byte) {
        ' ', '\t', '\r' => {},
        else => return false,
    };
    return true;
}

fn previousLineStart(text: []const u8, line_start: usize) ?usize {
    if (line_start == 0) return null;
    return logicalLineStart(text, line_start - 1);
}

pub fn previousParagraphStart(text: []const u8, cursor: usize) usize {
    var line_start = logicalLineStart(text, cursor);
    var line_end = logicalLineEnd(text, line_start);

    while (lineIsBlank(text, line_start, line_end)) {
        line_start = previousLineStart(text, line_start) orelse return 0;
        line_end = logicalLineEnd(text, line_start);
    }

    var paragraph_start = line_start;
    while (previousLineStart(text, paragraph_start)) |candidate| {
        if (lineIsBlank(text, candidate, logicalLineEnd(text, candidate))) break;
        paragraph_start = candidate;
    }
    if (cursor > paragraph_start) return paragraph_start;

    var previous = previousLineStart(text, paragraph_start) orelse return 0;
    while (lineIsBlank(text, previous, logicalLineEnd(text, previous))) {
        previous = previousLineStart(text, previous) orelse return 0;
    }
    var previous_start = previous;
    while (previousLineStart(text, previous_start)) |candidate| {
        if (lineIsBlank(text, candidate, logicalLineEnd(text, candidate))) break;
        previous_start = candidate;
    }
    return previous_start;
}

pub fn nextParagraphStart(text: []const u8, cursor: usize) usize {
    var line_start = logicalLineStart(text, cursor);
    var line_end = logicalLineEnd(text, line_start);

    while (!lineIsBlank(text, line_start, line_end)) {
        if (line_end == text.len) return text.len;
        line_start = line_end + 1;
        line_end = logicalLineEnd(text, line_start);
    }
    while (lineIsBlank(text, line_start, line_end)) {
        if (line_end == text.len) return text.len;
        line_start = line_end + 1;
        line_end = logicalLineEnd(text, line_start);
    }
    return line_start;
}

pub fn previousWhitespaceDelimitedTokenStart(
    text: []const u8,
    cursor: usize,
    lower_bound: usize,
) usize {
    var pos = @min(cursor, text.len);
    const lower = @min(lower_bound, pos);
    while (pos > lower) {
        const previous = previousCharacterStart(text, pos);
        if (!isWhitespaceCharacter(text, previous)) break;
        pos = previous;
    }
    while (pos > lower) {
        const previous = previousCharacterStart(text, pos);
        if (isWhitespaceCharacter(text, previous)) break;
        pos = previous;
    }
    return pos;
}

fn isControlBoundary(text: []const u8, start: usize) bool {
    const codepoint = display_width.decodeNextRune(text, start).codepoint;
    return codepoint < 0x20 or codepoint == 0x7F;
}

fn isWhitespaceCharacter(text: []const u8, start: usize) bool {
    const codepoint = display_width.decodeNextRune(text, start).codepoint;
    return codepoint <= 0x7F and std.ascii.isWhitespace(@intCast(codepoint));
}

fn isWordCharacterAt(text: []const u8, start: usize) bool {
    const codepoint = display_width.decodeNextRune(text, start).codepoint;
    return isWordCharacter(codepoint);
}

test "character boundaries group terminal character continuations" {
    const decomposed = "Ae\u{301}B";
    try std.testing.expectEqual(@as(usize, 4), nextCharacterEnd(decomposed, 1));
    try std.testing.expectEqual(@as(usize, 1), previousCharacterStart(decomposed, 4));

    const flag = "A🇺🇸B";
    try std.testing.expectEqual(@as(usize, 1 + "🇺🇸".len), nextCharacterEnd(flag, 1));
    try std.testing.expectEqual(@as(usize, 1), previousCharacterStart(flag, 1 + "🇺🇸".len));

    const modifier = "A👍🏽B";
    try std.testing.expectEqual(@as(usize, 1 + "👍🏽".len), nextCharacterEnd(modifier, 1));
    try std.testing.expectEqual(@as(usize, 1), previousCharacterStart(modifier, 1 + "👍🏽".len));

    const family = "A👨‍👩‍👧‍👦B";
    try std.testing.expectEqual(@as(usize, 1 + "👨‍👩‍👧‍👦".len), nextCharacterEnd(family, 1));
    try std.testing.expectEqual(@as(usize, 1), previousCharacterStart(family, 1 + "👨‍👩‍👧‍👦".len));
}

test "character boundaries group Thai base characters with their marks" {
    // Base consonant + above-vowel + tone mark forms one editing character.
    const cluster = "\u{0E01}\u{0E31}\u{0E49}";
    try std.testing.expectEqual(cluster.len, nextCharacterEnd(cluster, 0));
    try std.testing.expectEqual(@as(usize, 0), previousCharacterStart(cluster, cluster.len));

    // Stacked marks chain onto the same base (SARA U + MAI EK).
    const stacked = "\u{0E19}\u{0E38}\u{0E49}\u{0E01}";
    try std.testing.expectEqual("\u{0E19}\u{0E38}\u{0E49}".len, nextCharacterEnd(stacked, 0));
    try std.testing.expectEqual(@as(usize, 0), previousCharacterStart(stacked, "\u{0E19}\u{0E38}\u{0E49}".len));

    // SARA AM is spacing, so it starts a new editing character even after a
    // tone mark; the tone mark stays grouped with the base.
    const sara_am = "\u{0E19}\u{0E49}\u{0E33}";
    try std.testing.expectEqual("\u{0E19}\u{0E49}".len, nextCharacterEnd(sara_am, 0));
    try std.testing.expectEqual("\u{0E19}\u{0E49}".len, previousCharacterStart(sara_am, sara_am.len));

    // Spacing characters do not absorb a following mark.
    const spaced = "\u{0E01}\u{0E02}";
    try std.testing.expectEqual(@as(usize, 3), nextCharacterEnd(spaced, 0));
    try std.testing.expectEqual(@as(usize, 6), nextCharacterEnd(spaced, 3));
}

test "character boundaries preserve ascii and precomposed utf8" {
    const text = "AéB";
    try std.testing.expectEqual(@as(usize, 1), nextCharacterEnd(text, 0));
    try std.testing.expectEqual(@as(usize, 3), nextCharacterEnd(text, 1));
    try std.testing.expectEqual(@as(usize, 1), previousCharacterStart(text, 3));
    try std.testing.expectEqual(@as(usize, 3), previousCharacterStart(text, text.len));
    try std.testing.expectEqual(@as(usize, 0), previousCharacterStart(text, 0));
    try std.testing.expectEqual(text.len, nextCharacterEnd(text, text.len + 10));
}

test "control bytes remain independent character boundaries" {
    const text = "A\n\u{301}\tB";
    try std.testing.expectEqual(@as(usize, 1), nextCharacterEnd(text, 0));
    try std.testing.expectEqual(@as(usize, 2), nextCharacterEnd(text, 1));
    try std.testing.expectEqual(@as(usize, 4), nextCharacterEnd(text, 2));
    try std.testing.expectEqual(@as(usize, 5), nextCharacterEnd(text, 4));
    try std.testing.expectEqual(@as(usize, 4), previousCharacterStart(text, 5));
    try std.testing.expectEqual(@as(usize, 2), previousCharacterStart(text, 4));
    try std.testing.expectEqual(@as(usize, 1), previousCharacterStart(text, 2));
}

test "word boundaries use whole terminal characters" {
    const text = "alpha beta gamma";
    try std.testing.expectEqual(@as(usize, 11), previousWordStart(text, text.len));
    try std.testing.expectEqual(@as(usize, 6), previousWordStart(text, 11));
    try std.testing.expectEqual(@as(usize, 5), nextWordEnd(text, 0));
    try std.testing.expectEqual(@as(usize, 10), nextWordEnd(text, 5));
    try std.testing.expectEqual(text.len, nextWordEnd(text, 11));

    const unicode = "one e\u{301}lan 🇺🇸 flag";
    const flag_start = std.mem.find(u8, unicode, "🇺🇸").?;
    try std.testing.expectEqual(flag_start + "🇺🇸".len, nextWordEnd(unicode, "one e\u{301}lan".len));
    try std.testing.expectEqual(@as(usize, 4), previousWordStart(unicode, flag_start));
}

test "word deletion boundary consumes the current word and following separators" {
    const text = "alpha  beta gamma";
    try std.testing.expectEqual(@as(usize, 7), nextWordDeleteEnd(text, 0));
    try std.testing.expectEqual(@as(usize, 7), nextWordDeleteEnd(text, 5));
    try std.testing.expectEqual(@as(usize, 12), nextWordDeleteEnd(text, 7));
    try std.testing.expectEqual(text.len, nextWordDeleteEnd(text, 12));
    try std.testing.expectEqual(@as(usize, 7), nextWordDeleteEnd("alpha, beta", 0));

    const unicode = "élan 🙂 next";
    try std.testing.expectEqual(@as(usize, "élan ".len), nextWordDeleteEnd(unicode, 0));
}

test "logical line boundaries clamp to the current line" {
    const text = "alpha\nbeta\ngamma";
    try std.testing.expectEqual(@as(usize, 0), logicalLineStart(text, 5));
    try std.testing.expectEqual(@as(usize, 6), logicalLineStart(text, 8));
    try std.testing.expectEqual(@as(usize, 10), logicalLineEnd(text, 6));
    try std.testing.expectEqual(text.len, logicalLineEnd(text, text.len + 10));
}

test "paragraph boundaries move across blank-line-delimited blocks" {
    const text = "alpha\nbeta\n \t\ngamma\ndelta\n\nlast";
    const gamma = std.mem.find(u8, text, "gamma").?;
    const last = std.mem.find(u8, text, "last").?;

    try std.testing.expectEqual(@as(usize, 0), previousParagraphStart(text, "alpha\nbeta".len));
    try std.testing.expectEqual(@as(usize, 0), previousParagraphStart(text, gamma));
    try std.testing.expectEqual(gamma, nextParagraphStart(text, 0));
    try std.testing.expectEqual(last, nextParagraphStart(text, gamma));
    try std.testing.expectEqual(text.len, nextParagraphStart(text, last));
}

test "whitespace delimited token boundary stays within its logical line" {
    const text = "alpha\n  beta gamma";
    const line_start = logicalLineStart(text, text.len);
    try std.testing.expectEqual(@as(usize, 13), previousWhitespaceDelimitedTokenStart(text, text.len, line_start));
    try std.testing.expectEqual(@as(usize, 8), previousWhitespaceDelimitedTokenStart(text, 13, line_start));
    try std.testing.expectEqual(line_start, previousWhitespaceDelimitedTokenStart(text, 8, line_start));

    const unicode = "one\te\u{301}lan";
    try std.testing.expectEqual(@as(usize, 4), previousWhitespaceDelimitedTokenStart(unicode, unicode.len, 0));
}

test "character boundary offsets stay ordered and in bounds" {
    const cases = [_][]const u8{
        "",
        "ascii",
        "e\u{301}",
        "🇺🇸",
        "👍🏽",
        "👨‍👩‍👧‍👦",
        "\u{301}\u{302}x",
    };

    for (cases) |text| {
        var cursor: usize = 0;
        while (cursor < text.len) {
            const next = nextCharacterEnd(text, cursor);
            try std.testing.expect(next > cursor);
            try std.testing.expect(next <= text.len);
            try std.testing.expectEqual(cursor, previousCharacterStart(text, next));
            cursor = next;
        }
        try std.testing.expectEqual(text.len, cursor);
    }
}
