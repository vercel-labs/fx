//! A worker's turn queue and tombstone in its parent's registry (D101,
//! D102). The registry is the in-memory truth; `planQueueLines` writes
//! what changed to the parent's log, where `child_queued`, a cancelled
//! `child_finished` and `child_terminated` lines keep both across restarts.
const std = @import("std");
const child_state = @import("child_state.zig");
const session_adapter = @import("../session/session_adapter.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const Registry = child_state.Registry;
const Child = child_state.Child;
const ActiveWork = child_state.ActiveWork;

/// The most turns one worker may have queued, and their total bytes.
pub const max_queued_turns: usize = 8;
pub const max_queued_bytes: usize = 256 * 1024;

/// fx's data on a `child_queued` line: the work as it will start.
const QueueData = struct {
    fingerprint: []const u8,
    message: []const u8,
    turn: u32,
    created_at_ms: i64 = 0,
    permission_mode: ?[]const u8 = null,
};

pub const QueueError = error{ OutOfMemory, ChildNotFound, Terminated, QueueFull, InvalidState };

/// The turn number the worker's next accepted turn gets.
pub fn nextTurn(child: Child) u32 {
    return child.turns +| 1;
}

/// Queues `work` behind the worker's running turn. The registry owns a copy.
pub fn enqueue(registry: *Registry, alloc: Allocator, child_id: []const u8, work: ActiveWork) QueueError!*Child {
    const child = registry.findById(child_id) orelse return error.ChildNotFound;
    if (child.terminated) return error.Terminated;
    if (child.agentName() == null) return error.InvalidState;
    var bytes = work.message.len;
    for (child.queue) |queued| bytes += queued.message.len;
    if (child.queue.len >= max_queued_turns or bytes > max_queued_bytes) return error.QueueFull;
    var copy = try work.clone(alloc);
    errdefer copy.deinit(alloc);
    const next = try alloc.alloc(ActiveWork, child.queue.len + 1);
    @memcpy(next[0..child.queue.len], child.queue);
    next[child.queue.len] = copy;
    if (child.queue.len > 0) alloc.free(child.queue);
    child.queue = next;
    child.turns = @max(child.turns, work.turn);
    registry.generation +|= 1;
    return child;
}

/// Starts the front of an idle worker's queue as its active work; null when
/// there is nothing to start.
pub fn startQueued(registry: *Registry, alloc: Allocator, child_id: []const u8) !?*Child {
    const child = registry.findById(child_id) orelse return null;
    if (child.terminated or child.active != null or child.queue.len == 0) return null;
    child.active = child.queue[0];
    const rest = child.queue[1..];
    if (rest.len == 0) {
        alloc.free(child.queue);
        child.queue = &.{};
    } else {
        const next = try alloc.alloc(ActiveWork, rest.len);
        @memcpy(next, rest);
        alloc.free(child.queue);
        child.queue = next;
    }
    child.phase = .running;
    child.work_generation +|= 1;
    registry.generation +|= 1;
    return child;
}

/// Drops one queued turn; false when it is not queued.
pub fn cancelQueued(registry: *Registry, alloc: Allocator, child_id: []const u8, work_id: []const u8) !bool {
    const child = registry.findById(child_id) orelse return false;
    for (child.queue, 0..) |*work, index| {
        if (!std.mem.eql(u8, work.id, work_id)) continue;
        work.deinit(alloc);
        if (child.queue.len == 1) {
            alloc.free(child.queue);
            child.queue = &.{};
        } else {
            const next = try alloc.alloc(ActiveWork, child.queue.len - 1);
            @memcpy(next[0..index], child.queue[0..index]);
            @memcpy(next[index..], child.queue[index + 1 ..]);
            alloc.free(child.queue);
            child.queue = next;
        }
        registry.generation +|= 1;
        return true;
    }
    return false;
}

/// Makes an idle worker terminal and drops its queue. Its running turn, if
/// any, must be finished first.
pub fn terminate(registry: *Registry, alloc: Allocator, child_id: []const u8) QueueError!void {
    const child = registry.findById(child_id) orelse return error.ChildNotFound;
    if (child.terminated) return error.Terminated;
    if (child.active != null) return error.InvalidState;
    child_state.freeWorks(alloc, child.queue);
    child.queue = &.{};
    child.terminated = true;
    child.phase = .finished;
    registry.generation +|= 1;
}

/// The queue of a folded child, as registry work. Owned by `alloc`.
pub fn foldedQueue(alloc: Allocator, folded: []const session_adapter.QueuedWork) ![]ActiveWork {
    if (folded.len == 0) return &.{};
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const out = try alloc.alloc(ActiveWork, folded.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*work| work.deinit(alloc);
        alloc.free(out);
    }
    for (folded) |item| {
        const raw = item.data orelse return error.InvalidState;
        const data = std.json.parseFromSliceLeaky(QueueData, scratch.allocator(), raw, .{ .ignore_unknown_fields = true }) catch return error.InvalidState;
        var fingerprint: [32]u8 = undefined;
        if (data.fingerprint.len != 64) return error.InvalidState;
        _ = std.fmt.hexToBytes(&fingerprint, data.fingerprint) catch return error.InvalidState;
        const id = try alloc.dupe(u8, item.work_id);
        errdefer alloc.free(id);
        out[built] = .{
            .id = id,
            .request_fingerprint = fingerprint,
            .message = try alloc.dupe(u8, data.message),
            .permission_mode = if (data.permission_mode) |mode| std.meta.stringToEnum(types.PermissionMode, mode) orelse .ask else .ask,
            .created_at_ms = data.created_at_ms,
            .turn = data.turn,
        };
        built += 1;
    }
    return out;
}

/// Appends the lines that take `before`'s queue and tombstone to `after`'s:
/// a `queued` line per new item, a cancelled `finished` per item dropped
/// without starting, and `terminated` once. Runs after the child's own
/// finish and spawn lines, so a started item has already left the queue.
pub fn planQueueLines(arena: Allocator, lines: *std.ArrayList(session_adapter.ChildLine), before: ?Child, after: Child) !void {
    const old_queue: []const ActiveWork = if (before) |child| child.queue else &.{};
    const was_terminated = if (before) |child| child.terminated else false;
    if (after.terminated and !was_terminated) {
        try lines.append(arena, .{ .terminated = .{ .child = after.id, .data = "{\"reason\":\"explicit-kill\"}" } });
        return;
    }
    for (old_queue) |work| {
        if (containsWork(after.queue, work.id)) continue;
        if (after.active) |active| if (std.mem.eql(u8, active.id, work.id)) continue;
        try lines.append(arena, .{ .finished = .{ .child = after.id, .work_id = work.id, .outcome = .cancelled } });
    }
    for (after.queue) |work| {
        if (containsWork(old_queue, work.id)) continue;
        const fingerprint = std.fmt.bytesToHex(work.request_fingerprint, .lower);
        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(QueueData{
            .fingerprint = &fingerprint,
            .message = work.message,
            .turn = work.turn,
            .created_at_ms = work.created_at_ms,
            .permission_mode = @tagName(work.permission_mode),
        }, .{}, &out.writer);
        try lines.append(arena, .{ .queued = .{ .child = after.id, .work_id = work.id, .data = out.written() } });
    }
}

fn containsWork(works: []const ActiveWork, id: []const u8) bool {
    for (works) |work| if (std.mem.eql(u8, work.id, id)) return true;
    return false;
}

fn testWork(alloc: Allocator, id: []const u8, turn: u32) !ActiveWork {
    return .{ .id = try alloc.dupe(u8, id), .message = try alloc.dupe(u8, "next step"), .created_at_ms = 5, .turn = turn, .request_fingerprint = @splat(7) };
}

test "a worker's queue and tombstone survive the parent's log (D102)" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const store = parent.stateStore();
    const child_id = "01J00000000000000000000001";
    {
        var registry = try store.load(alloc);
        defer registry.deinit(alloc);
        var first = try testWork(alloc, "op-1", 1);
        defer first.deinit(alloc);
        try registry.appendPersistent(alloc, child_id, "parser", "", first);
        registry.children[0].turns = 1;
        var second = try testWork(alloc, "op-2", 2);
        defer second.deinit(alloc);
        _ = try enqueue(&registry, alloc, child_id, second);
        var third = try testWork(alloc, "op-3", 3);
        defer third.deinit(alloc);
        _ = try enqueue(&registry, alloc, child_id, third);
        try store.save(alloc, registry);
        // The running turn ends and the next starts in one batch.
        try registry.finish(alloc, child_id, "op-1", .completed, null);
        try std.testing.expect(try startQueued(&registry, alloc, child_id) != null);
        try std.testing.expectEqualStrings("op-2", registry.findById(child_id).?.active.?.id);
        try store.save(alloc, registry);
        try registry.finish(alloc, child_id, "op-2", .completed, null);
        try store.save(alloc, registry);
    }
    parent.children.forget();
    {
        var registry = try store.load(alloc);
        defer registry.deinit(alloc);
        const child = registry.findById(child_id).?;
        try std.testing.expectEqual(@as(usize, 1), child.queue.len);
        try std.testing.expectEqualStrings("op-3", child.queue[0].id);
        try std.testing.expectEqualStrings("next step", child.queue[0].message);
        try std.testing.expectEqual(@as(u32, 3), child.turns);
        try std.testing.expect(try cancelQueued(&registry, alloc, child_id, "op-3"));
        try terminate(&registry, alloc, child_id);
        try store.save(alloc, registry);
    }
    parent.children.forget();
    var registry = try store.load(alloc);
    defer registry.deinit(alloc);
    const child = registry.findById(child_id).?;
    try std.testing.expect(child.terminated);
    try std.testing.expectEqual(@as(usize, 0), child.queue.len);
    try std.testing.expectEqual(child_state.Phase.finished, child.phase);
    try std.testing.expect(registry.findPersistent("parser") == null);
    var late = try testWork(alloc, "op-4", 4);
    defer late.deinit(alloc);
    try std.testing.expectError(error.Terminated, enqueue(&registry, alloc, child_id, late));
}
