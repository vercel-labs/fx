const std = @import("std");
const managed_execution = @import("../execution/managed_execution.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const runtime_deps = @import("../agent/runtime/deps.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const agents = @import("../agents/agents.zig");
const authority_mod = @import("authority.zig");
const approval_registry_mod = @import("approval_registry.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const live_metrics = @import("live_metrics.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_adapter = @import("../session/session_adapter.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");

const Allocator = std.mem.Allocator;

/// The MCP view a subagent may use now, taken from its freshly resolved live
/// authority, which this consumes. The subagent engine and child agents both
/// use it.
pub fn liveMcpViewFrom(
    alloc: Allocator,
    authority: *authority_mod.Snapshot,
) !tool_mcp_runtime.ResolvedLiveView {
    defer authority.deinit(alloc);
    const view = authority.mcp_view orelse return error.McpRuntimeUnavailable;
    authority.mcp_view = null;
    return .{
        .authority_generation = mcp_access.authorityGeneration(view),
        .action_authority_generation = authority.generation,
        .view = view,
    };
}

/// Decides one tool call against a subagent's live authority, resolved fresh
/// from `resolver` for `child_id`. The child engine and child agents both use
/// it, so a subagent is held to its admission's tools and integrations
/// whichever runs its turn: a name outside them, such as `subagent`, is
/// unavailable.
/// `user_mode` decides a turn no work of main's started (`Resolver.resolveForUser`).
pub fn resolveLiveToolActionFor(
    resolver: *authority_mod.Resolver,
    child_id: []const u8,
    user_mode: ?types.PermissionMode,
    alloc: Allocator,
    call: types.ToolCall,
    workspace_root: []const u8,
    target: []const u8,
    target_kind: tool_dispatch.PermissionTargetKind,
) !runtime_deps.ResolvedLiveToolAuthority {
    const snapshot = if (user_mode) |mode|
        try resolver.resolveForUser(alloc, child_id, mode)
    else
        try resolver.resolve(alloc, child_id);
    const decision = try authority_mod.decideToolAuthority(
        alloc,
        snapshot.view(),
        workspace_root,
        call.name,
        target,
        target_kind,
    );
    const permission_state = try alloc.create(session_permission_state.State);
    permission_state.* = snapshot.permission_state;
    return .{
        .authority = .{
            .generation = snapshot.generation,
            .root_id = snapshot.root_id,
            .tools = snapshot.tools,
            .integrations = snapshot.integrations,
            .rules = snapshot.rules,
            .grants = snapshot.grants,
            .permission_state = permission_state,
            .permission_mode = snapshot.permission_mode,
        },
        .decision = switch (decision) {
            .allow => .allow,
            .ask => .ask,
            .deny => .deny,
            .unavailable => .unavailable,
        },
    };
}

test "a hosted run's turn context leaves saving to the child's own agent" {
    var turn = TurnContext.initHosted(std.testing.allocator, 8);
    defer turn.deinit();
    try std.testing.expect(turn.isHosted());
    try turn.beginTurn();
    try std.testing.expectError(error.ChildCapabilityUnavailable, turn.childCapability());
    const saved: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("task"), .work_id = @constCast("work-1") },
        .assistant = @constCast("answer"),
    } };
    try std.testing.expectError(error.SessionCommitFailed, turn.commit("work-1", saved));
    try std.testing.expect(!turn.committed);
}

test "child compaction preserves work identity and permits final commit" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const child = try parent.openChild("child-compaction", &.{});
    defer child.close();
    var turn = try TurnContext.init(alloc, child, 0);
    defer turn.deinit();
    turn.active_work_id = "work-checkpoint";
    try turn.beginTurn();
    try turn.commitContextCompaction(.{
        .summary = @constCast("<context_handoff>continue child work</context_handoff>"),
        .removed_turn_count = 0,
        .compaction_count = 1,
    }, .{ .user = .{ .text = @constCast("child request") }, .assistant = @constCast("") }, null);
    try std.testing.expect(!turn.committed);
    try turn.commit("work-checkpoint", .{ .assistant = .{
        .user = .{ .text = @constCast("child request") },
        .assistant = @constCast("child done"),
    } });
    try std.testing.expect(turn.committed);
    // The compaction's active prefix and the final turn are one request.
    const history = try parent.store.childHistory(alloc, "child-compaction");
    defer types.freeHistoryTurnSlice(alloc, history);
    var requests: usize = 0;
    for (history) |entry| switch (entry) {
        .assistant => |done| if (std.mem.eql(u8, done.user.text, "child request")) {
            requests += 1;
            try std.testing.expectEqualStrings("work-checkpoint", done.user.work_id.?);
            try std.testing.expectEqualStrings("child done", done.assistant);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), requests);
}

pub const TurnPreferences = struct {
    provider: @import("../config/model_provider.zig").ProviderId = .gateway,
    model: []const u8,
    effort: types.ReasoningEffort,
    /// The durable child preference wins when work resumes. Parent defaults are
    /// used only while creating a new child session.
    ultrafast_mode: bool = false,
};

pub const CaptureRequest = struct {
    child_id: []const u8,
    parent_id: []const u8,
    source_id: []const u8,
    preferences: TurnPreferences,
};

pub const RunOutcome = enum { completed, awaiting_approval, paused };

pub const ServiceError = error{
    OutOfMemory,
    AdmissionFailed,
    ProviderFailed,
    Cancelled,
};

pub const Services = struct {
    context: ?*anyopaque = null,
    /// Binds a run's turn to the child agent that will run it, setting its
    /// `hosted_worker` and `hosted_release`. Absent where the host runs turns
    /// itself. Blocks until bound.
    bind_fn: ?*const fn (
        ?*anyopaque,
        *TurnContext,
        *std.atomic.Value(bool),
    ) ServiceError!void = null,
    capture_fn: *const fn (
        ?*anyopaque,
        Allocator,
        CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot,
    run_fn: *const fn (
        ?*anyopaque,
        *TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) ServiceError!RunOutcome,

    /// Binds `turn` to its child agent's worker, where the host has one.
    pub fn bind(self: Services, turn: *TurnContext, cancel: *std.atomic.Value(bool)) ServiceError!void {
        const bind_fn = self.bind_fn orelse return;
        return bind_fn(self.context, turn, cancel);
    }

    pub fn capture(
        self: Services,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        return self.capture_fn(self.context, alloc, request);
    }

    pub fn run(
        self: Services,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        return self.run_fn(self.context, turn, message, admission, cancel);
    }
};

pub const CommitError = error{
    OutOfMemory,
    InvalidWorkId,
    TurnAlreadyCommitted,
    SessionCommitFailed,
};

/// Counts the slot-thread turns that hold a child agent's worker, so the
/// main loop frees the agent only once none is left, and wakes the main loop
/// when the last one lets go.
pub const HostedRelease = struct {
    count: std.atomic.Value(u32) = .init(0),
    released: std.Io.Event = .unset,

    pub fn hold(self: *HostedRelease) void {
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    /// Lets go of one hold. Wakes the waiter before the count drops: once it
    /// reads zero it may free this, so nothing touches it afterwards.
    pub fn release(self: *HostedRelease) void {
        self.released.set(io_mod.getIo());
        _ = self.count.fetchSub(1, .release);
    }

    pub fn held(self: *const HostedRelease) bool {
        return self.count.load(.acquire) > 0;
    }

    /// Blocks until no hold is left, or `timeout_ms` passes. False on the
    /// timeout, when a slot thread still holds the agent.
    pub fn waitReleased(self: *HostedRelease, timeout_ms: i64) bool {
        const deadline = io_mod.milliTimestamp() + timeout_ms;
        while (true) {
            if (!self.held()) return true;
            if (io_mod.milliTimestamp() >= deadline) return false;
            self.released.reset();
            // A release between the check and the reset is not lost.
            if (!self.held()) return true;
            self.released.waitTimeout(io_mod.getIo(), .{ .duration = .{
                .raw = .fromMilliseconds(50),
                .clock = .awake,
            } }) catch {};
        }
    }
};

test "a hosted agent's waiter wakes when the last hold lets go, or times out" {
    var hosted: HostedRelease = .{};
    try std.testing.expect(hosted.waitReleased(0));
    hosted.hold();
    try std.testing.expect(!hosted.waitReleased(20));
    const Releaser = struct {
        fn run(target: *HostedRelease) void {
            io_mod.sleep(10 * std.time.ns_per_ms);
            target.release();
        }
    };
    const thread = try std.Thread.spawn(.{}, Releaser.run, .{&hosted});
    defer thread.join();
    try std.testing.expect(hosted.waitReleased(5_000));
}

pub const TurnContext = struct {
    alloc: Allocator,
    runtime: session.SessionRuntime,
    worker: worker_runtime.WorkerRuntime = .{},
    /// In the interactive app, the child agent's own worker runs the turn, so
    /// approvals, cancel, and steering go to it instead of `worker`.
    hosted_worker: ?*worker_runtime.WorkerRuntime = null,
    /// Counts this turn as using its child agent until `deinit`, so the agent
    /// is not freed while a slot thread still holds its worker.
    hosted_release: ?*HostedRelease = null,
    managed_executions: managed_execution.Runtime,
    /// The child session the turn writes, through the adapter. Null
    /// for a hosted run, whose child's own agent saves its turns.
    child: ?*session_adapter.Session,
    live_authority: ?*authority_mod.Resolver = null,
    approval_registry: ?*approval_registry_mod.Registry = null,
    approval_worker_route: ?approval_registry_mod.WorkerRoute = null,
    child_id: ?[]const u8 = null,
    /// The name the parent gave the child, such as `reviewer`, or null for a
    /// one-off. Borrowed for the turn.
    child_name: ?[]const u8 = null,
    active_work_id: ?[]const u8 = null,
    phase_context: ?*anyopaque = null,
    phase_fn: ?*const fn (
        *anyopaque,
        []const u8,
        []const u8,
        child_state.Phase,
    ) anyerror!void = null,
    live_metrics: ?*live_metrics.LiveMetrics = null,
    /// This child's event queue, which only the main loop drains.
    /// Borrowed from the subagent host for the turn.
    failure_diagnostic: ?types.ModelFailureDiagnostic = null,
    committed: bool = false,

    /// A turn over a child, restored from its log.
    pub fn init(
        alloc: Allocator,
        child: *session_adapter.Session,
        max_history_turns: usize,
    ) !TurnContext {
        var restored = try child.restore(alloc);
        defer restored.deinit(alloc);
        var runtime = session.SessionRuntime{ .max_history_turns = max_history_turns };
        errdefer runtime.deinit(alloc);
        try runtime.restoreWithPermissionState(
            alloc,
            restored.language,
            restored.history,
            restored.permission_state orelse .{},
        );
        return .{
            .alloc = alloc,
            .runtime = runtime,
            .managed_executions = managed_execution.Runtime.init(alloc),
            .child = child,
        };
    }

    /// A run whose child's own agent holds the session: the host keeps
    /// the run's admission, approvals, phases, and result, and the agent saves
    /// its turns itself, so nothing here touches the session.
    pub fn initHosted(alloc: Allocator, max_history_turns: usize) TurnContext {
        return .{
            .alloc = alloc,
            .runtime = .{ .max_history_turns = max_history_turns },
            .managed_executions = managed_execution.Runtime.init(alloc),
            .child = null,
        };
    }

    /// True when the child's own agent holds the session.
    pub fn isHosted(self: *const TurnContext) bool {
        return self.child == null;
    }

    pub fn deinit(self: *TurnContext) void {
        if (self.hosted_release) |hosted| hosted.release();
        self.managed_executions.deinit();
        self.worker.deinit(self.alloc);
        self.runtime.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn setFailureDiagnostic(
        self: *TurnContext,
        code: []const u8,
        detail: []const u8,
    ) void {
        if (self.failure_diagnostic != null) return;
        self.failure_diagnostic = failureDiagnosticValue(code, detail);
    }

    pub fn failureDiagnostic(self: *const TurnContext) ?types.ModelFailureDiagnostic {
        return self.failure_diagnostic;
    }

    pub fn sessionRuntime(self: *TurnContext) *session.SessionRuntime {
        return &self.runtime;
    }

    /// Opens the child's turn on disk as its work starts, so a body its
    /// tools store is a blob of a session on disk (D44).
    pub fn beginTurn(self: *TurnContext) !void {
        // A hosted run's turns are opened by the child's own agent.
        const child = self.child orelse return;
        try child.beginTurn();
    }

    pub fn childCapability(
        self: *TurnContext,
    ) !*session_child_store.SessionChildCapability {
        const child = self.child orelse return error.ChildCapabilityUnavailable;
        return child.childCapability();
    }

    pub fn workerRuntime(self: *TurnContext) *worker_runtime.WorkerRuntime {
        return self.hosted_worker orelse &self.worker;
    }

    pub fn managedExecutionRuntime(self: *TurnContext) *managed_execution.Runtime {
        return &self.managed_executions;
    }

    pub fn appendLiveText(_: *TurnContext, _: []const u8) void {}

    pub fn appendLiveEvent(
        _: *TurnContext,
        _: worker_runtime.WorkerEvent,
    ) void {}

    pub fn resolveLiveAuthority(
        self: *TurnContext,
        alloc: Allocator,
    ) authority_mod.Error!authority_mod.Snapshot {
        const resolver = self.live_authority orelse
            return error.HostAuthorityUnavailable;
        return resolver.resolve(
            alloc,
            self.child_id orelse return error.ChildNotAttached,
        );
    }

    pub fn liveToolAuthorityProvider(
        self: *TurnContext,
    ) runtime_deps.LiveToolAuthorityProvider {
        return .{ .context = self, .resolve_fn = resolveLiveToolAction };
    }

    pub fn toolActivityRecorder(self: *TurnContext) runtime_deps.ToolActivityRecorder {
        return .{ .context = self, .record_fn = recordToolActivity };
    }

    pub fn permissionPrompter(self: *TurnContext) permission_prompter.Prompter {
        return .{ .context = self, .request_fn = requestChildPermission };
    }

    fn requestChildPermission(
        raw: *anyopaque,
        alloc: Allocator,
        request: permission_request.PermissionRequest,
        call: types.ToolCall,
        review: ?*const @import("../output/diff.zig").FileReview,
        grant_offer: ?[]const types.PermissionGrant,
    ) !permission_request.OwnedPermissionResponse {
        const self: *TurnContext = @ptrCast(@alignCast(raw));
        const child_id = self.child_id orelse return error.ChildNotAttached;
        const work_id = self.active_work_id orelse return error.StaleRequest;
        const prepared = approval_registry_mod.preparedRequestFingerprint(request);
        const grant = types.PermissionGrant{
            .tool_name = @constCast(call.name),
            .target_path = @constCast(request.command orelse call.name),
        };
        var context = PermissionObservation{
            .turn = self,
            .stable_id = approval_registry_mod.stableApprovalId(
                child_id,
                work_id,
                prepared,
            ),
            .grants = grant_offer orelse &.{grant},
        };
        return self.workerRuntime().requestPermissionBlockingObserved(
            alloc,
            request,
            review,
            .{ .context = &context, .observe_fn = PermissionObservation.observe },
        );
    }

    const PermissionObservation = struct {
        turn: *TurnContext,
        stable_id: [64]u8,
        grants: []const types.PermissionGrant,

        fn observe(
            raw: *anyopaque,
            _: *worker_runtime.WorkerRuntime,
            request: permission_request.PermissionRequest,
        ) error{
            OutOfMemory,
            PermissionRegistrationFailed,
            PermissionCapacityExceeded,
        }!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.turn.registerApproval(
                self.turn.alloc,
                &self.stable_id,
                request,
                self.grants,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CapacityExceeded => error.PermissionCapacityExceeded,
                else => error.PermissionRegistrationFailed,
            };
        }
    };

    fn resolveLiveToolAction(
        raw: *anyopaque,
        alloc: Allocator,
        call: types.ToolCall,
        workspace_root: []const u8,
        target: []const u8,
        target_kind: tool_dispatch.PermissionTargetKind,
    ) !runtime_deps.ResolvedLiveToolAuthority {
        const self: *TurnContext = @ptrCast(@alignCast(raw));
        const resolver = self.live_authority orelse return error.HostAuthorityUnavailable;
        return resolveLiveToolActionFor(
            resolver,
            self.child_id orelse return error.ChildNotAttached,
            null,
            alloc,
            call,
            workspace_root,
            target,
            target_kind,
        );
    }

    fn recordToolActivity(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: runtime_deps.ToolActivityPhase,
    ) !void {}

    pub fn registerApproval(
        self: *TurnContext,
        alloc: Allocator,
        stable_request_id: []const u8,
        request: permission_request.PermissionRequest,
        grants: []const types.PermissionGrant,
    ) (approval_registry_mod.Error || authority_mod.Error)!void {
        const registry = self.approval_registry orelse
            return error.RegistryClosed;
        const worker_route = self.approval_worker_route orelse
            return error.RegistryClosed;
        const child_id = self.child_id orelse return error.ChildNotAttached;
        const work_id = self.active_work_id orelse return error.StaleRequest;
        var authority = try self.resolveLiveAuthority(alloc);
        defer authority.deinit(alloc);
        try self.transitionPhase(work_id, .awaiting_approval);
        registry.registerTool(
            stable_request_id,
            child_id,
            authority.root_id,
            work_id,
            request,
            grants,
            worker_route,
            io_mod.milliTimestamp(),
        ) catch |err| {
            try self.transitionPhase(work_id, .running);
            return err;
        };
    }

    fn transitionPhase(
        self: *TurnContext,
        work_id: []const u8,
        phase: child_state.Phase,
    ) approval_registry_mod.Error!void {
        const apply = self.phase_fn orelse return error.CommitFailed;
        apply(
            self.phase_context orelse return error.CommitFailed,
            self.child_id orelse return error.CommitFailed,
            work_id,
            phase,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CommitFailed,
        };
    }

    pub fn commit(self: *TurnContext, work_id: []const u8, turn: types.HistoryTurn) CommitError!void {
        // The child's own agent saves a hosted run's turns.
        if (self.child == null) return error.SessionCommitFailed;
        if (self.committed) return error.TurnAlreadyCommitted;
        try self.appendCommittedHistory(work_id, turn);
        self.committed = true;
    }

    fn appendCommittedHistory(self: *TurnContext, work_id: []const u8, turn: types.HistoryTurn) CommitError!void {
        var committed_turn = session.dupeHistoryTurn(self.alloc, turn) catch
            return error.OutOfMemory;
        defer session.freeHistoryTurn(self.alloc, committed_turn);
        session.copyWorkIdToTurn(self.alloc, &committed_turn, work_id) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidWorkId, error.ConflictingWorkId => error.InvalidWorkId,
            };
        };
        var prepared = self.runtime.prepareHistoryEntry(self.alloc, committed_turn) catch
            return error.OutOfMemory;
        var prepared_owned = true;
        defer if (prepared_owned) session.freeHistoryTurn(self.alloc, prepared);
        // The work id rides on the turn.
        const child = self.child orelse return error.SessionCommitFailed;
        child.prepareTurn(&prepared) catch |err| return commitFailed(child, work_id, "prepare", err);
        child.commitTurn(prepared, self.runtime.languageSnapshot()) catch |err| return commitFailed(child, work_id, "commit", err);
        self.runtime.commitPreparedHistoryEntry(self.alloc, prepared);
        prepared_owned = false;
    }

    pub fn commitContextCompaction(
        self: *TurnContext,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        // The child's own agent compacts a hosted run's session.
        const child = self.child orelse return error.SessionCommitFailed;
        var prefix: ?types.HistoryTurn = if (active_prefix) |value|
            try session.dupeHistoryTurn(self.alloc, .{ .assistant = value })
        else
            null;
        defer if (prefix) |value| session.freeHistoryTurn(self.alloc, value);
        if (prefix) |*value| {
            try session.copyWorkIdToTurn(self.alloc, value, self.active_work_id orelse return error.InvalidWorkId);
        }
        const prepared = try session.prepareCompactedHistory(self.alloc, self.runtime.agent.history.items, summary, retained_from orelse .{ .turns = history_range.rawHistoryTurnCount(self.runtime.agent.history.items) });
        errdefer types.freeHistoryTurnSlice(self.alloc, prepared);
        // The active prefix reaches the log with the turn's commit.
        try child.commitCompaction(summary, prefix != null, retained_from);
        self.runtime.commitCompactedHistory(self.alloc, prepared);
    }
};

/// A v2 child's turn that did not reach its log is dropped; the trace names
/// the cause the commit error hides.
fn commitFailed(child: *session_adapter.Session, work_id: []const u8, stage: []const u8, err: anyerror) CommitError {
    debug_trace.logf("subagent", "child turn dropped child_id={s} work_id={s} stage={s} err={s}", .{ child.id(), work_id, stage, @errorName(err) });
    return if (err == error.OutOfMemory) error.OutOfMemory else error.SessionCommitFailed;
}

pub fn failureDiagnosticValue(code: []const u8, detail: []const u8) types.ModelFailureDiagnostic {
    const max_bytes = types.ModelFailureDiagnostic.max_bytes;
    const prefix = text_utils.utf8PrefixByBytes(code, max_bytes);
    const safe_detail = if (text_utils.isTerminalSafe(detail))
        text_utils.utf8PrefixByBytes(detail, max_bytes -| prefix.len -| 2)
    else
        "";
    if (safe_detail.len == 0) return types.ModelFailureDiagnostic.init(prefix);
    var buffer: [max_bytes]u8 = undefined;
    const text = buffer[0 .. prefix.len + 2 + safe_detail.len];
    @memcpy(text[0..prefix.len], prefix);
    @memcpy(text[prefix.len..][0..2], ": ");
    @memcpy(text[prefix.len + 2 ..], safe_detail);
    return types.ModelFailureDiagnostic.init(text);
}

test "subagent failure capture is bounded and keeps the first cause without allocation" {
    var turn: TurnContext = undefined;
    turn.failure_diagnostic = null;
    turn.setFailureDiagnostic("agent_turn_failed", "SessionCommitFailed");
    turn.setFailureDiagnostic("cleanup", "OutOfMemory");
    const retained = turn.failureDiagnostic().?;
    turn.failure_diagnostic = null;
    try std.testing.expectEqualStrings("agent_turn_failed: SessionCommitFailed", retained.view());
    const long = failureDiagnosticValue("stage", text_utils.repeat("界", 200));
    try std.testing.expect(long.view().len <= types.ModelFailureDiagnostic.max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long.view()));
    const unsafe = failureDiagnosticValue("provider_http_error", "unsafe\x1b[31m");
    try std.testing.expectEqualStrings("provider_http_error", unsafe.view());
}

test "a subagent's tool calls are decided against its admission, whichever engine runs its turn" {
    // Hiding a tool from the model does not stop a call to it. This shared
    // decision is what refuses any tool the host does not grant, for the
    // subagent engine and for child agents alike. `subagent` is decided like
    // any other tool the host grants.
    const Host = struct {
        fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority_mod.HostResolveError!authority_mod.HostAuthority {
            return authority_mod.HostAuthority.capture(alloc, &.{ "read_file", "subagent" }, &.{}, .{}, &.{}) catch
                return error.OutOfMemory;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const store = parent.stateStore();
    var registry = try child_state.Registry.init(alloc, parent.parent.id());
    defer registry.deinit(alloc);
    var work = child_state.ActiveWork{
        .id = try alloc.dupe(u8, "work-one"),
        .message = try alloc.dupe(u8, "review"),
        .permission_mode = .ask,
        .created_at_ms = 1,
    };
    defer work.deinit(alloc);
    try registry.appendPersistent(alloc, "authority-child", "worker", "", work);
    try store.save(alloc, registry);
    var resolver = authority_mod.Resolver{
        .children = &parent.children,
        .root_id = parent.parent.id(),
        .host = .{ .resolve_fn = Host.resolve },
    };

    // The decision's authority borrows its allocator, as the agent runtime's
    // per-action arena does.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const Case = struct { name: []const u8, available: bool };
    for ([_]Case{
        .{ .name = "subagent", .available = true },
        .{ .name = "write_file", .available = false },
        .{ .name = "read_file", .available = true },
    }) |case| {
        const resolved = try resolveLiveToolActionFor(
            &resolver,
            "authority-child",
            null,
            arena.allocator(),
            .{ .id = "call-1", .name = case.name, .arguments_json = "{}" },
            home,
            "",
            .none,
        );
        errdefer std.debug.print("tool {s}: decision {s}\n", .{ case.name, @tagName(resolved.decision) });
        try std.testing.expectEqual(case.available, resolved.decision != .unavailable);
        try std.testing.expectEqual(types.PermissionMode.ask, resolved.authority.permission_mode);
    }
    try std.testing.expectError(
        error.ChildNotAttached,
        resolveLiveToolActionFor(&resolver, "missing-child", null, arena.allocator(), .{ .id = "call-2", .name = "read_file", .arguments_json = "{}" }, home, "", .none),
    );
}
