//! Presentation-only ranges in the complete submitted user text.
const std = @import("std");
const pasted_blocks = @import("pasted_blocks.zig");

pub const CollapsedRange = struct {
    id: usize,
    start: usize,
    end: usize,
};

/// Display-only metadata carried with a user turn, never provider content.
/// Owners duplicate and release it with the turn's text and images.
pub const Presentation = struct {
    collapsed_ranges: []const CollapsedRange = &.{},

    pub fn dupe(self: Presentation, alloc: std.mem.Allocator) !Presentation {
        return .{ .collapsed_ranges = try alloc.dupe(CollapsedRange, self.collapsed_ranges) };
    }

    pub fn deinit(self: Presentation, alloc: std.mem.Allocator) void {
        alloc.free(self.collapsed_ranges);
    }
};

/// Keep the configured line preview when there is a remainder to collapse.
/// Zero, or a paste collapsed only for its character count, keeps a full marker.
pub fn hidden_start(text: []const u8, preview_lines: u32) usize {
    if (preview_lines == 0) return 0;
    var lines: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte != '\n') continue;
        lines += 1;
        if (lines == preview_lines) return if (i + 1 < text.len) i + 1 else 0;
    }
    return 0;
}

pub fn valid(text: []const u8, spans: []const CollapsedRange) bool {
    var previous_end: usize = 0;
    for (spans) |span| {
        if (span.id == 0 or span.start < previous_end or span.start >= span.end or span.end > text.len) return false;
        if (!std.unicode.utf8ValidateSlice(text[span.start..span.end])) return false;
        previous_end = span.end;
    }
    return true;
}

/// Caller owns the result. Missing metadata denotes ordinary text.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, value: ?std.json.Value) !Presentation {
    const raw = value orelse return .{};
    var parsed = std.json.parseFromValue(Presentation, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    if (!valid(text, parsed.value.collapsed_ranges)) return error.InvalidSessionFormat;
    return parsed.value.dupe(alloc);
}

pub fn write(writer: *std.Io.Writer, presentation: Presentation) !void {
    if (presentation.collapsed_ranges.len == 0) return;
    try writer.writeAll(",\"presentation\":");
    try std.json.Stringify.value(presentation, .{}, writer);
}

/// Caller owns the result. Invalid metadata falls back to complete text.
pub fn collapse(alloc: std.mem.Allocator, text: []const u8, spans: []const CollapsedRange) ![]u8 {
    if (!valid(text, spans)) return alloc.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var offset: usize = 0;
    for (spans) |span| {
        try out.appendSlice(alloc, text[offset..span.start]);
        var buffer: [96]u8 = undefined;
        try out.appendSlice(alloc, try pasted_blocks.formatPlaceholder(&buffer, span.id, pasted_blocks.countLines(text[span.start..span.end])));
        offset = span.end;
    }
    try out.appendSlice(alloc, text[offset..]);
    return out.toOwnedSlice(alloc);
}

pub fn collapsedOffset(text: []const u8, spans: []const CollapsedRange, offset: usize) ?usize {
    var source: usize = 0;
    var target: usize = 0;
    for (spans) |span| {
        if (offset <= span.start) break;
        if (offset < span.end) return null;
        var buffer: [96]u8 = undefined;
        const placeholder = pasted_blocks.formatPlaceholder(&buffer, span.id, pasted_blocks.countLines(text[span.start..span.end])) catch return null;
        target += span.start - source + placeholder.len;
        source = span.end;
    }
    return target + offset - source;
}

test "paste display preserves surrounding text and literal lookalikes" {
    const text = "before a\nb\n after [Pasted text #1, 2 lines]";
    const spans = [_]CollapsedRange{.{ .id = 7, .start = 7, .end = 11 }};
    const collapsed = try collapse(std.testing.allocator, text, &spans);
    defer std.testing.allocator.free(collapsed);
    try std.testing.expectEqualStrings("before [Pasted text #7, 2 lines] after [Pasted text #1, 2 lines]", collapsed);
    try std.testing.expectEqual(@as(?usize, null), collapsedOffset(text, &spans, 9));
    try std.testing.expectEqual(@as(?usize, "before [Pasted text #7, 2 lines]".len), collapsedOffset(text, &spans, 11));
}

test "paste display rejects overlapping out of range and split Unicode spans" {
    const text = "aéz";
    try std.testing.expect(!valid(text, &.{.{ .id = 1, .start = 0, .end = 5 }}));
    try std.testing.expect(!valid(text, &.{.{ .id = 1, .start = 2, .end = 3 }}));
    try std.testing.expect(!valid(text, &.{ .{ .id = 1, .start = 0, .end = 3 }, .{ .id = 2, .start = 1, .end = 4 } }));
    try std.testing.expect(valid(text, &.{.{ .id = 1, .start = 1, .end = 3 }}));
}

test "paste display previews complete lines and collapses only the remainder" {
    const text = "first\né\nthird\nfourth\n";
    const start = hidden_start(text, 2);
    const spans = [_]CollapsedRange{.{ .id = 1, .start = start, .end = text.len }};
    const compact = try collapse(std.testing.allocator, text, &spans);
    defer std.testing.allocator.free(compact);
    try std.testing.expectEqualStrings("first\né\n[Pasted text #1, 2 lines]", compact);
    try std.testing.expectEqual(@as(?usize, 6), collapsedOffset(text, &spans, 6));
    try std.testing.expectEqual(@as(?usize, null), collapsedOffset(text, &spans, start + 1));
    try std.testing.expectEqual(@as(?usize, compact.len), collapsedOffset(text, &spans, text.len));
    try std.testing.expectEqual(@as(usize, 0), hidden_start(text, 0));
    try std.testing.expectEqual(@as(usize, 0), hidden_start(text, 4));
    try std.testing.expectEqual(@as(usize, 0), hidden_start("first\nsecond", 2));
    try std.testing.expectEqual(@as(usize, 2), hidden_start("\n\nlast", 2));
}

test "paste presentation accepts absent metadata and rejects malformed ranges" {
    const alloc = std.testing.allocator;
    const absent = try parse(alloc, "plain", null);
    defer absent.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), absent.collapsed_ranges.len);
    for ([_][]const u8{
        "{\"collapsed_ranges\":[{\"id\":1,\"start\":0,\"end\":9}]}",
        "{\"collapsed_ranges\":\"invalid\"}",
    }) |json| {
        var value = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer value.deinit();
        try std.testing.expectError(error.InvalidSessionFormat, parse(alloc, "plain", value.value));
    }
}
