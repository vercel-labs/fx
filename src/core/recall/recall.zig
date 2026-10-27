//! Recall: search over a node's own history, and the internal URLs
//! `history://` and `agent://` that read any node of its tree.
//!
//! In: a `NodeView` of the calling node, which its host builds from the
//! session store and the fleet (`src/core/subagent/tool_host.zig`).
//! Out: text for the agent, in proto's recall shapes.
//!
//! Inside:
//! - corpus.zig turns saved turns into numbered entries and bounds them.
//! - rank.zig scores entries for a query (BM25+) and cuts snippets.
//! - urls.zig parses and renders `history://` and `agent://`.
//!
//! The index of a node is built on first use and cached per tree; a new
//! line in the node's log invalidates it (`NodeInfo.version`).
const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const corpus = @import("corpus.zig");
const rank = @import("rank.zig");
const urls = @import("urls.zig");

const Allocator = std.mem.Allocator;

pub const StoredReader = corpus.StoredReader;
pub const isInternalUrl = urls.isInternalUrl;
pub const readUrl = urls.read;

/// Results per page, as proto's recall.
pub const page_size = 5;
/// Entries listed when no query is given.
const recent_entries = 25;
/// Characters one response may spend before trailing results are dropped.
const response_budget = 48 * 1024;

/// Where a saved node sits in its tree. Strings are owned by the arena the
/// source was given.
pub const NodeInfo = struct {
    root: []const u8,
    parent: ?[]const u8,
    depth: u64,
    /// Changes whenever the node's log grows.
    version: u64,
    turns: u64,
    running: bool,
};

/// Takes each kept turn of a node with its number; the turn is borrowed for
/// the call.
pub const TurnSink = struct {
    context: *anyopaque,
    turn_fn: *const fn (context: *anyopaque, turn: types.HistoryTurn, number: u64) anyerror!void,

    pub fn turn(self: TurnSink, value: types.HistoryTurn, number: u64) !void {
        return self.turn_fn(self.context, value, number);
    }
};

/// What recall reads, implemented by the node's host.
pub const Source = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Every turn node `id` keeps, oldest first.
        visit_turns: *const fn (context: *anyopaque, alloc: Allocator, id: []const u8, sink: TurnSink) anyerror!void,
        /// Null when no saved node has that id.
        node_info: *const fn (context: *anyopaque, arena: Allocator, id: []const u8) anyerror!?NodeInfo,
        child_ids: *const fn (context: *anyopaque, arena: Allocator, id: []const u8) anyerror![]const []const u8,
        /// The fleet's summary of `id` when it is a worker of the calling
        /// node; null otherwise.
        inspect_worker: *const fn (context: *anyopaque, arena: Allocator, id: []const u8) anyerror!?[]const u8,
    };

    pub fn visitTurns(self: Source, alloc: Allocator, id: []const u8, sink: TurnSink) !void {
        return self.vtable.visit_turns(self.context, alloc, id, sink);
    }

    pub fn nodeInfo(self: Source, arena: Allocator, id: []const u8) !?NodeInfo {
        return self.vtable.node_info(self.context, arena, id);
    }

    pub fn childIds(self: Source, arena: Allocator, id: []const u8) ![]const []const u8 {
        return self.vtable.child_ids(self.context, arena, id);
    }

    pub fn inspectWorker(self: Source, arena: Allocator, id: []const u8) !?[]const u8 {
        return self.vtable.inspect_worker(self.context, arena, id);
    }
};

/// The calling node and its tree.
pub const NodeView = struct {
    source: Source,
    cache: *Cache,
    root_id: []const u8,
    node_id: []const u8,
};

/// The indexes of recently searched nodes of one tree, one per node, each
/// labelled with the log line its build began after (D125,
/// `tests/tla/session_manager/RecallCache.tla` `FreshAtStart`,
/// `CacheBounded`). The tree owns it and frees it after its hosts close
/// (`NoUseAfterFree`).
pub const Cache = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    slots: [slot_count]?*corpus.Index = @splat(null),
    used: [slot_count]u64 = @splat(0),
    clock: u64 = 0,

    const slot_count = 4;

    pub fn init(alloc: Allocator) Cache {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Cache) void {
        for (&self.slots) |*slot| if (slot.*) |index| self.drop(index, slot);
    }

    fn drop(self: *Cache, index: *corpus.Index, slot: *?*corpus.Index) void {
        index.deinit();
        self.alloc.destroy(index);
        slot.* = null;
    }

    /// The index of node `id` at `version`, rebuilt when the log moved on.
    /// The caller holds `mutex`.
    fn indexFor(self: *Cache, source: Source, id: []const u8, version: u64, stored: ?StoredReader) !*corpus.Index {
        self.clock += 1;
        for (&self.slots, 0..) |*slot, at| {
            const index = slot.* orelse continue;
            if (!std.mem.eql(u8, index.id, id)) continue;
            if (index.version == version) {
                self.used[at] = self.clock;
                return index;
            }
            self.drop(index, slot);
        }
        // An empty slot, else the least recently used one.
        var victim: usize = 0;
        for (self.slots, self.used, 0..) |slot, used, at| {
            if (slot == null) {
                victim = at;
                break;
            }
            if (used < self.used[victim]) victim = at;
        }
        if (self.slots[victim]) |old| self.drop(old, &self.slots[victim]);
        const index = try self.alloc.create(corpus.Index);
        errdefer self.alloc.destroy(index);
        index.* = try corpus.Index.init(self.alloc, id, version);
        errdefer index.deinit();
        const Builder = struct {
            index: *corpus.Index,
            stored: ?StoredReader,

            fn turn(context: *anyopaque, value: types.HistoryTurn, number: u64) anyerror!void {
                const builder: *@This() = @ptrCast(@alignCast(context));
                try builder.index.addTurn(value, number, builder.stored);
            }
        };
        var builder: Builder = .{ .index = index, .stored = stored };
        try source.visitTurns(self.alloc, id, .{ .context = &builder, .turn_fn = Builder.turn });
        self.slots[victim] = index;
        self.used[victim] = self.clock;
        return index;
    }
};

pub const Request = struct {
    query: []const u8 = "",
    page: usize = 1,
};

/// Searches the calling node's history. `stored` reads the whole outputs
/// the model saw only a preview of. Caller owns the text.
pub fn search(alloc: Allocator, view: NodeView, request: Request, stored: ?StoredReader) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const info = try view.source.nodeInfo(arena, view.node_id) orelse
        return alloc.dupe(u8, "No entries in session history: this session has no saved turn yet.");
    view.cache.mutex.lockUncancelable(io_mod.getIo());
    defer view.cache.mutex.unlock(io_mod.getIo());
    const index = try view.cache.indexFor(view.source, view.node_id, info.version, stored);
    var out: std.Io.Writer.Allocating = .init(arena);
    try respond(arena, &out.writer, index, view.node_id, request);
    return alloc.dupe(u8, out.written());
}

fn respond(arena: Allocator, writer: *std.Io.Writer, index: *const corpus.Index, node: []const u8, request: Request) !void {
    const query = std.mem.trim(u8, request.query, " \t\r\n");
    if (query.len == 0) return writeRecent(writer, index, node);
    if (expandIndex(query)) |number| return writeExpanded(writer, index, node, number);
    const query_terms = try rank.terms(arena, query);
    const hits = try rank.rank(arena, index.entries.items, query_terms);
    if (hits.len == 0) {
        try writer.print("No matches for \"{s}\" in session history.", .{query});
        return writeDropped(writer, index);
    }
    const pages = (hits.len + page_size - 1) / page_size;
    const page = @min(@max(request.page, 1), pages);
    if (pages > 1)
        try writer.print("Page {d}/{d} ({d} matches) for \"{s}\":", .{ page, pages, hits.len, query })
    else
        try writer.print("Found {d} {s} for \"{s}\":", .{ hits.len, if (hits.len == 1) "match" else "matches", query });
    try writeDropped(writer, index);
    const first = (page - 1) * page_size;
    var spent: usize = 0;
    for (hits[first..@min(hits.len, first + page_size)], first..) |hit, position| {
        var block: std.Io.Writer.Allocating = .init(arena);
        try writeHit(arena, &block.writer, index.entries.items[hit.slot], node, query_terms);
        if (spent > 0 and spent + block.written().len > response_budget) {
            try writer.print("\n\n--- {d} more results did not fit; use page:{d} ---", .{ @min(hits.len, first + page_size) - position, page + 1 });
            return;
        }
        spent += block.written().len;
        try writer.print("\n\n{s}", .{block.written()});
    }
    if (page < pages) try writer.print("\n\n--- Use page:{d} for more results ---", .{page + 1});
}

fn writeDropped(writer: *std.Io.Writer, index: *const corpus.Index) !void {
    if (index.dropped > 0) try writer.print("\n(The oldest {d} entries are past recall's memory bound; read them with history://.)", .{index.dropped});
}

/// `#12` expands entry 12.
fn expandIndex(query: []const u8) ?usize {
    if (query.len < 2 or query[0] != '#') return null;
    return std.fmt.parseUnsigned(usize, query[1..], 10) catch null;
}

fn writeHit(arena: Allocator, writer: *std.Io.Writer, entry: corpus.Entry, node: []const u8, query_terms: []const []const u8) !void {
    const body = try rank.snippet(arena, entry.text, query_terms) orelse summary(entry.text);
    try writer.print("#{d} [{s}] ", .{ entry.index, entry.label() });
    try writeIndented(writer, body);
    if (entry.path) |path| {
        var matches: usize = 0;
        var lines = std.mem.splitScalar(u8, entry.text, '\n');
        while (lines.next()) |line| {
            for (query_terms) |term| if (std.ascii.findIgnoreCase(line, term) != null) {
                matches += 1;
                break;
            };
        }
        try writer.print("\n  [{s}] {s} — {d} {s}", .{ entry.tool, path, matches, if (matches == 1) "match" else "matches" });
    }
    try writeUse(writer, entry, node);
}

fn writeUse(writer: *std.Io.Writer, entry: corpus.Entry, node: []const u8) !void {
    try writer.print("\n  use history://{s}/turn/{d}", .{ node, entry.turn });
    if (entry.handle) |handle| try writer.print(" or read_tool_result handle \"{s}\"", .{handle});
}

fn writeIndented(writer: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeAll("\n  ");
        try writer.writeAll(line);
        first = false;
    }
}

fn summary(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const line = trimmed[0 .. std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len];
    return corpus.clip(line, 160);
}

fn writeRecent(writer: *std.Io.Writer, index: *const corpus.Index, node: []const u8) !void {
    const entries = index.entries.items;
    if (entries.len == 0) return writer.writeAll("No entries in session history.");
    const shown = entries[entries.len - @min(entries.len, recent_entries) ..];
    try writer.print("Session history ({d} entries):\n", .{index.next});
    for (shown) |entry| try writer.print("\n#{d} [{s}] turn {d} · {s}", .{ entry.index, entry.label(), entry.turn, summary(entry.text) });
    try writer.print("\n\nSearch with a query, expand one entry with #N, or read a whole turn with history://{s}/turn/N.", .{node});
}

fn writeExpanded(writer: *std.Io.Writer, index: *const corpus.Index, node: []const u8, number: usize) !void {
    const entry = index.find(number) orelse
        return writer.print("No entry #{d} in session history; entries run from #{d} to #{d}.", .{ number, index.dropped, index.next -| 1 });
    try writer.print("#{d} [{s}] turn {d}\n", .{ entry.index, entry.label(), entry.turn });
    const shown = corpus.clip(entry.text, response_budget);
    try writer.writeAll(shown);
    if (shown.len < entry.text.len) try writer.print("\n… {d} more bytes", .{entry.text.len - shown.len});
    try writeUse(writer, entry, node);
}

const testing = std.testing;

const FakeSource = struct {
    turns: []const types.HistoryTurn,
    version: u64 = 1,
    visits: usize = 0,

    fn source(self: *FakeSource) Source {
        return .{ .context = self, .vtable = &.{
            .visit_turns = visitTurns,
            .node_info = nodeInfo,
            .child_ids = childIds,
            .inspect_worker = inspectWorker,
        } };
    }

    fn visitTurns(context: *anyopaque, _: Allocator, _: []const u8, sink: TurnSink) anyerror!void {
        const self: *FakeSource = @ptrCast(@alignCast(context));
        self.visits += 1;
        for (self.turns, 1..) |turn, number| try sink.turn(turn, number);
    }

    fn nodeInfo(context: *anyopaque, _: Allocator, _: []const u8) anyerror!?NodeInfo {
        const self: *FakeSource = @ptrCast(@alignCast(context));
        return .{ .root = "root", .parent = null, .depth = 0, .version = self.version, .turns = self.turns.len, .running = false };
    }

    fn childIds(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const []const u8 {
        return &.{};
    }

    fn inspectWorker(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?[]const u8 {
        return null;
    }
};

test "recall finds a detail in proto's shapes, pages, expands, and rebuilds only when the log grows" {
    var steps = [_]types.ToolExecutionStep{.{}};
    const turns = [_]types.HistoryTurn{
        corpus.testTurn("Use exponential backoff for retry storms.", &.{}, "Noted."),
        corpus.testTurn("deploy one", &steps, "deployed one"),
        corpus.testTurn("deploy two", &.{}, "deployed two"),
        corpus.testTurn("deploy three", &.{}, "deployed three"),
    };
    var fake: FakeSource = .{ .turns = &turns };
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();
    const view: NodeView = .{ .source = fake.source(), .cache = &cache, .root_id = "root", .node_id = "root" };

    const found = try search(testing.allocator, view, .{ .query = "retry storms" }, null);
    defer testing.allocator.free(found);
    try testing.expectEqualStrings(
        "Found 1 match for \"retry storms\":\n\n#0 [user] Use exponential backoff for retry storms.\n  use history://root/turn/1",
        found,
    );

    const paged = try search(testing.allocator, view, .{ .query = "deploy" }, null);
    defer testing.allocator.free(paged);
    try testing.expect(std.mem.startsWith(u8, paged, "Page 1/2 (6 matches) for \"deploy\":"));
    try testing.expect(std.mem.endsWith(u8, paged, "--- Use page:2 for more results ---"));
    const second = try search(testing.allocator, view, .{ .query = "deploy", .page = 2 }, null);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.startsWith(u8, second, "Page 2/2"));
    try testing.expectEqual(@as(usize, 1), fake.visits);

    const expanded = try search(testing.allocator, view, .{ .query = "#1" }, null);
    defer testing.allocator.free(expanded);
    try testing.expectEqualStrings("#1 [assistant] turn 1\nNoted.\n  use history://root/turn/1", expanded);

    const recent = try search(testing.allocator, view, .{}, null);
    defer testing.allocator.free(recent);
    try testing.expect(std.mem.startsWith(u8, recent, "Session history (8 entries):\n\n#0 [user] turn 1 · Use exponential"));

    const none = try search(testing.allocator, view, .{ .query = "kubernetes" }, null);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("No matches for \"kubernetes\" in session history.", none);
    try testing.expectEqual(@as(usize, 1), fake.visits);

    fake.version = 2;
    const again = try search(testing.allocator, view, .{ .query = "retry" }, null);
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(usize, 2), fake.visits);
}

test {
    _ = @import("scheme.zig");
    _ = corpus;
    _ = rank;
    _ = urls;
}
