const std = @import("std");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const menu_frame = @import("menu_frame.zig");
const render_input = @import("render_input.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const HelpMenuProjection = render_input.HelpMenuProjection;

/// The title and the blank row under it.
const header_rows: u16 = 2;
/// The help catalog lists as many rows as the other menus, so it stays lean
/// and the composer doesn't move while a filter narrows it.
const list_rows: u16 = list_window.default_max_picker_rows;
pub const max_inline_rows: u16 = header_rows + list_rows;

pub fn menuRowCount(projection: HelpMenuProjection, _: u16, max_rows: u16) u16 {
    return frameLayout(projection, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(
    projection: HelpMenuProjection,
    _: u16,
    row_budget: u16,
) u16 {
    return @max(frameLayout(projection, row_budget).visible_items, 1);
}

pub fn composeHelpMenuRow(
    alloc: Allocator,
    projection: HelpMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    return menu_frame.composeRow(alloc, frameSpec(&projection, row_count), row_index, width, row_count);
}

/// List rows within `row_budget`; a budget too short for the title gives
/// every row to the list.
fn listCap(row_budget: u16) u16 {
    return @min(list_rows, if (row_budget > header_rows) row_budget - header_rows else row_budget);
}

fn selectedIndex(projection: HelpMenuProjection, count: usize) usize {
    return if (count > 0) projection.selected_index % count else 0;
}

fn frameLayout(projection: HelpMenuProjection, row_budget: u16) menu_frame.Layout {
    const count = projection.filteredItemCount();
    return menu_frame.listLayout(count, selectedIndex(projection, count), projection.window_start, listCap(row_budget), row_budget);
}

fn frameSpec(projection: *const HelpMenuProjection, row_budget: u16) menu_frame.Spec {
    const count = projection.filteredItemCount();
    return .{
        .title = "commands",
        .active_tab = if (projection.category) |category| category.label() else "All",
        .ctx = projection,
        .item_count = count,
        .column_count = 2,
        .cell = cell,
        .selected = selectedIndex(projection.*, count),
        .window_start = projection.window_start,
        .list_cap = listCap(row_budget),
        .empty_message = if (projection.query.len > 0) "no matching commands." else "no commands.",
        .empty_hint = if (projection.category != null and projection.query.len == 0) "press tab to change the category." else "",
    };
}

fn cell(ctx: *const anyopaque, item: usize, column: usize, _: []u8) []const u8 {
    const projection: *const HelpMenuProjection = @ptrCast(@alignCast(ctx));
    const spec = projection.itemAt(item) orelse return "";
    return if (column == 0) spec.command else spec.completion_description orelse "";
}

const help_menu_test_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .status, .command = "/status", .help_entry = "/status", .completion_description = "show runtime configuration", .presentation_category = .general },
    .{ .kind = .paste, .command = "/paste", .help_entry = "/paste", .completion_description = "attach an image from the clipboard when supported", .presentation_category = .media },
};
const help_menu_test_registry = command_specs.SlashRegistry{ .commands = help_menu_test_specs[0..] };

/// Draws every menu row through the VT and returns the plain text, one line
/// per row. The caller owns the returned text.
fn renderPlain(alloc: Allocator, projection: HelpMenuProjection, width: u16, budget: u16) ![]u8 {
    const rows = menuRowCount(projection, width, budget);
    var grid = try vt_emulator.Grid.init(alloc, width, rows);
    defer grid.deinit();
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeHelpMenuRow(alloc, projection, row_index, width, rows);
        defer row.deinit(alloc);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        var cursor_buf: [32]u8 = undefined;
        try grid.feed(try std.mem.print(&cursor_buf, "\x1b[{d};1H", .{row_index + 1}));
        try grid.feed(row.items);
    }
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    row_index = 1;
    while (row_index <= rows) : (row_index += 1) {
        line.clearRetainingCapacity();
        try grid.rowTextTrimmed(row_index, &line);
        try text.appendSlice(alloc, line.items);
        try text.append(alloc, '\n');
    }
    return text.toOwnedSlice(alloc);
}

test "help menu draws the shared frame: gray title with its category, aligned columns, fixed height" {
    const alloc = std.testing.allocator;
    const projection: HelpMenuProjection = .{ .active = true, .registry = help_menu_test_registry };
    const text = try renderPlain(alloc, projection, 100, 22);
    defer alloc.free(text);
    // The tall budget the footer offers still gives the lean height.
    try std.testing.expectEqualStrings(
        \\commands   < All >
        \\
        \\  /help        show available slash commands
        \\  /status      show runtime configuration
        \\  /paste       attach an image from the clipboard when supported
        \\
        \\
        \\
        \\
    , text);
    try std.testing.expectEqual(max_inline_rows, menuRowCount(projection, 100, 22));

    // Only the selected row is bright, from its command through its description.
    var selected = try composeHelpMenuRow(alloc, projection, 2, 100, max_inline_rows);
    defer selected.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, selected.items, ui_render.selected_completion_style));
    var other = try composeHelpMenuRow(alloc, projection, 3, 100, max_inline_rows);
    defer other.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, other.items, ui_render.selected_completion_style) == null);
}

test "help menu shows five commands and a more row when the catalog is long" {
    const alloc = std.testing.allocator;
    var specs: [12]command_specs.SlashSpec = undefined;
    for (&specs) |*spec| spec.* = help_menu_test_specs[0];
    const projection: HelpMenuProjection = .{ .active = true, .registry = .{ .commands = &specs } };
    const text = try renderPlain(alloc, projection, 80, 22);
    defer alloc.free(text);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, text, "/help "));
    try std.testing.expect(std.mem.find(u8, text, "  ↓ 7 more\n") != null);
    try std.testing.expectEqual(@as(u16, 5), visibleNavigationItemsForBudget(projection, 80, 22));
}

test "help menu names the active category and says why the list is empty" {
    const alloc = std.testing.allocator;
    const media: HelpMenuProjection = .{ .active = true, .registry = help_menu_test_registry, .category = .media };
    const media_text = try renderPlain(alloc, media, 80, 22);
    defer alloc.free(media_text);
    try std.testing.expect(std.mem.startsWith(u8, media_text, "commands   < Media >\n\n  /paste"));
    try std.testing.expect(std.mem.find(u8, media_text, "General") == null);

    const missing: HelpMenuProjection = .{ .active = true, .registry = help_menu_test_registry, .query = "no command can match this query" };
    const missing_text = try renderPlain(alloc, missing, 80, 22);
    defer alloc.free(missing_text);
    try std.testing.expect(std.mem.find(u8, missing_text, "  no matching commands.\n") != null);
    try std.testing.expectEqual(max_inline_rows, menuRowCount(missing, 80, 22));
}

test "help menu clips descriptions on a narrow terminal and keeps every row inside it" {
    const alloc = std.testing.allocator;
    const projection: HelpMenuProjection = .{ .active = true, .registry = help_menu_test_registry };
    const text = try renderPlain(alloc, projection, 30, 22);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "  /paste") != null);
    try std.testing.expect(std.mem.find(u8, text, "…") != null);
}
