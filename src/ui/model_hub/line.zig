//! One row of the model hub, built left to right within a cell budget.

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;

pub const Line = struct {
    alloc: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    width: usize,
    used: usize = 0,

    pub fn init(alloc: Allocator, width: usize) Line {
        return .{ .alloc = alloc, .width = width };
    }

    pub fn deinit(self: *Line) void {
        self.bytes.deinit(self.alloc);
    }

    pub fn remaining(self: *const Line) usize {
        return self.width -| self.used;
    }

    /// Text fx wrote itself, clipped at the budget.
    pub fn put(self: *Line, style: []const u8, text: []const u8) !void {
        try self.putClipped(style, text, self.remaining());
    }

    /// Text from a catalog or settings: control bytes escaped, the end
    /// ellipsized to at most `max` cells.
    pub fn putUntrusted(self: *Line, style: []const u8, text: []const u8, max: usize) !void {
        var encoded = try text_utils.encodeTerminalSafeInline(self.alloc, text, 1024);
        defer encoded.deinit(self.alloc);
        const budget = @min(max, self.remaining());
        if (budget == 0) return;
        const visible = display_width.visibleWidth(encoded.bytes);
        if (visible <= budget) return self.putClipped(style, encoded.bytes, budget);
        if (budget == 1) return self.putClipped(style, "…", 1);
        try self.putClipped(style, display_width.prefixByWidth(encoded.bytes, budget - 1), budget - 1);
        try self.putClipped(style, "…", 1);
    }

    fn putClipped(self: *Line, style: []const u8, text: []const u8, max: usize) !void {
        const budget = @min(max, self.remaining());
        if (budget == 0 or text.len == 0) return;
        const clipped = display_width.prefixByWidth(text, budget);
        if (style.len > 0) try self.bytes.appendSlice(self.alloc, style);
        try self.bytes.appendSlice(self.alloc, clipped);
        if (style.len > 0) try self.bytes.appendSlice(self.alloc, ui_render.reset_style);
        self.used += display_width.visibleWidth(clipped);
    }

    pub fn spaces(self: *Line, count: usize) !void {
        const n = @min(count, self.remaining());
        try self.bytes.appendNTimes(self.alloc, ' ', n);
        self.used += n;
    }

    pub fn padTo(self: *Line, column: usize) !void {
        if (column > self.used) try self.spaces(column - self.used);
    }

    /// Puts `text` so it ends at the budget's right edge, when it fits
    /// after `gap` cells of space.
    pub fn putRight(self: *Line, style: []const u8, text: []const u8, gap: usize) !bool {
        const visible = display_width.visibleWidth(text);
        if (visible == 0 or self.remaining() < visible + gap) return false;
        try self.padTo(self.width - visible);
        try self.put(style, text);
        return true;
    }
};

test "lines clip at their budget and escape untrusted text" {
    var line: Line = .init(std.testing.allocator, 8);
    defer line.deinit();
    try line.put("", "ab");
    try line.putUntrusted("", "c\x1bdefghij", 10);
    try std.testing.expectEqual(@as(usize, 8), line.used);
    try std.testing.expect(std.mem.findScalar(u8, line.bytes.items, 0x1b) == null);
    try std.testing.expect(!try line.putRight("", "x", 0));
}
