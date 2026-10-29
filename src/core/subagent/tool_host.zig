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
    /// Called on the slot thread that ran the child's turn, with the host
    /// whose owner the report is for.
    post_fn: *const fn (?*anyopaque, *Runtime, reports.Report) PostReportError!void,

    pub fn post(self: ReportSink, host: *Runtime, report: reports.Report) PostReportError!void {
        return self.post_fn(self.context, host, report);
    }
};

pub const PostReportError = error{ OutOfMemory, AgentGone };

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
    steering_worker: ?*worker_runtime.WorkerRuntime = null,
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
    admission_mutex: std.Io.Mutex = .init,
    yielded_mutex: std.Io.Mutex = .init,
    yielded: std.ArrayList(YieldedWork) = .empty,

    const YieldedWork = struct { child_id: []u8, work_id: []u8, max_result_bytes: usize, result: ?ManagedExecutionResult = null, delivered: bool = false };
    pub const YieldedResult = struct { child_id: []const u8, work_id: []const u8, body: []const u8, max_result_bytes: usize, delivered: bool, receipt_sequence: u64 = 0 };

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
        errdefer runtime.approvals.deinit();
        errdefer runtime.managed.deinit();
        try runtime.managed.recoverInterrupted();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.cancelYielded();
        self.yielded.deinit(self.alloc);
        self.managed.deinit();
        self.approvals.deinit();
        if (self.profile_cache) |*cache| cache.deinit();
        self.alloc.free(self.root_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
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
        self.authority_resolver.root_id = self.root_id;
        self.authority_resolver.host = host_authority;
        self.managed.children = self.children;
        self.managed.state_store.children = self.children;
        self.managed.services.context = self;
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

        return switch (request.*) {
            .run, .message => blk: {
                if (!std.mem.eql(u8, options.caller_id, self.root_id)) {
                    break :blk self.encodeManaged(alloc, .{
                        .ok = false,
                        .error_code = "caller_unavailable",
                    });
                }
                // A new child's profile sets its model and effort unless the
                // request names them. Loading it here refuses an unknown
                // profile, or one that would nest subagents, before any child
                // exists.
                var profile_arena = std.heap.ArenaAllocator.init(alloc);
                defer profile_arena.deinit();
                var profiled = options;
                var model_override = request.override();
                if (model_override.profile) |name| {
                    const profile = switch (try loadChildProfile(profile_arena.allocator(), name)) {
                        .rejected => |failure| break :blk try self.encodeManaged(alloc, failure),
                        .loaded => |value| value,
                    };
                    if (model_override.model == null) model_override.model = profile.model;
                    if (model_override.effort == null) {
                        if (profile.effort) |effort| profiled.defaults.effort = effort;
                    }
                }
                const resolved_model: ?[]const u8 = switch (try resolveOverrideModel(alloc, model_override, profiled)) {
                    .rejected => |failure| break :blk try self.encodeManaged(alloc, failure),
                    .accepted => |model| model,
                };
                if (request.override().model == null) {
                    if (model_override.model) |raw| profiled.defaults.model = resolved_model orelse raw;
                }
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
                        profiled,
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
                            const result = self.observeManagedState(
                                alloc,
                                ready.child_id,
                                operation_id,
                                effectiveDefaults(profiled.defaults, request.override(), resolved_model),
                                options.progress,
                                options.cancel_flag,
                                options.steering_worker,
                                options.model_capability_resolver,
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
        );
        defer active.deinit(alloc);
        switch (request) {
            .run => {
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendOneOff(alloc, child_id, active);
                if (request.override().profile) |name| try registry.setProfile(alloc, child_id, name);
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
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(child_id, active.id, defaults);
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
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
        status.tick(.{}, io_mod.milliTimestamp());
        while (true) {
            if (cancel_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    debug_trace.eventf("subagent", "parent_cancel_propagated", .{}, "child_id={s} work_id={s}", .{ child_id, work_id });
                    self.managed.cancel(child_id) catch |err| switch (err) {
                        error.ChildUnavailable => {},
                    };
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
                }
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

    fn completeManagedResult(
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
        return self.encodeManaged(alloc, terminalResult(observation, failure_text orelse result));
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
    var runtime = Runtime{ .alloc = alloc, .children = undefined, .root_id = undefined, .host_authority = undefined, .child_runner = undefined, .approvals = undefined, .authority_resolver = undefined, .managed = undefined };
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
    var runtime = Runtime{ .alloc = alloc, .children = &parent.children, .root_id = undefined, .host_authority = undefined, .child_runner = undefined, .approvals = undefined, .authority_resolver = undefined, .managed = undefined };
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
    var runtime = Runtime{ .alloc = alloc, .children = undefined, .root_id = undefined, .host_authority = undefined, .child_runner = undefined, .approvals = undefined, .authority_resolver = undefined, .managed = undefined };
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
                .caller_id = self.runtime.root_id,
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
    });
    defer request.deinit(alloc);
    const options = ExecuteOptions{
        .caller_id = parent.parent.id(),
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

    var request = try model_contract.validateRequest(alloc, .{ .run = .{ .task = "probe", .model = "terra-fast" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = parent.parent.id(),
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
        .caller_id = parent.parent.id(),
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

fn makeManagedWork(
    alloc: Allocator,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    request: model_contract.Request,
    options: ExecuteOptions,
) !child_state.ActiveWork {
    const message = switch (request) {
        .run => |value| value.task,
        .message => |value| value.message,
    };
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
