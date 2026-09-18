//! Durable display metadata owned by a user turn, independent of terminal rendering.
const std = @import("std");

/// Hidden byte range in the complete submitted text. The id identifies its paste.
/// Persisted with the text so resume does not need composer state or heuristics.
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

pub fn valid(text: []const u8, spans: []const CollapsedRange) bool {
    var previous_end: usize = 0;
    for (spans) |span| {
        if (span.id == 0 or span.start < previous_end or span.start >= span.end or span.end > text.len) return false;
        if (!std.unicode.utf8ValidateSlice(text[span.start..span.end])) return false;
        previous_end = span.end;
    }
    return true;
}

test "paste display rejects overlapping out of range and split Unicode spans" {
    const text = "aéz";
    try std.testing.expect(!valid(text, &.{.{ .id = 1, .start = 0, .end = 5 }}));
    try std.testing.expect(!valid(text, &.{.{ .id = 1, .start = 2, .end = 3 }}));
    try std.testing.expect(!valid(text, &.{ .{ .id = 1, .start = 0, .end = 3 }, .{ .id = 2, .start = 1, .end = 4 } }));
    try std.testing.expect(valid(text, &.{.{ .id = 1, .start = 1, .end = 3 }}));
}
