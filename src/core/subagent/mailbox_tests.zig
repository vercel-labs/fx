//! Messages between a tree's agents end to end through real hosts, child
//! sessions and worker threads (D185 to D189): every message reaches its
//! recipient's model exactly once, as a wake turn its parent owns, a steer
//! into a running turn, or the root's notice, and survives a restart.
const std = @import("std");
const agent_message = @import("agent_message.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const io_mod = @import("../shared/io.zig");
const mailbox = @import("mailbox.zig");
const model_contract = @import("model_contract.zig");
const node_ops = @import("node_ops.zig");
const session = @import("../session/session.zig");
const session_adapter = @import("../session/session_adapter.zig");
const slot_pool = @import("slot_pool.zig");
const tool_host = @import("tool_host.zig");
const tree_mod = @import("tree.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Every turn a worker runs: what reached its model, by node.
const Mailroom = struct {
    mutex: std.Io.Mutex = .init,
    seen: std.ArrayList(Seen) = .empty,
    turns: usize = 0,
    /// While set, a turn whose message starts with "hold" stays running
    /// and takes steering at its boundaries.
    hold: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(u32) = .init(0),
    /// A turn whose message starts with "broadcast" sends one message to
    /// every other agent.
    broadcasts: std.atomic.Value(u32) = .init(0),
    /// A broadcasting turn waits for this, so every agent exists first.
    gate: std.atomic.Value(bool) = .init(true),
    process: slot_pool.Pool = .{ .capacity = 64 },

    const Seen = struct { node: []u8, text: []u8, steered: bool = false, at: i64 = 0 };

    fn deinit(self: *Mailroom) void {
        for (self.seen.items) |item| {
            testing.allocator.free(item.node);
            testing.allocator.free(item.text);
        }
        self.seen.deinit(testing.allocator);
    }

    fn note(self: *Mailroom, node: []const u8, text: []const u8) void {
        self.noteKind(node, text, false);
    }

    fn noteKind(self: *Mailroom, node: []const u8, text: []const u8, steered: bool) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const owned_node = testing.allocator.dupe(u8, node) catch return;
        const owned_text = testing.allocator.dupe(u8, text) catch {
            testing.allocator.free(owned_node);
            return;
        };
        self.seen.append(testing.allocator, .{ .node = owned_node, .text = owned_text, .steered = steered, .at = io_mod.milliTimestamp() }) catch {
            testing.allocator.free(owned_node);
            testing.allocator.free(owned_text);
        };
    }

    /// How many times message `id` reached `node`'s model.
    fn received(self: *Mailroom, node: []const u8, id: []const u8) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var count: usize = 0;
        for (self.seen.items) |item| {
            if (std.mem.eql(u8, item.node, node) and agent_message.carries(item.text, id)) count += 1;
        }
        return count;
    }

    fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
        return authority.HostAuthority.capture(alloc, &.{ "read_file", tree_mod.spawn_tool_name }, &.{}, .{}, &.{});
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *Mailroom = @ptrCast(@alignCast(raw.?));
        const node = turn.node_path[turn.node_path.len - 1];
        if (!turn.worker.beginDirectProcessing(1)) return error.ProviderFailed;
        turn.beginTurn() catch return error.ProviderFailed;
        self.note(node, message.content);
        if (std.mem.startsWith(u8, message.content, "broadcast")) if (turn.node_host) |own| {
            while (!self.gate.load(.seq_cst) and !cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
            var scratch = std.heap.ArenaAllocator.init(turn.alloc);
            defer scratch.deinit();
            const body = scratch.allocator().print("hello from {s}", .{node}) catch return error.OutOfMemory;
            const receipts = mailbox.send(own, scratch.allocator(), .{ .to = "all", .body = body }) catch return error.ProviderFailed;
            for (receipts) |r| if (r.outcome == .rejected) std.debug.print("rejected {s} -> {s}: {s}\n", .{ node, r.to, r.@"error" orelse "" });
            _ = self.broadcasts.fetchAdd(1, .seq_cst);
        };
        var steering: std.ArrayList(types.PersistedSteering) = .empty;
        defer steering.deinit(turn.alloc);
        var arena_state = std.heap.ArenaAllocator.init(turn.alloc);
        defer arena_state.deinit();
        if (std.mem.startsWith(u8, message.content, "hold")) {
            _ = self.held.fetchAdd(1, .seq_cst);
            while (self.hold.load(.seq_cst) and !cancel.load(.seq_cst)) {
                switch (turn.worker.takeSteeringBoundaryInto(turn.alloc, arena_state.allocator(), 1, .model) catch return error.OutOfMemory) {
                    .continue_turn => |texts| for (texts) |text| {
                        self.note(node, text);
                        steering.append(turn.alloc, .{ .text = text, .after_tool_step_count = 0 }) catch return error.OutOfMemory;
                    },
                    else => {},
                }
                io_mod.sleep(std.time.ns_per_ms);
            }
        }
        // The last boundary: steering that arrived as the turn ended.
        switch (turn.worker.takeSteeringBoundaryInto(turn.alloc, arena_state.allocator(), 1, .finalizing) catch return error.OutOfMemory) {
            .continue_turn => |texts| for (texts) |text| {
                self.noteKind(node, text, true);
                steering.append(turn.alloc, .{ .text = text, .after_tool_step_count = 0 }) catch return error.OutOfMemory;
            },
            else => {},
        }
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            self.turns += 1;
        }
        turn.commit(turn.active_work_id.?, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = @constCast("done"),
            .execution = .{ .steering = steering.items },
        } }) catch return error.ProviderFailed;
        return .completed;
    }
};

fn testDefaults() tool_host.Defaults {
    return .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") };
}

fn rootHost(parent: *child_state.TestParent, room: *Mailroom) !*tool_host.Runtime {
    const runtime = try tool_host.Runtime.createWithPolicy(testing.allocator, &parent.children, .{ .resolve_fn = Mailroom.resolve }, .{ .context = room, .run_fn = Mailroom.run }, .{ .max_depth = 3, .max_children_per_node = 32, .max_tree_nodes = 64, .tree_slots = 4 });
    runtime.tree.process_slots = &room.process;
    return runtime;
}

/// Spawns worker `label` with `message` and returns its id.
fn spawn(arena: Allocator, host: *tool_host.Runtime, label: []const u8, message: []const u8) ![]const u8 {
    var request = try model_contract.validateRequest(testing.allocator, .{ .spawn = .{ .message = message, .label = label } });
    defer request.deinit(testing.allocator);
    const result = try host.executeManaged(testing.allocator, &request, .{
        .invocation_id = label,
        .defaults = testDefaults(),
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
    });
    defer testing.allocator.free(result.body);
    try testing.expect(result.success);
    const parsed = try std.json.parseFromSliceLeaky(struct { worker: []const u8 }, arena, result.body, .{ .ignore_unknown_fields = true });
    return arena.dupe(u8, parsed.worker);
}

/// Waits until every turn of `host`'s workers settled.
fn settle(host: *tool_host.Runtime) !void {
    var waited: usize = 0;
    while (waited < 4000) : (waited += 1) {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var busy = false;
        for (try host.fleet.snapshot(arena_state.allocator())) |job| {
            if (!job.state.settled()) busy = true;
        }
        if (!busy and !host.managed.anyRunning()) return;
        io_mod.sleep(2 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn one(receipts: []const mailbox.Receipt) mailbox.Receipt {
    std.debug.assert(receipts.len == 1);
    return receipts[0];
}

test "agents of one tree message each other, their parent and all, each message once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(testing.allocator);
    defer parent.deinit();
    var room: Mailroom = .{};
    defer room.deinit();
    const root = try rootHost(&parent, &room);
    defer root.deinit();

    const a = try spawn(arena, root, "alpha", "start alpha");
    const b = try spawn(arena, root, "beta", "start beta");
    const c = try spawn(arena, root, "gamma", "start gamma");
    try settle(root);
    mailbox.pump(root);

    // Root to an idle worker: a wake turn the root owns.
    const to_a = one(try mailbox.send(root, arena, .{ .to = a, .body = "alpha, report status" }));
    try testing.expectEqual(mailbox.Outcome.delivered, to_a.outcome);
    try testing.expectEqual(mailbox.Effect.wake_requested, to_a.effect.?);
    try settle(root);
    try testing.expectEqual(@as(usize, 1), room.received(a, to_a.id.?));

    // Worker to worker, from alpha's own host, replying.
    const alpha = try node_ops.lease(root, &.{a});
    const to_b = one(try mailbox.send(alpha.runtime, arena, .{ .to = b, .body = "beta, take the parser", .reply_to = to_a.id.? }));
    node_ops.release(root, alpha);
    try testing.expectEqual(mailbox.Outcome.delivered, to_b.outcome);
    try settle(root);
    try testing.expectEqual(@as(usize, 1), room.received(b, to_b.id.?));

    // A label never routes; a broadcast reaches every other live agent.
    const gamma = try node_ops.lease(root, &.{c});
    const by_label = one(try mailbox.send(gamma.runtime, arena, .{ .to = "alpha", .body = "x" }));
    try testing.expectEqual(mailbox.Outcome.rejected, by_label.outcome);
    try testing.expect(std.mem.find(u8, by_label.@"error".?, "labels never route") != null);
    const all = try mailbox.send(gamma.runtime, arena, .{ .to = "all", .body = "gamma is done" });
    const to_parent = one(try mailbox.send(gamma.runtime, arena, .{ .to = "parent", .body = "gamma needs input" }));
    node_ops.release(root, gamma);
    try testing.expectEqual(@as(usize, 3), all.len);
    try settle(root);
    for (all) |receipt| {
        try testing.expectEqual(mailbox.Outcome.delivered, receipt.outcome);
        if (!std.mem.eql(u8, receipt.to, root.node_id)) try testing.expectEqual(@as(usize, 1), room.received(receipt.to, receipt.id.?));
    }

    // The root's messages wait for the supervisor's notice, which settles
    // them once the loop says the model got them.
    mailbox.pump(root);
    const notice = (try mailbox.takeRootNotice(root, arena)).?;
    try testing.expectEqual(@as(usize, 2), notice.ids.len);
    try testing.expect(agent_message.carries(notice.text, to_parent.id.?));
    mailbox.rootAdmitted(root, notice, 41);
    try testing.expect((try mailbox.takeRootNotice(root, arena)) == null);
    mailbox.rootAnswered(root, 41, false);
    // Not delivered: they wait again, after the retry window.
    root.tree.mail.root_retry_after_ms = 0;
    const again = (try mailbox.takeRootNotice(root, arena)).?;
    mailbox.rootAdmitted(root, again, 42);
    mailbox.rootAnswered(root, 42, true);
    try testing.expectEqual(@as(usize, 0), (try root.children.parent.mailbox(arena)).len);
    try testing.expect((try mailbox.takeRootNotice(root, arena)) == null);

    // Every worker's mailbox is empty: each message left it once.
    for ([_][]const u8{ a, b, c }) |id| try testing.expectEqual(@as(usize, 0), (try parent.store.peekMailbox(arena, id)).len);

    // `list` scope visible names every other agent.
    const nodes = try mailbox.directory.list(arena, root);
    try testing.expectEqual(@as(usize, 4), nodes.len);
    try testing.expectEqualStrings("root", nodes[0].label);
}

test "a busy worker takes messages inside its running turn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(testing.allocator);
    defer parent.deinit();
    var room: Mailroom = .{};
    defer room.deinit();
    const root = try rootHost(&parent, &room);
    defer root.deinit();

    room.hold.store(true, .seq_cst);
    const busy = try spawn(arena, root, "busy", "hold until told");
    while (room.held.load(.seq_cst) == 0) io_mod.sleep(std.time.ns_per_ms);
    mailbox.pump(root);
    // Steering waits until the worker's turn is streaming; retry briefly.
    const receipt = one(try mailbox.send(root, arena, .{ .to = busy, .body = "while you work: also check docs" }));
    try testing.expectEqual(mailbox.Effect.injected, receipt.effect.?);
    var waited: usize = 0;
    while (room.received(busy, receipt.id.?) == 0 and waited < 2000) : (waited += 1) io_mod.sleep(std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 1), room.received(busy, receipt.id.?));
    // The applied steer settles at the next pump: the message left.
    mailbox.pump(root);
    try testing.expectEqual(@as(usize, 0), (try parent.store.peekMailbox(arena, busy)).len);
    room.hold.store(false, .seq_cst);
    try settle(root);
    try testing.expectEqual(@as(usize, 1), room.turns);
}

test "a full mailbox drops its oldest message and says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(testing.allocator);
    defer parent.deinit();
    var room: Mailroom = .{};
    defer room.deinit();
    const root = try rootHost(&parent, &room);
    defer root.deinit();
    const w = try spawn(arena, root, "talker", "start");
    try settle(root);
    const talker = try node_ops.lease(root, &.{w});
    defer node_ops.release(root, talker);
    var first: ?[]const u8 = null;
    for (0..session_adapter.max_mailbox) |index| {
        const receipt = one(try mailbox.send(talker.runtime, arena, .{ .to = "root", .body = try arena.print("note {d}", .{index}) }));
        try testing.expect(receipt.dropped_oldest == null);
        if (first == null) first = receipt.id;
    }
    const over = one(try mailbox.send(talker.runtime, arena, .{ .to = "parent", .body = "one more" }));
    try testing.expectEqualStrings(first.?, over.dropped_oldest.?);
    const box = try root.children.parent.mailbox(arena);
    try testing.expectEqual(session_adapter.max_mailbox, box.len);
    try testing.expectEqualStrings("note 1", box[0].body);
    // inbox peeks, then takes as read.
    try testing.expectEqual(session_adapter.max_mailbox, (try mailbox.inbox(root, arena, true, null)).len);
    try testing.expectEqual(session_adapter.max_mailbox, (try mailbox.inbox(root, arena, false, null)).len);
    try testing.expectEqual(@as(usize, 0), (try mailbox.inbox(root, arena, true, null)).len);
}

test "after a restart, a message the model already got leaves as delivered and the rest wait" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(testing.allocator);
    defer parent.deinit();
    var room: Mailroom = .{};
    defer room.deinit();
    // A crash left two messages waiting; the root's model already read the
    // first in a turn the log keeps.
    const mails = [_]session_adapter.Mail{
        .{ .id = @constCast("m-seen"), .seq = 0, .from = @constCast("w"), .label = @constCast("w"), .body = @constCast("seen") },
        .{ .id = @constCast("m-new"), .seq = 0, .from = @constCast("w"), .label = @constCast("w"), .body = @constCast("new") },
    };
    try parent.parent.appendMail(&.{
        .{ .mail = .{ .id = "m-seen", .from = "w", .label = "w", .body = "seen" } },
        .{ .mail = .{ .id = "m-new", .from = "w", .label = "w", .body = "new" } },
    });
    const seen_text = (try agent_message.build(arena, "root", mails[0..1])).?.text;
    try parent.parent.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast(seen_text), .origin = .peer_message }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());

    const root = try rootHost(&parent, &room);
    defer root.deinit();
    mailbox.pump(root);
    const left = try root.children.parent.mailbox(arena);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("m-new", left[0].id);
    const notice = (try mailbox.takeRootNotice(root, arena)).?;
    try testing.expectEqual(@as(usize, 1), notice.ids.len);
    try testing.expectEqualStrings("m-new", notice.ids[0]);
}

test "a wait on the root's mailbox takes a message and holds automatic delivery off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(testing.allocator);
    defer parent.deinit();
    var room: Mailroom = .{};
    defer room.deinit();
    const root = try rootHost(&parent, &room);
    defer root.deinit();
    mailbox.pump(root);
    const Waiter = struct {
        root: *tool_host.Runtime,
        got: usize = 0,
        fn run(self: *@This()) void {
            var scratch = std.heap.ArenaAllocator.init(testing.allocator);
            defer scratch.deinit();
            const taken = mailbox.waitRoot(self.root, scratch.allocator(), "watch_1", 5_000, null) catch return;
            self.got = taken.len;
        }
    };
    var waiter: Waiter = .{ .root = root };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    while (root.tree.mail.rootWaits() == 0) io_mod.sleep(std.time.ns_per_ms);
    try mailbox.postToRoot(root, "watch_1", "tests", "Watch watch_1 matched: FAIL");
    // The wait holds the root's mail: no notice takes it.
    try testing.expect((try mailbox.takeRootNotice(root, arena)) == null);
    thread.join();
    try testing.expectEqual(@as(usize, 1), waiter.got);
    try testing.expectEqual(@as(usize, 0), (try root.children.parent.mailbox(arena)).len);
}

/// Every envelope id that reached `node`, counted.
fn idsSeen(room: *Mailroom, arena: Allocator, node: []const u8) !std.array_hash_map.String(usize) {
    room.mutex.lockUncancelable(io_mod.getIo());
    defer room.mutex.unlock(io_mod.getIo());
    var seen: std.array_hash_map.String(usize) = .empty;
    for (room.seen.items) |item| {
        if (!std.mem.eql(u8, item.node, node)) continue;
        const parsed = agent_message.parse(arena, item.text) orelse continue;
        for (parsed.messages) |row| {
            const entry = try seen.getOrPut(arena, try arena.dupe(u8, row.id));
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }
    return seen;
}

fn maxRssBytes() usize {
    const usage = std.posix.getrusage(0);
    const raw: usize = @intCast(usage.maxrss);
    // Linux reports kilobytes, macOS bytes.
    return if (@import("builtin").target.os.tag == .linux) raw * 1024 else raw;
}

test "twenty workers in one tree broadcast to each other: every message once, no deadlock, bounded hosts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(testing.allocator);
    defer parent.deinit();
    var room: Mailroom = .{};
    defer room.deinit();
    // The default policy: eight run slots for twenty workers.
    const root = try tool_host.Runtime.createWithPolicy(testing.allocator, &parent.children, .{ .resolve_fn = Mailroom.resolve }, .{ .context = &room, .run_fn = Mailroom.run }, .{});
    defer root.deinit();
    root.tree.process_slots = &room.process;
    const workers = 20;
    const started = io_mod.milliTimestamp();
    const rss_before = maxRssBytes();
    mailbox.pump(root);
    room.gate.store(false, .seq_cst);
    var ids: [workers][]const u8 = undefined;
    for (&ids, 0..) |*id, index| id.* = try spawn(arena, root, try arena.print("w{d}", .{index}), "broadcast once");
    // Twelve of them wait for a run slot, with no log yet: messages to them
    // are held until they start.
    room.gate.store(true, .seq_cst);

    var root_seen: std.array_hash_map.String(usize) = .empty;
    var request: i64 = 1;
    var max_open: usize = 0;
    var rounds: usize = 0;
    while (rounds < 3000) : (rounds += 1) {
        mailbox.pump(root);
        max_open = @max(max_open, root.tree.nodes.openCount());
        // The supervisor's part: the root's notices, answered as delivered.
        if (try mailbox.takeRootNotice(root, arena)) |notice| {
            for (notice.ids) |id| {
                const entry = try root_seen.getOrPut(arena, try arena.dupe(u8, id));
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
            }
            mailbox.rootAdmitted(root, notice, request);
            mailbox.rootAnswered(root, request, true);
            request += 1;
        }
        var waiting: usize = 0;
        for (try mailbox.directory.list(arena, root)) |node| waiting += node.waiting;
        var busy = root.managed.anyRunning();
        for (try root.fleet.snapshot(arena)) |job| {
            if (!job.state.settled()) busy = true;
        }
        if (room.broadcasts.load(.seq_cst) == workers and waiting == 0 and !busy) break;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    const elapsed = io_mod.milliTimestamp() - started;
    const rss_after = maxRssBytes();
    std.debug.print("\nmailbox scale: {d} workers, {d} turns, {d} ms, max open hosts {d}, peak RSS growth {d} KiB\n", .{ workers, room.turns, elapsed, max_open, (rss_after -| rss_before) / 1024 });
    try testing.expectEqual(@as(u32, workers), room.broadcasts.load(.seq_cst));
    // The root got one message from each worker, each once.
    try testing.expectEqual(@as(usize, workers), root_seen.count());
    for (root_seen.keys(), root_seen.values()) |key, count| if (count != 1) std.debug.print("root dup {s} x{d}\n", .{ key, count });
    for (ids) |id| {
        const seen = try idsSeen(&room, arena, id);
        for (seen.keys(), seen.values()) |key, count| if (count != 1) {
            std.debug.print("worker {s} dup {s} x{d}\n", .{ id, key, count });
            room.mutex.lockUncancelable(io_mod.getIo());
            defer room.mutex.unlock(io_mod.getIo());
            for (room.seen.items) |item| if (std.mem.eql(u8, item.node, id) and agent_message.carries(item.text, key)) std.debug.print("  seen steered={} at={d} as {s}\n", .{ item.steered, item.at, item.text[0..@min(item.text.len, 200)] });
        };
    }
    for (root_seen.values()) |count| try testing.expectEqual(@as(usize, 1), count);
    // Each worker got one from each of the others, each once.
    for (ids) |id| {
        const seen = try idsSeen(&room, arena, id);
        if (seen.count() != workers - 1) std.debug.print("worker {s} saw {d}\n", .{ id, seen.count() });
    }
    for (ids) |id| {
        const seen = try idsSeen(&room, arena, id);
        try testing.expectEqual(@as(usize, workers - 1), seen.count());
        for (seen.values()) |count| try testing.expectEqual(@as(usize, 1), count);
        try testing.expectEqual(@as(usize, 0), (try parent.store.peekMailbox(arena, id)).len);
    }
    // Hosts stay near the tree's cap while every worker runs.
    try testing.expect(max_open <= root.tree.nodes.limits.max_open + root.tree.policy.tree_slots + workers);
}

test "a message to a worker that has not started is kept in the root's log and reaches it once after a restart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(testing.allocator);
    defer parent.deinit();
    var room: Mailroom = .{};
    defer room.deinit();
    const root = try rootHost(&parent, &room);
    defer root.deinit();

    // Four running turns fill the tree's four run slots, so a fifth worker
    // is admitted but cannot start: it has no log yet.
    room.hold.store(true, .seq_cst);
    for (0..4) |index| _ = try spawn(arena, root, try arena.print("busy{d}", .{index}), "hold until told");
    while (room.held.load(.seq_cst) < 4) io_mod.sleep(std.time.ns_per_ms);
    const late = try spawn(arena, root, "late", "start");
    const receipt = one(try mailbox.send(root, arena, .{ .to = late, .body = "for when you start" }));
    try testing.expectEqual(mailbox.Outcome.queued, receipt.outcome);
    const held = try root.children.parent.heldMail(arena);
    try testing.expectEqual(@as(usize, 1), held.len);
    try testing.expectEqualStrings(late, held[0].hold_for.?);
    // Held mail is not the root's own.
    try testing.expectEqual(@as(usize, 0), (try root.children.parent.mailbox(arena)).len);

    // A crash loses the process's memory of it; the log keeps it.
    root.tree.mail.deinit();
    root.tree.mail = mailbox.Bus.init(testing.allocator);
    room.hold.store(false, .seq_cst);
    var waited: usize = 0;
    while (room.received(late, receipt.id.?) == 0 and waited < 4000) : (waited += 1) {
        mailbox.pump(root);
        io_mod.sleep(2 * std.time.ns_per_ms);
    }
    try settle(root);
    try testing.expectEqual(@as(usize, 1), room.received(late, receipt.id.?));
    try testing.expectEqual(@as(usize, 0), (try root.children.parent.heldMail(arena)).len);

    // A crash after the move but before the root's log let go of it leaves
    // it held again; the next move sees the worker already has it.
    try root.children.parent.appendMail(&.{.{ .mail = .{ .id = receipt.id.?, .from = root.node_id, .label = "root", .body = "for when you start", .hold_for = late } }});
    root.tree.mail.held_maybe.store(true, .seq_cst);
    mailbox.pump(root);
    try settle(root);
    mailbox.pump(root);
    try testing.expectEqual(@as(usize, 0), (try root.children.parent.heldMail(arena)).len);
    try testing.expectEqual(@as(usize, 1), room.received(late, receipt.id.?));
}
