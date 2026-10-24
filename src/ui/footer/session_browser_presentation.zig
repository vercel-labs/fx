//! Compact navigation rows using the existing inline picker styles.
const std = @import("std");
const browser = @import("../../core/input/session_browser.zig");
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
    try row.appendSlice(alloc, if (position == state.selected) render.selected_completion_style else render.dim_style);
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try text.writer.writeAll("  ");
    for (0..@min(item.depth, 8)) |_| try text.writer.writeAll("  ");
    if (item.current) try text.writer.writeAll("• ");
    try text.writer.writeAll(item.title);
    if (item.status.len > 0) try text.writer.print("  {s}", .{item.status});
    if (item.detail.len > 0) try text.writer.print(" · {s}", .{item.detail});
    try row_text.appendSingleLineEllipsized(alloc, &row, text.written(), width);
    try row.appendSlice(alloc, render.reset_style);
    return row;
}
