const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const SettingsMenuProjection = render_input.SettingsMenuProjection;
const roomy_header_rows: u16 = 2;

fn itemRowCount(_: u16) u16 {
    return 1;
}

fn inlineModelRowCount(projection: SettingsMenuProjection) u16 {
    if (!projection.models.active) return 0;
    if (projection.models.load_state != .ready or projection.models.filteredItemCount() == 0) return 1;
    return @intCast(@min(projection.models.filteredItemCount(), 6));
}

const BodyRow = union(enum) {
    none,
    category: settings_catalog.Category,
    item: struct {
        item: settings_catalog.Item,
        selected: bool,
        description: bool,
    },
    model: usize,
};

const Layout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    first_item: usize = 0,
    visible_items: u16 = 0,
    body_start_row: u16 = 0,
    row_count: u16 = 0,
    compact: bool = false,
    show_category: bool = false,
    show_description: bool = false,
};

pub fn menuRowCount(projection: SettingsMenuProjection, width: u16, max_rows: u16) u16 {
    return buildBrowseLayout(projection, width, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(
    projection: SettingsMenuProjection,
    width: u16,
    row_budget: u16,
) u16 {
    return @max(buildBrowseLayout(projection, width, row_budget).visible_items, 1);
}

pub fn composeSettingsMenuRow(
    alloc: Allocator,
    projection: SettingsMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count) return empty;

    const layout = buildBrowseLayout(projection, width, row_count);
    if (row_index < layout.body_start_row) {
        if (row_index == 0) return composeBrowseHeader(alloc, projection, width);
        return empty;
    }
    if (layout.match_count == 0) return composeEmptyRow(alloc, width);
    const value_col = centeredValueColumn(projection.snapshot, width);
    return switch (browseBodyRowAt(projection, width, layout, row_index - layout.body_start_row)) {
        .none => empty,
        .category => |category| composeCategoryRow(alloc, projection, category, width),
        .item => |body| if (body.description)
            empty
        else
            composeItemRow(alloc, projection.snapshot, body.item, body.selected, width, value_col),
        .model => |display_index| composeModelRow(alloc, projection, display_index, width, value_col),
    };
}

fn buildBrowseLayout(projection: SettingsMenuProjection, width: u16, max_rows: u16) Layout {
    if (max_rows == 0) return .{};
    const match_count = projection.filteredItemCount();
    const selected = if (match_count == 0) 0 else projection.selected_index % match_count;
    const body_start_row: u16 = if (max_rows >= roomy_header_rows + 3)
        roomy_header_rows
    else if (max_rows >= 2)
        1
    else
        0;
    if (match_count == 0) {
        return .{
            .body_start_row = body_start_row,
            .row_count = @min(max_rows, body_start_row + 1),
        };
    }

    const body_budget = max_rows - body_start_row;
    if (max_rows < roomy_header_rows + 3) {
        return .{
            .match_count = match_count,
            .selected = selected,
            .first_item = selected,
            .visible_items = 1,
            .body_start_row = body_start_row,
            .row_count = max_rows,
            .compact = true,
            .show_category = body_budget >= 3,
            .show_description = false,
        };
    }

    var first_item = @min(projection.window_start, match_count - 1);
    if (selected < first_item) first_item = selected;
    var body = measureBrowseBody(projection, width, first_item, body_budget);
    while (selected >= first_item + body.visible_items and first_item < selected) {
        first_item += 1;
        body = measureBrowseBody(projection, width, first_item, body_budget);
    }
    if (body.visible_items == 0) {
        first_item = selected;
        body = measureBrowseBody(projection, width, first_item, body_budget);
    }
    return .{
        .match_count = match_count,
        .selected = selected,
        .first_item = first_item,
        .visible_items = body.visible_items,
        .body_start_row = body_start_row,
        .row_count = body_start_row + body.rows,
    };
}

const Measurement = struct {
    visible_items: u16 = 0,
    rows: u16 = 0,
};

fn measureBrowseBody(projection: SettingsMenuProjection, width: u16, first_item: usize, row_budget: u16) Measurement {
    var result: Measurement = .{};
    var previous_category: ?settings_catalog.Category = null;
    const rows_per_item = itemRowCount(width);
    var display_index = first_item;
    while (projection.itemAt(display_index)) |item| : (display_index += 1) {
        const category_rows: u16 = if (previous_category == null or previous_category.? != item.category)
            if (previous_category == null) 1 else 2
        else
            0;
        const model_rows: u16 = if (item.id == .model) inlineModelRowCount(projection) else 0;
        const required = category_rows + rows_per_item + model_rows;
        if (result.rows + required > row_budget) break;
        result.rows += required;
        result.visible_items += 1;
        previous_category = item.category;
    }
    return result;
}

fn browseBodyRowAt(projection: SettingsMenuProjection, width: u16, layout: Layout, target: u16) BodyRow {
    if (layout.compact) {
        const item = projection.itemAt(layout.first_item) orelse return .none;
        var row: u16 = 0;
        if (layout.show_category) {
            if (target == row) return .{ .category = item.category };
            row += 1;
        }
        if (target == row) return .{ .item = .{
            .item = item,
            .selected = true,
            .description = false,
        } };
        row += 1;
        if (layout.show_description and target == row) {
            return .{ .item = .{
                .item = item,
                .selected = true,
                .description = true,
            } };
        }
        return .none;
    }

    const rows_per_item = itemRowCount(width);
    var row: u16 = 0;
    var previous_category: ?settings_catalog.Category = null;
    var offset: usize = 0;
    while (offset < layout.visible_items) : (offset += 1) {
        const display_index = layout.first_item + offset;
        const item = projection.itemAt(display_index) orelse return .none;
        if (previous_category == null or previous_category.? != item.category) {
            if (previous_category != null) {
                if (row == target) return .none;
                row += 1;
            }
            if (row == target) return .{ .category = item.category };
            row += 1;
        }
        if (row == target) return .{ .item = .{
            .item = item,
            .selected = display_index == layout.selected,
            .description = false,
        } };
        row += 1;
        if (item.id == .model and projection.models.active) {
            const model_count = inlineModelRowCount(projection);
            var model_offset: u16 = 0;
            while (model_offset < model_count) : (model_offset += 1) {
                if (row == target) return .{ .model = model_offset };
                row += 1;
            }
        }
        if (rows_per_item == 2) {
            if (row == target) return .{ .item = .{
                .item = item,
                .selected = display_index == layout.selected,
                .description = true,
            } };
            row += 1;
        }
        previous_category = item.category;
    }
    return .none;
}

fn composeBrowseHeader(alloc: Allocator, _: SettingsMenuProjection, width: u16) !std.ArrayList(u8) {
    return composeStyledText(alloc, "Settings", width, ui_render.selected_completion_style, 0);
}

fn composeCategoryRow(
    alloc: Allocator,
    projection: SettingsMenuProjection,
    category: settings_catalog.Category,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    _ = projection;
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, category.label(), width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeItemRow(
    alloc: Allocator,
    snapshot: settings_catalog.Snapshot,
    item: settings_catalog.Item,
    selected: bool,
    width: u16,
    value_col: usize,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent: usize = if (width <= 2) 0 else 2;
    if (indent > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        item.label,
        value_col -| indent,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, value_col);

    const option_count = settings_catalog.optionCount(&snapshot, item.id);
    if (option_count == 0) {
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, item.value, @as(usize, width) -| value_col);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    var option_index: usize = 0;
    while (option_index < option_count) : (option_index += 1) {
        if (option_index > 0) try row.appendSlice(alloc, "  ");
        const option = settings_catalog.optionAt(&snapshot, item.id, option_index) orelse continue;
        const current = std.ascii.eqlIgnoreCase(option, item.value);
        try row.appendSlice(alloc, if (current) ui_render.selected_completion_style else ui_render.dim_style);
        const used = display_width.visibleWidthIgnoringAnsi(row.items);
        try row_text.appendSingleLineEllipsized(alloc, &row, option, @as(usize, width) -| used);
        try row.appendSlice(alloc, ui_render.reset_style);
        if (display_width.visibleWidthIgnoringAnsi(row.items) >= width) break;
    }
    return row;
}

fn composeModelRow(
    alloc: Allocator,
    projection: SettingsMenuProjection,
    visible_offset: usize,
    width: u16,
    value_col: usize,
) !std.ArrayList(u8) {
    if (projection.models.load_state != .ready or projection.models.filteredItemCount() == 0) {
        const label = switch (projection.models.load_state) {
            .loading => "Loading models…",
            .ready => "No models found",
            .failed => "Models unavailable",
        };
        return composeStyledText(alloc, label, width, ui_render.dim_style, 4);
    }

    const match_count = projection.models.filteredItemCount();
    const selected = projection.models.selected_index % match_count;
    const visible_count: usize = @min(match_count, 6);
    var window_start = projection.models.window_start;
    if (selected < window_start) window_start = selected;
    if (selected >= window_start + visible_count) window_start = selected + 1 - visible_count;
    window_start = @min(window_start, match_count - visible_count);
    const display_index = window_start + visible_offset;
    const model = projection.models.itemAt(display_index) orelse return .empty;

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendSpacesToColumn(alloc, &row, value_col);
    try row.appendSlice(alloc, if (display_index == selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, model.id, @as(usize, width) -| value_col);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn centeredValueColumn(snapshot: settings_catalog.Snapshot, width: u16) usize {
    const total_width: usize = width;
    const right_column_start = total_width * 2 / 3;
    const right_column_width = total_width - right_column_start;
    var widest_value_width: usize = 0;
    var display_index: usize = 0;
    while (settings_catalog.itemAt(snapshot, .all, "", display_index)) |item| : (display_index += 1) {
        widest_value_width = @max(widest_value_width, display_width.visibleWidth(item.value));
    }
    const value_block_width = @min(widest_value_width, right_column_width);
    return right_column_start + (right_column_width - value_block_width) / 2;
}

fn composeEmptyRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    return composeStyledText(alloc, "No settings found.", width, ui_render.dim_style, 0);
}

fn composeStyledText(alloc: Allocator, text: []const u8, width: u16, style: []const u8, indent: usize) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var spaces = indent;
    while (spaces > 0 and row.items.len < width) : (spaces -= 1) try row.append(alloc, ' ');
    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, text, @as(usize, width) -| indent);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClipped(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    return row;
}

const test_snapshot: settings_catalog.Snapshot = .{
    .model = "zai/glm-5.2",
    .effort = "default",
    .fast_mode = true,
    .permission_mode = "ask",
    .statusline_context = true,
    .statusline_session = false,
    .statusline_workspace = false,
    .startup_scrollback = true,
    .prompt_history = true,
    .sound_level = "on",
};

test "settings menu renders each setting on one row at wide and narrow widths" {
    const alloc = std.testing.allocator;
    const projection: render_input.SettingsMenuProjection = .{
        .active = true,
        .snapshot = test_snapshot,
    };
    const wide_rows = menuRowCount(projection, 100, 40);
    try std.testing.expectEqual(@as(u16, 20), wide_rows);

    var header = try composeSettingsMenuRow(alloc, projection, 0, 100, wide_rows);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Settings") != null);

    var category = try composeSettingsMenuRow(alloc, projection, 2, 100, wide_rows);
    defer category.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, category.items, "Interface") != null);

    var item = try composeSettingsMenuRow(alloc, projection, 3, 100, wide_rows);
    defer item.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, item.items, "Status line context") != null);
    try std.testing.expect(std.mem.find(u8, item.items, "on") != null);
    try std.testing.expect(std.mem.find(u8, item.items, "Show context usage") == null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.findScalar(u8, item.items, '\n'));
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(item.items) <= 100);

    const compact_rows = menuRowCount(projection, 100, 4);
    var compact_item = try composeSettingsMenuRow(alloc, projection, 2, 100, compact_rows);
    defer compact_item.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, compact_item.items, "Status line context") != null);
    try std.testing.expect(std.mem.find(u8, compact_item.items, "on") != null);

    const narrow_rows = menuRowCount(projection, 24, 40);
    try std.testing.expectEqual(@as(u16, 20), narrow_rows);
    var narrow_item = try composeSettingsMenuRow(alloc, projection, 3, 24, narrow_rows);
    defer narrow_item.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, narrow_item.items, "Status line") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow_item.items) <= 24);
}

test "settings menu values form a centered left aligned block" {
    const alloc = std.testing.allocator;
    const projection: render_input.SettingsMenuProjection = .{
        .active = true,
        .snapshot = test_snapshot,
    };
    const rows = menuRowCount(projection, 100, 40);

    var short = try composeSettingsMenuRow(alloc, projection, 3, 100, rows);
    defer short.deinit(alloc);
    var long = try composeSettingsMenuRow(alloc, projection, 9, 100, rows);
    defer long.deinit(alloc);

    const short_start = std.mem.find(u8, short.items, "off").?;
    const long_start = std.mem.find(u8, long.items, "zai/glm-5.2").?;
    const short_column = display_width.visibleWidthIgnoringAnsi(short.items[0..short_start]);
    const long_column = display_width.visibleWidthIgnoringAnsi(long.items[0..long_start]);
    try std.testing.expectEqual(
        short_column,
        long_column,
    );

    try std.testing.expect(long_column >= 100 * 2 / 3);
    try std.testing.expect(long_column < 100);
}
