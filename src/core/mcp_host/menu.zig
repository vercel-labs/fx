//! The `/mcp` menu's logic: fx's picker
//! showing servers. A server's actions are choices that run the `/mcp`
//! verbs, so the menu adds nothing of its own. Pure: the shell's state owns
//! one, and the footer draws it.

const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const runtime = @import("runtime.zig");

pub const Screen = enum { list, server, confirm };

pub const Choice = enum {
    login,
    logout,
    approve,
    reject,
    remove,

    pub fn label(c: Choice) []const u8 {
        return switch (c) {
            .login => "Log in",
            .logout => "Log out",
            .approve => "Approve",
            .reject => "Reject",
            .remove => "Remove",
        };
    }

    /// The `/mcp` verb it runs.
    pub fn verb(c: Choice) []const u8 {
        return @tagName(c);
    }

    /// Remove, approve, and reject ask first; login and logout are quick to undo.
    pub fn asks(c: Choice) bool {
        return switch (c) {
            .remove, .approve, .reject => true,
            .login, .logout => false,
        };
    }
};

/// One server as the menu shows it; borrowed from the host's snapshot.
pub const Row = struct {
    status: runtime.Status,
    /// What it connects to or runs: what an approval trusts.
    target: ?[]const u8 = null,
};

pub const max_choices = 4;

/// The choices a server offers: its next step first, Remove last.
pub fn choices(row: Row, out: *[max_choices]Choice) []const Choice {
    const s = row.status;
    const project = s.source == .workspace;
    var n: usize = 0;
    if (s.state == .waiting_for_approval or s.state == .rejected) {
        out[n] = .approve;
        n += 1;
    } else if (s.needs_login) {
        out[n] = .login;
        n += 1;
    }
    if (s.signed_in and s.state != .waiting_for_approval and s.state != .rejected) {
        out[n] = .logout;
        n += 1;
    }
    if (project and s.state != .rejected) {
        out[n] = .reject;
        n += 1;
    }
    out[n] = .remove;
    n += 1;
    return out[0..n];
}

/// Case-insensitive, like fx's other pickers; an empty filter keeps everything.
pub fn matches(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.ascii.findIgnoreCase(name, filter) != null;
}

/// What the menu knows of the open server's tools.
pub const Tools = union(enum) {
    loading,
    needs_login,
    needs_approval,
    failed: []const u8,
    ready: []const Tool,
};

pub const Tool = struct { name: []const u8, description: []const u8 };

/// A tool matches by its name or by what it says it does, so a terse name is
/// still found.
pub fn toolMatches(t: Tool, filter: []const u8) bool {
    return matches(t.name, filter) or matches(t.description, filter);
}

/// How many tools `filter` keeps.
pub fn toolCount(tools: Tools, filter: []const u8) usize {
    const all = switch (tools) {
        .ready => |t| t,
        else => return 0,
    };
    var n: usize = 0;
    for (all) |t| n += @intFromBool(toolMatches(t, filter));
    return n;
}

/// The `n`th tool `filter` keeps.
pub fn nthTool(tools: []const Tool, filter: []const u8, n: usize) ?Tool {
    var seen: usize = 0;
    for (tools) |t| {
        if (!toolMatches(t, filter)) continue;
        if (seen == n) return t;
        seen += 1;
    }
    return null;
}

/// A server's screen below its title: its facts and a blank, its choices,
/// then a blank and either the tools' heading and the tools, or one line
/// saying why there are none.
pub const Layout = struct {
    lead: usize,
    choices: usize,
    gap: usize,
    tools: usize,
    /// Lines the screen shows below its title.
    window: usize,
    /// While a sign-in waits for the browser: its address, wrapped, after
    /// the heading. Nothing there is selectable.
    waiting: usize = 0,

    pub fn lines(l: Layout) usize {
        return l.lead + l.choices + l.gap + l.waiting + l.tools;
    }

    pub fn selectable(l: Layout) usize {
        return l.choices + l.tools;
    }

    /// The line the `cursor`th selectable item is on.
    pub fn line(l: Layout, cursor: usize) usize {
        return if (cursor < l.choices) l.lead + cursor else l.lead + l.choices + l.gap + l.waiting + (cursor - l.choices);
    }

    /// Content lines shown; when everything doesn't fit, two rows go to the
    /// counts of what's above and below.
    pub fn shown(l: Layout) usize {
        return if (l.lines() <= l.window) l.lines() else @max(l.window -| 2, 1);
    }
};

/// Whether a server's screen shows its last error; a login it needs is
/// already its status.
pub fn showsError(row: Row) bool {
    return row.status.last_error != null and !row.status.needs_login;
}

/// The tools as the screen tells them: a server that needs a login or an
/// approval says so, rather than as a failure, even while a load is still on
/// its way.
pub fn toolsFor(row: Row, tools: Tools) Tools {
    if (tools == .ready) return tools;
    if (row.status.state == .waiting_for_approval) return .needs_approval;
    return if (row.status.needs_login) .needs_login else tools;
}

/// A server's screen with `filter` typed, which narrows its tools.
pub fn serverLayout(row: Row, tools: Tools, filter: []const u8, window: usize) Layout {
    var buf: [max_choices]Choice = undefined;
    return .{
        // http or runs, file, and error when there is one; then a blank.
        .lead = 2 + @as(usize, @intFromBool(showsError(row))) + 1,
        .choices = choices(row, &buf).len,
        // A blank, then the heading or the reason there are no tools.
        .gap = 2,
        .tools = toolCount(tools, filter),
        .window = window,
    };
}

pub const name_capacity = 256;

pub const State = struct {
    active: bool = false,
    screen: Screen = .list,
    selected_len: usize = 0,
    selected_buf: [name_capacity]u8 = undefined,
    /// On a server's screen: the selected item (its choices, then its
    /// tools), and the first line shown.
    cursor: usize = 0,
    top: usize = 0,
    confirm: ?Choice = null,
    /// The list's filter, kept while a server's screen filters its tools.
    list_filter_len: usize = 0,
    list_filter_buf: [name_capacity]u8 = undefined,

    /// The selected server, kept by name so a reload doesn't move it.
    pub fn selectedName(s: *const State) []const u8 {
        return s.selected_buf[0..s.selected_len];
    }

    pub fn listFilter(s: *const State) []const u8 {
        return s.list_filter_buf[0..s.list_filter_len];
    }

    /// Keeps the list's filter, up to `name_capacity` bytes and never
    /// inside a character.
    pub fn keepListFilter(s: *State, filter: []const u8) void {
        var n = @min(filter.len, name_capacity);
        while (n > 0 and n < filter.len and filter[n] & 0xC0 == 0x80) n -= 1;
        s.list_filter_len = n;
        @memcpy(s.list_filter_buf[0..n], filter[0..n]);
    }

    fn select(s: *State, name: []const u8) void {
        s.selected_len = @min(name.len, name_capacity);
        @memcpy(s.selected_buf[0..s.selected_len], name[0..s.selected_len]);
    }

    /// Where the selection is in `rows`; the first row when it isn't there.
    pub fn selectedIndex(s: *const State, rows: []const Row) ?usize {
        if (rows.len == 0) return null;
        for (rows, 0..) |r, i| if (std.mem.eql(u8, r.status.name, s.selectedName())) return i;
        return 0;
    }
};

pub const Key = enum { up, down, enter, escape };

pub const Effect = union(enum) {
    none,
    close,
    /// A server opened: load its tools.
    open: []const u8,
    /// Back to the list: its tools aren't needed any more.
    back,
    run: struct { choice: Choice, server: []const u8 },
};

pub const View = struct {
    /// The servers the list shows, after the filter.
    rows: []const Row,
    /// The open server, found by name among all servers; null once it's gone.
    open: ?Row = null,
    layout: Layout = .{ .lead = 0, .choices = 0, .gap = 0, .tools = 0, .window = 1 },
};

/// The lines a server's screen has below its title: the inline panel's 12
/// rows less the title. A shorter panel moves its own view to keep the
/// selection.
pub const server_window: usize = 11;

/// What `s` shows of `rows` with `filter` typed, the list's rows going into
/// `buf`. On a server's screen `filter` narrows its tools instead.
pub fn viewOf(s: *const State, rows: []const Row, filter: []const u8, tools: Tools, buf: []Row) View {
    var n: usize = 0;
    var open_row: ?Row = null;
    for (rows) |r| {
        if (s.screen != .list and std.mem.eql(u8, r.status.name, s.selectedName())) open_row = r;
        if (n == buf.len or !matches(r.status.name, filter)) continue;
        buf[n] = r;
        n += 1;
    }
    var v: View = .{ .rows = buf[0..n], .open = open_row };
    if (open_row) |r| v.layout = serverLayout(r, tools, filter, server_window);
    return v;
}

/// A new tool filter on a server's screen selects the first tool it keeps,
/// so Enter can't run a choice by surprise; with no filter, or no tool
/// left, the selection goes back to the first choice.
pub fn filterChanged(s: *State, view: View, filtering: bool) void {
    if (s.screen != .server) return;
    const l = view.layout;
    s.cursor = if (filtering and l.tools > 0) l.choices else 0;
    s.top = 0;
    keepVisible(s, l);
}

pub fn open(s: *State) void {
    s.* = .{ .active = true };
}

/// Keeps a server's screen valid after its choices or tools changed, or
/// after the server went away.
pub fn settle(s: *State, view: View) Effect {
    if (s.screen == .list) return .none;
    if (view.open == null) {
        s.screen = .list;
        s.confirm = null;
        s.cursor = 0;
        s.top = 0;
        return .back;
    }
    const l = view.layout;
    if (l.selectable() > 0) s.cursor = @min(s.cursor, l.selectable() - 1) else s.cursor = 0;
    keepVisible(s, l);
    return .none;
}

pub fn press(s: *State, view: View, key: Key) Effect {
    switch (s.screen) {
        .list => {
            const i = s.selectedIndex(view.rows) orelse return if (key == .escape) .close else .none;
            switch (key) {
                .up => s.select(view.rows[i -| 1].status.name),
                .down => s.select(view.rows[@min(i + 1, view.rows.len - 1)].status.name),
                .enter => {
                    const name = view.rows[i].status.name;
                    s.select(name);
                    s.screen = .server;
                    s.cursor = 0;
                    s.top = 0;
                    return .{ .open = name };
                },
                .escape => return .close,
            }
            return .none;
        },
        .server => {
            const r = view.open orelse return settle(s, view);
            const l = view.layout;
            switch (key) {
                .up => s.cursor -|= 1,
                .down => if (s.cursor + 1 < l.selectable()) {
                    s.cursor += 1;
                },
                .enter => {
                    var buf: [max_choices]Choice = undefined;
                    const cs = choices(r, &buf);
                    if (s.cursor >= cs.len) return .none;
                    const c = cs[s.cursor];
                    if (!c.asks()) return .{ .run = .{ .choice = c, .server = r.status.name } };
                    s.screen = .confirm;
                    s.confirm = c;
                    return .none;
                },
                .escape => {
                    s.screen = .list;
                    s.cursor = 0;
                    s.top = 0;
                    return .back;
                },
            }
            keepVisible(s, l);
            return .none;
        },
        // Nothing moves while a confirmation is open.
        .confirm => {
            const r = view.open orelse return settle(s, view);
            const c = s.confirm.?;
            switch (key) {
                .enter => {
                    // A removed server has no screen to come back to.
                    s.screen = if (c == .remove) .list else .server;
                    s.confirm = null;
                    if (c == .remove) {
                        s.cursor = 0;
                        s.top = 0;
                    }
                    return .{ .run = .{ .choice = c, .server = r.status.name } };
                },
                .escape => {
                    s.screen = .server;
                    s.confirm = null;
                },
                .up, .down => {},
            }
            return .none;
        },
    }
}

fn keepVisible(s: *State, l: Layout) void {
    if (l.lines() <= l.window or s.cursor == 0) {
        s.top = 0;
        return;
    }
    const at = l.line(s.cursor);
    const shown = l.shown();
    if (at < s.top) s.top = at;
    if (at >= s.top + shown) s.top = at + 1 - shown;
    s.top = @min(s.top, l.lines() - shown);
}

/// How long news of a sign-in stays on the status line.
pub const news_ms: i64 = 5000;

/// What the status line says about MCP, written into `buf`: fresh news,
/// else the sign-in waiting for the browser, else what needs the user until
/// it's handled, else how many servers are ready. Empty with no servers.
/// `notes` counts config problems, which `/mcp list` shows.
pub fn statusLine(buf: []u8, statuses: []const runtime.Status, signing_in: ?[]const u8, news: ?[]const u8, notes: usize) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (news) |text| {
        writeSafe(&w, text);
        return whole(w.buffered());
    }
    if (signing_in) |name| {
        w.writeAll("Signing in to ") catch {};
        writeSafe(&w, name);
        w.writeAll(" · /mcp") catch {};
        return whole(w.buffered());
    }
    var needs: usize = 0;
    var first: ?runtime.Status = null;
    var ready: usize = 0;
    var enabled: usize = 0;
    for (statuses) |s| {
        if (s.state == .disabled or s.state == .rejected) continue;
        enabled += 1;
        if (s.state == .ready) ready += 1;
        if (attention(s) == null) continue;
        if (needs == 0) first = s;
        needs += 1;
    }
    if (needs == 1) {
        writeSafe(&w, first.?.name);
        w.print(" {s} · /mcp", .{attention(first.?).?}) catch {};
    } else if (needs > 1) {
        w.print("{d} MCP servers need you · /mcp", .{needs}) catch {};
    } else if (notes > 0) {
        w.print("MCP config has {d} problem{s} · /mcp list", .{ notes, if (notes == 1) "" else "s" }) catch {};
    } else if (enabled > 0) {
        w.print("mcp {d}/{d}", .{ ready, enabled }) catch {};
    }
    return whole(w.buffered());
}

/// What a server needs from the user, if anything.
fn attention(s: runtime.Status) ?[]const u8 {
    if (s.needs_login) return "needs login";
    return switch (s.state) {
        .waiting_for_approval => "is waiting for approval",
        .failed => "failed",
        .missing_env => "needs a variable",
        else => null,
    };
}

/// Names and reasons come from config and servers: control characters,
/// C1 included, become `?`.
fn writeSafe(w: *std.Io.Writer, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        const c1 = c == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f;
        if (c < 0x20 or c == 0x7f or c1) {
            w.writeByte('?') catch return;
            if (c1) i += 1;
        } else w.writeByte(c) catch return;
    }
}

/// A full buffer may end inside a character; drop the partial one.
fn whole(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) end -= 1;
    return bytes[0..end];
}

const testing = std.testing;

test "the status line puts news first, then what needs the user, then a count" {
    var buf: [96]u8 = undefined;
    const plain: runtime.Status = .{ .name = "plain", .source = .profile, .transport = .http, .state = .idle, .needs_login = true };
    const ready: runtime.Status = .{ .name = "linear", .source = .profile, .transport = .http, .state = .ready };
    const off: runtime.Status = .{ .name = "old", .source = .profile, .transport = .stdio, .state = .disabled };
    const proj: runtime.Status = .{ .name = "proj", .source = .workspace, .transport = .stdio, .state = .waiting_for_approval };
    try testing.expectEqualStrings("Signed in to plain", statusLine(&buf, &.{ plain, ready }, null, "Signed in to plain", 0));
    try testing.expectEqualStrings("Signing in to plain · /mcp", statusLine(&buf, &.{ plain, ready }, "plain", null, 0));
    try testing.expectEqualStrings("plain needs login · /mcp", statusLine(&buf, &.{ plain, ready, off }, null, null, 0));
    try testing.expectEqualStrings("2 MCP servers need you · /mcp", statusLine(&buf, &.{ plain, proj, ready }, null, null, 3));
    try testing.expectEqualStrings("MCP config has 2 problems · /mcp list", statusLine(&buf, &.{ready}, null, null, 2));
    // Disabled servers aren't counted.
    try testing.expectEqualStrings("mcp 1/1", statusLine(&buf, &.{ ready, off }, null, null, 0));
    try testing.expectEqualStrings("", statusLine(&buf, &.{}, null, null, 0));
}

test "the status line keeps names inert and never ends inside a character" {
    var buf: [96]u8 = undefined;
    const evil: runtime.Status = .{ .name = "a\x1b[31mb\xc2\x9b", .source = .profile, .transport = .http, .state = .failed };
    try testing.expectEqualStrings("a?[31mb? failed · /mcp", statusLine(&buf, &.{evil}, null, null, 0));
    var small: [8]u8 = undefined;
    try testing.expectEqualStrings("Signed ", statusLine(&small, &.{}, null, "Signed \u{00e9}", 0));
}

fn testRow(name: []const u8, state: runtime.State, extra: struct {
    source: @FieldType(runtime.Status, "source") = .profile,
    transport: @FieldType(runtime.Status, "transport") = .http,
    needs_login: bool = false,
    signed_in: bool = false,
}) Row {
    return .{ .status = .{
        .name = name,
        .source = extra.source,
        .transport = extra.transport,
        .state = state,
        .needs_login = extra.needs_login,
        .signed_in = extra.signed_in,
    } };
}

fn choiceList(r: Row, buf: *[max_choices]Choice) []const Choice {
    return choices(r, buf);
}

test "a server's choices start with its next step and end with Remove" {
    var b: [max_choices]Choice = undefined;
    try testing.expectEqualSlices(Choice, &.{ .login, .remove }, choiceList(testRow("a", .failed, .{ .needs_login = true }), &b));
    try testing.expectEqualSlices(Choice, &.{ .logout, .remove }, choiceList(testRow("a", .ready, .{ .signed_in = true }), &b));
    try testing.expectEqualSlices(Choice, &.{.remove}, choiceList(testRow("a", .ready, .{}), &b));
    try testing.expectEqualSlices(Choice, &.{ .approve, .reject, .remove }, choiceList(testRow("a", .waiting_for_approval, .{ .source = .workspace }), &b));
    try testing.expectEqualSlices(Choice, &.{ .approve, .remove }, choiceList(testRow("a", .rejected, .{ .source = .workspace }), &b));
    try testing.expectEqualSlices(Choice, &.{ .reject, .remove }, choiceList(testRow("a", .idle, .{ .source = .workspace, .transport = .stdio }), &b));
    try testing.expectEqualSlices(Choice, &.{ .login, .logout, .reject, .remove }, choiceList(testRow("a", .retrying, .{ .source = .workspace, .needs_login = true, .signed_in = true }), &b));
    try testing.expect(Choice.remove.asks() and Choice.approve.asks() and Choice.reject.asks());
    try testing.expect(!Choice.login.asks() and !Choice.logout.asks());
}

test "the filter is a case-insensitive part of the name" {
    try testing.expect(matches("Linear", "lin"));
    try testing.expect(matches("context7", ""));
    try testing.expect(!matches("context7", "li"));
    const rows = [_]Row{ testRow("context7", .ready, .{}), testRow("linear", .ready, .{}) };
    var buf: [2]Row = undefined;
    var s: State = .{ .active = true };
    try testing.expectEqual(@as(usize, 1), viewOf(&s, &rows, "LIN", .loading, &buf).rows.len);
    // The open server is found among all servers, whatever the filter.
    s.select("context7");
    s.screen = .server;
    try testing.expectEqualStrings("context7", viewOf(&s, &rows, "lin", .loading, &buf).open.?.status.name);
}

test "the list keeps its selection by name, and Enter opens the server" {
    const rows = [_]Row{ testRow("context7", .ready, .{}), testRow("linear", .failed, .{ .needs_login = true }), testRow("docs", .idle, .{}) };
    var s: State = .{};
    open(&s);
    try testing.expectEqual(Effect.none, press(&s, .{ .rows = &rows }, .down));
    try testing.expectEqualStrings("linear", s.selectedName());
    _ = press(&s, .{ .rows = &rows }, .down);
    _ = press(&s, .{ .rows = &rows }, .down);
    try testing.expectEqualStrings("docs", s.selectedName());
    // A reload that drops a server above doesn't move the selection.
    const fewer = [_]Row{ rows[1], rows[2] };
    try testing.expectEqual(@as(?usize, 1), s.selectedIndex(&fewer));
    // A filter that hides the selection falls back to the first match.
    const filtered = [_]Row{rows[0]};
    try testing.expectEqual(@as(?usize, 0), s.selectedIndex(&filtered));
    const effect = press(&s, .{ .rows = &filtered }, .enter);
    try testing.expectEqualStrings("context7", effect.open);
    try testing.expectEqual(Screen.server, s.screen);
    var empty: State = .{ .active = true };
    try testing.expectEqual(Effect.close, press(&empty, .{ .rows = &.{} }, .escape));
}

test "on a server, the next step is selected, and asking actions confirm first" {
    const r = testRow("linear", .failed, .{ .needs_login = true });
    var s: State = .{ .active = true, .screen = .server };
    const view: View = .{ .rows = &.{}, .open = r, .layout = serverLayout(r, .needs_login, "", 9) };
    const run = press(&s, view, .enter);
    try testing.expectEqual(Choice.login, run.run.choice);
    try testing.expectEqualStrings("linear", run.run.server);

    _ = press(&s, view, .down);
    try testing.expectEqual(Effect.none, press(&s, view, .enter));
    try testing.expectEqual(Screen.confirm, s.screen);
    // Nothing moves while the confirmation is open, and Esc cancels it.
    _ = press(&s, view, .up);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    _ = press(&s, view, .escape);
    try testing.expectEqual(Screen.server, s.screen);
    _ = press(&s, view, .enter);
    const removed = press(&s, view, .enter);
    try testing.expectEqual(Choice.remove, removed.run.choice);
    // Confirmed, Remove goes straight back to the list.
    try testing.expectEqual(Screen.list, s.screen);
    try testing.expectEqual(@as(usize, 0), s.cursor);
    try testing.expectEqual(Effect.close, press(&s, view, .escape));
}

test "the selection moves on from the choices through the tools, and the screen scrolls" {
    var tools: [30]Tool = undefined;
    for (&tools) |*t| t.* = .{ .name = "t", .description = "" };
    const r = testRow("github", .ready, .{ .signed_in = true });
    const layout = serverLayout(r, .{ .ready = &tools }, "", 8);
    try testing.expectEqual(@as(usize, 3), layout.lead);
    try testing.expectEqual(@as(usize, 2), layout.choices);
    try testing.expectEqual(@as(usize, 37), layout.lines());
    var s: State = .{ .active = true, .screen = .server };
    const view: View = .{ .rows = &.{}, .open = r, .layout = layout };
    for (0..10) |_| _ = press(&s, view, .down);
    try testing.expectEqual(@as(usize, 10), s.cursor);
    // The selected tool is in view, between the counts above and below.
    const at = layout.line(s.cursor);
    try testing.expect(at >= s.top and at < s.top + layout.shown());
    // Enter on a tool does nothing.
    try testing.expectEqual(Effect.none, press(&s, view, .enter));
    for (0..40) |_| _ = press(&s, view, .down);
    try testing.expectEqual(@as(usize, 31), s.cursor);
    try testing.expectEqual(layout.lines() - layout.shown(), s.top);
    for (0..40) |_| _ = press(&s, view, .up);
    try testing.expectEqual(@as(usize, 0), s.top);
}

test "typing on a server's screen narrows its tools; the list keeps its own filter" {
    const tools = [_]Tool{
        .{ .name = "search_logs", .description = "Find log lines" },
        .{ .name = "_dd_gff", .description = "Get feature flags" },
        .{ .name = "list_monitors", .description = "Monitors and their state" },
    };
    const r = testRow("datadog", .ready, .{ .signed_in = true });
    try testing.expectEqual(@as(usize, 3), toolCount(.{ .ready = &tools }, ""));
    // By name or by description, in any case.
    try testing.expectEqual(@as(usize, 3), toolCount(.{ .ready = &tools }, "_"));
    try testing.expectEqual(@as(usize, 1), toolCount(.{ .ready = &tools }, "FIND"));
    try testing.expectEqualStrings("_dd_gff", nthTool(&tools, "flag", 0).?.name);
    try testing.expectEqual(@as(?Tool, null), nthTool(&tools, "flag", 1));
    try testing.expectEqual(@as(usize, 0), toolCount(.loading, ""));

    // A filter selects the first tool it keeps, past the choices; none left,
    // or none typed, goes back to the first choice.
    var s: State = .{ .active = true, .screen = .server, .cursor = 4 };
    var layout = serverLayout(r, .{ .ready = &tools }, "monitor", 8);
    try testing.expectEqual(@as(usize, 1), layout.tools);
    filterChanged(&s, .{ .rows = &.{}, .open = r, .layout = layout }, true);
    try testing.expectEqual(layout.choices, s.cursor);
    layout = serverLayout(r, .{ .ready = &tools }, "nothing", 8);
    filterChanged(&s, .{ .rows = &.{}, .open = r, .layout = layout }, true);
    try testing.expectEqual(@as(usize, 0), s.cursor);

    var list: State = .{ .active = true };
    list.keepListFilter("dat");
    try testing.expectEqualStrings("dat", list.listFilter());
    // Never cut inside a character.
    const long = text_utils.repeat("a", name_capacity - 1) ++ "é";
    list.keepListFilter(long);
    try testing.expectEqual(@as(usize, name_capacity - 1), list.listFilter().len);
    // Off a server's screen a filter changes nothing.
    list.cursor = 0;
    filterChanged(&list, .{ .rows = &.{} }, true);
    try testing.expectEqual(@as(usize, 0), list.cursor);
}

test "a server that goes away takes its screen back to the list" {
    var s: State = .{ .active = true, .screen = .confirm, .confirm = .remove, .cursor = 1 };
    try testing.expectEqual(Effect.back, settle(&s, .{ .rows = &.{} }));
    try testing.expectEqual(Screen.list, s.screen);
    try testing.expect(s.confirm == null);
    // Fewer choices after a login clamp the cursor.
    const r = testRow("linear", .ready, .{});
    s = .{ .active = true, .screen = .server, .cursor = 3 };
    _ = settle(&s, .{ .rows = &.{}, .open = r, .layout = serverLayout(r, .loading, "", 9) });
    try testing.expectEqual(@as(usize, 0), s.cursor);
}
