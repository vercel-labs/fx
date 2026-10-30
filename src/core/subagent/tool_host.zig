const std = @import("std");
const execution_observation = @import("../agent/runtime/observation.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const approval_registry = @import("approval_registry.zig");
const reports = @import("reports.zig");
const agents = @import("../agents/agents.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const managed_owner = @import("managed_owner.zig");
const session_adapter = @import("../session/session_adapter.zig");
const agent_frame = @import("../shared/agent_frame.zig");
const live_metrics = @import("live_metrics.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const model_contract = @import("model_contract.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profiles = @import("../profiles/profiles.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const model_provider = @import("../config/model_provider.zig");
const permissions = @import("../permissions/permissions.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
/// Bounds how long a parent wait takes to observe cancellation or steering,
/// and how long the polling loops take to see a child change. The terminal
/// result wait also wakes on child state changes. Status publishing is rate
/// limited separately, so a short pulse only adds cheap wakeups.
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
    /// Where the host runs each child turn on a child agent of its own:
    /// binds the run's turn to that agent's worker before it starts.
    bind_fn: ?*const fn (
        ?*anyopaque,
        *execution.TurnContext,
        *std.atomic.Value(bool),
    ) execution.ServiceError!void = null,
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

test "managed execution receipts retain the pending contract" {
    var runtime: Runtime = undefined;
    for ([_]bool{ false, true }) |pending| {
        const result = try runtime.encodeManaged(std.testing.allocator, .{ .ok = true, .pending = pending });
        defer std.testing.allocator.free(result.body);
        try std.testing.expectEqual(pending, result.pending);
    }
}

/// Delivers a child's report to the agent that owns this host. Each runtime
/// supplies its own, since only it can build that agent's next turn: the
/// report joins a running turn, or wakes the idle agent with the user's last
/// request as root context. It never interrupts the model.
pub const ReportSink = struct {
    context: ?*anyopaque = null,
    /// Called with the host the delivery comes from. It never blocks: the
    /// runtime copies what it keeps and delivers it later.
    post_fn: *const fn (?*anyopaque, *Runtime, Delivery) PostReportError!void,

    pub fn post(self: ReportSink, host: *Runtime, delivery: Delivery) PostReportError!void {
        return self.post_fn(self.context, host, delivery);
    }
};

/// What a host hands its runtime to deliver, borrowed for the call.
pub const Delivery = union(enum) {
    /// A child's report, for the agent that owns the host.
    report: reports.Report,
    /// A subagent's message to its parent.
    message: reports.Message,
};

/// `QueueFull`: the receiving agent's queue already holds
/// `agent_frame.queue_cap` messages from other agents. Only a message is
/// refused this way, never a report.
pub const PostReportError = error{ OutOfMemory, AgentGone, QueueFull };

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

pub const ExecuteOptions = struct {
    observer: ?*execution_observation.Observer = null,
    caller_id: []const u8,
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
    /// The caller's own worker, which `wait` blocks on.
    caller_worker: ?*worker_runtime.WorkerRuntime = null,
    progress: ?ProgressSink = null,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    model_override_resolver: ?ModelOverrideResolver = null,
};

pub const ManagedExecutionResult = struct {
    pending: bool = false,
    success: bool,
    body: []u8,
    /// The final status model is owned by the result allocator.
    final_status: ?types.SubagentStatus = null,
};

pub const Runtime = struct {
    alloc: Allocator,
    /// The parent's children, borrowed until deinit (D22).
    children: *child_state.V2Children,
    root_id: []u8,
    host_authority: authority.HostResolver,
    child_runner: ChildRunner,
    /// Where this host's children report, set by its runtime.
    report_sink: ?ReportSink = null,
    approvals: approval_registry.Registry,
    authority_resolver: authority.Resolver,
    /// The profile each child started in, for its authority and prompt.
    profile_cache: ?authority.ProfileCache = null,
    managed: managed_owner.Owner,
    /// Guards admission, `pending`, and `busy`. Taken before the registry's
    /// lock and before the managed owner's.
    admission_mutex: std.Io.Mutex = .init,
    /// Messages for busy children, in the order they were sent.
    pending: std.ArrayList(Pending) = .empty,
    /// The children whose slot is running their work, between works too.
    busy: std.ArrayList([]u8) = .empty,
    /// The tool call that sent each work still running or waiting, so its
    /// report can point back at it. Guarded by `admission_mutex`.
    work_calls: std.ArrayList(WorkCall) = .empty,
    /// Children the user stopped on their own screen, with how many of the
    /// parent's messages waiting for them the stop dropped, until the
    /// stopped work's report or notice says so (`userStopped`).
    user_dropped: std.ArrayList(UserDrop) = .empty,
    /// Children working on a turn their parent didn't start, as a work in
    /// the parent's log (`beginTurnWork`): the user's, typed on the child's
    /// screen, or one its own child's report woke.
    turn_works: std.ArrayList(TurnWork) = .empty,
    waiter_mutex: std.Io.Mutex = .init,
    /// The owner's worker while it waits in `wait`.
    waiter: ?*worker_runtime.WorkerRuntime = null,
    /// Whether this host's owner is itself a subagent, so a message to its
    /// parent has somewhere to go. Set by its runtime.
    owner_has_parent: bool = false,

    /// A host over a parent whose children live in its log (D22), returned
    /// only after abandoned child work has been recovered. Borrows
    /// `children` and the callback contexts until deinit; the parent stays
    /// open until then (`tests/tla/session_manager/Wiring.tla`
    /// ParentOutlivesChildren).
    pub fn create(
        alloc: Allocator,
        children: *child_state.V2Children,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    ) !*Runtime {
        const root_id = children.parent.id();
        try domain.validateId(root_id);
        const runtime = try alloc.create(Runtime);
        errdefer alloc.destroy(runtime);
        const owned_root = try alloc.dupe(u8, root_id);
        errdefer alloc.free(owned_root);
        runtime.* = .{
            .alloc = alloc,
            .children = children,
            .root_id = owned_root,
            .host_authority = host_authority,
            .child_runner = child_runner,
            .approvals = undefined,
            .authority_resolver = undefined,
            .managed = undefined,
        };
        runtime.approvals = .{
            .alloc = alloc,
        };
        runtime.profile_cache = .{ .alloc = alloc };
        runtime.authority_resolver = .{
            .children = children,
            .root_id = runtime.root_id,
            .host = host_authority,
            .profiles = &runtime.profile_cache.?,
        };
        runtime.managed = runtime.managedOwnerValue();
        runtime.managed.on_end = .{ .context = runtime, .end_fn = workEnded };
        errdefer runtime.approvals.deinit();
        errdefer runtime.managed.deinit();
        try runtime.managed.recoverInterrupted();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.managed.deinit();
        for (self.pending.items) |*item| {
            debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason=host_closed", .{ item.child_id, item.work.id });
            item.deinit(self.alloc);
        }
        self.pending.deinit(self.alloc);
        for (self.busy.items) |id| self.alloc.free(id);
        self.busy.deinit(self.alloc);
        for (self.work_calls.items) |*call| call.deinit(self.alloc);
        self.work_calls.deinit(self.alloc);
        for (self.user_dropped.items) |drop| self.alloc.free(drop.child_id);
        self.user_dropped.deinit(self.alloc);
        for (self.turn_works.items) |*work| work.deinit(self.alloc);
        self.turn_works.deinit(self.alloc);
        self.approvals.deinit();
        if (self.profile_cache) |*cache| cache.deinit();
        self.alloc.free(self.root_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    /// Points the host's callbacks, its child runner and its report sink,
    /// at a host context that moved; the children stay as they are. A sink
    /// left on the old context would post into memory no longer in use.
    /// `/close` is closing the tree this host belongs to: its subagents'
    /// works that end from now on owe no report. Call before their turns
    /// are cancelled.
    pub fn closeTree(self: *Runtime) void {
        self.managed.closeTree();
        debug_trace.eventf("mailbox", "tree_closed", .{}, "owner={s}", .{self.ownerName()});
    }

    pub fn rebindHost(
        self: *Runtime,
        host_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        self.host_authority = host_authority;
        self.child_runner.context = host_context;
        if (self.report_sink) |*sink| sink.context = host_context;
        self.authority_resolver.children = self.children;
        self.authority_resolver.root_id = self.root_id;
        self.authority_resolver.host = host_authority;
        self.managed.children = self.children;
        self.managed.state_store.children = self.children;
        self.managed.services.context = self;
        self.managed.on_end = .{ .context = self, .end_fn = workEnded };
        self.managed.authority_resolver = &self.authority_resolver;
        self.managed.approvals = &self.approvals;
    }

    /// Opens child `child_id`'s session for its own agent to hold, as main
    /// holds its own. The caller owns it.
    pub fn openChildSession(self: *Runtime, child_id: []const u8) !*session_adapter.Session {
        return managed_owner.openChildForAgent(&self.managed, child_id);
    }

    pub const ChildListing = struct {
        id: []u8,
        /// The name its parent gave it, or empty for a one-off.
        name: []u8,
    };

    /// The root's subagents in the order they started, after a restart too.
    /// Free with `freeChildListing`.
    pub fn listChildren(self: *Runtime, alloc: Allocator) ![]ChildListing {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        const listing = try alloc.alloc(ChildListing, registry.children.len);
        var filled: usize = 0;
        errdefer freeChildListing(alloc, listing[0..filled]);
        for (registry.children) |child| {
            const id = try alloc.dupe(u8, child.id);
            errdefer alloc.free(id);
            listing[filled] = .{ .id = id, .name = try alloc.dupe(u8, child.agentName() orelse "") };
            filled += 1;
        }
        return listing;
    }

    pub fn freeChildListing(alloc: Allocator, listing: []ChildListing) void {
        for (listing) |entry| {
            alloc.free(entry.id);
            alloc.free(entry.name);
        }
        alloc.free(listing);
    }

    /// A child's saved conversation, read without opening it. The caller
    /// owns the turns (`types.freeHistoryTurnSlice`).
    pub fn childHistory(self: *Runtime, alloc: Allocator, child_id: []const u8) ![]types.HistoryTurn {
        return self.children.parent.store.childHistory(alloc, child_id);
    }

    /// What a turn the user starts on a subagent's own screen runs under.
    pub const UserTurnAdmission = struct {
        admission: domain.AdmissionSnapshot,
        /// The child's instructions, for its system prompt. Owned.
        instructions: []u8,

        pub fn deinit(self: *UserTurnAdmission, alloc: Allocator) void {
            self.admission.deinit(alloc);
            alloc.free(self.instructions);
            self.* = undefined;
        }
    };

    /// Admits a turn the user starts on child `child_id`'s own screen,
    /// captured as a run's admission is, from the child's saved preferences,
    /// so its profile and main's live permissions limit it the same way.
    /// The registry is not changed: no work of main's is started, and
    /// a run main sends meanwhile waits for the turn to end. A one-off ran a
    /// single task for main and takes no turns of the user's. The caller owns
    /// the result.
    pub fn admitUserTurn(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        permission_mode: types.PermissionMode,
    ) !UserTurnAdmission {
        const instructions = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(alloc);
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildUnavailable;
            if (child.agentName() == null) return error.OneOffChild;
            break :blk try alloc.dupe(u8, child.instructions());
        };
        errdefer alloc.free(instructions);
        var preferences = try managed_owner.readChildPreferences(&self.managed, child_id);
        defer preferences.deinit(self.managed.alloc);
        var snapshot = try self.authority_resolver.resolveForUser(alloc, child_id, permission_mode);
        defer snapshot.deinit(alloc);
        const admission = try admissionFrom(alloc, .{
            .child_id = child_id,
            .parent_id = self.managed.state_store.parent_id,
            .source_id = self.managed.state_store.parent_id,
            .preferences = managed_owner.turnPreferencesForDurable(preferences),
        }, &snapshot);
        return .{ .admission = admission, .instructions = instructions };
    }

    /// The resolver that decides a child's tools and permissions, for a
    /// turn's live authority.
    pub fn authorityResolver(self: *Runtime) *authority.Resolver {
        return &self.authority_resolver;
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
        const from_root = std.mem.eql(u8, options.caller_id, self.root_id);

        switch (request.*) {
            .wait => return self.waitForMail(alloc, options),
            .status => {
                if (!from_root) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "caller_unavailable" });
                return self.statusOf(alloc, request.status.agent);
            },
            .stop => {
                if (!from_root) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "caller_unavailable" });
                return self.stopChild(alloc, request.stop.agent);
            },
            .message => {},
        }
        if (request.toParent()) return self.messageParent(alloc, request.message.message, options, from_root);
        if (!from_root) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "caller_unavailable" });

        // A new child's profile sets its model and effort unless the
        // request names them. Loading it here refuses an unknown profile, or
        // one that would nest subagents, before any child exists.
        var profile_arena = std.heap.ArenaAllocator.init(alloc);
        defer profile_arena.deinit();
        var profiled = options;
        var model_override = request.override();
        if (model_override.profile) |name| {
            const profile = switch (try loadChildProfile(profile_arena.allocator(), name)) {
                .rejected => |failure| return self.encodeManaged(alloc, failure),
                .loaded => |value| value,
            };
            if (model_override.model == null) model_override.model = profile.model;
            if (model_override.effort == null) {
                if (profile.effort) |effort| profiled.defaults.effort = effort;
            }
        }
        const resolved_model: ?[]const u8 = switch (try resolveOverrideModel(alloc, model_override, profiled)) {
            .rejected => |failure| return self.encodeManaged(alloc, failure),
            .accepted => |model| model,
        };
        if (request.override().model == null) {
            if (model_override.model) |raw| profiled.defaults.model = resolved_model orelse raw;
        }
        if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
        const fingerprint = model_contract.requestFingerprint(request.*);
        if (self.managed.feedbackReplay(operation_id, fingerprint)) |replay| {
            return self.encodeManaged(alloc, switch (replay) {
                .receipt => |delivery| model_contract.feedbackResult(delivery),
                else => .{ .ok = false, .error_code = "operation_conflict" },
            });
        }
        // Remembered before admission, which can start the work and see it
        // end before returning. Only a started or waiting work keeps it.
        try self.rememberCall(operation_id, options.invocation_id);
        var keep_call = false;
        defer if (!keep_call) self.forgetCall(operation_id);
        var admission_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer admission_arena.deinit();
        const admission_alloc = admission_arena.allocator();
        var admitted = try self.admitAndStartManagedWork(admission_alloc, request.*, operation_id, profiled, resolved_model);
        defer admitted.deinit(admission_alloc);
        const agent = request.message.agent;
        switch (admitted) {
            .feedback => |target| {
                const delivery = steer: {
                    self.admission_mutex.lockUncancelable(io_mod.getIo());
                    defer self.admission_mutex.unlock(io_mod.getIo());
                    // Older messages for this child wait their turn; a new one
                    // never joins the running turn past them. A turn the user
                    // started has no slot to join, so they wait for it too.
                    if (!self.hasPendingLocked(target.child_id) and !self.inTurnWorkLocked(target.child_id)) {
                        const result = try self.managed.steer(target.child_id, target.work_id, operation_id, fingerprint, request.message.message);
                        switch (result) {
                            .receipt => |delivery| break :steer delivery,
                            .waiting => {},
                            .unavailable, .cancelled, .conflict, .capacity => return self.encodeManaged(alloc, .{
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
                    }
                    // It waits, and starts the child's next turn.
                    self.queuePendingLocked(target.child_id, agent, operation_id, fingerprint, request.*, profiled, resolved_model) catch |err| {
                        if (err == error.QueueFull) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "queue_full" });
                        return err;
                    };
                    keep_call = true;
                    if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = target.child_id, .work_id = operation_id, .phase = .dispatched } });
                    var buf: [sent_result_bytes]u8 = undefined;
                    return self.encodeManaged(alloc, .{ .ok = true, .result = queuedResult(&buf, agent) });
                };
                debug_trace.eventf("mailbox", "message", .{}, "child={s} work_id={s} delivery=joined receipt={s}", .{ target.child_id, target.work_id, @tagName(delivery) });
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
                return self.encodeManaged(alloc, model_contract.feedbackResult(delivery));
            },
            .rejected => |failure| return self.encodeManaged(alloc, .{
                .ok = false,
                .error_code = failure.code,
            }),
            .ready => |ready| {
                keep_call = true;
                if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = ready.child_id, .work_id = operation_id, .phase = .dispatched } });
                var buf: [sent_result_bytes]u8 = undefined;
                return self.encodeManaged(alloc, .{ .ok = true, .result = sentResult(&buf, agent) });
            },
            .completed => |completed| {
                if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = completed.child_id, .work_id = operation_id, .phase = .replayed } });
                return self.encodeManaged(alloc, .{ .ok = true, .result = "This message was sent earlier, and the subagent's work on it has ended. Its report went to you then." });
            },
        }
    }

    const WorkCall = struct {
        work_id: []u8,
        call_id: []u8,

        fn deinit(self: *WorkCall, alloc: Allocator) void {
            alloc.free(self.work_id);
            alloc.free(self.call_id);
        }
    };

    fn rememberCall(self: *Runtime, work_id: []const u8, call_id: []const u8) !void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.work_calls.items) |call| if (std.mem.eql(u8, call.work_id, work_id)) return;
        const owned_work = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(owned_work);
        const owned_call = try self.alloc.dupe(u8, call_id);
        errdefer self.alloc.free(owned_call);
        try self.work_calls.append(self.alloc, .{ .work_id = owned_work, .call_id = owned_call });
    }

    fn forgetCall(self: *Runtime, work_id: []const u8) void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        self.forgetCallLocked(work_id);
    }

    fn forgetCallLocked(self: *Runtime, work_id: []const u8) void {
        for (self.work_calls.items, 0..) |*call, i| {
            if (!std.mem.eql(u8, call.work_id, work_id)) continue;
            call.deinit(self.alloc);
            _ = self.work_calls.swapRemove(i);
            return;
        }
    }

    /// The call that sent `work_id`, copied into `a`, or empty.
    fn callOf(self: *Runtime, a: Allocator, work_id: []const u8) []const u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.work_calls.items) |call| {
            if (std.mem.eql(u8, call.work_id, work_id)) return a.dupe(u8, call.call_id) catch "";
        }
        return "";
    }

    /// A message for a busy child, waiting to start its next turn.
    const Pending = struct {
        child_id: []u8,
        agent: []u8,
        work: child_state.ActiveWork,

        fn deinit(self: *Pending, alloc: Allocator) void {
            alloc.free(self.child_id);
            alloc.free(self.agent);
            self.work.deinit(alloc);
        }
    };

    /// How many messages may wait for one busy child: the one cap on an
    /// agent's queue of other agents' messages.
    const max_pending_per_child: usize = agent_frame.queue_cap;

    fn hasPendingLocked(self: *const Runtime, child_id: []const u8) bool {
        for (self.pending.items) |item| if (std.mem.eql(u8, item.child_id, child_id)) return true;
        return false;
    }

    /// Queues a message behind the child's running turn. A call replayed
    /// with the same operation is queued once.
    fn queuePendingLocked(
        self: *Runtime,
        child_id: []const u8,
        agent: []const u8,
        operation_id: []const u8,
        fingerprint: [32]u8,
        request: model_contract.Request,
        options: ExecuteOptions,
        resolved_model: ?[]const u8,
    ) !void {
        var waiting: usize = 0;
        for (self.pending.items) |item| {
            if (std.mem.eql(u8, item.work.id, operation_id)) return;
            if (std.mem.eql(u8, item.child_id, child_id)) waiting += 1;
        }
        if (waiting >= max_pending_per_child) return error.QueueFull;
        try self.ensureManagedChildSession(child_id, operation_id, effectiveDefaults(options.defaults, request.override(), resolved_model));
        var work = try makeManagedWork(self.alloc, operation_id, fingerprint, request, options);
        errdefer work.deinit(self.alloc);
        const owned_child = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_child);
        const owned_agent = try self.alloc.dupe(u8, agent);
        errdefer self.alloc.free(owned_agent);
        try self.pending.append(self.alloc, .{ .child_id = owned_child, .agent = owned_agent, .work = work });
        debug_trace.eventf("mailbox", "message", .{}, "child={s} work_id={s} delivery=queued waiting={d}", .{ child_id, operation_id, waiting + 1 });
    }

    /// Drops every message waiting for `child_id`, returning how many.
    fn dropPendingLocked(self: *Runtime, child_id: []const u8, reason: []const u8) usize {
        var dropped: usize = 0;
        var index: usize = 0;
        while (index < self.pending.items.len) {
            if (!std.mem.eql(u8, self.pending.items[index].child_id, child_id)) {
                index += 1;
                continue;
            }
            var item = self.pending.orderedRemove(index);
            debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ child_id, item.work.id, reason });
            self.forgetCallLocked(item.work.id);
            item.deinit(self.alloc);
            dropped += 1;
        }
        return dropped;
    }

    fn isBusyLocked(self: *const Runtime, child_id: []const u8) bool {
        for (self.busy.items) |id| if (std.mem.eql(u8, id, child_id)) return true;
        return false;
    }

    fn markBusyLocked(self: *Runtime, child_id: []const u8) !void {
        if (self.isBusyLocked(child_id)) return;
        try self.busy.append(self.alloc, try self.alloc.dupe(u8, child_id));
    }

    fn clearBusyLocked(self: *Runtime, child_id: []const u8) void {
        for (self.busy.items, 0..) |id, index| if (std.mem.eql(u8, id, child_id)) {
            self.alloc.free(self.busy.swapRemove(index));
            return;
        };
    }

    /// Whether any child is working, or a message waits for one.
    fn anyWorking(self: *Runtime) bool {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        return self.busy.items.len > 0 or self.pending.items.len > 0;
    }

    /// Whether nothing in this host's tree can still post to its owner:
    /// no child works and no message waits for one. `fx ask` and ACP finish
    /// only then.
    pub fn quiet(self: *Runtime) bool {
        return !self.anyWorking();
    }

    pub const TreeWake = enum { mail, quiet, stopped };
    const cancel_poll: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };

    /// For a runtime that finishes only once its tree is quiet, as `fx ask`
    /// does: blocks until mail is queued for `worker`, nothing in this host
    /// can still post, or `worker` is stopped. A child posts its report
    /// before it stops counting as working, so `quiet` never leaves one
    /// behind.
    /// A set `cancel` stops it too. It is rechecked every `cancel_poll`, so
    /// a signal handler may set it without waking anything.
    pub fn awaitMailOrQuiet(self: *Runtime, worker: *worker_runtime.WorkerRuntime, cancel: ?*const std.atomic.Value(bool)) TreeWake {
        self.setWaiter(worker);
        defer self.setWaiter(null);
        while (true) {
            if (cancel) |flag| if (flag.load(.seq_cst)) return .stopped;
            if (worker.queuedPromptCount() > 0) return .mail;
            if (!self.anyWorking()) return .quiet;
            const wake = if (cancel != null)
                worker.waitForPostOrNudgeTimeout(cancel_poll) orelse continue
            else
                worker.waitForPostOrNudge();
            switch (wake) {
                .posted => return .mail,
                .nudged => continue,
                .stopped => return .stopped,
            }
        }
    }

    /// How trace lines name this host's owner: `main` for a root host, as the
    /// mailbox trace contract reads it, or the owner's own id.
    fn ownerName(self: *const Runtime) []const u8 {
        return if (self.owner_has_parent) self.root_id else "main";
    }

    fn setWaiter(self: *Runtime, worker: ?*worker_runtime.WorkerRuntime) void {
        self.waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.waiter_mutex.unlock(io_mod.getIo());
        self.waiter = worker;
    }

    /// Ends the owner's `wait` when a child's work ended with nothing to
    /// post, so it can look again.
    fn nudgeWaiter(self: *Runtime) void {
        self.waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.waiter_mutex.unlock(io_mod.getIo());
        if (self.waiter) |worker| worker.nudgeWaiter();
    }

    /// The owner's hook for a child's work ending (`managed_owner.EndHook`),
    /// on the child's slot thread: the report goes to the owner, or the
    /// owner's wait is nudged, and the next waiting message, if any, becomes
    /// the child's next work. Returns whether it did.
    fn workEnded(raw: *anyopaque, end: managed_owner.WorkEnd) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.deliverEnd(end);
        var ended = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            self.forgetCallLocked(end.work_id);
            self.queueLeftoversLocked(end);
            switch (self.openWaitingTurnWorkLocked(end.child_id)) {
                .none => return self.nextOrIdleLocked(end.child_id),
                // The turn that began meanwhile keeps the child busy; the
                // parent's next message waits for it.
                .opened => {
                    self.managed.markEnding(end.child_id);
                    return false;
                },
                .ended => |work| break :blk work,
            }
        };
        // Its turn ended before the work could open: finish it now, and let
        // this slot take the parent's next message.
        defer ended.deinit(self.alloc);
        const reply = ended.ended.?.reply;
        self.finishTurnWork(ended, ended.ended.?.outcome, reply);
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        return self.nextOrIdleLocked(end.child_id);
    }

    /// Makes the parent's next message waiting for `child_id` the slot's
    /// next work, or else marks the child idle.
    fn nextOrIdleLocked(self: *Runtime, child_id: []const u8) bool {
        if (self.startNextPendingLocked(child_id)) return true;
        self.clearBusyLocked(child_id);
        self.managed.markEnding(child_id);
        return false;
    }

    /// Queues the parent's messages the ended turn never took ahead of the
    /// others waiting, so the child's next work takes them.
    fn queueLeftoversLocked(self: *Runtime, end: managed_owner.WorkEnd) void {
        if (end.leftovers.len == 0) return;
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const name = self.childName(scratch.allocator(), end.child_id) catch end.child_id;
        var at: usize = self.pending.items.len;
        for (self.pending.items, 0..) |item, index| if (std.mem.eql(u8, item.child_id, end.child_id)) {
            at = index;
            break;
        };
        for (end.leftovers) |work| {
            const queued = for (self.pending.items) |item| {
                if (std.mem.eql(u8, item.work.id, work.id)) break true;
            } else false;
            if (queued) continue;
            self.insertPendingLocked(at, end.child_id, name, work) catch |err| {
                debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ end.child_id, work.id, @errorName(err) });
                continue;
            };
            at += 1;
            debug_trace.eventf("mailbox", "handed_back", .{}, "child={s} work_id={s}", .{ end.child_id, work.id });
        }
    }

    fn insertPendingLocked(self: *Runtime, at: usize, child_id: []const u8, agent: []const u8, work: child_state.ActiveWork) !void {
        var copy = try work.clone(self.alloc);
        errdefer copy.deinit(self.alloc);
        const owned_child = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_child);
        const owned_agent = try self.alloc.dupe(u8, agent);
        errdefer self.alloc.free(owned_agent);
        try self.pending.insert(self.alloc, at, .{ .child_id = owned_child, .agent = owned_agent, .work = copy });
    }

    const UserDrop = struct { child_id: []u8, count: usize };

    /// fx is quitting: the works its quit cancels say so in their reports.
    /// Call before the quit stops any of this host's children.
    pub fn noteQuitting(self: *Runtime) void {
        self.managed.noteQuitting();
    }

    /// Esc on a subagent's own screen while it works for its parent, the
    /// user's own stop: the turn ends as
    /// the Esc ends it, and the parent's messages waiting for the subagent
    /// are dropped now, so none of them starts after it: those waiting here,
    /// and `from_queue` the subagent's own queue already dropped. The parent
    /// learns of the drop from the stopped work's report, or else a notice.
    pub fn userStopped(self: *Runtime, child_id: []const u8, from_queue: usize) void {
        self.managed.noteUserStop(child_id);
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.findTurnWorkLocked(child_id)) |index| self.turn_works.items[index].stopped_by = .user;
        const dropped = self.dropPendingLocked(child_id, "stopped_by_user") + from_queue;
        debug_trace.eventf("mailbox", "stop", .{}, "target={s} by=user running={} dropped={d}", .{ child_id, self.isBusyLocked(child_id), dropped });
        if (dropped == 0) return;
        for (self.user_dropped.items) |*drop| {
            if (!std.mem.eql(u8, drop.child_id, child_id)) continue;
            drop.count += dropped;
            return;
        }
        const owned = self.alloc.dupe(u8, child_id) catch return self.logLostDrop(child_id, dropped);
        self.user_dropped.append(self.alloc, .{ .child_id = owned, .count = dropped }) catch {
            self.alloc.free(owned);
            return self.logLostDrop(child_id, dropped);
        };
    }

    fn logLostDrop(_: *Runtime, child_id: []const u8, dropped: usize) void {
        debug_trace.logf("mailbox", "stop notice lost child={s} dropped={d} reason=out_of_memory", .{ child_id, dropped });
    }

    /// How many messages the user's stop of `child_id` dropped, forgotten
    /// once read.
    fn takeUserDropped(self: *Runtime, child_id: []const u8) usize {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.user_dropped.items, 0..) |drop, index| {
            if (!std.mem.eql(u8, drop.child_id, child_id)) continue;
            _ = self.user_dropped.swapRemove(index);
            self.alloc.free(drop.child_id);
            return drop.count;
        }
        return 0;
    }

    fn deliverEnd(self: *Runtime, end: managed_owner.WorkEnd) void {
        debug_trace.eventf("mailbox", "child_end", .{}, "child={s} work_id={s} outcome={s} report={}", .{ end.child_id, end.work_id, @tagName(end.outcome), end.report_owed });
        const dropped = self.takeUserDropped(end.child_id);
        if (end.report_owed) return self.postReportWith(end, dropped);
        // Nothing owed, but the parent's messages were dropped: say so.
        if (dropped > 0) return self.postReportWith(.{ .child_id = end.child_id, .work_id = "", .outcome = .cancelled, .report_owed = false }, dropped);
        self.nudgeWaiter();
    }

    /// Posts the reports `session`'s log still owes its owner, oldest first,
    /// as each would have been posted when its work ended: a restart, or an
    /// exit, left them untaken. Once per open of
    /// the session. Call it after the report sink is in place.
    pub fn resumeReports(self: *Runtime, parent: *session_adapter.Session) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const lines = (parent.pendingReportLines(a) catch |err| {
            debug_trace.eventf("mailbox", "resume_reports_failed", .{}, "session={s} err={s}", .{ parent.id(), @errorName(err) });
            return;
        }) orelse return;
        const pending = reports.pendingReports(a, lines) catch |err| {
            debug_trace.eventf("mailbox", "resume_reports_failed", .{}, "session={s} err={s}", .{ parent.id(), @errorName(err) });
            return;
        };
        for (pending) |item| {
            debug_trace.eventf("mailbox", "report_resumed", .{}, "session={s} child={s} work_id={s} outcome={s}", .{ parent.id(), item.child_id, item.work_id, @tagName(item.outcome) });
            self.postReport(.{ .child_id = item.child_id, .work_id = item.work_id, .outcome = item.outcome, .report_owed = true, .end = item.end });
        }
    }

    fn postReport(self: *Runtime, end: managed_owner.WorkEnd) void {
        self.postReportWith(end, 0);
    }

    /// Posts `end`'s report, or with no `work_id` the notice that the user's
    /// stop dropped `dropped` messages.
    fn postReportWith(self: *Runtime, end: managed_owner.WorkEnd, dropped: usize) void {
        const sink = self.report_sink orelse {
            // Nothing here can take it; it stays owed in the log.
            debug_trace.eventf("mailbox", "report_held", .{}, "child={s} work_id={s} reason=no_sink", .{ end.child_id, end.work_id });
            return self.nudgeWaiter();
        };
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const notice = end.work_id.len == 0;
        const output = if (notice)
            (a.print("The user stopped it, and {d} of your messages waiting for it were dropped.", .{dropped}) catch "")
        else
            self.reportOutput(a, end) catch "";
        const agent = self.childName(a, end.child_id) catch end.child_id;
        sink.post(self, .{ .report = .{
            .agent = agent,
            .child_id = end.child_id,
            .work_id = end.work_id,
            .call_id = if (notice) "" else self.callOf(a, end.work_id),
            .outcome = end.outcome,
            .output = output,
            .dropped = dropped,
            .end = end.end,
        } }) catch |err| {
            // A report stays owed in the log; a notice is lost.
            debug_trace.eventf("mailbox", "report_held", .{}, "child={s} work_id={s} reason={s} notice={}", .{ end.child_id, end.work_id, @errorName(err), notice });
            return self.nudgeWaiter();
        };
        if (notice) {
            debug_trace.eventf("mailbox", "notice_queued", .{}, "to={s} from={s} dropped={d}", .{ self.ownerName(), end.child_id, dropped });
        } else {
            debug_trace.eventf("mailbox", "report_queued", .{}, "to={s} from={s} work={s} dropped={d} started_by={s} cause={s}", .{
                self.ownerName(),
                end.child_id,
                end.work_id,
                dropped,
                @tagName(end.end.started_by),
                if (end.end.cause) |cause| @tagName(cause) else "none",
            });
        }
    }

    /// What a report says about the work: the child's reply, or how it
    /// ended, with any text it had written.
    fn reportOutput(self: *Runtime, a: Allocator, end: managed_owner.WorkEnd) ![]const u8 {
        const text = if (end.reply) |reply|
            (if (reply.len > 0) reply else null)
        else
            self.managedResultText(a, end.child_id, end.work_id) catch null;
        return switch (end.outcome) {
            .completed => text orelse "The subagent ended its turn without a reply.",
            .failed => formatFailedResult(a, if (end.failure) |*failure| failure.view() else null, text),
            .cancelled => withPartial(a, cancelledSentence(end.end.cause), text),
            .interrupted => withPartial(a, "fx stopped before it finished.", text),
            .lost => lost_result,
        };
    }

    fn childName(self: *Runtime, a: Allocator, child_id: []const u8) ![]const u8 {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(a);
        const child = registry.findById(child_id) orelse return child_id;
        return a.dupe(u8, child.agentName() orelse child_id);
    }

    /// Makes the next message waiting for `child_id` its next work, which
    /// the child's slot runs at once. False when none waits or it could not
    /// be started, which drops it.
    fn startNextPendingLocked(self: *Runtime, child_id: []const u8) bool {
        const index = for (self.pending.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.child_id, child_id)) break i;
        } else return false;
        var item = self.pending.orderedRemove(index);
        defer item.deinit(self.alloc);
        self.absorbPendingLocked(&item, index);
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = self.managed.state_store.load(self.alloc) catch |err| return self.dropStart(item, err);
        defer registry.deinit(self.alloc);
        _ = registry.startPersistentWork(self.alloc, item.agent, null, item.work) catch |err| return self.dropStart(item, err);
        self.managed.state_store.save(self.alloc, registry) catch |err| return self.dropStart(item, err);
        debug_trace.eventf("mailbox", "next_turn", .{}, "child={s} work_id={s}", .{ child_id, item.work.id });
        return true;
    }

    /// The messages waiting for `head`'s child behind it join the turn it
    /// starts, in order: one turn and one report.
    /// They arrive as one message, each in its own paragraph, with the
    /// newest root request for the reviewer. `from` is where the next of
    /// the child's waiting messages can be.
    fn absorbPendingLocked(self: *Runtime, head: *Pending, from: usize) void {
        var index = from;
        while (index < self.pending.items.len) {
            const next = &self.pending.items[index];
            if (!std.mem.eql(u8, next.child_id, head.child_id)) {
                index += 1;
                continue;
            }
            const joined = std.mem.concat(self.alloc, u8, &.{ head.work.message, "\n\n", next.work.message }) catch {
                debug_trace.logf("mailbox", "absorb skipped child={s} work_id={s} reason=out_of_memory", .{ head.child_id, next.work.id });
                return;
            };
            self.alloc.free(head.work.message);
            head.work.message = joined;
            std.mem.swap([]u8, &head.work.root_user_intent_context, &next.work.root_user_intent_context);
            std.mem.swap([][]u8, &head.work.root_user_messages, &next.work.root_user_messages);
            std.mem.swap(bool, &head.work.root_user_evidence_complete, &next.work.root_user_evidence_complete);
            debug_trace.eventf("mailbox", "absorbed", .{}, "child={s} work_id={s} into={s}", .{ head.child_id, next.work.id, head.work.id });
            var absorbed = self.pending.orderedRemove(index);
            self.forgetCallLocked(absorbed.work.id);
            absorbed.deinit(self.alloc);
        }
    }

    fn inTurnWorkLocked(self: *const Runtime, child_id: []const u8) bool {
        return self.findTurnWorkLocked(child_id) != null;
    }

    fn findTurnWorkLocked(self: *const Runtime, child_id: []const u8) ?usize {
        for (self.turn_works.items, 0..) |work, index| if (std.mem.eql(u8, work.child_id, child_id)) return index;
        return null;
    }

    /// A turn of a child's that its parent didn't start, as a work in the
    /// parent's log.
    const TurnWork = struct {
        child_id: []u8,
        work_id: []u8,
        started_by: reports.StartedBy,
        /// The child's own worker, which runs the turn, so the parent's
        /// stop can end it. Borrowed; null when the caller has none.
        worker: ?*worker_runtime.WorkerRuntime,
        /// False while the parent's work the child was finishing still
        /// holds it: this one opens in the log when that one ends.
        opened: bool,
        stopped_by: enum { none, parent, user } = .none,
        /// Set when the turn ended before its work could open, so it
        /// finishes as it opens. Owned reply.
        ended: ?struct { outcome: child_state.Outcome, reply: []u8 } = null,

        fn deinit(self: *TurnWork, alloc: Allocator) void {
            alloc.free(self.child_id);
            alloc.free(self.work_id);
            if (self.ended) |ended| alloc.free(ended.reply);
        }
    };

    /// Opens a work in the parent's log for a turn the user starts on
    /// `child_id`'s own screen, as every child turn is one. Null while a work of the parent's is going, which
    /// the user's message then joins, or when the child can't take one. Its
    /// end owes the parent a report only under `every_turn`, or when it
    /// fails or is interrupted (`reports.reportable`). `worker` runs the
    /// turn. The caller owns the id, and ends the work with `endUserWork`.
    pub fn beginUserWork(self: *Runtime, alloc: Allocator, child_id: []const u8, worker: ?*worker_runtime.WorkerRuntime) ?[]u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.isBusyLocked(child_id)) return null;
        return self.openTurnWorkLocked(alloc, child_id, .user, worker, true) catch |err| {
            debug_trace.eventf("mailbox", "user_work_failed", .{}, "child={s} err={s}", .{ child_id, @errorName(err) });
            return null;
        };
    }

    /// Opens a work in the parent's log for a turn `worker` began on
    /// `child_id` with no work going for it: the user's prompt it took after
    /// a hand-off, or a report from the child's own child. While the parent's last work for the child is still
    /// ending, the work opens as that one ends, and the parent's next message
    /// waits for it. Null when one is open already, or the child can't take
    /// one. The caller owns the id, and ends the work with `endUserWork`.
    pub fn beginTurnWork(self: *Runtime, alloc: Allocator, child_id: []const u8, started_by: reports.StartedBy, worker: ?*worker_runtime.WorkerRuntime) ?[]u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.inTurnWorkLocked(child_id)) return null;
        return self.openTurnWorkLocked(alloc, child_id, started_by, worker, !self.isBusyLocked(child_id)) catch |err| {
            debug_trace.eventf("mailbox", "turn_work_failed", .{}, "child={s} err={s}", .{ child_id, @errorName(err) });
            return null;
        };
    }

    fn openTurnWorkLocked(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        started_by: reports.StartedBy,
        worker: ?*worker_runtime.WorkerRuntime,
        open_now: bool,
    ) ![]u8 {
        const suffix = try session_store.generateSessionId(self.alloc);
        defer self.alloc.free(suffix);
        const work_id = try alloc.print("{s}:{s}", .{ if (started_by == .user) "fxuser" else "fxwake", suffix });
        errdefer alloc.free(work_id);
        if (open_now) try self.startTurnWorkInLog(child_id, work_id);
        var work: TurnWork = .{
            .child_id = try self.alloc.dupe(u8, child_id),
            .work_id = undefined,
            .started_by = started_by,
            .worker = worker,
            .opened = open_now,
        };
        errdefer self.alloc.free(work.child_id);
        work.work_id = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(work.work_id);
        try self.turn_works.append(self.alloc, work);
        errdefer _ = self.turn_works.pop();
        try self.markBusyLocked(child_id);
        debug_trace.eventf("mailbox", if (started_by == .user) "user_work" else "turn_work", .{}, "child={s} work_id={s} started_by={s} opened={}", .{ child_id, work_id, @tagName(started_by), open_now });
        return work_id;
    }

    /// Starts `work_id` as the child's work in the parent's log.
    fn startTurnWorkInLog(self: *Runtime, child_id: []const u8, work_id: []const u8) !void {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        const agent = child.agentName() orelse return error.OneOffChild;
        _ = try registry.startPersistentWork(self.alloc, agent, null, .{
            .id = @constCast(work_id),
            .message = @constCast(""),
            .created_at_ms = io_mod.milliTimestamp(),
        });
        try self.managed.state_store.save(self.alloc, registry);
    }

    /// Opens the turn work that waited for `child_id`'s ending work, as
    /// that work ends. `.ended` hands back one whose turn ended meanwhile,
    /// removed from the list, for the caller to finish.
    fn openWaitingTurnWorkLocked(self: *Runtime, child_id: []const u8) union(enum) { none, opened, ended: TurnWork } {
        const index = self.findTurnWorkLocked(child_id) orelse return .none;
        const work = &self.turn_works.items[index];
        if (work.opened) return .none;
        self.startTurnWorkInLog(child_id, work.work_id) catch |err| {
            debug_trace.eventf("mailbox", "turn_work_failed", .{}, "child={s} work_id={s} err={s}", .{ child_id, work.work_id, @errorName(err) });
            var dropped = self.turn_works.swapRemove(index);
            dropped.deinit(self.alloc);
            return .none;
        };
        work.opened = true;
        debug_trace.eventf("mailbox", "turn_work_opened", .{}, "child={s} work_id={s}", .{ child_id, work.work_id });
        if (work.ended == null) return .opened;
        return .{ .ended = self.turn_works.swapRemove(index) };
    }

    /// Ends the work `beginUserWork` or `beginTurnWork` opened, with the
    /// turn's `reply`, and starts the parent's next message waiting for the
    /// child. A work still waiting to open finishes as it opens.
    pub fn endUserWork(self: *Runtime, child_id: []const u8, work_id: []const u8, outcome: child_state.Outcome, reply: []const u8) void {
        var work = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            const index = self.findTurnWorkLocked(child_id) orelse return;
            const item = &self.turn_works.items[index];
            if (!std.mem.eql(u8, item.work_id, work_id)) return;
            if (!item.opened) {
                const owned = self.alloc.dupe(u8, reply) catch "";
                item.ended = .{ .outcome = outcome, .reply = @constCast(owned) };
                debug_trace.eventf("mailbox", "turn_work_ended_early", .{}, "child={s} work_id={s} outcome={s}", .{ child_id, work_id, @tagName(outcome) });
                return;
            }
            break :blk self.turn_works.swapRemove(index);
        };
        defer work.deinit(self.alloc);
        self.finishTurnWork(work, outcome, reply);
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.startNextPendingLocked(child_id)) {
            _ = self.managed.start(child_id) catch |err| {
                debug_trace.eventf("mailbox", "start_failed", .{}, "child={s} error={s}", .{ child_id, @errorName(err) });
                self.clearBusyLocked(child_id);
            };
            return;
        }
        self.clearBusyLocked(child_id);
    }

    /// Finishes `work` in the log and posts its report, if it owes one.
    fn finishTurnWork(self: *Runtime, work: TurnWork, outcome: child_state.Outcome, reply: []const u8) void {
        const finished = self.managed.finishTurnWork(work.child_id, work.work_id, outcome, work.started_by, switch (work.stopped_by) {
            .none => .none,
            .parent => .parent,
            .user => .user,
        });
        self.deliverEnd(.{
            .child_id = work.child_id,
            .work_id = work.work_id,
            .outcome = outcome,
            .report_owed = finished.report_owed,
            .reply = reply,
            .end = finished.end,
        });
    }

    fn dropStart(self: *Runtime, item: Pending, err: anyerror) bool {
        debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ item.child_id, item.work.id, @errorName(err) });
        self.forgetCallLocked(item.work.id);
        return false;
    }

    /// `wait`: blocks on the caller's own worker until a report or message
    /// is queued for it, a child's work ends with nothing to post, or the
    /// caller is stopped. Returns at once when nothing can still arrive.
    fn waitForMail(self: *Runtime, alloc: Allocator, options: ExecuteOptions) !ManagedExecutionResult {
        const worker = options.caller_worker orelse return self.encodeManaged(alloc, .{ .ok = false, .error_code = "wait_unavailable" });
        // Registered first, so a child that ends before the wait starts
        // still ends it.
        self.setWaiter(worker);
        defer self.setWaiter(null);
        if (worker.queuedPromptCount() == 0 and !self.anyWorking()) {
            debug_trace.eventf("mailbox", "wait_skipped", .{}, "agent={s} reason=quiet", .{self.ownerName()});
            return self.encodeManaged(alloc, .{ .ok = true, .result = "No subagent is working and no message is waiting, so nothing more will arrive. Continue, or end your turn." });
        }
        debug_trace.eventf("mailbox", "wait_begin", .{}, "agent={s}", .{self.ownerName()});
        const wake = worker.waitForPostOrNudge();
        debug_trace.eventf("mailbox", "wait_end", .{}, "agent={s} reason={s}", .{ self.ownerName(), @tagName(wake) });
        return switch (wake) {
            .posted => self.encodeManaged(alloc, .{ .ok = true, .result = "A report or message arrived. It follows this result." }),
            .nudged => self.encodeManaged(alloc, .{ .ok = true, .result = "A subagent's turn ended without a report. Call status to see where things stand, or wait again." }),
            .stopped => error.Cancelled,
        };
    }

    /// `status`: each subagent, or the one named, with what it is doing.
    fn statusOf(self: *Runtime, alloc: Allocator, agent: ?[]const u8) !ManagedExecutionResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        var listed: usize = 0;
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        const registry = try self.managed.state_store.load(a);
        for (registry.children) |child| {
            const name = child.agentName() orelse continue;
            if (agent) |wanted| if (!std.mem.eql(u8, wanted, name)) continue;
            var waiting: usize = 0;
            for (self.pending.items) |item| {
                if (std.mem.eql(u8, item.child_id, child.id)) waiting += 1;
            }
            const state = if (child.phase == .awaiting_approval) "waiting for an approval" else if (self.isBusyLocked(child.id)) "working" else switch (child.phase) {
                .interrupted => "interrupted",
                .finished => "finished",
                else => "idle",
            };
            if (listed > 0) try out.writer.writeByte('\n');
            try out.writer.print("{s}: {s}", .{ name, state });
            if (waiting > 0) try out.writer.print(", {d} waiting message{s}", .{ waiting, if (waiting == 1) "" else "s" });
            if (child.last_outcome) |outcome| try out.writer.print(", last work {s}", .{@tagName(outcome)});
            try out.writer.print(", reports {s}", .{@tagName(child.report_rule)});
            listed += 1;
        }
        if (agent != null and listed == 0) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "child_unavailable" });
        if (listed == 0) try out.writer.writeAll("No subagents yet.");
        return self.encodeManaged(alloc, .{ .ok = true, .result = out.written() });
    }

    /// `stop`: ends the named child's running turn, which then owes no
    /// report, and drops the messages waiting for it.
    fn stopChild(self: *Runtime, alloc: Allocator, agent: []const u8) !ManagedExecutionResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const child_id = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(a);
            const child = registry.findPersistent(agent) orelse return self.encodeManaged(alloc, .{ .ok = false, .error_code = "child_unavailable" });
            break :blk try a.dupe(u8, child.id);
        };
        const dropped, const stopped = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            const dropped = self.dropPendingLocked(child_id, "stopped");
            break :blk .{ dropped, self.managed.stop(child_id) or self.stopTurnWorkLocked(child_id) };
        };
        debug_trace.eventf("mailbox", "stop", .{}, "target={s} by=parent running={} dropped={d}", .{ child_id, stopped, dropped });
        const dropped_text = switch (dropped) {
            0 => "",
            1 => "the message waiting for it was dropped",
            else => try a.print("the {d} messages waiting for it were dropped", .{dropped}),
        };
        const text = if (stopped)
            try a.print("Stopped {s}: its turn ended{s}{s}.", .{ agent, if (dropped > 0) ", and " else "", dropped_text })
        else
            try a.print("{s} was not working{s}{s}.", .{ agent, if (dropped > 0) "; " else "", dropped_text });
        return self.encodeManaged(alloc, .{ .ok = true, .result = text });
    }

    /// Ends the turn of a work the parent didn't start, as its `stop`
    /// ends one it did: the work owes no report.
    fn stopTurnWorkLocked(self: *Runtime, child_id: []const u8) bool {
        const index = self.findTurnWorkLocked(child_id) orelse return false;
        const work = &self.turn_works.items[index];
        work.stopped_by = .parent;
        if (work.worker) |worker| worker.requestTurnCancel();
        return true;
    }

    /// `message{agent: "parent"}`: a child of this host writes to the
    /// host's owner, and the owner, when it is a subagent, writes to its
    /// own parent. The message arrives framed as the subagent's.
    fn messageParent(self: *Runtime, alloc: Allocator, text: []const u8, options: ExecuteOptions, from_root: bool) !ManagedExecutionResult {
        const sink = self.report_sink orelse return self.encodeManaged(alloc, .{ .ok = false, .error_code = "no_parent" });
        if (from_root and !self.owner_has_parent) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "no_parent" });
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const agent = if (from_root) "" else self.childName(arena.allocator(), options.caller_id) catch options.caller_id;
        sink.post(self, .{ .message = .{
            .to = if (from_root) .owners_parent else .owner,
            .agent = agent,
            .child_id = options.caller_id,
            .text = text,
        } }) catch |err| return self.encodeManaged(alloc, .{
            .ok = false,
            .error_code = if (err == error.QueueFull) "queue_full" else "no_parent",
        });
        debug_trace.eventf("mailbox", "post", .{}, "from={s} to={s}", .{ options.caller_id, if (from_root) "owners_parent" else self.ownerName() });
        return self.encodeManaged(alloc, .{ .ok = true, .result = "Sent to your parent. It arrives as your message, never as the user's." });
    }

    const ChildProfile = union(enum) {
        loaded: profiles.Profile,
        rejected: model_contract.Result,
    };

    /// Loads the profile a new child asks for, from the fx home and the
    /// current directory, as `fx --profile` does. The result and any message
    /// belong to `arena`.
    fn loadChildProfile(arena: Allocator, name: []const u8) !ChildProfile {
        const workspace_root = io_mod.realpathAlloc(arena, ".") catch null;
        const roots = try profiles.Roots.init(arena, io_mod.homeDir(), workspace_root);
        var failure: ?[]const u8 = null;
        const profile = profiles.load(arena, roots, name, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .rejected = .{ .ok = false, .error_code = "profile_unavailable", .result = failure } },
        };
        debug_trace.eventf("profile", "profile_admitted", .{}, "name={s} source={s} mode={s}", .{
            profile.name,
            @tagName(profile.source),
            if (profile.permission_mode) |mode| @tagName(mode) else "inherit",
        });
        return .{ .loaded = profile };
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
        const raw_model = override.model orelse return .{ .accepted = null };
        // Only the gateway catalog is an authoritative model list. Configured
        // providers (OpenAI-compatible endpoints) accept arbitrary model IDs,
        // so overrides for those children pass through to the provider.
        if (options.defaults.provider != .gateway) {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=non_gateway_provider", .{raw_model});
            return .{ .accepted = null };
        }
        const resolver = options.model_override_resolver orelse {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_resolver", .{raw_model});
            return .{ .accepted = null };
        };
        switch (try resolver.resolve(alloc, raw_model)) {
            .no_catalog => {
                debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_catalog", .{raw_model});
                return .{ .accepted = null };
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
                .bind_fn = if (self.child_runner.bind_fn != null) bindChild else null,
                .capture_fn = captureAdmission,
                .run_fn = runChild,
            },
            .authority_resolver = &self.authority_resolver,
            .approvals = &self.approvals,
        };
    }

    fn childStateStore(self: *Runtime) child_state.Store {
        return .{ .children = self.children, .parent_id = self.root_id };
    }

    const ManagedAdmission = union(enum) {
        /// `created` when this admission made the child.
        ready: struct { child_id: []u8, created: bool = false },
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
        resolved_model: ?[]const u8,
    ) !ManagedAdmission {
        // A running registry entry must not be exposed before its Slot exists.
        // Release the registry lock before taking the managed-owner lock.
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
        var admitted = try self.admitManagedWork(alloc, request, operation_id, options, resolved_model);
        errdefer admitted.deinit(alloc);
        if (admitted == .ready) {
            const child_id = admitted.ready.child_id;
            try self.markBusyLocked(child_id);
            _ = self.managed.start(child_id) catch |err| {
                debug_trace.eventf("mailbox", "start_failed", .{}, "child={s} work_id={s} error={s}", .{ child_id, operation_id, @errorName(err) });
                self.clearBusyLocked(child_id);
                return err;
            };
            if (admitted.ready.created)
                debug_trace.eventf("mailbox", "launch", .{}, "child={s} work_id={s}", .{ child_id, operation_id })
            else
                debug_trace.eventf("mailbox", "message", .{}, "child={s} work_id={s} delivery=next_turn", .{ child_id, operation_id });
        }
        return admitted;
    }

    fn admitManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
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
            return managedAdmissionReady(alloc, existing.id, false);
        }

        var active = try makeManagedWork(
            alloc,
            operation_id,
            fingerprint,
            request,
            options,
        );
        defer active.deinit(alloc);
        switch (request) {
            .wait, .status, .stop => unreachable,
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
                    // A child whose slot still runs works between turns too:
                    // the message joins or waits, never starts a second run.
                    const phase: child_state.Phase = if (self.isBusyLocked(child.id)) .running else child.phase;
                    const plan = model_contract.plan(request, .{ .kind = .persistent, .phase = phase });
                    if (plan != .reject) if (message.report) |rule| {
                        try registry.setReportRule(child.id, rule);
                        try self.managed.state_store.save(alloc, registry);
                    };
                    switch (plan) {
                        .steer_persistent => {
                            const id = try alloc.dupe(u8, child.id);
                            errdefer alloc.free(id);
                            // Between works there is no turn to join, so the
                            // message waits for the next one.
                            const work_id = if (child.active) |active_work| active_work.id else "";
                            return .{ .feedback = .{ .child_id = id, .work_id = try alloc.dupe(u8, work_id) } };
                        },
                        .reject => |code| return managedAdmissionRejected(alloc, child.id, @tagName(code)),
                        .continue_persistent => {},
                        .create_persistent => unreachable,
                    }
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
                    return managedAdmissionReady(alloc, started.id, false);
                }
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendPersistent(
                    alloc,
                    child_id,
                    message.agent,
                    message.instructions orelse "",
                    active,
                );
                if (request.override().profile) |name| try registry.setProfile(alloc, child_id, name);
                if (message.report) |rule| try registry.setReportRule(child_id, rule);
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(child_id, active.id, defaults);
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                    true,
                );
            },
        }
    }

    fn ensureManagedChildSession(
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
};

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

/// A host whose children run until released, and whose reports and
/// messages are recorded, for the mailbox tests below.
const MailboxFixture = struct {
    /// While set, a run waits for `release` or its cancel.
    hold: bool = false,
    /// While set, a run's turn takes steering, as a model turn's does, so
    /// a message can join it.
    steerable: bool = false,
    /// While set, the first run fails once released.
    fail_first: bool = false,
    release: std.Io.Event = .unset,
    runs: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    /// "agent work_id outcome output" per report, in arrival order. Owned.
    reports: std.ArrayList([]u8) = .empty,
    /// Each report's facts, in the same order.
    ends: std.ArrayList(child_state.EndFacts) = .empty,
    /// When set, each report is also posted to this worker, as `fx ask`'s sink does.
    worker: ?*worker_runtime.WorkerRuntime = null,

    fn deinit(self: *MailboxFixture) void {
        for (self.reports.items) |line| std.testing.allocator.free(line);
        self.reports.deinit(std.testing.allocator);
        self.ends.deinit(std.testing.allocator);
    }

    fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
        return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const worker = turn.workerRuntime();
        // Counted once it can take steering, so a test that waits for the
        // run can join it.
        const steering = self.steerable and worker.beginDirectProcessing(self.runs.load(.seq_cst) + 1);
        defer if (steering) worker.finishProcessing();
        const run_number = self.runs.fetchAdd(1, .seq_cst) + 1;
        while (self.hold and !self.release.isSet() and !cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        if (cancel.load(.seq_cst)) return error.Cancelled;
        if (self.fail_first and run_number == 1) return error.ProviderFailed;
        const reply = std.testing.allocator.print("DONE {s}", .{message.content}) catch return error.ProviderFailed;
        defer std.testing.allocator.free(reply);
        turn.commit(turn.active_work_id.?, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = reply,
        } }) catch return error.ProviderFailed;
        return .completed;
    }

    fn post(raw: ?*anyopaque, _: *Runtime, delivery: Delivery) PostReportError!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const report = delivery.report;
        const line = if (report.dropped > 0)
            try std.testing.allocator.print("{s} {s} {s} {s} {s} dropped={d}", .{ report.agent, report.call_id, report.work_id, @tagName(report.outcome), report.output, report.dropped })
        else
            try std.testing.allocator.print("{s} {s} {s} {s} {s}", .{ report.agent, report.call_id, report.work_id, @tagName(report.outcome), report.output });
        errdefer std.testing.allocator.free(line);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.ends.ensureUnusedCapacity(std.testing.allocator, 1);
        try self.reports.append(std.testing.allocator, line);
        self.ends.appendAssumeCapacity(report.end);
        if (self.worker) |worker| {
            worker.postMail(std.testing.allocator, .{
                .prompt = try std.testing.allocator.dupe(u8, line),
                .images = &.{},
                .model = &.{},
                .api_key = &.{},
                .permission_mode = .ask,
                .history = &.{},
                .grants = &.{},
                .author = .child,
            }) catch return error.AgentGone;
        }
    }

    fn reportCount(self: *MailboxFixture) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.reports.items.len;
    }
};

fn mailboxRuntime(alloc: Allocator, fixture: *MailboxFixture, parent: *child_state.TestParent) !*Runtime {
    const runtime = try Runtime.create(alloc, &parent.children, .{ .resolve_fn = MailboxFixture.resolve }, .{ .context = fixture, .run_fn = MailboxFixture.run });
    runtime.report_sink = .{ .context = fixture, .post_fn = MailboxFixture.post };
    return runtime;
}

/// One call of the subagent tool from the root, as its model would make it.
fn callTool(runtime: *Runtime, arena: Allocator, input: model_contract.RequestInput, invocation_id: []const u8, worker: ?*worker_runtime.WorkerRuntime) ![]const u8 {
    var request = try model_contract.validateRequest(std.testing.allocator, input);
    defer request.deinit(std.testing.allocator);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = runtime.root_id,
        .invocation_id = invocation_id,
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .caller_worker = worker,
    });
    return result.body;
}

fn waitForRuns(fixture: *MailboxFixture, count: usize) !void {
    for (0..5000) |_| {
        if (fixture.runs.load(.seq_cst) >= count) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

test "a message returns at once, and the subagent's report reaches its parent on its own" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const body = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "check" } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, body, "Sent to reviewer") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const line = fixture.reports.items[0];
    // It points back at the call that sent the work.
    try std.testing.expect(std.mem.startsWith(u8, line, "reviewer call-1 "));
    try std.testing.expect(std.mem.find(u8, line, " completed DONE check") != null);
    // The finish line records that the report was owed.
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findPersistent("reviewer").?.last_report_owed);

    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, status, "reviewer: idle, last work completed, reports final") != null);
}

test "a message to a busy subagent waits and runs as its next work, in order" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    const status = try callTool(runtime, arena, .{ .status = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, status, "reviewer: working, 1 waiting message") != null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[0], "DONE first"));
    try std.testing.expect(std.mem.startsWith(u8, fixture.reports.items[0], "reviewer call-1 "));
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], "DONE second"));
    try std.testing.expect(std.mem.startsWith(u8, fixture.reports.items[1], "reviewer call-2 "));
    // Nothing is left remembered once both works ended.
    try std.testing.expectEqual(@as(usize, 0), runtime.work_calls.items.len);
}

test "a message past a busy subagent's full queue is refused to its sender" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-0", null);
    try waitForRuns(&fixture, 1);
    for (0..Runtime.max_pending_per_child) |index| {
        const call_id = try arena.print("call-{d}", .{index + 1});
        const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "more" } }, call_id, null);
        try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    }
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "one too many" } }, "call-full", null);
    try std.testing.expect(std.mem.find(u8, refused, "\"error_code\":\"queue_full\"") != null);
    // The refused message was never remembered as work.
    for (runtime.work_calls.items) |entry| try std.testing.expect(!std.mem.eql(u8, entry.call_id, "call-full"));

    _ = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-stop", null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
}

fn reviewerId(runtime: *Runtime, arena: Allocator) ![]const u8 {
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(arena);
    return try arena.dupe(u8, registry.findPersistent("reviewer").?.id);
}

test "a user's stop drops the parent's messages waiting for a subagent, and its report says how many" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "next" } }, "call-2", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after that" } }, "call-3", null);
    const child_id = try reviewerId(runtime, arena);
    // Esc on its screen: the waiting messages go first, then the turn.
    runtime.userStopped(child_id, 0);
    try runtime.managed.cancel(child_id);
    try waitUntilQuiet(runtime);

    // Neither waiting message ran, and the cancelled work's report counts them.
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const line = fixture.reports.items[0];
    try std.testing.expect(std.mem.startsWith(u8, line, "reviewer call-1 "));
    try std.testing.expect(std.mem.find(u8, line, " cancelled ") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, " dropped=2"));
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
    // It says who stopped it, so the parent needn't guess.
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .user_stop }, fixture.ends.items[0]);
    try std.testing.expect(std.mem.find(u8, line, "The user stopped its turn before it finished.") != null);
}

test "a work fx's quit cancels says so in its report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    runtime.noteQuitting();
    try runtime.managed.cancel(child_id);
    try waitUntilQuiet(runtime);

    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .fx_quit }, fixture.ends.items[0]);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], " cancelled fx quit before it finished.") != null);
    // The log keeps the cause for a report posted after a restart.
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(arena);
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .fx_quit }, registry.findPersistent("reviewer").?.last_end);
}

test "a user's stop of a work that owes no report tells the parent of its dropped messages" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "never" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "next" } }, "call-2", null);
    const child_id = try reviewerId(runtime, arena);
    runtime.userStopped(child_id, 0);
    try runtime.managed.cancel(child_id);
    try waitUntilQuiet(runtime);

    // A notice: no work to take, so no call and no work id.
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expectEqualStrings(
        "reviewer   cancelled The user stopped it, and 1 of your messages waiting for it were dropped. dropped=1",
        fixture.reports.items[0],
    );
}

test "a turn the user starts on an idle subagent is a work, and reports its reply under every_turn" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "every_turn" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const child_id = try reviewerId(runtime, arena);

    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);
    {
        var lock = runtime.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try runtime.managed.state_store.load(arena);
        const child = registry.findPersistent("reviewer").?;
        try std.testing.expectEqual(child_state.Phase.running, child.phase);
        try std.testing.expectEqualStrings(work_id, child.active.?.id);
    }
    // A second turn can't open while this one is open.
    try std.testing.expect(runtime.beginUserWork(alloc, child_id, null) == null);
    runtime.endUserWork(child_id, work_id, .completed, "USER_TURN_REPLY");
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    const line = fixture.reports.items[1];
    try std.testing.expect(std.mem.find(u8, line, work_id) != null);
    try std.testing.expect(std.mem.endsWith(u8, line, " completed USER_TURN_REPLY"));
    try std.testing.expect(!runtime.anyWorking());
    // The parent learns the user started it, not the parent.
    try std.testing.expectEqual(reports.StartedBy.parent, fixture.ends.items[0].started_by);
    try std.testing.expectEqual(child_state.EndFacts{ .started_by = .user }, fixture.ends.items[1]);
}

test "a parent's message that joined a turn that failed runs as the child's next work" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true, .steerable = true, .fail_first = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const joined = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, joined, "Sent into the subagent's running turn") != null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);

    // The failed work reports, and the message it never took runs after it.
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], " failed ") != null);
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], " completed DONE also this"));
}

test "the parent's stop drops a message that joined the turn it stops" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true, .steerable = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
}

test "the parent's stop ends a turn the user started on the child's screen, which owes no report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "every_turn" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const child_id = try reviewerId(runtime, arena);
    // The user's turn runs on the child's own worker.
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    try std.testing.expect(worker.beginDirectProcessing(5));
    const work_id = runtime.beginUserWork(alloc, child_id, &worker).?;
    defer alloc.free(work_id);

    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended") != null);
    try std.testing.expect(worker.isCancelRequested());
    runtime.endUserWork(child_id, work_id, .cancelled, "");
    // Under every_turn the user's turn would report, but the parent's own stop answers it.
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(!runtime.anyWorking());
}

test "a turn the child's own child woke while the parent's work ended opens as that work ends, and reports" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    // The parent's work still holds the child, so the woken turn's work waits.
    const work_id = runtime.beginTurnWork(alloc, child_id, .child, null).?;
    defer alloc.free(work_id);
    try std.testing.expect(runtime.beginTurnWork(alloc, child_id, .child, null) == null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after" } }, "call-2", null);
    fixture.release.set(io_mod.getIo());
    try waitForActiveWork(runtime, arena, child_id, work_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));

    runtime.endUserWork(child_id, work_id, .completed, "WOKEN_REPLY");
    try waitUntilQuiet(runtime);
    // The parent's work, the woken turn, then the message that waited for it.
    try std.testing.expectEqual(@as(usize, 3), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], " completed WOKEN_REPLY"));
    try std.testing.expectEqual(child_state.EndFacts{ .started_by = .child }, fixture.ends.items[1]);
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[2], " completed DONE after"));
}

test "a woken turn that ends before its work could open still finishes and reports" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginTurnWork(alloc, child_id, .user, null).?;
    defer alloc.free(work_id);
    // The user's turn fails before the parent's work lets go of the child.
    runtime.endUserWork(child_id, work_id, .failed, "");
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], work_id) != null);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " failed ") != null);
}

test "a user's turn under the final rule reports only when it fails" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const done = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(done);
    runtime.endUserWork(child_id, done, .completed, "fine");
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const failed = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(failed);
    runtime.endUserWork(child_id, failed, .failed, "");
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " failed ") != null);
}

test "a parent's message while the user's turn runs waits for it, then starts" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);
    const queued = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after the user" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, queued, "is busy") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));

    runtime.endUserWork(child_id, work_id, .completed, "");
    try waitForRuns(&fixture, 2);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], "DONE after the user") != null);
}

test "messages waiting for a busy subagent are taken into its next turn as one work" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "third" } }, "call-3", null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);

    // Two works, not three: the second took in the third.
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], "DONE second\n\nthird") != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.work_calls.items.len);
}

test "a work that ends after its tree closed owes no report and posts none" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    runtime.closeTree();
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), registry.children.len);
    try std.testing.expect(!registry.children[0].last_report_owed);
}

test "stop ends a subagent's turn without a report and drops what waits for it" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended, and the message waiting for it was dropped.") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    const child = registry.findPersistent("reviewer").?;
    try std.testing.expectEqual(child_state.Outcome.cancelled, child.last_outcome.?);
    try std.testing.expect(!child.last_report_owed);
    const again = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, again, "reviewer was not working.") != null);
    const missing = try callTool(runtime, arena, .{ .stop = .{ .agent = "nobody" } }, "call-5", null);
    try std.testing.expect(std.mem.find(u8, missing, "child_unavailable") != null);
}

test "wait returns at once when nothing works, and when a report arrives" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    var fixture = MailboxFixture{ .hold = true, .worker = &worker };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const quiet = try callTool(runtime, arena, .wait, "call-1", &worker);
    try std.testing.expect(std.mem.find(u8, quiet, "nothing more will arrive") != null);

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-2", &worker);
    try waitForRuns(&fixture, 1);
    const Releaser = struct {
        fn run(target: *MailboxFixture) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            target.release.set(io_mod.getIo());
        }
    };
    const releaser = try std.Thread.spawn(.{}, Releaser.run, .{&fixture});
    defer releaser.join();
    const woken = try callTool(runtime, arena, .wait, "call-3", &worker);
    try std.testing.expect(std.mem.find(u8, woken, "A report or message arrived") != null);
    try std.testing.expectEqual(@as(usize, 1), worker.queuedPromptCount());
    const queued = worker.takeQueuedPrompt(alloc).?;
    defer worker_runtime.freeQueuedPrompt(alloc, queued);
    try std.testing.expectEqual(types.MessageAuthor.child, queued.author);
}

test "a subagent that reports never stays quiet when its work completes" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "quiet", .message = "go", .report = "never" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, status, "quiet: idle, last work completed, reports never") != null);
}

test "rebinding a moved host context moves its report sink too" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var before = MailboxFixture{};
    defer before.deinit();
    var after = MailboxFixture{};
    defer after.deinit();
    const runtime = try mailboxRuntime(alloc, &before, &parent);
    defer runtime.deinit();
    runtime.rebindHost(&after, .{ .resolve_fn = MailboxFixture.resolve });
    try std.testing.expectEqual(@as(?*anyopaque, &after), runtime.report_sink.?.context);
    try std.testing.expectEqual(@as(?*anyopaque, &after), runtime.child_runner.context);
}

test "the root has no parent to message" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    const body = try callTool(runtime, arena, .{ .message = .{ .agent = "parent", .message = "done" } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, body, "no_parent") != null);
}

/// Waits, in a test, until no child of `runtime` works.
/// Waits until `child_id`'s work in the parent's log is `work_id`.
fn waitForActiveWork(runtime: *Runtime, arena: Allocator, child_id: []const u8, work_id: []const u8) !void {
    for (0..5000) |_| {
        {
            var lock = runtime.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try runtime.managed.state_store.load(arena);
            if (registry.findById(child_id)) |child| if (child.active) |active| if (std.mem.eql(u8, active.id, work_id)) return;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn waitUntilQuiet(runtime: *Runtime) !void {
    for (0..5000) |_| {
        if (runtime.quiet()) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
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
        var preferences = turn.child.?.currentPreferences(std.testing.allocator) catch return error.ProviderFailed;
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

    var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "terra-fast" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = parent.parent.id(),
        .invocation_id = "override-resolve",
        .defaults = .{ .provider = .gateway, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    });

    // The message returns at once; the child runs on its own.
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.find(u8, result.body, "Sent to probe") != null);
    try waitUntilQuiet(runtime);
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
        .caller_id = parent.parent.id(),
        .invocation_id = "override-reject",
        .defaults = .{ .provider = .gateway, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    };

    var unknown = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "skldjf" } });
    defer unknown.deinit(alloc);
    const unknown_result = try runtime.executeManaged(arena, &unknown, options);
    try std.testing.expect(!unknown_result.success);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "\"error_code\":\"unknown_model\"") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "skldjf") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "omit model to inherit") != null);

    var ambiguous = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "terra" } });
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

    var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "unknown-model" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = parent.parent.id(),
        .invocation_id = "override-non-gateway",
        .defaults = .{ .provider = .codex, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    });

    // The configured provider accepts arbitrary model IDs, so the raw override
    // reaches the child even though the gateway catalog lacks it.
    try std.testing.expect(result.success);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs);
    try std.testing.expectEqualStrings("unknown-model", fixture.observed_model.?);
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

const sent_result_bytes = 256 + domain.max_agent_name_bytes;

/// `message`'s answer when the child takes it now.
fn sentResult(buf: []u8, agent: []const u8) []const u8 {
    return std.mem.print(buf, "Sent to {s}, which works on it now. Its report arrives on its own when the work ends; keep working or end your turn.", .{agent}) catch "Sent.";
}

/// `message`'s answer when the child is busy and the message waits.
fn queuedResult(buf: []u8, agent: []const u8) []const u8 {
    return std.mem.print(buf, "{s} is busy, so the message waits and starts its next turn. Its report arrives on its own.", .{agent}) catch "Queued.";
}

/// What a cancelled work's report says about its end.
fn cancelledSentence(cause: ?child_state.Cause) []const u8 {
    const known = cause orelse return "Its turn was cancelled before it finished.";
    return switch (known) {
        .user_stop => "The user stopped its turn before it finished.",
        .fx_quit => "fx quit before it finished.",
    };
}

/// `note`, then the text the subagent had written, when it wrote any.
fn withPartial(a: Allocator, note: []const u8, partial: ?[]const u8) ![]const u8 {
    const text = partial orelse return note;
    return a.print("{s}\n\nWhat it had written:\n{s}", .{ note, text });
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
    created: bool,
) !Runtime.ManagedAdmission {
    return .{ .ready = .{ .child_id = try alloc.dupe(u8, child_id), .created = created } };
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

fn makeManagedWork(
    alloc: Allocator,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    request: model_contract.Request,
    options: ExecuteOptions,
) !child_state.ActiveWork {
    const message = request.message.message;
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
        .permission_mode = options.parent_permission_mode,
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
fn effectiveDefaults(
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
    return admissionFrom(alloc, request, &snapshot);
}

/// A child's admission from its resolved authority and `request`'s saved
/// preferences.
fn admissionFrom(
    alloc: Allocator,
    request: execution.CaptureRequest,
    snapshot: *const authority.Snapshot,
) execution.ServiceError!domain.AdmissionSnapshot {
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

fn bindChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!void {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    const bind_fn = self.child_runner.bind_fn orelse return;
    return bind_fn(self.child_runner.context, turn, cancel);
}

fn runChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    message: domain.QueuedMessage,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.child_runner.run_fn(
        self.child_runner.context,
        turn,
        message,
        admission,
        cancel,
    );
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
