//! Every agent of one tree, as the logs have them (D186): the root, and
//! each worker below it with its label, parent, place and mailbox size.
//! Read without any node's lock, so a sender anywhere in the tree can
//! address any other agent, as proto's `listVisibleTo` does.
const std = @import("std");
const tool_host = @import("tool_host.zig");
const Allocator = std.mem.Allocator;

pub const root_label = "root";

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    /// The parent's id; null for the root.
    parent: ?[]const u8 = null,
    depth: u8 = 0,
    /// Terminated, or abandoned by a rewind: it takes no more messages.
    terminated: bool = false,
    /// Its parent's log has its work open.
    running: bool = false,
    /// Messages waiting in its mailbox.
    waiting: usize = 0,
    /// Ids from just below the root down to it; empty for the root.
    path: []const []const u8 = &.{},
};

const SpawnData = struct { agent: ?[]const u8 = null };

/// Every agent of `root`'s tree, root first, then breadth first. Workers
/// only: one-off runs are not addressable. Owned by `arena`.
pub fn list(arena: Allocator, root: *tool_host.Runtime) ![]Node {
    const store = root.tree.store;
    const max_depth = root.tree.policy.max_depth;
    var nodes: std.ArrayList(Node) = .empty;
    try nodes.append(arena, .{ .id = root.node_id, .label = root_label });
    var index: usize = 0;
    while (index < nodes.items.len) : (index += 1) {
        const node = nodes.items[index];
        const peeked = store.manager.peek(arena, node.id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A node with no log yet has no mailbox and no children.
            else => continue,
        };
        nodes.items[index].waiting = peeked.state.mailbox.items.len;
        if (node.depth >= max_depth) continue;
        for (peeked.state.children.items) |child| {
            const raw = child.spawn_data orelse continue;
            const spawn = std.json.parseFromSliceLeaky(SpawnData, arena, raw, .{ .ignore_unknown_fields = true }) catch continue;
            const label = spawn.agent orelse continue;
            const path = try arena.alloc([]const u8, node.path.len + 1);
            @memcpy(path[0..node.path.len], node.path);
            path[node.path.len] = child.id;
            try nodes.append(arena, .{
                .id = child.id,
                .label = label,
                .parent = node.id,
                .depth = node.depth + 1,
                .terminated = child.closed(),
                .running = child.open,
                .path = path,
            });
        }
    }
    return nodes.items;
}

pub fn find(nodes: []const Node, id: []const u8) ?Node {
    for (nodes) |node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}

pub fn findLabel(nodes: []const Node, label: []const u8) ?Node {
    for (nodes) |node| if (std.mem.eql(u8, node.label, label)) return node;
    return null;
}

/// The path of node `id` below the root, or null when the tree has no such
/// node. Owned by `arena`.
pub fn pathOf(arena: Allocator, root: *tool_host.Runtime, id: []const u8) !?[]const []const u8 {
    const node = find(try list(arena, root), id) orelse return null;
    return node.path;
}
