//! What a frontend does to a node anywhere in a tree, outside that node's
//! own turns: reach its host through its ancestors' (D96), rewind it (D97),
//! and fork it into a new root session (D98). Every path here names node ids from just below the root down to
//! the target.
const std = @import("std");
const child_state = @import("child_state.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const node_hosts = @import("node_hosts.zig");
const session_adapter = @import("../session/session_adapter.zig");
const tool_host = @import("tool_host.zig");
const Allocator = std.mem.Allocator;

/// Leases the host of the last node of `path`, opening each ancestor's
/// host on the way. Each open host holds its parent's, so one lease on the
/// target keeps the whole chain open. Release with `release`.
pub fn lease(root: *tool_host.Runtime, path: []const []const u8) node_hosts.LeaseError!*node_hosts.Entry {
    std.debug.assert(path.len > 0);
    var parent = root;
    var held: ?*node_hosts.Entry = null;
    for (path) |id| {
        const entry = root.tree.nodes.lease(parent, id, .use, "") catch |err| {
            if (held) |above| root.tree.nodes.release(above, .use);
            return err;
        };
        if (held) |above| root.tree.nodes.release(above, .use);
        held = entry;
        parent = entry.runtime;
    }
    return held.?;
}

pub fn release(root: *tool_host.Runtime, entry: *node_hosts.Entry) void {
    root.tree.nodes.release(entry, .use);
}

/// Why a node was not rewound.
pub const RewindRefusal = enum {
    /// The node, or a node below it, runs or waits for an approval.
    busy,
    /// The node's history holds no turn.
    nothing_to_rewind,
    /// A compaction summarized the turn; dropping it would drop the
    /// summary of turns before it too.
    past_compaction,
};

pub const Rewound = struct {
    /// The dropped turn's prompt, owned.
    prompt: []u8,
    /// How many of the node's children it abandoned.
    abandoned: usize,
};

pub const RewindOutcome = union(enum) {
    rewound: Rewound,
    refused: RewindRefusal,
};

/// Drops the newest turn of the node `path` ends at, and abandons the
/// children that turn spawned (D97). Refused while the node or any node
/// below it runs: the node's parent admits no turn of it, the node admits
/// no child, and no host at or below it is leased until the rewind is
/// written (`tests/tla/session_manager/Rewind.tla` NoRewindWhileBusy). The
/// parent's record of the node's earlier work stays as it is. Caller owns
/// the prompt.
pub fn rewindLatest(alloc: Allocator, root: *tool_host.Runtime, path: []const []const u8) !RewindOutcome {
    const id = path[path.len - 1];
    const above: ?*node_hosts.Entry = if (path.len > 1) lease(root, path[0 .. path.len - 1]) catch |err| return switch (err) {
        error.NodeBusy => .{ .refused = .busy },
        else => err,
    } else null;
    defer if (above) |entry| release(root, entry);
    const parent = if (above) |entry| entry.runtime else root;
    parent.admission_mutex.lockUncancelable(io_mod.getIo());
    defer parent.admission_mutex.unlock(io_mod.getIo());
    {
        const store = child_state.Store{ .children = parent.children, .parent_id = parent.node_id };
        var lock = store.acquireLock();
        defer lock.release();
        var registry = try store.load(alloc);
        defer registry.deinit(alloc);
        const child = registry.findById(id) orelse return error.NodeUnavailable;
        switch (child.phase) {
            .running, .awaiting_approval => return .{ .refused = .busy },
            else => {},
        }
    }
    const entry = root.tree.nodes.lease(parent, id, .use, "") catch |err| return switch (err) {
        error.NodeBusy => .{ .refused = .busy },
        else => err,
    };
    defer root.tree.nodes.release(entry, .use);
    entry.runtime.admission_mutex.lockUncancelable(io_mod.getIo());
    defer entry.runtime.admission_mutex.unlock(io_mod.getIo());
    if (!root.tree.nodes.freeze(id)) return .{ .refused = .busy };
    defer root.tree.nodes.thaw();

    const points = try entry.session.forkPoints(alloc);
    defer session_adapter.Session.freeForkPoints(alloc, points);
    if (points.len == 0) return .{ .refused = .nothing_to_rewind };
    const newest = points[points.len - 1];
    var rewound = entry.session.rewind(alloc, newest.turn) catch |err| return switch (err) {
        error.RewindPastCompaction => .{ .refused = .past_compaction },
        else => err,
    };
    defer rewound.deinit(alloc);
    // Its abandoned children leave the node's registry: their names are
    // free again for its next turns.
    entry.children.forget();
    debug_trace.logf("subagent", "node rewound node_id={s} turn={d} abandoned={d}", .{ id, newest.turn, rewound.abandoned.len });
    return .{ .rewound = .{ .prompt = try alloc.dupe(u8, newest.prompt), .abandoned = rewound.abandoned.len } };
}

pub const Forked = struct {
    /// The new root session's id, owned.
    session_id: []u8,
    /// How many of the node's turns it holds.
    turns: usize,
};

pub const ForkOutcome = union(enum) {
    forked: Forked,
    refused: enum { busy, nothing_to_fork },
};

/// Forks the node `path` ends at into a new root session holding its whole
/// history, as `/fork` forks a root (D58, D98): the session manager copies
/// the node's log through its newest kept turn and hard-links its blobs,
/// and the copy owns none of the node's children. The fork's line 1 names
/// the source tree and turn, and its title names `trail`, the node's path
/// as a person reads it. The source tree is not changed. Refused while a
/// turn of the node runs. Caller owns the id.
pub fn forkLatest(alloc: Allocator, root: *tool_host.Runtime, path: []const []const u8, workspace: []const u8, trail: []const u8) !ForkOutcome {
    const entry = lease(root, path) catch |err| return switch (err) {
        error.NodeBusy => .{ .refused = .busy },
        else => err,
    };
    defer release(root, entry);
    if (entry.turn) return .{ .refused = .busy };
    const points = try entry.session.forkPoints(alloc);
    defer session_adapter.Session.freeForkPoints(alloc, points);
    if (points.len == 0) return .{ .refused = .nothing_to_fork };
    const newest = points[points.len - 1].turn;
    const copy = try entry.session.fork(alloc, .{
        .before_turn = newest + 1,
        .workspace = workspace,
        .host = .acp,
        .node = .{ .root = root.tree.root_id, .turn = newest },
    });
    defer copy.close();
    const title = try alloc.print("forked from {s} · turn {d}", .{ trail, points.len });
    defer alloc.free(title);
    try copy.rename(title);
    debug_trace.logf("subagent", "node forked node_id={s} turn={d} fork={s}", .{ path[path.len - 1], newest, copy.id() });
    return .{ .forked = .{ .session_id = try alloc.dupe(u8, copy.id()), .turns = points.len } };
}
