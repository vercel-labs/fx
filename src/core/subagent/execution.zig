const std = @import("std");
const managed_execution = @import("../execution/managed_execution.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const runtime_deps = @import("../agent/runtime/deps.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
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
const types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");

const Allocator = std.mem.Allocator;

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

pub const TurnContext = struct {
    alloc: Allocator,
    runtime: session.SessionRuntime,
    worker: worker_runtime.WorkerRuntime = .{},
    managed_executions: managed_execution.Runtime,
    /// The child session the turn writes, through the adapter (D22).
    child: *session_adapter.Session,
    live_authority: ?*authority_mod.Resolver = null,
    approval_registry: ?*approval_registry_mod.Registry = null,
    approval_worker_route: ?approval_registry_mod.WorkerRoute = null,
    child_id: ?[]const u8 = null,
    active_work_id: ?[]const u8 = null,
    phase_context: ?*anyopaque = null,
    phase_fn: ?*const fn (
        *anyopaque,
        []const u8,
        []const u8,
        child_state.Phase,
    ) anyerror!void = null,
    live_metrics: ?*live_metrics.LiveMetrics = null,
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

    pub fn deinit(self: *TurnContext) void {
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
        try self.child.beginTurn();
    }

    pub fn childCapability(
        self: *TurnContext,
    ) !*session_child_store.SessionChildCapability {
        return self.child.childCapability();
    }

    pub fn workerRuntime(self: *TurnContext) *worker_runtime.WorkerRuntime {
        return &self.worker;
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
        return self.worker.requestPermissionBlockingObserved(
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
        const snapshot = try self.resolveLiveAuthority(alloc);
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
        const child = self.child;
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
        try self.child.commitCompaction(summary, prefix != null, retained_from);
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
