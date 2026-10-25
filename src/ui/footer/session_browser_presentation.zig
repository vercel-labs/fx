//! Compact navigation rows using the existing inline picker styles.
const std = @import("std");
const browser = @import("../../core/input/session_browser.zig");
const display_width = @import("../../core/shared/display_width.zig");
const input_presentation = @import("input_presentation.zig");
const render = @import("../render.zig");
const row_text = @import("row_text.zig");

pub fn rowCount(state: *const browser.State, budget: u16) u16 {
    return @intCast(@min(budget, @max(1, @min(state.count(), 20)) + 1));
}

pub fn composeRow(alloc: std.mem.Allocator, state: *const browser.State, index: u16, width: u16, budget: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0 or index >= budget) return row;
    if (index == 0) {
        try row.appendSlice(alloc, render.selected_completion_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, if (state.scope == .sessions) "Sessions" else "Subagents", width);
        try row.appendSlice(alloc, render.reset_style);
        return row;
    }
    const count = state.count();
    const total = rowCount(state, budget);
    if (state.loading or state.error_len > 0 or count == 0) {
        if (index != 1) return row;
        const text = if (state.error_len > 0) state.error_buf[0..state.error_len] else if (state.loading) "Loading…" else if (state.query_len > 0) "No matching sessions" else if (state.scope == .subagents) "No subagents in this session" else "No sessions yet";
        try row.appendSlice(alloc, render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
        try row.appendSlice(alloc, render.reset_style);
        return row;
    }
    const visible: usize = @max(1, total -| 1);
    const start = if (state.selected < state.window_start) state.selected else if (state.selected >= state.window_start + visible) state.selected + 1 - visible else state.window_start;
    const position = start + index - 1;
    const item = state.itemAt(position) orelse return row;
    const selected = position == state.selected;
    const style = if (selected) render.selected_completion_style else render.dim_style;

    var left: std.ArrayList(u8) = .empty;
    defer left.deinit(alloc);
    try left.appendSlice(alloc, "  ");
    for (0..@min(item.depth, 8)) |_| try left.appendSlice(alloc, "  ");
    if (item.current) try left.appendSlice(alloc, "• ");
    try left.appendSlice(alloc, item.title);
    if (item.meta.len > 0) {
        if (item.detail.len > 0) {
            try left.appendSlice(alloc, "  ");
            try left.appendSlice(alloc, item.detail);
        }
    } else {
        // Older callers set status/detail without meta. Preserve their
        // single-line shape; the remote browser uses meta for the right-aligned
        // age or state.
        if (item.status.len > 0) {
            try left.appendSlice(alloc, "  ");
            try left.appendSlice(alloc, item.status);
        }
        if (item.detail.len > 0) {
            try left.appendSlice(alloc, " · ");
            try left.appendSlice(alloc, item.detail);
        }
    }

    const meta_width = display_width.visibleWidth(item.meta);
    if (meta_width > 0 and width > meta_width + 10) {
        var clipped: std.ArrayList(u8) = .empty;
        defer clipped.deinit(alloc);
        try row_text.appendSingleLineEllipsized(alloc, &clipped, left.items, @as(usize, width) - meta_width - 2);
        try row.appendSlice(alloc, style);
        try row.appendSlice(alloc, clipped.items);
        try row_text.appendSpacesToColumn(alloc, &row, @as(usize, width) - meta_width);
        try row.appendSlice(alloc, item.meta);
        try row.appendSlice(alloc, render.reset_style);
        return row;
    }

    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, left.items, width);
    try row.appendSlice(alloc, render.reset_style);
    return row;
}

const filtered_hints = [_][]const u8{
    "up/down select   enter open   left back   esc clear filter",
    "up/down select  enter open  left back  esc clear filter",
    "up/down select  enter open  esc clear",
    "enter open  esc clear",
    "esc clear",
};

const unfiltered_hints = [_][]const u8{
    "up/down select   enter open   left back   esc close",
    "up/down select  enter open  left back  esc close",
    "up/down select  enter open  esc close",
    "enter open  esc close",
    "enter esc",
};

/// The key hint under the browser: Esc clears a filter before it closes.
pub fn composeHintRow(
    alloc: std.mem.Allocator,
    state: *const browser.State,
    width: u16,
    ctrl_c_pending: bool,
) !std.ArrayList(u8) {
    const variants: []const []const u8 = if (state.query_len > 0) &filtered_hints else &unfiltered_hints;
    return input_presentation.composeVariantHintRow(alloc, width, ctrl_c_pending, variants);
}

test "browser rows keep title and right-aligned meta only" {
    const alloc = std.testing.allocator;
    var state: browser.State = .{};
    defer state.close();
    state.open(.sessions);
    try state.replaceRows(alloc, &.{
        .{ .id = "abc123456789", .title = "session abc12345", .meta = "12m" },
        .{ .id = "current", .title = "Review the footer layout", .meta = "now", .current = true },
    });
    state.selected = 1;

    var first = try composeRow(alloc, &state, 1, 40, 10);
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, first.items, "session abc12345") != null);
    try std.testing.expect(std.mem.find(u8, first.items, "12m") != null);
    try std.testing.expect(std.mem.find(u8, first.items, "/Users/") == null);

    var selected = try composeRow(alloc, &state, 2, 40, 10);
    defer selected.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, selected.items, "• Review the footer layout") != null);
    try std.testing.expect(std.mem.find(u8, selected.items, "now") != null);
}
