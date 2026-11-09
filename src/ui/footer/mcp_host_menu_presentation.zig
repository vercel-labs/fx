//! Draws the `/mcp` menu as fx's picker: a
//! titled list, a server's facts, choices, and tools, and fx's hint line.
//! The logic is `core/mcp_host/menu.zig`; this only turns it into rows.

const std = @import("std");
const profile_paths = @import("../../core/shared/profile_paths.zig");
const display_width = @import("../../core/shared/display_width.zig");
const menu = @import("../../core/mcp_host/menu.zig");
const verbs = @import("../../core/mcp_host/verbs.zig");
const row_text = @import("row_text.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const Row = std.ArrayList(u8);

pub const max_inline_rows: u16 = menu.server_window + 1;
/// Where a server's facts start: after `http`, `runs`, `file`, `status`,
/// `protocol`, `error`.
const fact_col: usize = 12;

pub const Projection = struct {
    state: menu.State = .{},
    /// Every server, in config order.
    rows: []const menu.Row = &.{},
    /// What's typed in the composer, which filters the list, or the open
    /// server's tools on its screen.
    filter: []const u8 = "",
    tools: menu.Tools = .loading,
    /// What loading the config had to say, which `/mcp list` shows.
    notes: usize = 0,
    /// While the open server's sign-in waits for the browser, its address.
    sign_in_url: ?[]const u8 = null,
    /// The project config file, as shown. The profile file is named by
    /// `profile_paths.displayText`.
    project_file: []const u8 = ".mcp.json",

    pub fn active(p: Projection) bool {
        return p.state.active;
    }

    /// The open server, found by name among all servers.
    pub fn openRow(p: Projection) ?menu.Row {
        return menu.viewOf(&p.state, p.rows, "", p.tools, &.{}).open;
    }

    pub fn layout(p: Projection, r: menu.Row) menu.Layout {
        return menu.serverLayout(r, p.tools, p.filter, menu.server_window);
    }

    /// The server's screen at `width`: its layout with the waiting address.
    fn screenLayout(p: Projection, r: menu.Row, width: u16) menu.Layout {
        var l = p.layout(r);
        l.waiting = p.waitingLines(r, width);
        return l;
    }

    /// The sign-in address while the open server waits for the browser; null
    /// once its tools load.
    fn waitingAddress(p: Projection, r: menu.Row) ?[]const u8 {
        const url = p.sign_in_url orelse return null;
        if (url.len == 0 or menu.toolsFor(r, p.tools) == .ready) return null;
        return url;
    }

    /// The address's own lines below the heading: none when the heading
    /// links it, else the whole address, wrapped.
    fn waitingLines(p: Projection, r: menu.Row, width: u16) usize {
        const url = p.waitingAddress(r) orelse return 0;
        if (headingLinks(url, width)) return 0;
        const w = addressWidth(width);
        return (url.len + w - 1) / w;
    }

    fn fileOf(p: Projection, r: menu.Row) []const u8 {
        return if (r.status.source == .workspace) p.project_file else profile_paths.displayText("~/.fx/mcp.json");
    }
};

/// The rows the panel needs, at most `budget`.
pub fn menuRowCount(p: Projection, width: u16, budget: u16) u16 {
    if (!p.active() or budget == 0) return 0;
    var confirm: Confirm = undefined;
    const wanted: usize = switch (p.state.screen) {
        .list => blk: {
            var buf: [256]menu.Row = undefined;
            const shown = @max(listLines(menu.viewOf(&p.state, p.rows, p.filter, p.tools, &buf)), 1);
            break :blk 1 + (if (p.rows.len == 0) 2 else shown) + @as(usize, @intFromBool(p.notes > 0));
        },
        .server => if (p.openRow()) |r| serverRows(p, r, width) else 1,
        .confirm => if (p.openRow()) |r| (if (asksInPlace(p))
            serverRows(p, r, width)
        else
            1 + confirmLines(p, r, width, &confirm).len) else 1,
    };
    return @intCast(@min(wanted, budget));
}

/// A server's screen: its title and lines, the panel's height, made taller
/// so a waiting sign-in's address is never cut off.
fn serverRows(p: Projection, r: menu.Row, width: u16) usize {
    const l = p.screenLayout(r, width);
    return 1 + @min(l.lines(), menu.server_window + l.waiting);
}

fn addressWidth(width: u16) usize {
    return @max(@as(usize, width) -| 4, 16);
}

/// The indent, the transcript's label, and its period.
const sign_in_link_width = 2 + menu.sign_in_link_label.len + 1;

/// Whether the heading links the address in one line, as the transcript
/// does: it can be a link target and the label fits. Otherwise the address
/// is shown whole below it.
fn headingLinks(url: []const u8, width: u16) bool {
    return text_utils.isLinkTarget(url) and width >= sign_in_link_width;
}

/// The waiting sign-in's one line, its label linking the whole address so a
/// long one never fills the screen. Narrow screens drop the lead first; the
/// bare label always fits, as `headingLinks` checked.
fn signInLinkRow(alloc: Allocator, url: []const u8, width: u16) !Row {
    const leads = [_][]const u8{ "Waiting for the browser. Didn't open? ", "Didn't open? ", "" };
    const lead = for (leads) |candidate| {
        if (sign_in_link_width + candidate.len <= width) break candidate;
    } else "";
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, lead);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row.appendSlice(alloc, "\x1b]8;id=fx-mcp-sign-in;");
    try row.appendSlice(alloc, url);
    try row.appendSlice(alloc, "\x1b\\\x1b[4m" ++ menu.sign_in_link_label ++ "\x1b[24m\x1b]8;;\x1b\\");
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, ".");
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

/// The list's lines below its title: a line per server, and before the
/// servers that need attention their heading, set apart by a blank line
/// when servers that work come first.
fn listLines(v: menu.View) usize {
    return v.rows.len + headingLines(v);
}

fn headingLines(v: menu.View) usize {
    const start = v.attention_start orelse return 0;
    return if (start > 0) 2 else 1;
}

/// The list line the `i`th row of `v` is on, after the heading.
fn lineOfRow(v: menu.View, i: usize) usize {
    const start = v.attention_start orelse return i;
    return if (i >= start) i + headingLines(v) else i;
}

pub fn composeRow(alloc: Allocator, p: Projection, index: u16, width: u16, row_count: u16) !Row {
    if (width == 0 or index >= row_count or !p.active()) return .empty;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return switch (p.state.screen) {
        .list => listRow(alloc, arena, p, index, width, row_count),
        .server => serverRow(alloc, arena, p, index, width, row_count),
        .confirm => if (asksInPlace(p)) serverRow(alloc, arena, p, index, width, row_count) else confirmRow(alloc, arena, p, index, width),
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
    const view = menu.viewOf(&p.state, p.rows, p.filter, p.tools, &buf);
    const rows = view.rows;
    if (index == 0) {
        const meta = if (p.rows.len == 0)
            "none yet"
        else if (p.filter.len > 0)
            try arena.print("{d} of {d}", .{ rows.len, p.rows.len })
        else
            try arena.print("{d}", .{p.rows.len});
        return title(alloc, "MCP servers", meta, width);
    }
    const has_note = p.notes > 0;
    if (has_note and index == row_count - 1) {
        const note = try arena.print("{d} config note{s}: /mcp list shows {s}", .{ p.notes, if (p.notes == 1) "" else "s", if (p.notes == 1) "it" else "them" });
        return row_text.composeTextRow(alloc, note, width, ui_render.dim_style, 2);
    }
    if (p.rows.len == 0) return if (index == 1)
        row_text.composeTextRow(alloc, "Add one with /mcp add NAME URL", width, "", 2)
    else
        row_text.composeTextRow(alloc, "or /mcp add NAME -- COMMAND", width, "", 11);
    const body = row_count - 1 - @as(u16, @intFromBool(has_note));
    if (rows.len == 0) {
        const none = try arena.print("No server matches \"{s}\"", .{p.filter});
        return row_text.composeTextRow(alloc, none, width, ui_render.dim_style, 2);
    }
    const selected = p.state.selectedIndex(rows) orelse 0;
    // The window keeps the selection in view.
    const selected_line = lineOfRow(view, selected);
    const start = if (selected_line < body) 0 else selected_line + 1 - body;
    const line = start + (index - 1);
    if (line >= listLines(view)) return .empty;
    if (view.attention_start) |first| {
        const heading = headingLines(view);
        if (line >= first and line < first + heading) {
            if (line + 1 < first + heading) return .empty;
            return title(alloc, "Needs attention", try arena.print("{d}", .{rows.len - first}), width);
        }
        const i = if (line > first) line - heading else line;
        return serverListRow(alloc, arena, rows[i], i == selected, width);
    }
    return serverListRow(alloc, arena, rows[line], line == selected, width);
}

fn serverListRow(alloc: Allocator, arena: Allocator, r: menu.Row, selected: bool, width: u16) !Row {
    const show_source = width >= 64;
    const name_width: usize = std.math.clamp(@as(usize, width) / 4, 12, 22);
    const status_col = 2 + name_width + 2;
    const source_col = status_col + 22 + 2;
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    // Like fx's other pickers: dim rows, the selected one bright.
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    try row_text.appendTerminalSafeSingleLine(alloc, &row, r.status.name, name_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, status_col);
    const needs_you = r.status.needs_login or switch (r.status.state) {
        .failed, .retrying, .waiting_for_approval, .missing_env, .invalid_env => true,
        else => false,
    };
    // What needs the user stays bright so it stands out among dim rows.
    try row.appendSlice(alloc, if (needs_you) ui_render.hint_style else ui_render.dim_style);
    const status_width = if (show_source) 22 else @as(usize, width) -| status_col;
    try row_text.appendTerminalSafeSingleLine(alloc, &row, try verbs.statusText(arena, runState(r.status)), status_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (show_source) {
        try row_text.appendSpacesToColumn(alloc, &row, source_col);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, if (r.status.source == .workspace) "project" else "profile");
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

/// The status without its saved login: the menu says how a server runs, and
/// its screen puts the login beside that.
fn runState(s: anytype) @TypeOf(s) {
    var out = s;
    out.signed_in = false;
    return out;
}

/// The status fact on a server's screen. Its tool count is beside its
/// tools' heading and its login is in its choices, so neither repeats here.
fn statusFact(arena: Allocator, s: menu.Row) ![]const u8 {
    if (s.status.state == .ready and !s.status.needs_login) return "ready";
    return verbs.statusText(arena, runState(s.status));
}

/// Line `line` of a server's screen below its title.
fn serverLine(alloc: Allocator, arena: Allocator, p: Projection, r: menu.Row, l: menu.Layout, line: usize, width: u16) !Row {
    if (line < l.lead) {
        const facts = l.lead - 1;
        if (line >= facts) return .empty;
        const protocol_lines: usize = @intFromBool(r.status.version != null);
        if (line == 0) return row_text.composeFactRow(alloc, if (r.status.transport == .stdio) "runs" else @tagName(r.status.transport), r.target orelse "", width, fact_col, "");
        if (line == 1) return row_text.composeFactRow(alloc, "file", p.fileOf(r), width, fact_col, "");
        if (line == 2) return row_text.composeFactRow(alloc, "status", try statusFact(arena, r), width, fact_col, "");
        if (line == 3 and protocol_lines == 1) return row_text.composeFactRow(alloc, "protocol", r.status.version.?, width, fact_col, "");
        return row_text.composeFactRow(alloc, "error", r.status.last_error orelse "", width, fact_col, ui_render.hint_style);
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
        // Remove and Reject ask on their own row, answers included: the
        // chosen one is bright, and ← → move between them.
        if (asksInPlace(p) and p.state.confirm.? == cs[at]) {
            const answers = "   yes  no";
            const no = p.state.answer_no;
            try row_text.appendTerminalSafeSingleLine(alloc, &row, try question(arena, p, r, cs[at]), @as(usize, width) -| 2 -| answers.len);
            try row.appendSlice(alloc, ui_render.reset_style);
            try row.appendSlice(alloc, "   ");
            try row.appendSlice(alloc, if (no) ui_render.dim_style else ui_render.selected_completion_style);
            try row.appendSlice(alloc, "yes");
            try row.appendSlice(alloc, ui_render.reset_style);
            try row.appendSlice(alloc, "  ");
            try row.appendSlice(alloc, if (no) ui_render.selected_completion_style else ui_render.dim_style);
            try row.appendSlice(alloc, "no");
            try row.appendSlice(alloc, ui_render.reset_style);
            return row;
        }
        try row.appendSlice(alloc, cs[at].label());
        try row.appendSlice(alloc, ui_render.reset_style);
        if (width >= 56) {
            try row_text.appendSpacesToColumn(alloc, &row, 16);
            try row.appendSlice(alloc, ui_render.dim_style);
            const command = try arena.print("/mcp {s} {s}", .{ cs[at].verb(), r.status.name });
            try row_text.appendTerminalSafeSingleLine(alloc, &row, command, @as(usize, width) -| 16);
            try row.appendSlice(alloc, ui_render.reset_style);
        }
        return row;
    }
    const after = at - cs.len;
    if (after == 0) return .empty;
    if (after == 1) {
        if (p.waitingAddress(r)) |url| {
            if (headingLinks(url, width)) return signInLinkRow(alloc, url, width);
            return row_text.composeTextRow(alloc, "Waiting for the browser. Didn't open? Go to:", width, ui_render.dim_style, 2);
        }
    }
    if (after >= 2 and after < 2 + l.waiting) {
        // Where the heading can't link it: the whole address, wrapped, never cut.
        const url = p.sign_in_url orelse return .empty;
        const w = addressWidth(width);
        const from = @min((after - 2) * w, url.len);
        var row: Row = .empty;
        errdefer row.deinit(alloc);
        try row.appendSlice(alloc, "    ");
        // One link on every row of it, so a click on any opens the whole
        // address; one that can't be a link target is shown unlinked.
        const linked = text_utils.isLinkTarget(url);
        if (linked) {
            try row.appendSlice(alloc, "\x1b]8;id=fx-mcp-sign-in;");
            try row.appendSlice(alloc, url);
            try row.appendSlice(alloc, "\x1b\\\x1b[4m");
        }
        try row_text.appendTerminalSafeSingleLine(alloc, &row, url[from..@min(from + w, url.len)], w);
        if (linked) try row.appendSlice(alloc, "\x1b[24m\x1b]8;;\x1b\\");
        return row;
    }
    // From Log in until the address comes, the requests before it can take seconds.
    if (after == 1 and r.status.signing_in and menu.toolsFor(r, p.tools) != .ready)
        return row_text.composeTextRow(alloc, "Signing in…", width, ui_render.dim_style, 2);
    if (after == 1) {
        const heading: []const u8 = switch (menu.toolsFor(r, p.tools)) {
            .loading => "Loading tools…",
            .needs_login => "Its tools show here once you log in.",
            .needs_approval => "Its tools show here once you approve it.",
            .failed => |reason| try arena.print("Its tools couldn't load: {s}", .{reason}),
            .ready => |t| if (t.len == 0)
                "It has no tools."
            else if (p.filter.len == 0)
                try arena.print("Tools {d}", .{t.len})
            else if (l.tools == 0)
                "No tools match."
            else
                try arena.print("Tools {d} of {d}", .{ l.tools, t.len }),
        };
        return row_text.composeTextRow(alloc, heading, width, ui_render.dim_style, 2);
    }
    const tools = switch (p.tools) {
        .ready => |t| t,
        else => return .empty,
    };
    const ti = after - 2 - l.waiting;
    const tool = menu.nthTool(tools, p.filter, ti) orelse return .empty;
    const selected = p.state.cursor == cs.len + ti;
    var row: Row = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else "");
    try row.appendSlice(alloc, if (selected) "› " else "  ");
    try row_text.appendTerminalSafeSingleLine(alloc, &row, tool.name, 20);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, 24);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendTerminalSafeSingleLine(alloc, &row, tool.description, @as(usize, width) -| 24);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn serverRow(alloc: Allocator, arena: Allocator, shown: Projection, index: u16, width: u16, row_count: u16) !Row {
    const r = shown.openRow() orelse return .empty;
    if (index == 0) return title(alloc, r.status.name, "", width);
    const l = shown.screenLayout(r, width);
    // A filter typed since the last key can leave fewer items than the
    // selection's place; draw it on the last one left.
    var p = shown;
    p.state.cursor = @min(p.state.cursor, l.selectable() -| 1);
    const window: usize = row_count - 1;
    if (l.lines() <= window) return serverLine(alloc, arena, p, r, l, index - 1, width);
    const v = scrolled(p.state, l, window);
    const slot: usize = index - 1;
    if (slot < v.lines) return serverLine(alloc, arena, p, r, l, v.top + slot, width);
    if (slot == v.lines and v.below > 0) return countRow(alloc, arena, v.below, "more below", width);
    return .empty;
}

const Scrolled = struct { top: usize, lines: usize, below: usize };

/// What a scrolled server screen shows in `window` rows: the menu's logic
/// keeps the selection in view for the full panel, and a shorter panel
/// moves the view itself.
fn scrolled(state: menu.State, l: menu.Layout, window: usize) Scrolled {
    const shown = @max(window -| 1, 1);
    var top = @min(state.top, l.lines() - shown);
    const at = l.line(state.cursor);
    if (at < top) top = at;
    if (at >= top + shown) top = at + 1 - shown;
    if (state.cursor == 0) top = 0;
    var lines = window;
    if (top + lines < l.lines()) lines -= 1;
    lines = @min(lines, l.lines() - top);
    return .{ .top = top, .lines = lines, .below = l.lines() - top - lines };
}

fn countRow(alloc: Allocator, arena: Allocator, n: usize, where: []const u8, width: u16) !Row {
    return row_text.composeTextRow(alloc, try arena.print("{d} {s}", .{ n, where }), width, ui_render.dim_style, 2);
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
        .remove => std.mem.print(&out.question, "Remove {s} from {s}?", .{ name, p.fileOf(r) }),
        .approve => std.mem.print(&out.question, "Approve {s} for this project? It {s}:", .{ name, if (r.status.transport == .stdio) "runs" else "connects to" }),
        .reject => std.mem.print(&out.question, "Reject {s}? fx won't start it in this project.", .{name}),
        .login, .logout => std.mem.print(&out.question, "{s} {s}?", .{ c.label(), name }),
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
                    if (std.mem.findScalarLast(u8, rest[0..end], ' ')) |space| {
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
    // The confirmation hides the server's facts, so its title keeps the status.
    if (index == 0) return title(alloc, r.status.name, try statusFact(arena, r), width);
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

/// Remove and Reject ask on the server's own screen, on the choice's row, so
/// the panel keeps its size. An approval keeps its screen: it shows
/// everything it trusts, uncut.
fn asksInPlace(p: Projection) bool {
    const c = p.state.confirm orelse return false;
    return c.asksOnRow();
}

/// fx's hint line for where the menu is, widest first.
pub fn hintVariants(p: Projection) []const []const u8 {
    return switch (p.state.screen) {
        .list => if (p.rows.len == 0) &.{"esc close"} else &.{ "↑↓ navigate     enter open     esc close", "↑↓ move  enter open  esc", "enter open  esc close", "enter esc" },
        // A question asked in place leaves the server's hint line as it was;
        // the row shows its answers.
        .confirm => if (asksInPlace(p)) serverHints(p) else &.{ "enter confirm     esc cancel", "enter confirm  esc cancel", "enter esc" },
        .server => serverHints(p),
    };
}

fn serverHints(p: Projection) []const []const u8 {
    const r = p.openRow() orelse return &.{"esc back"};
    var buf: [menu.max_choices]menu.Choice = undefined;
    if (p.state.cursor >= menu.choices(r, &buf).len) return &.{ "↑↓ navigate     esc back", "↑↓ move  esc back", "esc" };
    return &.{ "↑↓ navigate     enter run     esc back", "↑↓ move  enter run  esc", "enter run  esc back", "enter esc" };
}

/// The question Remove or Reject asks on its row. The row draws it terminal
/// safe, so a name of any bytes stays inert.
fn question(arena: Allocator, p: Projection, r: menu.Row, c: menu.Choice) ![]const u8 {
    const name = r.status.name;
    return switch (c) {
        .remove => if (r.status.signed_in)
            arena.print("Remove {s} and its login from {s}?", .{ name, p.fileOf(r) })
        else
            arena.print("Remove {s} from {s}?", .{ name, p.fileOf(r) }),
        else => arena.print("Reject {s}? fx won't start it in this project.", .{name}),
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
        // A link: OSC up to its ST.
        if (std.mem.startsWith(u8, styled[i..], "\x1b]")) {
            i = if (std.mem.find(u8, styled[i..], "\x1b\\")) |end| i + end + 2 else styled.len;
            continue;
        }
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
    // The servers that work come first; the ones that need the user follow
    // under their own heading.
    try testing.expectEqualStrings(
        \\  MCP servers  3
        \\› context7                ready, 2 tools          profile
        \\
        \\  Needs attention  2
        \\  docs                    waiting for approval    project
        \\  linear                  needs login             profile
        \\
    , text);

    p.filter = "LIN";
    const filtered = try render(p, 88);
    defer testing.allocator.free(filtered);
    try testing.expectEqualStrings(
        \\  MCP servers  1 of 3
        \\  Needs attention  1
        \\› linear                  needs login             profile
        \\
    , filtered);

    p.filter = "";
    p.notes = 1;
    const narrow = try render(p, 48);
    defer testing.allocator.free(narrow);
    try testing.expectEqualStrings(
        \\  MCP servers  3
        \\› context7      ready, 2 tools
        \\
        \\  Needs attention  2
        \\  docs          waiting for approval
        \\  linear        needs login
        \\  1 config note: /mcp list shows it
        \\
    , narrow);
    try testing.expectEqualStrings("↑↓ navigate     enter open     esc close", hintVariants(p)[0]);
}

test "a long list scrolls to a selection below the attention heading" {
    var rows: [14]menu.Row = undefined;
    var names: [14][8]u8 = undefined;
    for (&rows, &names, 0..) |*r, *n, i| {
        var s = testStatus(try std.mem.print(n, "srv{d:0>2}", .{i}), .ready);
        s.needs_login = i >= 8;
        r.* = .{ .status = s };
    }
    var p: Projection = .{ .rows = &rows };
    menu.open(&p.state);
    var buf: [14]menu.Row = undefined;
    for (0..13) |_| _ = menu.press(&p.state, menu.viewOf(&p.state, &rows, "", .loading, &buf), .down);
    try testing.expectEqualStrings("srv13", p.state.selectedName());
    try testing.expectEqual(max_inline_rows, menuRowCount(p, 88, max_inline_rows));
    const text = try render(p, 88);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.find(u8, text, "  Needs attention  6\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "› srv13                   needs login             profile\n"));
}

test "the list says how a server runs; its login shows on its screen" {
    var plain = testStatus("plain", .idle);
    plain.signed_in = true;
    const rows = [_]menu.Row{.{ .status = plain }};
    var p: Projection = .{ .rows = &rows };
    menu.open(&p.state);
    const text = try render(p, 88);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\  MCP servers  1
        \\› plain                   not started             profile
        \\
    , text);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Its login shows as Log out among its choices, not in its status.
    try testing.expectEqualStrings("not started", try statusFact(arena.allocator(), rows[0]));
    var ready = testStatus("ready", .ready);
    ready.tools = 3;
    try testing.expectEqualStrings("ready", try statusFact(arena.allocator(), .{ .status = ready }));
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
        \\  github
        \\  http      https://api.githubcopilot.com/mcp/
        \\  file      ~/.fx/mcp.json
        \\  status    ready
        \\  protocol  2025-11-25
        \\
        \\› Log out       /mcp logout github
        \\  Remove        /mcp remove github
        \\
        \\  Tools 2
        \\  create_issue          Create a new issue.
        \\  search_code           Search for code.
        \\
    , text);
    // On a tool, Enter does nothing, so the hint doesn't offer it.
    p.state.cursor = 2;
    try testing.expectEqualStrings("↑↓ navigate     esc back", hintVariants(p)[0]);
}

test "a long tool list scrolls with the selection and counts what's below" {
    const gh = testStatus("github", .ready);
    const rows = [_]menu.Row{.{ .status = gh, .target = "https://h/mcp" }};
    var tools: [30]menu.Tool = undefined;
    var names: [30][8]u8 = undefined;
    for (&tools, &names, 0..) |*t, *n, i| t.* = .{ .name = try std.mem.print(n, "tool{d:0>2}", .{i}), .description = "" };
    var p: Projection = .{ .rows = &rows, .tools = .{ .ready = &tools } };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const view: menu.View = .{ .rows = &rows, .open = rows[0], .layout = p.layout(rows[0]) };
    for (0..12) |_| _ = menu.press(&p.state, view, .down);
    const text = try render(p, 60);
    defer testing.allocator.free(text);
    // What scrolled off the top isn't counted; what's below is.
    try testing.expect(std.mem.find(u8, text, "above\n") == null);
    try testing.expect(std.mem.find(u8, text, "more below\n") != null);
    try testing.expect(std.mem.find(u8, text, "› tool11") != null);
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

test "Remove asks on its own row, at the same size" {
    var gh = testStatus("github", .ready);
    gh.signed_in = true;
    const rows = [_]menu.Row{.{ .status = gh, .target = "https://api.github.com/mcp" }};
    var p: Projection = .{ .rows = &rows, .tools = .{ .ready = &.{} } };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    // Log out, then Remove.
    p.state.cursor = 1;
    const server_rows = menuRowCount(p, 88, 40);
    _ = menu.press(&p.state, .{ .rows = &rows, .open = rows[0], .layout = p.layout(rows[0]) }, .enter);
    try testing.expectEqual(menu.Screen.confirm, p.state.screen);
    try testing.expectEqual(server_rows, menuRowCount(p, 88, 40));
    // The question takes Remove's row with its answers; the hint line stays
    // the server screen's.
    const text = try render(p, 88);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.find(u8, text, "› Remove github and its login from ~/.fx/mcp.json?   yes  no\n") != null);
    try testing.expect(std.mem.find(u8, text, "  Log out       /mcp logout github\n") != null);
    try testing.expectEqualStrings("↑↓ navigate     enter run     esc back", hintVariants(p)[0]);
    var asked = try composeRow(testing.allocator, p, 6, 88, menuRowCount(p, 88, 40));
    defer asked.deinit(testing.allocator);
    const answers = try testing.allocator.print("{s}yes{s}  {s}no{s}", .{ ui_render.selected_completion_style, ui_render.reset_style, ui_render.dim_style, ui_render.reset_style });
    defer testing.allocator.free(answers);
    try testing.expect(std.mem.endsWith(u8, asked.items, answers));

    // A name of any bytes stays inert on the row.
    const odd_rows = [_]menu.Row{.{ .status = testStatus("x\x1b[2Jy", .ready) }};
    var odd: Projection = .{ .rows = &odd_rows, .tools = .{ .ready = &.{} } };
    menu.open(&odd.state);
    _ = menu.press(&odd.state, .{ .rows = &odd_rows }, .enter);
    _ = menu.press(&odd.state, .{ .rows = &odd_rows, .open = odd_rows[0], .layout = odd.layout(odd_rows[0]) }, .enter);
    var row = try composeRow(testing.allocator, odd, 5, 88, menuRowCount(odd, 88, 40));
    defer row.deinit(testing.allocator);
    try testing.expect(std.mem.find(u8, row.items, "Remove x") != null);
    try testing.expect(std.mem.find(u8, row.items, "\x1b[2J") == null);
}

test "a sign-in that waits links its address in one line, like the transcript" {
    var linear = testStatus("linear", .idle);
    linear.needs_login = true;
    const rows = [_]menu.Row{.{ .status = linear, .target = "https://mcp.linear.app/mcp" }};
    const url = "https://linear.app/oauth/authorize?client_id=abc&state=0123456789abcdef0123456789&x=1";
    var p: Projection = .{ .rows = &rows, .tools = .needs_login, .sign_in_url = url };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const text = try render(p, 80);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.find(u8, text, "  Waiting for the browser. Didn't open? Open the sign-in page.\n") != null);
    try testing.expect(std.mem.find(u8, text, "Its tools show here once you log in.") == null);
    try testing.expect(std.mem.find(u8, text, "https://linear.app/oauth") == null);
    // Title, three facts and a blank, two choices, a blank and the heading:
    // the address takes no lines of its own.
    try testing.expectEqual(@as(u16, 9), menuRowCount(p, 80, 40));
    p.sign_in_url = null;
    try testing.expectEqual(@as(u16, 9), menuRowCount(p, 80, 40));
    p.sign_in_url = url;

    // The label links the whole address; narrower screens drop the lead.
    for ([_]u16{ 80, 48, 24 }) |width| {
        const count = menuRowCount(p, width, 40);
        var row = try composeRow(testing.allocator, p, count - 1, width, count);
        defer row.deinit(testing.allocator);
        try testing.expect(std.mem.find(u8, row.items, "\x1b]8;id=fx-mcp-sign-in;" ++ url ++ "\x1b\\\x1b[4mOpen the sign-in page\x1b[24m\x1b]8;;\x1b\\") != null);
        try testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
    }
}

test "too narrow for the label, the waiting address is one link on every row it wraps to" {
    var linear = testStatus("linear", .idle);
    linear.needs_login = true;
    const rows = [_]menu.Row{.{ .status = linear, .target = "https://mcp.linear.app/mcp" }};
    const url = "https://linear.app/oauth/authorize?client_id=abc&state=0123456789abcdef0123456789&x=1";
    var p: Projection = .{ .rows = &rows, .tools = .needs_login, .sign_in_url = url };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    // 18 columns of address a row at width 22, so five rows come last.
    const count = menuRowCount(p, 22, 40);
    var heading = try composeRow(testing.allocator, p, count - 6, 22, count);
    defer heading.deinit(testing.allocator);
    try testing.expect(std.mem.find(u8, heading.items, "Waiting for the") != null);
    for (0..5) |i| {
        var row = try composeRow(testing.allocator, p, count - 5 + @as(u16, @intCast(i)), 22, count);
        defer row.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, row.items, "    \x1b]8;id=fx-mcp-sign-in;" ++ url ++ "\x1b\\\x1b[4m"));
        const piece = url[i * 18 .. @min(i * 18 + 18, url.len)];
        const close = "\x1b[24m\x1b]8;;\x1b\\";
        try testing.expect(std.mem.endsWith(u8, row.items, close));
        try testing.expect(std.mem.endsWith(u8, row.items[0 .. row.items.len - close.len], piece));
        try testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 22);
    }

    // An address that could end the sequence is shown, inert, without one.
    for ([_][]const u8{ "https://h/a\x1b\\\x1b]8;;evil", "https://h/a b", "https://h/\xc3\xa9" }) |odd| {
        p.sign_in_url = odd;
        const n = menuRowCount(p, 48, 40);
        var row = try composeRow(testing.allocator, p, n - 1, 48, n);
        defer row.deinit(testing.allocator);
        try testing.expect(std.mem.find(u8, row.items, "\x1b]") == null);
    }
}

// The address is the server's: no byte of it may end the link, start another
// sequence, or push a row past the width.
fn fuzzWaitingAddress(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x21, 0x7e, 8),
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, 0x1b, 2),
        .value(u8, 0x07, 1),
        .value(u8, '\\', 2),
        .value(u8, ']', 2),
    });
    const url = buffer[0..len];
    var linear = testStatus("linear", .idle);
    linear.needs_login = true;
    const rows = [_]menu.Row{.{ .status = linear, .target = "https://mcp.linear.app/mcp" }};
    var p: Projection = .{ .rows = &rows, .tools = .needs_login, .sign_in_url = url };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const width = smith.valueRangeAtMost(u16, 20, 140);
    const count = menuRowCount(p, width, max_inline_rows);
    const open = "\x1b]8;id=fx-mcp-sign-in;";
    const close = "\x1b]8;;\x1b\\";
    for (0..count) |i| {
        var row = try composeRow(testing.allocator, p, @intCast(i), width, count);
        defer row.deinit(testing.allocator);
        try testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        try testing.expect(std.mem.findScalar(u8, row.items, 0x07) == null);
        // Every OSC in a row is the link's, around an address that can't end it.
        var rest = row.items;
        while (std.mem.find(u8, rest, "\x1b]")) |at| {
            rest = rest[at..];
            if (std.mem.startsWith(u8, rest, close)) {
                rest = rest[close.len..];
                continue;
            }
            try testing.expect(text_utils.isLinkTarget(url));
            try testing.expect(std.mem.startsWith(u8, rest, open));
            try testing.expect(std.mem.startsWith(u8, rest[open.len..], url));
            try testing.expect(std.mem.startsWith(u8, rest[open.len + url.len ..], "\x1b\\"));
            rest = rest[open.len + url.len + 2 ..];
        }
    }
}

test "a waiting address of any bytes stays in its rows and inside its link" {
    try testing.fuzz({}, fuzzWaitingAddress, .{ .corpus = &.{
        "https://linear.app/oauth/authorize?client_id=abc&state=0123456789abcdef0123456789&x=1",
        "https://h/a\x1b\\\x1b]8;;evil\x07",
        "https://h/\xc3\xa9\xe2\x80\x8b",
    } });
}

test "a login under way says so until its address comes" {
    var linear = testStatus("linear", .idle);
    linear.needs_login = true;
    linear.signing_in = true;
    const rows = [_]menu.Row{.{ .status = linear, .target = "https://mcp.linear.app/mcp" }};
    var p: Projection = .{ .rows = &rows, .tools = .needs_login };
    menu.open(&p.state);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const text = try render(p, 80);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\  linear
        \\  http      https://mcp.linear.app/mcp
        \\  file      ~/.fx/mcp.json
        \\  status    needs login
        \\
        \\› Log in        /mcp login linear
        \\  Remove        /mcp remove linear
        \\
        \\  Signing in…
        \\
    , text);
    // Its address takes that line's place.
    p.sign_in_url = "https://linear.app/oauth/authorize?state=1";
    const waiting = try render(p, 80);
    defer testing.allocator.free(waiting);
    try testing.expect(std.mem.find(u8, waiting, "Signing in…") == null);
    try testing.expect(std.mem.find(u8, waiting, "Waiting for the browser. Didn't open? Open the sign-in page.") != null);
    // A server already signed in keeps its tools while it signs in again.
    var github = testStatus("github", .ready);
    github.signed_in = true;
    github.signing_in = true;
    const gh_rows = [_]menu.Row{.{ .status = github, .target = "https://h/mcp" }};
    var gh: Projection = .{ .rows = &gh_rows, .tools = .{ .ready = &.{} } };
    menu.open(&gh.state);
    _ = menu.press(&gh.state, .{ .rows = &gh_rows }, .enter);
    const ready = try render(gh, 80);
    defer testing.allocator.free(ready);
    try testing.expect(std.mem.find(u8, ready, "It has no tools.") != null);
    try testing.expect(std.mem.find(u8, ready, "Signing in…") == null);
}

test "names and errors from config and servers stay inert" {
    var bad = testStatus("x\x1b[2Jy", .failed);
    bad.last_error = "boom\x1b]0;owned\x07";
    const rows = [_]menu.Row{.{ .status = bad, .target = "https://h/\x1b[31m" }};
    var p: Projection = .{ .rows = &rows };
    menu.open(&p.state);
    const list = try render(p, 80);
    defer testing.allocator.free(list);
    try testing.expect(std.mem.findScalar(u8, list, 0x1b) == null);
    _ = menu.press(&p.state, .{ .rows = &rows }, .enter);
    const server = try render(p, 80);
    defer testing.allocator.free(server);
    try testing.expect(std.mem.findScalar(u8, server, 0x1b) == null);
    try testing.expect(std.mem.find(u8, server, "error     boom") != null);
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
        \\  linear
        \\  http      https://mcp.linear.app/mcp
        \\  file      ~/.fx/mcp.json
        \\  status    needs login
        \\
        \\› Log in        /mcp login linear
        \\  Remove        /mcp remove linear
        \\
        \\  Its tools show here once you log in.
        \\
    , text);
}
