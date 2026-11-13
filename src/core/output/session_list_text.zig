//! The text `fx sessions` and `fx sessions --live` print for a person: one
//! row per session in fixed columns, title first, then the session's
//! status or turns, how long ago it changed, and its id. A live session's
//! subagents follow it as a tree. `--json` is written elsewhere and keeps
//! its fields.

const std = @import("std");
const Allocator = std.mem.Allocator;
const display_width = @import("../shared/display_width.zig");
const local_time = @import("../shared/local_time.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const text_utils = @import("../shared/text_utils.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const session_store = @import("../session/session_store.zig");

/// How a list prints: color and width for a terminal, the clock ages count
/// from, and the home folder that workspace paths show as `~`.
pub const Style = struct {
    /// ANSI color, only for a terminal that takes it.
    color: bool = false,
    /// The width a row fits in, cutting long titles; null prints them whole.
    columns: ?usize = null,
    now_ms: i64 = 0,
    home: ?[]const u8 = null,
};

/// `fx sessions`: one page of saved sessions, newest first.
pub const Saved = struct {
    sessions: []const session_store.SessionSummary,
    has_more: bool = false,
    next_cursor: ?[]const u8 = null,
    skipped_invalid: usize = 0,
    all_workspaces: bool = false,
};

/// Between two columns.
const gap = "  ";
/// A title column narrower than this cuts too much to read.
const min_title_width = 20;
/// The hint lines' labels end here.
const hint_label_width = 18;
/// Younger than this shows as "3d ago"; older shows its local date.
const relative_age_limit_ms = 7 * std.time.ms_per_day;

const Paint = enum { plain, bold, dim, green, yellow };

fn ansi(paint: Paint) []const u8 {
    return switch (paint) {
        .plain => "",
        .bold => "\x1b[1m",
        .dim => "\x1b[2m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
    };
}

fn writePainted(writer: *std.Io.Writer, color: bool, paint: Paint, parts: []const []const u8) !void {
    const painted = color and paint != .plain;
    if (painted) try writer.writeAll(ansi(paint));
    for (parts) |part| try writer.writeAll(part);
    if (painted) try writer.writeAll("\x1b[0m");
}

/// One cell, already terminal-safe. A subagent's title cell carries its
/// tree branches in `tree`, drawn dim before the name.
const Cell = struct {
    text: []const u8 = "",
    paint: Paint = .plain,
    tree: []const u8 = "",

    fn width(cell: Cell) usize {
        return display_width.visibleWidth(cell.tree) + display_width.visibleWidth(cell.text);
    }

    fn isEmpty(cell: Cell) bool {
        return cell.text.len == 0 and cell.tree.len == 0;
    }
};

const Row = struct {
    cells: []const Cell,
    /// A blank line goes before the row.
    gap_before: bool = false,
};

const Column = struct {
    head: []const u8,
    right: bool = false,
};

/// `rows` under `columns`' heads, each column as wide as its widest cell.
/// The first column is the title. When `style.columns` is set, it narrows,
/// though not below `min_title_width`, so a row fits the window, and a
/// longer title ends in "…". A row ends at its last cell with text.
fn writeTable(writer: *std.Io.Writer, alloc: Allocator, style: Style, columns: []const Column, rows: []const Row) !void {
    const widths = try alloc.alloc(usize, columns.len);
    defer alloc.free(widths);
    for (columns, widths) |column, *w| w.* = display_width.visibleWidth(column.head);
    for (rows) |row| {
        for (row.cells, widths) |cell, *w| w.* = @max(w.*, cell.width());
    }
    if (style.columns) |available| {
        var others: usize = 0;
        for (widths[1..]) |w| others += gap.len + w;
        widths[0] = @max(@min(widths[0], min_title_width), @min(widths[0], available -| others));
    }

    const heads = try alloc.alloc(Cell, columns.len);
    defer alloc.free(heads);
    for (columns, heads) |column, *head| head.* = .{ .text = column.head, .paint = .dim };
    try writeRow(writer, style.color, columns, widths, heads);
    for (rows) |row| {
        if (row.gap_before) try writer.writeByte('\n');
        try writeRow(writer, style.color, columns, widths, row.cells);
    }
}

fn writeRow(writer: *std.Io.Writer, color: bool, columns: []const Column, widths: []const usize, cells: []const Cell) !void {
    var last: usize = 0;
    for (cells, 0..) |cell, i| {
        if (!cell.isEmpty()) last = i;
    }
    for (cells[0 .. last + 1], columns[0 .. last + 1], widths[0 .. last + 1], 0..) |cell, column, w, i| {
        if (i > 0) try writer.writeAll(gap);
        const ends = i == last;
        if (i == 0) {
            try writeTitle(writer, color, cell, w, ends);
            continue;
        }
        const pad = w -| cell.width();
        if (column.right) try writer.splatByteAll(' ', pad);
        try writePainted(writer, color, cell.paint, &.{cell.text});
        if (!column.right and !ends) try writer.splatByteAll(' ', pad);
    }
    try writer.writeByte('\n');
}

/// The title cell in `w` columns: its tree, then its text, cut with "…"
/// when it is wider than the room the tree leaves.
fn writeTitle(writer: *std.Io.Writer, color: bool, cell: Cell, w: usize, ends: bool) !void {
    try writePainted(writer, color, .dim, &.{cell.tree});
    const room = w -| display_width.visibleWidth(cell.tree);
    var shown = display_width.visibleWidth(cell.text);
    if (shown > room) {
        const cut = display_width.prefixByWidth(cell.text, room -| 1);
        try writePainted(writer, color, cell.paint, &.{ cut, "…" });
        shown = display_width.visibleWidth(cut) + 1;
    } else {
        try writePainted(writer, color, cell.paint, &.{cell.text});
    }
    if (!ends) try writer.splatByteAll(' ', room -| shown);
}

fn writeHint(writer: *std.Io.Writer, alloc: Allocator, color: bool, label: []const u8, command: []const u8) !void {
    const line = try alloc.alloc(u8, @max(hint_label_width, label.len) + command.len);
    defer alloc.free(line);
    @memset(line, ' ');
    @memcpy(line[0..label.len], label);
    @memcpy(line[line.len - command.len ..], command);
    try writePainted(writer, color, .dim, &.{line});
    try writer.writeByte('\n');
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

fn safe(arena: Allocator, raw: []const u8) ![]const u8 {
    return (try text_utils.encodeTerminalSafe(arena, raw, std.math.maxInt(usize))).bytes;
}

/// How long ago `updated_ms` was, as the resume picker says it ("3m ago"),
/// or its local date once it is a week old.
fn age(arena: Allocator, updated_ms: i64, now_ms: i64) ![]const u8 {
    if (now_ms -| updated_ms < relative_age_limit_ms) {
        var buf: [32]u8 = undefined;
        return arena.dupe(u8, session_catalog.relativeActivityAge(&buf, updated_ms, now_ms));
    }
    const reading = local_time.local(updated_ms) orelse return "unknown";
    return arena.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ reading.year, reading.month.numeric(), reading.day });
}

/// The session's workspace, with the home folder shown as `~`.
fn workspace(arena: Allocator, summary: session_store.SessionSummary, home: ?[]const u8) ![]const u8 {
    const root = summary.workspace_root orelse summary.origin_workspace_root orelse return "";
    if (home) |dir| if (dir.len > 0 and std.mem.startsWith(u8, root, dir)) {
        if (root.len == dir.len) return "~";
        if (root[dir.len] == '/') return safe(arena, try std.mem.concat(arena, u8, &.{ "~", root[dir.len..] }));
    };
    return safe(arena, root);
}

fn stateCell(state: session_store.LiveState) Cell {
    return .{ .text = @tagName(state), .paint = switch (state) {
        .working => .green,
        .idle => .dim,
        .unknown => .yellow,
    } };
}

/// Working sessions first, then ones whose log can't be read, then idle
/// ones; the newest first in each.
fn liveFirst(sessions: []const session_store.LiveSession, a: usize, b: usize) bool {
    const rank_a = stateRank(sessions[a].state);
    const rank_b = stateRank(sessions[b].state);
    if (rank_a != rank_b) return rank_a < rank_b;
    return sessions[a].summary.updated_at_ms > sessions[b].summary.updated_at_ms;
}

fn stateRank(state: session_store.LiveState) u2 {
    return switch (state) {
        .working => 0,
        .unknown => 1,
        .idle => 2,
    };
}

/// The model most sessions saved, the first in `order` on a tie; null when
/// none saved one.
fn commonModel(sessions: []const session_store.LiveSession, order: []const usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    for (order) |index| {
        const model = sessions[index].saved_model orelse continue;
        var count: usize = 0;
        for (sessions) |other| {
            if (other.saved_model) |m| {
                if (std.mem.eql(u8, m, model)) count += 1;
            }
        }
        if (count > best_count) {
            best = model;
            best_count = count;
        }
    }
    return best;
}

/// `fx sessions --live`.
pub fn writeLive(writer: *std.Io.Writer, alloc: Allocator, sessions: []const session_store.LiveSession, all_workspaces: bool, style: Style) !void {
    if (sessions.len == 0) {
        return writer.writeAll(if (all_workspaces) "No live sessions.\n" else "No live sessions in this workspace.\n");
    }
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const order = try arena.alloc(usize, sessions.len);
    for (order, 0..) |*slot, i| slot.* = i;
    sort_utils.sort(usize, order, sessions, liveFirst);

    var counts = std.enums.EnumArray(session_store.LiveState, usize).initFill(0);
    for (sessions) |entry| counts.getPtr(entry.state).* += 1;
    const common = commonModel(sessions, order);
    const other_models = for (sessions) |entry| {
        if (entry.saved_model) |model| {
            if (!std.mem.eql(u8, model, common.?)) break true;
        }
    } else false;

    try writePainted(writer, style.color, .bold, &.{
        try arena.print("{d} live session{s}", .{ sessions.len, plural(sessions.len) }),
        if (all_workspaces) " in all workspaces" else "",
    });
    for ([_]session_store.LiveState{ .working, .idle, .unknown }) |state| {
        const count = counts.get(state);
        if (count == 0) continue;
        try writer.writeAll("  ·  ");
        try writePainted(writer, style.color, stateCell(state).paint, &.{try arena.print("{d} {s}", .{ count, @tagName(state) })});
    }
    try writer.writeByte('\n');
    if (common) |model| {
        try writePainted(writer, style.color, .dim, &.{
            "Model ",
            try safe(arena, model),
            if (other_models) ", unless the MODEL column names another" else "",
        });
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');

    var columns: std.ArrayList(Column) = .empty;
    try columns.appendSlice(arena, &.{ .{ .head = "TITLE" }, .{ .head = "STATUS" }, .{ .head = "UPDATED" }, .{ .head = "SESSION ID" } });
    if (all_workspaces) try columns.append(arena, .{ .head = "WORKSPACE" });
    if (other_models) try columns.append(arena, .{ .head = "MODEL" });

    var rows: std.ArrayList(Row) = .empty;
    var previous_working: ?bool = null;
    for (order) |index| {
        const entry = sessions[index];
        const cells = try arena.alloc(Cell, columns.items.len);
        @memset(cells, .{});
        cells[0] = .{ .text = try safe(arena, entry.summary.title orelse session_display_metadata.fallback_title) };
        cells[1] = stateCell(entry.state);
        cells[2] = .{ .text = try age(arena, entry.summary.updated_at_ms, style.now_ms), .paint = .dim };
        cells[3] = .{ .text = try safe(arena, entry.summary.id) };
        var next: usize = 4;
        if (all_workspaces) {
            cells[next] = .{ .text = try workspace(arena, entry.summary, style.home), .paint = .dim };
            next += 1;
        }
        if (other_models) if (entry.saved_model) |model| if (!std.mem.eql(u8, model, common.?)) {
            cells[next] = .{ .text = try safe(arena, model), .paint = .dim };
        };
        const working = entry.state == .working;
        try rows.append(arena, .{ .cells = cells, .gap_before = if (previous_working) |was| was != working else false });
        previous_working = working;
        try appendAgentRows(arena, &rows, entry.agents, "", columns.items.len);
    }
    try writeTable(writer, arena, style, columns.items, rows.items);

    try writer.writeByte('\n');
    try writeHint(writer, arena, style.color, "Read a session", "fx session <session id> --tail 5");
    try writeHint(writer, arena, style.color, "Read a subagent", "fx session <session id>/<name> --tail 5");
    try writeHint(writer, arena, style.color, "Every field", if (all_workspaces) "fx sessions --live --all --json" else "fx sessions --live --json");
}

/// One row per subagent below its parent's, its branches drawn from
/// `indent`. Names are agent names, which hold no control bytes.
fn appendAgentRows(arena: Allocator, rows: *std.ArrayList(Row), agents: []const session_store.LiveAgent, indent: []const u8, column_count: usize) !void {
    for (agents, 0..) |agent, i| {
        const last = i + 1 == agents.len;
        const cells = try arena.alloc(Cell, column_count);
        @memset(cells, .{});
        cells[0] = .{
            .tree = try std.mem.concat(arena, u8, &.{ indent, if (last) "└─ " else "├─ " }),
            .text = agent.name,
            .paint = if (agent.state == .working) .plain else .dim,
        };
        cells[1] = stateCell(agent.state);
        try rows.append(arena, .{ .cells = cells });
        try appendAgentRows(arena, rows, agent.agents, try std.mem.concat(arena, u8, &.{ indent, if (last) "   " else "│  " }), column_count);
    }
}

/// `fx sessions`.
pub fn writeSaved(writer: *std.Io.Writer, alloc: Allocator, list: Saved, style: Style) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const where = if (list.all_workspaces) "in all workspaces" else "in this workspace";

    if (list.sessions.len == 0) {
        try writer.print("No {s}saved sessions {s}.\n", .{ if (list.skipped_invalid > 0) "readable " else "", where });
        return writeSkipped(writer, arena, style.color, list.skipped_invalid);
    }

    const count = try arena.print("{d} saved session{s} {s}", .{ list.sessions.len, plural(list.sessions.len), where });
    if (list.has_more) {
        try writePainted(writer, style.color, .bold, &.{ "Newest ", count });
    } else {
        try writePainted(writer, style.color, .bold, &.{count});
        try writePainted(writer, style.color, .dim, &.{", newest first"});
    }
    try writer.writeAll("\n\n");

    var columns: std.ArrayList(Column) = .empty;
    try columns.appendSlice(arena, &.{ .{ .head = "TITLE" }, .{ .head = "TURNS", .right = true }, .{ .head = "UPDATED" }, .{ .head = "SESSION ID" } });
    if (list.all_workspaces) try columns.append(arena, .{ .head = "WORKSPACE" });

    const rows = try arena.alloc(Row, list.sessions.len);
    for (list.sessions, rows) |entry, *row| {
        const cells = try arena.alloc(Cell, columns.items.len);
        cells[0] = .{ .text = try safe(arena, entry.title orelse session_display_metadata.fallback_title) };
        cells[1] = .{ .text = try arena.print("{d}", .{entry.history_len}) };
        cells[2] = .{ .text = try age(arena, entry.updated_at_ms, style.now_ms), .paint = .dim };
        cells[3] = .{ .text = try safe(arena, entry.id) };
        if (list.all_workspaces) cells[4] = .{ .text = try workspace(arena, entry, style.home), .paint = .dim };
        row.* = .{ .cells = cells };
    }
    try writeTable(writer, arena, style, columns.items, rows);

    try writer.writeByte('\n');
    if (list.has_more) if (list.next_cursor) |cursor| {
        try writeHint(writer, arena, style.color, "More", try arena.print("fx sessions {s}--cursor {s}", .{ if (list.all_workspaces) "--all " else "", cursor }));
    };
    try writeHint(writer, arena, style.color, "Read a session", "fx session <session id> --tail 5");
    try writeHint(writer, arena, style.color, "Running now", "fx sessions --live");
    try writeSkipped(writer, arena, style.color, list.skipped_invalid);
}

fn writeSkipped(writer: *std.Io.Writer, arena: Allocator, color: bool, skipped: usize) !void {
    if (skipped == 0) return;
    try writePainted(writer, color, .yellow, &.{try arena.print(
        "Skipped {d} unreadable saved session{s}; run `fx doctor` for recovery guidance",
        .{ skipped, plural(skipped) },
    )});
    try writer.writeByte('\n');
}

// Tests -----------------------------------------------------------------

const testing = std.testing;
const types = @import("../shared/types.zig");

const test_now_ms: i64 = 1_800_000_000_000;

fn summaryAt(id: []const u8, title: ?[]const u8, minutes_ago: i64) session_store.SessionSummary {
    return .{
        .id = @constCast(id),
        .title = if (title) |t| @constCast(t) else null,
        .workspace_root = @constCast("/Users/example/w"),
        .created_at_ms = 1,
        .updated_at_ms = test_now_ms - minutes_ago * std.time.ms_per_min,
        .conversation_language = types.ConversationLanguage.default(),
        .history_len = 3,
    };
}

fn renderLive(sessions: []const session_store.LiveSession, all_workspaces: bool, style: Style) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeLive(&out.writer, testing.allocator, sessions, all_workspaces, style);
    return out.toOwnedSlice();
}

fn renderSaved(list: Saved, style: Style) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeSaved(&out.writer, testing.allocator, list, style);
    return out.toOwnedSlice();
}

test "a live list puts working sessions first, each subagent in a tree, and each column in line" {
    const helper: session_store.LiveAgent = .{ .name = "helper", .address = "abc/lead/helper", .id = "h1", .state = .working, .agents = &.{} };
    const lead: session_store.LiveAgent = .{ .name = "lead", .address = "abc/lead", .id = "l1", .state = .idle, .agents = &.{helper} };
    const scout: session_store.LiveAgent = .{ .name = "scout", .address = "abc/scout", .id = "s1", .state = .idle, .agents = &.{} };
    const sessions = [_]session_store.LiveSession{
        .{ .summary = summaryAt("idle0000aaaa", "An idle one", 30), .saved_model = "openai/gpt-5", .state = .idle, .agents = &.{} },
        .{ .summary = summaryAt("abc000000000", "Fix the login bug", 5), .saved_model = "openai/gpt-5", .state = .working, .agents = &.{ lead, scout } },
        .{ .summary = summaryAt("newer0000000", null, 0), .saved_model = "example/other-model", .state = .working, .agents = &.{} },
    };
    const text = try renderLive(&sessions, false, .{ .now_ms = test_now_ms });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "3 live sessions  ·  2 working  ·  1 idle\n" ++
            "Model openai/gpt-5, unless the MODEL column names another\n" ++
            "\n" ++
            "TITLE              STATUS   UPDATED   SESSION ID    MODEL\n" ++
            "Untitled session   working  just now  newer0000000  example/other-model\n" ++
            "Fix the login bug  working  5m ago    abc000000000\n" ++
            "├─ lead            idle\n" ++
            "│  └─ helper       working\n" ++
            "└─ scout           idle\n" ++
            "\n" ++
            "An idle one        idle     30m ago   idle0000aaaa\n" ++
            "\n" ++
            "Read a session    fx session <session id> --tail 5\n" ++
            "Read a subagent   fx session <session id>/<name> --tail 5\n" ++
            "Every field       fx sessions --live --json\n",
        text,
    );
}

test "a live list adds the workspace with --all, leaves out MODEL when every session saved one model, and says when it is empty" {
    var home_summary = summaryAt("abc000000000", "In a folder", 2);
    home_summary.workspace_root = @constCast("/Users/example/code/fx");
    var other = summaryAt("def000000000", "Elsewhere", 3);
    other.workspace_root = @constCast("/srv/w");
    const sessions = [_]session_store.LiveSession{
        .{ .summary = home_summary, .saved_model = "openai/gpt-5", .state = .idle, .agents = &.{} },
        .{ .summary = other, .saved_model = null, .state = .unknown, .agents = &.{} },
    };
    const text = try renderLive(&sessions, true, .{ .now_ms = test_now_ms, .home = "/Users/example" });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "2 live sessions in all workspaces  ·  1 idle  ·  1 unknown\nModel openai/gpt-5\n\n"));
    try testing.expect(std.mem.find(u8, text, "MODEL\n") == null);
    try testing.expect(std.mem.find(u8, text, "Elsewhere    unknown  3m ago   def000000000  /srv/w\n") != null);
    try testing.expect(std.mem.find(u8, text, "In a folder  idle     2m ago   abc000000000  ~/code/fx\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "Every field       fx sessions --live --all --json\n"));

    for ([_]bool{ false, true }) |all| {
        const empty = try renderLive(&.{}, all, .{ .now_ms = test_now_ms });
        defer testing.allocator.free(empty);
        try testing.expectEqualStrings(if (all) "No live sessions.\n" else "No live sessions in this workspace.\n", empty);
    }
}

test "a session list colors only when asked, and every row still lines up" {
    const lead: session_store.LiveAgent = .{ .name = "lead", .address = "abc/lead", .id = "l1", .state = .idle, .agents = &.{} };
    const sessions = [_]session_store.LiveSession{
        .{ .summary = summaryAt("abc000000000", "Fix \x1b[31mred", 1), .saved_model = "m", .state = .working, .agents = &.{lead} },
    };
    const plain = try renderLive(&sessions, false, .{ .now_ms = test_now_ms });
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.findScalar(u8, plain, 0x1b) == null);
    try testing.expect(std.mem.find(u8, plain, "Fix \\x1b[31mred  working  1m ago   abc000000000\n") != null);

    const colored = try renderLive(&sessions, false, .{ .now_ms = test_now_ms, .color = true });
    defer testing.allocator.free(colored);
    try testing.expect(std.mem.find(u8, colored, "\x1b[32mworking\x1b[0m") != null);
    try testing.expect(std.mem.find(u8, colored, "\x1b[2m└─ \x1b[0m\x1b[2mlead\x1b[0m") != null);
    // The title's own escape stays escaped; only fx's codes are real.
    try testing.expect(std.mem.find(u8, colored, "Fix \\x1b[31mred") != null);
    // Without the color codes, the colored text is the plain text.
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(testing.allocator);
    var i: usize = 0;
    while (i < colored.len) {
        if (colored[i] == 0x1b) {
            i = std.mem.findScalarPos(u8, colored, i, 'm').? + 1;
            continue;
        }
        try stripped.append(testing.allocator, colored[i]);
        i += 1;
    }
    try testing.expectEqualStrings(plain, stripped.items);
}

test "a title cuts with an ellipsis to fit a terminal, never below twenty columns" {
    const long = "A very long session title that keeps going well past any narrow terminal";
    const sessions = [_]session_store.LiveSession{
        .{ .summary = summaryAt("abc000000000", long, 1), .saved_model = "m", .state = .working, .agents = &.{} },
    };
    const fitted = try renderLive(&sessions, false, .{ .now_ms = test_now_ms, .columns = 60 });
    defer testing.allocator.free(fitted);
    var lines = std.mem.splitScalar(u8, fitted, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "abc000000000") == null) continue;
        try testing.expectEqual(@as(usize, 60), display_width.visibleWidth(line));
        try testing.expect(std.mem.startsWith(u8, line, "A very long session title t…  working"));
    }
    const narrow = try renderLive(&sessions, false, .{ .now_ms = test_now_ms, .columns = 10 });
    defer testing.allocator.free(narrow);
    try testing.expect(std.mem.find(u8, narrow, "A very long session…  working") != null);
    // A pipe gets the whole title.
    const whole = try renderLive(&sessions, false, .{ .now_ms = test_now_ms });
    defer testing.allocator.free(whole);
    try testing.expect(std.mem.find(u8, whole, long ++ "  working") != null);
}

test "an age reads as the resume picker says it for a week, then as a local date" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const day = std.time.ms_per_day;
    try testing.expectEqualStrings("just now", try age(arena, test_now_ms, test_now_ms));
    try testing.expectEqualStrings("just now", try age(arena, test_now_ms + 5_000, test_now_ms));
    try testing.expectEqualStrings("59m ago", try age(arena, test_now_ms - 59 * std.time.ms_per_min, test_now_ms));
    try testing.expectEqualStrings("23h ago", try age(arena, test_now_ms - 23 * std.time.ms_per_hour, test_now_ms));
    try testing.expectEqualStrings("6d ago", try age(arena, test_now_ms - 7 * day + 1, test_now_ms));
    // 2027-01-08 08:00:00 UTC, a week before 1_800_000_000_000.
    try testing.expectEqualStrings("2027-01-08", try age(arena, test_now_ms - 7 * day, test_now_ms));

    local_time.test_zone = .{ .offset_s = -5 * 3600, .name = "EST" };
    defer local_time.test_zone = .utc;
    // 04:30 UTC is still the day before five hours west.
    try testing.expectEqualStrings("2023-11-14", try age(arena, 1_700_022_600_000, test_now_ms));
}

test "a saved list shows title, turns, age, and id in columns, and says how to page on" {
    const sessions = [_]session_store.SessionSummary{
        summaryAt("abc000000000", "Fix the login bug", 4),
        summaryAt("old000000000", null, 30 * 24 * 60),
    };
    const text = try renderSaved(.{ .sessions = &sessions, .has_more = true, .next_cursor = "v1:2:old000000000", .skipped_invalid = 1 }, .{ .now_ms = test_now_ms });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "Newest 2 saved sessions in this workspace\n" ++
            "\n" ++
            "TITLE              TURNS  UPDATED     SESSION ID\n" ++
            "Fix the login bug      3  4m ago      abc000000000\n" ++
            "Untitled session       3  2026-12-16  old000000000\n" ++
            "\n" ++
            "More              fx sessions --cursor v1:2:old000000000\n" ++
            "Read a session    fx session <session id> --tail 5\n" ++
            "Running now       fx sessions --live\n" ++
            "Skipped 1 unreadable saved session; run `fx doctor` for recovery guidance\n",
        text,
    );

    const one = try renderSaved(.{ .sessions = sessions[0..1], .all_workspaces = true }, .{ .now_ms = test_now_ms, .home = "/Users/example" });
    defer testing.allocator.free(one);
    try testing.expect(std.mem.startsWith(u8, one, "1 saved session in all workspaces, newest first\n\nTITLE              TURNS  UPDATED  SESSION ID    WORKSPACE\n"));
    try testing.expect(std.mem.find(u8, one, "Fix the login bug      3  4m ago   abc000000000  ~/w\n") != null);
}

test "an empty saved list says so, and names unreadable sessions" {
    const none = try renderSaved(.{ .sessions = &.{} }, .{ .now_ms = test_now_ms });
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("No saved sessions in this workspace.\n", none);
    const unreadable = try renderSaved(.{ .sessions = &.{}, .skipped_invalid = 2, .all_workspaces = true }, .{ .now_ms = test_now_ms });
    defer testing.allocator.free(unreadable);
    try testing.expectEqualStrings(
        "No readable saved sessions in all workspaces.\n" ++
            "Skipped 2 unreadable saved sessions; run `fx doctor` for recovery guidance\n",
        unreadable,
    );
}

test "every row of a random session list lines up and holds no control bytes" {
    var prng = std.Random.DefaultPrng.init(0x5e55);
    const random = prng.random();
    var titles: [12][24]u8 = undefined;
    var summaries: [12]session_store.SessionSummary = undefined;
    var live: [12]session_store.LiveSession = undefined;
    const ids = [_][]const u8{ "aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc", "dddddddddddd", "eeeeeeeeeeee", "ffffffffffff", "gggggggggggg", "hhhhhhhhhhhh", "iiiiiiiiiiii", "jjjjjjjjjjjj", "kkkkkkkkkkkk", "llllllllllll" };
    for (0..200) |_| {
        const count = random.uintAtMost(usize, titles.len);
        for (0..count) |i| {
            const len = random.uintAtMost(usize, titles[i].len);
            random.bytes(titles[i][0..len]);
            summaries[i] = summaryAt(ids[i], if (random.boolean()) titles[i][0..len] else null, @intCast(random.uintAtMost(u32, 20 * 24 * 60)));
            live[i] = .{ .summary = summaries[i], .saved_model = if (random.boolean()) "m" else "n", .state = random.enumValue(session_store.LiveState), .agents = &.{} };
        }
        const columns: ?usize = if (random.boolean()) null else 20 + random.uintAtMost(usize, 100);
        const style: Style = .{ .now_ms = test_now_ms, .columns = columns };
        const outputs = [_][]u8{
            try renderLive(live[0..count], random.boolean(), style),
            try renderSaved(.{ .sessions = summaries[0..count] }, style),
        };
        for (outputs) |text| {
            defer testing.allocator.free(text);
            try testing.expect(text_utils.isTerminalSafeText(text));
            // Each id starts at the column its SESSION ID head starts at.
            var lines = std.mem.splitScalar(u8, text, '\n');
            var id_column: ?usize = null;
            while (lines.next()) |line| {
                if (std.mem.find(u8, line, "SESSION ID")) |at| id_column = display_width.visibleWidth(line[0..at]);
                for (ids[0..count]) |id| {
                    const at = std.mem.find(u8, line, id) orelse continue;
                    try testing.expectEqual(id_column.?, display_width.visibleWidth(line[0..at]));
                }
            }
        }
    }
}
