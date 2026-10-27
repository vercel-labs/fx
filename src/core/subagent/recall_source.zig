//! A node host as recall reads it: the tree's session store for every
//! node's turns and place in the tree, and the node's fleet for the worker
//! rows of `agent://`. Nothing here takes a host lock, so a read never waits
//! on a running turn.
const std = @import("std");
const recall = @import("../recall/recall.zig");
const types = @import("../shared/types.zig");
const tool_host = @import("tool_host.zig");
const fleet_host = @import("fleet_host.zig");

const Allocator = std.mem.Allocator;

/// The view of the node `runtime` serves. Borrows the runtime and its tree.
pub fn view(runtime: *tool_host.Runtime) recall.NodeView {
    return .{
        .source = .{ .context = runtime, .vtable = &vtable },
        .cache = &runtime.tree.recall_cache,
        .root_id = runtime.tree.root_id,
        .node_id = runtime.node_id,
    };
}

const vtable: recall.Source.VTable = .{
    .visit_turns = visitTurns,
    .node_info = nodeInfo,
    .child_ids = childIds,
    .inspect_worker = inspectWorker,
};

fn host(context: *anyopaque) *tool_host.Runtime {
    return @ptrCast(@alignCast(context));
}

fn visitTurns(context: *anyopaque, alloc: Allocator, id: []const u8, sink: recall.TurnSink) anyerror!void {
    const Visitor = struct {
        sink: recall.TurnSink,

        pub fn turn(self: *@This(), value: types.HistoryTurn, number: u64) !void {
            try self.sink.turn(value, number);
        }
    };
    var visitor: Visitor = .{ .sink = sink };
    host(context).tree.store.visitTurns(alloc, id, &visitor) catch |err| switch (err) {
        // Not saved yet: no turns.
        error.NotFound, error.InvalidArgument => {},
        else => return err,
    };
}

fn nodeInfo(context: *anyopaque, arena: Allocator, id: []const u8) anyerror!?recall.NodeInfo {
    const info = host(context).tree.store.nodeInfo(arena, id) catch |err| switch (err) {
        error.NotFound, error.InvalidArgument => return null,
        else => return err,
    };
    return .{
        .root = info.root,
        .parent = info.parent,
        .depth = info.depth,
        .version = info.last_seq,
        .turns = info.turns,
        .running = info.running,
    };
}

fn childIds(context: *anyopaque, arena: Allocator, id: []const u8) anyerror![]const []const u8 {
    const ids = host(context).tree.store.childIds(arena, id) catch |err| switch (err) {
        error.NotFound, error.InvalidArgument => return &.{},
        else => return err,
    };
    return ids;
}

fn inspectWorker(context: *anyopaque, arena: Allocator, id: []const u8) anyerror!?[]const u8 {
    return fleet_host.inspectText(host(context), arena, id);
}
