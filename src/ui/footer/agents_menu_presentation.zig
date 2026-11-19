//! The agent list ↓, Ctrl+X, and `/agents` open: the menu frame's title, then
//! one row per open agent, in columns. Each fx comes first, named "main", or "fx 2"
//! while several are open, with its subagents under it on a branch, and a
//! subagent's own subagents under that one. A profile other than main
//! comes last:
//!
//!   agents
//!
//!   main              Fix the login bug       working             opus 4-7 high
//!   ├ reviewer        Review the parser       needs approval      opus 4-7
//!   │ └ checker       Check one fix           working             opus 4-7
//!   └ tester          Run the auth tests      idle                gpt-5.4-mini      tester

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const menu_frame = @import("menu_frame.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const AgentsMenuProjection = render_input.AgentsMenuProjection;
const AgentsMenuRow = render_input.AgentsMenuRow;

/// The title and the blank row under it.
const heading_rows: u16 = 2;
/// The list holds as many rows as the other menus; more agents than fit show
/// a `↓ N more` row in its last one.
const max_agent_rows: u16 = list_window.default_max_picker_rows;
/// The most rows the list takes.
pub const max_inline_rows: u16 = heading_rows + max_agent_rows;
/// The heading shows once the list also has room for this many agents, or
/// for all of them.
const agents_beside_heading: usize = 3;

const untitled = "new session";

/// The columns a subagent's row gives its branch.
fn branchWidth(row: AgentsMenuRow) usize {
    if (!row.subagent) return 0;
    return if (row.nested) 2 * branch_width else branch_width;
}

/// Whether no later row of `rows[index]`'s branch follows: the next one on
/// it, past any of its own subagents, before the branch it hangs off ends.
fn lastOnBranch(rows: []const AgentsMenuRow, index: usize) bool {
    const nested = rows[index].nested;
    for (rows[index + 1 ..]) |next| {
        if (!next.subagent) return true;
        if (next.nested == nested) return false;
        if (nested) return true;
    }
    return true;
}

/// The row of the subagent nested row `index` hangs off.
fn parentRow(rows: []const AgentsMenuRow, index: usize) usize {
    var at = index;
    while (at > 0 and rows[at].nested) at -= 1;
    return at;
}
/// The gap between columns, which narrows to `narrow_column_gap` before the
/// profile, the model, or the title gives up room.
const column_gap: usize = 6;
const narrow_column_gap: usize = 2;
const branch_width: usize = 2;
/// The widest state, "needs approval".
const max_state_width: usize = 14;
const max_name_width: usize = 22;
const max_profile_width: usize = 16;
const max_model_width: usize = 24;
const model_label_bytes = 160;
/// The title keeps this much room, or its own width when that is less,
/// before the profile and then the model give up theirs.
const min_title_width: usize = 14;

fn indentWidth(width: u16) usize {
    return if (width > 4) 2 else 0;
}

fn headingRowCount(projection: AgentsMenuProjection, row_budget: u16) u16 {
    const beside = @min(projection.rows.len, agents_beside_heading);
    return if (row_budget >= heading_rows + beside) heading_rows else 0;
}

/// Rows the list takes below the title: as many as the other menus, so a
/// search that narrows it doesn't move the composer.
fn listRows(projection: AgentsMenuProjection, row_budget: u16) u16 {
    return @min(max_agent_rows, row_budget -| headingRowCount(projection, row_budget));
}

/// Agents the list shows; the rest leave its last row to `↓ N more`.
fn visibleAgents(projection: AgentsMenuProjection, row_budget: u16) u16 {
    return list_window.visibleRowsWithMore(projection.rows.len, listRows(projection, row_budget));
}

pub fn menuRowCount(projection: AgentsMenuProjection, row_budget: u16) u16 {
    if (!projection.active()) return 0;
    return headingRowCount(projection, row_budget) + @max(listRows(projection, row_budget), 1);
}

/// The first agent shown: `projection.window_start`, moved only as far as it
/// takes to show the selected one, so the list scrolls at its edges.
pub fn windowStart(projection: AgentsMenuProjection, row_budget: u16) usize {
    return list_window.updateEdgeStart(
        projection.window_start,
        projection.rows.len,
        projection.selected,
        @max(visibleAgents(projection, row_budget), 1),
    );
}

/// Its session's title, else what a subagent is for, else `untitled`. The
/// purpose is model-written text like the title, and `appendCell` draws both
/// through the same escaping and display-width cut.
fn titleOf(row: AgentsMenuRow) []const u8 {
    if (row.title.len > 0) return row.title;
    return if (row.purpose.len > 0) row.purpose else untitled;
}

/// The model as the status line names it, then its effort, such as
/// "opus 4-7 high"; empty when the model is unknown. May use `buf`.
fn modelLabel(row: AgentsMenuRow, buf: *[model_label_bytes]u8) []const u8 {
    if (row.model.len == 0) return "";
    var compact_buf: [96]u8 = undefined;
    const model = ui_render.compactModelLabel(row.model, &compact_buf);
    const separator = if (row.effort.len > 0) " " else "";
    return std.mem.print(buf, "{s}{s}{s}", .{ model, separator, row.effort }) catch row.model;
}

/// The width of each column, the same for every row of the list. A width of
/// 0 leaves that column out.
const Columns = struct {
    /// A subagent's branch included.
    name: usize,
    title: usize,
    state: usize,
    profile: usize,
    model: usize,
    gap: usize = column_gap,

    /// Every column as wide as its widest value in `projection`, in `width`
    /// columns after `indent`. The gaps narrow first; then a title too long
    /// for its room is cut, and a narrow terminal leaves out the profile,
    /// then the model, so the name, title, and state always fit.
    fn of(projection: AgentsMenuProjection, width: usize, indent: usize) Columns {
        const wide = withGap(projection, width, indent, column_gap);
        const narrow = withGap(projection, width, indent, narrow_column_gap);
        const same = wide.title == narrow.title and wide.profile == narrow.profile and wide.model == narrow.model;
        return if (same) wide else narrow;
    }

    fn withGap(projection: AgentsMenuProjection, width: usize, indent: usize, gap: usize) Columns {
        var name: usize = 0;
        var title: usize = 0;
        var state: usize = 0;
        var profile: usize = 0;
        var model: usize = 0;
        for (projection.rows) |row| {
            const branch = branchWidth(row);
            name = @max(name, branch + text_utils.terminalSafeVisibleWidth(row.name));
            title = @max(title, text_utils.terminalSafeVisibleWidth(titleOf(row)));
            state = @max(state, text_utils.terminalSafeVisibleWidth(row.state));
            profile = @max(profile, text_utils.terminalSafeVisibleWidth(row.profile));
            var model_buf: [model_label_bytes]u8 = undefined;
            model = @max(model, text_utils.terminalSafeVisibleWidth(modelLabel(row, &model_buf)));
        }
        name = @min(name, max_name_width);
        state = @min(state, max_state_width);
        profile = @min(profile, max_profile_width);
        model = @min(model, max_model_width);

        // One column stays free at the right edge, as in the session list.
        const fixed = indent + name + gap + gap + state;
        const room = (width -| 1) -| fixed;
        const title_floor = @min(title, min_title_width);
        var columns: Columns = .{ .name = name, .title = title, .state = state, .profile = profile, .model = model, .gap = gap };
        if (room < title_floor + columns.columnRoom(columns.profile) + columns.columnRoom(columns.model)) columns.profile = 0;
        if (room < title_floor + columns.columnRoom(columns.profile) + columns.columnRoom(columns.model)) columns.model = 0;
        columns.title = @min(title, room -| (columns.columnRoom(columns.profile) + columns.columnRoom(columns.model)));
        return columns;
    }

    /// A column `width` wide and the gap before it.
    fn columnRoom(self: Columns, width: usize) usize {
        return if (width > 0) self.gap + width else 0;
    }

    fn titleStart(self: Columns, indent: usize) usize {
        return indent + self.name + self.gap;
    }

    fn stateStart(self: Columns, indent: usize) usize {
        return self.titleStart(indent) + self.columnRoom(self.title);
    }

    fn modelStart(self: Columns, indent: usize) usize {
        return self.stateStart(indent) + self.state + self.gap;
    }

    fn profileStart(self: Columns, indent: usize) usize {
        return self.modelStart(indent) + self.columnRoom(self.model);
    }
};

/// Pads `line` to column `start`, then adds `text` in `style`, cut to
/// `width` columns. A name or title comes from a prompt, which another agent
/// may have written, so its control bytes show as escapes. Empty text adds
/// nothing, so a row never ends in padding.
fn appendCell(
    alloc: Allocator,
    line: *std.ArrayList(u8),
    start: usize,
    text: []const u8,
    width: usize,
    style: []const u8,
) !void {
    if (text.len == 0 or width == 0) return;
    try row_text.appendSpacesToColumn(alloc, line, start);
    try line.appendSlice(alloc, style);
    try row_text.appendTerminalSafeSingleLine(alloc, line, text, width);
    try line.appendSlice(alloc, ui_render.reset_style);
}

fn composeHeadingRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    return menu_frame.composeTitleRow(alloc, "agents", null, width);
}

fn composeAgentRow(alloc: Allocator, projection: AgentsMenuProjection, index: usize, width: u16) !std.ArrayList(u8) {
    const rows = projection.rows;
    const row = rows[index];
    const selected = index == projection.selected;
    const indent = indentWidth(width);
    const columns: Columns = .of(projection, width, indent);
    // Selection is the whole row bold and bright, as in every menu; an
    // unselected row is gray throughout, its state included.
    const dim = if (selected) ui_render.selected_completion_style else ui_render.dim_style;

    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    try line.appendNTimes(alloc, ' ', indent);
    var name_start = indent;
    var name_width = columns.name;
    if (row.subagent) {
        // The branch runs down a fx's subagents and ends at the last one, and
        // a subagent's own subagents hang off it on a branch of their own. It
        // is dim on every row, the selected one too, so it reads as one line.
        try line.appendSlice(alloc, ui_render.dim_style);
        if (row.nested) try line.appendSlice(alloc, if (lastOnBranch(rows, parentRow(rows, index))) "  " else "│ ");
        try line.appendSlice(alloc, if (lastOnBranch(rows, index)) "└ " else "├ ");
        try line.appendSlice(alloc, ui_render.reset_style);
        name_start += branchWidth(row);
        name_width -|= branchWidth(row);
    }
    try appendCell(alloc, &line, name_start, row.name, name_width, dim);
    try appendCell(alloc, &line, columns.titleStart(indent), titleOf(row), columns.title, dim);
    try appendCell(alloc, &line, columns.stateStart(indent), row.state, columns.state, dim);
    var model_buf: [model_label_bytes]u8 = undefined;
    try appendCell(alloc, &line, columns.modelStart(indent), modelLabel(row, &model_buf), columns.model, dim);
    try appendCell(alloc, &line, columns.profileStart(indent), row.profile, columns.profile, dim);
    if (display_width.visibleWidthIgnoringAnsi(line.items) <= width) return line;

    // Too narrow for even the name and state: cut the row at the edge.
    var clipped: std.ArrayList(u8) = .empty;
    errdefer clipped.deinit(alloc);
    try row_text.appendClipped(alloc, &clipped, line.items, width);
    try clipped.appendSlice(alloc, ui_render.reset_style);
    line.deinit(alloc);
    return clipped;
}

pub fn composeAgentsMenuRow(
    alloc: Allocator,
    projection: AgentsMenuProjection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    if (width == 0 or row_index >= menuRowCount(projection, row_budget)) return .empty;
    const heading = headingRowCount(projection, row_budget);
    if (row_index < heading) {
        return if (row_index == 0) composeHeadingRow(alloc, width) else .empty;
    }
    const list_row = row_index - heading;
    if (projection.rows.len == 0) {
        return if (list_row == 0) menu_frame.composeMessageRow(alloc, "no matching agents.", width) else .empty;
    }
    const start = windowStart(projection, row_budget);
    const visible = visibleAgents(projection, row_budget);
    if (list_row >= visible) {
        const hidden = projection.rows.len -| (start + visible);
        if (list_row != visible or hidden == 0) return .empty;
        var buf: [40]u8 = undefined;
        return menu_frame.composeMessageRow(alloc, std.mem.print(&buf, "↓ {d} more", .{hidden}) catch "↓ more", width);
    }
    return composeAgentRow(alloc, projection, start + list_row, width);
}

const hint_variants = [_][]const u8{
    "↑↓ preview     enter switch     esc close",
    "↑↓ preview  enter switch  esc close",
    "↑↓ preview  enter  esc",
    "enter switch  esc close",
};

const closable_hint_variants = [_][]const u8{
    "↑↓ preview     enter switch     delete remove     esc close",
    "↑↓ preview  enter switch  delete remove  esc close",
    "↑↓ preview  enter  delete remove  esc",
    "enter switch  esc close",
};

const search_hint_variants = [_][]const u8{
    "↑↓ preview     enter switch     esc clear",
    "↑↓ preview  enter switch  esc clear",
    "↑↓ preview  enter  esc clear",
    "enter switch  esc clear",
};

const armed_hint_variants = [_][]const u8{
    "press delete again to remove this subagent",
};

const armed_instance_hint_variants = [_][]const u8{
    "press delete again to remove this instance",
};

/// Delete closes a subagent's or an instance's row after a second press
/// confirms it; while there is a search, it erases the search instead.
pub fn hintVariants(projection: AgentsMenuProjection) []const []const u8 {
    if (projection.close_armed) return if (projection.selected_instance) &armed_instance_hint_variants else &armed_hint_variants;
    if (projection.search.len > 0) return &search_hint_variants;
    if (projection.selected_closable) return &closable_hint_variants;
    return &hint_variants;
}

/// The visible text of row `row_index`, and whether it is drawn selected.
/// Caller owns the text.
fn testRow(projection: AgentsMenuProjection, row_index: u16, width: u16, row_budget: u16) !struct { text: []u8, selected: bool } {
    const alloc = std.testing.allocator;
    var row = try composeAgentsMenuRow(alloc, projection, row_index, width, row_budget);
    defer row.deinit(alloc);
    const selected = std.mem.find(u8, row.items, ui_render.selected_completion_style) != null;
    // The row as a terminal shows it.
    var grid = try vt_emulator.Grid.init(alloc, width, 1);
    defer grid.deinit();
    try grid.feed(row.items);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    try grid.rowTextTrimmed(1, &text);
    return .{ .text = try text.toOwnedSlice(alloc), .selected = selected };
}

fn expectRows(projection: AgentsMenuProjection, width: u16, row_budget: u16, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, menuRowCount(projection, row_budget));
    for (expected, 0..) |text, row_index| {
        const row = try testRow(projection, @intCast(row_index), width, row_budget);
        defer std.testing.allocator.free(row.text);
        try std.testing.expectEqualStrings(text, row.text);
    }
}

const test_team = [_]AgentsMenuRow{
    .{ .name = "main", .title = "Fix the login bug", .state = "working", .state_tone = .active, .model = "anthropic/claude-opus-4-7", .effort = "high" },
    .{ .name = "tester", .subagent = true, .title = "Run the auth tests", .profile = "tester", .state = "needs approval", .state_tone = .needs_user, .model = "openai/gpt-5.4-mini" },
    .{ .name = "docs", .subagent = true, .title = "", .state = "idle" },
};

test "the agent list shows the menu title, then each agent's name, title, state, model, and a profile other than main in columns" {
    const projection: AgentsMenuProjection = .{ .rows = &test_team, .selected = 1 };
    // The list keeps the other menus' height, so a search doesn't move the
    // composer.
    try expectRows(projection, 80, max_inline_rows, &.{
        "agents",
        "",
        "  main      Fix the login bug   working         opus 4-7 high",
        "  ├ tester  Run the auth tests  needs approval  gpt-5.4-mini   tester",
        "  └ docs    new session         idle",
        "",
        "",
        "",
    });
    for ([_]u16{ 2, 3, 4 }) |row_index| {
        const row = try testRow(projection, row_index, 80, max_inline_rows);
        defer std.testing.allocator.free(row.text);
        try std.testing.expectEqual(row_index == 3, row.selected);
    }
}

test "a working subagent's row keeps its title, and shows its call's time with its state" {
    const rows = [_]AgentsMenuRow{
        .{ .name = "main", .title = "Fix the login bug", .state = "working", .state_tone = .active, .model = "anthropic/claude-opus-4-7", .effort = "high" },
        .{ .name = "worker", .subagent = true, .title = "Run the auth tests", .state = "working 4m12s", .state_tone = .active, .model = "openai/gpt-5.4-mini" },
    };
    try expectRows(.{ .rows = &rows }, 80, max_inline_rows, &.{
        "agents",
        "",
        "  main          Fix the login bug       working            opus 4-7 high",
        "  \u{2514} worker      Run the auth tests      working 4m12s      gpt-5.4-mini",
        "",
        "",
        "",
        "",
    });
}

test "a search keeps the list's height, and says so when nothing matches" {
    const matched: AgentsMenuProjection = .{ .rows = test_team[1..2], .search = "TEST" };
    const heading = try testRow(matched, 0, 80, max_inline_rows);
    defer std.testing.allocator.free(heading.text);
    try std.testing.expectEqualStrings("agents", heading.text);
    try std.testing.expectEqual(max_inline_rows, menuRowCount(matched, max_inline_rows));
    try std.testing.expectEqualStrings("↑↓ preview     enter switch     esc clear", hintVariants(matched)[0]);

    try expectRows(.{ .search = "nobody" }, 80, max_inline_rows, &.{ "agents", "", "  no matching agents.", "", "", "", "", "" });
    try std.testing.expect(!(AgentsMenuProjection{}).active());
}

test "the agent list draws an unselected row gray throughout, its state included" {
    const alloc = std.testing.allocator;
    const projection: AgentsMenuProjection = .{ .rows = &test_team, .selected = 0 };
    var waiting = try composeAgentsMenuRow(alloc, projection, 3, 80, max_inline_rows);
    defer waiting.deinit(alloc);
    const dim = ui_render.dim_style;
    const reset = ui_render.reset_style;
    const expected_waiting = try alloc.print(
        "  {[dim]s}├ {[reset]s}{[dim]s}tester{[reset]s}  {[dim]s}Run the auth tests{[reset]s}" ++
            "  {[dim]s}needs approval{[reset]s}  {[dim]s}gpt-5.4-mini{[reset]s}   {[dim]s}tester{[reset]s}",
        .{ .dim = dim, .reset = reset },
    );
    defer alloc.free(expected_waiting);
    try std.testing.expectEqualStrings(expected_waiting, waiting.items);

    // The branch stays dim on the selected row.
    const chosen: AgentsMenuProjection = .{ .rows = &test_team, .selected = 2 };
    var last = try composeAgentsMenuRow(alloc, chosen, 4, 80, max_inline_rows);
    defer last.deinit(alloc);
    const expected_last = try alloc.print(
        "  {[dim]s}└ {[reset]s}{[bold]s}docs{[reset]s}    {[bold]s}new session{[reset]s}" ++
            "         {[bold]s}idle{[reset]s}",
        .{ .dim = dim, .reset = reset, .bold = ui_render.selected_completion_style },
    );
    defer alloc.free(expected_last);
    try std.testing.expectEqualStrings(expected_last, last.items);
}

test "the agent list draws the model after the state, and a profile other than main last, as a terminal shows it" {
    const alloc = std.testing.allocator;
    const width: u16 = 80;
    const projection: AgentsMenuProjection = .{ .rows = &test_team };
    const rows = menuRowCount(projection, max_inline_rows);
    var grid = try vt_emulator.Grid.init(alloc, width, rows);
    defer grid.deinit();
    var row_index: u16 = 0;
    while (row_index < rows) : (row_index += 1) {
        var row = try composeAgentsMenuRow(alloc, projection, row_index, width, max_inline_rows);
        defer row.deinit(alloc);
        var cursor_buf: [32]u8 = undefined;
        try grid.feed(try std.mem.print(&cursor_buf, "\x1b[{d};1H", .{row_index + 1}));
        try grid.feed(row.items);
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    // Main runs in the main profile, so nothing follows its model. Six-cell
    // gaps would leave out the tester's profile at this width, so the gaps
    // narrow to two.
    try grid.rowTextTrimmed(3, &text);
    try std.testing.expectEqualStrings("  main      Fix the login bug   working         opus 4-7 high", text.items);
    text.clearRetainingCapacity();
    try grid.rowTextTrimmed(4, &text);
    try std.testing.expectEqualStrings("  ├ tester  Run the auth tests  needs approval  gpt-5.4-mini   tester", text.items);
    // Every cell of an unselected row is gray, the state waiting for the
    // user too.
    const title = grid.cellAt(4, 13).?;
    const state = grid.cellAt(4, 33).?;
    const model = grid.cellAt(4, 49).?;
    const profile = grid.cellAt(4, 64).?;
    try std.testing.expectEqual(@as(u21, 'R'), title.codepoint);
    try std.testing.expectEqual(@as(u21, 'n'), state.codepoint);
    try std.testing.expectEqual(@as(u21, 'g'), model.codepoint);
    try std.testing.expectEqual(@as(u21, 't'), profile.codepoint);
    try std.testing.expect(model.style.eql(title.style));
    try std.testing.expect(profile.style.eql(title.style));
    try std.testing.expect(state.style.eql(title.style));
}

test "the agent list puts each fx's subagents under it on a branch that ends at the last one" {
    const rows = [_]AgentsMenuRow{
        .{ .name = "fx 1", .title = "Plan the parser work", .state = "idle" },
        .{ .name = "reviewer", .subagent = true, .title = "Review the parser", .state = "working", .state_tone = .active },
        .{ .name = "tester", .subagent = true, .title = "Run the auth tests", .profile = "tester", .state = "idle" },
        .{ .name = "fx 2", .title = "Trace the resize flake", .state = "has a question", .state_tone = .needs_user },
        .{ .name = "scout", .subagent = true, .title = "Map the session store", .state = "working", .state_tone = .active },
        .{ .name = "fx 3", .title = "", .state = "idle" },
    };
    try expectRows(.{ .rows = &rows }, 80, max_inline_rows, &.{
        "agents",
        "",
        "  fx 1            Plan the parser work        idle",
        "  ├ reviewer      Review the parser           working",
        "  └ tester        Run the auth tests          idle                tester",
        "  fx 2            Trace the resize flake      has a question",
        "  └ scout         Map the session store       working",
        "  fx 3            new session                 idle",
    });
}

test "a subagent's own subagents hang off its branch, which goes on past them to its next sibling" {
    const rows = [_]AgentsMenuRow{
        .{ .name = "main", .title = "Fix the login bug", .state = "working", .state_tone = .active },
        .{ .name = "lead", .subagent = true, .title = "Plan the fix", .state = "idle" },
        .{ .name = "helper", .subagent = true, .nested = true, .title = "Check one fix", .state = "working", .state_tone = .active },
        .{ .name = "checker", .subagent = true, .nested = true, .title = "Run the tests", .state = "idle" },
        .{ .name = "tester", .subagent = true, .title = "Run the auth tests", .profile = "tester", .state = "idle" },
        .{ .name = "scout", .subagent = true, .nested = true, .title = "Map the store", .state = "idle" },
    };
    try expectRows(.{ .rows = &rows }, 80, max_inline_rows, &.{
        "agents",
        "",
        "  main             Fix the login bug       working",
        "  ├ lead           Plan the fix            idle",
        "  │ ├ helper       Check one fix           working",
        "  │ └ checker      Run the tests           idle",
        "  └ tester         Run the auth tests      idle         tester",
        "    └ scout        Map the store           idle",
    });
}

test "the state column is as wide as the widest state shown, so the model follows an idle one closely" {
    const rows = [_]AgentsMenuRow{
        .{ .name = "main", .title = "Fix the login bug", .state = "idle", .model = "anthropic/claude-opus-4-7", .effort = "high" },
        .{ .name = "scout", .subagent = true, .title = "List the open items", .state = "idle", .model = "anthropic/claude-opus-4-7" },
    };
    try expectRows(.{ .rows = &rows }, 80, max_inline_rows, &.{
        "agents",
        "",
        "  main         Fix the login bug        idle      opus 4-7 high",
        "  └ scout      List the open items      idle      opus 4-7",
        "",
        "",
        "",
        "",
    });
}

test "a failed or stopped subagent's state fits the state column, wide and narrow" {
    const rows = [_]AgentsMenuRow{
        .{ .name = "main", .title = "Fix the login bug", .state = "working", .state_tone = .active },
        .{ .name = "builder", .subagent = true, .title = "Build the parser", .state = "failed", .model = "anthropic/claude-opus-4-7" },
        .{ .name = "tester", .subagent = true, .title = "Run the auth tests", .state = "stopped", .model = "openai/gpt-5.4-mini" },
        .{ .name = "docs", .subagent = true, .title = "", .state = "idle" },
    };
    const projection: AgentsMenuProjection = .{ .rows = &rows };
    // The column is as wide as the widest state shown, "stopped".
    try expectRows(projection, 80, max_inline_rows, &.{
        "agents",
        "",
        "  main           Fix the login bug       working",
        "  ├ builder      Build the parser        failed       opus 4-7",
        "  ├ tester       Run the auth tests      stopped      gpt-5.4-mini",
        "  └ docs         new session             idle",
        "",
        "",
    });
    // Narrower, the model goes first, and the state always fits.
    try expectRows(projection, 48, max_inline_rows, &.{
        "agents",
        "",
        "  main       Fix the login bug   working",
        "  ├ builder  Build the parser    failed",
        "  ├ tester   Run the auth tests  stopped",
        "  └ docs     new session         idle",
        "",
        "",
    });
    try expectRows(projection, 40, max_inline_rows, &.{
        "agents",
        "",
        "  main       Fix the login bug  working",
        "  ├ builder  Build the parser   failed",
        "  ├ tester   Run the auth tes…  stopped",
        "  └ docs     new session        idle",
        "",
        "",
    });
}

test "a stopped row that shows what its subagent is for keeps the state column, wide and narrow" {
    // After a quit and a resume, a subagent whose turn the quit cut short has
    // no title yet, so its row shows its purpose and says `stopped`.
    const rows = [_]AgentsMenuRow{
        .{ .name = "main", .title = "Fix the login bug", .state = "idle" },
        .{ .name = "scout", .subagent = true, .title = "", .purpose = "日本語日本語日本語日本語", .state = "stopped" },
        .{ .name = "docs", .subagent = true, .title = "", .purpose = "Write the docs.", .state = "idle" },
    };
    const projection: AgentsMenuProjection = .{ .rows = &rows };
    // Wide, the gaps keep their full width; at 48 columns they narrow, and
    // the state column stays aligned on every row.
    try expectRows(projection, 80, max_inline_rows, &.{
        "agents",
        "",
        "  main         Fix the login bug             idle",
        "  ├ scout      日本語日本語日本語日本語      stopped",
        "  └ docs       Write the docs.               idle",
        "",
        "",
        "",
    });
    try expectRows(projection, 48, max_inline_rows, &.{
        "agents",
        "",
        "  main     Fix the login bug         idle",
        "  ├ scout  日本語日本語日本語日本語  stopped",
        "  └ docs   Write the docs.           idle",
        "",
        "",
        "",
    });
    // Narrower, the title cell takes what is left: a cut keeps whole wide
    // characters, and the state column stays under one column on every row.
    try expectRows(projection, 40, max_inline_rows, &.{
        "agents",
        "",
        "  main     Fix the login bug    idle",
        "  ├ scout  日本語日本語日本語…  stopped",
        "  └ docs   Write the docs.      idle",
        "",
        "",
        "",
    });
    try expectRows(projection, 34, max_inline_rows, &.{
        "agents",
        "",
        "  main     Fix the logi…  idle",
        "  ├ scout  日本語日本語…  stopped",
        "  └ docs   Write the do…  idle",
        "",
        "",
        "",
    });
}

test "a narrow agent list narrows its gaps, then leaves out the profile, then the model, and cuts a long title" {
    const projection: AgentsMenuProjection = .{ .rows = &test_team };
    try expectRows(projection, 64, max_inline_rows, &.{
        "agents",
        "",
        "  main      Fix the login bug   working         opus 4-7 high",
        "  ├ tester  Run the auth tests  needs approval  gpt-5.4-mini",
        "  └ docs    new session         idle",
        "",
        "",
        "",
    });
    try expectRows(projection, 48, max_inline_rows, &.{
        "agents",
        "",
        "  main      Fix the login bug   working",
        "  ├ tester  Run the auth tests  needs approval",
        "  └ docs    new session         idle",
        "",
        "",
        "",
    });
    try expectRows(projection, 40, max_inline_rows, &.{
        "agents",
        "",
        "  main      Fix the lo…  working",
        "  ├ tester  Run the au…  needs approval",
        "  └ docs    new session  idle",
        "",
        "",
        "",
    });
}

test "a row's title comes before what the subagent is for, which comes before new session, whether the subagent works or not" {
    try std.testing.expectEqualStrings("Review the parser", titleOf(.{ .name = "a", .title = "Review the parser", .purpose = "You review the parser.", .state = "working" }));
    try std.testing.expectEqualStrings("You review the parser.", titleOf(.{ .name = "a", .title = "", .purpose = "You review the parser.", .state = "working" }));
    try std.testing.expectEqualStrings("Review the parser", titleOf(.{ .name = "a", .title = "Review the parser", .purpose = "You review the parser.", .state = "idle" }));
    try std.testing.expectEqualStrings("You review the parser.", titleOf(.{ .name = "a", .title = "", .purpose = "You review the parser.", .state = "idle" }));
    try std.testing.expectEqualStrings(untitled, titleOf(.{ .name = "a", .title = "", .purpose = "", .state = "idle" }));
}

test "a subagent with no title shows what it is for in the title's place, and a row with a title or none keeps its text" {
    const rows = [_]AgentsMenuRow{
        .{ .name = "main", .title = "", .state = "idle" },
        .{ .name = "auditor", .subagent = true, .title = "", .purpose = "You audit the parser.", .state = "working", .state_tone = .active },
        .{ .name = "writer", .subagent = true, .title = "Write the docs", .purpose = "You write the docs.", .state = "idle" },
        .{ .name = "scout", .subagent = true, .title = "", .purpose = "", .state = "idle" },
    };
    try expectRows(.{ .rows = &rows }, 80, max_inline_rows, &.{
        "agents",
        "",
        "  main           new session                idle",
        "  ├ auditor      You audit the parser.      working",
        "  ├ writer       Write the docs             idle",
        "  └ scout        new session                idle",
        "",
        "",
    });
}

test "a purpose is drawn as a title is: control bytes, bidi overrides, and wide characters are escaped or counted, and a cut keeps whole characters" {
    // An escape sequence, a right-to-left override, CJK, and an emoji.
    const wide = [_]AgentsMenuRow{
        .{ .name = "main", .title = "Fix the login bug", .state = "idle" },
        .{ .name = "scout", .subagent = true, .title = "", .purpose = "Audit \x1b[2J\u{202e}日本語 \u{1F642} logic", .state = "working", .state_tone = .active },
        .{ .name = "docs", .subagent = true, .title = "", .purpose = "Write", .state = "idle" },
    };
    // The state column starts under the same column on every row, so the wide
    // characters count as the columns they take.
    try expectRows(.{ .rows = &wide }, 80, max_inline_rows, &.{
        "agents",
        "",
        "  main         Fix the login bug                         idle",
        "  ├ scout      Audit \\x1b[2J\\u{202e}日本語 🙂 logic      working",
        "  └ docs       Write                                     idle",
        "",
        "",
        "",
    });
    for ([_]u16{ 2, 3, 4 }) |row_index| {
        const row = try testRow(.{ .rows = &wide }, row_index, 80, max_inline_rows);
        defer std.testing.allocator.free(row.text);
        try std.testing.expect(text_utils.isTerminalSafe(row.text));
    }

    // Too narrow for all of it: the cut lands between whole wide characters.
    const long = [_]AgentsMenuRow{.{ .name = "scout", .subagent = true, .title = "", .purpose = "日本語日本語日本語日本語", .state = "idle" }};
    try expectRows(.{ .rows = &long }, 30, 1, &.{
        "  └ scout  日本語日本…   idle",
    });
}

test "an agent's row shows its name's and title's control bytes as escapes" {
    const rows = [_]AgentsMenuRow{.{
        .name = "re\x1b[2Jview",
        .subagent = true,
        .title = "task \x1b]2;pwned\x07 \xc2\x9b2J",
        .state = "idle",
    }};
    const row = try testRow(.{ .rows = &rows }, 0, 120, 1);
    defer std.testing.allocator.free(row.text);
    try std.testing.expectEqualStrings("  └ re\\x1b[2Jview      task \\x1b]2;pwned\\x07 \\u{009b}2J      idle", row.text);
    try std.testing.expect(text_utils.isTerminalSafe(row.text));
}

test "the agent list scrolls to keep the selected agent in view, and counts the agents below it" {
    const names = "abcdef";
    var rows: [names.len]AgentsMenuRow = undefined;
    rows[0] = .{ .name = "main", .title = "t", .state = "idle" };
    for (rows[1..], 1..) |*row, at| row.* = .{ .name = names[at..][0..1], .subagent = true, .title = "t", .state = "idle" };
    var projection: AgentsMenuProjection = .{ .rows = &rows, .selected = 0 };
    // Two rows hold no title: one agent, then the more row.
    try expectRows(projection, 80, 2, &.{
        "  main      t      idle",
        "  ↓ 5 more",
    });
    projection.selected = 3;
    projection.window_start = windowStart(projection, 2);
    try expectRows(projection, 80, 2, &.{
        "  ├ d       t      idle",
        "  ↓ 2 more",
    });
    const shown = try testRow(projection, 0, 80, 2);
    defer std.testing.allocator.free(shown.text);
    try std.testing.expect(shown.selected);

    // Five rows hold the title and two agents above the more row, which a
    // window at the end leaves blank; a branch that goes on below stays open.
    projection.selected = 5;
    projection.window_start = windowStart(projection, 5);
    try expectRows(projection, 80, 5, &.{
        "agents",
        "",
        "  ├ e       t      idle",
        "  └ f       t      idle",
        "",
    });
    projection.selected = 2;
    projection.window_start = windowStart(projection, 5);
    try expectRows(projection, 80, 5, &.{
        "agents",
        "",
        "  ├ c       t      idle",
        "  ├ d       t      idle",
        "  ↓ 2 more",
    });
}
