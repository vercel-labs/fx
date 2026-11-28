//! A saved session's history a page at a time, for a client that asks for
//! it with `_meta.fx.historyPages`: `session/load` sends the newest page,
//! which holds the bottom screen, and `_fx/session/history` sends each older
//! one. A page holds whole turns, newest first back to a budget of update
//! bytes, except a turn that alone passes the budget: its final reply is cut
//! at a paragraph start, and the cursor's `part` says where, so the bottom
//! screen stays small whatever the size of the chat or of one reply.
//! `tests/tla/session/HistoryLoad.tla` models it (BottomBounded, LoadBounded,
//! TranscriptExact).

const std = @import("std");
const Allocator = std.mem.Allocator;
const debug_trace = @import("../core/shared/debug_trace.zig");
const types = @import("../core/shared/types.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const runtime_tool_presentation = @import("../core/agent/runtime/tool_presentation.zig");
const server = @import("server.zig");
const sessions = @import("sessions.zig");

const LogCursor = std.meta.Elem(@FieldType(session_adapter.Session.HistoryPage, "turns"));

/// Update bytes in the newest page, which holds the bottom screen.
pub const newest_budget: usize = 64 << 10;
/// Update bytes in each older page.
pub const older_budget: usize = 256 << 10;

/// Where a page ends: before the turn whose first line is at `offset`, or,
/// when `part` is above 0, inside that turn, before byte `part` of its final
/// reply.
pub const Cursor = struct {
    offset: u64,
    seq: u64,
    part: u64 = 0,
};

/// While a page is built, the updates the history senders write, as
/// `session/update` params, instead of the client (`ServerState.history_capture`).
/// Only the thread that builds the page sets it.
pub const Capture = struct {
    arena: Allocator,
    updates: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *Capture, params: []const u8) Allocator.Error!void {
        try self.updates.append(self.arena, try self.arena.dupe(u8, params));
    }
};

/// A page, ready to send.
pub const Page = struct {
    /// `session/update` params, oldest first.
    updates: []const []const u8,
    /// Where the next older page ends, or null at the log's start or at a
    /// damaged line.
    next: ?Cursor,
    /// A damaged line stopped the read: older history can't be read.
    damaged: bool,
    /// Its last update continues the message the client shows right below.
    continues: bool,
};

/// One encoded turn of a page.
const Turn = struct {
    /// Every update of the turn, as a whole load sends it.
    whole: []const []const u8,
    /// For a turn that ends with a reply a cut can shorten: the updates
    /// before the reply, and the reply. Kept only for a turn past the budget.
    head: []const []const u8 = &.{},
    reply: ?[]const u8 = null,
};

/// Builds the page that ends at `end`, or at the log's end when it is null,
/// in `arena`. `error.InvalidCursor` when `end` isn't where a page of this
/// session ends.
pub fn build(
    state: *server.ServerState,
    arena: Allocator,
    session_id: []const u8,
    end: ?Cursor,
    budget: usize,
) !Page {
    const v2 = state.active_session.?.v2.?;
    // The newest turn of the page: the one the cursor ends inside, or the
    // one before it. `turnAfter` also checks the cursor names a turn start.
    const before: ?LogCursor = if (end) |c| blk: {
        const at: LogCursor = .{ .offset = c.offset, .seq = c.seq };
        const after = try v2.turnAfter(arena, at);
        break :blk if (c.part > 0) after else at;
    } else null;
    const found = try v2.historyPage(arena, before, budget);
    const continues = if (end) |c| c.part > 0 else false;
    if (found.turns.len == 0) return .{ .updates = &.{}, .next = null, .damaged = found.damaged, .continues = false };

    var capture: Capture = .{ .arena = arena };
    var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
    var collector: Collector = .{ .state = state, .arena = arena, .session_id = session_id, .sources = &sources, .capture = &capture, .budget = budget };
    state.history_capture = &capture;
    defer state.history_capture = null;
    try v2.visitHistoryRange(arena, found.turns[0], if (before) |c| c.offset else null, &collector);
    const turns = collector.turns.items;

    if (turns.len != found.turns.len) {
        // Each turn start the scan found is one turn of the replay; when they
        // don't pair up, the page goes whole, with no cut.
        debug_trace.logf("acp", "event=history_page_unpaired starts={d} turns={d}", .{ found.turns.len, turns.len });
        var all: std.ArrayList([]const u8) = .empty;
        for (turns) |turn| try all.appendSlice(arena, turn.whole);
        const next: ?Cursor = if (found.older) .{ .offset = found.turns[0].offset, .seq = found.turns[0].seq } else null;
        return .{ .updates = all.items, .next = next, .damaged = found.damaged, .continues = continues };
    }

    // The newest turn may be cut short by the cursor's `part`.
    const newest = turns[turns.len - 1];
    const limit: ?usize = if (end) |c| (if (c.part > 0) @intCast(c.part) else null) else null;
    var sizes = try arena.alloc(usize, turns.len);
    for (turns, sizes) |turn, *size| size.* = bytesOf(turn.whole);
    if (limit) |part| sizes[turns.len - 1] = bytesOf(newest.head) + part;

    const count = fitting(sizes, budget);
    var out: std.ArrayList([]const u8) = .empty;
    const first = turns.len - count;
    for (turns[first .. turns.len - 1]) |turn| try out.appendSlice(arena, turn.whole);
    var next: ?Cursor = if (first > 0 or found.older) .{ .offset = found.turns[first].offset, .seq = found.turns[first].seq } else null;

    const newest_start = found.turns[turns.len - 1];
    if (newest.reply) |reply| {
        const reply_end = limit orelse reply.len;
        const cut = if (sizes[turns.len - 1] > budget) paragraphCut(reply, reply_end, budget) else 0;
        if (cut > 0) {
            // Only the end of the reply fits: the rest of the turn goes in
            // the next page.
            try out.appendSlice(arena, try collector.chunk(reply[cut..reply_end]));
            next = .{ .offset = newest_start.offset, .seq = newest_start.seq, .part = cut };
        } else if (limit != null) {
            try out.appendSlice(arena, newest.head);
            try out.appendSlice(arena, try collector.chunk(reply[0..reply_end]));
        } else try out.appendSlice(arena, newest.whole);
    } else try out.appendSlice(arena, newest.whole);
    return .{ .updates = out.items, .next = next, .damaged = found.damaged, .continues = continues };
}

/// Encodes each turn of a page as it is replayed.
const Collector = struct {
    state: *server.ServerState,
    arena: Allocator,
    session_id: []const u8,
    sources: *runtime_tool_presentation.ReplayedSavedOutputSources,
    capture: *Capture,
    budget: usize,
    turns: std.ArrayList(Turn) = .empty,

    pub fn append(self: *Collector, turn: types.HistoryTurn) !void {
        // A compaction's summary sends nothing, so it is no turn of a page.
        if (turn == .compacted_summary) return;
        try sessions.sendHistoryTurnAsUpdates(self.state, self.arena, self.session_id, self.sources, turn);
        const whole = try self.take();
        var entry: Turn = .{ .whole = whole };
        if (turn == .assistant and bytesOf(whole) > self.budget) {
            const assistant = turn.assistant;
            try sessions.sendUserHistoryTurn(self.state, self.arena, self.session_id, assistant.user);
            try sessions.sendExecutionHistory(self.state, self.arena, self.session_id, self.sources, assistant.execution);
            entry.head = try self.take();
            entry.reply = try self.arena.dupe(u8, assistant.assistant);
        }
        try self.turns.append(self.arena, entry);
    }

    /// One agent message with `text`, as a reply's part.
    fn chunk(self: *Collector, text: []const u8) ![]const []const u8 {
        self.state.history_capture = self.capture;
        defer self.state.history_capture = null;
        try sessions.sendAgentHistoryChunk(self.state, self.arena, self.session_id, text);
        return self.take();
    }

    /// The updates captured since the last take.
    fn take(self: *Collector) ![]const []const u8 {
        const updates = try self.arena.dupe([]const u8, self.capture.updates.items);
        self.capture.updates.clearRetainingCapacity();
        return updates;
    }
};

fn bytesOf(updates: []const []const u8) usize {
    var total: usize = 0;
    for (updates) |update| total += update.len;
    return total;
}

/// How many of a page's turns, newest first, fit `budget` together: always
/// at least one, so a turn past the budget still goes in a page of its own.
pub fn fitting(sizes: []const usize, budget: usize) usize {
    var used: usize = 0;
    var count: usize = 0;
    var index = sizes.len;
    while (index > 0) {
        index -= 1;
        if (count > 0 and used + sizes[index] > budget) break;
        used += sizes[index];
        count += 1;
    }
    return count;
}

/// Where to cut `text[0..end]` so about `budget` bytes follow the cut: the
/// first paragraph start at or past `end - budget`, else the last one before
/// it, so a long paragraph goes whole. 0, no cut, when `end` fits or there
/// is no paragraph start.
pub fn paragraphCut(text: []const u8, end: usize, budget: usize) usize {
    if (end <= budget) return 0;
    const lowest = end - budget;
    var last_before: usize = 0;
    var from: usize = 0;
    while (std.mem.findPos(u8, text[0..end], from, "\n\n")) |at| {
        const start = at + 2;
        if (start >= end) break;
        if (start >= lowest) return start;
        last_before = start;
        from = at + 1;
    }
    return last_before;
}

test "fitting takes the newest turns that fit, and at least one" {
    try std.testing.expectEqual(@as(usize, 2), fitting(&.{ 50, 40, 30 }, 80));
    try std.testing.expectEqual(@as(usize, 3), fitting(&.{ 10, 20, 30 }, 60));
    try std.testing.expectEqual(@as(usize, 1), fitting(&.{ 10, 500 }, 100));
    try std.testing.expectEqual(@as(usize, 0), fitting(&.{}, 100));
}

test "paragraphCut leaves about the budget after the cut, at a paragraph start" {
    const text = "aaaa\n\nbbbb\n\ncccc\n\ndddd";
    // Everything fits: no cut.
    try std.testing.expectEqual(@as(usize, 0), paragraphCut(text, text.len, 100));
    // The first paragraph start at or past end - 10 is the one before "cccc".
    try std.testing.expectEqual(@as(usize, 12), paragraphCut(text, text.len, 10));
    try std.testing.expectEqualStrings("cccc\n\ndddd", text[paragraphCut(text, text.len, 10)..]);
    // Inside a long paragraph: the last start before it, so it goes whole.
    const long = "aa\n\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try std.testing.expectEqual(@as(usize, 4), paragraphCut(long, long.len, 5));
    // No paragraph start at all: no cut.
    const one_paragraph: [64]u8 = @splat('x');
    try std.testing.expectEqual(@as(usize, 0), paragraphCut(&one_paragraph, 64, 8));
    // A cut inside an earlier part, as a cursor's `part` makes.
    try std.testing.expectEqual(@as(usize, 6), paragraphCut(text, 12, 6));
}
