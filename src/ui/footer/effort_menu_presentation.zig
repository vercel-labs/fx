//! The `/effort` menu in the footer, drawn with the shared menu frame: an
//! `effort · <model>` title, then one row per reasoning effort level with the
//! one in use marked `current`. When the levels do not all fit, the list
//! scrolls with the highlight.

const std = @import("std");
const effort_menu = @import("../../core/input/effort_menu.zig");
const menu_frame = @import("menu_frame.zig");
const render_input = @import("render_input.zig");
const types = @import("../../core/shared/types.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Projection = render_input.EffortMenuProjection;

/// The title and the blank row under it.
const header_rows: u16 = 2;
const current_label = "current";
pub const max_inline_rows: u16 = header_rows + effort_menu.max_options;

pub fn menuRowCount(projection: Projection, row_budget: u16) u16 {
    return frameLayout(projection, row_budget).row_count;
}

pub fn visibleItems(projection: Projection, row_budget: u16) u16 {
    return frameLayout(projection, row_budget).visible_items;
}

/// The first level shown: `projection.window_start`, moved only as far as
/// it takes to show the highlighted level.
pub fn windowStart(projection: Projection, row_budget: u16) usize {
    return frameLayout(projection, row_budget).window_start;
}

pub fn composeEffortMenuRow(
    alloc: Allocator,
    projection: Projection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    var title_buf: [160]u8 = undefined;
    const title = if (projection.model.len > 0)
        std.mem.print(&title_buf, "effort · {s}", .{projection.model}) catch "effort"
    else
        "effort";
    return menu_frame.composeRow(alloc, .{
        .title = title,
        .ctx = &projection,
        .item_count = projection.levels.len,
        .column_count = 2,
        .cell = cell,
        .selected = projection.selected,
        .window_start = projection.window_start,
        .list_cap = listCap(projection, row_budget),
    }, row_index, width, row_budget);
}

/// List rows within `row_budget`; a budget too short for the title gives
/// every row to the list.
fn listCap(projection: Projection, row_budget: u16) u16 {
    const rows = if (row_budget > header_rows) row_budget - header_rows else row_budget;
    return @min(@as(u16, @intCast(@max(projection.levels.len, 1))), rows);
}

fn frameLayout(projection: Projection, row_budget: u16) menu_frame.Layout {
    return menu_frame.listLayout(projection.levels.len, projection.selected, projection.window_start, listCap(projection, row_budget), row_budget);
}

fn cell(ctx: *const anyopaque, item: usize, column: usize, _: []u8) []const u8 {
    const projection: *const Projection = @ptrCast(@alignCast(ctx));
    if (item >= projection.levels.len) return "";
    if (column == 0) return projection.levels[item].displayLabel();
    return if (item == projection.current) current_label else "";
}

test "effort menu draws the shared frame with the model after the title" {
    const alloc = std.testing.allocator;
    const levels = [_]types.ReasoningEffort{ .auto, .literal("low"), .literal("high") };
    const projection: Projection = .{ .model = "provider/model", .levels = &levels, .selected = 1, .current = 0 };
    const rows = menuRowCount(projection, max_inline_rows);
    try std.testing.expectEqual(@as(u16, 5), rows);

    var grid = try vt_emulator.Grid.init(alloc, 60, rows);
    defer grid.deinit();
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeEffortMenuRow(alloc, projection, row_index, 60, max_inline_rows);
        defer row.deinit(alloc);
        if (row_index == 3) try std.testing.expect(std.mem.find(u8, row.items, ui_render.selected_completion_style) != null);
        if (row_index == 2) try std.testing.expect(std.mem.find(u8, row.items, ui_render.selected_completion_style) == null);
        var cursor_buf: [32]u8 = undefined;
        try grid.feed(try std.mem.print(&cursor_buf, "\x1b[{d};1H", .{row_index + 1}));
        try grid.feed(row.items);
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    const expected = [_][]const u8{ "effort · provider/model", "", "  default      current", "  low", "  high" };
    for (expected, 1..) |line, at| {
        text.clearRetainingCapacity();
        try grid.rowTextTrimmed(@intCast(at), &text);
        try std.testing.expectEqualStrings(line, text.items);
    }
}
