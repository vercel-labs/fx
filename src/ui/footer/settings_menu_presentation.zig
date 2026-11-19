const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const menu_frame = @import("menu_frame.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const SettingsMenuProjection = render_input.SettingsMenuProjection;
const roomy_header_rows: u16 = 2;
/// The list holds as many rows as the other menus; a longer catalog shows a
/// `↓ N more` row in its last one.
const list_rows: u16 = list_window.default_max_picker_rows;
pub const max_inline_rows: u16 = roomy_header_rows + list_rows;
const widest_value_gap: usize = 6;
const narrowest_value_gap: usize = 2;

fn inlineModelRowCount(projection: SettingsMenuProjection) u16 {
    if (!projection.models.active) return 0;
    if (projection.models.load_state != .ready or projection.models.filteredItemCount() == 0) return 1;
    return @intCast(@min(projection.models.filteredItemCount(), 6));
}

const BodyRow = union(enum) {
    none,
    item: struct {
        item: settings_catalog.Item,
        selected: bool,
    },
    model: usize,
    more: usize,
};

const Layout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    first_item: usize = 0,
    visible_items: u16 = 0,
    body_start_row: u16 = 0,
    row_count: u16 = 0,
    model_only: bool = false,
    /// Settings below the window, reported by the list's last row.
    hidden_below: usize = 0,
    /// Rows the visible settings and their model choices take.
    body_rows: u16 = 0,
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

pub fn visibleModelItemsForBudget(
    projection: SettingsMenuProjection,
    width: u16,
    row_budget: u16,
) u16 {
    const layout = buildBrowseLayout(projection, width, row_budget);
    var visible: u16 = 0;
    var row_index = layout.body_start_row;
    while (row_index < layout.row_count) : (row_index += 1) {
        switch (browseBodyRowAt(
            projection,
            layout,
            row_index - layout.body_start_row,
        )) {
            .model => visible += 1,
            else => {},
        }
    }
    return visible;
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
    if (layout.match_count == 0) {
        if (row_index != layout.body_start_row) return empty;
        return menu_frame.composeMessageRow(alloc, if (projection.query.len > 0) "no matching settings." else "no settings.", width);
    }
    const value_col = valueColumn(projection, width);
    return switch (browseBodyRowAt(projection, layout, row_index - layout.body_start_row)) {
        .none => empty,
        .item => |body| composeItemRow(alloc, projection.snapshot, body.item, body.selected, width, value_col),
        .model => |display_index| composeModelRow(alloc, projection, display_index, width, value_col),
        .more => |count| {
            var buf: [40]u8 = undefined;
            return menu_frame.composeMessageRow(alloc, std.mem.print(&buf, "↓ {d} more", .{count}) catch "↓ more", width);
        },
    };
}

fn buildBrowseLayout(projection: SettingsMenuProjection, width: u16, max_rows: u16) Layout {
    if (max_rows == 0) return .{};
    const match_count = projection.filteredItemCount();
    const selected = if (match_count == 0) 0 else projection.selected_index % match_count;
    const show_header = max_rows > 2;
    const body_start_row: u16 = if (show_header) roomy_header_rows else 0;
    // The list keeps its height while a filter narrows it, so the composer
    // stays put.
    const full_budget = @min(max_rows - body_start_row, list_rows);
    if (match_count == 0) {
        return .{
            .body_start_row = body_start_row,
            .row_count = body_start_row + @max(full_budget, 1),
        };
    }

    var layout = measureWindow(projection, width, selected, match_count, full_budget);
    // A list that runs past the window gives its last row to `↓ N more`.
    if (full_budget > 1 and layout.first_item + layout.visible_items < match_count) {
        layout = measureWindow(projection, width, selected, match_count, full_budget - 1);
        layout.hidden_below = match_count - (layout.first_item + layout.visible_items);
    }
    layout.match_count = match_count;
    layout.selected = selected;
    layout.body_start_row = body_start_row;
    layout.model_only = projection.models.active and full_budget == 1;
    layout.row_count = body_start_row + full_budget;
    return layout;
}

fn measureWindow(projection: SettingsMenuProjection, width: u16, selected: usize, match_count: usize, body_budget: u16) Layout {
    var first_item = if (projection.models.active)
        selected
    else
        @min(projection.window_start, match_count - 1);
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
        .first_item = first_item,
        .visible_items = body.visible_items,
        .body_rows = body.rows,
    };
}

const Measurement = struct {
    visible_items: u16 = 0,
    rows: u16 = 0,
};

fn measureBrowseBody(projection: SettingsMenuProjection, width: u16, first_item: usize, row_budget: u16) Measurement {
    var result: Measurement = .{};
    _ = width;
    var display_index = first_item;
    while (projection.itemAt(display_index)) |item| : (display_index += 1) {
        const required: u16 = 1;
        if (result.rows + required > row_budget) break;
        const model_rows: u16 = if (item.id == .model)
            @min(inlineModelRowCount(projection), row_budget - result.rows - required)
        else
            0;
        result.rows += required + model_rows;
        result.visible_items += 1;
    }
    if (projection.models.active and row_budget == 1 and result.visible_items > 0) {
        result.rows = 1;
    }
    return result;
}

fn browseBodyRowAt(projection: SettingsMenuProjection, layout: Layout, target: u16) BodyRow {
    if (layout.model_only) return if (target == 0) .{ .model = 0 } else .none;
    if (target >= layout.body_rows) {
        return if (layout.hidden_below > 0 and target == layout.body_rows) .{ .more = layout.hidden_below } else .none;
    }
    var row: u16 = 0;
    var offset: usize = 0;
    while (offset < layout.visible_items) : (offset += 1) {
        const display_index = layout.first_item + offset;
        const item = projection.itemAt(display_index) orelse return .none;
        if (row == target) return .{ .item = .{
            .item = item,
            .selected = display_index == layout.selected,
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
    }
    return .none;
}

fn composeBrowseHeader(alloc: Allocator, projection: SettingsMenuProjection, width: u16) !std.ArrayList(u8) {
    return menu_frame.composeTitleRow(alloc, "settings", projection.category.label(), width);
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
            .loading => "loading models…",
            .ready => "no matching models.",
            .failed => "models unavailable.",
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

fn valueColumn(projection: SettingsMenuProjection, width: u16) usize {
    const indent: usize = if (width <= 2) 0 else 2;
    var widest_label_width: usize = 0;
    var display_index: usize = 0;
    while (projection.itemAt(display_index)) |item| : (display_index += 1) {
        widest_label_width = @max(widest_label_width, display_width.visibleWidth(item.label));
    }
    // The gap narrows before the values start to clip.
    const gap: usize = if (indent + widest_label_width + widest_value_gap + 16 <= width) widest_value_gap else narrowest_value_gap;
    return @min(indent + widest_label_width + gap, width);
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

/// Draws every menu row through the VT and returns the plain text, one line
/// per row. The caller owns the returned text.
fn renderPlain(alloc: Allocator, projection: SettingsMenuProjection, width: u16, budget: u16) ![]u8 {
    const rows = menuRowCount(projection, width, budget);
    var grid = try vt_emulator.Grid.init(alloc, width, rows);
    defer grid.deinit();
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeSettingsMenuRow(alloc, projection, row_index, width, rows);
        defer row.deinit(alloc);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
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

test "settings menu draws the shared title, five settings, and a more row at a fixed height" {
    const alloc = std.testing.allocator;
    const projection: SettingsMenuProjection = .{ .active = true, .snapshot = test_snapshot };
    try std.testing.expectEqual(max_inline_rows, menuRowCount(projection, 100, 40));
    const text = try renderPlain(alloc, projection, 100, 40);
    defer alloc.free(text);
    try std.testing.expectEqualStrings(
        \\settings   < All >
        \\
        \\  Status line context        off  on
        \\  Status line session        off  on
        \\  Status line workspace      off  on
        \\  Slash menu categories      off  on
        \\  Collapse tool calls        off  on
        \\  ↓ 9 more
        \\
    , text);
    try std.testing.expectEqual(@as(u16, 5), visibleNavigationItemsForBudget(projection, 100, max_inline_rows));

    // Every option shows; the value in use is bright on every row.
    var row = try composeSettingsMenuRow(alloc, projection, 3, 100, max_inline_rows);
    defer row.deinit(alloc);
    const off_at = std.mem.find(u8, row.items, "off").?;
    try std.testing.expect(std.mem.endsWith(u8, row.items[0..off_at], ui_render.selected_completion_style));
}

test "settings menu values line up after the widest label, with a gap that narrows" {
    const alloc = std.testing.allocator;
    const projection: SettingsMenuProjection = .{ .active = true, .snapshot = test_snapshot, .selected_index = 5 };
    const text = try renderPlain(alloc, projection, 100, max_inline_rows);
    defer alloc.free(text);
    // The model's value starts in the same column as every other value.
    try std.testing.expect(std.mem.find(u8, text, "  Model                      zai/glm-5.2\n") != null);

    const narrow = try renderPlain(alloc, projection, 40, max_inline_rows);
    defer alloc.free(narrow);
    try std.testing.expect(std.mem.find(u8, narrow, "  Model                  zai/glm-5.2\n") != null);
}

test "settings menu keeps its height and says when a search finds nothing" {
    const alloc = std.testing.allocator;
    const projection: SettingsMenuProjection = .{ .active = true, .snapshot = test_snapshot, .query = "no setting has this name" };
    try std.testing.expectEqual(max_inline_rows, menuRowCount(projection, 80, 40));
    const text = try renderPlain(alloc, projection, 80, 40);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "settings   < All >\n\n  no matching settings.\n"));
}

test "settings model choices remain visible within the inline row budget" {
    const alloc = std.testing.allocator;
    const model_cache_runtime = @import("../../core/app/model_cache_runtime.zig");
    const models = [_]model_cache_runtime.ModelMenuItem{
        .{ .id = @constCast("provider/one"), .provider = "provider", .capabilities = .{} },
        .{ .id = @constCast("provider/two"), .provider = "provider", .capabilities = .{} },
        .{ .id = @constCast("provider/three"), .provider = "provider", .capabilities = .{} },
    };
    const projection: SettingsMenuProjection = .{
        .active = true,
        .selected_index = 5,
        .snapshot = test_snapshot,
        .models = .{ .active = true, .load_state = .ready, .items = &models },
    };
    const text = try renderPlain(alloc, projection, 100, max_inline_rows);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "  Model ") != null);
    try std.testing.expect(std.mem.find(u8, text, "provider/one") != null);
    try std.testing.expect(std.mem.find(u8, text, "provider/three") != null);
}
