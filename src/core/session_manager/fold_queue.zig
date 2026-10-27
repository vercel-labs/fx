//! A worker's queue in the fold (D102): queued work items, and the view of
//! a child's queue that planning a batch reads.
const std = @import("std");
const fold = @import("fold.zig");
const schema = @import("schema.zig");

const State = fold.State;
const Event = fold.Event;

/// One queued work item of a child (D102). Owns its slices.
pub const Queued = struct {
    work_id: []u8,
    data: ?[]u8 = null,

    pub fn deinit(item: Queued, gpa: std.mem.Allocator) void {
        gpa.free(item.work_id);
        if (item.data) |data| gpa.free(data);
    }

    pub fn clone(item: Queued, gpa: std.mem.Allocator) error{OutOfMemory}!Queued {
        const work_id = try gpa.dupe(u8, item.work_id);
        errdefer gpa.free(work_id);
        return .{ .work_id = work_id, .data = if (item.data) |data| try gpa.dupe(u8, data) else null };
    }
};

/// The most work items one child may have queued (D102).
pub const max_queued_work: usize = 8;

/// A child's queue after `earlier` events of the batch, without copying:
/// the folded queue's tail past `skipped`, then the batch's additions.
pub fn enqueue(gpa: std.mem.Allocator, child: *fold.Child, seq: u64, queued: schema.Body.WorkItem) error{OutOfMemory}!void {
    const work_id = try gpa.dupe(u8, queued.work_id);
    errdefer gpa.free(work_id);
    const data = if (queued.data) |d| try gpa.dupe(u8, d) else null;
    errdefer if (data) |d| gpa.free(d);
    try child.queue.append(gpa, .{ .work_id = work_id, .data = data });
    child.seq = seq;
}

/// Makes the child terminal and drops its queue (D102).
pub fn terminate(gpa: std.mem.Allocator, child: *fold.Child, seq: u64, terminated: schema.Body.Terminated) error{OutOfMemory}!void {
    const data = try gpa.dupe(u8, terminated.data orelse "{}");
    if (child.terminated) |old| gpa.free(old);
    child.terminated = data;
    for (child.queue.items) |item| item.deinit(gpa);
    child.queue.clearRetainingCapacity();
    child.seq = seq;
}

pub const QueueView = struct {
    folded: []const Queued = &.{},
    skipped: usize = 0,
    removed: [max_queued_work][]const u8 = undefined,
    removed_len: usize = 0,
    added: [max_queued_work][]const u8 = undefined,
    added_len: usize = 0,

    pub fn len(view: *QueueView) usize {
        return view.folded.len - view.skipped - view.removed_len + view.added_len;
    }

    fn isRemoved(view: *QueueView, work_id: []const u8) bool {
        for (view.removed[0..view.removed_len]) |id| if (std.mem.eql(u8, id, work_id)) return true;
        return false;
    }

    pub fn front(view: *QueueView) ?[]const u8 {
        for (view.folded[view.skipped..]) |item| if (!view.isRemoved(item.work_id)) return item.work_id;
        return if (view.added_len > 0) view.added[0] else null;
    }

    pub fn contains(view: *QueueView, work_id: []const u8) bool {
        for (view.folded[view.skipped..]) |item| {
            if (std.mem.eql(u8, item.work_id, work_id)) return !view.isRemoved(work_id);
        }
        for (view.added[0..view.added_len]) |id| if (std.mem.eql(u8, id, work_id)) return true;
        return false;
    }

    fn remove(view: *QueueView, work_id: []const u8) void {
        for (view.added[0..view.added_len], 0..) |id, index| {
            if (!std.mem.eql(u8, id, work_id)) continue;
            @memmove(view.added[index .. view.added_len - 1], view.added[index + 1 .. view.added_len]);
            view.added_len -= 1;
            return;
        }
        if (view.removed_len < max_queued_work) {
            view.removed[view.removed_len] = work_id;
            view.removed_len += 1;
        }
    }
};

pub fn queueAt(state: *const State, earlier: []const Event, child: []const u8) QueueView {
    var view: QueueView = .{};
    if (state.findChild(child)) |index| view.folded = state.children.items[index].queue.items;
    for (earlier) |event| switch (event) {
        .child_queued => |c| if (std.mem.eql(u8, c.child, child) and view.added_len < max_queued_work) {
            view.added[view.added_len] = c.work_id;
            view.added_len += 1;
        },
        .child_spawned => |c| if (std.mem.eql(u8, c.child, child) and view.contains(c.work_id)) view.remove(c.work_id),
        .child_finished => |c| if (std.mem.eql(u8, c.child, child) and view.contains(c.work_id)) view.remove(c.work_id),
        .child_terminated => |c| if (std.mem.eql(u8, c.child, child)) {
            view.skipped = view.folded.len;
            view.removed_len = 0;
            view.added_len = 0;
        },
        else => {},
    };
    return view;
}

const testing = std.testing;

fn step(state: *State, seq: *u64, event: Event) !void {
    var one: [1]schema.Body = undefined;
    try fold.plan(state, &.{event}, &one);
    seq.* += 1;
    try fold.apply(testing.allocator, state, 0, .{ .seq = seq.*, .offset = 0, .body = one[0] });
}

test "queued work starts in order, a cancel drops it, and terminate ends the child (D102)" {
    var state: State = .{};
    defer state.deinit(testing.allocator);
    var one: [1]schema.Body = undefined;
    var seq: u64 = 0;
    try step(&state, &seq, .{ .child_spawned = .{ .child = "w", .work_id = "a" } });
    // Only a known child queues, never its open item, and never twice.
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{.{ .child_queued = .{ .child = "x", .work_id = "b" } }}, &one));
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{.{ .child_queued = .{ .child = "w", .work_id = "a" } }}, &one));
    try step(&state, &seq, .{ .child_queued = .{ .child = "w", .work_id = "b", .data = "{\"turn\":2}" } });
    try step(&state, &seq, .{ .child_queued = .{ .child = "w", .work_id = "c" } });
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{.{ .child_queued = .{ .child = "w", .work_id = "b" } }}, &one));
    try testing.expectEqual(@as(usize, 2), state.children.items[0].queue.items.len);
    // The front starts first, in the same batch as the finish before it.
    try step(&state, &seq, .{ .child_finished = .{ .child = "w", .work_id = "a", .outcome = .ok } });
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{.{ .child_spawned = .{ .child = "w", .work_id = "c" } }}, &one));
    var two: [2]schema.Body = undefined;
    try fold.plan(&state, &.{ .{ .child_finished = .{ .child = "w", .work_id = "b", .outcome = .cancelled } }, .{ .child_spawned = .{ .child = "w", .work_id = "c" } } }, &two);
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{.{ .child_finished = .{ .child = "w", .work_id = "b", .outcome = .ok } }}, &one));
    try step(&state, &seq, .{ .child_spawned = .{ .child = "w", .work_id = "b" } });
    try testing.expectEqualStrings("b", state.children.items[0].work_id);
    try step(&state, &seq, .{ .child_finished = .{ .child = "w", .work_id = "c", .outcome = .cancelled } });
    try testing.expectEqual(@as(usize, 0), state.children.items[0].queue.items.len);
    try step(&state, &seq, .{ .child_queued = .{ .child = "w", .work_id = "d" } });
    // Terminal only between work items; then no more work, and no queue.
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{.{ .child_terminated = .{ .child = "w" } }}, &one));
    try step(&state, &seq, .{ .child_finished = .{ .child = "w", .work_id = "b", .outcome = .cancelled } });
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{ .{ .child_terminated = .{ .child = "w" } }, .{ .child_queued = .{ .child = "w", .work_id = "e" } } }, &two));
    try step(&state, &seq, .{ .child_terminated = .{ .child = "w", .data = "{\"reason\":\"explicit-kill\"}" } });
    try testing.expect(state.children.items[0].closed());
    try testing.expectEqual(@as(usize, 0), state.children.items[0].queue.items.len);
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{.{ .child_spawned = .{ .child = "w", .work_id = "d" } }}, &one));
    try testing.expectError(error.InvalidTransition, fold.plan(&state, &.{.{ .child_queued = .{ .child = "w", .work_id = "f" } }}, &one));
    // A snapshot keeps the queue and the tombstone.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try fold.encodeState(testing.allocator, &out, &state);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var decoded = try fold.decodeState(testing.allocator, arena.allocator(), out.items);
    defer decoded.deinit(testing.allocator);
    decoded.last_seq = state.last_seq;
    decoded.clean_exit = state.clean_exit;
    try testing.expect(state.eql(&decoded));
}
