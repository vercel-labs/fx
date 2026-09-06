const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const HelpMenuProjection = render_input.HelpMenuProjection;

const roomy_header_rows: u16 = 2;
pub const max_visible_items: u16 = 20;
pub const max_inline_rows: u16 = roomy_header_rows + max_visible_items;

const BodyRow = union(enum) {
    none,
    item: struct {
        spec: *const command_specs.SlashSpec,
        selected: bool,
    },
};

const Layout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    first_item: usize = 0,
    visible_items: u16 = 0,
    body_start_row: u16 = 0,
    row_count: u16 = 0,
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
    return switch (bodyRowAt(projection, layout, row_index - layout.body_start_row)) {
        .none => empty,
        .item => |item| composeCommandRow(alloc, item.spec.*, item.selected, width, description_col),
    };
}

fn buildLayout(projection: HelpMenuProjection, width: u16, max_rows: u16) Layout {
    if (max_rows == 0) return .{};
    const match_count = projection.filteredItemCount();
    const selected = if (match_count == 0) 0 else projection.selected_index % match_count;
    const show_header = max_rows > 2;
    const body_start_row: u16 = if (show_header) roomy_header_rows else 0;
    if (match_count == 0) {
        return .{
            .body_start_row = body_start_row,
            .row_count = @min(max_rows, body_start_row + 1),
        };
    }

    const body_budget = max_rows - body_start_row;
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
    _ = width;
    var display_index = first_item;
    while (projection.itemAt(display_index) != null) : (display_index += 1) {
        const required: u16 = 1;
        if (measurement.rows + required > row_budget) break;
        measurement.rows += required;
        measurement.visible_items += 1;
        if (measurement.visible_items == max_visible_items) break;
    }
    return measurement;
}

fn bodyRowAt(projection: HelpMenuProjection, layout: Layout, target: u16) BodyRow {
    var row: u16 = 0;
    var offset: usize = 0;
    while (offset < layout.visible_items) : (offset += 1) {
        const display_index = layout.first_item + offset;
        const spec = projection.itemAt(display_index) orelse return .none;
        if (row == target) return .{ .item = .{
            .spec = spec,
            .selected = display_index == layout.selected,
        } };
        row += 1;
    }
    return .none;
}

fn composeHeaderRow(alloc: Allocator, projection: HelpMenuProjection, width: u16) !std.ArrayList(u8) {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try appendHeaderTitle(alloc, &wide, projection.filteredItemCount());
    try wide.appendSlice(alloc, "  ");
    try appendCategoryTab(alloc, &wide, null, projection.category == null);
    inline for (std.meta.fields(command_specs.SlashPresentationCategory)) |field| {
        const category: command_specs.SlashPresentationCategory = @enumFromInt(field.value);
        try wide.appendSlice(alloc, "  ");
        try appendCategoryTab(alloc, &wide, category, projection.category == category);
    }
    if (display_width.visibleWidthIgnoringAnsi(wide.items) <= width) {
        return cloneClippedRow(alloc, wide.items, width);
    }

    const category_count = std.meta.fields(command_specs.SlashPresentationCategory).len + 1;
    const active_index = helpCategoryIndex(projection.category);
    var packed_row: std.ArrayList(u8) = .empty;
    defer packed_row.deinit(alloc);
    var prefix_count = category_count - 1;
    while (prefix_count > 0) : (prefix_count -= 1) {
        packed_row.clearRetainingCapacity();
        try appendHeaderTitle(alloc, &packed_row, projection.filteredItemCount());
        for (0..prefix_count) |index| {
            const category = helpCategoryAt(index);
            try packed_row.appendSlice(alloc, "  ");
            try appendCategoryTab(alloc, &packed_row, category, active_index == index);
        }
        try packed_row.appendSlice(alloc, "  ");
        try packed_row.appendSlice(alloc, ui_render.dim_style);
        try packed_row.appendSlice(alloc, "…");
        try packed_row.appendSlice(alloc, ui_render.reset_style);
        if (active_index >= prefix_count) {
            try packed_row.appendSlice(alloc, "  ");
            try appendCategoryTab(alloc, &packed_row, projection.category, true);
        }
        if (display_width.visibleWidthIgnoringAnsi(packed_row.items) <= width) {
            return cloneClippedRow(alloc, packed_row.items, width);
        }
    }

    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try appendHeaderTitle(alloc, &compact, projection.filteredItemCount());
    try compact.appendSlice(alloc, "  ");
    try appendCategoryTab(alloc, &compact, projection.category, true);
    if (display_width.visibleWidthIgnoringAnsi(compact.items) <= width) {
        return cloneClippedRow(alloc, compact.items, width);
    }

    compact.clearRetainingCapacity();
    try appendCategoryTab(alloc, &compact, projection.category, true);
    return cloneClippedRow(alloc, compact.items, width);
}

fn helpCategoryAt(index: usize) ?command_specs.SlashPresentationCategory {
    if (index == 0) return null;
    return @enumFromInt(index - 1);
}

fn helpCategoryIndex(category: ?command_specs.SlashPresentationCategory) usize {
    return if (category) |value| @intFromEnum(value) + 1 else 0;
}

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Commands {d}", .{count}) catch "Commands";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendCategoryTab(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    category: ?command_specs.SlashPresentationCategory,
    active: bool,
) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, if (category) |value| value.label() else "All");
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
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
    const gutter: usize = if (description_col >= indent + picker_presentation.inline_picker_column_gap_width)
        picker_presentation.inline_picker_column_gap_width
    else
        0;
    if (indent > 0) try row.appendSlice(alloc, "  ");

    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, spec.command, description_col -| indent -| gutter);
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
    const indent: usize = if (width <= 2) 0 else 2;
    var widest_command_width: usize = 0;
    var display_index: usize = 0;
    while (projection.itemAt(display_index)) |spec| : (display_index += 1) {
        widest_command_width = @max(
            widest_command_width,
            display_width.visibleWidth(spec.command),
        );
    }
    return @min(indent + widest_command_width + picker_presentation.inline_picker_column_gap_width, width);
}

fn composeEmptyRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, "No commands found.", width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClippedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    return row;
}

const help_menu_test_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .status, .command = "/status", .help_entry = "/status", .completion_description = "show runtime configuration", .presentation_category = .general },
    .{ .kind = .paste, .command = "/paste", .help_entry = "/paste", .completion_description = "attach an image from the clipboard when supported", .presentation_category = .media },
};
const help_menu_test_registry = command_specs.SlashRegistry{ .commands = help_menu_test_specs[0..] };

test "help menu places descriptions after the widest matching command" {
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

    var selected = try composeHelpMenuRow(alloc, projection, 2, 160, rows);
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
        @as(usize, 13),
        display_width.visibleWidthIgnoringAnsi(selected.items[0..description_start]),
    );

    const narrow_rows = menuRowCount(projection, 22, 20);
    try std.testing.expectEqual(rows, narrow_rows);
    try std.testing.expectEqual(@as(usize, 13), descriptionColumn(projection, 22));
    var narrow = try composeHelpMenuRow(alloc, projection, 2, 22, narrow_rows);
    defer narrow.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, narrow.items, "/help") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow.items) <= 22);
    try std.testing.expect(std.mem.findScalar(u8, narrow.items, '\n') == null);
}

test "help menu keeps a four column gutter after command names" {
    const alloc = std.testing.allocator;
    const long_specs = [_]command_specs.SlashSpec{
        .{ .kind = .permissions, .command = "/permissions", .help_entry = "/permissions [ask|auto|remember|revoke|full-access|reset]", .completion_description = "choose permission behavior", .presentation_category = .security },
    };
    const projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = .{ .commands = long_specs[0..] },
    };
    const rows = menuRowCount(projection, 160, 12);
    var item = try composeHelpMenuRow(alloc, projection, 2, 160, rows);
    defer item.deinit(alloc);

    const description_start = std.mem.find(u8, item.items, "choose permission behavior").?;
    const description_col = display_width.visibleWidthIgnoringAnsi(item.items[0..description_start]);
    try std.testing.expectEqual(@as(usize, 18), description_col);
    try std.testing.expect(std.mem.find(u8, item.items[0..description_start], "…") == null);
    try std.testing.expect(std.mem.find(u8, item.items, "[ask") == null);
}

test "help menu search keeps headings non-selectable and reports empty results" {
    const alloc = std.testing.allocator;
    const projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
        .query = "clipboard",
    };
    const rows = menuRowCount(projection, 80, 12);
    try std.testing.expectEqual(@as(u16, 3), rows);

    var item = try composeHelpMenuRow(alloc, projection, 2, 80, rows);
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

test "help menu renders category tabs and flat commands through the VT" {
    const alloc = std.testing.allocator;
    const width: u16 = 120;
    const projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
    };
    const rows = menuRowCount(projection, width, 8);

    var grid = try vt_emulator.Grid.init(alloc, width, rows);
    defer grid.deinit();
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeHelpMenuRow(alloc, projection, row_index, width, rows);
        defer row.deinit(alloc);
        var cursor_buf: [32]u8 = undefined;
        const cursor = try std.fmt.bufPrint(&cursor_buf, "\x1b[{d};1H", .{row_index + 1});
        try grid.feed(cursor);
        try grid.feed(row.items);
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try grid.rowTextTrimmed(1, &text);
    try std.testing.expect(std.mem.find(u8, text.items, "Commands 3") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "General") != null);
    text.clearRetainingCapacity();
    try grid.rowTextTrimmed(3, &text);
    try std.testing.expect(std.mem.find(u8, text.items, "/help") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "General") == null);
}

test "help menu packs more filters while preserving a far active filter in the VT" {
    const alloc = std.testing.allocator;
    const width: u16 = 100;
    var specs: [37]command_specs.SlashSpec = undefined;
    for (&specs) |*spec| {
        spec.* = .{
            .kind = .help,
            .command = "/help",
            .help_entry = "/help",
            .completion_description = "show available slash commands",
            .presentation_category = .general,
        };
    }
    specs[specs.len - 1].presentation_category = .product;
    const registry = command_specs.SlashRegistry{ .commands = &specs };

    const all_projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = registry,
    };
    var all_row = try composeHelpMenuRow(alloc, all_projection, 0, width, 8);
    defer all_row.deinit(alloc);
    var all_grid = try vt_emulator.Grid.init(alloc, width, 1);
    defer all_grid.deinit();
    try all_grid.feed(all_row.items);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try all_grid.rowTextTrimmed(1, &text);
    try std.testing.expect(std.mem.find(u8, text.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "General") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "Session") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "…") != null);

    const product_projection: render_input.HelpMenuProjection = .{
        .active = true,
        .category = .product,
        .registry = registry,
    };
    var product_row = try composeHelpMenuRow(alloc, product_projection, 0, width, 8);
    defer product_row.deinit(alloc);
    var product_grid = try vt_emulator.Grid.init(alloc, width, 1);
    defer product_grid.deinit();
    try product_grid.feed(product_row.items);
    text.clearRetainingCapacity();
    try product_grid.rowTextTrimmed(1, &text);
    try std.testing.expect(std.mem.find(u8, text.items, "All") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "General") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "…") != null);
    try std.testing.expect(std.mem.find(u8, text.items, "[Product]") != null);
}
