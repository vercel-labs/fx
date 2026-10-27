//! A tree of agent sessions (D91). Every agent is a session node: the root
//! at depth 0, each child one deeper. One `Tree` per root host holds what
//! the whole tree shares: the spawn policy, the node budget, the run slots
//! (D92), the approval registry (D93) and the hosts of every node below the
//! root (D96). Node hosts borrow it; the root host owns it.
const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const child_state = @import("child_state.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session_adapter = @import("../session/session_adapter.zig");
const slot_pool = @import("slot_pool.zig");
const node_hosts = @import("node_hosts.zig");
const tool_host = @import("tool_host.zig");
const kernel_pool = @import("../kernel/slot.zig").pool;

const Allocator = std.mem.Allocator;

/// The tool that carries the spawn ability. A node that may not spawn is
/// never offered it.
pub const spawn_tool_name = "fleet";

/// The spawn tool's name before the fleet (D101), still in older sessions'
/// histories.
pub const legacy_spawn_tool_name = "subagent";

/// Whether `name` is the spawn tool, now or as older histories name it.
pub fn isSpawnToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, spawn_tool_name) or std.mem.eql(u8, name, legacy_spawn_tool_name);
}

/// Why a spawn was refused, as the parent's tool result names it.
pub const SpawnRefusal = enum {
    depth_limit,
    child_limit,
    tree_limit,
    permission_escalation,
};

/// The one rule for who may spawn (D91). Nodes sit at depths
/// 0..`max_depth`; one at `max_depth` has no spawn ability.
pub const SpawnPolicy = struct {
    max_depth: u8 = 3,
    max_children_per_node: usize = 64,
    /// Nodes below the root, across every depth.
    max_tree_nodes: usize = child_state.max_children,
    tree_slots: usize = slot_pool.default_tree_slots,

    /// Whether a node at `depth` may have children.
    pub fn canSpawn(policy: SpawnPolicy, depth: u8) bool {
        return depth < policy.max_depth;
    }

    /// Pure: whether a node at `depth` with `children` direct children may
    /// add one more to a tree that already has `tree_nodes` nodes below its
    /// root.
    pub fn admit(policy: SpawnPolicy, depth: u8, children: usize, tree_nodes: usize) ?SpawnRefusal {
        if (!policy.canSpawn(depth)) return .depth_limit;
        if (children >= policy.max_children_per_node) return .child_limit;
        if (tree_nodes >= policy.max_tree_nodes) return .tree_limit;
        return null;
    }
};

/// What a node may do, computed once when its host starts: from its depth
/// alone, so nothing asks later whether it is a child.
pub const Abilities = struct {
    depth: u8,
    can_spawn: bool,

    pub fn at(policy: SpawnPolicy, depth: u8) Abilities {
        return .{ .depth = depth, .can_spawn = policy.canSpawn(depth) };
    }

    /// Whether a tool its parent holds stays in this node's set. Every node
    /// gets a subset of its parent's tools; only the spawn ability depends
    /// on depth.
    pub fn keepsTool(self: Abilities, name: []const u8) bool {
        return self.can_spawn or !std.mem.eql(u8, name, spawn_tool_name);
    }
};

pub const Tree = struct {
    alloc: Allocator,
    policy: SpawnPolicy,
    root_id: []u8,
    /// The root's store, for counting saved nodes.
    store: *session_adapter.Store,
    approvals: approval_registry.Registry,
    slots: slot_pool.Pool,
    process_slots: *slot_pool.Pool = &slot_pool.process_pool,
    mutex: std.Io.Mutex = .init,
    /// Nodes below the root, saved or admitted; counted on first need.
    node_count: ?usize = null,
    /// The root's host, for the tree's life.
    root_host: ?*tool_host.Runtime = null,
    /// The open hosts of the nodes below the root (D96). Viewers read a
    /// node's children and live output through them (`withHost`).
    nodes: node_hosts.Registry,

    /// Caller owns; free with `destroy`.
    pub fn create(alloc: Allocator, root_id: []const u8, store: *session_adapter.Store, policy: SpawnPolicy) !*Tree {
        const tree = try alloc.create(Tree);
        errdefer alloc.destroy(tree);
        tree.* = .{
            .alloc = alloc,
            .policy = policy,
            .root_id = try alloc.dupe(u8, root_id),
            .store = store,
            .approvals = .{ .alloc = alloc },
            .slots = .{ .capacity = policy.tree_slots },
            .nodes = node_hosts.Registry.init(alloc, node_hosts.Limits.fromEnv()),
        };
        return tree;
    }

    /// The root host calls this after joining its own children. Every node
    /// host closes, deepest first, and then no node still uses the kernels
    /// the tree kept for its subagents.
    pub fn destroy(self: *Tree) void {
        self.nodes.closeAll();
        kernel_pool.releaseRetained(self);
        self.approvals.deinit();
        const alloc = self.alloc;
        alloc.free(self.root_id);
        alloc.destroy(self);
    }

    /// Runs `visit(context, host)` on node `id`'s open host, which cannot
    /// close until `visit` returns. Null when the node has no open host.
    /// The root's host stays open for the tree's life.
    pub fn withHost(self: *Tree, id: []const u8, comptime R: type, context: anytype, comptime visit: fn (@TypeOf(context), *tool_host.Runtime) R) ?R {
        if (std.mem.eql(u8, id, self.root_id)) return visit(context, self.root_host orelse return null);
        return self.nodes.visit(id, R, context, visit);
    }

    pub fn permit(self: *Tree) slot_pool.Permit {
        return .{ .tree = &self.slots, .process = self.process_slots };
    }

    /// Admits one new node at `parent_depth + 1` under a parent that has
    /// `children` already, or names why not. The count it checks covers
    /// every node the tree has saved, at every depth.
    pub fn admitNode(self: *Tree, parent_depth: u8, children: usize) !?SpawnRefusal {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const nodes = self.node_count orelse try self.countSaved();
        self.node_count = nodes;
        if (self.policy.admit(parent_depth, children, nodes)) |refusal| return refusal;
        self.node_count = nodes + 1;
        return null;
    }

    /// Walks the saved tree from the root through each node's children,
    /// down to the deepest depth the policy allows.
    fn countSaved(self: *Tree) !usize {
        var frontier: std.ArrayList([]u8) = .empty;
        defer {
            for (frontier.items) |id| self.alloc.free(id);
            frontier.deinit(self.alloc);
        }
        try frontier.append(self.alloc, try self.alloc.dupe(u8, self.root_id));
        var count: usize = 0;
        var depth: u8 = 0;
        while (frontier.items.len > 0 and depth < self.policy.max_depth) : (depth += 1) {
            var next: std.ArrayList([]u8) = .empty;
            errdefer {
                for (next.items) |id| self.alloc.free(id);
                next.deinit(self.alloc);
            }
            for (frontier.items) |id| {
                const ids = self.store.childIds(self.alloc, id) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // A node not saved yet has no children on disk.
                    else => continue,
                };
                defer self.alloc.free(ids);
                count += ids.len;
                errdefer for (ids) |child| self.alloc.free(child);
                try next.appendSlice(self.alloc, ids);
            }
            for (frontier.items) |id| self.alloc.free(id);
            frontier.deinit(self.alloc);
            frontier = next;
        }
        debug_trace.logf("subagent", "tree nodes counted root_id={s} nodes={d}", .{ self.root_id, count });
        return count;
    }
};

test "one spawn policy bounds depth, children per node and the tree" {
    const policy = SpawnPolicy{ .max_depth = 3, .max_children_per_node = 2, .max_tree_nodes = 5 };
    try std.testing.expectEqual(@as(?SpawnRefusal, null), policy.admit(0, 0, 0));
    try std.testing.expectEqual(@as(?SpawnRefusal, null), policy.admit(2, 1, 4));
    // A node at depth 3 would add one at depth 4.
    try std.testing.expectEqual(@as(?SpawnRefusal, .depth_limit), policy.admit(3, 0, 0));
    try std.testing.expectEqual(@as(?SpawnRefusal, .child_limit), policy.admit(1, 2, 0));
    try std.testing.expectEqual(@as(?SpawnRefusal, .tree_limit), policy.admit(1, 0, 5));
    for ([_]u8{ 0, 1, 2 }) |depth| try std.testing.expect(Abilities.at(policy, depth).can_spawn);
    const leaf = Abilities.at(policy, 3);
    try std.testing.expect(!leaf.can_spawn);
    try std.testing.expect(!leaf.keepsTool(spawn_tool_name));
    try std.testing.expect(leaf.keepsTool("read_file"));
}

test "the spawn tool is the built-in subagent tool" {
    try std.testing.expectEqualStrings(@import("../../builtins/tools.zig").fleet.name, spawn_tool_name);
}
