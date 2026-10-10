//! Draws the `/mcp` menu on MCP-v2 as fx's picker: a
//! titled list, a server's facts, choices, and tools, and fx's hint line.
//! The logic is `core/mcp_host/menu.zig`; this only turns it into rows.

const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const menu = @import("../../core/mcp_host/menu.zig");
const verbs = @import("../../core/mcp_host/verbs.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Row = std.ArrayList(u8);

pub const max_inline_rows: u16 = menu.server_window + 1;
/// Where a server's facts start: after `http`, `runs`, `file`, `error`.
const fact_col: usize = 9;

pub const Projection = struct {
    state: menu.State = .{},
    /// Every server, in config order.
    rows: []const menu.Row = &.{},
    /// What's typed in the composer, which filters the list.
    filter: []const u8 = "",
    tools: menu.Tools = .loading,
    /// What loading the config had to say, which `/mcp list` shows.
    notes: usize = 0,
    /// The two config files, as shown.
    profile_file: []const u8 = "~/.fx/mcp.json",
    project_file: []const u8 = ".mcp.json",

    pub fn active(p: Projection) bool {
        return p.state.active;
    }

    /// The open server, found by name among all servers.
    pub fn openRow(p: Projection) ?menu.Row {
        return menu.viewOf(&p.state, p.rows, "", p.tools, &.{}).open;
    }

    pub fn layout(p: Projection, r: menu.Row) menu.Layout {
        return menu.serverLayout(r, p.tools, menu.server_window);
    }

    fn fileOf(p: Projection, r: menu.Row) []const u8 {
        return if (r.status.source == .workspace) p.project_file else p.profile_file;
    }
};

/// The rows the panel needs, at most `budget`.
pub fn menuRowCount(p: Projection, width: u16, budget: u16) u16 {
    if (!p.active() or budget == 0) return 0;
    var confirm: Confirm = undefined;
    const wanted: usize = switch (p.state.screen) {
        .list => blk: {
            const shown = @max(matching(p), 1);
            break :blk 1 + (if (p.rows.len == 0) 2 else shown) + @as(usize, @intFromBool(p.notes > 0));
        },
        .server => if (p.openRow()) |r| 1 + @min(p.layout(r).lines(), menu.server_window) else 1,
        .confirm => if (p.openRow()) |r| 1 + confirmLines(p, r, width, &confirm).len else 1,
    };
    return @intCast(@min(wanted, budget));
}

fn matching(p: Projection) usize {
    var n: usize = 0;
    for (p.rows) |r| n += @intFromBool(menu.matches(r.status.name, p.filter));
    return n;
}

pub fn composeRow(alloc: Allocator, p: Projection, index: u16, width: u16, row_count: u16) !Row {
    if (width == 0 or index >= row_count or !p.active()) return .empty;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return switch (p.state.screen) {
        .list => listRow(alloc, arena, p, index, width, row_count),
        .server => serverRow(alloc, arena, p, index, width, row_count),
        .confirm => confirmRow(alloc, arena, p, index, width),
    };
}

fn title(alloc: Allocator, name: []const u8, meta: []const u8, width: u16) !Row {
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.subtitle_style);
    try row_text.appendTerminalSafeSingleLine(alloc, &row, name, @as(usize, width) / 2);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendTerminalSafeSingleLine(alloc, &row, meta, @as(usize, width) -| display_width.visibleWidthIgnoringAnsi(row.items));
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn listRow(alloc: Allocator, arena: Allocator, p: Projection, index: u16, width: u16, row_count: u16) !Row {
    var buf: [256]menu.Row = undefined;
    const rows = menu.viewOf(&p.state, p.rows, p.filter, p.tools, &buf).rows;
    if (index == 0) {
        const meta = if (p.rows.len == 0)
            "none yet"
        else if (p.filter.len > 0)
            try std.fmt.allocPrint(arena, "{d} of {d}", .{ rows.len, p.rows.len })
        else
            try std.fmt.allocPrint(arena, "{d}", .{p.rows.len});
        return title(alloc, "MCP servers", meta, width);
    }
    const has_note = p.notes > 0;
    if (has_note and index == row_count - 1) {
        const note = try std.fmt.allocPrint(arena, "{d} config note{s}: /mcp list shows {s}", .{ p.notes, if (p.notes == 1) "" else "s", if (p.notes == 1) "it" else "them" });
        return row_text.composeTextRow(alloc, note, width, ui_render.dim_style, 2);
    }
    if (p.rows.len == 0) return if (index == 1)
        row_text.composeTextRow(alloc, "Add one with /mcp add NAME URL", width, "", 2)
    else
        row_text.composeTextRow(alloc, "or /mcp add NAME -- COMMAND", width, "", 11);
    const body = row_count - 1 - @as(u16, @intFromBool(has_note));
    if (rows.len == 0) {
        const none = try std.fmt.allocPrint(arena, "No server matches \"{s}\"", .{p.filter});
        return row_text.composeTextRow(alloc, none, width, ui_render.dim_style, 2);
    }
    const selected = p.state.selectedIndex(rows) orelse 0;
    // The window keeps the selection in view.
    const start = if (selected < body) 0 else selected + 1 - body;
    const i = start + (index - 1);
    if (i >= rows.len) return .empty;
    return serverListRow(alloc, arena, rows[i], i == selected, width);
}

fn serverListRow(alloc: Allocator, arena: Allocator, r: menu.Row, selected: bool, width: u16) !Row {
    const show_source = width >= 64;
    const name_width: usize = std.math.clamp(@as(usize, width) / 4, 12, 22);
    const status_col = 2 + name_width + 2;
    const source_col = status_col + 22 + 2;
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else "");
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    try row_text.appendTerminalSafeSingleLine(alloc, &row, r.status.name, name_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, status_col);
    const needs_you = r.status.needs_login or switch (r.status.state) {
        .failed, .retrying, .waiting_for_approval, .missing_env => true,
        else => false,
    };
    const idle = !needs_you and switch (r.status.state) {
        .idle, .disabled, .rejected, .unsupported => true,
        else => false,
    };
    try row.appendSlice(alloc, if (needs_you) ui_render.hint_style else if (idle) ui_render.dim_style else "");
    const status_width = if (show_source) 22 else @as(usize, width) -| status_col;
    try row_text.appendTerminalSafeSingleLine(alloc, &row, try verbs.statusText(arena, r.status), status_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (show_source) {
        try row_text.appendSpacesToColumn(alloc, &row, source_col);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, if (r.status.source == .workspace) "project" else "profile");
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn serverMeta(arena: Allocator, r: menu.Row) ![]const u8 {
    const status = try verbs.statusText(arena, r.status);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, status);
    if (r.status.signed_in and !std.mem.eql(u8, status, "signed in")) try out.appendSlice(arena, " · signed in");
    if (r.status.version) |v| try out.print(arena, " · protocol {s}", .{v});
    return out.items;
}

/// Line `line` of a server's screen below its title.
fn serverLine(alloc: Allocator, arena: Allocator, p: Projection, r: menu.Row, l: menu.Layout, line: usize, width: u16) !Row {
    if (line < l.lead) {
        const facts = l.lead - 1;
        if (line >= facts) return .empty;
        return switch (line) {
            0 => row_text.composeFactRow(alloc, if (r.status.transport == .stdio) "runs" else @tagName(r.status.transport), r.target orelse "", width, fact_col, ""),
            1 => row_text.composeFactRow(alloc, "file", p.fileOf(r), width, fact_col, ""),
            else => row_text.composeFactRow(alloc, "error", r.status.last_error orelse "", width, fact_col, ui_render.hint_style),
        };
    }
    var buf: [menu.max_choices]menu.Choice = undefined;
    const cs = menu.choices(r, &buf);
    const at = line - l.lead;
    if (at < cs.len) {
        const selected = p.state.cursor == at;
        var row: Row = .empty;
        errdefer row.deinit(alloc);
        try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else "");
        try row.appendSlice(alloc, if (selected) "› " else "  ");
        try row.appendSlice(alloc, cs[at].label());
        try row.appendSlice(alloc, ui_render.reset_style);
        if (width >= 56) {
            try row_text.appendSpacesToColumn(alloc, &row, 16);
            try row.appendSlice(alloc, ui_render.dim_style);
            const command = try std.fmt.allocPrint(arena, "/mcp {s} {s}", .{ cs[at].verb(), r.status.name });
            try row_text.appendTerminalSafeSingleLine(alloc, &row, command, @as(usize, width) -| 16);
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }
    const after = at - cs.len;
    if (after == 0) return .empty;
    if (after == 1) {
        const heading: []const u8 = switch (menu.toolsFor(r, p.tools)) {
            .loading => "Loading tools…",
            .needs_login => "Its tools show here once you log in.",
            .needs_approval => "Its tools show here once you approve it.",
            .failed => |reason| try std.fmt.allocPrint(arena, "Its tools couldn't load: {s}", .{reason}),
            .ready => |t| if (t.len == 0) "It has no tools." else "Tools",
        };
        return row_text.composeTextRow(alloc, heading, width, ui_render.dim_style, 2);
    }
    const tools = switch (p.tools) {
        .ready => |t| t,
        else => return .empty,
    };
    const ti = after - 2;
    if (ti >= tools.len) return .empty;
    const selected = p.state.cursor == cs.len + ti;
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else "");
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    try row_text.appendTerminalSafeSingleLine(alloc, &row, tools[ti].name, 20);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, 24);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendTerminalSafeSingleLine(alloc, &row, tools[ti].description, @as(usize, width) -| 24);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn serverRow(alloc: Allocator, arena: Allocator, p: Projection, index: u16, width: u16, row_count: u16) !Row {
    const r = p.openRow() orelse return .empty;
    if (index == 0) return title(alloc, r.status.name, try serverMeta(arena, r), width);
    const l = p.layout(r);
    const window: usize = row_count - 1;
    if (l.lines() <= window) return serverLine(alloc, arena, p, r, l, index - 1, width);
    const v = scrolled(p.state, l, window);
    var slot: usize = index - 1;
    if (v.top > 0) {
        if (slot == 0) return countRow(alloc, arena, v.top, "above", width);
        slot -= 1;
    }
    if (slot < v.lines) return serverLine(alloc, arena, p, r, l, v.top + slot, width);
    if (slot == v.lines and v.below > 0) return countRow(alloc, arena, v.below, "more below", width);
    return .empty;
}

const Scrolled = struct { top: usize, lines: usize, below: usize };

/// What a scrolled server screen shows in `window` rows: the menu's logic
/// keeps the selection in view for the full panel, and a shorter panel
/// moves the view itself.
fn scrolled(state: menu.State, l: menu.Layout, window: usize) Scrolled {
    const shown = @max(window -| 2, 1);
    var top = @min(state.top, l.lines() - shown);
    const at = l.line(state.cursor);
    if (at < top) top = at;
    if (at >= top + shown) top = at + 1 - shown;
    if (state.cursor == 0) top = 0;
    var lines = window - @intFromBool(top > 0);
    if (top + lines < l.lines()) lines -= 1;
    lines = @min(lines, l.lines() - top);
    return .{ .top = top, .lines = lines, .below = l.lines() - top - lines };
}

fn countRow(alloc: Allocator, arena: Allocator, n: usize, where: []const u8, width: u16) !Row {
    return row_text.composeTextRow(alloc, try std.fmt.allocPrint(arena, "{d} {s}", .{ n, where }), width, ui_render.dim_style, 2);
}

const ConfirmLine = struct { text: []const u8, style: enum { question, detail, target } };

const Confirm = struct {
    lines: [24]ConfirmLine,
    question: [512]u8,
};

/// The confirmation's lines below the title: a blank, the question, and
/// what it means. An approval's target wraps, and is never cut.
fn confirmLines(p: Projection, r: menu.Row, width: u16, out: *Confirm) []const ConfirmLine {
    var n: usize = 0;
    const c = p.state.confirm orelse return out.lines[0..0];
    out.lines[n] = .{ .text = "", .style = .detail };
    n += 1;
    const name = r.status.name;
    const q = switch (c) {
        .remove => std.fmt.bufPrint(&out.question, "Remove {s} from {s}?", .{ name, p.fileOf(r) }),
        .approve => std.fmt.bufPrint(&out.question, "Approve {s} for this project? It {s}:", .{ name, if (r.status.transport == .stdio) "runs" else "connects to" }),
        .reject => std.fmt.bufPrint(&out.question, "Reject {s}? fx won't start it in this project.", .{name}),
        .login, .logout => std.fmt.bufPrint(&out.question, "{s} {s}?", .{ c.label(), name }),
    } catch "Are you sure?";
    out.lines[n] = .{ .text = q, .style = .question };
    n += 1;
    switch (c) {
        .remove => if (r.status.signed_in) {
            out.lines[n] = .{ .text = "Its saved login is deleted too.", .style = .detail };
            n += 1;
        },
        .approve => {
            var rest = r.target orelse "";
            const limit = @max(@as(usize, width) -| 4, 16);
            while (rest.len > 0 and n < out.lines.len) {
                var end = @min(rest.len, limit);
                if (end < rest.len) {
                    if (std.mem.lastIndexOfScalar(u8, rest[0..end], ' ')) |space| {
                        if (space > 0) end = space;
                    }
                    // Never inside a character.
                    while (end > 1 and end < rest.len and rest[end] & 0xC0 == 0x80) end -= 1;
                }
                out.lines[n] = .{ .text = rest[0..end], .style = .target };
                n += 1;
                rest = std.mem.trimStart(u8, rest[end..], " ");
            }
        },
        else => {},
    }
    return out.lines[0..n];
}

fn confirmRow(alloc: Allocator, arena: Allocator, p: Projection, index: u16, width: u16) !Row {
    const r = p.openRow() orelse return .empty;
    if (index == 0) return title(alloc, r.status.name, try serverMeta(arena, r), width);
    var confirm: Confirm = undefined;
    const lines = confirmLines(p, r, width, &confirm);
    if (index - 1 >= lines.len) return .empty;
    const line = lines[index - 1];
    return switch (line.style) {
        .question => row_text.composeTextRow(alloc, line.text, width, ui_render.subtitle_style, 2),
        .detail => row_text.composeTextRow(alloc, line.text, width, ui_render.dim_style, 2),
        .target => row_text.composeTextRow(alloc, line.text, width, "", 4),
    };
}

/// fx's hint line for where the menu is, widest first.
pub fn hintVariants(p: Projection) []const []const u8 {
    return switch (p.state.screen) {
        .list => if (p.rows.len == 0) &.{"esc close"} else &.{ "↑↓ navigate     enter open     esc close", "↑↓ move  enter open  esc", "enter open  esc close", "enter esc" },
        .confirm => &.{ "enter confirm     esc cancel", "enter confirm  esc cancel", "enter esc" },
        .server => blk: {
            const r = p.openRow() orelse break :blk &.{"esc back"};
            var buf: [menu.max_choices]menu.Choice = undefined;
            if (p.state.cursor >= menu.choices(r, &buf).len) break :blk &.{ "↑↓ navigate     esc back", "↑↓ move  esc back", "esc" };
            break :blk &.{ "↑↓ navigate     enter run     esc back", "↑↓ move  enter run  esc", "enter run  esc back", "enter esc" };
        },
    };
}

const testing = std.testing;

const host_runtime = @import("../../core/mcp_host/runtime.zig");

fn testStatus(name: []const u8, state: host_runtime.State) host_runtime.Status {
    return .{ .name = name, .source = .profile, .transport = .http, .state = state };
}

fn render(p: Projection, width: u16) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const rows = menuRowCount(p, width, max_inline_rows);
    var i: u16 = 0;
    while (i < rows) : (i += 1) {
        var row = try composeRow(testing.allocator, p, i, width, rows);
        defer row.deinit(testing.allocator);
        try testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        try out.writer.print("{s}\n", .{try stripped(row.items)});
    }
    return out.toOwnedSlice();
}

var strip_buf: [4096]u8 = undefined;

fn stripped(styled: []const u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < styled.len) {
        if (styled[i] == 0x1b) {
            while (i < styled.len and styled[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        strip_buf[n] = styled[i];
        n += 1;
        i += 1;
    }
    return std.mem.trimEnd(u8, strip_buf[0..n], " ");
}

test "the list is fx's picker: a title, rows with status and source, and a filter" {
    var linear = testStatus("linear", .failed);
    linear.needs_login = true;
    var ctx = testStatus("context7", .ready);
    ctx.tools = 2;
    var docs = testStatus("docs", .waiting_for_approval);
    docs.source = .workspace;
    docs.transport = .stdio;
    const rows = [_]menu.Row{ .{ .status = linear }, .{ .status = ctx }, .{ .status = docs } };
    var p: Projection = .{ .rows = &rows };
    menu.open(&p.state);
    const text = try render(p, 88);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\  MCP servers  3
        \\› linear                  needs login             profile
        \\  context7                ready, 2 tools          profile
        \\  docs                    waiting for approval    project
        \\
    , text);

    p.filter = "LIN";
    const filtered = try render(p, 88);
    defer testing.allocator.free(filtered);
    try testing.expectEqualStrings(
        \\  MCP servers  1 of 3
        \\› linear                  needs login             profile
        \\
    , filtered);

    p.filter = "";
    p.notes = 1;
    const narrow = try render(p, 48);
    defer testing.allocator.free(narrow);
    try testing.expectEqualStrings(
        \\  MCP servers  3
        \\› linear        needs login
        \\  context7      ready, 2 tools
        \\  docs          waiting for approval
        \\  1 config note: /mcp list shows it
        \\
    , narrow);
    try testing.expectEqualStrings("↑↓ navigate     enter open     esc close", hintVariants(p)[0]);
}

test "a server's screen: facts, choices with their commands, then tools" {
    var gh = testStatus("github", .ready);
    gh.signed_in = true;
    gh.tools = 2;
    gh.version = "2025-11-25";
    const rows = [_]menu.Row{.{ .status = gh, .target = "https://api.githubcopilot.com/mcp/" }};
    const tools = [_]menu.Tool{ .{ .name = "create_issue", .description = "Create a new issue." }, .{ .name = "search_code", .description = "Search for code." } };
    var p: Projection = .{ .rows = &rows, .tools = .{ .ready = &tools } };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const text = try render(p, 88);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\  github  ready, 2 tools · signed in · protocol 2025-11-25
        \\  http   https://api.githubcopilot.com/mcp/
        \\  file   ~/.fx/mcp.json
        \\
        \\› Log out       /mcp logout github
        \\  Remove        /mcp remove github
        \\
        \\  Tools
        \\  create_issue          Create a new issue.
        \\  search_code           Search for code.
        \\
    , text);
    // On a tool, Enter does nothing, so the hint doesn't offer it.
    p.state.cursor = 2;
    try testing.expectEqualStrings("↑↓ navigate     esc back", hintVariants(p)[0]);
}

test "a long tool list scrolls with the selection, framed by what's hidden" {
    const gh = testStatus("github", .ready);
    const rows = [_]menu.Row{.{ .status = gh, .target = "https://h/mcp" }};
    var tools: [30]menu.Tool = undefined;
    var names: [30][8]u8 = undefined;
    for (&tools, &names, 0..) |*t, *n, i| t.* = .{ .name = std.fmt.bufPrint(n, "tool{d:0>2}", .{i}) catch unreachable, .description = "" };
    var p: Projection = .{ .rows = &rows, .tools = .{ .ready = &tools } };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const view: menu.View = .{ .rows = &rows, .open = rows[0], .layout = p.layout(rows[0]) };
    for (0..12) |_| _ = menu.press(&p.state, view, .down);
    const text = try render(p, 60);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "above\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "more below\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "› tool11") != null);
    try testing.expectEqual(@as(u16, max_inline_rows), menuRowCount(p, 60, max_inline_rows));
}

test "a confirmation names its target, and an approval shows everything it trusts" {
    var docs = testStatus("docs", .waiting_for_approval);
    docs.source = .workspace;
    docs.transport = .stdio;
    const rows = [_]menu.Row{.{ .status = docs, .target = "node ./scripts/docs-server.js --root . --port 4100 --watch" }};
    var p: Projection = .{ .rows = &rows };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    _ = menu.press(&p.state, .{ .rows = &rows, .open = rows[0], .layout = p.layout(rows[0]) }, .enter);
    try testing.expectEqual(menu.Screen.confirm, p.state.screen);
    const text = try render(p, 48);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\  docs  waiting for approval
        \\
        \\  Approve docs for this project? It runs:
        \\    node ./scripts/docs-server.js --root .
        \\    --port 4100 --watch
        \\
    , text);
    try testing.expectEqualStrings("enter confirm     esc cancel", hintVariants(p)[0]);
}

test "names and errors from config and servers stay inert" {
    var bad = testStatus("x\x1b[2Jy", .failed);
    bad.last_error = "boom\x1b]0;owned\x07";
    const rows = [_]menu.Row{.{ .status = bad, .target = "https://h/\x1b[31m" }};
    var p: Projection = .{ .rows = &rows };
    menu.open(&p.state);
    const list = try render(p, 80);
    defer testing.allocator.free(list);
    try testing.expect(std.mem.indexOfScalar(u8, list, 0x1b) == null);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const server = try render(p, 80);
    defer testing.allocator.free(server);
    try testing.expect(std.mem.indexOfScalar(u8, server, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, server, "error  boom") != null);
}

test "no servers points to /mcp add" {
    var p: Projection = .{};
    menu.open(&p.state);
    const text = try render(p, 80);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\  MCP servers  none yet
        \\  Add one with /mcp add NAME URL
        \\           or /mcp add NAME -- COMMAND
        \\
    , text);
    try testing.expectEqualStrings("esc close", hintVariants(p)[0]);
}

test "a server that needs a login says so, once" {
    var linear = testStatus("linear", .failed);
    linear.needs_login = true;
    linear.last_error = "it needs a login";
    const rows = [_]menu.Row{.{ .status = linear, .target = "https://mcp.linear.app/mcp" }};
    var p: Projection = .{ .rows = &rows };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const text = try render(p, 80);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\  linear  needs login
        \\  http   https://mcp.linear.app/mcp
        \\  file   ~/.fx/mcp.json
        \\
        \\› Log in        /mcp login linear
        \\  Remove        /mcp remove linear
        \\
        \\  Its tools show here once you log in.
        \\
    , text);
}
