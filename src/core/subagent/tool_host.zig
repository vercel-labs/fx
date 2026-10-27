const std = @import("std");
const execution_observation = @import("../agent/runtime/observation.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const managed_owner = @import("managed_owner.zig");
const live_metrics = @import("live_metrics.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const model_contract = @import("model_contract.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const model_provider = @import("../config/model_provider.zig");
const permissions = @import("../permissions/permissions.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const result_store = @import("../session/result_store.zig");
const slot_pool = @import("slot_pool.zig");
const text_utils = @import("../shared/text_utils.zig");
const tree_mod = @import("tree.zig");
const turn_jobs = @import("turn_jobs.zig");
const fleet_host = @import("fleet_host.zig");
const node_hosts = @import("node_hosts.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
/// Bounds how long a parent wait takes to observe cancellation or steering,
/// and how long the polling loops take to see a child change. The terminal
/// result wait also wakes on child state changes. Status publishing is rate
/// limited separately, so a short pulse only adds cheap wakeups.
const terminal_wait_pulse_ms: u64 = 20;

pub const Defaults = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    conversation_language: session.ConversationLanguage,
};

pub const ChildRunner = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (
        ?*anyopaque,
        *execution.TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome = unavailableChildRun,
};

fn unavailableChildRun(
    _: ?*anyopaque,
    _: *execution.TurnContext,
    _: domain.QueuedMessage,
    _: domain.AdmissionSnapshot,
    _: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    return error.ProviderFailed;
}

test {
    _ = @import("nested_tests.zig");
    _ = @import("mailbox.zig");
    _ = @import("mail_ops.zig");
    _ = @import("node_hosts.zig");
    _ = @import("node_ops.zig");
    _ = @import("slot_pool.zig");
    _ = @import("tree.zig");
    _ = @import("turn_jobs.zig");
    _ = @import("fleet_state.zig");
    _ = @import("fleet_host.zig");
}

test "managed execution receipts retain the pending contract" {
    var runtime: Runtime = undefined;
    for ([_]bool{ false, true }) |pending| {
        const result = try runtime.encodeManaged(std.testing.allocator, .{ .ok = true, .pending = pending });
        defer std.testing.allocator.free(result.body);
        try std.testing.expectEqual(pending, result.pending);
    }
}

pub const ProgressSink = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, types.SubagentStatus) void,

    pub fn publish(self: ProgressSink, status: types.SubagentStatus) void {
        self.publish_fn(self.context, status);
    }
};

/// Resolves a creation-time model override against the host's model catalog.
/// Returned slices are allocated from the passed allocator and must remain
/// valid for the duration of the `executeManaged` call.
pub const ModelOverrideResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) Allocator.Error!model_contract.ModelCatalogMatch,

    pub fn resolve(
        self: ModelOverrideResolver,
        alloc: Allocator,
        raw_model: []const u8,
    ) Allocator.Error!model_contract.ModelCatalogMatch {
        return self.resolve_fn(self.context, alloc, raw_model);
    }
};

/// Resolves a fleet `model` of the form `@role` to the model the role picks
/// on the parent's provider (D174). The model must outlive `executeManaged`.
pub const ModelRoleResolver = struct {
    pub const Lookup = union(enum) {
        model: []const u8,
        unknown_role,
        /// The role picks no model on this provider; the worker inherits.
        unavailable,
    };

    context: ?*anyopaque = null,
    resolve_fn: *const fn (?*anyopaque, []const u8) Lookup,
};

pub const ExecuteOptions = struct {
    observer: ?*execution_observation.Observer = null,
    invocation_id: []const u8,
    parent_permission_mode: types.PermissionMode = .yolo,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    defaults: Defaults,
    max_result_bytes: usize,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    steering_worker: ?*worker_runtime.WorkerRuntime = null,
    progress: ?ProgressSink = null,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    model_override_resolver: ?ModelOverrideResolver = null,
    model_role_resolver: ?ModelRoleResolver = null,
    /// The caller is this node's own turn, whose run slots its wait lends
    /// back (D92). A person's message from the frontend runs outside any
    /// turn and holds none, so it lends nothing.
    lend_turn_slots: bool = true,
};

pub const ManagedExecutionResult = struct {
    pending: bool = false,
    success: bool,
    body: []u8,
    /// The final status model is owned by the result allocator.
    final_status: ?types.SubagentStatus = null,
};

pub const ApprovalResolveOptions = struct {
    request_id: []const u8,
    child_id: []const u8,
    decision: types.ToolPermissionDecision,
    feedback: ?[]const u8 = null,
    timestamp_ms: i64,
};

/// A result longer than this reaches the parent as its start and a handle
/// to the whole text, which `read_tool_result` reads (D94).
pub const max_inline_result_bytes: usize = 6000;

/// One node's host for its children (D91, D96). The root's host is created
/// by the frontend and owns the tree. Every node below it has its host in
/// the tree's registry (`node_hosts.zig`), opened when the node has work
/// and closed once it is idle, so it outlives its parent's turn.
pub const Runtime = struct {
    alloc: Allocator,
    /// This node's children, borrowed until deinit (D22): from the frontend
    /// for the root, from the node's registry entry below it.
    children: *child_state.V2Children,
    /// The node this host serves.
    node_id: []u8,
    /// Ids from the tree's root down to this node.
    node_path: []const []const u8 = &.{},
    depth: u8 = 0,
    tree: *tree_mod.Tree,
    owns_tree: bool = false,
    /// The registry entry that owns this host; null for the root.
    node_entry: ?*node_hosts.Entry = null,
    /// The widest permission mode this node's children may get: its own,
    /// as its latest turn was admitted.
    permission_ceiling: types.PermissionMode = .yolo,
    /// The run slots of this node's running turn, lent back while it waits
    /// on a child (D92); null between turns and for the root, whose turn
    /// holds none.
    turn_permit: ?*slot_pool.Permit = null,
    host_authority: authority.HostResolver,
    child_runner: ChildRunner,
    /// The tree's registry (D93).
    approvals: *approval_registry.Registry,
    authority_resolver: authority.Resolver,
    managed: managed_owner.Owner,
    admission_mutex: std.Io.Mutex = .init,
    yielded_mutex: std.Io.Mutex = .init,
    yielded: std.ArrayList(YieldedWork) = .empty,
    /// The turn jobs of this node's workers (D112).
    fleet: turn_jobs.Ledger,

    const YieldedWork = struct { child_id: []u8, work_id: []u8, max_result_bytes: usize, result: ?ManagedExecutionResult = null, delivered: bool = false };
    pub const YieldedResult = struct { child_id: []const u8, work_id: []const u8, body: []const u8, max_result_bytes: usize, delivered: bool, receipt_sequence: u64 = 0 };

    /// The root's host over a session whose children live in its log
    /// (D22), returned only after abandoned child work has been recovered.
    /// It owns the tree. Borrows `children` and the callback contexts until
    /// deinit; the root stays open until then
    /// (`tests/tla/session_manager/Wiring.tla` ParentOutlivesChildren).
    pub fn create(
        alloc: Allocator,
        children: *child_state.V2Children,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    ) !*Runtime {
        return createWithPolicy(alloc, children, host_authority, child_runner, .{});
    }

    pub fn createWithPolicy(
        alloc: Allocator,
        children: *child_state.V2Children,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
        policy: tree_mod.SpawnPolicy,
    ) !*Runtime {
        const root_id = children.parent.id();
        try domain.validateId(root_id);
        const tree = try tree_mod.Tree.create(alloc, root_id, children.parent.store, policy);
        errdefer tree.destroy();
        const runtime = try open(alloc, .{
            .children = children,
            .tree = tree,
            .depth = 0,
            .host_authority = host_authority,
            .child_runner = child_runner,
        });
        runtime.owns_tree = true;
        tree.root_host = runtime;
        return runtime;
    }

    const OpenOptions = struct {
        children: *child_state.V2Children,
        tree: *tree_mod.Tree,
        depth: u8,
        node_path: ?[]const []const u8 = null,
        node_entry: ?*node_hosts.Entry = null,
        permission_ceiling: types.PermissionMode = .yolo,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    };

    fn open(alloc: Allocator, options: OpenOptions) !*Runtime {
        const node_id = options.children.parent.id();
        const runtime = try alloc.create(Runtime);
        errdefer alloc.destroy(runtime);
        const owned_node = try alloc.dupe(u8, node_id);
        errdefer alloc.free(owned_node);
        runtime.* = .{
            .alloc = alloc,
            .children = options.children,
            .node_id = owned_node,
            .depth = options.depth,
            .tree = options.tree,
            .node_entry = options.node_entry,
            .permission_ceiling = options.permission_ceiling,
            .host_authority = options.host_authority,
            .child_runner = options.child_runner,
            .approvals = &options.tree.approvals,
            .authority_resolver = undefined,
            .managed = undefined,
            .fleet = turn_jobs.Ledger.init(alloc),
        };
        runtime.node_path = options.node_path orelse (&runtime.tree.root_id)[0..1];
        runtime.authority_resolver = .{
            .children = options.children,
            .node_id = runtime.node_id,
            .root_id = options.tree.root_id,
            .child_abilities = tree_mod.Abilities.at(options.tree.policy, options.depth + 1),
            .host = options.host_authority,
        };
        runtime.managed = runtime.managedOwnerValue();
        errdefer runtime.managed.deinit();
        try runtime.managed.recoverInterrupted();
        return runtime;
    }

    /// Runs `visit(context, host)` on the open host of node `id` anywhere in
    /// this tree; that host cannot close until `visit` returns. Null when
    /// the node has no open host: it is not the root and has had no work
    /// lately (D96).
    pub fn withNodeHost(self: *Runtime, id: []const u8, comptime R: type, context: anytype, comptime visit: fn (@TypeOf(context), *Runtime) R) ?R {
        return self.tree.withHost(id, R, context, visit);
    }

    /// The host of `entry`'s node, a child of this node, over the children
    /// in its own log (D22, D96). It may spawn only below the depth limit.
    pub fn openChildHost(self: *Runtime, entry: *node_hosts.Entry) !*Runtime {
        return open(self.alloc, .{
            .children = &entry.children,
            .tree = self.tree,
            .depth = entry.depth,
            .node_path = @ptrCast(entry.path),
            .node_entry = entry,
            // Until the node's own turn is admitted, its children get no
            // wider a mode than this node's.
            .permission_ceiling = self.permission_ceiling,
            .host_authority = self.host_authority,
            .child_runner = self.child_runner,
        });
    }

    /// This node and its tree for recall and the internal URLs read_file
    /// opens. Borrows the runtime.
    pub fn nodeView(self: *Runtime) @import("../recall/recall.zig").NodeView {
        return @import("recall_source.zig").view(self);
    }

    /// Joins every child first, so no node closes while a descendant runs
    /// (`tests/tla/session_manager/Tree.tla` AncestorsOutliveDescendants).
    /// The root host then closes every node host of the tree, deepest
    /// first.
    pub fn deinit(self: *Runtime) void {
        if (self.owns_tree) self.tree.root_host = null;
        self.cancelYielded();
        self.yielded.deinit(self.alloc);
        self.managed.deinit();
        self.fleet.deinit();
        if (self.owns_tree) self.tree.destroy();
        self.alloc.free(self.node_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    /// Whether this node's children or any of their descendants are running,
    /// the check a rewind of this node must pass (D91, D97).
    pub fn subtreeBusy(self: *Runtime) bool {
        return self.managed.anyRunning() or self.tree.nodes.subtreeBusy(self.node_id);
    }

    /// Whether the host may close: no child's work runs and no yielded
    /// result waits for delivery.
    pub fn idle(self: *Runtime) bool {
        if (self.managed.anyRunning()) return false;
        if (self.fleet.active()) return false;
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items) |item| if (!item.delivered) return false;
        return true;
    }

    /// Points the host's callbacks at a host context that moved; the
    /// children stay as they are.
    pub fn rebindHost(
        self: *Runtime,
        child_runner_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        self.host_authority = host_authority;
        self.child_runner.context = child_runner_context;
        self.authority_resolver.children = self.children;
        self.authority_resolver.node_id = self.node_id;
        self.authority_resolver.host = host_authority;
        self.managed.children = self.children;
        self.managed.state_store.children = self.children;
        self.managed.services.context = self;
        self.managed.authority_resolver = &self.authority_resolver;
        self.managed.approvals = self.approvals;
        if (self.owns_tree) self.tree.nodes.rebind(child_runner_context, host_authority);
    }

    /// The oldest approval waiting anywhere in the tree.
    pub fn pendingApprovalRequest(
        self: *Runtime,
        alloc: Allocator,
    ) !?approval_registry.PendingRequest {
        return self.approvals.firstPendingRequest(alloc);
    }

    /// Up to `limit` approvals waiting anywhere in the tree, oldest first,
    /// each naming the path to the node that asked (D93).
    pub fn pendingApprovalRequests(
        self: *Runtime,
        alloc: Allocator,
        limit: usize,
    ) ![]approval_registry.PendingRequest {
        return self.approvals.pendingRequests(alloc, limit);
    }

    pub fn resolveApproval(
        self: *Runtime,
        options: ApprovalResolveOptions,
    ) approval_registry.Error!approval_registry.ResolveResult {
        return switch (try self.approvals.resolve(
            options.request_id,
            options.child_id,
            options.decision,
            options.feedback,
            options.timestamp_ms,
        )) {
            .accepted => .accepted,
            .rejected => .rejected,
        };
    }

    pub fn issueOperationIdentity(
        self: *Runtime,
        invocation_id: []const u8,
    ) u64 {
        _ = self;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("model");
        hash.update(&.{0});
        hash.update(invocation_id);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return std.mem.readInt(u64, digest[0..8], .little) | 1;
    }

    pub fn executeManaged(
        self: *Runtime,
        alloc: Allocator,
        request: *model_contract.Request,
        options: ExecuteOptions,
    ) !ManagedExecutionResult {
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            self.issueOperationIdentity(options.invocation_id);
        const operation_id = try operationIdAlloc(
            alloc,
            options.invocation_id,
            identity_epoch,
        );
        defer alloc.free(operation_id);

        return switch (request.*) {
            .peer_message, .inbox, .peers => @import("mail_ops.zig").execute(self, alloc, request),
            .list, .inspect, .terminate => fleet_host.execute(self, alloc, request, .{
                .operation_id = operation_id,
                .options = options,
                .child_mode = .ask,
                .resolved_model = null,
            }),
            .run, .message, .spawn, .send => blk: {
                // A child is never wider than the node that asks for it.
                const child_mode = authority.admitChildPermission(self.permission_ceiling, options.parent_permission_mode) catch
                    break :blk self.encodeManaged(alloc, .{ .ok = false, .error_code = @tagName(tree_mod.SpawnRefusal.permission_escalation) });
                const resolved_model: ?[]const u8 = switch (try resolveOverrideModel(alloc, request.override(), options)) {
                    .rejected => |failure| break :blk try self.encodeManaged(alloc, failure),
                    .accepted => |model| model,
                };
                if (request.* == .spawn or request.* == .send) break :blk fleet_host.execute(self, alloc, request, .{
                    .operation_id = operation_id,
                    .options = options,
                    .child_mode = child_mode,
                    .resolved_model = resolved_model,
                });
                var admission_arena = std.heap.ArenaAllocator.init(self.alloc);
                defer admission_arena.deinit();
                var queued_receipt: ?ManagedExecutionResult = null;
                defer if (queued_receipt) |queued| alloc.free(queued.body);
                while (true) {
                    _ = admission_arena.reset(.retain_capacity);
                    const admission_alloc = admission_arena.allocator();
                    if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
                    if (self.managed.feedbackReplay(operation_id, model_contract.requestFingerprint(request.*))) |replay| {
                        break :blk try self.encodeManaged(alloc, switch (replay) {
                            .receipt => |delivery| model_contract.feedbackResult(delivery),
                            else => .{ .ok = false, .error_code = "operation_conflict" },
                        });
                    }
                    var admitted = try self.admitAndStartManagedWork(
                        admission_alloc,
                        request.*,
                        operation_id,
                        options,
                        child_mode,
                        resolved_model,
                    );
                    defer admitted.deinit(admission_alloc);
                    switch (admitted) {
                        .feedback => |target| {
                            // Allocate the receipt before handing any text to the worker.
                            if (queued_receipt == null) queued_receipt = try self.encodeManaged(alloc, model_contract.feedbackResult(.queued));
                            const result = steer: {
                                self.admission_mutex.lockUncancelable(io_mod.getIo());
                                defer self.admission_mutex.unlock(io_mod.getIo());
                                if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
                                break :steer try self.managed.steer(target.child_id, target.work_id, operation_id, model_contract.requestFingerprint(request.*), request.message.message);
                            };
                            switch (result) {
                                .receipt => |delivery| {
                                    if (options.observer) |observer| observer.emit(.{ .delegation = .{
                                        .call_id = options.invocation_id,
                                        .child_id = target.child_id,
                                        .work_id = target.work_id,
                                        .operation_id = operation_id,
                                        .phase = switch (delivery) {
                                            .queued => .feedback_queued,
                                            .applied => .feedback_applied,
                                            .not_applied => .feedback_not_applied,
                                        },
                                    } });
                                    if (delivery == .queued) {
                                        const queued = queued_receipt.?;
                                        queued_receipt = null;
                                        break :blk queued;
                                    }
                                    break :blk try self.encodeManaged(alloc, model_contract.feedbackResult(delivery));
                                },
                                .waiting => {
                                    io_mod.sleep(terminal_wait_pulse_ms * std.time.ns_per_ms);
                                    continue;
                                },
                                .unavailable, .cancelled, .conflict, .capacity => break :blk try self.encodeManaged(alloc, .{
                                    .ok = false,
                                    .error_code = switch (result) {
                                        .unavailable => "state_unavailable",
                                        .cancelled => "child_cancelled",
                                        .conflict => "operation_conflict",
                                        .capacity => "feedback_capacity",
                                        else => unreachable,
                                    },
                                }),
                            }
                        },
                        .rejected => |failure| {
                            break :blk self.encodeManaged(alloc, .{
                                .ok = false,
                                .error_code = failure.code,
                            });
                        },
                        .ready => |ready| {
                            if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = ready.child_id, .work_id = operation_id, .phase = .dispatched } });
                            const result = self.observeLendingSlot(
                                alloc,
                                ready.child_id,
                                operation_id,
                                effectiveDefaults(options.defaults, request.override(), resolved_model),
                                options,
                            ) catch |err| {
                                if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = ready.child_id, .work_id = operation_id, .phase = if (err == error.Cancelled) .cancelled else .failed } });
                                return err;
                            };
                            if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = ready.child_id, .work_id = operation_id, .phase = if (result.pending) .yielded else if (result.success) .completed else .failed } });
                            break :blk result;
                        },
                        .completed => |completed| {
                            if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = completed.child_id, .work_id = operation_id, .phase = .replayed } });
                            break :blk self.completeManagedResult(
                                alloc,
                                completed.child_id,
                                operation_id,
                                completed.observation,
                            );
                        },
                    }
                }
            },
        };
    }

    const OverrideModelResolution = union(enum) {
        /// Resolved canonical catalog ID, or null to keep the raw override.
        accepted: ?[]const u8,
        rejected: model_contract.Result,
    };

    /// Resolves a creation-time model override against the model catalog before
    /// any child session exists, so an unknown or ambiguous name fails fast
    /// with actionable guidance instead of dying in the child after a wasted
    /// gateway request. Without a resolver (or a ready catalog) the raw
    /// override passes through and the gateway remains the final arbiter.
    fn resolveOverrideModel(
        alloc: Allocator,
        override: model_contract.Override,
        options: ExecuteOptions,
    ) !OverrideModelResolution {
        var raw_model = override.model orelse return .{ .accepted = null };
        var from_role = false;
        if (raw_model[0] == '@') {
            const roles = options.model_role_resolver orelse return .{ .rejected = .{
                .ok = false,
                .error_code = "unknown_model_role",
                .result = try alloc.dupe(u8, "This host has no model roles; pass a catalog model ID."),
            } };
            switch (roles.resolve_fn(roles.context, raw_model[1..])) {
                .model => |model| {
                    debug_trace.logf("subagent", "model role resolved raw={s} model={s}", .{ raw_model, model });
                    raw_model = model;
                    from_role = true;
                },
                .unknown_role => return .{ .rejected = .{
                    .ok = false,
                    .error_code = "unknown_model_role",
                    .result = try alloc.print("unknown model role '{s}'. Roles: @default, @small, @deep, @worker, @tiny, @review, @title, @compact, @designer, @commit, @advisor.", .{raw_model}),
                } },
                .unavailable => {
                    debug_trace.logf("subagent", "model role unset raw={s}; inheriting model={s}", .{ raw_model, options.defaults.model });
                    return .{ .accepted = options.defaults.model };
                },
            }
        }
        // A role's model is used as given unless the catalog resolves it.
        const passthrough: ?[]const u8 = if (from_role) raw_model else null;
        // Only the gateway catalog is an authoritative model list. Configured
        // providers (OpenAI-compatible endpoints) accept arbitrary model IDs,
        // so overrides for those children pass through to the provider.
        if (options.defaults.provider != .gateway) {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=non_gateway_provider", .{raw_model});
            return .{ .accepted = passthrough };
        }
        const resolver = options.model_override_resolver orelse {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_resolver", .{raw_model});
            return .{ .accepted = passthrough };
        };
        switch (try resolver.resolve(alloc, raw_model)) {
            .no_catalog => {
                debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_catalog", .{raw_model});
                return .{ .accepted = passthrough };
            },
            .matched => |id| {
                if (!std.mem.eql(u8, id, raw_model)) {
                    debug_trace.logf(
                        "subagent",
                        "model override resolved raw={s} resolved={s}",
                        .{ raw_model, id },
                    );
                }
                return .{ .accepted = id };
            },
            .ambiguous => |candidates| {
                debug_trace.logf(
                    "subagent",
                    "model override rejected raw={s} code=ambiguous_model candidates={d}",
                    .{ raw_model, candidates.len },
                );
                return .{ .rejected = .{
                    .ok = false,
                    .error_code = "ambiguous_model",
                    .result = try modelOverrideFailureMessage(alloc, .ambiguous, raw_model, candidates),
                } };
            },
            .unknown => |candidates| {
                debug_trace.logf(
                    "subagent",
                    "model override rejected raw={s} code=unknown_model candidates={d}",
                    .{ raw_model, candidates.len },
                );
                return .{ .rejected = .{
                    .ok = false,
                    .error_code = "unknown_model",
                    .result = try modelOverrideFailureMessage(alloc, .unknown, raw_model, candidates),
                } };
            },
        }
    }

    fn managedOwnerValue(self: *Runtime) managed_owner.Owner {
        return .{
            .alloc = self.alloc,
            .children = self.children,
            .state_store = self.childStateStore(),
            .services = .{
                .context = self,
                .capture_fn = captureAdmission,
                .run_fn = runChild,
                .lease_fn = leaseChildNode,
                .release_fn = releaseChildNode,
            },
            .authority_resolver = &self.authority_resolver,
            .approvals = self.approvals,
            .tree = self.tree,
            .node_path = self.node_path,
            .turn_hook = fleet_host.turnHook(self),
        };
    }

    fn childStateStore(self: *Runtime) child_state.Store {
        return .{ .children = self.children, .parent_id = self.node_id };
    }

    /// Waits on a child with this node's own run slots lent back, so the
    /// child can run however full the pool is (D92). The slots come back
    /// before this node's turn goes on.
    fn observeLendingSlot(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        fallback_defaults: Defaults,
        options: ExecuteOptions,
    ) !ManagedExecutionResult {
        const permit = if (options.lend_turn_slots) self.turn_permit else null;
        if (permit) |held| held.lend();
        var result = self.observeManagedState(
            alloc,
            child_id,
            work_id,
            fallback_defaults,
            options.progress,
            options.cancel_flag,
            options.steering_worker,
            options.model_capability_resolver,
        ) catch |err| {
            if (permit) |held| held.reclaim(.{}) catch {};
            return err;
        };
        if (permit) |held| held.reclaim(.{ .first = options.cancel_flag }) catch {
            alloc.free(result.body);
            if (result.final_status) |status| alloc.free(status.model);
            result = undefined;
            return error.Cancelled;
        };
        return result;
    }

    const ManagedAdmission = union(enum) {
        ready: struct { child_id: []u8 },
        feedback: struct { child_id: []u8, work_id: []u8 },
        completed: struct {
            child_id: []u8,
            observation: managed_owner.Observation,
        },
        rejected: struct {
            child_id: ?[]u8 = null,
            code: []const u8,
        },

        fn deinit(self: *ManagedAdmission, alloc: Allocator) void {
            switch (self.*) {
                .ready => |ready| alloc.free(ready.child_id),
                .feedback => |value| {
                    alloc.free(value.child_id);
                    alloc.free(value.work_id);
                },
                .completed => |completed| alloc.free(completed.child_id),
                .rejected => |failure| if (failure.child_id) |child_id| {
                    alloc.free(child_id);
                },
            }
            self.* = undefined;
        }
    };

    fn admitAndStartManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
        child_mode: types.PermissionMode,
        resolved_model: ?[]const u8,
    ) !ManagedAdmission {
        // A running registry entry must not be exposed before its Slot exists.
        // Release the registry lock before taking the managed-owner lock.
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
        var admitted = try self.admitManagedWork(alloc, request, operation_id, options, child_mode, resolved_model);
        errdefer admitted.deinit(alloc);
        if (admitted == .ready) {
            const child_id = admitted.ready.child_id;
            try self.retainYielded(child_id, operation_id, options.max_result_bytes, if (options.steering_worker != null) 64 else child_state.max_children);
            _ = self.managed.start(child_id) catch |err| {
                debug_trace.eventf("subagent", "steering_wait_registration_dropped", .{}, "child_id={s} work_id={s} reason=start_failed error={s}", .{ child_id, operation_id, @errorName(err) });
                self.removeYielded(child_id, operation_id);
                return err;
            };
        }
        return admitted;
    }

    fn admitManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
        child_mode: types.PermissionMode,
        resolved_model: ?[]const u8,
    ) !ManagedAdmission {
        const fingerprint = model_contract.requestFingerprint(request);
        const defaults = effectiveDefaults(options.defaults, request.override(), resolved_model);
        debug_trace.logf(
            "subagent",
            "admission requested operation={s} action={s} agent={s} override={s}",
            .{
                operation_id,
                @tagName(request.action()),
                request.agentName() orelse "none",
                if (request.override().present()) "yes" else "no",
            },
        );
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        if (registry.findByOperation(operation_id)) |existing| {
            const observed = child_state.Registry.operationFingerprint(
                existing.*,
                operation_id,
            ) orelse return managedAdmissionRejected(
                alloc,
                existing.id,
                "operation_conflict",
            );
            if (!std.mem.eql(u8, &observed, &fingerprint)) {
                debug_trace.logf(
                    "subagent",
                    "admission rejected operation={s} child_id={s} code=operation_conflict",
                    .{ operation_id, existing.id },
                );
                return managedAdmissionRejected(
                    alloc,
                    existing.id,
                    "operation_conflict",
                );
            }
            try self.ensureManagedChildSession(
                existing.id,
                operation_id,
                defaults,
            );
            if (existing.last_work_id) |work_id| {
                if (std.mem.eql(u8, work_id, operation_id)) return .{ .completed = .{
                    .child_id = try alloc.dupe(u8, existing.id),
                    .observation = .{
                        .phase = existing.phase,
                        .outcome = existing.last_outcome,
                        .failure = existing.last_failure,
                    },
                } };
            }
            return managedAdmissionReady(alloc, existing.id);
        }

        var active = try makeManagedWork(
            alloc,
            operation_id,
            fingerprint,
            request,
            options,
            child_mode,
        );
        defer active.deinit(alloc);
        switch (request) {
            .run => {
                if (try self.refuseNewChild(alloc, registry)) |refused| return refused;
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendOneOff(alloc, child_id, active);
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(child_id, active.id, defaults);
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                );
            },
            .message => |message| {
                if (registry.findPersistent(message.agent)) |child| {
                    if (request.override().present()) {
                        debug_trace.logf(
                            "subagent",
                            "admission rejected operation={s} child_id={s} agent={s} code=override_after_create",
                            .{ operation_id, child.id, message.agent },
                        );
                        return managedAdmissionRejected(
                            alloc,
                            child.id,
                            "override_after_create",
                        );
                    }
                    switch (model_contract.plan(request, .{ .kind = .persistent, .phase = child.phase })) {
                        .steer_persistent => {
                            const active_work = child.active orelse return managedAdmissionRejected(alloc, child.id, "state_unavailable");
                            const id = try alloc.dupe(u8, child.id);
                            errdefer alloc.free(id);
                            return .{ .feedback = .{ .child_id = id, .work_id = try alloc.dupe(u8, active_work.id) } };
                        },
                        .reject => |code| return managedAdmissionRejected(alloc, child.id, @tagName(code)),
                        .continue_persistent => {},
                        .create_one_off, .create_persistent => unreachable,
                    }
                    if (self.hasYieldedChild(child.id)) try self.capturePriorYielded(child.*);
                    const started = try registry.startPersistentWork(
                        alloc,
                        message.agent,
                        message.instructions,
                        active,
                    );
                    try self.managed.state_store.save(alloc, registry);
                    // A child lost before its first turn has no log to
                    // resume, so its next work starts it fresh (D33).
                    try self.ensureManagedChildSession(started.id, active.id, defaults);
                    return managedAdmissionReady(alloc, started.id);
                }
                if (try self.refuseNewChild(alloc, registry)) |refused| return refused;
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendPersistent(
                    alloc,
                    child_id,
                    message.agent,
                    message.instructions orelse "",
                    active,
                );
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(child_id, active.id, defaults);
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                );
            },
            .spawn, .send, .list, .inspect, .terminate, .peer_message, .inbox, .peers => unreachable,
        }
    }

    /// The spawn policy's one check for a new child (D91).
    pub fn refuseNewChild(self: *Runtime, alloc: Allocator, registry: child_state.Registry) !?ManagedAdmission {
        const refusal = (try self.tree.admitNode(self.depth, registry.children.len)) orelse return null;
        debug_trace.logf("subagent", "admission rejected node_id={s} depth={d} code={s}", .{ self.node_id, self.depth, @tagName(refusal) });
        return try managedAdmissionRejected(alloc, null, @tagName(refusal));
    }

    pub fn ensureManagedChildSession(
        self: *Runtime,
        child_id: []const u8,
        work_id: []const u8,
        defaults: Defaults,
    ) !void {
        // A child reaches the disk with its first turn, under the id its
        // spawn line names (D34); until then only its settings wait here.
        try self.children.rememberSeed(child_id, .{
            .preferences = .{
                .provider = defaults.provider,
                .model = @constCast(defaults.model),
                .effort = defaults.effort,
                .fast_mode = defaults.fast_mode,
                .ultrafast_mode = defaults.ultrafast_mode,
            },
            .language = defaults.conversation_language,
        });
        debug_trace.logf(
            "subagent",
            "child session reserved child_id={s} work_id={s} provider={s} model={s} effort={s} fast_mode={} ultrafast_mode={}",
            .{ child_id, work_id, @tagName(defaults.provider), defaults.model, defaults.effort.label(), defaults.fast_mode, defaults.ultrafast_mode },
        );
    }

    fn observeManagedState(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        fallback_defaults: Defaults,
        progress: ?ProgressSink,
        cancel_flag: ?*std.atomic.Value(bool),
        steering_worker: ?*worker_runtime.WorkerRuntime,
        model_capability_resolver: ?model_capabilities.Resolver,
    ) !ManagedExecutionResult {
        var status = self.startStatusPublisher(alloc, child_id, fallback_defaults, progress, model_capability_resolver) catch StatusPublisher{
            .model = fallback_defaults.model,
            .effort = fallback_defaults.effort,
        };
        defer status.deinit(alloc);
        // A caller with no steering worker never takes a yielded result
        // later, so a wait that ends without one leaves nothing to deliver
        // and the host can go idle (D96).
        errdefer if (steering_worker == null) self.removeYielded(child_id, work_id);
        status.tick(.{}, io_mod.milliTimestamp());
        while (true) {
            if (cancel_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    debug_trace.eventf("subagent", "parent_cancel_propagated", .{}, "child_id={s} work_id={s}", .{ child_id, work_id });
                    // The child cancels its own children the same way and
                    // joins them, so the subtree stops deepest first.
                    self.managed.cancelAndJoin(child_id);
                    return error.Cancelled;
                }
            }
            if (try self.takeCapturedResult(alloc, child_id, work_id)) |result| return result;
            const observation = self.managed.wait(child_id, .{
                .clock = .awake,
                .raw = .fromMilliseconds(terminal_wait_pulse_ms),
            }) catch |err| {
                if (try self.takeCapturedResult(alloc, child_id, work_id)) |result| return result;
                if (!self.managed.hasRunningChild(child_id)) {
                    // A timed-out observation can leave a completed slot to drain.
                    self.managed.cancelAndJoin(child_id);
                    debug_trace.eventf("subagent", "steering_wait_registration_dropped", .{}, "child_id={s} work_id={s} reason=observation_failed_no_runner error={s}", .{ child_id, work_id, @errorName(err) });
                    self.removeYielded(child_id, work_id);
                } else if (steering_worker == null) self.removeYielded(child_id, work_id);
                return self.encodeManaged(alloc, .{
                    .ok = false,
                    .error_code = switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ChildUnavailable => "child_unavailable",
                        error.StateUnavailable => "state_unavailable",
                    },
                });
            };
            if (try self.takeCapturedResult(alloc, child_id, work_id)) |result| return result;
            switch (observation.phase) {
                .running, .awaiting_approval => {
                    status.tick(observation.metrics, io_mod.milliTimestamp());
                    if (steering_worker) |worker| {
                        if (worker.hasPendingPlainSteering()) {
                            debug_trace.eventf("subagent", "steering_wait_yielded", .{}, "child_id={s} work_id={s} child_cancelled=false", .{ child_id, work_id });
                            const pending_text = try alloc.print("{s}\nchild_id={s} work_id={s}", .{ model_contract.steering_pending_result, child_id, work_id });
                            defer alloc.free(pending_text);
                            var pending = try self.encodeManaged(alloc, .{ .ok = true, .pending = true, .result = pending_text });
                            if (status.sink != null) attachStatusPresentation(alloc, &pending, status.current(observation.metrics));
                            return pending;
                        }
                    }
                    continue;
                },
                .idle, .finished, .interrupted => {},
            }
            var result = try self.completeManagedResult(alloc, child_id, work_id, observation);
            if (status.sink != null) attachStatusPresentation(alloc, &result, status.current(observation.metrics));
            self.removeYielded(child_id, work_id);
            return result;
        }
    }

    fn hasYieldedChild(self: *Runtime, child_id: []const u8) bool {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items) |item| if (!item.delivered and std.mem.eql(u8, item.child_id, child_id)) return true;
        return false;
    }

    // Registry is held by admission. Preserve the old work's result before a
    // newer generation can become observable through this child ID.
    fn capturePriorYielded(self: *Runtime, child: child_state.Child) !void {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items) |*item| {
            if (item.delivered or item.result != null or !std.mem.eql(u8, item.child_id, child.id)) continue;
            if (!std.mem.eql(u8, item.work_id, child.last_work_id orelse return error.StaleWork)) return error.StaleWork;
            item.result = try self.completeManagedResult(self.alloc, child.id, item.work_id, .{
                .phase = child.phase,
                .outcome = child.last_outcome,
                .failure = child.last_failure,
            });
        }
    }

    fn takeCapturedResult(self: *Runtime, alloc: Allocator, child_id: []const u8, work_id: []const u8) !?ManagedExecutionResult {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.child_id, child_id) or !std.mem.eql(u8, item.work_id, work_id)) continue;
            const stored = item.result orelse return null;
            const result = ManagedExecutionResult{ .success = stored.success, .body = try alloc.dupe(u8, stored.body) };
            _ = self.yielded.orderedRemove(index);
            self.alloc.free(item.child_id);
            self.alloc.free(item.work_id);
            self.alloc.free(stored.body);
            return result;
        }
        return null;
    }

    fn retainYielded(self: *Runtime, child_id: []const u8, work_id: []const u8, max_result_bytes: usize, capacity: usize) !void {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items) |item| if (std.mem.eql(u8, item.work_id, work_id)) return;
        if (self.yielded.items.len >= capacity) return error.TooManyYieldedChildren;
        const child = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(child);
        const work = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(work);
        try self.yielded.append(self.alloc, .{ .child_id = child, .work_id = work, .max_result_bytes = max_result_bytes });
        debug_trace.eventf("subagent", "steering_wait_registered", .{}, "child_id={s} work_id={s} tracked={d}", .{ child_id, work_id, self.yielded.items.len });
    }

    /// Main-loop-only; callers finish tool dispatch before inspecting completions.
    /// Returned values belong to arena. Acknowledged results remain context until
    /// the main execution ends; they are not delivered as a second tool response.
    pub fn prepareYielded(self: *Runtime, arena: Allocator) ![]YieldedResult {
        var results: std.ArrayList(YieldedResult) = .empty;
        for (self.yielded.items) |*item| {
            if (item.result == null) {
                const state = try self.managed.wait(item.child_id, .{ .clock = .awake, .raw = .fromMilliseconds(0) });
                if (state.phase == .running or state.phase == .awaiting_approval) continue;
                item.result = try self.completeManagedResult(self.alloc, item.child_id, item.work_id, state);
                debug_trace.eventf("subagent", "steering_result_captured", .{}, "child_id={s} work_id={s} phase={s} result_bytes={d}", .{ item.child_id, item.work_id, @tagName(state.phase), item.result.?.body.len });
            }
            try results.append(arena, .{
                .child_id = try arena.dupe(u8, item.child_id),
                .work_id = try arena.dupe(u8, item.work_id),
                .body = try arena.dupe(u8, item.result.?.body),
                .max_result_bytes = item.max_result_bytes,
                .delivered = item.delivered,
            });
        }
        for (try self.managed.feedbackUpdates(arena)) |update| {
            try results.append(arena, .{
                .child_id = update.child_id,
                .work_id = update.operation_id,
                .body = try model_contract.encodeResultAlloc(arena, model_contract.feedbackResult(update.delivery)),
                .max_result_bytes = tool_result_limits.min_configured_tool_result_bytes,
                .delivered = false,
                .receipt_sequence = @as(u64, @backingInt(update.delivery)) + 1,
            });
        }
        return results.toOwnedSlice(arena);
    }

    pub fn acknowledgeFeedback(self: *Runtime, child_id: []const u8, operation_id: []const u8, sequence: u64) void {
        const delivery = std.enums.fromInt(types.SteeringDelivery, sequence -| 1) orelse return;
        self.managed.acknowledgeFeedback(child_id, operation_id, delivery);
    }

    pub fn acknowledgeYielded(self: *Runtime, child_id: []const u8, work_id: []const u8) void {
        for (self.yielded.items) |*item| {
            if (item.delivered or !std.mem.eql(u8, item.child_id, child_id) or !std.mem.eql(u8, item.work_id, work_id)) continue;
            item.delivered = true;
            debug_trace.eventf("subagent", "steering_result_delivered", .{}, "child_id={s} work_id={s}", .{ child_id, work_id });
            return;
        }
    }

    fn removeYielded(self: *Runtime, child_id: []const u8, work_id: []const u8) void {
        self.yielded_mutex.lockUncancelable(io_mod.getIo());
        defer self.yielded_mutex.unlock(io_mod.getIo());
        for (self.yielded.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.child_id, child_id) or !std.mem.eql(u8, item.work_id, work_id)) continue;
            _ = self.yielded.orderedRemove(index);
            self.alloc.free(item.child_id);
            self.alloc.free(item.work_id);
            if (item.result) |result| self.alloc.free(result.body);
            return;
        }
    }

    /// Main-loop-only after tool dispatch drains; completed but undelivered work counts.
    pub fn hasPendingYielded(self: *const Runtime) bool {
        for (self.yielded.items) |item| {
            if (!item.delivered) return true;
        }
        return false;
    }

    pub fn waitYielded(self: *Runtime, worker: *worker_runtime.WorkerRuntime) !bool {
        if (!self.hasPendingYielded()) return false;
        debug_trace.eventf("subagent", "steering_parent_waiting", .{}, "pending={d}", .{self.yielded.items.len});
        while (true) {
            const cancelled = worker.worker_cancel_requested.load(.seq_cst);
            const steering = worker.hasPendingPlainSteering();
            if (cancelled or steering) {
                debug_trace.eventf("subagent", "steering_parent_woken", .{ .turn_id = worker.activeTurnId() }, "cancel_requested={} plain_steering={}", .{ cancelled, steering });
                return true;
            }
            for (self.yielded.items) |item| {
                if (item.delivered) continue;
                const state = try self.managed.wait(item.child_id, .{ .clock = .awake, .raw = .fromMilliseconds(0) });
                if (state.phase != .running and state.phase != .awaiting_approval) {
                    debug_trace.eventf("subagent", "steering_parent_woken", .{ .turn_id = worker.activeTurnId() }, "child_id={s} work_id={s} phase={s}", .{ item.child_id, item.work_id, @tagName(state.phase) });
                    return true;
                }
            }
            io_mod.sleep(terminal_wait_pulse_ms * std.time.ns_per_ms);
        }
    }

    /// Drain before the main execution releases context borrowed by child runners.
    pub fn cancelYielded(self: *Runtime) void {
        for (self.yielded.items) |item| {
            if (item.delivered) continue;
            self.managed.cancel(item.child_id) catch |err| debug_trace.logf("subagent", "steering cancellation child_id={s} error={s}", .{ item.child_id, @errorName(err) });
        }
        for (self.yielded.items) |item| {
            if (!item.delivered) self.managed.cancelAndJoin(item.child_id);
            if (item.result) |result| self.alloc.free(result.body);
            debug_trace.eventf("subagent", "steering_continuation_released", .{}, "child_id={s} work_id={s} delivered={} reason=parent_turn_end", .{ item.child_id, item.work_id, item.delivered });
            self.alloc.free(item.child_id);
            self.alloc.free(item.work_id);
        }
        self.yielded.clearRetainingCapacity();
    }

    pub fn completeManagedResult(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        observation: managed_owner.Observation,
    ) !ManagedExecutionResult {
        const result = try self.managedResultText(alloc, child_id, work_id);
        defer if (result) |text| alloc.free(text);
        const failure_text = if (observation.outcome == .failed)
            try formatFailedResult(alloc, if (observation.failure) |*failure| failure.view() else null, result)
        else
            null;
        defer if (failure_text) |text| alloc.free(text);
        const capped = try self.capResult(alloc, work_id, failure_text orelse result);
        defer if (capped) |text| alloc.free(text);
        return self.encodeManaged(alloc, terminalResult(observation, capped orelse failure_text orelse result));
    }

    /// A long result keeps its start and a handle to the whole text, saved
    /// with this node's session (D94). Null keeps `text` as it is.
    fn capResult(self: *Runtime, alloc: Allocator, work_id: []const u8, text: ?[]const u8) !?[]u8 {
        const full = text orelse return null;
        if (full.len <= max_inline_result_bytes) return null;
        const head = text_utils.utf8PrefixByBytes(full, max_inline_result_bytes);
        const handle = self.storeFullResult(alloc, work_id, full) catch |err| {
            debug_trace.logf("subagent", "full result not stored node_id={s} work_id={s} err={s}", .{ self.node_id, work_id, @errorName(err) });
            return try alloc.print("{s}\n\n[Subagent result truncated: {d} of {d} bytes shown. The full text could not be stored.]", .{ head, head.len, full.len });
        };
        defer alloc.free(handle);
        return try alloc.print(
            "{s}\n\n[Subagent result truncated: {d} of {d} bytes shown. Read the rest with read_tool_result, handle \"{s}\".]",
            .{ head, head.len, full.len, handle },
        );
    }

    pub fn storeFullResult(self: *Runtime, alloc: Allocator, work_id: []const u8, full: []const u8) ![]u8 {
        const capability = try self.children.parent.childCapability();
        return result_store.storeLargeResultManaged(alloc, capability, work_id, tree_mod.spawn_tool_name, full);
    }

    fn managedResultText(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
    ) !?[]u8 {
        const history = self.children.parent.store.childHistory(alloc, child_id) catch return null;
        defer types.freeHistoryTurnSlice(alloc, history);
        const text = assistantTextForWork(history, work_id) orelse return null;
        return @as(?[]u8, try alloc.dupe(u8, text));
    }

    /// A child's saved preferences, read without opening it. Caller owns.
    fn childPreferences(self: *Runtime, alloc: Allocator, child_id: []const u8) !session_codec.DurableSessionPreferences {
        return self.children.parent.store.childPreferences(alloc, child_id);
    }

    fn encodeManaged(
        self: *Runtime,
        alloc: Allocator,
        result: model_contract.Result,
    ) !ManagedExecutionResult {
        _ = self;
        return .{
            .success = result.ok,
            .pending = result.pending,
            .body = try model_contract.encodeResultAlloc(alloc, result),
        };
    }

    fn startStatusPublisher(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        fallback: Defaults,
        sink: ?ProgressSink,
        model_capability_resolver: ?model_capabilities.Resolver,
    ) Allocator.Error!StatusPublisher {
        var model: []u8 = undefined;
        var effort: types.ReasoningEffort = undefined;
        if (self.childPreferences(alloc, child_id)) |loaded| {
            var preferences = loaded;
            defer preferences.deinit(alloc);
            model = try alloc.dupe(u8, preferences.model);
            effort = preferences.effort;
        } else |err| {
            debug_trace.eventf("subagent", "status_publisher_fallback", .{}, "child_id={s} reason=session_load_failed error={s}", .{ child_id, @errorName(err) });
            model = try alloc.dupe(u8, fallback.model);
            effort = fallback.effort;
        }
        var context_window: ?u32 = null;
        if (model_capability_resolver) |resolver| {
            var resolve_arena = std.heap.ArenaAllocator.init(alloc);
            defer resolve_arena.deinit();
            if (resolver.resolve(resolve_arena.allocator(), model)) |caps| {
                context_window = caps.context_window;
            } else |_| {}
        }
        return .{
            .sink = sink,
            .model = model,
            .owns_model = true,
            .effort = effort,
            .context_window = context_window,
        };
    }
};

const StatusPublisher = struct {
    sink: ?ProgressSink = null,
    model: []const u8,
    owns_model: bool = false,
    effort: types.ReasoningEffort,
    context_window: ?u32 = null,
    last_publish_ms: ?i64 = null,
    last_metrics: ?live_metrics.Snapshot = null,

    fn deinit(self: *StatusPublisher, alloc: Allocator) void {
        if (self.owns_model) alloc.free(@constCast(self.model));
        self.* = undefined;
    }

    fn current(self: *const StatusPublisher, metrics: live_metrics.Snapshot) types.SubagentStatus {
        return .{
            .model = self.model,
            .effort = self.effort,
            .input_tokens = metrics.input_tokens,
            .context_window = self.context_window,
        };
    }

    fn tick(self: *StatusPublisher, metrics: live_metrics.Snapshot, now_ms: i64) void {
        const changed = if (self.last_metrics) |last| !std.meta.eql(metrics, last) else true;
        if (!shouldPublish(self.last_publish_ms, now_ms, changed)) return;
        if (self.sink) |sink| sink.publish(self.current(metrics));
        self.last_publish_ms = now_ms;
        self.last_metrics = metrics;
    }
};

fn attachStatusPresentation(
    alloc: Allocator,
    result: *ManagedExecutionResult,
    status: types.SubagentStatus,
) void {
    const model = alloc.dupe(u8, status.model) catch return;
    result.final_status = .{
        .model = model,
        .effort = status.effort,
        .input_tokens = status.input_tokens,
        .context_window = status.context_window,
    };
}

const status_min_publish_interval_ms: i64 = 250;

fn shouldPublish(last_publish_ms: ?i64, now_ms: i64, changed: bool) bool {
    const last = last_publish_ms orelse return true;
    if (now_ms < last) return false;
    return changed and now_ms - last >= status_min_publish_interval_ms;
}

fn operationIdAlloc(
    alloc: Allocator,
    invocation_id: []const u8,
    epoch: u64,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(invocation_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.print("fxop:2:m:{d}:{s}", .{ epoch, &hex });
}

fn checkYieldedOwnership(alloc: Allocator) !void {
    var runtime = Runtime{ .alloc = alloc, .children = undefined, .node_id = undefined, .tree = undefined, .host_authority = undefined, .child_runner = undefined, .approvals = undefined, .authority_resolver = undefined, .managed = undefined, .fleet = .init(alloc) };
    runtime.managed = .{ .alloc = alloc, .children = undefined, .state_store = undefined, .services = undefined, .authority_resolver = undefined, .approvals = undefined };
    defer runtime.yielded.deinit(alloc);
    defer while (runtime.yielded.items.len > 0) {
        const item = runtime.yielded.items[0];
        runtime.removeYielded(item.child_id, item.work_id);
    };
    try std.testing.expect(!runtime.hasPendingYielded());
    try runtime.retainYielded("child", "work", 4096, 64);
    try runtime.retainYielded("child", "work", 4096, 64);
    try std.testing.expect(runtime.hasPendingYielded());
    try std.testing.expectEqual(@as(usize, 1), runtime.yielded.items.len);
    runtime.acknowledgeYielded("other", "work");
    try std.testing.expect(runtime.hasYieldedChild("child"));
    runtime.yielded.items[0].result = .{ .success = true, .body = try alloc.dupe(u8, "saved result") };
    runtime.acknowledgeYielded("child", "work");
    try std.testing.expect(!runtime.hasYieldedChild("child"));
    try std.testing.expect(!runtime.hasPendingYielded());
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const retained = try runtime.prepareYielded(arena.allocator());
    try std.testing.expect(retained[0].delivered);
    try std.testing.expectEqualStrings("saved result", retained[0].body);
}

test "subagent yielded identity is owned and allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, checkYieldedOwnership, .{});
}

test "subagent admission preserves an undelivered result before advancing its child" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("old task"), .work_id = @constCast("old-work") },
        .assistant = @constCast("ORIGINAL_RESULT"),
    } }};
    (try parent.openChild("frozen-child", &history)).close();
    var runtime = Runtime{ .alloc = alloc, .children = &parent.children, .node_id = undefined, .tree = undefined, .host_authority = undefined, .child_runner = undefined, .approvals = undefined, .authority_resolver = undefined, .managed = undefined, .fleet = .init(alloc) };
    defer runtime.yielded.deinit(alloc);
    try runtime.retainYielded("frozen-child", "old-work", 4096, 64);
    defer runtime.removeYielded("frozen-child", "old-work");
    var child = child_state.Child{ .id = @constCast("frozen-child"), .kind = .{ .persistent = .{ .agent = @constCast("reviewer"), .instructions = &.{} } }, .phase = .idle, .last_work_id = @constCast("old-work"), .last_outcome = .completed };
    try runtime.capturePriorYielded(child);
    const original = try alloc.dupe(u8, runtime.yielded.items[0].result.?.body);
    defer alloc.free(original);
    try std.testing.expect(std.mem.find(u8, original, "ORIGINAL_RESULT") != null);
    child.last_work_id = @constCast("new-work");
    try runtime.capturePriorYielded(child);
    try std.testing.expectEqualStrings(original, runtime.yielded.items[0].result.?.body);
    const captured = (try runtime.takeCapturedResult(alloc, "frozen-child", "old-work")).?;
    defer alloc.free(captured.body);
    try std.testing.expect(captured.success);
    try std.testing.expectEqualStrings(original, captured.body);
    try std.testing.expect((try runtime.takeCapturedResult(alloc, "frozen-child", "old-work")) == null);
    try runtime.retainYielded("frozen-child", "old-work", 4096, 64);
    try std.testing.expectError(error.StaleWork, runtime.capturePriorYielded(child));
}

test "parallel subagent wait bookkeeping stays serialized" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{ .alloc = alloc, .children = undefined, .node_id = undefined, .tree = undefined, .host_authority = undefined, .child_runner = undefined, .approvals = undefined, .authority_resolver = undefined, .managed = undefined, .fleet = .init(alloc) };
    defer runtime.yielded.deinit(alloc);
    const Writer = struct {
        runtime: *Runtime,
        id: []const u8,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            for (0..100) |_| {
                self.runtime.retainYielded(self.id, self.id, 4096, 64) catch |err| {
                    self.failure = err;
                    return;
                };
                self.runtime.removeYielded(self.id, self.id);
            }
        }
    };
    var first = Writer{ .runtime = &runtime, .id = "first" };
    var second = Writer{ .runtime = &runtime, .id = "second" };
    const a = try std.Thread.spawn(.{}, Writer.run, .{&first});
    var joined = false;
    defer if (!joined) a.join();
    const b = try std.Thread.spawn(.{}, Writer.run, .{&second});
    b.join();
    a.join();
    joined = true;
    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.yielded.items.len);
}

test "subagent feedback waits for admitted work to install its worker" {
    const Fixture = struct {
        release: std.Io.Event = .unset,
        runs: usize = 0,
        consumed: usize = 0,

        fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
            return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
        }

        fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.runs += 1;
            if (!turn.worker.beginDirectProcessing(1)) return error.ProviderFailed;
            self.release.waitUncancelable(io_mod.getIo());
            var arena = std.heap.ArenaAllocator.init(turn.alloc);
            defer arena.deinit();
            const feedback = try turn.worker.takeSteeringBoundaryInto(turn.alloc, arena.allocator(), 1, .model);
            self.consumed = if (feedback == .continue_turn) feedback.continue_turn.len else 0;
            turn.commit(turn.active_work_id.?, .{ .assistant = .{
                .user = .{ .text = message.content },
                .assistant = @constCast("ORIGINAL_RESULT"),
            } }) catch return error.ProviderFailed;
            return .completed;
        }
    };
    const Call = struct {
        runtime: *Runtime,
        text: []const u8,
        entered: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        result: ?ManagedExecutionResult = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.entered.set(io_mod.getIo());
            defer self.done.set(io_mod.getIo());
            self.result = self.execute() catch |err| {
                self.failure = err;
                return;
            };
        }

        fn execute(self: *@This()) !ManagedExecutionResult {
            var request = try model_contract.validateRequest(self.runtime.alloc, .{ .message = .{ .agent = "reviewer", .message = self.text } });
            defer request.deinit(self.runtime.alloc);
            return self.runtime.executeManaged(self.runtime.alloc, &request, .{
                .invocation_id = self.text,
                .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
                .max_result_bytes = 4096,
                .timestamp_ms = 1,
            });
        }
    };
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = Fixture{};
    const runtime = try Runtime.create(alloc, &parent.children, .{ .resolve_fn = Fixture.resolve }, .{ .context = &fixture, .run_fn = Fixture.run });
    defer runtime.deinit();
    var first = Call{ .runtime = runtime, .text = "original task" };
    var second = Call{ .runtime = runtime, .text = "parent feedback" };
    var first_thread: ?std.Thread = null;
    var second_thread: ?std.Thread = null;
    runtime.yielded_mutex.lockUncancelable(io_mod.getIo());
    var held = true;
    defer {
        if (held) runtime.yielded_mutex.unlock(io_mod.getIo());
        fixture.release.set(io_mod.getIo());
        if (first_thread) |thread| thread.join();
        if (second_thread) |thread| thread.join();
        if (first.result) |result| alloc.free(result.body);
        if (second.result) |result| alloc.free(result.body);
    }
    first_thread = try std.Thread.spawn(.{}, Call.run, .{&first});
    // Hold result registration after durable admission, before Slot publication.
    var admitted = false;
    for (0..1000) |_| {
        admitted = blk: {
            var lock = runtime.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try runtime.managed.state_store.load(alloc);
            defer registry.deinit(alloc);
            break :blk registry.findPersistent("reviewer") != null;
        };
        if (admitted) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(admitted);
    second_thread = try std.Thread.spawn(.{}, Call.run, .{&second});
    try second.entered.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try std.testing.expectError(error.Timeout, second.done.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(100) } }));
    runtime.yielded_mutex.unlock(io_mod.getIo());
    held = false;
    try second.done.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try std.testing.expect(second.failure == null);
    const expected = try model_contract.encodeResultAlloc(alloc, model_contract.feedbackResult(.queued));
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, second.result.?.body);
    fixture.release.set(io_mod.getIo());
    try first.done.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try std.testing.expect(first.failure == null);
    try std.testing.expect(first.result.?.success);
    try std.testing.expect(std.mem.find(u8, first.result.?.body, "ORIGINAL_RESULT") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs);
    try std.testing.expectEqual(@as(usize, 1), fixture.consumed);
}

fn checkFailedStartBookkeeping(action: model_contract.Action) !void {
    const Fixture = struct {
        runs: std.atomic.Value(usize) = .init(0),

        fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
            return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
        }

        fn run(raw: ?*anyopaque, _: *execution.TurnContext, _: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.runs.fetchAdd(1, .seq_cst);
            return error.ProviderFailed;
        }
    };
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = Fixture{};
    const runtime = try Runtime.create(alloc, &parent.children, .{ .resolve_fn = Fixture.resolve }, .{ .context = &fixture, .run_fn = Fixture.run });
    defer runtime.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    runtime.managed.closed = true;
    try runtime.retainYielded("other-child", "other-work", 2048, 64);

    var request = try model_contract.validateRequest(alloc, switch (action) {
        .run => .{ .run = .{ .task = "review this" } },
        .message => .{ .message = .{ .agent = "reviewer", .message = "review this" } },
        else => unreachable,
    });
    defer request.deinit(alloc);
    const options = ExecuteOptions{
        .invocation_id = "failed-start",
        .identity_epoch = 1,
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .steering_worker = &worker,
    };
    try std.testing.expectError(error.OwnerClosed, runtime.executeManaged(alloc, &request, options));
    try std.testing.expectEqual(@as(usize, 0), runtime.managed.slots.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.runs.load(.seq_cst));

    const work_id = try operationIdAlloc(alloc, options.invocation_id, options.identity_epoch);
    defer alloc.free(work_id);
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), registry.children.len);
    const child = registry.findByOperation(work_id).?;
    try std.testing.expectEqual(child_state.Phase.running, child.phase);
    // The child is reserved: its settings wait for its first turn (D34).
    var seed = (try parent.children.seedFor(alloc, child.id)).?;
    defer seed.preferences.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), runtime.yielded.items.len);
    try std.testing.expect(!runtime.hasYieldedChild(child.id));
    const retained = runtime.yielded.items[0];
    try std.testing.expectEqualStrings("other-child", retained.child_id);
    try std.testing.expectEqualStrings("other-work", retained.work_id);
    try std.testing.expectEqual(@as(usize, 2048), retained.max_result_bytes);
    try std.testing.expect(!retained.delivered);
    if (action == .message) {
        var feedback_options = options;
        feedback_options.invocation_id = "feedback-after-failed-start";
        const feedback = try runtime.executeManaged(alloc, &request, feedback_options);
        defer alloc.free(feedback.body);
        const expected = try model_contract.encodeResultAlloc(alloc, .{ .ok = false, .error_code = "state_unavailable" });
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, feedback.body);
    }
    runtime.removeYielded("other-child", "other-work");
    // Keep the regression bounded even when failed starts leave pending work.
    try std.testing.expectEqual(@as(usize, 0), runtime.yielded.items.len);
    try std.testing.expect(!try runtime.waitYielded(&worker));
}

test "subagent failed start removes only its pending tuple for run" {
    try checkFailedStartBookkeeping(.run);
}

test "subagent failed start removes only its pending tuple for message" {
    try checkFailedStartBookkeeping(.message);
}

test "subagent status publisher carries actual child facts and throttles unchanged metrics" {
    const Capture = struct {
        statuses: std.ArrayList(types.SubagentStatus) = .empty,

        fn publish(raw: *anyopaque, status: types.SubagentStatus) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.statuses.append(std.testing.allocator, status) catch {};
        }
    };
    var capture = Capture{};
    defer capture.statuses.deinit(std.testing.allocator);
    var publisher = StatusPublisher{
        .sink = .{ .context = &capture, .publish_fn = Capture.publish },
        .model = try std.testing.allocator.dupe(u8, "openai/gpt-5.5"),
        .owns_model = true,
        .effort = types.ReasoningEffort.literal("high"),
        .context_window = 100_000,
    };
    defer publisher.deinit(std.testing.allocator);

    publisher.tick(.{ .input_tokens = 12_000 }, 1_000);
    publisher.tick(.{ .input_tokens = 12_000 }, 2_000);
    publisher.tick(.{ .input_tokens = 13_000 }, 2_001);
    publisher.tick(.{ .input_tokens = 13_000 }, 2_250);

    try std.testing.expectEqual(@as(usize, 2), capture.statuses.items.len);
    try std.testing.expectEqualStrings("openai/gpt-5.5", capture.statuses.items[1].model);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), capture.statuses.items[1].effort);
    try std.testing.expectEqual(@as(u64, 13_000), capture.statuses.items[1].input_tokens);
    try std.testing.expectEqual(@as(?u32, 100_000), capture.statuses.items[1].context_window);
}

test "internal operation identity is deterministic and invocation-bound" {
    const alloc = std.testing.allocator;
    const first = try operationIdAlloc(alloc, "call-1", 41);
    defer alloc.free(first);
    const replay = try operationIdAlloc(alloc, "call-1", 41);
    defer alloc.free(replay);
    const changed = try operationIdAlloc(alloc, "call-2", 41);
    defer alloc.free(changed);
    try std.testing.expectEqualStrings(first, replay);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
    try std.testing.expect(std.mem.startsWith(u8, first, "fxop:2:m:41:"));
}

test "creation defaults keep parent values unless the request overrides them" {
    const parent = Defaults{
        .provider = .gateway,
        .model = "parent-model",
        .effort = .auto,
        .conversation_language = session.ConversationLanguage.default(),
    };
    const inherited = effectiveDefaults(parent, .{}, null);
    try std.testing.expectEqualStrings("parent-model", inherited.model);
    try std.testing.expect(inherited.effort.isDefault());
    const overridden = effectiveDefaults(parent, .{
        .model = "gpt-5.6-sol-fast",
        .effort = types.ReasoningEffort.parse("medium"),
    }, null);
    try std.testing.expectEqualStrings("gpt-5.6-sol-fast", overridden.model);
    try std.testing.expectEqualStrings("medium", overridden.effort.label());
    try std.testing.expectEqual(parent.provider, overridden.provider);
    // Model-only and effort-only overrides leave the other value inherited.
    const model_only = effectiveDefaults(parent, .{ .model = "other-model" }, null);
    try std.testing.expectEqualStrings("other-model", model_only.model);
    try std.testing.expect(model_only.effort.isDefault());
    // A catalog-resolved model wins over the raw override text.
    const resolved = effectiveDefaults(parent, .{ .model = "terra-fast" }, "openai/gpt-5.6-terra-fast");
    try std.testing.expectEqualStrings("openai/gpt-5.6-terra-fast", resolved.model);
    // Without an override there is nothing to resolve.
    const no_override = effectiveDefaults(parent, .{}, "openai/gpt-5.6-terra-fast");
    try std.testing.expectEqualStrings("parent-model", no_override.model);
}

const OverrideResolverFixture = struct {
    runs: usize = 0,
    observed_model: ?[]u8 = null,
    catalog: []const []const u8 = &.{ "openai/gpt-5.6-terra", "openai/gpt-5.6-terra-fast", "openai/gpt-6-astra" },

    fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
        return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.runs += 1;
        var preferences = turn.child.currentPreferences(std.testing.allocator) catch return error.ProviderFailed;
        defer preferences.deinit(std.testing.allocator);
        self.observed_model = std.testing.allocator.dupe(u8, preferences.model) catch return error.ProviderFailed;
        if (!turn.worker.beginDirectProcessing(1)) return error.ProviderFailed;
        turn.commit(turn.active_work_id.?, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = @constCast("CHILD_OK"),
        } }) catch return error.ProviderFailed;
        return .completed;
    }

    fn resolveModel(raw: ?*anyopaque, alloc: Allocator, raw_model: []const u8) Allocator.Error!model_contract.ModelCatalogMatch {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return model_contract.matchCatalogModel(alloc, self.catalog, raw_model);
    }
};

fn overrideResolverFixtureRuntime(
    alloc: Allocator,
    fixture: *OverrideResolverFixture,
    parent: *child_state.TestParent,
) !*Runtime {
    return Runtime.create(alloc, &parent.children, .{ .resolve_fn = OverrideResolverFixture.resolve }, .{ .context = fixture, .run_fn = OverrideResolverFixture.run });
}

test "model override resolves against the catalog before child creation" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    var request = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "probe", .model = "terra-fast" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .invocation_id = "override-resolve",
        .defaults = .{ .provider = .gateway, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    });

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.find(u8, result.body, "CHILD_OK") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs);
    try std.testing.expectEqualStrings("openai/gpt-5.6-terra-fast", fixture.observed_model.?);
}

test "unknown and ambiguous model overrides reject before any child session" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const options = ExecuteOptions{
        .invocation_id = "override-reject",
        .defaults = .{ .provider = .gateway, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    };

    var unknown = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "probe", .model = "skldjf" } });
    defer unknown.deinit(alloc);
    const unknown_result = try runtime.executeManaged(arena, &unknown, options);
    try std.testing.expect(!unknown_result.success);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "\"error_code\":\"unknown_model\"") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "skldjf") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "omit model to inherit") != null);

    var ambiguous = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "probe", .model = "terra" } });
    defer ambiguous.deinit(alloc);
    const ambiguous_result = try runtime.executeManaged(arena, &ambiguous, options);
    try std.testing.expect(!ambiguous_result.success);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "\"error_code\":\"ambiguous_model\"") != null);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "openai/gpt-5.6-terra") != null);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "openai/gpt-5.6-terra-fast") != null);

    // Rejections never created or ran a child.
    try std.testing.expectEqual(@as(usize, 0), fixture.runs);
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), registry.children.len);
}

test "model override passes through for non-gateway providers" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    var request = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "probe", .model = "unknown-model" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .invocation_id = "override-non-gateway",
        .defaults = .{ .provider = .codex, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    });

    // The configured provider accepts arbitrary model IDs, so the raw override
    // reaches the child even though the gateway catalog lacks it.
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs);
    try std.testing.expectEqualStrings("unknown-model", fixture.observed_model.?);
}

const RoleResolverFixture = struct {
    fn resolve(_: ?*anyopaque, name: []const u8) ModelRoleResolver.Lookup {
        if (std.mem.eql(u8, name, "worker")) return .{ .model = "cento-worker" };
        if (std.mem.eql(u8, name, "small")) return .unavailable;
        return .unknown_role;
    }
};

test "a fleet @role model resolves before the child exists" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    const options = ExecuteOptions{
        .invocation_id = "role-resolve",
        .defaults = .{ .provider = .codex, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_role_resolver = .{ .resolve_fn = RoleResolverFixture.resolve },
    };

    // The child runs with the role's model, never the `@worker` text.
    var worker = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "probe", .model = "@worker" } });
    defer worker.deinit(alloc);
    try std.testing.expect((try runtime.executeManaged(arena, &worker, options)).success);
    try std.testing.expectEqualStrings("cento-worker", fixture.observed_model.?);

    // A role without a model on this provider inherits the parent's.
    var small = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "probe", .model = "@small" } });
    defer small.deinit(alloc);
    alloc.free(fixture.observed_model.?);
    fixture.observed_model = null;
    var small_options = options;
    small_options.invocation_id = "role-inherit";
    try std.testing.expect((try runtime.executeManaged(arena, &small, small_options)).success);
    try std.testing.expectEqualStrings("parent-model", fixture.observed_model.?);

    var unknown = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "probe", .model = "@nobody" } });
    defer unknown.deinit(alloc);
    var unknown_options = options;
    unknown_options.invocation_id = "role-unknown";
    const rejected = try runtime.executeManaged(arena, &unknown, unknown_options);
    try std.testing.expect(!rejected.success);
    try std.testing.expect(std.mem.find(u8, rejected.body, "\"error_code\":\"unknown_model_role\"") != null);
    try std.testing.expectEqual(@as(usize, 2), fixture.runs);
}

fn formatFailedResult(alloc: Allocator, failure: ?[]const u8, partial: ?[]const u8) ![]u8 {
    const reason = failure orelse "failure reason unavailable";
    const text = partial orelse "";
    return alloc.print("Subagent failed: {s}. Earlier tool calls may have completed; their effects are not rolled back.{s}{s}", .{
        reason,
        if (text.len > 0) "\n\nPartial result:\n" else "",
        text,
    });
}

test "subagent failure result distinguishes runtime cause from retained partial text" {
    const alloc = std.testing.allocator;
    const text = try formatFailedResult(alloc, "agent_turn_failed: SessionCommitFailed", "one edit completed");
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "SessionCommitFailed") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "Partial result:\none edit completed"));
    const legacy = try formatFailedResult(alloc, null, "");
    defer alloc.free(legacy);
    try std.testing.expect(std.mem.find(u8, legacy, "failure reason unavailable") != null);
    try std.testing.expect(std.mem.find(u8, legacy, "Partial result:") == null);
}

fn terminalResult(
    observation: managed_owner.Observation,
    result: ?[]const u8,
) model_contract.Result {
    return switch (observation.outcome orelse return .{
        .ok = false,
        .result = result,
        .error_code = "child_result_unavailable",
    }) {
        .completed => if (result != null) .{
            .ok = true,
            .result = result,
        } else .{
            .ok = false,
            .error_code = "child_result_unavailable",
        },
        .failed => .{
            .ok = false,
            .result = result,
            .error_code = "child_failed",
        },
        .cancelled => .{
            .ok = false,
            .result = result,
            .error_code = "child_cancelled",
        },
        .interrupted => .{
            .ok = false,
            .result = result,
            .error_code = "child_interrupted",
        },
        .lost => .{
            .ok = false,
            .result = result orelse lost_result,
            .error_code = "child_lost",
        },
    };
}

/// A crash lost the work before the child started it (D33).
const lost_result = "fx stopped before this message reached the subagent, so it never ran. Send it again if it is still needed.";

test "terminal result projects every managed outcome without a lifecycle phase" {
    const completed = terminalResult(.{
        .phase = .finished,
        .outcome = .completed,
    }, "done");
    try std.testing.expect(completed.ok);
    try std.testing.expectEqualStrings("done", completed.result.?);
    try std.testing.expect(completed.error_code == null);

    const cases = [_]struct {
        outcome: child_state.Outcome,
        error_code: []const u8,
    }{
        .{ .outcome = .failed, .error_code = "child_failed" },
        .{ .outcome = .cancelled, .error_code = "child_cancelled" },
        .{ .outcome = .interrupted, .error_code = "child_interrupted" },
        .{ .outcome = .lost, .error_code = "child_lost" },
    };
    for (cases) |case| {
        const projected = terminalResult(.{
            .phase = .interrupted,
            .outcome = case.outcome,
        }, "partial");
        try std.testing.expect(!projected.ok);
        try std.testing.expectEqualStrings("partial", projected.result.?);
        try std.testing.expectEqualStrings(case.error_code, projected.error_code.?);
    }

    // Work lost before the child started it says so, so the parent can
    // send it again (D33).
    const lost = terminalResult(.{ .phase = .interrupted, .outcome = .lost }, null);
    try std.testing.expect(!lost.ok);
    try std.testing.expectEqualStrings(lost_result, lost.result.?);

    const missing = terminalResult(.{
        .phase = .finished,
        .outcome = .completed,
    }, null);
    try std.testing.expect(!missing.ok);
    try std.testing.expectEqualStrings("child_result_unavailable", missing.error_code.?);
}

fn managedAdmissionReady(
    alloc: Allocator,
    child_id: []const u8,
) !Runtime.ManagedAdmission {
    return .{ .ready = .{ .child_id = try alloc.dupe(u8, child_id) } };
}

fn managedAdmissionRejected(
    alloc: Allocator,
    child_id: ?[]const u8,
    code: []const u8,
) !Runtime.ManagedAdmission {
    return .{ .rejected = .{
        .child_id = if (child_id) |value| try alloc.dupe(u8, value) else null,
        .code = code,
    } };
}

pub fn makeManagedWork(
    alloc: Allocator,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    request: model_contract.Request,
    options: ExecuteOptions,
    permission_mode: types.PermissionMode,
) !child_state.ActiveWork {
    const message = request.turnMessage().?;
    const id = try alloc.dupe(u8, operation_id);
    errdefer alloc.free(id);
    const owned_message = try alloc.dupe(u8, message);
    errdefer alloc.free(owned_message);
    const root_context = if (options.root_user_intent_context.len == 0)
        &.{}
    else
        try alloc.dupe(u8, options.root_user_intent_context);
    errdefer if (root_context.len > 0) alloc.free(root_context);
    return .{
        .id = id,
        .request_fingerprint = request_fingerprint,
        .message = owned_message,
        .root_user_intent_context = @constCast(root_context),
        .root_user_messages = try cloneStrings(alloc, options.root_user_messages),
        .root_user_evidence_complete = options.root_user_evidence_complete,
        .permission_mode = permission_mode,
        .created_at_ms = options.timestamp_ms,
    };
}

fn assistantTextForWork(
    history: []const types.HistoryTurn,
    work_id: []const u8,
) ?[]const u8 {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        const candidate = history[index];
        const candidate_work_id = session.historyTurnWorkId(candidate) orelse continue;
        if (!std.mem.eql(u8, candidate_work_id, work_id)) continue;
        return switch (candidate) {
            .assistant => |value| value.assistant,
            .interrupted => |value| value.assistant orelse "",
            .compacted_summary => null,
        };
    }
    return null;
}

/// Builds the parent-facing guidance for a rejected model override.
fn modelOverrideFailureMessage(
    alloc: Allocator,
    comptime kind: enum { ambiguous, unknown },
    raw_model: []const u8,
    candidates: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    switch (kind) {
        .ambiguous => {
            try writer.print("model override '{s}' matches multiple catalog models: ", .{raw_model});
            for (candidates, 0..) |candidate, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.writeAll(candidate);
            }
            try writer.writeAll(". Retry with an exact catalog model ID.");
        },
        .unknown => {
            try writer.print("unknown model override '{s}'", .{raw_model});
            if (candidates.len > 0) {
                try writer.writeAll(". Closest catalog matches: ");
                for (candidates, 0..) |candidate, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try writer.writeAll(candidate);
                }
                try writer.writeByte('.');
            } else {
                try writer.writeAll("; no catalog model names match it.");
            }
            try writer.writeAll(" Use an exact catalog model ID, or omit model to inherit the parent's model.");
        },
    }
    return out.toOwnedSlice();
}

/// Resolves the defaults used to seed a new child session. When the override
/// passed catalog resolution, `resolved_model` is the canonical catalog ID and
/// wins over the raw override text. The returned value borrows the override or
/// resolved model; the request, the resolved model, and the original defaults
/// must outlive the result.
pub fn effectiveDefaults(
    defaults: Defaults,
    override: model_contract.Override,
    resolved_model: ?[]const u8,
) Defaults {
    var resolved = defaults;
    if (override.model) |model| resolved.model = resolved_model orelse model;
    if (override.effort) |effort| resolved.effort = effort;
    return resolved;
}

fn captureAdmission(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: execution.CaptureRequest,
) execution.ServiceError!domain.AdmissionSnapshot {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    var snapshot = self.authority_resolver.resolve(alloc, request.child_id) catch
        return error.AdmissionFailed;
    defer snapshot.deinit(alloc);
    return domain.captureAdmission(alloc, .{
        .parent_id = request.parent_id,
        .source_id = request.source_id,
        .model = request.preferences.model,
        .provider = request.preferences.provider,
        .effort = request.preferences.effort,
        .ultrafast_mode = request.preferences.ultrafast_mode,
        .permission_mode = snapshot.permission_mode,
        .tool_names = snapshot.tools,
        .rules = snapshot.rules,
        .grants = snapshot.grants,
        .permission_state = snapshot.permission_state,
        .integration_names = snapshot.integrations,
        .authority_generation = if (snapshot.mcp_view) |view|
            mcp_access.authorityGeneration(view)
        else
            0,
        .mcp_view = snapshot.mcp_view,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AdmissionFailed,
    };
}

/// Runs one child turn. Its host, leased for the turn, carries the turn's
/// run slots and permission mode to the children it spawns (D92, D96).
fn runChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    message: domain.QueuedMessage,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    if (turn.node_host) |node| {
        node.permission_ceiling = admission.permission_mode;
        node.turn_permit = turn.permit;
    }
    defer if (turn.node_host) |node| {
        node.turn_permit = null;
    };
    return self.child_runner.run_fn(
        self.child_runner.context,
        turn,
        message,
        admission,
        cancel,
    );
}

/// Leases the host of this node's child `child_id` for its turn (D96). The
/// turn writes the child's log through it, and a child below the depth
/// limit gets it as its host for its own children.
fn leaseChildNode(raw: ?*anyopaque, child_id: []const u8, instructions: []const u8) execution.ServiceError!execution.NodeLease {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    const entry = self.tree.nodes.lease(self, child_id, .turn, instructions) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AdmissionFailed,
    };
    return .{
        .session = entry.session,
        .host = if (self.tree.policy.canSpawn(entry.depth)) entry.runtime else null,
        .handle = entry,
    };
}

fn releaseChildNode(raw: ?*anyopaque, lease: execution.NodeLease) void {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    self.tree.nodes.release(@ptrCast(@alignCast(lease.handle)), .turn);
}

fn cloneStrings(
    alloc: Allocator,
    source: []const []const u8,
) ![][]u8 {
    const result = try alloc.alloc([]u8, source.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source) |value| {
        result[built] = try alloc.dupe(u8, value);
        built += 1;
    }
    return result;
}

pub const ModePolicy = union(enum) {
    full,
    active: struct {
        registry: mode_registry.Registry,
        id: []const u8,
    },

    fn allows(
        self: ModePolicy,
        tool_set: tool_set_contract.ToolSet,
        tool_name: []const u8,
    ) bool {
        return switch (self) {
            .full => true,
            .active => |active| active.registry.toolAllowed(
                tool_set,
                active.id,
                tool_name,
            ),
        };
    }
};

pub const CapabilityPolicy = struct {
    tool_set: tool_set_contract.ToolSet,
    mode: ModePolicy,
};

pub fn captureHostAuthorityWithMcpView(
    alloc: Allocator,
    policy: CapabilityPolicy,
    integration_names: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
    mcp_view: ?*const mcp_access.View,
) !authority.HostAuthority {
    var tool_names: std.ArrayList([]const u8) = .empty;
    defer tool_names.deinit(alloc);
    for (policy.tool_set.registry.tools) |registered_tool| {
        if (!policy.mode.allows(policy.tool_set, registered_tool.name)) continue;
        if (permissions.rulesDenyAllTargetsForTool(rules, registered_tool.name)) continue;
        try tool_names.append(alloc, registered_tool.name);
    }
    return authority.HostAuthority.captureWithPermissionStateAndMcpView(
        alloc,
        tool_names.items,
        integration_names,
        rules,
        grants,
        permission_state,
        mcp_view,
    );
}
