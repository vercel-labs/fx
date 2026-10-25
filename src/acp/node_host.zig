//! What a persistent host does for the nodes below its root session (D91,
//! D96): it forwards their approvals to its connection, delivers a person's
//! message to an idle node at any depth, and runs the `fx/command`s a node
//! supports, rewind included (D97).
//! Everything here runs on the host's owner thread except a message's own
//! work, which runs on its thread until the host joins it.
const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const types = @import("../core/shared/types.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const approval_registry = @import("../core/subagent/approval_registry.zig");
const child_state = @import("../core/subagent/child_state.zig");
const model_contract = @import("../core/subagent/model_contract.zig");
const tool_host = @import("../core/subagent/tool_host.zig");
const node_hosts = @import("../core/subagent/node_hosts.zig");
const node_ops = @import("../core/subagent/node_ops.zig");
const authority = @import("../core/subagent/authority.zig");
const kernel = @import("../core/kernel/slot.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const host_commands = @import("commands.zig");
const server = @import("server.zig");
const Allocator = std.mem.Allocator;

/// The most child approvals a host forwards at once, from any depth. More
/// wait in the tree's registry and are forwarded as earlier ones settle.
pub const max_forwarded_approvals: usize = 16;

pub const permission_retired_method = "proto/permission_retired";

/// The child approvals forwarded to the connection, oldest first, each
/// under the outbound request id its reply names.
pub const Approvals = struct {
    forwarded: std.ArrayList(Forwarded) = .empty,
    revision: ?u64 = null,

    const Forwarded = struct { id: i64, pending: approval_registry.PendingRequest };

    pub fn deinit(self: *Approvals, state: *server.ServerState) void {
        self.retireAll(state);
        self.forwarded.deinit(state.alloc);
        self.* = undefined;
    }

    /// Takes back every forwarded request; the next pump forwards what is
    /// still waiting.
    pub fn retireAll(self: *Approvals, state: *server.ServerState) void {
        while (self.forwarded.items.len > 0) self.retire(state, self.forwarded.items.len - 1);
        self.revision = null;
    }

    fn retire(self: *Approvals, state: *server.ServerState, index: usize) void {
        var removed = self.forwarded.orderedRemove(index);
        defer removed.pending.deinit(state.alloc);
        var params: std.Io.Writer.Allocating = .init(state.alloc);
        defer params.deinit();
        std.json.Stringify.value(.{ .request_id = removed.id }, .{}, &params.writer) catch return;
        state.writer.writeNotification(state.alloc, permission_retired_method, params.written()) catch {};
    }

    fn find(self: *const Approvals, request_id: []const u8) ?usize {
        for (self.forwarded.items, 0..) |entry, index| if (std.mem.eql(u8, entry.pending.request_id, request_id)) return index;
        return null;
    }

    /// Whether `id` is a forwarded request's outbound id.
    pub fn owns(self: *const Approvals, id: i64) bool {
        for (self.forwarded.items) |entry| if (entry.id == id) return true;
        return false;
    }

    /// Answers the forwarded request whose outbound id is `id`.
    pub fn answer(self: *Approvals, state: *server.ServerState, id: i64, decision: types.ToolPermissionDecision) !void {
        const index = for (self.forwarded.items, 0..) |entry, i| {
            if (entry.id == id) break i;
        } else return;
        const root = state.subagent_host orelse return error.SessionStopped;
        const entry = self.forwarded.items[index];
        _ = try root.resolveApproval(.{
            .request_id = entry.pending.request_id,
            .child_id = entry.pending.child_id,
            .decision = decision,
            .timestamp_ms = io_mod.milliTimestamp(),
        });
        self.retire(state, index);
        self.revision = null;
    }

    /// Projects the tree's waiting approvals onto the connection: forwards
    /// each new one, up to the bound, and retires those no longer waiting.
    pub fn pump(self: *Approvals, state: *server.ServerState) !void {
        const root = state.subagent_host orelse return;
        const revision = root.approvals.pendingRevision();
        if (self.revision == revision) return;
        const alloc = state.alloc;
        const pending = try root.pendingApprovalRequests(alloc, max_forwarded_approvals);
        const kept = try alloc.alloc(bool, pending.len);
        defer alloc.free(kept);
        @memset(kept, false);
        defer {
            for (pending, kept) |*request, moved| if (!moved) request.deinit(alloc);
            alloc.free(pending);
        }
        var index: usize = 0;
        while (index < self.forwarded.items.len) {
            const still = for (pending) |request| {
                if (std.mem.eql(u8, request.request_id, self.forwarded.items[index].pending.request_id)) break true;
            } else false;
            if (still) index += 1 else self.retire(state, index);
        }
        for (pending, kept) |request, *moved| {
            if (self.find(request.request_id) != null) continue;
            try self.forwarded.ensureUnusedCapacity(alloc, 1);
            const id = try forward(state, request);
            self.forwarded.appendAssumeCapacity(.{ .id = id, .pending = request });
            moved.* = true;
        }
        self.revision = revision;
    }
};

/// Writes one child approval as a permission request and returns its id.
/// Its title names the path to the node that asked, as `root › a › b`.
fn forward(state: *server.ServerState, request: approval_registry.PendingRequest) !i64 {
    const alloc = state.alloc;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Hop = struct { id: []const u8, name: []const u8 };
    const hops = try arena.alloc(Hop, request.path.len);
    var trail: std.Io.Writer.Allocating = .init(arena);
    for (request.path, hops, 0..) |id, *hop, index| {
        hop.* = .{ .id = id, .name = if (index == 0) "root" else try nodeLabel(arena, state, request.path[index - 1], id) };
        if (index > 0) try trail.writer.writeAll(" › ");
        try trail.writer.writeAll(hop.name);
    }
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    const id = state.next_outbound_request_id;
    state.next_outbound_request_id += 1;
    state.outbound_mutex.unlock(io_mod.getIo());
    const title = try arena.print("{s}: {s}", .{ trail.written(), request.request.label });
    var params: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .sessionId = state.active_session.?.session_id,
        .childSessionId = request.child_id,
        .toolCall = .{
            .toolCallId = request.request_id,
            .name = "subagent",
            .title = title,
            .kind = "execute",
            .status = "pending",
            .rawInput = .{ .child_id = request.child_id, .command = request.request.command, .arguments_preview = request.request.tool_arguments_preview, .explanation = request.request.explanation },
        },
        .options = .{
            .{ .optionId = "allow_once", .name = "Allow once", .kind = "allow_once" },
            .{ .optionId = "allow_always", .name = "Allow for this session", .kind = "allow_always" },
            .{ .optionId = "reject_once", .name = "Reject", .kind = "reject_once" },
        },
        ._meta = .{ .fx = .{ .nodePath = hops } },
    }, .{}, &params.writer);
    try state.writer.writeRequest(alloc, .{ .integer = @intCast(id) }, "session/request_permission", params.written());
    return @intCast(id);
}

/// A node's label: its agent name as its parent saved it, else the end of
/// its id, which differs between siblings. Borrows `arena`.
fn nodeLabel(arena: Allocator, state: *server.ServerState, parent_id: []const u8, id: []const u8) ![]const u8 {
    const fallback = id[id.len -| 8..];
    const store = if (state.sessions_v2) |*value| value else return fallback;
    const peeked = store.manager.peek(arena, parent_id) catch return fallback;
    for (peeked.state.children.items) |child| {
        if (!std.mem.eql(u8, child.id, id)) continue;
        const Spawn = struct { agent: ?[]const u8 = null };
        const raw = child.spawn_data orelse return fallback;
        const spawn = std.json.parseFromSliceLeaky(Spawn, arena, raw, .{ .ignore_unknown_fields = true }) catch return fallback;
        return spawn.agent orelse fallback;
    }
    return fallback;
}

/// A person's message to a node at any depth, running as that node's own
/// work on its own thread, as its parent's `message` call would run it. It
/// holds its parent's host open until it ends (D96).
pub const Message = struct {
    state: *server.ServerState,
    alloc: Allocator,
    node_id: []u8,
    agent: []u8,
    text: []u8,
    invocation_id: []u8,
    defaults: tool_host.Defaults,
    permission_mode: types.PermissionMode,
    max_result_bytes: usize,
    /// The host the message runs on: the node's parent's.
    host: *tool_host.Runtime,
    /// The lease on that host; null when it is the root's.
    lease: ?*node_hosts.Entry,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn destroy(self: *Message) void {
        const alloc = self.alloc;
        alloc.free(self.node_id);
        alloc.free(self.agent);
        alloc.free(self.text);
        alloc.free(self.invocation_id);
        alloc.free(self.defaults.model);
        alloc.destroy(self);
    }

    fn run(self: *Message) void {
        defer self.done.store(true, .release);
        defer if (self.lease) |entry| self.host.tree.nodes.release(entry, .use);
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var request = model_contract.validateRequest(arena, .{ .message = .{ .agent = self.agent, .message = self.text } }) catch |err| {
            debug_trace.logf("acp", "node message invalid node_id={s} err={s}", .{ self.node_id, @errorName(err) });
            return;
        };
        defer request.deinit(arena);
        const result = self.host.executeManaged(arena, &request, .{
            .invocation_id = self.invocation_id,
            .parent_permission_mode = self.permission_mode,
            .defaults = self.defaults,
            .max_result_bytes = self.max_result_bytes,
            .timestamp_ms = io_mod.milliTimestamp(),
            .cancel_flag = &self.cancel,
            .lend_turn_slots = false,
        }) catch |err| {
            debug_trace.logf("acp", "node message failed node_id={s} err={s}", .{ self.node_id, @errorName(err) });
            return;
        };
        if (!result.success) debug_trace.logf("acp", "node message refused node_id={s} result={s}", .{ self.node_id, result.body });
    }
};

/// The one message a host runs at a time.
pub const Messages = struct {
    running: ?*Message = null,

    /// Joins a finished message, or waits for the running one.
    pub fn reap(self: *Messages, wait: bool) void {
        const message = self.running orelse return;
        if (!wait and !message.done.load(.acquire)) return;
        message.thread.join();
        message.destroy();
        self.running = null;
    }

    pub fn busy(self: *Messages) bool {
        self.reap(false);
        return self.running != null;
    }

    /// Cancels the message running on `node_id`, if any.
    pub fn cancel(self: *Messages, node_id: []const u8) void {
        const message = self.running orelse return;
        if (std.mem.eql(u8, message.node_id, node_id)) message.cancel.store(true, .seq_cst);
    }

    /// Cancels and joins the running message before the host closes.
    pub fn deinit(self: *Messages) void {
        if (self.running) |message| message.cancel.store(true, .seq_cst);
        self.reap(true);
    }

    /// Starts `text` as node `node_id`'s next work, at any depth, or names
    /// why it cannot take it now.
    pub fn start(self: *Messages, state: *server.ServerState, node_id: []const u8, text: []const u8) !?host_commands.NodeRefusal {
        if (self.busy()) return .message_running;
        const root = state.subagent_host orelse return .unsupported;
        const active = if (state.active_session) |*session| session else return .unsupported;
        var arena_state = std.heap.ArenaAllocator.init(state.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const node = (try resolve(arena, state, node_id)) orelse return .unknown_node;
        if (node.abandoned) return .abandoned;
        // The node's parent runs the message, as its own `message` call.
        const above = node.path[0 .. node.path.len - 1];
        const lease: ?*node_hosts.Entry = if (above.len == 0) null else node_ops.lease(root, above) catch |err| return switch (err) {
            error.NodeBusy => .node_running,
            error.NodeUnavailable => .unknown_node,
            else => err,
        };
        var handed = false;
        defer if (!handed) if (lease) |entry| node_ops.release(root, entry);
        const host = if (lease) |entry| entry.runtime else root;
        const registry = try (child_state.Store{ .children = host.children, .parent_id = host.node_id }).load(arena);
        const child = for (registry.children) |*row| {
            if (std.mem.eql(u8, row.id, node_id)) break row;
        } else return .unknown_node;
        switch (child.phase) {
            .running, .awaiting_approval => return .node_running,
            else => {},
        }
        const agent = child.agentName() orelse return .one_off;
        if (root.tree.slots.inUse() >= root.tree.slots.capacity) return .capacity;

        const alloc = state.alloc;
        const message = try alloc.create(Message);
        errdefer alloc.destroy(message);
        const owned_node = try alloc.dupe(u8, node_id);
        errdefer alloc.free(owned_node);
        const owned_agent = try alloc.dupe(u8, agent);
        errdefer alloc.free(owned_agent);
        const owned_text = try alloc.dupe(u8, text);
        errdefer alloc.free(owned_text);
        const invocation_id = try alloc.print("frontend-{d}", .{io_mod.milliTimestamp()});
        errdefer alloc.free(invocation_id);
        const model = try alloc.dupe(u8, active.model);
        errdefer alloc.free(model);
        message.* = .{
            .state = state,
            .alloc = alloc,
            .node_id = owned_node,
            .agent = owned_agent,
            .text = owned_text,
            .invocation_id = invocation_id,
            .defaults = .{
                .provider = active.provider,
                .model = model,
                .effort = active.effort,
                .fast_mode = active.fast_mode,
                .ultrafast_mode = active.ultrafast_mode,
                .conversation_language = active.session_rt.languageSnapshot(),
            },
            // No wider than the session, nor than the parent's own mode.
            .permission_mode = authority.narrowerPermission(active.permission_mode, host.permission_ceiling),
            .max_result_bytes = active.max_tool_result_bytes,
            .host = host,
            .lease = lease,
        };
        message.thread = try std.Thread.spawn(.{}, Message.run, .{message});
        handed = true;
        self.running = message;
        debug_trace.logf("acp", "node message started node_id={s} agent={s} depth={d}", .{ node_id, agent, node.path.len });
        return null;
    }
};

/// A node of the attached session's tree, as its saved logs place it.
const Resolved = struct {
    /// Ids from just below the root down to the node, in `arena`.
    path: []const []const u8,
    /// The node, or one of its ancestors, was abandoned by a rewind of its
    /// parent (D97): it is read-only.
    abandoned: bool,
};

/// More hops than any tree has levels, so a damaged parent chain ends.
const max_resolve_hops = 16;

/// Places `node_id` in the attached session's tree by walking its saved
/// parents up to the root; null when it is not a node below that root.
fn resolve(arena: Allocator, state: *server.ServerState, node_id: []const u8) !?Resolved {
    const store = if (state.sessions_v2) |*value| value else return null;
    const active = if (state.active_session) |*session| session else return null;
    var path: std.ArrayList([]const u8) = .empty;
    var abandoned = false;
    var current = node_id;
    for (0..max_resolve_hops) |_| {
        const peeked = store.manager.peek(arena, current) catch return null;
        const parent = peeked.parent orelse return null;
        if (!std.mem.eql(u8, peeked.root, active.session_id)) return null;
        const above = store.manager.peek(arena, parent) catch return null;
        for (above.state.children.items) |child| {
            if (std.mem.eql(u8, child.id, current) and child.abandoned) abandoned = true;
        }
        try path.insert(arena, 0, current);
        if (std.mem.eql(u8, parent, active.session_id)) return .{ .path = path.items, .abandoned = abandoned };
        current = parent;
    }
    return null;
}

/// Runs `command` for node `node_id` below the root, at any depth, writing
/// its result to `out`, or names why the host cannot run it there.
pub fn runCommand(arena: Allocator, state: *server.ServerState, node_id: []const u8, command: host_commands.Command, out: *std.Io.Writer) !?host_commands.NodeRefusal {
    const store = if (state.sessions_v2) |*value| value else return .unknown_node;
    const root = state.subagent_host orelse return .unknown_node;
    const node = (try resolve(arena, state, node_id)) orelse return .unknown_node;
    switch (command) {
        .last_reply => {
            const history = try store.childHistory(arena, node_id);
            try host_commands.writeResult(out, command, .{ .text = lastReply(history) orelse "" });
            return null;
        },
        .context => {
            var preferences = try store.childPreferences(arena, node_id);
            defer preferences.deinit(arena);
            const capabilities = state.capability_resolver.available(preferences.model, state.cfg.provider_set.select(preferences.provider).fallbackModelCapabilities(preferences.model));
            try host_commands.writeResult(out, command, .{ .context = .{
                .used = (try store.contextUsage(arena, node_id)) orelse 0,
                .total = capabilities.context_window,
                .auto_compact_percent = state.auto_compact_percent,
            } });
            return null;
        },
        // A node has no file journal of its own: undo on it rewinds its
        // newest turn (D97).
        .undo => {
            if (node.abandoned) return .abandoned;
            const outcome = node_ops.rewindLatest(arena, root, node.path) catch |err| return switch (err) {
                error.NodeUnavailable => .unknown_node,
                else => err,
            };
            switch (outcome) {
                .refused => |refusal| return switch (refusal) {
                    .busy => .node_running,
                    .past_compaction => .rewind_past_compaction,
                    .nothing_to_rewind => {
                        try host_commands.writeResult(out, command, .{ .undo = .{ .outcome = .nothing_to_undo } });
                        return null;
                    },
                },
                .rewound => |rewound| {
                    std.mem.replaceScalar(u8, rewound.prompt, '\n', ' ');
                    const prompt = text_utils.utf8PrefixByBytes(rewound.prompt, 160);
                    const more = if (prompt.len < rewound.prompt.len) "…" else "";
                    const text = switch (rewound.abandoned) {
                        0 => try arena.print("Rewound this subagent's latest turn: \"{s}{s}\"", .{ prompt, more }),
                        1 => try arena.print("Rewound this subagent's latest turn: \"{s}{s}\". The subagent it started there is abandoned: you can read it, not message it.", .{ prompt, more }),
                        else => try arena.print("Rewound this subagent's latest turn: \"{s}{s}\". The {d} subagents it started there are abandoned: you can read them, not message them.", .{ prompt, more, rewound.abandoned }),
                    };
                    try host_commands.writeResult(out, command, .{ .undo = .{ .outcome = .rewound, .text = text } });
                    return null;
                },
            }
        },
        .model, .effort => |value| {
            const wanted = value orelse {
                var preferences = try store.childPreferences(arena, node_id);
                defer preferences.deinit(arena);
                const text = try arena.print("model: {s} · effort: {s}", .{ preferences.model, preferences.effort.label() });
                try host_commands.writeResult(out, command, .{ .text = text });
                return null;
            };
            if (node.abandoned) return .abandoned;
            const effort: ?types.ReasoningEffort = if (command == .effort) types.ReasoningEffort.parse(wanted) orelse return .invalid_effort else null;
            const entry = node_ops.lease(root, node.path) catch |err| return switch (err) {
                error.NodeBusy => .node_running,
                error.NodeUnavailable => .unknown_node,
                else => err,
            };
            defer node_ops.release(root, entry);
            // Saved on the node, so its next turns use it however often its
            // host closes and opens again.
            var preferences = try entry.session.currentPreferences(arena);
            if (effort) |level| preferences.effort = level else preferences.model = try arena.dupe(u8, wanted);
            try entry.session.setPreferences(preferences);
            const text = try arena.print("This subagent's next turns use model {s} · effort {s}.", .{ preferences.model, preferences.effort.label() });
            try host_commands.writeResult(out, command, .{ .text = text });
            return null;
        },
        .compact => return .compact,
        // A fork of a node is a new root session of its own (D98).
        .fork => {
            const active = if (state.active_session) |*session| session else return .unknown_node;
            var trail: std.Io.Writer.Allocating = .init(arena);
            try trail.writer.writeAll("root");
            for (node.path, 0..) |hop, index| {
                const parent = if (index == 0) active.session_id else node.path[index - 1];
                try trail.writer.print(" › {s}", .{try nodeLabel(arena, state, parent, hop)});
            }
            const outcome = node_ops.forkLatest(arena, root, node.path, active.workspace_root, trail.written()) catch |err| return switch (err) {
                error.NodeUnavailable => .unknown_node,
                else => err,
            };
            switch (outcome) {
                .refused => |refusal| return switch (refusal) {
                    .busy => .node_running,
                    .nothing_to_fork => .nothing_to_fork,
                },
                .forked => |forked| {
                    const text = try arena.print("Forked into a new session: forked from {s} · turn {d}.", .{ trail.written(), forked.turns });
                    try host_commands.writeResult(out, command, .{ .fork = .{ .session_id = forked.session_id, .text = text } });
                    return null;
                },
            }
        },
        else => return .unsupported,
    }
}

/// `/kernel` for node `node_id`: its kernel lives in the process pool under
/// the node's id, whether or not a turn of it holds it (D95).
pub fn kernelControl(alloc: Allocator, state: *server.ServerState, node_id: []const u8, action: kernel.Action) !server.PersistentHost.KernelInfo {
    var arena_state = std.heap.ArenaAllocator.init(state.alloc);
    defer arena_state.deinit();
    const root = state.subagent_host orelse return error.NoActiveSession;
    const active = if (state.active_session) |*session| session else return error.NoActiveSession;
    const node = (try resolve(arena_state.allocator(), state, node_id)) orelse return error.ChildNotFound;
    if (node.abandoned and action != .status) return error.NodeAbandoned;
    if (action != .status and action != .interrupt and root.tree.nodes.subtreeBusy(node_id)) return error.SessionBusy;
    var slot: kernel.Slot = .{ .home_override = state.cfg.home_override, .retainer = root.tree };
    defer slot.deinit();
    _ = try slot.ensure(state.alloc, .{ .cwd = active.workspace_root, .session_id = node_id });
    const value = try slot.control(state.alloc, .{ .cwd = active.workspace_root, .session_id = node_id }, action);
    return .{ .state = if (value) |current| @tagName(current) else "uninitialized", .diagnostics = try slot.report(alloc, .{ .cwd = active.workspace_root, .session_id = node_id }) };
}

fn lastReply(history: []const types.HistoryTurn) ?[]const u8 {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        switch (history[index]) {
            .assistant => |entry| if (entry.assistant.len > 0) return entry.assistant,
            else => {},
        }
    }
    return null;
}

test "a node's last reply is its newest assistant text" {
    const turns = [_]types.HistoryTurn{
        .{ .assistant = .{ .user = .{ .text = @constCast("one") }, .assistant = @constCast("first") } },
        .{ .assistant = .{ .user = .{ .text = @constCast("two") }, .assistant = @constCast("") } },
    };
    try std.testing.expectEqualStrings("first", lastReply(&turns).?);
    try std.testing.expect(lastReply(&.{}) == null);
}
