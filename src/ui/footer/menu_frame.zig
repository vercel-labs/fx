//! Shared layout for inline catalog menus.
//!
//! A frame is a gray title row (with an optional active tab), a blank row,
//! and a fixed-height list. Every item is gray except the selected one, which
//! is bright and bold; there is no marker glyph. Columns are sized to their
//! content with a gap that shrinks on narrow terminals, and then a chosen
//! flex column gives up width. Hidden items below the window show as a
//! `↓ N more` row, and an empty list shows a message and a hint.
//!
//! The footer draws the dividers around the menu and the hint row, so the
//! frame never does.

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;

pub const max_columns = 4;
const cell_buffer_len = 256;
const row_indent: usize = 2;
const widest_column_gap: usize = 6;
const narrowest_column_gap: usize = 2;
/// Narrowest the flex column gets before the last column drops for it.
const min_flex_width: usize = 16;
/// The title row and the blank row under it.
const header_rows: u16 = 2;
const tab_gap = "   ";

/// Returns the text of one cell. The result may point into `buf`, into the
/// caller's data, or at static text, and must stay valid until the next call
/// for the same column.
pub const CellFn = *const fn (ctx: *const anyopaque, item: usize, column: usize, buf: []u8) []const u8;

pub const Spec = struct {
    title: []const u8,
    /// The active tab, drawn as `< name >` after the title.
    active_tab: ?[]const u8 = null,
    ctx: *const anyopaque,
    item_count: usize,
    /// Between 1 and `max_columns`.
    column_count: usize,
    cell: CellFn,
    /// The column that gives up width when the row does not fit after the
    /// gaps shrink, usually a description. Without one, the last column
    /// clips at the edge.
    flex_column: ?usize = null,
    selected: usize = 0,
    /// The caller's remembered window start; the frame keeps the selection
    /// inside the window.
    window_start: usize = 0,
    /// List rows the menu holds even when a filter leaves fewer items.
    list_cap: u16,
    empty_message: []const u8 = "",
    empty_hint: []const u8 = "",
};

pub const Layout = struct {
    show_header: bool = false,
    row_count: u16 = 0,
    list_rows: u16 = 0,
    visible_items: u16 = 0,
    window_start: usize = 0,
    hidden_below: usize = 0,
};

/// Rows a frame uses within `row_budget`, and which items it shows.
pub fn layout(spec: Spec, row_budget: u16) Layout {
    return listLayout(spec.item_count, spec.selected, spec.window_start, spec.list_cap, row_budget);
}

/// The same layout from counts alone, for callers that size or navigate a
/// menu before they have its cells.
pub fn listLayout(item_count: usize, selected: usize, window_start: usize, list_cap: u16, row_budget: u16) Layout {
    if (row_budget == 0) return .{};
    const show_header = row_budget > header_rows;
    const header: u16 = if (show_header) header_rows else 0;
    const list_rows = @min(@max(list_cap, 1), row_budget - header);

    var result: Layout = .{
        .show_header = show_header,
        .row_count = header + list_rows,
        .list_rows = list_rows,
    };
    if (item_count == 0) return result;

    const overflows = item_count > list_rows;
    const visible: u16 = if (overflows and list_rows > 1) list_rows - 1 else @intCast(@min(item_count, list_rows));
    const clamped_selection = @min(selected, item_count - 1);
    const start = list_window.updateEdgeStart(window_start, item_count, clamped_selection, visible);
    result.visible_items = visible;
    result.window_start = start;
    result.hidden_below = item_count -| (start + visible);
    return result;
}

/// Layout and column widths for one paint, so a caller drawing every row
/// measures the cells once.
pub const Prepared = struct {
    layout: Layout,
    fit: ColumnFit,
    width: u16,
};

pub fn prepare(spec: Spec, width: u16, row_count: u16) Prepared {
    const budget = contentWidth(width);
    return .{
        .layout = layout(spec, row_count),
        .fit = fitColumns(spec, budget -| rowIndent(budget)),
        .width = width,
    };
}

/// One terminal-safe row of the frame. The caller owns the returned list.
pub fn composeRow(alloc: Allocator, spec: Spec, index: u16, width: u16, row_count: u16) !std.ArrayList(u8) {
    return composePreparedRow(alloc, spec, prepare(spec, width, row_count), index);
}

/// One row from a `prepare` result. The caller owns the returned list.
pub fn composePreparedRow(alloc: Allocator, spec: Spec, prepared: Prepared, index: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const width = prepared.width;
    const frame = prepared.layout;
    if (width == 0 or index >= frame.row_count) return row;

    var list_index = index;
    if (frame.show_header) {
        if (index == 0) {
            try appendTitle(alloc, &row, spec, width);
            return row;
        }
        if (index == 1) return row;
        list_index = index - header_rows;
    }

    if (spec.item_count == 0) {
        const text = switch (list_index) {
            0 => spec.empty_message,
            1 => spec.empty_hint,
            else => "",
        };
        if (text.len > 0) try appendDimLine(alloc, &row, text, width);
        return row;
    }

    if (list_index < frame.visible_items) {
        try appendItem(alloc, &row, spec, prepared.fit, frame.window_start + list_index, width);
        return row;
    }

    if (list_index + 1 == frame.list_rows and frame.hidden_below > 0) {
        var buf: [48]u8 = undefined;
        const more = std.mem.print(&buf, "↓ {d} more", .{frame.hidden_below}) catch "↓ more";
        try appendDimLine(alloc, &row, more, width);
    }
    return row;
}

fn contentWidth(width: u16) usize {
    // Leave the last cell empty so a full row never wraps.
    return @as(usize, width) -| 1;
}

fn rowIndent(budget: usize) usize {
    return if (budget > row_indent) row_indent else 0;
}

fn appendTitle(alloc: Allocator, row: *std.ArrayList(u8), spec: Spec, width: u16) !void {
    const budget = contentWidth(width);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendTerminalSafeSingleLine(alloc, row, spec.title, budget);
    try row.appendSlice(alloc, ui_render.reset_style);

    const tab = spec.active_tab orelse return;
    const used = display_width.visibleWidthIgnoringAnsi(row.items);
    // `< ` and ` >` around the tab name.
    const decoration = tab_gap.len + 4;
    if (used + decoration >= budget) return;
    try row.appendSlice(alloc, tab_gap);
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try row.appendSlice(alloc, "< ");
    try row_text.appendTerminalSafeSingleLine(alloc, row, tab, budget - used - decoration);
    try row.appendSlice(alloc, " >");
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendDimLine(alloc: Allocator, row: *std.ArrayList(u8), text: []const u8, width: u16) !void {
    const budget = contentWidth(width);
    const indent = rowIndent(budget);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendNTimes(alloc, ' ', indent);
    try row_text.appendTerminalSafeSingleLine(alloc, row, text, budget - indent);
    try row.appendSlice(alloc, ui_render.reset_style);
}

const ColumnFit = struct {
    widths: [max_columns]usize = @splat(0),
    gap: usize = widest_column_gap,
    /// Columns drawn; the last one drops when the flex column would get too
    /// narrow to read.
    columns: usize = 0,
};

/// Sizes columns to the widest cell of every item, so they hold still while
/// the selection scrolls. When a row does not fit, the gaps shrink first,
/// then the last column drops if the flex column would fall below
/// `min_flex_width`, and then the flex column clips.
fn fitColumns(spec: Spec, available: usize) ColumnFit {
    const columns = @min(spec.column_count, max_columns);
    var fit: ColumnFit = .{ .columns = columns };
    var buf: [cell_buffer_len]u8 = undefined;
    for (0..spec.item_count) |item| {
        for (0..columns) |column| {
            const cell = spec.cell(spec.ctx, item, column, &buf);
            fit.widths[column] = @max(fit.widths[column], display_width.visibleWidth(cell));
        }
    }
    if (columns <= 1) {
        fit.widths[0] = @min(fit.widths[0], available);
        return fit;
    }

    while (fit.gap > narrowest_column_gap and neededWidth(fit) > available) fit.gap -= 1;

    const flex = spec.flex_column orelse return fit;
    if (flex >= columns) return fit;
    var needed = neededWidth(fit);
    if (needed <= available) return fit;
    if (flex + 1 < fit.columns and fit.widths[flex] -| (needed - available) < min_flex_width) {
        fit.columns -= 1;
        needed = neededWidth(fit);
        if (needed <= available) return fit;
    }
    fit.widths[flex] -|= needed - available;
    return fit;
}

fn neededWidth(fit: ColumnFit) usize {
    var total: usize = 0;
    for (fit.widths[0..fit.columns]) |column_width| total += column_width;
    return total + fit.gap * (fit.columns -| 1);
}

fn appendItem(alloc: Allocator, row: *std.ArrayList(u8), spec: Spec, fit: ColumnFit, item: usize, width: u16) !void {
    const budget = contentWidth(width);
    const indent = rowIndent(budget);
    const columns = fit.columns;

    const style = if (item == @min(spec.selected, spec.item_count - 1))
        ui_render.selected_completion_style
    else
        ui_render.dim_style;
    try row.appendSlice(alloc, style);
    try row.appendNTimes(alloc, ' ', indent);

    var buffers: [max_columns][cell_buffer_len]u8 = undefined;
    var column_start = indent;
    for (0..columns) |column| {
        const cell = spec.cell(spec.ctx, item, column, &buffers[column]);
        const last = column + 1 == columns;
        const used = display_width.visibleWidthIgnoringAnsi(row.items);
        const cell_budget = if (last) budget -| used else @min(fit.widths[column], budget -| used);
        if (cell_budget == 0) break;
        try row_text.appendTerminalSafeSingleLine(alloc, row, cell, cell_budget);
        if (last) break;
        column_start += fit.widths[column] + fit.gap;
        if (column_start >= budget) break;
        try row_text.appendSpacesToColumn(alloc, row, column_start);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
}

const TestMenu = struct {
    rows: []const []const []const u8,

    fn cell(ctx: *const anyopaque, item: usize, column: usize, _: []u8) []const u8 {
        const menu: *const TestMenu = @ptrCast(@alignCast(ctx));
        const cells = menu.rows[item];
        return if (column < cells.len) cells[column] else "";
    }

    fn spec(menu: *const TestMenu, columns: usize, list_cap: u16) Spec {
        return .{
            .title = "commands",
            .ctx = menu,
            .item_count = menu.rows.len,
            .column_count = columns,
            .cell = cell,
            .list_cap = list_cap,
        };
    }
};

fn plainRow(alloc: Allocator, spec: Spec, index: u16, width: u16, row_count: u16) ![]u8 {
    var row = try composeRow(alloc, spec, index, width, row_count);
    defer row.deinit(alloc);
    var plain: std.ArrayList(u8) = .empty;
    errdefer plain.deinit(alloc);
    var i: usize = 0;
    while (i < row.items.len) {
        if (row.items[i] == 0x1b) {
            i = display_width.ansiSequenceEnd(row.items, i);
            continue;
        }
        try plain.append(alloc, row.items[i]);
        i += 1;
    }
    return plain.toOwnedSlice(alloc);
}

fn expectPlainRow(spec: Spec, index: u16, width: u16, row_count: u16, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const plain = try plainRow(alloc, spec, index, width, row_count);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(expected, plain);
}

const command_rows = [_][]const []const u8{
    &.{ "/help", "show slash commands", "general" },
    &.{ "/clear", "start a fresh conversation", "general" },
    &.{ "/resume", "resume a saved session", "session" },
};

test "menu frame draws a gray title, a blank row, and content-sized columns" {
    const menu: TestMenu = .{ .rows = &command_rows };
    const spec = menu.spec(3, 5);
    const frame = layout(spec, 20);
    try std.testing.expectEqual(@as(u16, 7), frame.row_count);
    try std.testing.expectEqual(@as(u16, 3), frame.visible_items);

    try expectPlainRow(spec, 0, 80, frame.row_count, "commands");
    try expectPlainRow(spec, 1, 80, frame.row_count, "");
    try expectPlainRow(spec, 2, 80, frame.row_count, "  /help        show slash commands             general");
    try expectPlainRow(spec, 3, 80, frame.row_count, "  /clear       start a fresh conversation      general");
    try expectPlainRow(spec, 4, 80, frame.row_count, "  /resume      resume a saved session          session");
}

test "menu frame keeps its height while a filter leaves fewer items" {
    const one = [_][]const []const u8{command_rows[0]};
    const filtered: TestMenu = .{ .rows = &one };
    const full: TestMenu = .{ .rows = &command_rows };
    try std.testing.expectEqual(layout(full.spec(3, 5), 20).row_count, layout(filtered.spec(3, 5), 20).row_count);
    try expectPlainRow(filtered.spec(3, 5), 3, 80, 7, "");
}

test "menu frame marks only the selected row bright, with no marker glyph" {
    const alloc = std.testing.allocator;
    const menu: TestMenu = .{ .rows = &command_rows };
    var spec = menu.spec(3, 5);
    spec.selected = 1;

    var selected = try composeRow(alloc, spec, 3, 80, 7);
    defer selected.deinit(alloc);
    var other = try composeRow(alloc, spec, 2, 80, 7);
    defer other.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, selected.items, ui_render.selected_completion_style));
    try std.testing.expect(std.mem.startsWith(u8, other.items, ui_render.dim_style));
    try std.testing.expect(std.mem.find(u8, selected.items, "›") == null);
    try std.testing.expect(std.mem.find(u8, selected.items, "❯") == null);
}

test "menu frame shows hidden items below as a more row" {
    const many = [_][]const []const u8{
        &.{"one"}, &.{"two"}, &.{"three"}, &.{"four"}, &.{"five"}, &.{"six"},
    };
    const menu: TestMenu = .{ .rows = &many };
    const spec = menu.spec(1, 4);
    const frame = layout(spec, 20);
    try std.testing.expectEqual(@as(u16, 3), frame.visible_items);
    try std.testing.expectEqual(@as(usize, 3), frame.hidden_below);
    try expectPlainRow(spec, 4, 40, frame.row_count, "  three");
    try expectPlainRow(spec, 5, 40, frame.row_count, "  ↓ 3 more");

    var scrolled = spec;
    scrolled.selected = 5;
    const end = layout(scrolled, 20);
    try std.testing.expectEqual(@as(usize, 3), end.window_start);
    try std.testing.expectEqual(@as(usize, 0), end.hidden_below);
    try expectPlainRow(scrolled, 4, 40, end.row_count, "  six");
    try expectPlainRow(scrolled, 5, 40, end.row_count, "");
}

test "menu frame shows the active tab and an empty list message" {
    const none = [_][]const []const u8{};
    const menu: TestMenu = .{ .rows = &none };
    var spec = menu.spec(2, 4);
    spec.title = "skills";
    spec.active_tab = "codex";
    spec.empty_message = "no skills.";
    spec.empty_hint = "add one to ~/.fx/skills or press tab.";
    try expectPlainRow(spec, 0, 80, 6, "skills   < codex >");
    try expectPlainRow(spec, 2, 80, 6, "  no skills.");
    try expectPlainRow(spec, 3, 80, 6, "  add one to ~/.fx/skills or press tab.");
    try expectPlainRow(spec, 4, 80, 6, "");
}

test "menu frame shrinks the gap, then the flex column, then drops the last column" {
    const models = [_][]const []const u8{
        &.{ "claude-opus-4.7", "1M ctx · reasoning", "current" },
        &.{ "gpt-5.6-sol", "400k ctx · reasoning", "" },
    };
    const menu: TestMenu = .{ .rows = &models };
    var spec = menu.spec(3, 4);
    spec.flex_column = 1;
    // Wide: 6-cell gaps.
    try expectPlainRow(spec, 2, 80, 6, "  claude-opus-4.7      1M ctx · reasoning        current");
    // Narrower: gaps fall to 2 and the flex column ellipsizes.
    const narrow = try plainRow(std.testing.allocator, spec, 2, 46, 6);
    defer std.testing.allocator.free(narrow);
    try std.testing.expect(display_width.visibleWidth(narrow) <= 45);
    try std.testing.expect(std.mem.startsWith(u8, narrow, "  claude-opus-4.7  "));
    try std.testing.expect(std.mem.find(u8, narrow, "…") != null);
    try std.testing.expect(std.mem.endsWith(u8, narrow, "current"));
    // Narrowest: the flex column would fall under its minimum, so the last
    // column drops instead.
    const narrowest = try plainRow(std.testing.allocator, spec, 2, 40, 6);
    defer std.testing.allocator.free(narrowest);
    try std.testing.expectEqualStrings("  claude-opus-4.7  1M ctx · reasoning", narrowest);
}

test "menu frame drops the last column before the flex column gets unreadable" {
    const rows = [_][]const []const u8{
        &.{ "fx-dogfood-operator", "orchestrate continuous dogfood issue hunting", "workspace .fx" },
        &.{ "/model", "choose what model and reasoning effort to use", "Model" },
    };
    const menu: TestMenu = .{ .rows = &rows };
    var spec = menu.spec(3, 4);
    spec.flex_column = 1;
    const plain = try plainRow(std.testing.allocator, spec, 2, 48, 6);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "workspace") == null);
    try std.testing.expect(std.mem.find(u8, plain, "orchestrate continuous") != null);
    try std.testing.expect(display_width.visibleWidth(plain) <= 47);
    // Wide enough for all three columns, the last one stays.
    try expectPlainRow(spec, 3, 120, 6, "  /model                   choose what model and reasoning effort to use      Model");
}

test "menu frame drops the header before the list on a tiny budget" {
    const menu: TestMenu = .{ .rows = &command_rows };
    const frame = layout(menu.spec(3, 5), 2);
    try std.testing.expect(!frame.show_header);
    try std.testing.expectEqual(@as(u16, 2), frame.row_count);
    try expectPlainRow(menu.spec(3, 5), 0, 80, 2, "  /help        show slash commands             general");
}
