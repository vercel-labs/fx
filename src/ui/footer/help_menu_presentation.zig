const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const HelpMenuProjection = render_input.HelpMenuProjection;

const roomy_header_rows: u16 = 2;
// Keep command names and descriptions visually associated on wide terminals.
const maximum_description_column: usize = 48;

fn commandRowCount(_: u16) u16 {
    return 1;
}

const BodyRow = union(enum) {
    none,
    category: command_specs.SlashPresentationCategory,
    item: struct {
        spec: *const command_specs.SlashSpec,
        selected: bool,
        description: bool,
    },
};

const Layout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    first_item: usize = 0,
    visible_items: u16 = 0,
    body_rows: u16 = 0,
    body_start_row: u16 = 0,
    row_count: u16 = 0,
    compact: bool = false,
};

pub fn menuRowCount(projection: HelpMenuProjection, width: u16, max_rows: u16) u16 {
    return buildLayout(projection, width, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(
    projection: HelpMenuProjection,
    width: u16,
    row_budget: u16,
) u16 {
    return @max(buildLayout(projection, width, row_budget).visible_items, 1);
}

pub fn composeHelpMenuRow(
    alloc: Allocator,
    projection: HelpMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count) return empty;

    const layout = buildLayout(projection, width, row_count);
    if (row_index < layout.body_start_row) {
        if (row_index == 0) return composeHeaderRow(alloc, projection, width);
        return empty;
    }
    if (layout.match_count == 0) return composeEmptyRow(alloc, width);

    const description_col = descriptionColumn(projection, width);
    return switch (bodyRowAt(projection, width, layout, row_index - layout.body_start_row)) {
        .none => empty,
        .category => |category| composeCategoryRow(alloc, category, width),
        .item => |item| if (item.description)
            empty
        else
            composeCommandRow(alloc, item.spec.*, item.selected, width, description_col),
    };
}

fn buildLayout(projection: HelpMenuProjection, width: u16, max_rows: u16) Layout {
    if (max_rows == 0) return .{};
    const match_count = projection.filteredItemCount();
    const selected = if (match_count == 0) 0 else projection.selected_index % match_count;
    const body_start_row: u16 = if (max_rows >= roomy_header_rows + 1)
        roomy_header_rows
    else
        max_rows -| 1;
    if (match_count == 0) {
        return .{
            .body_start_row = body_start_row,
            .row_count = @min(max_rows, body_start_row + 1),
        };
    }

    const body_budget = max_rows - body_start_row;
    const item_rows = commandRowCount(width);
    if (body_budget <= item_rows) {
        return .{
            .match_count = match_count,
            .selected = selected,
            .first_item = selected,
            .visible_items = 1,
            .body_rows = body_budget,
            .body_start_row = body_start_row,
            .row_count = max_rows,
            .compact = true,
        };
    }

    var first_item = @min(projection.window_start, match_count - 1);
    if (selected < first_item) first_item = selected;
    var body = measureBody(projection, width, first_item, body_budget);
    while (selected >= first_item + body.visible_items and first_item < selected) {
        first_item += 1;
        body = measureBody(projection, width, first_item, body_budget);
    }
    if (body.visible_items == 0) {
        first_item = selected;
        body = measureBody(projection, width, first_item, body_budget);
    }
    return .{
        .match_count = match_count,
        .selected = selected,
        .first_item = first_item,
        .visible_items = body.visible_items,
        .body_rows = body.rows,
        .body_start_row = body_start_row,
        .row_count = body_start_row + body.rows,
    };
}

const BodyMeasurement = struct {
    visible_items: u16 = 0,
    rows: u16 = 0,
};

fn measureBody(projection: HelpMenuProjection, width: u16, first_item: usize, row_budget: u16) BodyMeasurement {
    var measurement: BodyMeasurement = .{};
    var previous_category: ?command_specs.SlashPresentationCategory = null;
    const item_rows = commandRowCount(width);
    var display_index = first_item;
    while (projection.itemAt(display_index)) |spec| : (display_index += 1) {
        const category = spec.presentation_category.?;
        const category_changed = previous_category == null or previous_category.? != category;
        const category_rows: u16 = if (!category_changed) 0 else if (previous_category == null) 1 else 2;
        const required = category_rows + item_rows;
        if (measurement.rows + required > row_budget) break;
        measurement.rows += required;
        measurement.visible_items += 1;
        previous_category = category;
    }
    return measurement;
}

fn bodyRowAt(projection: HelpMenuProjection, width: u16, layout: Layout, target: u16) BodyRow {
    if (layout.compact) {
        const spec = projection.itemAt(layout.first_item) orelse return .none;
        if (target >= layout.body_rows) return .none;
        return .{ .item = .{
            .spec = spec,
            .selected = true,
            .description = target > 0,
        } };
    }

    var row: u16 = 0;
    var previous_category: ?command_specs.SlashPresentationCategory = null;
    var offset: usize = 0;
    const item_rows = commandRowCount(width);
    while (offset < layout.visible_items) : (offset += 1) {
        const display_index = layout.first_item + offset;
        const spec = projection.itemAt(display_index) orelse return .none;
        const category = spec.presentation_category.?;
        if (previous_category == null or previous_category.? != category) {
            if (previous_category != null) {
                if (row == target) return .none;
                row += 1;
            }
            if (row == target) return .{ .category = category };
            row += 1;
        }
        if (row == target) return .{ .item = .{
            .spec = spec,
            .selected = display_index == layout.selected,
            .description = false,
        } };
        row += 1;
        if (item_rows == 2) {
            if (row == target) return .{ .item = .{
                .spec = spec,
                .selected = display_index == layout.selected,
                .description = true,
            } };
            row += 1;
        }
        previous_category = category;
    }
    return .none;
}

fn composeHeaderRow(alloc: Allocator, projection: HelpMenuProjection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Commands {d}", .{projection.filteredItemCount()}) catch "Commands";
    try row_text.appendSingleLineEllipsized(alloc, &row, title, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeCategoryRow(
    alloc: Allocator,
    category: command_specs.SlashPresentationCategory,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, category.label(), width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeCommandRow(
    alloc: Allocator,
    spec: command_specs.SlashSpec,
    selected: bool,
    width: u16,
    description_col: usize,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent: usize = if (width <= 2) 0 else 2;
    const gutter: usize = if (description_col >= indent + 2) 2 else 0;
    if (indent > 0) try row.appendSlice(alloc, "  ");

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, spec.help_entry.?, description_col -| indent -| gutter);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, description_col);

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        spec.completion_description.?,
        @as(usize, width) -| description_col,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn descriptionColumn(projection: HelpMenuProjection, width: u16) usize {
    const total_width: usize = width;
    const right_column_start = total_width * 2 / 3;
    const right_column_width = total_width - right_column_start;
    var widest_description_width: usize = 0;
    var display_index: usize = 0;
    while (projection.itemAt(display_index)) |spec| : (display_index += 1) {
        widest_description_width = @max(
            widest_description_width,
            display_width.visibleWidth(spec.completion_description.?),
        );
    }
    const description_block_width = @min(widest_description_width, right_column_width);
    const centered_column = right_column_start + (right_column_width - description_block_width) / 2;
    return @min(centered_column, maximum_description_column);
}

fn composeEmptyRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, "No commands found.", width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const help_menu_test_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .status, .command = "/status", .help_entry = "/status", .completion_description = "show runtime configuration", .presentation_category = .general },
    .{ .kind = .paste, .command = "/paste", .help_entry = "/paste", .completion_description = "attach an image from the clipboard when supported", .presentation_category = .media },
};
const help_menu_test_registry = command_specs.SlashRegistry{ .commands = help_menu_test_specs[0..] };

test "help menu keeps descriptions close at wide widths without changing narrow layout" {
    const alloc = std.testing.allocator;
    const projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
        .selected_index = 0,
    };
    const rows = menuRowCount(projection, 160, 20);

    var header = try composeHelpMenuRow(alloc, projection, 0, 160, rows);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Commands 3") != null);

    var category = try composeHelpMenuRow(alloc, projection, 2, 160, rows);
    defer category.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, category.items, "General") != null);

    var selected = try composeHelpMenuRow(alloc, projection, 3, 160, rows);
    defer selected.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, selected.items, "/help") != null);
    try std.testing.expect(std.mem.find(u8, selected.items, "●") == null);
    try std.testing.expect(std.mem.find(u8, selected.items, "show available slash commands") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.findScalar(u8, selected.items, '\n'));
    const description_start = std.mem.find(u8, selected.items, "show available slash commands").?;
    const selected_style_start = description_start - ui_render.selected_completion_style.len;
    try std.testing.expectEqualStrings(
        ui_render.selected_completion_style,
        selected.items[selected_style_start..description_start],
    );
    try std.testing.expectEqual(
        maximum_description_column,
        display_width.visibleWidthIgnoringAnsi(selected.items[0..description_start]),
    );

    const narrow_rows = menuRowCount(projection, 22, 20);
    try std.testing.expectEqual(rows, narrow_rows);
    try std.testing.expectEqual(@as(usize, 14), descriptionColumn(projection, 22));
    var narrow = try composeHelpMenuRow(alloc, projection, 3, 22, narrow_rows);
    defer narrow.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, narrow.items, "/help") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow.items) <= 22);
    try std.testing.expect(std.mem.findScalar(u8, narrow.items, '\n') == null);
}

test "help menu keeps a gutter between long commands and descriptions" {
    const alloc = std.testing.allocator;
    const long_specs = [_]command_specs.SlashSpec{
        .{ .kind = .appearance, .command = "/appearance", .help_entry = "/appearance [input lines|tint|presentation normal|minimal] [theme system|light|dark]", .completion_description = "choose presentation", .presentation_category = .appearance },
    };
    const projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = .{ .commands = long_specs[0..] },
    };
    const rows = menuRowCount(projection, 160, 12);
    var item = try composeHelpMenuRow(alloc, projection, 3, 160, rows);
    defer item.deinit(alloc);

    const description_start = std.mem.find(u8, item.items, "choose presentation").?;
    const description_col = display_width.visibleWidthIgnoringAnsi(item.items[0..description_start]);
    try std.testing.expectEqual(maximum_description_column, description_col);
    try std.testing.expect(std.mem.find(u8, item.items[0..description_start], "…") != null);
}

test "help menu search keeps headings non-selectable and reports empty results" {
    const alloc = std.testing.allocator;
    const projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
        .query = "clipboard",
    };
    const rows = menuRowCount(projection, 80, 12);
    try std.testing.expectEqual(@as(u16, 4), rows);

    var category = try composeHelpMenuRow(alloc, projection, 2, 80, rows);
    defer category.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, category.items, "Media") != null);

    var item = try composeHelpMenuRow(alloc, projection, 3, 80, rows);
    defer item.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, item.items, "/paste") != null);

    const empty_projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
        .query = "no command can match this query",
    };
    const empty_rows = menuRowCount(empty_projection, 80, 12);
    var empty = try composeHelpMenuRow(alloc, empty_projection, empty_rows - 1, 80, empty_rows);
    defer empty.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, empty.items, "No commands found.") != null);
}
