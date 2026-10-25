//! Nested subagents end to end through real hosts, child sessions and
//! threads (D91, D92): every level of the tree runs the same runner, which
//! delegates once more while its turn has a host.
const std = @import("std");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const io_mod = @import("../shared/io.zig");
const model_contract = @import("model_contract.zig");
const node_ops = @import("node_ops.zig");
const session = @import("../session/session.zig");
const session_adapter = @import("../session/session_adapter.zig");
const slot_pool = @import("slot_pool.zig");
const tool_host = @import("tool_host.zig");
const tree_mod = @import("tree.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const max_depth = 3;

const Chain = struct {
    process: slot_pool.Pool = .{ .capacity = 32 },
    mutex: std.Io.Mutex = .init,
    /// Turns doing their own work now, not waiting on a child.
    executing: usize = 0,
    max_executing: usize = 0,
    /// Per depth: the turn ran, and whether it held the spawn tool and a host.
    ran: [max_depth + 2]bool = @splat(false),
    had_spawn_tool: [max_depth + 2]bool = @splat(false),
    had_host: [max_depth + 2]bool = @splat(false),
    recorded_depth: [max_depth + 2]u64 = @splat(0),
    /// Set when the deepest turn starts; it then blocks until cancelled.
    block_leaf: bool = false,
    leaf_entered: std.Io.Event = .unset,
    /// The depth whose turn asks for a wider permission mode than its own.
    escalate_at: ?usize = null,
    escalation_result: ?[]u8 = null,

    fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
        return authority.HostAuthority.capture(alloc, &.{ "read_file", tree_mod.spawn_tool_name }, &.{}, .{}, &.{});
    }

    fn enter(self: *Chain) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.executing += 1;
        self.max_executing = @max(self.max_executing, self.executing);
    }

    fn leave(self: *Chain) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.executing -= 1;
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, admission: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *Chain = @ptrCast(@alignCast(raw.?));
        const depth = turn.node_path.len - 1;
        self.ran[depth] = true;
        self.recorded_depth[depth] = turn.child.node().depth;
        for (admission.tool_names) |tool| {
            if (std.mem.eql(u8, tool, tree_mod.spawn_tool_name)) self.had_spawn_tool[depth] = true;
        }
        self.had_host[depth] = turn.node_host != null;
        if (!turn.worker.beginDirectProcessing(1)) return error.ProviderFailed;
        // As the agent adapter does: the child's turn is open on disk before
        // it spawns, so its own child lines have a log to land in.
        turn.beginTurn() catch return error.ProviderFailed;
        self.enter();
        var entered = true;
        defer if (entered) self.leave();

        var inner: []const u8 = "leaf";
        var inner_owned: ?[]u8 = null;
        defer if (inner_owned) |text| turn.alloc.free(text);
        if (turn.node_host) |node| {
            var request = model_contract.validateRequest(turn.alloc, .{ .run = .{ .task = message.content } }) catch return error.ProviderFailed;
            defer request.deinit(turn.alloc);
            const wider: types.PermissionMode = if (self.escalate_at == depth) .yolo else admission.permission_mode;
            self.leave();
            entered = false;
            const result = node.executeManaged(turn.alloc, &request, .{
                .invocation_id = turn.node_path[turn.node_path.len - 1],
                .parent_permission_mode = wider,
                .defaults = testDefaults(),
                .max_result_bytes = 4096,
                .timestamp_ms = 1,
                .cancel_flag = cancel,
            }) catch |err| return switch (err) {
                error.Cancelled => error.Cancelled,
                error.OutOfMemory => error.OutOfMemory,
                else => error.ProviderFailed,
            };
            self.enter();
            entered = true;
            if (self.escalate_at == depth) self.escalation_result = std.testing.allocator.dupe(u8, result.body) catch null;
            inner_owned = result.body;
            inner = result.body;
        } else if (self.block_leaf) {
            self.leaf_entered.set(io_mod.getIo());
            while (!cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
            return error.Cancelled;
        }
        const text = turn.alloc.print("depth {d}: {s}", .{ depth, inner }) catch return error.OutOfMemory;
        defer turn.alloc.free(text);
        turn.commit(turn.active_work_id.?, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = text,
        } }) catch return error.ProviderFailed;
        return .completed;
    }
};

fn testDefaults() tool_host.Defaults {
    return .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") };
}

fn rootHost(alloc: Allocator, parent: *child_state.TestParent, chain: *Chain, policy: tree_mod.SpawnPolicy) !*tool_host.Runtime {
    const runtime = try tool_host.Runtime.createWithPolicy(alloc, &parent.children, .{ .resolve_fn = Chain.resolve }, .{ .context = chain, .run_fn = Chain.run }, policy);
    runtime.tree.process_slots = &chain.process;
    return runtime;
}

fn delegate(alloc: Allocator, runtime: *tool_host.Runtime, invocation_id: []const u8, options: struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    mode: types.PermissionMode = .yolo,
}) !tool_host.ManagedExecutionResult {
    var request = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "go one level deeper" } });
    defer request.deinit(alloc);
    return runtime.executeManaged(alloc, &request, .{
        .invocation_id = invocation_id,
        .parent_permission_mode = options.mode,
        .defaults = testDefaults(),
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .cancel_flag = options.cancel_flag,
    });
}

test "a root delegates to a child that delegates down to depth 3, where the spawn tool ends" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var chain = Chain{};
    const runtime = try rootHost(alloc, &parent, &chain, .{});
    defer runtime.deinit();

    const result = try delegate(alloc, runtime, "nested-chain", .{});
    defer alloc.free(result.body);
    try std.testing.expect(result.success);
    for ([_][]const u8{ "depth 1:", "depth 2:", "depth 3: leaf" }) |needle| {
        try std.testing.expect(std.mem.find(u8, result.body, needle) != null);
    }
    for (1..max_depth + 1) |depth| {
        try std.testing.expect(chain.ran[depth]);
        // Each child records its depth on line 1 (D91).
        try std.testing.expectEqual(@as(u64, depth), chain.recorded_depth[depth]);
        // Only depths below the limit hold the spawn tool and a host.
        try std.testing.expectEqual(depth < max_depth, chain.had_spawn_tool[depth]);
        try std.testing.expectEqual(depth < max_depth, chain.had_host[depth]);
    }
    try std.testing.expect(!chain.ran[max_depth + 1]);
    // Every descendant was joined before the root's call returned.
    try std.testing.expect(!runtime.subtreeBusy());
    try std.testing.expectEqual(@as(usize, 0), runtime.managed.slots.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.tree.slots.inUse());
    try std.testing.expectEqual(@as(usize, 0), chain.process.inUse());
}

test "a node at the depth limit is refused a child by the spawn policy" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var chain = Chain{};
    // A root at depth 0 under a limit of 0 stands where a depth-3 node does
    // under the default: it may not add a node one deeper.
    const runtime = try rootHost(alloc, &parent, &chain, .{ .max_depth = 0 });
    defer runtime.deinit();
    const result = try delegate(alloc, runtime, "past-the-limit", .{});
    defer alloc.free(result.body);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.find(u8, result.body, "\"error_code\":\"depth_limit\"") != null);
    try std.testing.expect(!chain.ran[1]);
}

test "the tree budget counts nodes at every depth, also after a reopen" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var chain = Chain{};
    {
        // A chain of three nodes fills a budget of three.
        const runtime = try rootHost(alloc, &parent, &chain, .{ .max_tree_nodes = 3 });
        defer runtime.deinit();
        const first = try delegate(alloc, runtime, "fills-budget", .{});
        defer alloc.free(first.body);
        try std.testing.expect(first.success);
        const second = try delegate(alloc, runtime, "over-budget", .{});
        defer alloc.free(second.body);
        try std.testing.expect(std.mem.find(u8, second.body, "\"error_code\":\"tree_limit\"") != null);
    }
    // A new host counts what the tree saved, grandchildren included.
    var reopened = child_state.V2Children.init(alloc, parent.parent, parent.home);
    defer reopened.deinit();
    const runtime = try tool_host.Runtime.createWithPolicy(alloc, &reopened, .{ .resolve_fn = Chain.resolve }, .{ .context = &chain, .run_fn = Chain.run }, .{ .max_tree_nodes = 4 });
    defer runtime.deinit();
    runtime.tree.process_slots = &chain.process;
    try std.testing.expectEqual(@as(?tree_mod.SpawnRefusal, null), try runtime.tree.admitNode(0, 1));
    try std.testing.expectEqual(@as(?tree_mod.SpawnRefusal, .tree_limit), try runtime.tree.admitNode(0, 1));
}

test "one run slot carries a chain to depth 3 because waiting parents lend theirs" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var chain = Chain{ .process = .{ .capacity = 1 } };
    const runtime = try rootHost(alloc, &parent, &chain, .{ .tree_slots = 1 });
    defer runtime.deinit();
    const result = try delegate(alloc, runtime, "one-slot", .{});
    defer alloc.free(result.body);
    try std.testing.expect(result.success);
    try std.testing.expect(chain.ran[max_depth]);
    // Never more than one turn worked at a time, and every slot came back.
    try std.testing.expectEqual(@as(usize, 1), chain.max_executing);
    try std.testing.expectEqual(@as(usize, 0), runtime.tree.slots.inUse());
    try std.testing.expectEqual(@as(usize, 0), chain.process.inUse());
}

test "cancelling the root's call cancels every level, deepest first" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var chain = Chain{ .block_leaf = true };
    const runtime = try rootHost(alloc, &parent, &chain, .{});
    defer runtime.deinit();
    const Call = struct {
        runtime: *tool_host.Runtime,
        cancel: std.atomic.Value(bool) = .init(false),
        outcome: ?anyerror = null,
        fn run(self: *@This()) void {
            const result = delegate(std.testing.allocator, self.runtime, "cancel-chain", .{ .cancel_flag = &self.cancel }) catch |err| {
                self.outcome = err;
                return;
            };
            std.testing.allocator.free(result.body);
        }
    };
    var call = Call{ .runtime = runtime };
    const thread = try std.Thread.spawn(.{}, Call.run, .{&call});
    var joined = false;
    defer if (!joined) {
        call.cancel.store(true, .seq_cst);
        thread.join();
    };
    try chain.leaf_entered.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } });
    // While the leaf runs, every ancestor's turn is still open.
    try std.testing.expect(runtime.subtreeBusy());
    call.cancel.store(true, .seq_cst);
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), call.outcome);
    try std.testing.expect(!runtime.subtreeBusy());
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), registry.children.len);
    try std.testing.expectEqual(child_state.Outcome.cancelled, registry.children[0].last_outcome.?);
    // Each level below saved its child's work as cancelled in its own log.
    var node_id = try alloc.dupe(u8, registry.children[0].id);
    defer alloc.free(node_id);
    for (1..max_depth) |_| {
        var peeked = try parent.store.manager.peek(alloc, node_id);
        defer peeked.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), peeked.state.children.items.len);
        const below = peeked.state.children.items[0];
        try std.testing.expectEqual(session_adapter.ChildOutcome.cancelled, below.outcome.?);
        alloc.free(node_id);
        node_id = try alloc.dupe(u8, below.id);
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.tree.slots.inUse());
}

test "a child cannot hand its own child a wider permission mode" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var chain = Chain{ .escalate_at = 1 };
    defer if (chain.escalation_result) |body| alloc.free(body);
    const runtime = try rootHost(alloc, &parent, &chain, .{});
    defer runtime.deinit();
    const result = try delegate(alloc, runtime, "narrow-root", .{ .mode = .ask });
    defer alloc.free(result.body);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.find(u8, chain.escalation_result.?, "\"error_code\":\"permission_escalation\"") != null);
    try std.testing.expect(!chain.ran[2]);
}

test "a long child result reaches its parent capped, with a handle to the rest" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const Long = struct {
        fn run(_: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
            const text = turn.alloc.alloc(u8, tool_host.max_inline_result_bytes * 3) catch return error.OutOfMemory;
            defer turn.alloc.free(text);
            @memset(text, 'x');
            turn.commit(turn.active_work_id.?, .{ .assistant = .{ .user = .{ .text = message.content }, .assistant = text } }) catch return error.ProviderFailed;
            return .completed;
        }
    };
    var chain = Chain{};
    const runtime = try tool_host.Runtime.create(alloc, &parent.children, .{ .resolve_fn = Chain.resolve }, .{ .run_fn = Long.run });
    defer runtime.deinit();
    runtime.tree.process_slots = &chain.process;
    const result = try delegate(alloc, runtime, "long-result", .{});
    defer alloc.free(result.body);
    try std.testing.expect(result.success);
    try std.testing.expect(result.body.len < tool_host.max_inline_result_bytes + 512);
    try std.testing.expect(std.mem.find(u8, result.body, "read_tool_result") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "result-") != null);
}

/// A chain of named subagents: the node at depth d messages `n{d+1}` until
/// `deepest`, and each reply names the node's turn count so far.
const Named = struct {
    process: slot_pool.Pool = .{ .capacity = 32 },
    deepest: usize = 2,
    /// Whether the deepest node's next turn spawns a one-off child.
    leaf_spawns: bool = false,

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, admission: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *Named = @ptrCast(@alignCast(raw.?));
        const depth = turn.node_path.len - 1;
        if (!turn.worker.beginDirectProcessing(1)) return error.ProviderFailed;
        turn.beginTurn() catch return error.ProviderFailed;
        var inner: ?[]u8 = null;
        defer if (inner) |text| turn.alloc.free(text);
        const spawn_below = depth < self.deepest or (self.leaf_spawns and depth == self.deepest);
        if (spawn_below) if (turn.node_host) |node| {
            const agent = turn.alloc.print("n{d}", .{depth + 1}) catch return error.OutOfMemory;
            defer turn.alloc.free(agent);
            var request = (if (depth < self.deepest)
                model_contract.validateRequest(turn.alloc, .{ .message = .{ .agent = agent, .message = message.content } })
            else
                model_contract.validateRequest(turn.alloc, .{ .run = .{ .task = "late work" } })) catch return error.ProviderFailed;
            defer request.deinit(turn.alloc);
            const invocation = turn.alloc.print("{s}-{d}", .{ turn.active_work_id.?, depth }) catch return error.OutOfMemory;
            defer turn.alloc.free(invocation);
            const result = node.executeManaged(turn.alloc, &request, .{
                .invocation_id = invocation,
                .parent_permission_mode = admission.permission_mode,
                .defaults = testDefaults(),
                .max_result_bytes = 4096,
                .timestamp_ms = 1,
                .cancel_flag = cancel,
            }) catch return error.ProviderFailed;
            inner = result.body;
        };
        const text = turn.alloc.print("depth {d} turn {d}: {s}", .{ depth, turn.runtime.agent.history.items.len + 1, inner orelse "leaf" }) catch return error.OutOfMemory;
        defer turn.alloc.free(text);
        turn.commit(turn.active_work_id.?, .{ .assistant = .{ .user = .{ .text = message.content }, .assistant = text } }) catch return error.ProviderFailed;
        return .completed;
    }
};

fn namedHost(alloc: Allocator, parent: *child_state.TestParent, named: *Named) !*tool_host.Runtime {
    const runtime = try tool_host.Runtime.create(alloc, &parent.children, .{ .resolve_fn = Chain.resolve }, .{ .context = named, .run_fn = Named.run });
    runtime.tree.process_slots = &named.process;
    return runtime;
}

/// The root's message to `n1`, as the root's subagent tool sends it.
fn messageFrom(alloc: Allocator, host: *tool_host.Runtime, agent: []const u8, text: []const u8, invocation_id: []const u8) !tool_host.ManagedExecutionResult {
    var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = agent, .message = text } });
    defer request.deinit(alloc);
    return host.executeManaged(alloc, &request, .{
        .invocation_id = invocation_id,
        .parent_permission_mode = .yolo,
        .defaults = testDefaults(),
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        // As a person's message from the frontend: no turn's slots to lend.
        .lend_turn_slots = host.depth == 0,
    });
}

/// The id of `host`'s named child `agent`.
fn childNamed(alloc: Allocator, host: *tool_host.Runtime, agent: []const u8) ![]u8 {
    var lock = host.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try host.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    return alloc.dupe(u8, (registry.findPersistent(agent) orelse return error.TestExpectedChild).id);
}

test "a node's host outlives its parent's turn, and a depth-2 node takes a message after it" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var named = Named{};
    const runtime = try namedHost(alloc, &parent, &named);
    defer runtime.deinit();
    const first = try messageFrom(alloc, runtime, "n1", "start", "root-1");
    defer alloc.free(first.body);
    try std.testing.expect(first.success);
    try std.testing.expect(std.mem.find(u8, first.body, "depth 2 turn 1") != null);
    // Every node that ran keeps its host after its turn: depth 1 and 2.
    try std.testing.expectEqual(@as(usize, 2), runtime.tree.nodes.openCount());
    try std.testing.expect(!runtime.subtreeBusy());

    // A person messages n2 through n1's host while n1 runs no turn.
    const n1 = try childNamed(alloc, runtime, "n1");
    defer alloc.free(n1);
    const n1_host = try node_ops.lease(runtime, &.{n1});
    const second = messageFrom(alloc, n1_host.runtime, "n2", "follow up", "frontend-1");
    node_ops.release(runtime, n1_host);
    const reply = try second;
    defer alloc.free(reply.body);
    try std.testing.expect(reply.success);
    try std.testing.expect(std.mem.find(u8, reply.body, "depth 2 turn 2") != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.tree.slots.inUse());
}

test "idle node hosts close leaves first under the TTL and the cap, and reopen on demand" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var named = Named{};
    const runtime = try namedHost(alloc, &parent, &named);
    defer runtime.deinit();
    runtime.tree.nodes.limits = .{ .idle_ms = 60 * 60 * 1000, .max_open = 8 };
    const first = try messageFrom(alloc, runtime, "n1", "start", "root-1");
    defer alloc.free(first.body);
    try std.testing.expectEqual(@as(usize, 2), runtime.tree.nodes.openCount());
    // Not idle long enough: nothing closes.
    runtime.tree.nodes.sweep(io_mod.monotonicMilliTimestamp());
    try std.testing.expectEqual(@as(usize, 2), runtime.tree.nodes.openCount());
    // Past the TTL only the leaf closes: n1's host is held open by n2's.
    const later = io_mod.monotonicMilliTimestamp() + 2 * 60 * 60 * 1000;
    runtime.tree.nodes.sweep(later);
    try std.testing.expectEqual(@as(usize, 1), runtime.tree.nodes.openCount());
    runtime.tree.nodes.sweep(later);
    try std.testing.expectEqual(@as(usize, 0), runtime.tree.nodes.openCount());
    // The next message reopens both from their logs, which kept every turn.
    const second = try messageFrom(alloc, runtime, "n1", "again", "root-2");
    defer alloc.free(second.body);
    try std.testing.expect(std.mem.find(u8, second.body, "depth 1 turn 2") != null);
    try std.testing.expect(std.mem.find(u8, second.body, "depth 2 turn 2") != null);
    // Over the cap, the least recently used idle host closes at once.
    runtime.tree.nodes.limits.max_open = 1;
    runtime.tree.nodes.sweep(io_mod.monotonicMilliTimestamp());
    try std.testing.expectEqual(@as(usize, 1), runtime.tree.nodes.openCount());
    try std.testing.expect(runtime.tree.nodes.closed_total >= 3);
}

test "a rewind of a child drops its newest turn and abandons the children that turn spawned" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var named = Named{ .deepest = 1 };
    const runtime = try namedHost(alloc, &parent, &named);
    defer runtime.deinit();
    const first = try messageFrom(alloc, runtime, "n1", "start", "root-1");
    defer alloc.free(first.body);
    // Its second turn spawns a one-off child.
    named.leaf_spawns = true;
    const second = try messageFrom(alloc, runtime, "n1", "spawn one", "root-2");
    defer alloc.free(second.body);
    try std.testing.expect(second.success);
    const n1 = try childNamed(alloc, runtime, "n1");
    defer alloc.free(n1);
    const outcome = try node_ops.rewindLatest(alloc, runtime, &.{n1});
    defer if (outcome == .rewound) alloc.free(outcome.rewound.prompt);
    try std.testing.expectEqualStrings("spawn one", outcome.rewound.prompt);
    try std.testing.expectEqual(@as(usize, 1), outcome.rewound.abandoned);
    var peeked = try parent.store.manager.peek(alloc, n1);
    defer peeked.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), peeked.state.children.items.len);
    try std.testing.expect(peeked.state.children.items[0].abandoned);
    const history = try parent.store.childHistory(alloc, n1);
    defer types.freeHistoryTurnSlice(alloc, history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    // The root's record of n1's work stays as it was.
    var lock = runtime.managed.state_store.acquireLock();
    var registry = try runtime.managed.state_store.load(alloc);
    lock.release();
    defer registry.deinit(alloc);
    try std.testing.expectEqual(child_state.Outcome.completed, registry.findById(n1).?.last_outcome.?);
    // The node goes on from what the rewind kept.
    named.leaf_spawns = false;
    const third = try messageFrom(alloc, runtime, "n1", "after", "root-3");
    defer alloc.free(third.body);
    try std.testing.expect(std.mem.find(u8, third.body, "depth 1 turn 2") != null);
}

test "a node is not rewound while a node below it runs" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var named = Named{};
    const runtime = try namedHost(alloc, &parent, &named);
    defer runtime.deinit();
    const first = try messageFrom(alloc, runtime, "n1", "start", "root-1");
    defer alloc.free(first.body);
    const n1 = try childNamed(alloc, runtime, "n1");
    defer alloc.free(n1);
    const n1_host = try node_ops.lease(runtime, &.{n1});
    defer node_ops.release(runtime, n1_host);
    // n2's turn holds its host as a running turn would.
    const n2 = try childNamed(alloc, n1_host.runtime, "n2");
    defer alloc.free(n2);
    const n2_host = try runtime.tree.nodes.lease(n1_host.runtime, n2, .turn, "");
    const refused = try node_ops.rewindLatest(alloc, runtime, &.{n1});
    try std.testing.expectEqual(node_ops.RewindOutcome{ .refused = .busy }, refused);
    runtime.tree.nodes.release(n2_host, .turn);
    const allowed = try node_ops.rewindLatest(alloc, runtime, &.{n1});
    defer if (allowed == .rewound) alloc.free(allowed.rewound.prompt);
    try std.testing.expect(allowed == .rewound);
}

test "a fork of a depth-2 node is a new root with the node's history, its origin, and no children" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var named = Named{};
    const runtime = try namedHost(alloc, &parent, &named);
    defer runtime.deinit();
    // n2 spawns a child of its own, which the fork must not carry.
    named.leaf_spawns = true;
    const first = try messageFrom(alloc, runtime, "n1", "start", "root-1");
    defer alloc.free(first.body);
    const n1 = try childNamed(alloc, runtime, "n1");
    defer alloc.free(n1);
    const n1_host = try node_ops.lease(runtime, &.{n1});
    const n2 = childNamed(alloc, n1_host.runtime, "n2");
    node_ops.release(runtime, n1_host);
    const n2_id = try n2;
    defer alloc.free(n2_id);
    const source_lines = blk: {
        var page = try parent.store.manager.read(alloc, n2_id, .start, .forward, 1000);
        defer page.deinit();
        break :blk page.entries.len;
    };

    const outcome = try node_ops.forkLatest(alloc, runtime, &.{ n1, n2_id }, parent.home, "root › n1 › n2");
    const fork_id = outcome.forked.session_id;
    defer alloc.free(fork_id);
    var peeked = try parent.store.manager.peek(alloc, fork_id);
    defer peeked.deinit(alloc);
    // A root of its own: no parent, depth 0, its own tree, no children.
    try std.testing.expect(peeked.parent == null);
    try std.testing.expectEqual(@as(u64, 0), peeked.depth);
    try std.testing.expectEqualStrings(fork_id, peeked.root);
    try std.testing.expectEqual(@as(usize, 0), peeked.state.children.items.len);
    // Line 1 names where it came from.
    var page = try parent.store.manager.read(alloc, fork_id, .start, .forward, 1);
    defer page.deinit();
    const created = page.entries[0].body.?.session_created;
    try std.testing.expectEqualStrings(n2_id, created.forked_from.?.id);
    try std.testing.expectEqualStrings(parent.parent.id(), created.forked_node.?.root);
    const title = try std.json.parseFromSlice([]const u8, alloc, peeked.state.title.?, .{});
    defer title.deinit();
    try std.testing.expectEqualStrings("forked from root › n1 › n2 · turn 1", title.value);
    // Its transcript is the node's, mission first.
    const forked = try parent.store.childHistory(alloc, fork_id);
    defer types.freeHistoryTurnSlice(alloc, forked);
    try std.testing.expectEqual(@as(usize, 1), forked.len);
    try std.testing.expectEqualStrings("start", forked[0].assistant.user.text);
    // The source tree is as it was.
    var after = try parent.store.manager.read(alloc, n2_id, .start, .forward, 1000);
    defer after.deinit();
    try std.testing.expectEqual(source_lines, after.entries.len);
    var source = try parent.store.manager.peek(alloc, n2_id);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), source.state.children.items.len);
    try std.testing.expectEqualStrings(n1, source.parent.?);
}
