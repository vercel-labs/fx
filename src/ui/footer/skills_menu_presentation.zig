const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const display_width = @import("../../core/shared/display_width.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const ui_render = @import("../render.zig");
const menu_frame = @import("menu_frame.zig");
const render_input = @import("render_input.zig");

const Allocator = std.mem.Allocator;
const SkillsMenuProjection = render_input.SkillsMenuProjection;

/// The title and the blank row under it.
const header_rows: u16 = 2;

pub const PreparedSkillsMenu = struct {
    projection: SkillsMenuProjection,
    row_budget: u16,
    layout: menu_frame.Layout,

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
        return self.projection.itemAt(self.layout.window_start + visible_offset);
    }
};

/// Lays out the skills menu without allocating; rows are drawn later by
/// `composeSkillsMenuRow`.
pub fn prepareInlineSkillsMenu(
    _: Allocator,
    projection: SkillsMenuProjection,
    row_budget: u16,
) !PreparedSkillsMenu {
    return .{
        .projection = projection,
        .row_budget = row_budget,
        .layout = frameLayout(projection, row_budget),
    };
}

pub fn inlineVisibleNavigationRowsForBudget(
    projection: SkillsMenuProjection,
    row_budget: u16,
) u16 {
    return frameLayout(projection, row_budget).visible_items;
}

pub fn inlineMenuRowCount(
    projection: SkillsMenuProjection,
    row_budget: u16,
) u16 {
    return frameLayout(projection, row_budget).row_count;
}

pub fn composeSkillsMenuRow(
    alloc: Allocator,
    prepared: PreparedSkillsMenu,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    var empty_buf: [96]u8 = undefined;
    const spec = frameSpec(&prepared.projection, prepared.row_budget, &empty_buf);
    return menu_frame.composeRow(alloc, spec, row_index, width, prepared.row_budget);
}

fn listCap(row_budget: u16) u16 {
    return if (row_budget > header_rows) row_budget - header_rows else row_budget;
}

fn selectedIndex(projection: SkillsMenuProjection, count: usize) usize {
    return if (count > 0) projection.selected_index % count else 0;
}

fn frameLayout(projection: SkillsMenuProjection, row_budget: u16) menu_frame.Layout {
    const count = projection.itemCount();
    return menu_frame.listLayout(count, selectedIndex(projection, count), projection.window_start, listCap(row_budget), row_budget);
}

fn frameSpec(projection: *const SkillsMenuProjection, row_budget: u16, empty_buf: []u8) menu_frame.Spec {
    const count = projection.itemCount();
    const empty = emptyText(projection.*, empty_buf);
    return .{
        .title = "skills",
        .active_tab = skill_runtime.skillMenuFilterLabel(projection.source_filter),
        .ctx = projection,
        .item_count = count,
        .column_count = 2,
        .cell = cell,
        .selected = selectedIndex(projection.*, count),
        .window_start = projection.window_start,
        .list_cap = listCap(row_budget),
        .empty_message = empty.message,
        .empty_hint = empty.hint,
    };
}

fn cell(ctx: *const anyopaque, item: usize, column: usize, _: []u8) []const u8 {
    const projection: *const SkillsMenuProjection = @ptrCast(@alignCast(ctx));
    const skill = projection.itemAt(item) orelse return "";
    return if (column == 0) skill.name else skillSourceScopeLabel(skill.source);
}

const EmptyText = struct {
    message: []const u8,
    hint: []const u8 = "",
};

fn emptyText(projection: SkillsMenuProjection, buf: []u8) EmptyText {
    if (projection.items.len == 0) return .{ .message = "no skills.", .hint = "add one to ~/.fx/skills." };
    if (projection.query.len > 0) return .{ .message = "no matching skills." };
    if (projection.source_filter == .all) return .{ .message = "no skills." };
    const message = std.mem.print(buf, "no {s} skills.", .{
        skill_runtime.skillMenuFilterLabel(projection.source_filter),
    }) catch "no skills.";
    return .{ .message = message, .hint = "press tab to change the source." };
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

fn testSkill(name: []const u8, source: skill_runtime.SkillSource) skill_runtime.Skill {
    return .{ .name = name, .description = "description", .path = "/tmp/skill/SKILL.md", .source = source };
}

test "skills menu labels native workspace skills with lowercase product name" {
    try std.testing.expectEqualStrings("fx · Workspace", skillSourceScopeLabel(.workspace_fx));
}

test "skills menu shows a plain title, only the active source, and single-line rows" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        testSkill("managed", .global_fx),
        testSkill("workspace", .workspace_codex),
    };
    const projection: SkillsMenuProjection = .{ .active = true, .items = &skills, .selected_index = 1 };
    var prepared = try prepareInlineSkillsMenu(alloc, projection, 8);
    defer prepared.deinit(alloc);
    // The menu holds its height: title, blank row, and six list rows.
    try std.testing.expectEqual(@as(u16, 8), prepared.rowCount());

    var title = try composeSkillsMenuRow(alloc, prepared, 0, 120);
    defer title.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, title.items, "skills") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "< All >") != null);
    try std.testing.expect(std.mem.find(u8, title.items, "skills 2") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "Skills") == null);
    try std.testing.expect(std.mem.find(u8, title.items, "OpenCode") == null);

    var gap = try composeSkillsMenuRow(alloc, prepared, 1, 120);
    defer gap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), gap.items.len);

    var selected = try composeSkillsMenuRow(alloc, prepared, 3, 120);
    defer selected.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, selected.items, ui_render.selected_completion_style));
    try std.testing.expect(std.mem.find(u8, selected.items, "workspace") != null);
    try std.testing.expect(std.mem.find(u8, selected.items, "Codex · Workspace") != null);
    try std.testing.expect(std.mem.find(u8, selected.items, "description") == null);
    try std.testing.expect(std.mem.find(u8, selected.items, "›") == null);

    var other = try composeSkillsMenuRow(alloc, prepared, 2, 120);
    defer other.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, other.items, ui_render.dim_style));
}

test "inline skills menu reserves a more row and prioritizes selection when tiny" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        testSkill("one", .global_fx),   testSkill("two", .global_fx),
        testSkill("three", .global_fx), testSkill("four", .global_fx),
        testSkill("five", .global_fx),  testSkill("six", .global_fx),
        testSkill("seven", .global_fx),
    };
    const projection: SkillsMenuProjection = .{ .active = true, .items = &skills, .selected_index = 6 };

    var roomy = try prepareInlineSkillsMenu(alloc, projection, 8);
    defer roomy.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 8), roomy.rowCount());
    try std.testing.expectEqual(@as(u16, 5), inlineVisibleNavigationRowsForBudget(projection, 8));
    try std.testing.expectEqual(@as(usize, 2), roomy.layout.window_start);

    var first: SkillsMenuProjection = projection;
    first.selected_index = 0;
    var top = try prepareInlineSkillsMenu(alloc, first, 8);
    defer top.deinit(alloc);
    var more = try composeSkillsMenuRow(alloc, top, 7, 40);
    defer more.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, more.items, "↓ 2 more") != null);

    var tiny = try prepareInlineSkillsMenu(alloc, projection, 1);
    defer tiny.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 1), tiny.rowCount());
    try std.testing.expectEqual(@as(u16, 1), inlineVisibleNavigationRowsForBudget(projection, 1));
    var tiny_row = try composeSkillsMenuRow(alloc, tiny, 0, 20);
    defer tiny_row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, tiny_row.items, "seven") != null);
    try std.testing.expect(std.mem.find(u8, tiny_row.items, "skills") == null);
}

test "prepared skills menu borrows one indexed query without allocating" {
    const skills = [_]skill_runtime.Skill{
        testSkill("ignored", .global_fx),
        testSkill("selected", .global_codex),
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
        testing_allocator.no_resize,
        .{ .fail_index = 0 },
    );

    var prepared = try prepareInlineSkillsMenu(failing.allocator(), projection, 4);
    defer prepared.deinit(failing.allocator());
    try std.testing.expectEqual(@as(u16, 4), prepared.rowCount());
    try std.testing.expectEqualStrings("selected", prepared.skillAtVisibleOffset(0).?.name);
}

test "skills menu empty states name the reason and the next step" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{testSkill("managed", .global_fx)};

    const cases = [_]struct { projection: SkillsMenuProjection, message: []const u8, hint: []const u8 }{
        .{ .projection = .{ .active = true, .items = &.{} }, .message = "no skills.", .hint = "add one to ~/.fx/skills." },
        .{ .projection = .{ .active = true, .items = &skills, .query = "missing" }, .message = "no matching skills.", .hint = "" },
        .{ .projection = .{ .active = true, .items = &skills, .source_filter = .codex }, .message = "no Codex skills.", .hint = "press tab to change the source." },
    };
    for (cases) |case| {
        var prepared = try prepareInlineSkillsMenu(alloc, case.projection, 6);
        defer prepared.deinit(alloc);
        try std.testing.expectEqual(@as(u16, 6), prepared.rowCount());
        var message = try composeSkillsMenuRow(alloc, prepared, 2, 80);
        defer message.deinit(alloc);
        try std.testing.expect(std.mem.startsWith(u8, message.items, ui_render.dim_style));
        try std.testing.expect(std.mem.find(u8, message.items, case.message) != null);
        var hint = try composeSkillsMenuRow(alloc, prepared, 3, 80);
        defer hint.deinit(alloc);
        if (case.hint.len > 0) try std.testing.expect(std.mem.find(u8, hint.items, case.hint) != null);
    }

    // A one-row budget still shows the message.
    var one_row = try prepareInlineSkillsMenu(alloc, .{ .active = true, .items = &skills, .query = "missing" }, 1);
    defer one_row.deinit(alloc);
    var row = try composeSkillsMenuRow(alloc, one_row, 0, 24);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.items, "no matching skills.") != null);
}

test "skills menu clips long names with a Unicode ellipsis" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{testSkill("very-long-skill-name-that-will-not-fit", .global_fx)};
    var prepared = try prepareInlineSkillsMenu(alloc, .{ .active = true, .items = &skills }, 8);
    defer prepared.deinit(alloc);

    var row = try composeSkillsMenuRow(alloc, prepared, 2, 24);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.items, "…") != null);
    try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 24);
}

test "skills menu source column stays fixed across scroll windows" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        testSkill("one", .global_opencode),
        testSkill("longest-skill-name", .global_opencode),
        testSkill("three", .global_opencode),
        testSkill("four", .global_opencode),
    };

    var first_window = try prepareInlineSkillsMenu(alloc, .{ .active = true, .items = &skills }, 4);
    defer first_window.deinit(alloc);
    var first_row = try composeSkillsMenuRow(alloc, first_window, 2, 80);
    defer first_row.deinit(alloc);

    var second_window = try prepareInlineSkillsMenu(alloc, .{ .active = true, .items = &skills, .selected_index = 3 }, 4);
    defer second_window.deinit(alloc);
    var second_row = try composeSkillsMenuRow(alloc, second_window, 2, 80);
    defer second_row.deinit(alloc);

    const first_scope = std.mem.find(u8, first_row.items, "OpenCode · Global") orelse return error.MissingFirstScope;
    const second_scope = std.mem.find(u8, second_row.items, "OpenCode · Global") orelse return error.MissingSecondScope;
    // Two-cell indent, the widest name, and the six-cell gap.
    try std.testing.expectEqual(@as(usize, 26), display_width.visibleWidthIgnoringAnsi(first_row.items[0..first_scope]));
    try std.testing.expectEqual(@as(usize, 26), display_width.visibleWidthIgnoringAnsi(second_row.items[0..second_scope]));
}

test "skills menu rows fit within one through four columns" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{testSkill("managed", .global_fx)};
    var prepared = try prepareInlineSkillsMenu(alloc, .{ .active = true, .items = &skills }, 1);
    defer prepared.deinit(alloc);
    for (1..5) |width| {
        var row = try composeSkillsMenuRow(alloc, prepared, 0, @intCast(width));
        defer row.deinit(alloc);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
    }
}
