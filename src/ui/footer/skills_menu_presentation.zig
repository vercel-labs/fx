const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const list_window = @import("../../core/shared/list_window.zig");
const ui_render = @import("../render.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const SkillsMenuProjection = render_input.SkillsMenuProjection;

const header_rows: u16 = 1;
const roomy_top_gap_rows: u16 = 1;
const title_rows: u16 = 1;
// Each skill is a single line now, so there is no separate description row
// or gap.
const description_rows: u16 = 0;
const item_gap_rows: u16 = 0;

const SkillsMenuLayout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    visible_items: u16 = 0,
    show_header: bool = true,
    first_item_row: u16 = header_rows,
    description_row_count: u16 = 0,
    item_stride: u16 = title_rows,
    row_count: u16 = 0,

    fn build(match_count: usize, selected_index: usize, row_budget: u16) SkillsMenuLayout {
        if (row_budget == 0) return .{};

        const selected = if (match_count > 0) selected_index % match_count else 0;
        if (match_count == 0) {
            return .{
                .match_count = 0,
                .row_count = @min(row_budget, header_rows + roomy_top_gap_rows + 1),
            };
        }

        if (row_budget == 1) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .row_count = 1,
            };
        }
        if (row_budget == 2) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .first_item_row = 1,
                .row_count = 2,
            };
        }
        if (row_budget < header_rows + roomy_top_gap_rows + title_rows + description_rows) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .first_item_row = 1,
                .description_row_count = 1,
                .item_stride = title_rows + description_rows,
                .row_count = 3,
            };
        }

        const first_item_row = header_rows + roomy_top_gap_rows;
        const item_stride = title_rows + description_rows + item_gap_rows;
        const item_budget = (row_budget - first_item_row +| item_gap_rows) / item_stride;
        const visible_items: u16 = @intCast(@min(match_count, @max(item_budget, 1)));
        return .{
            .match_count = match_count,
            .selected = selected,
            .visible_items = visible_items,
            .first_item_row = first_item_row,
            .description_row_count = description_rows,
            .item_stride = item_stride,
            .row_count = first_item_row + visible_items * item_stride - item_gap_rows,
        };
    }

    fn buildInline(match_count: usize, selected_index: usize, row_budget: u16) SkillsMenuLayout {
        if (row_budget == 0) return .{};

        const selected = if (match_count > 0) selected_index % match_count else 0;
        if (match_count == 0) {
            if (row_budget < header_rows + roomy_top_gap_rows + 1) {
                return .{
                    .show_header = false,
                    .first_item_row = 0,
                    .row_count = 1,
                };
            }
            return .{
                .first_item_row = header_rows + roomy_top_gap_rows,
                .row_count = header_rows + roomy_top_gap_rows + 1,
            };
        }

        if (row_budget <= 2) {
            const visible_items: u16 = @intCast(@min(match_count, row_budget));
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = visible_items,
                .show_header = false,
                .first_item_row = 0,
                .row_count = visible_items,
            };
        }

        const first_item_row = header_rows + roomy_top_gap_rows;
        const visible_items: u16 = @intCast(@min(match_count, row_budget - first_item_row));
        return .{
            .match_count = match_count,
            .selected = selected,
            .visible_items = visible_items,
            .first_item_row = first_item_row,
            .row_count = first_item_row + visible_items,
        };
    }
};

pub const PreparedSkillsMenu = struct {
    layout: SkillsMenuLayout,
    projection: SkillsMenuProjection,
    source_filter: skill_runtime.SkillMenuSourceFilter,
    catalog_empty: bool,
    window_start: usize,
    inline_name_column_width: ?usize,
    scope_column_width: usize,

    pub fn deinit(self: *PreparedSkillsMenu, _: Allocator) void {
        self.* = undefined;
    }

    pub fn rowCount(self: PreparedSkillsMenu) u16 {
        return self.layout.row_count;
    }

    pub fn skillAtVisibleOffset(
        self: PreparedSkillsMenu,
        visible_offset: usize,
    ) ?*const skill_runtime.Skill {
        if (visible_offset >= self.layout.visible_items) return null;
        return self.projection.itemAt(self.window_start + visible_offset);
    }
};

pub fn prepareSkillsMenu(
    alloc: Allocator,
    projection: SkillsMenuProjection,
    row_budget: u16,
) !PreparedSkillsMenu {
    const match_count = visibleSkillCount(projection);
    const layout = SkillsMenuLayout.build(match_count, projection.selected_index, row_budget);
    return prepareSkillsMenuWithLayout(alloc, projection, layout, false);
}

pub fn prepareInlineSkillsMenu(
    alloc: Allocator,
    projection: SkillsMenuProjection,
    row_budget: u16,
) !PreparedSkillsMenu {
    const match_count = visibleSkillCount(projection);
    const layout = SkillsMenuLayout.buildInline(match_count, projection.selected_index, row_budget);
    return prepareSkillsMenuWithLayout(alloc, projection, layout, true);
}

fn prepareSkillsMenuWithLayout(
    _: Allocator,
    projection: SkillsMenuProjection,
    layout: SkillsMenuLayout,
    inline_mode: bool,
) !PreparedSkillsMenu {
    const window_start = list_window.updateEdgeStart(
        projection.window_start,
        layout.match_count,
        layout.selected,
        layout.visible_items,
    );

    return .{
        .layout = layout,
        .projection = projection,
        .source_filter = projection.source_filter,
        .catalog_empty = projection.items.len == 0,
        .window_start = window_start,
        .inline_name_column_width = if (inline_mode) matching_name_column_width(projection) else null,
        .scope_column_width = scopeColumnWidth(
            projection,
            window_start,
            layout.visible_items,
        ),
    };
}

pub fn visibleNavigationRowsForBudget(
    projection: SkillsMenuProjection,
    row_budget: u16,
) u16 {
    return SkillsMenuLayout.build(
        visibleSkillCount(projection),
        projection.selected_index,
        row_budget,
    ).visible_items;
}

pub fn inlineVisibleNavigationRowsForBudget(
    projection: SkillsMenuProjection,
    row_budget: u16,
) u16 {
    return SkillsMenuLayout.buildInline(
        visibleSkillCount(projection),
        projection.selected_index,
        row_budget,
    ).visible_items;
}

pub fn inlineMenuRowCount(
    projection: SkillsMenuProjection,
    row_budget: u16,
) u16 {
    return SkillsMenuLayout.buildInline(
        visibleSkillCount(projection),
        projection.selected_index,
        row_budget,
    ).row_count;
}

pub fn composeSkillsMenuRow(
    alloc: Allocator,
    prepared: PreparedSkillsMenu,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    const row: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= prepared.layout.row_count) return row;
    if (prepared.layout.show_header and row_index == 0) {
        return composeHeaderRow(
            alloc,
            prepared.layout.match_count,
            prepared.source_filter,
            width,
        );
    }

    const layout = prepared.layout;
    if (layout.match_count == 0) {
        if (row_index < layout.row_count -| 1) return row;
        return composeEmptyRow(alloc, prepared.catalog_empty, prepared.source_filter, width);
    }
    if (row_index < layout.first_item_row) return row;

    const body_offset = row_index - layout.first_item_row;
    const visible_offset = body_offset / layout.item_stride;
    if (visible_offset >= layout.visible_items) return row;

    const display_index = prepared.window_start + visible_offset;
    const skill = (prepared.skillAtVisibleOffset(visible_offset) orelse return row).*;

    // item_stride is 1: every skill is a single row.
    return composeSkillTitleRow(
        alloc,
        skill,
        display_index == layout.selected,
        prepared.inline_name_column_width,
        prepared.scope_column_width,
        width,
    );
}

fn matching_name_column_width(projection: SkillsMenuProjection) usize {
    var col: usize = 0;
    var display_index: usize = 0;
    while (display_index < projection.itemCount()) : (display_index += 1) {
        const skill = projection.itemAt(display_index) orelse continue;
        col = @max(col, display_width.visibleWidth(skill.name));
    }
    return col;
}

// Widest source-scope label across the visible skills, so the scope column
// lines up vertically instead of drifting with each row's own width.
fn scopeColumnWidth(
    projection: SkillsMenuProjection,
    window_start: usize,
    visible_items: u16,
) usize {
    var col: usize = 0;
    var visible_offset: usize = 0;
    while (visible_offset < visible_items) : (visible_offset += 1) {
        const skill = projection.itemAt(window_start + visible_offset) orelse continue;
        col = @max(col, display_width.visibleWidth(skillSourceScopeLabel(skill.source)));
    }
    return col;
}

fn composeHeaderRow(
    alloc: Allocator,
    match_count: usize,
    source_filter: skill_runtime.SkillMenuSourceFilter,
    width: u16,
) !std.ArrayList(u8) {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try appendHeaderTitle(alloc, &wide, match_count);

    for (skill_runtime.skill_menu_source_filters) |filter| {
        try wide.appendSlice(alloc, "  ");
        try appendSourceTab(alloc, &wide, filter, filter == source_filter);
    }

    if (display_width.visibleWidthIgnoringAnsi(wide.items) <= width) {
        return try cloneClippedRow(alloc, wide.items, width);
    }

    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try appendHeaderTitle(alloc, &compact, match_count);
    try compact.appendSlice(alloc, "    ");
    try compact.appendSlice(alloc, ui_render.dim_style);
    try compact.appendSlice(alloc, "Source ");
    try compact.appendSlice(alloc, ui_render.reset_style);
    try appendSourceTab(alloc, &compact, source_filter, true);
    if (display_width.visibleWidthIgnoringAnsi(compact.items) <= width) {
        return try cloneClippedRow(alloc, compact.items, width);
    }

    compact.clearRetainingCapacity();
    try appendHeaderTitle(alloc, &compact, match_count);
    try compact.appendSlice(alloc, "  ");
    try appendSourceTab(alloc, &compact, source_filter, true);
    if (display_width.visibleWidthIgnoringAnsi(compact.items) <= width) {
        return try cloneClippedRow(alloc, compact.items, width);
    }

    compact.clearRetainingCapacity();
    try appendSourceTab(alloc, &compact, source_filter, true);
    return try cloneClippedRow(alloc, compact.items, width);
}

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Skills {d}", .{count}) catch "Skills";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendSourceTab(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    filter: skill_runtime.SkillMenuSourceFilter,
    active: bool,
) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, skill_runtime.skillMenuFilterLabel(filter));
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn composeSkillTitleRow(
    alloc: Allocator,
    skill: skill_runtime.Skill,
    selected: bool,
    inline_name_width: ?usize,
    scope_col: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);

    const indent_width: usize = if (width <= 4) 0 else 2;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");

    const scope = skillSourceScopeLabel(skill.source);
    const scope_width = @max(scope_col, display_width.visibleWidth(scope));
    const prefix_width = display_width.visibleWidthIgnoringAnsi(row.items);
    const content_width: usize = @as(usize, width) -| 1;
    const show_scope = if (inline_name_width) |name_col|
        scope_width > 0 and content_width >= prefix_width + name_col + picker_presentation.inline_picker_column_gap_width + scope_width
    else
        scope_width > 0 and content_width >= prefix_width + 8 + 2 + scope_width;
    const name_budget = if (!show_scope)
        @as(usize, width) -| prefix_width
    else if (inline_name_width) |name_col|
        name_col
    else
        content_width - prefix_width - scope_width - 2;

    // Selection by brightness: bold bright white when selected, dim gray
    // otherwise, applied to the whole row (name and scope). No marker glyph.
    const style = if (selected) ui_render.selected_completion_style else ui_render.dim_style;
    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, skill.name, name_budget);

    if (show_scope) {
        const scope_start = if (inline_name_width) |name_col|
            prefix_width + name_col + picker_presentation.inline_picker_column_gap_width
        else
            content_width - scope_width;
        try row_text.appendSpacesToColumn(alloc, &row, scope_start);
        try row.appendSlice(alloc, scope);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeEmptyRow(
    alloc: Allocator,
    catalog_empty: bool,
    source_filter: skill_runtime.SkillMenuSourceFilter,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    const text = if (catalog_empty)
        "No skills available."
    else if (source_filter == .all)
        "No skills found."
    else blk: {
        var buf: [96]u8 = undefined;
        break :blk std.fmt.bufPrint(
            &buf,
            "No {s} skills found.",
            .{skill_runtime.skillMenuFilterLabel(source_filter)},
        ) catch "No skills found.";
    };
    try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn skillSourceScopeLabel(source: skill_runtime.SkillSource) []const u8 {
    return switch (source) {
        .global_fx => "fx · Global",
        .workspace_fx => "fx · Workspace",
        .workspace_shared => "fx · Workspace",
        .workspace_opencode => "OpenCode · Workspace",
        .global_opencode => "OpenCode · Global",
        .workspace_codex => "Codex · Workspace",
        .global_codex => "Codex · Global",
        .workspace_claude => "Claude · Workspace",
        .global_claude => "Claude · Global",
        .workspace_agents => "Agents · Workspace",
        .global_agents => "Agents · Global",
        .workspace_claw => "Claw · Workspace",
        .global_claw => "Claw · Global",
    };
}

fn cloneClippedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn visibleSkillCount(projection: SkillsMenuProjection) usize {
    return projection.itemCount();
}

test "skills menu labels native workspace skills with lowercase product name" {
    try std.testing.expectEqualStrings("fx · Workspace", skillSourceScopeLabel(.workspace_fx));
}

test "skills menu renders source tabs and single-line results" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "managed", .description = "Managed skill description.", .path = "/tmp/managed/SKILL.md", .source = .global_fx },
        .{ .name = "workspace", .description = "Workspace skill description.", .path = "/tmp/workspace/SKILL.md", .source = .workspace_codex },
    };
    const projection: SkillsMenuProjection = .{
        .active = true,
        .items = &skills,
        .selected_index = 1,
    };
    var prepared = try prepareSkillsMenu(alloc, projection, 20);
    defer prepared.deinit(alloc);
    const rows = prepared.rowCount();
    // header + top gap + one row per skill.
    try std.testing.expectEqual(@as(u16, 4), rows);

    var header = try composeSkillsMenuRow(alloc, prepared, 0, 120);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Skills 2") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "[All]") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "OpenCode") != null);

    var gap = try composeSkillsMenuRow(alloc, prepared, 1, 120);
    defer gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), gap.items.len);

    // Selected skill on a single line: name + scope, no marker, no description.
    var selected = try composeSkillsMenuRow(alloc, prepared, 3, 120);
    defer selected.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, selected.items, "workspace") != null);
    try std.testing.expect(std.mem.find(u8, selected.items, "Codex · Workspace") != null);
    try std.testing.expect(std.mem.find(u8, selected.items, "/tmp/") == null);
    try std.testing.expect(std.mem.find(u8, selected.items, "●") == null);
    try std.testing.expect(std.mem.find(u8, selected.items, "○") == null);
    try std.testing.expect(std.mem.find(u8, selected.items, "Workspace skill description.") == null);
}

test "skills menu narrow header always shows the active source" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "description",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    const projection: SkillsMenuProjection = .{
        .active = true,
        .items = &skills,
        .source_filter = .opencode,
    };

    var prepared = try prepareSkillsMenu(alloc, projection, 3);
    defer prepared.deinit(alloc);
    var header = try composeSkillsMenuRow(alloc, prepared, 0, 32);
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.items, "Source ") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "[OpenCode]") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(header.items) <= 32);

    inline for (.{ @as(u16, 20), @as(u16, 21) }) |width| {
        var all_prepared = try prepareSkillsMenu(alloc, .{
            .active = true,
            .items = &skills,
            .source_filter = .all,
        }, 3);
        defer all_prepared.deinit(alloc);
        var all_header = try composeSkillsMenuRow(alloc, all_prepared, 0, width);
        defer all_header.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, all_header.items, "[All]") != null);
        try std.testing.expect(
            display_width.visibleWidthIgnoringAnsi(all_header.items) <= width,
        );

        var fx_prepared = try prepareSkillsMenu(alloc, .{
            .active = true,
            .items = &skills,
            .source_filter = .fx,
        }, 3);
        defer fx_prepared.deinit(alloc);
        var fx_header = try composeSkillsMenuRow(alloc, fx_prepared, 0, width);
        defer fx_header.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, fx_header.items, "[fx]") != null);
        try std.testing.expect(std.mem.find(u8, fx_header.items, "[Fx]") == null);
        try std.testing.expect(
            display_width.visibleWidthIgnoringAnsi(fx_header.items) <= width,
        );
    }
}

test "skills menu navigation budget counts whole items" {
    const skills = [_]skill_runtime.Skill{
        .{ .name = "one", .description = "one", .path = "/tmp/one", .source = .global_fx },
        .{ .name = "two", .description = "two", .path = "/tmp/two", .source = .global_fx },
        .{ .name = "three", .description = "three", .path = "/tmp/three", .source = .global_fx },
        .{ .name = "four", .description = "four", .path = "/tmp/four", .source = .global_fx },
    };
    const projection: SkillsMenuProjection = .{ .active = true, .items = &skills };

    // Single-line rows: header + gap (2) leave 8 for items, capped at 4 skills.
    try std.testing.expectEqual(@as(u16, 4), visibleNavigationRowsForBudget(projection, 10));
}

test "inline skills menu shows six roomy items and prioritizes selection when tiny" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "one", .description = "", .path = "/tmp/one", .source = .global_fx },
        .{ .name = "two", .description = "", .path = "/tmp/two", .source = .global_fx },
        .{ .name = "three", .description = "", .path = "/tmp/three", .source = .global_fx },
        .{ .name = "four", .description = "", .path = "/tmp/four", .source = .global_fx },
        .{ .name = "five", .description = "", .path = "/tmp/five", .source = .global_fx },
        .{ .name = "six", .description = "", .path = "/tmp/six", .source = .global_fx },
        .{ .name = "seven", .description = "", .path = "/tmp/seven", .source = .global_fx },
    };
    const projection: SkillsMenuProjection = .{
        .active = true,
        .items = &skills,
        .selected_index = 6,
    };

    var roomy = try prepareInlineSkillsMenu(alloc, projection, 8);
    defer roomy.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 8), roomy.rowCount());
    try std.testing.expectEqual(@as(u16, 6), inlineVisibleNavigationRowsForBudget(projection, 8));
    try std.testing.expectEqual(@as(usize, 1), roomy.window_start);

    var tiny = try prepareInlineSkillsMenu(alloc, projection, 1);
    defer tiny.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 1), tiny.rowCount());
    try std.testing.expectEqual(@as(u16, 1), inlineVisibleNavigationRowsForBudget(projection, 1));
    var tiny_row = try composeSkillsMenuRow(alloc, tiny, 0, 20);
    defer tiny_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, tiny_row.items, "seven") != null);
    try std.testing.expect(std.mem.find(u8, tiny_row.items, "Skills") == null);
}

test "prepared skills menu borrows one indexed query without allocating" {
    const skills = [_]skill_runtime.Skill{
        .{ .name = "ignored", .description = "", .path = "/skills/ignored", .source = .global_fx },
        .{ .name = "selected", .description = "", .path = "/skills/selected", .source = .global_codex },
    };
    const actual_indices = [_]u32{1};
    const projection: SkillsMenuProjection = .{
        .active = true,
        .items = &skills,
        .selected_index = 0,
        .actual_indices = &actual_indices,
        .index_ready = true,
    };
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    var prepared = try prepareInlineSkillsMenu(failing.allocator(), projection, 4);
    defer prepared.deinit(failing.allocator());
    try std.testing.expectEqual(@as(u16, 3), prepared.rowCount());
    try std.testing.expectEqualStrings("selected", prepared.skillAtVisibleOffset(0).?.name);
}

test "inline skills menu keeps an empty result visible at one row" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed",
        .source = .global_fx,
    }};
    const projection: SkillsMenuProjection = .{
        .active = true,
        .items = &skills,
        .query = "missing",
    };

    var prepared = try prepareInlineSkillsMenu(alloc, projection, 1);
    defer prepared.deinit(alloc);
    var row = try composeSkillsMenuRow(alloc, prepared, 0, 24);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.items, "No skills found.") != null);
}

test "skills menu keeps the selected whole item in its window" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "one", .description = "one description", .path = "/tmp/one", .source = .global_fx },
        .{ .name = "two", .description = "two description", .path = "/tmp/two", .source = .global_fx },
        .{ .name = "three", .description = "three description", .path = "/tmp/three", .source = .global_fx },
    };
    const projection: SkillsMenuProjection = .{
        .active = true,
        .items = &skills,
        .selected_index = 2,
        .window_start = 0,
    };
    var prepared = try prepareSkillsMenu(alloc, projection, 8);
    defer prepared.deinit(alloc);

    // Selected skill "three" (index 2) lands on its own single row.
    var title = try composeSkillsMenuRow(alloc, prepared, 4, 80);
    defer title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, title.items, "three") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "●") == null);
}

test "skills menu clips long names with a Unicode ellipsis" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "very-long-skill-name-that-will-not-fit",
        .description = "A very long description.",
        .path = "/tmp/long/SKILL.md",
        .source = .global_fx,
    }};
    const projection: SkillsMenuProjection = .{ .active = true, .items = &skills };
    var prepared = try prepareSkillsMenu(alloc, projection, 8);
    defer prepared.deinit(alloc);

    var title = try composeSkillsMenuRow(alloc, prepared, 2, 24);
    defer title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, title.items, "…") != null);
    try std.testing.expect(std.mem.findScalar(u8, title.items, '\n') == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(title.items) <= 24);
}

test "skills menu empty states stay compact and identify the source" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    const projection: SkillsMenuProjection = .{
        .active = true,
        .items = &skills,
        .source_filter = .codex,
    };
    var prepared = try prepareSkillsMenu(alloc, projection, 20);
    defer prepared.deinit(alloc);
    const rows = prepared.rowCount();
    try std.testing.expectEqual(@as(u16, 3), rows);

    var empty = try composeSkillsMenuRow(alloc, prepared, 2, 80);
    defer empty.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, empty.items, "No Codex skills found.") != null);
}

test "skills menu degrades to one complete item in a tiny row budget" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{.{
        .name = "managed",
        .description = "managed description",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    }};
    const projection: SkillsMenuProjection = .{ .active = true, .items = &skills };
    var prepared = try prepareSkillsMenu(alloc, projection, 3);
    defer prepared.deinit(alloc);
    const rows = prepared.rowCount();
    try std.testing.expectEqual(@as(u16, 3), rows);

    var title = try composeSkillsMenuRow(alloc, prepared, 2, 12);
    defer title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, title.items, "managed") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(title.items) <= 12);
}

test "prepared skills menu aligns sources beside the widest visible name" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "a", .description = "compat", .path = "/tmp/a", .source = .global_claw },
        .{ .name = "workspace", .description = "workspace", .path = "/tmp/workspace", .source = .workspace_shared },
        .{ .name = "managed", .description = "managed", .path = "/tmp/managed", .source = .global_fx },
        .{ .name = "much-longer", .description = "compat", .path = "/tmp/much-longer", .source = .global_opencode },
    };
    const projection: SkillsMenuProjection = .{
        .active = true,
        .items = &skills,
        .selected_index = 3,
    };

    var prepared = try prepareInlineSkillsMenu(alloc, projection, 4);
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), prepared.window_start);
    try std.testing.expectEqual(@as(u16, 2), prepared.layout.visible_items);
    try std.testing.expectEqualStrings("a", prepared.skillAtVisibleOffset(0).?.name);
    try std.testing.expectEqualStrings("much-longer", prepared.skillAtVisibleOffset(1).?.name);

    var first = try composeSkillsMenuRow(alloc, prepared, 2, 80);
    defer first.deinit(alloc);
    var second = try composeSkillsMenuRow(alloc, prepared, 3, 80);
    defer second.deinit(alloc);

    const first_scope = std.mem.find(u8, first.items, "Claw · Global") orelse return error.MissingFirstScope;
    const second_scope = std.mem.find(u8, second.items, "OpenCode · Global") orelse return error.MissingSecondScope;
    const first_scope_col = display_width.visibleWidthIgnoringAnsi(first.items[0..first_scope]);
    const second_scope_col = display_width.visibleWidthIgnoringAnsi(second.items[0..second_scope]);
    try std.testing.expectEqual(@as(usize, 17), first_scope_col);
    try std.testing.expectEqual(first_scope_col, second_scope_col);
    try std.testing.expect(std.mem.find(u8, second.items, ui_render.selected_completion_style) != null);
}

test "inline source column stays fixed to the widest matching skill across scroll windows" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "one", .description = "", .path = "/tmp/one", .source = .global_opencode },
        .{ .name = "longest-skill-name", .description = "", .path = "/tmp/longest", .source = .global_opencode },
        .{ .name = "three", .description = "", .path = "/tmp/three", .source = .global_opencode },
        .{ .name = "four", .description = "", .path = "/tmp/four", .source = .global_opencode },
    };

    var first_window = try prepareInlineSkillsMenu(alloc, .{
        .active = true,
        .items = &skills,
    }, 4);
    defer first_window.deinit(alloc);
    var first_row = try composeSkillsMenuRow(alloc, first_window, 2, 80);
    defer first_row.deinit(alloc);

    var second_window = try prepareInlineSkillsMenu(alloc, .{
        .active = true,
        .items = &skills,
        .selected_index = 3,
    }, 4);
    defer second_window.deinit(alloc);
    var second_row = try composeSkillsMenuRow(alloc, second_window, 2, 80);
    defer second_row.deinit(alloc);

    const first_scope = std.mem.find(u8, first_row.items, "OpenCode · Global") orelse return error.MissingFirstScope;
    const second_scope = std.mem.find(u8, second_row.items, "OpenCode · Global") orelse return error.MissingSecondScope;
    try std.testing.expectEqual(
        @as(usize, 24),
        display_width.visibleWidthIgnoringAnsi(first_row.items[0..first_scope]),
    );
    try std.testing.expectEqual(
        @as(usize, 24),
        display_width.visibleWidthIgnoringAnsi(second_row.items[0..second_scope]),
    );
}

test "skills menu result rows preserve content within one through four columns" {
    const alloc = std.testing.allocator;
    const skill: skill_runtime.Skill = .{
        .name = "managed",
        .description = "managed description",
        .path = "/tmp/managed/SKILL.md",
        .source = .global_fx,
    };

    for (1..5) |width| {
        const terminal_width: u16 = @intCast(width);
        var title = try composeSkillTitleRow(alloc, skill, true, null, 0, terminal_width);
        defer title.deinit(alloc);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(title.items) <= width);
        try std.testing.expect(std.mem.find(u8, title.items, "●") == null);
    }
}
