const std = @import("std");
const entity_spans = @import("../shared/entity_spans.zig");
const Allocator = std.mem.Allocator;

/// Pasted text stays visible inline until it exceeds the threshold; oversized
/// blocks collapse to placeholders and expand again before submit.
pub const large_paste_char_threshold: usize = 1000;

/// A block of pasted text replaced in the input by a short
/// `[Pasted text #N, M lines]` placeholder. The containing list owns
/// `text` and releases it through `clearBlocks` or `deinitBlocks`.
pub const PastedBlock = struct {
    id: usize,
    text: []u8,
    line_count: usize,
    span: entity_spans.Span = .{ .raw_start = 0, .raw_end = 0 },
};

/// Releases every backing text allocation and the list allocation.
pub fn deinitBlocks(alloc: Allocator, blocks: *std.ArrayList(PastedBlock)) void {
    for (blocks.items) |block| alloc.free(block.text);
    blocks.deinit(alloc);
}

/// Releases every backing text allocation while retaining the list capacity.
pub fn clearBlocks(alloc: Allocator, blocks: *std.ArrayList(PastedBlock)) void {
    for (blocks.items) |block| alloc.free(block.text);
    blocks.clearRetainingCapacity();
}

pub fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var lines: usize = 1;
    for (bytes) |b| {
        if (b == '\n') lines += 1;
    }
    // A trailing newline shouldn't inflate the count.
    if (bytes[bytes.len - 1] == '\n' and lines > 1) lines -= 1;
    return lines;
}

pub fn countCodepoints(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const width = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        i += @min(width, bytes.len - i);
        count += 1;
    }
    return count;
}

pub fn shouldUsePlaceholder(bytes: []const u8, line_threshold: u32) bool {
    return countCodepoints(bytes) > large_paste_char_threshold or
        (line_threshold > 0 and countLines(bytes) > line_threshold);
}

/// Write the placeholder that stands in for a pasted block inside the input.
/// Returns the slice of `buf` that was filled.
pub fn formatPlaceholder(buf: []u8, id: usize, line_count: usize) ![]const u8 {
    const noun = if (line_count == 1) "line" else "lines";
    return std.fmt.bufPrint(buf, "[Pasted text #{d}, {d} {s}]", .{ id, line_count, noun });
}

/// Replace every registered pasted-text span with its matching block content.
/// If nothing matches, returns `text` and `owned=false` — callers must not free
/// the result in that case.
pub const ExpandResult = struct {
    text: []const u8,
    owned: bool,
};

pub fn expand(alloc: Allocator, text: []const u8, blocks: []const PastedBlock) !ExpandResult {
    if (blocks.len == 0) {
        return .{ .text = text, .owned = false };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    var expanded_any = false;
    while (i < text.len) {
        if (registeredBlockStartingAt(text, blocks, i)) |block| {
            try out.appendSlice(alloc, block.text);
            i = block.span.raw_end;
            expanded_any = true;
            continue;
        }
        try out.append(alloc, text[i]);
        i += 1;
    }

    if (!expanded_any) {
        out.deinit(alloc);
        return .{ .text = text, .owned = false };
    }
    return .{ .text = try out.toOwnedSlice(alloc), .owned = true };
}

/// Expands registered paste spans fully contained in `[range_start, range_end)`.
/// The returned text contains only that range.
pub fn expandRange(
    alloc: Allocator,
    text: []const u8,
    blocks: []const PastedBlock,
    range_start: usize,
    range_end: usize,
) !ExpandResult {
    if (range_start > range_end or range_end > text.len) return error.InvalidPasteRange;
    if (blocks.len == 0) {
        return .{ .text = text[range_start..range_end], .owned = false };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var expanded_any = false;
    var i = range_start;
    while (i < range_end) {
        if (registeredBlockStartingAt(text, blocks, i)) |block| {
            if (block.span.raw_end <= range_end) {
                try out.appendSlice(alloc, block.text);
                i = block.span.raw_end;
                expanded_any = true;
                continue;
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }

    if (!expanded_any) {
        out.deinit(alloc);
        return .{ .text = text[range_start..range_end], .owned = false };
    }
    return .{ .text = try out.toOwnedSlice(alloc), .owned = true };
}

/// Returns the byte length after registered paste placeholders are expanded.
/// Null means the requested range is invalid or its length overflowed.
pub fn expandedRangeLen(
    text: []const u8,
    blocks: []const PastedBlock,
    range_start: usize,
    range_end: usize,
) ?usize {
    if (range_start > range_end or range_end > text.len) return null;
    if (blocks.len == 0) return range_end - range_start;

    var expanded_len: usize = 0;
    var i = range_start;
    while (i < range_end) {
        if (registeredBlockStartingAt(text, blocks, i)) |block| {
            if (block.span.raw_end <= range_end) {
                expanded_len = std.math.add(
                    usize,
                    expanded_len,
                    block.text.len,
                ) catch return null;
                i = block.span.raw_end;
                continue;
            }
        }
        expanded_len = std.math.add(usize, expanded_len, 1) catch return null;
        i += 1;
    }
    return expanded_len;
}

pub fn expandedLen(text: []const u8, blocks: []const PastedBlock) ?usize {
    var expanded_len = text.len;
    for (blocks) |block| {
        if (!isRegisteredBlock(text, block)) continue;
        const placeholder_len = block.span.raw_end - block.span.raw_start;
        if (block.text.len >= placeholder_len) {
            expanded_len = std.math.add(
                usize,
                expanded_len,
                block.text.len - placeholder_len,
            ) catch return null;
        } else {
            expanded_len = std.math.sub(
                usize,
                expanded_len,
                placeholder_len - block.text.len,
            ) catch return null;
        }
    }
    return expanded_len;
}

fn registeredBlockStartingAt(text: []const u8, blocks: []const PastedBlock, raw_start: usize) ?PastedBlock {
    for (blocks) |block| {
        if (block.span.raw_start < raw_start) continue;
        if (block.span.raw_start > raw_start) return null;
        if (!isRegisteredBlock(text, block)) return null;
        return block;
    }
    return null;
}

fn isRegisteredBlock(text: []const u8, block: PastedBlock) bool {
    if (!block.span.isValid(text.len)) return false;
    var placeholder_buf: [64]u8 = undefined;
    const canonical = formatPlaceholder(
        &placeholder_buf,
        block.id,
        block.line_count,
    ) catch return false;
    return std.mem.eql(
        u8,
        text[block.span.raw_start..block.span.raw_end],
        canonical,
    );
}

pub fn registeredPlaceholderSpanStartingAt(
    text: []const u8,
    raw_start: usize,
    blocks: []const PastedBlock,
) ?PlaceholderSpan {
    const block = registeredBlockStartingAt(text, blocks, raw_start) orelse return null;
    return .{
        .start = block.span.raw_start,
        .end = block.span.raw_end,
        .id = block.id,
    };
}

pub const PlaceholderSpan = struct { start: usize, end: usize, id: usize };

/// Maps a byte offset in placeholder-bearing input into the expanded text.
/// Returns null when the offset lands inside a placeholder span.
pub fn projectOffsetThroughExpansion(
    raw_input: []const u8,
    pasted_blocks: []const PastedBlock,
    raw_offset: usize,
) ?usize {
    if (raw_offset > raw_input.len) return null;
    var input_offset: usize = 0;
    var output_offset: usize = 0;
    while (input_offset < raw_offset) {
        if (registeredBlockStartingAt(raw_input, pasted_blocks, input_offset)) |block| {
            if (raw_offset < block.span.raw_end) return null;
            output_offset = std.math.add(
                usize,
                output_offset,
                block.text.len,
            ) catch return null;
            input_offset = block.span.raw_end;
            continue;
        }
        input_offset += 1;
        output_offset = std.math.add(usize, output_offset, 1) catch return null;
    }
    return output_offset;
}

test "countLines counts lines with and without trailing newline" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("foo"));
    try std.testing.expectEqual(@as(usize, 1), countLines("foo\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("foo\nbar"));
    try std.testing.expectEqual(@as(usize, 2), countLines("foo\nbar\n"));
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
}

test "formatPlaceholder singular and plural" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[Pasted text #1, 1 line]", try formatPlaceholder(&buf, 1, 1));
    try std.testing.expectEqualStrings("[Pasted text #42, 17 lines]", try formatPlaceholder(&buf, 42, 17));
}

test "shouldUsePlaceholder matches large paste threshold" {
    try std.testing.expect(!shouldUsePlaceholder("hello", 0));
    try std.testing.expect(!shouldUsePlaceholder("x" ** large_paste_char_threshold, 0));
    try std.testing.expect(shouldUsePlaceholder("x" ** (large_paste_char_threshold + 1), 0));
    try std.testing.expect(!shouldUsePlaceholder("\xc3\xa9" ** large_paste_char_threshold, 0));
    try std.testing.expect(shouldUsePlaceholder("\xc3\xa9" ** (large_paste_char_threshold + 1), 0));
}

test "expand substitutes placeholder for real text" {
    const alloc = std.testing.allocator;
    var blocks: std.ArrayList(PastedBlock) = .empty;
    defer deinitBlocks(alloc, &blocks);
    const input = "prefix [Pasted text #1, 2 lines] suffix";
    const start = "prefix ".len;
    try blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.dupe(u8, "hello\nworld"),
        .line_count = 2,
        .span = .{
            .raw_start = start,
            .raw_end = start + "[Pasted text #1, 2 lines]".len,
        },
    });

    const result = try expand(alloc, input, blocks.items);
    defer if (result.owned) alloc.free(result.text);
    try std.testing.expectEqualStrings("prefix hello\nworld suffix", result.text);
    try std.testing.expect(result.owned);
}

test "expand with no placeholder returns original slice unowned" {
    const alloc = std.testing.allocator;
    var blocks: std.ArrayList(PastedBlock) = .empty;
    defer deinitBlocks(alloc, &blocks);

    const result = try expand(alloc, "nothing to replace", blocks.items);
    try std.testing.expect(!result.owned);
    try std.testing.expectEqualStrings("nothing to replace", result.text);
}

test "expand preserves unknown placeholder ids verbatim" {
    const alloc = std.testing.allocator;
    var blocks: std.ArrayList(PastedBlock) = .empty;
    defer deinitBlocks(alloc, &blocks);
    try blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.dupe(u8, "X"),
        .line_count = 1,
        .span = .{
            .raw_start = "before [Pasted text #9, 4 lines] ".len,
            .raw_end = "before [Pasted text #9, 4 lines] [Pasted text #1, 1 line]".len,
        },
    });

    const result = try expand(alloc, "before [Pasted text #9, 4 lines] [Pasted text #1, 1 line]", blocks.items);
    defer if (result.owned) alloc.free(result.text);
    try std.testing.expectEqualStrings("before [Pasted text #9, 4 lines] X", result.text);
}

test "expanded lengths count registered backing text without allocating" {
    const alloc = std.testing.allocator;
    const placeholder = "[Pasted text #1, 1 line]";
    const input = "ab" ++ placeholder ++ "cd";
    var blocks: std.ArrayList(PastedBlock) = .empty;
    defer deinitBlocks(alloc, &blocks);
    try blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.dupe(u8, "expanded"),
        .line_count = 1,
        .span = .{
            .raw_start = "ab".len,
            .raw_end = "ab".len + placeholder.len,
        },
    });

    try std.testing.expectEqual(
        @as(?usize, "abexpandedcd".len),
        expandedLen(input, blocks.items),
    );
    try std.testing.expectEqual(
        @as(?usize, "expanded".len),
        expandedRangeLen(
            input,
            blocks.items,
            "ab".len,
            "ab".len + placeholder.len,
        ),
    );
}

test "expand ignores typed lookalikes with a registered id" {
    const alloc = std.testing.allocator;
    const registered = "[Pasted text #1, 1 line]";
    const input = registered ++ " typed [Pasted text #1, 999 lines]";
    var blocks: std.ArrayList(PastedBlock) = .empty;
    defer deinitBlocks(alloc, &blocks);
    try blocks.append(alloc, .{
        .id = 1,
        .text = try alloc.dupe(u8, "original"),
        .line_count = 1,
        .span = .{ .raw_start = 0, .raw_end = registered.len },
    });

    const result = try expand(alloc, input, blocks.items);
    defer if (result.owned) alloc.free(result.text);
    try std.testing.expectEqualStrings("original typed [Pasted text #1, 999 lines]", result.text);
}

test "paste collapse line threshold is opt in and counts normalized logical lines" {
    try std.testing.expect(!shouldUsePlaceholder("a\nb\nc\n", 0));
    try std.testing.expect(!shouldUsePlaceholder("a\nb", 3));
    try std.testing.expect(!shouldUsePlaceholder("a\nb\nc\n", 3));
    try std.testing.expect(shouldUsePlaceholder("a\nb\nc\nd\n", 3));
    try std.testing.expect(!shouldUsePlaceholder("", 1));
    try std.testing.expect(!shouldUsePlaceholder("\n", 1));
    try std.testing.expect(shouldUsePlaceholder("\n\n", 1));
    try std.testing.expect(!shouldUsePlaceholder("é\n界\n", 2));
    var crlf = "a\r\nb\rc\r\n".*;
    const normalized = @import("../shared/text_utils.zig").normalizeLineEndingsInPlace(&crlf);
    try std.testing.expect(!shouldUsePlaceholder(normalized, 3));
    try std.testing.expect(shouldUsePlaceholder(normalized, 2));
    try std.testing.expect(shouldUsePlaceholder("x" ** 1001, 10));
}
