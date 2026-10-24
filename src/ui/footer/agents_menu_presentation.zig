//! The instance list `/agents` and Alt+↑ open: one row per open instance,
//! such as "fx 3 · Fix the login bug · reviewer · needs approval".

const std = @import("std");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const AgentsMenuProjection = render_input.AgentsMenuProjection;

/// The most rows the list takes before it scrolls.
pub const max_inline_rows: u16 = 10;

const untitled = "new session";

fn indentWidth(width: u16) u16 {
    return if (width > 4) 2 else 0;
}

pub fn menuRowCount(projection: AgentsMenuProjection, row_budget: u16) u16 {
    return @intCast(@min(row_budget, projection.rows.len));
}

/// The first row shown: `projection.window_start`, moved only as far as it
/// takes to show the selected row, so the list scrolls at its edges.
pub fn windowStart(projection: AgentsMenuProjection, row_budget: u16) usize {
    return picker_presentation.updateEdgeScrollPickerWindowStart(
        projection.window_start,
        projection.rows.len,
        projection.selected,
        row_budget,
    );
}

/// The text of `row`, before it is clipped to the footer's width. The caller
/// owns it.
pub fn rowText(alloc: Allocator, row: render_input.AgentsMenuRow) ![]u8 {
    return alloc.print("fx {d}{s} · {s} · {s} · {s}", .{
        row.number,
        if (row.on_screen) " (on screen)" else "",
        if (row.title.len > 0) row.title else untitled,
        row.profile,
        row.state,
    });
}

pub fn composeAgentsMenuRow(
    alloc: Allocator,
    projection: AgentsMenuProjection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (width == 0 or row_index >= row_budget) return row;
    const index = windowStart(projection, row_budget) + row_index;
    if (index >= projection.rows.len) return row;
    const text = try rowText(alloc, projection.rows[index]);
    defer alloc.free(text);
    const indent = indentWidth(width);
    try row.appendNTimes(alloc, ' ', indent);
    try row.appendSlice(alloc, if (index == projection.selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, text, width - indent);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub const hint_variants = [_][]const u8{
    "↑↓ navigate     enter show     esc close",
    "↑↓ navigate  enter show  esc close",
    "↑↓ move  enter  esc",
    "enter show  esc close",
};

/// The visible text of row `row_index`, and whether it is selected. Caller owns the text.
fn testRow(projection: AgentsMenuProjection, row_index: u16, width: u16, row_budget: u16) !struct { text: []u8, selected: bool } {
    const alloc = std.testing.allocator;
    var row = try composeAgentsMenuRow(alloc, projection, row_index, width, row_budget);
    defer row.deinit(alloc);
    const selected = std.mem.find(u8, row.items, ui_render.selected_completion_style) != null;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var index: usize = 0;
    while (index < row.items.len) {
        if (row.items[index] == 0x1b) {
            index = std.mem.findScalarPos(u8, row.items, index, 'm').? + 1;
            continue;
        }
        try text.append(alloc, row.items[index]);
        index += 1;
    }
    return .{ .text = try text.toOwnedSlice(alloc), .selected = selected };
}

test "the instance list shows each instance's number, title, profile, and state" {
    const rows = [_]render_input.AgentsMenuRow{
        .{ .number = 1, .title = "Fix the login bug", .profile = "main", .state = "working", .on_screen = true },
        .{ .number = 2, .title = "", .profile = "reviewer", .state = "needs approval", .on_screen = false },
    };
    const projection: AgentsMenuProjection = .{ .rows = &rows, .selected = 1 };
    try std.testing.expectEqual(@as(u16, 2), menuRowCount(projection, max_inline_rows));
    const expected = [_][]const u8{
        "  fx 1 (on screen) · Fix the login bug · main · working",
        "  fx 2 · new session · reviewer · needs approval",
    };
    for (expected, 0..) |text, row_index| {
        const row = try testRow(projection, @intCast(row_index), 80, max_inline_rows);
        defer std.testing.allocator.free(row.text);
        try std.testing.expectEqualStrings(text, row.text);
        try std.testing.expectEqual(row_index == 1, row.selected);
    }
}

test "the instance list scrolls to keep the selected instance in view" {
    var rows: [5]render_input.AgentsMenuRow = undefined;
    for (&rows, 1..) |*row, number| row.* = .{ .number = number, .title = "t", .profile = "main", .state = "idle", .on_screen = false };
    var projection: AgentsMenuProjection = .{ .rows = &rows, .selected = 0 };
    try std.testing.expectEqual(@as(u16, 2), menuRowCount(projection, 2));
    projection.selected = 3;
    projection.window_start = windowStart(projection, 2);
    const top = try testRow(projection, 0, 80, 2);
    defer std.testing.allocator.free(top.text);
    const bottom = try testRow(projection, 1, 80, 2);
    defer std.testing.allocator.free(bottom.text);
    try std.testing.expectEqualStrings("  fx 3 · t · main · idle", top.text);
    try std.testing.expectEqualStrings("  fx 4 · t · main · idle", bottom.text);
    try std.testing.expect(bottom.selected);
}
