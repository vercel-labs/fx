//! The agent list ↓, Ctrl+X, and `/agents` open: a count, then one row per
//! open agent, in columns. Each fx comes first, named "main", or "fx 2"
//! while several are open, with its subagents under it on a branch, and a
//! subagent's own subagents under that one:
//!
//!   Agents 4
//!
//!   main          Fix the login bug   working         main    opus 4-7 high
//!   ├ reviewer    Review the parser   needs approval  main    opus 4-7
//!   │ └ checker   Check one fix       working         main    opus 4-7
//!   └ tester      Run the auth tests  idle            tester  gpt-5.4-mini

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const AgentsMenuProjection = render_input.AgentsMenuProjection;
const AgentsMenuRow = render_input.AgentsMenuRow;

/// The count and the blank row under it.
const heading_rows: u16 = 2;
/// The most agents shown before the list scrolls.
const max_agent_rows: u16 = 10;
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
const column_gap: usize = 2;
const branch_width: usize = 2;
/// The state column: as wide as the longest state, "needs approval".
const state_width: usize = 14;
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

pub fn menuRowCount(projection: AgentsMenuProjection, row_budget: u16) u16 {
    if (!projection.active()) return 0;
    return @intCast(@min(row_budget, headingRowCount(projection, row_budget) + projection.rows.len));
}

/// The first agent shown: `projection.window_start`, moved only as far as it
/// takes to show the selected one, so the list scrolls at its edges.
pub fn windowStart(projection: AgentsMenuProjection, row_budget: u16) usize {
    return picker_presentation.updateEdgeScrollPickerWindowStart(
        projection.window_start,
        projection.rows.len,
        projection.selected,
        row_budget - headingRowCount(projection, row_budget),
    );
}

fn titleOf(row: AgentsMenuRow) []const u8 {
    return if (row.title.len > 0) row.title else untitled;
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
    profile: usize,
    model: usize,

    /// Every column as wide as its widest value in `projection`, in `width`
    /// columns after `indent`. A title too long for its room is cut, and a
    /// narrow terminal leaves out the profile, then the model, so the name,
    /// title, and state always fit.
    fn of(projection: AgentsMenuProjection, width: usize, indent: usize) Columns {
        var name: usize = 0;
        var title: usize = 0;
        var profile: usize = 0;
        var model: usize = 0;
        for (projection.rows) |row| {
            const branch = branchWidth(row);
            name = @max(name, branch + text_utils.terminalSafeVisibleWidth(row.name));
            title = @max(title, text_utils.terminalSafeVisibleWidth(titleOf(row)));
            profile = @max(profile, text_utils.terminalSafeVisibleWidth(row.profile));
            var model_buf: [model_label_bytes]u8 = undefined;
            model = @max(model, text_utils.terminalSafeVisibleWidth(modelLabel(row, &model_buf)));
        }
        name = @min(name, max_name_width);
        profile = @min(profile, max_profile_width);
        model = @min(model, max_model_width);

        // One column stays free at the right edge, as in the session list.
        const fixed = indent + name + column_gap + column_gap + state_width;
        const room = (width -| 1) -| fixed;
        const title_floor = @min(title, min_title_width);
        if (room < title_floor + columnRoom(profile) + columnRoom(model)) profile = 0;
        if (room < title_floor + columnRoom(profile) + columnRoom(model)) model = 0;
        return .{
            .name = name,
            .title = @min(title, room -| (columnRoom(profile) + columnRoom(model))),
            .profile = profile,
            .model = model,
        };
    }

    /// A column `width` wide and the gap before it.
    fn columnRoom(width: usize) usize {
        return if (width > 0) column_gap + width else 0;
    }

    fn titleStart(self: Columns, indent: usize) usize {
        return indent + self.name + column_gap;
    }

    fn stateStart(self: Columns, indent: usize) usize {
        return self.titleStart(indent) + columnRoom(self.title);
    }

    fn profileStart(self: Columns, indent: usize) usize {
        return self.stateStart(indent) + state_width + column_gap;
    }

    fn modelStart(self: Columns, indent: usize) usize {
        return self.profileStart(indent) + columnRoom(self.profile);
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

fn composeHeadingRow(alloc: Allocator, projection: AgentsMenuProjection, width: u16) !std.ArrayList(u8) {
    var buf: [32]u8 = undefined;
    const text = std.mem.print(&buf, "Agents {d}", .{projection.rows.len}) catch "Agents";
    return row_text.composeTextRow(alloc, text, width, ui_render.selected_completion_style, indentWidth(width));
}

fn composeAgentRow(alloc: Allocator, projection: AgentsMenuProjection, index: usize, width: u16) !std.ArrayList(u8) {
    const rows = projection.rows;
    const row = rows[index];
    const selected = index == projection.selected;
    const indent = indentWidth(width);
    const columns: Columns = .of(projection, width, indent);
    // Selection is the whole row bold and bright, as in the session list.
    // An unselected row is dim, with its name and what it is doing in plain
    // text, and a state that waits for the user bright.
    const dim = if (selected) ui_render.selected_completion_style else ui_render.dim_style;
    const plain = if (selected) ui_render.selected_completion_style else "";
    const state_style = if (selected) ui_render.selected_completion_style else switch (row.state_tone) {
        .needs_user => ui_render.hint_style,
        .active => "",
        .idle => ui_render.dim_style,
    };

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
    try appendCell(alloc, &line, name_start, row.name, name_width, plain);
    try appendCell(alloc, &line, columns.titleStart(indent), titleOf(row), columns.title, dim);
    try appendCell(alloc, &line, columns.stateStart(indent), row.state, state_width, state_style);
    try appendCell(alloc, &line, columns.profileStart(indent), row.profile, columns.profile, dim);
    var model_buf: [model_label_bytes]u8 = undefined;
    try appendCell(alloc, &line, columns.modelStart(indent), modelLabel(row, &model_buf), columns.model, dim);
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
        return if (row_index == 0) composeHeadingRow(alloc, projection, width) else .empty;
    }
    const index = windowStart(projection, row_budget) + (row_index - heading);
    if (index >= projection.rows.len) return .empty;
    return composeAgentRow(alloc, projection, index, width);
}

const hint_variants = [_][]const u8{
    "↑↓ move     enter switch     esc back",
    "↑↓ move  enter switch  esc back",
    "↑↓ move  enter  esc",
    "enter switch  esc back",
};

const closable_hint_variants = [_][]const u8{
    "↑↓ move     enter switch     delete close     esc back",
    "↑↓ move  enter switch  delete close  esc back",
    "↑↓ move  enter  delete close  esc",
    "enter switch  esc back",
};

const search_hint_variants = [_][]const u8{
    "↑↓ move     enter switch     esc clear",
    "↑↓ move  enter switch  esc clear",
    "↑↓ move  enter  esc clear",
    "enter switch  esc clear",
};

const armed_hint_variants = [_][]const u8{
    "press delete again to close this subagent",
};

const armed_instance_hint_variants = [_][]const u8{
    "press delete again to close this instance",
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
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var index: usize = 0;
    while (index < row.items.len) {
        if (row.items[index] == 0x1b) {
            index = std.mem.findScalarPos(u8, row.items, index, 'm').? + 1;
            continue;
        }
        try text.append(alloc, row.items[index]);
        index += 1;
    }
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
    .{ .name = "main", .title = "Fix the login bug", .profile = "main", .state = "working", .state_tone = .active, .model = "anthropic/claude-opus-4-7", .effort = "high" },
    .{ .name = "tester", .subagent = true, .title = "Run the auth tests", .profile = "tester", .state = "needs approval", .state_tone = .needs_user, .model = "openai/gpt-5.4-mini" },
    .{ .name = "docs", .subagent = true, .title = "", .profile = "main", .state = "idle" },
};

test "the agent list counts the agents, then shows each one's name, title, state, profile, and model in columns" {
    const projection: AgentsMenuProjection = .{ .rows = &test_team, .selected = 1 };
    try expectRows(projection, 80, max_inline_rows, &.{
        "  Agents 3",
        "",
        "  main      Fix the login bug   working         main    opus 4-7 high",
        "  ├ tester  Run the auth tests  needs approval  tester  gpt-5.4-mini",
        "  └ docs    new session         idle            main",
    });
    for ([_]u16{ 2, 3, 4 }) |row_index| {
        const row = try testRow(projection, row_index, 80, max_inline_rows);
        defer std.testing.allocator.free(row.text);
        try std.testing.expectEqual(row_index == 3, row.selected);
    }
}

test "a search counts what it matched, and keeps the list open when nothing does" {
    const matched: AgentsMenuProjection = .{ .rows = test_team[1..2], .search = "TEST" };
    const heading = try testRow(matched, 0, 80, max_inline_rows);
    defer std.testing.allocator.free(heading.text);
    try std.testing.expectEqualStrings("  Agents 1", heading.text);
    try std.testing.expectEqual(@as(u16, 3), menuRowCount(matched, max_inline_rows));
    try std.testing.expectEqualStrings("↑↓ move     enter switch     esc clear", hintVariants(matched)[0]);

    try expectRows(.{ .search = "nobody" }, 80, max_inline_rows, &.{ "  Agents 0", "" });
    try std.testing.expect(!(AgentsMenuProjection{}).active());
}

test "the agent list draws an unselected row dim, with its name plain and a state that waits for the user bright" {
    const alloc = std.testing.allocator;
    const projection: AgentsMenuProjection = .{ .rows = &test_team, .selected = 0 };
    var waiting = try composeAgentsMenuRow(alloc, projection, 3, 80, max_inline_rows);
    defer waiting.deinit(alloc);
    const dim = ui_render.dim_style;
    const reset = ui_render.reset_style;
    const expected_waiting = try alloc.print(
        "  {[dim]s}├ {[reset]s}tester{[reset]s}  {[dim]s}Run the auth tests{[reset]s}" ++
            "  {[bright]s}needs approval{[reset]s}  {[dim]s}tester{[reset]s}  {[dim]s}gpt-5.4-mini{[reset]s}",
        .{ .dim = dim, .reset = reset, .bright = ui_render.hint_style },
    );
    defer alloc.free(expected_waiting);
    try std.testing.expectEqualStrings(expected_waiting, waiting.items);

    // The branch stays dim on the selected row.
    const chosen: AgentsMenuProjection = .{ .rows = &test_team, .selected = 2 };
    var last = try composeAgentsMenuRow(alloc, chosen, 4, 80, max_inline_rows);
    defer last.deinit(alloc);
    const expected_last = try alloc.print(
        "  {[dim]s}└ {[reset]s}{[bold]s}docs{[reset]s}    {[bold]s}new session{[reset]s}" ++
            "         {[bold]s}idle{[reset]s}            {[bold]s}main{[reset]s}",
        .{ .dim = dim, .reset = reset, .bold = ui_render.selected_completion_style },
    );
    defer alloc.free(expected_last);
    try std.testing.expectEqualStrings(expected_last, last.items);
}

test "the agent list puts each fx's subagents under it on a branch that ends at the last one" {
    const rows = [_]AgentsMenuRow{
        .{ .name = "fx 1", .title = "Plan the parser work", .profile = "main", .state = "idle" },
        .{ .name = "reviewer", .subagent = true, .title = "Review the parser", .profile = "main", .state = "working", .state_tone = .active },
        .{ .name = "tester", .subagent = true, .title = "Run the auth tests", .profile = "tester", .state = "idle" },
        .{ .name = "fx 2", .title = "Trace the resize flake", .profile = "main", .state = "has a question", .state_tone = .needs_user },
        .{ .name = "scout", .subagent = true, .title = "Map the session store", .profile = "main", .state = "working", .state_tone = .active },
        .{ .name = "fx 3", .title = "", .profile = "main", .state = "idle" },
    };
    try expectRows(.{ .rows = &rows }, 80, max_inline_rows, &.{
        "  Agents 6",
        "",
        "  fx 1        Plan the parser work    idle            main",
        "  ├ reviewer  Review the parser       working         main",
        "  └ tester    Run the auth tests      idle            tester",
        "  fx 2        Trace the resize flake  has a question  main",
        "  └ scout     Map the session store   working         main",
        "  fx 3        new session             idle            main",
    });
}

test "a subagent's own subagents hang off its branch, which goes on past them to its next sibling" {
    const rows = [_]AgentsMenuRow{
        .{ .name = "main", .title = "Fix the login bug", .profile = "main", .state = "working", .state_tone = .active },
        .{ .name = "lead", .subagent = true, .title = "Plan the fix", .profile = "main", .state = "idle" },
        .{ .name = "helper", .subagent = true, .nested = true, .title = "Check one fix", .profile = "main", .state = "working", .state_tone = .active },
        .{ .name = "checker", .subagent = true, .nested = true, .title = "Run the tests", .profile = "main", .state = "idle" },
        .{ .name = "tester", .subagent = true, .title = "Run the auth tests", .profile = "tester", .state = "idle" },
        .{ .name = "scout", .subagent = true, .nested = true, .title = "Map the store", .profile = "main", .state = "idle" },
    };
    try expectRows(.{ .rows = &rows }, 80, max_inline_rows, &.{
        "  Agents 6",
        "",
        "  main         Fix the login bug   working         main",
        "  ├ lead       Plan the fix        idle            main",
        "  │ ├ helper   Check one fix       working         main",
        "  │ └ checker  Run the tests       idle            main",
        "  └ tester     Run the auth tests  idle            tester",
        "    └ scout    Map the store       idle            main",
    });
}

test "a narrow agent list leaves out the profile, then the model, and cuts a long title" {
    const projection: AgentsMenuProjection = .{ .rows = &test_team };
    try expectRows(projection, 64, max_inline_rows, &.{
        "  Agents 3",
        "",
        "  main      Fix the login bug   working         opus 4-7 high",
        "  ├ tester  Run the auth tests  needs approval  gpt-5.4-mini",
        "  └ docs    new session         idle",
    });
    try expectRows(projection, 48, max_inline_rows, &.{
        "  Agents 3",
        "",
        "  main      Fix the login bug   working",
        "  ├ tester  Run the auth tests  needs approval",
        "  └ docs    new session         idle",
    });
    try expectRows(projection, 40, max_inline_rows, &.{
        "  Agents 3",
        "",
        "  main      Fix the lo…  working",
        "  ├ tester  Run the au…  needs approval",
        "  └ docs    new session  idle",
    });
}

test "an agent's row shows its name's and title's control bytes as escapes" {
    const rows = [_]AgentsMenuRow{.{
        .name = "re\x1b[2Jview",
        .subagent = true,
        .title = "task \x1b]2;pwned\x07 \xc2\x9b2J",
        .profile = "main",
        .state = "idle",
    }};
    const row = try testRow(.{ .rows = &rows }, 0, 120, 1);
    defer std.testing.allocator.free(row.text);
    try std.testing.expectEqualStrings("  └ re\\x1b[2Jview  task \\x1b]2;pwned\\x07 \\u{009b}2J  idle            main", row.text);
    try std.testing.expect(text_utils.isTerminalSafe(row.text));
}

test "the agent list scrolls to keep the selected agent in view, and a branch that goes on below the last row stays open" {
    const names = "abcdef";
    var rows: [names.len]AgentsMenuRow = undefined;
    rows[0] = .{ .name = "main", .title = "t", .profile = "main", .state = "idle" };
    for (rows[1..], 1..) |*row, at| row.* = .{ .name = names[at..][0..1], .subagent = true, .title = "t", .profile = "main", .state = "idle" };
    var projection: AgentsMenuProjection = .{ .rows = &rows, .selected = 0 };
    // Two rows hold no heading: both go to agents.
    try expectRows(projection, 80, 2, &.{
        "  main  t  idle            main",
        "  ├ b   t  idle            main",
    });
    projection.selected = 3;
    projection.window_start = windowStart(projection, 2);
    try expectRows(projection, 80, 2, &.{
        "  ├ c   t  idle            main",
        "  ├ d   t  idle            main",
    });
    const bottom = try testRow(projection, 1, 80, 2);
    defer std.testing.allocator.free(bottom.text);
    try std.testing.expect(bottom.selected);

    // Five rows hold the heading and three agents.
    projection.selected = 5;
    projection.window_start = windowStart(projection, 5);
    try expectRows(projection, 80, 5, &.{
        "  Agents 6",
        "",
        "  ├ d   t  idle            main",
        "  ├ e   t  idle            main",
        "  └ f   t  idle            main",
    });
}
