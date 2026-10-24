//! The `/effort` menu in the footer, laid out like the `/model` menu: an
//! `Effort` title naming the model, then one row per reasoning effort level
//! with the one in use marked `current`. When the levels do not all fit, the
//! list scrolls with the highlight.

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const effort_menu = @import("../../core/input/effort_menu.zig");
const list_window = @import("../../core/shared/list_window.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Projection = render_input.EffortMenuProjection;

const header_rows: u16 = 1;
const gap_rows: u16 = 1;
const current_label = "current";
pub const max_inline_rows: u16 = header_rows + gap_rows + effort_menu.max_options;

const Layout = struct {
    show_header: bool = false,
    first_item_row: u16 = 0,
    visible_items: u16 = 0,

    /// The title and the gap under it come first; a short footer drops the
    /// gap, then the title, before it drops a level.
    fn build(projection: Projection, row_budget: u16) Layout {
        const count = projection.levels.len;
        if (row_budget == 0 or count == 0) return .{};
        if (row_budget == 1) return .{ .visible_items = 1 };
        const first_item_row: u16 = if (row_budget >= 3) header_rows + gap_rows else header_rows;
        return .{
            .show_header = true,
            .first_item_row = first_item_row,
            .visible_items = @intCast(@min(count, row_budget - first_item_row)),
        };
    }

    fn rowCount(self: Layout) u16 {
        return self.first_item_row + self.visible_items;
    }
};

pub fn menuRowCount(projection: Projection, row_budget: u16) u16 {
    return Layout.build(projection, row_budget).rowCount();
}

pub fn visibleItems(projection: Projection, row_budget: u16) u16 {
    return Layout.build(projection, row_budget).visible_items;
}

/// The first level shown: `projection.window_start`, moved only as far as
/// it takes to show the highlighted level.
pub fn windowStart(projection: Projection, row_budget: u16) usize {
    const visible = visibleItems(projection, row_budget);
    return list_window.updateEdgeStart(projection.window_start, projection.levels.len, projection.selected, @max(visible, 1));
}

pub fn composeEffortMenuRow(
    alloc: Allocator,
    projection: Projection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const layout = Layout.build(projection, row_budget);
    if (width == 0 or row_index >= layout.rowCount()) return row;
    if (layout.show_header and row_index == 0) return composeHeaderRow(alloc, projection, width);
    if (row_index < layout.first_item_row) return row;

    const index = windowStart(projection, row_budget) + (row_index - layout.first_item_row);
    if (index >= projection.levels.len) return row;
    const selected = index == projection.selected;
    const indent: usize = if (width <= 2) 0 else 2;
    try row.appendNTimes(alloc, ' ', indent);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    const label = projection.levels[index].displayLabel();
    const marker_column = indent + labelColumnWidth(projection) + 2;
    const show_marker = index == projection.current and marker_column + current_label.len <= width;
    try row_text.appendSingleLineEllipsized(alloc, &row, label, @as(usize, width) -| indent);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (show_marker) {
        try row_text.appendSpacesToColumn(alloc, &row, marker_column);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, current_label);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn composeHeaderRow(alloc: Allocator, projection: Projection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var title_buf: [32]u8 = undefined;
    const title = std.mem.print(&title_buf, "Effort {d}", .{projection.levels.len}) catch "Effort";
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try row_text.appendClipped(alloc, &row, title, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    const title_width = display_width.visibleWidth(title);
    if (projection.model.len > 0 and title_width + 2 < width) {
        try row.appendSlice(alloc, "  ");
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineMiddleEllipsized(alloc, &row, projection.model, width - title_width - 2);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn labelColumnWidth(projection: Projection) usize {
    var widest: usize = 0;
    for (projection.levels) |*level| widest = @max(widest, display_width.visibleWidth(level.displayLabel()));
    return widest;
}
