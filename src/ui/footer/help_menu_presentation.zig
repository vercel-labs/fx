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

pub const PreparedHelpMenu = struct {
    projection: *const HelpMenuProjection,
    layout: Layout,
    width: u16,
    row_budget: u16,
    description_column: usize,

    pub noinline fn composeRow(self: PreparedHelpMenu, alloc: Allocator, row_index: u16) !std.ArrayList(u8) {
        const empty: std.ArrayList(u8) = .empty;
        if (self.width == 0 or row_index >= self.row_budget) return empty;
        if (row_index < self.layout.body_start_row) {
            if (row_index == 0) return composeHeaderRow(alloc, self.projection.*, self.width, self.layout.match_count);
            return empty;
        }
        if (self.layout.match_count == 0) return composeEmptyRow(alloc, self.width);
        return switch (bodyRowAt(self.projection.*, self.layout, row_index - self.layout.body_start_row)) {
            .none => empty,
            .item => |item| composeCommandRow(alloc, item.spec.*, item.selected, self.width, self.description_column),
        };
    }
};

/// Borrows the frame's projection; its registry and filter must remain stable.
pub fn prepareHelpMenu(projection: *const HelpMenuProjection, width: u16, row_budget: u16) PreparedHelpMenu {
    const layout = if (width == 0) Layout{} else buildLayout(projection.*, row_budget);
    return .{
        .projection = projection,
        .layout = layout,
        .width = width,
        .row_budget = row_budget,
        .description_column = if (layout.visible_items == 0) 0 else descriptionColumn(projection.*, width),
    };
}

pub fn menuRowCount(projection: HelpMenuProjection, _: u16, max_rows: u16) u16 {
    return buildLayout(projection, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(
    projection: HelpMenuProjection,
    _: u16,
    row_budget: u16,
) u16 {
    return @max(buildLayout(projection, row_budget).visible_items, 1);
}

fn buildLayout(projection: HelpMenuProjection, max_rows: u16) Layout {
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

    const capacity = @min(max_rows - body_start_row, max_visible_items);
    const first_item = @max(@min(projection.window_start, selected), selected -| (capacity - 1));
    const visible_items: u16 = @intCast(@min(match_count - first_item, capacity));
    return .{
        .match_count = match_count,
        .selected = selected,
        .first_item = first_item,
        .visible_items = visible_items,
        .body_start_row = body_start_row,
        .row_count = body_start_row + visible_items,
    };
}

fn bodyRowAt(projection: HelpMenuProjection, layout: Layout, target: u16) BodyRow {
    if (target >= layout.visible_items) return .none;
    const display_index = layout.first_item + target;
    const spec = projection.itemAt(display_index) orelse return .none;
    return .{ .item = .{ .spec = spec, .selected = display_index == layout.selected } };
}

fn composeHeaderRow(alloc: Allocator, projection: HelpMenuProjection, width: u16, match_count: usize) !std.ArrayList(u8) {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try appendHeaderTitle(alloc, &wide, match_count);
    try wide.appendSlice(alloc, "  ");
    try appendCategoryTab(alloc, &wide, null, projection.category == null);
    for (std.meta.tags(command_specs.SlashPresentationCategory)) |category| {
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
        try appendHeaderTitle(alloc, &packed_row, match_count);
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
    try appendHeaderTitle(alloc, &compact, match_count);
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

test "help menu preserves a partial end window with a larger row budget" {
    const projection: HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
        .selected_index = 2,
        .window_start = 2,
    };
    try std.testing.expectEqual(@as(u16, 3), menuRowCount(projection, 80, 22));
    try std.testing.expectEqual(@as(u16, 1), visibleNavigationItemsForBudget(projection, 80, 22));
    var row = try prepareHelpMenu(&projection, 80, 22).composeRow(std.testing.allocator, 2);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "/paste") != null);
}

test "help menu scrolls only far enough to reveal the selected command" {
    var specs: [25]command_specs.SlashSpec = undefined;
    var names: [25][8]u8 = undefined;
    for (&specs, &names, 0..) |*spec, *buffer, index| {
        const name = try std.fmt.bufPrint(buffer, "/c{d:0>2}", .{index});
        spec.* = .{ .kind = .help, .command = name, .help_entry = name, .completion_description = "command", .presentation_category = .general };
    }
    const projection: HelpMenuProjection = .{ .active = true, .registry = .{ .commands = &specs }, .selected_index = 21 };
    const prepared = prepareHelpMenu(&projection, 80, 8);
    var first = try prepared.composeRow(std.testing.allocator, 2);
    defer first.deinit(std.testing.allocator);
    var last = try prepared.composeRow(std.testing.allocator, 7);
    defer last.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, first.items, "/c16") != null);
    try std.testing.expect(std.mem.find(u8, last.items, "/c21") != null);
    try std.testing.expect(std.mem.find(u8, last.items, ui_render.selected_completion_style) != null);
}

test "prepared help menu preserves frame selection and tight row budgets" {
    const alloc = std.testing.allocator;
    var projection: HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
        .selected_index = 2,
    };
    const prepared = prepareHelpMenu(&projection, 40, 3);
    projection.selected_index = 0;
    var selected = try prepared.composeRow(alloc, 2);
    defer selected.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, selected.items, "/paste") != null);
    try std.testing.expect(std.mem.find(u8, selected.items, ui_render.selected_completion_style) != null);

    var outside = try prepared.composeRow(alloc, 3);
    defer outside.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), outside.items.len);

    const next = prepareHelpMenu(&projection, 40, 1);
    var first = try next.composeRow(alloc, 0);
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, first.items, "/help") != null);
    try std.testing.expect(std.mem.find(u8, first.items, "Commands") == null);

    const zero_width = prepareHelpMenu(&projection, 0, 3);
    var empty = try zero_width.composeRow(alloc, 0);
    defer empty.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "help menu places descriptions after the widest matching command" {
    const alloc = std.testing.allocator;
    const projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
        .selected_index = 0,
    };
    const rows = menuRowCount(projection, 160, 20);
    const prepared = prepareHelpMenu(&projection, 160, rows);

    var header = try prepared.composeRow(alloc, 0);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Commands 3") != null);

    var selected = try prepared.composeRow(alloc, 2);
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
    var narrow = try prepareHelpMenu(&projection, 22, narrow_rows).composeRow(alloc, 2);
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
    var item = try prepareHelpMenu(&projection, 160, rows).composeRow(alloc, 2);
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

    var item = try prepareHelpMenu(&projection, 80, rows).composeRow(alloc, 2);
    defer item.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, item.items, "/paste") != null);

    const empty_projection: render_input.HelpMenuProjection = .{
        .active = true,
        .registry = help_menu_test_registry,
        .query = "no command can match this query",
    };
    const empty_rows = menuRowCount(empty_projection, 80, 12);
    var empty = try prepareHelpMenu(&empty_projection, 80, empty_rows).composeRow(alloc, empty_rows - 1);
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
    const prepared = prepareHelpMenu(&projection, width, rows);

    var grid = try vt_emulator.Grid.init(alloc, width, rows);
    defer grid.deinit();
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try prepared.composeRow(alloc, row_index);
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
    var all_row = try prepareHelpMenu(&all_projection, width, 8).composeRow(alloc, 0);
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
    var product_row = try prepareHelpMenu(&product_projection, width, 8).composeRow(alloc, 0);
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
