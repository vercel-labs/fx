//! What a session's viewers read about the nodes of its tree: any node's
//! children and any node's transcript after a cursor (D91). A node whose
//! turn runs is read through its live host (`tool_host.Runtime.withNodeHost`),
//! which has its live phases and output; any other node is read from its
//! parent's saved log. Every node names its real parent. All of this reads
//! the host, so only the session's executor calls it.
const std = @import("std");
const acp = @import("../../acp/server.zig");
const child_state = @import("../subagent/child_state.zig");
const live_presentation = @import("../subagent/live_presentation.zig");
const tool_host = @import("../subagent/tool_host.zig");
const session_adapter = @import("../session/session_adapter.zig");
const types = @import("../shared/types.zig");
const protocol = @import("protocol.zig");
const Allocator = std.mem.Allocator;

/// The child-history response the supervisor encodes: saved turns as cached
/// JSON, live events as the tail's JSON.
pub const View = protocol.ChildHistory(protocol.RawJson, protocol.RawJson);

/// One node as its parent records it. Strings borrow the read's arena.
const Row = struct {
    id: []const u8,
    parent_id: []const u8,
    name: []const u8,
    /// The phase, or the last outcome once a one-off finished.
    status: []const u8,
    detail: []const u8 = "",
    depth: u8,
    /// The work shown: the running one, or the newest.
    work_id: []const u8,
    /// Its work runs or waits for an approval.
    busy: bool = false,
    last_outcome: ?[]const u8 = null,
    last_failure: ?[]const u8 = null,
    active_prompt: ?[]const u8 = null,
};

/// What one read of a node's children found, and the live tail of the one
/// child `Read.child_id` names, read under the same host lock.
const Found = struct { rows: []const Row, live: ?live_presentation.Snapshot = null };

const Read = struct {
    arena: Allocator,
    node_id: []const u8,
    /// The child whose live output to copy, after this sequence.
    child_id: ?[]const u8 = null,
    viewer_work_id: []const u8 = "",
    after: u64 = 0,
    reset: bool = false,
};

/// The direct children of `node_id`, from its live host when its turn runs,
/// else from its saved log. A node with no log yet has none.
fn childRows(host: *acp.PersistentHost, read: Read) !Found {
    if (host.state.subagent_host) |root| {
        if (root.withNodeHost(read.node_id, anyerror!Found, &read, liveRows)) |found| return found;
    }
    const store = if (host.state.sessions_v2) |*value| value else return .{ .rows = &.{} };
    return .{ .rows = try savedRows(read.arena, store, read.node_id) };
}

fn liveRows(read: *const Read, node: *tool_host.Runtime) anyerror!Found {
    const store = child_state.Store{ .children = node.children, .parent_id = node.node_id };
    const registry = try store.load(read.arena);
    // The registry holds a node's live children; those a rewind abandoned
    // stay listed from its log, read-only (D97).
    const folded = try node.children.parent.children(read.arena);
    var abandoned: usize = 0;
    for (folded) |child| {
        if (child.abandoned) abandoned += 1;
    }
    const all = try read.arena.alloc(Row, registry.children.len + abandoned);
    const rows = all[0..registry.children.len];
    var live: ?live_presentation.Snapshot = null;
    for (registry.children, rows) |*child, *row| {
        const busy = child.phase == .running or child.phase == .awaiting_approval;
        const work_id = if (child.active) |active| active.id else child.last_work_id orelse "";
        row.* = .{
            .id = child.id,
            .parent_id = node.node_id,
            .name = child.agentName() orelse "subagent",
            .status = try liveStatus(read.arena, child),
            .detail = if (child.active) |active| active.message else child.instructions(),
            .depth = node.depth + 1,
            .work_id = work_id,
            .busy = busy,
            .last_outcome = if (child.last_outcome) |outcome| @tagName(outcome) else null,
            .last_failure = if (child.last_failure) |*failure| failure.view() else null,
            .active_prompt = if (child.active) |active| active.message else null,
        };
        const wanted = read.child_id orelse continue;
        if (!std.mem.eql(u8, child.id, wanted)) continue;
        const changed_work = !std.mem.eql(u8, read.viewer_work_id, work_id);
        live = try node.managed.snapshotPresentation(read.arena, child.id, work_id, read.after, read.reset or changed_work);
    }
    var next = rows.len;
    for (folded) |child| {
        if (!child.abandoned) continue;
        all[next] = .{
            .id = child.id,
            .parent_id = node.node_id,
            .name = spawnAgent(read.arena, child.spawn_data) orelse "subagent",
            .status = "abandoned",
            .depth = node.depth + 1,
            .work_id = child.work_id,
        };
        next += 1;
    }
    // The registry strings borrow the arena; the node id outlives the read.
    for (all) |*row| row.parent_id = try read.arena.dupe(u8, row.parent_id);
    return .{ .rows = all, .live = live };
}

fn liveStatus(arena: Allocator, child: *const child_state.Child) ![]const u8 {
    if (child.terminated) return "terminated";
    const base = if (child.phase != .finished) @tagName(child.phase) else if (child.last_outcome) |outcome| @tagName(outcome) else "finished";
    // A worker's queued turns wait behind this one (D102).
    if (child.queue.len > 0) return arena.print("{s} · {d} queued", .{ base, child.queue.len });
    return base;
}

/// fx's data on the saved `child_spawned` and `child_finished` lines.
const SpawnData = struct { agent: ?[]const u8 = null };

fn spawnAgent(arena: Allocator, raw: ?[]const u8) ?[]const u8 {
    const data = raw orelse return null;
    const spawn = std.json.parseFromSliceLeaky(SpawnData, arena, data, .{ .ignore_unknown_fields = true }) catch return null;
    return spawn.agent;
}
const FinishData = struct { failure: ?[]const u8 = null };

fn savedRows(arena: Allocator, store: *session_adapter.Store, node_id: []const u8) ![]const Row {
    const peeked = store.manager.peek(arena, node_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const folded = peeked.state.children.items;
    const rows = try arena.alloc(Row, folded.len);
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    for (folded, rows) |child, *row| {
        const spawn: SpawnData = if (child.spawn_data) |raw| std.json.parseFromSliceLeaky(SpawnData, arena, raw, options) catch .{} else .{};
        const finish: FinishData = if (child.finish_data) |raw| std.json.parseFromSliceLeaky(FinishData, arena, raw, options) catch .{} else .{};
        const outcome: ?[]const u8 = if (child.outcome) |value| switch (value) {
            .ok => "completed",
            else => @tagName(value),
        } else null;
        // Saved work with no live host stopped: its parent's turn ended.
        const status = if (child.abandoned)
            "abandoned"
        else if (child.terminated != null)
            "terminated"
        else if (child.queue.items.len > 0)
            try arena.print("{s} · {d} queued", .{ if (child.open) "interrupted" else "idle", child.queue.items.len })
        else if (child.open)
            "interrupted"
        else if (outcome) |value|
            if (spawn.agent != null and !std.mem.eql(u8, value, "interrupted") and !std.mem.eql(u8, value, "lost")) "idle" else value
        else
            "idle";
        row.* = .{
            .id = child.id,
            .parent_id = node_id,
            .name = spawn.agent orelse "subagent",
            .status = status,
            .depth = @intCast(@min(peeked.depth + 1, std.math.maxInt(u8))),
            .work_id = child.work_id,
            .last_outcome = outcome,
            .last_failure = finish.failure,
        };
    }
    return rows;
}

/// Node `node_id`'s direct children, encoded as a `Children` response.
pub fn children(arena: Allocator, host: *acp.PersistentHost, node_id: []const u8) ![]const u8 {
    const found = try childRows(host, .{ .arena = arena, .node_id = node_id });
    const listed = try arena.alloc(protocol.Child, found.rows.len);
    for (found.rows, listed) |row, *out| out.* = .{
        .id = row.id,
        .parent_id = row.parent_id,
        .name = row.name,
        .status = row.status,
        .detail = row.detail,
        .depth = row.depth,
    };
    return protocol.encode(arena, protocol.Children{ .node_id = node_id, .children = listed });
}

/// Whether any node of the tree has work running or waiting for an
/// approval. A descendant runs only inside its ancestors' running turns, so
/// a root child shows it, and any approval waiting at any depth counts too.
pub fn anyRunning(arena: Allocator, host: *acp.PersistentHost, root_id: []const u8) !bool {
    if (host.nodeWorkRunning()) return true;
    const root = host.state.subagent_host orelse return false;
    if (root.subtreeBusy()) return true;
    if ((try root.pendingApprovalRequests(arena, 1)).len > 0) return true;
    const found = try childRows(host, .{ .arena = arena, .node_id = root_id });
    for (found.rows) |row| if (row.busy) return true;
    return false;
}

/// One node's transcript after the cursor in `request`. Its saved turns come
/// from `cache` while its log is unchanged.
pub fn childView(arena: Allocator, host: *acp.PersistentHost, cache: *Cache, request: protocol.History) !View {
    const child_id = request.child_id orelse return error.ChildNotFound;
    const store = if (host.state.sessions_v2) |*value| value else return error.ChildNotFound;
    const parent_id = request.parent_id orelse parent: {
        const peeked = store.manager.peek(arena, child_id) catch return error.ChildNotFound;
        break :parent peeked.parent orelse return error.ChildNotFound;
    };
    const found = try childRows(host, .{
        .arena = arena,
        .node_id = parent_id,
        .child_id = child_id,
        .viewer_work_id = request.work_id orelse "",
        .after = request.after_live_sequence,
        .reset = request.include_history,
    });
    for (found.rows) |row| {
        if (!std.mem.eql(u8, row.id, child_id)) continue;
        const changed_work = !std.mem.eql(u8, request.work_id orelse "", row.work_id);
        const live_active = found.live != null or row.busy;
        const tail: live_presentation.Snapshot = found.live orelse .{};
        const live_reset = request.include_history or changed_work or tail.reset or request.live_active != live_active;
        const history: ?protocol.RawJson = if (live_reset)
            .{ .bytes = try savedHistory(arena, store, cache, child_id, if (live_active) row.work_id else "") }
        else
            null;
        return .{
            .child_id = child_id,
            .parent_id = row.parent_id,
            .work_id = row.work_id,
            .live_active = live_active,
            .live_sequence = tail.sequence,
            .oldest_live_sequence = tail.oldest_sequence,
            .live_reset = live_reset,
            .name = row.name,
            .status = if (live_active and !row.busy) "running" else row.status,
            .last_outcome = row.last_outcome,
            .last_failure = row.last_failure,
            .active_prompt = if (live_active) row.active_prompt else null,
            .history = history,
            .live_events = .{ .bytes = tail.events_json },
        };
    }
    return error.ChildNotFound;
}

/// The node's saved turns as JSON, without those of `skip_work`, the work
/// still running: its commits and compaction can race this read, so its
/// turns stay out until settlement replaces the live tail.
fn savedHistory(arena: Allocator, store: *session_adapter.Store, cache: *Cache, node_id: []const u8, skip_work: []const u8) ![]const u8 {
    const peeked = store.manager.peek(arena, node_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A child whose first work has not opened its log yet.
        error.NotFound => if (skip_work.len > 0) return "[]" else return err,
        else => return err,
    };
    const revision = peeked.state.last_seq;
    if (cache.get(node_id, revision, skip_work)) |bytes| return bytes;
    const saved = try store.childHistory(arena, node_id);
    var kept: std.ArrayList(types.HistoryTurn) = .empty;
    for (saved) |turn| {
        if (skip_work.len > 0 and historyBelongsToWork(turn, skip_work)) continue;
        try kept.append(arena, turn);
    }
    const bytes = try protocol.encode(arena, kept.items);
    cache.put(node_id, revision, skip_work, bytes) catch {};
    return bytes;
}

fn historyBelongsToWork(turn: types.HistoryTurn, work_id: []const u8) bool {
    const saved_work = switch (turn) {
        .assistant => |entry| entry.user.work_id,
        .interrupted => |entry| entry.user.work_id,
        .compacted_summary => null,
    } orelse return false;
    return std.mem.eql(u8, saved_work, work_id);
}

/// The saved transcripts of recently viewed nodes, keyed by node and log
/// revision, so moving between nodes or resetting a view does not replay a
/// log that has not changed. Bounded by count and bytes; the least recently
/// used goes first. Executor-only.
pub const Cache = struct {
    alloc: Allocator,
    /// Least recently used first.
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    max_entries: usize = 8,
    max_bytes: usize = 4 * 1024 * 1024,
    /// Reads that had to replay a log; tests watch it.
    misses: u64 = 0,

    const Entry = struct {
        node_id: []u8,
        /// The log's newest line when read.
        revision: u64,
        skip_work: []u8,
        json: []u8,

        fn deinit(self: Entry, alloc: Allocator) void {
            alloc.free(self.node_id);
            alloc.free(self.skip_work);
            alloc.free(self.json);
        }
    };

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    /// The cached JSON, which stays valid until the next `put`.
    fn get(self: *Cache, node_id: []const u8, revision: u64, skip_work: []const u8) ?[]const u8 {
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.node_id, node_id)) continue;
            if (entry.revision != revision or !std.mem.eql(u8, entry.skip_work, skip_work)) break;
            const hit = self.entries.orderedRemove(index);
            self.entries.appendAssumeCapacity(hit);
            return hit.json;
        }
        self.misses += 1;
        return null;
    }

    /// Keeps one entry per node: a newer read replaces it.
    fn put(self: *Cache, node_id: []const u8, revision: u64, skip_work: []const u8, json: []const u8) !void {
        if (json.len > self.max_bytes) return;
        for (self.entries.items, 0..) |entry, index| if (std.mem.eql(u8, entry.node_id, node_id)) {
            self.bytes -= entry.json.len;
            entry.deinit(self.alloc);
            _ = self.entries.orderedRemove(index);
            break;
        };
        while (self.entries.items.len > 0 and (self.entries.items.len >= self.max_entries or self.bytes + json.len > self.max_bytes)) {
            const oldest = self.entries.orderedRemove(0);
            self.bytes -= oldest.json.len;
            oldest.deinit(self.alloc);
        }
        const owned_node = try self.alloc.dupe(u8, node_id);
        errdefer self.alloc.free(owned_node);
        const owned_skip = try self.alloc.dupe(u8, skip_work);
        errdefer self.alloc.free(owned_skip);
        const owned_json = try self.alloc.dupe(u8, json);
        errdefer self.alloc.free(owned_json);
        try self.entries.append(self.alloc, .{ .node_id = owned_node, .revision = revision, .skip_work = owned_skip, .json = owned_json });
        self.bytes += json.len;
    }
};

test "the view cache keeps recent nodes within its bounds and drops stale revisions" {
    var cache = Cache{ .alloc = std.testing.allocator, .max_entries = 2, .max_bytes = 10 };
    defer cache.deinit();
    try std.testing.expect(cache.get("a", 1, "") == null);
    try cache.put("a", 1, "", "[1]");
    try cache.put("b", 1, "", "[2]");
    try std.testing.expectEqualStrings("[1]", cache.get("a", 1, "").?);
    // `b` is now the least recently used, so a third node evicts it.
    try cache.put("c", 1, "", "[3]");
    try std.testing.expect(cache.get("b", 1, "") == null);
    try std.testing.expectEqualStrings("[1]", cache.get("a", 1, "").?);
    // A newer log or a different running work misses.
    try std.testing.expect(cache.get("a", 2, "") == null);
    try std.testing.expect(cache.get("a", 1, "work") == null);
    try cache.put("a", 2, "", "[1,2]");
    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try std.testing.expectEqual(@as(usize, 8), cache.bytes);
    // The byte bound evicts the oldest; a value over it is never kept.
    try cache.put("d", 1, "", "[4444]");
    try std.testing.expect(cache.bytes <= 10);
    try cache.put("e", 1, "", "[too long json]");
    try std.testing.expect(cache.get("e", 1, "") == null);
    try std.testing.expectEqual(@as(u64, 5), cache.misses);
}

test "saved nodes list under their real parent at every depth" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const child_id = "1786460757753-mid";
    const grandchild_id = "1786460757753-low";
    try parent.parent.appendChildLines(&.{.{ .spawned = .{ .child = child_id, .work_id = "w1", .data = "{\"agent\":\"reviewer\",\"fingerprint\":\"00\"}" } }});
    var seed = parent.seed("");
    seed.node = .{ .root = parent.parent.id(), .depth = 1 };
    const child = try session_adapter.Session.openChild(alloc, &parent.store, parent.parent.id(), child_id, parent.home, seed);
    defer child.close();
    try child.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("review") }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());
    try child.appendChildLines(&.{
        .{ .spawned = .{ .child = grandchild_id, .work_id = "w2", .data = "{\"agent\":\"tests\",\"fingerprint\":\"00\"}" } },
        .{ .finished = .{ .child = grandchild_id, .work_id = "w2", .outcome = .ok } },
    });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top = try savedRows(arena, &parent.store, parent.parent.id());
    try std.testing.expectEqual(@as(usize, 1), top.len);
    try std.testing.expectEqualStrings("reviewer", top[0].name);
    try std.testing.expectEqualStrings(parent.parent.id(), top[0].parent_id);
    try std.testing.expectEqual(@as(u8, 1), top[0].depth);
    // Open work without a live host stopped with its parent's turn.
    try std.testing.expectEqualStrings("interrupted", top[0].status);

    const below = try savedRows(arena, &parent.store, child_id);
    try std.testing.expectEqual(@as(usize, 1), below.len);
    try std.testing.expectEqualStrings(grandchild_id, below[0].id);
    try std.testing.expectEqualStrings(child_id, below[0].parent_id);
    try std.testing.expectEqualStrings("tests", below[0].name);
    try std.testing.expectEqual(@as(u8, 2), below[0].depth);
    try std.testing.expectEqualStrings("idle", below[0].status);
    try std.testing.expectEqualStrings("completed", below[0].last_outcome.?);
    // A leaf has no children, and an unknown node has none either.
    try std.testing.expectEqual(@as(usize, 0), (try savedRows(arena, &parent.store, grandchild_id)).len);

    // The child's saved turns are read once while its log is unchanged.
    var cache = Cache{ .alloc = alloc };
    defer cache.deinit();
    const first = try savedHistory(arena, &parent.store, &cache, child_id, "");
    const again = try savedHistory(arena, &parent.store, &cache, child_id, "");
    try std.testing.expectEqualStrings(first, again);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    try std.testing.expect(std.mem.find(u8, first, "review") != null);
    try child.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("again") }, .assistant = @constCast("done") } }, types.ConversationLanguage.default());
    const after = try savedHistory(arena, &parent.store, &cache, child_id, "");
    try std.testing.expectEqual(@as(u64, 2), cache.misses);
    try std.testing.expect(std.mem.find(u8, after, "again") != null);
}
