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
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

test "child compaction preserves work identity and permits final commit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var store = try session_store.Store.initFromHome(alloc, root, root);
    defer store.deinit(alloc);
    const state = session_codec.DurableSessionState{
        .id = @constCast("child-compaction"),
        .origin_workspace_root = @constCast(root),
        .workspace_root = @constCast(root),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
    };
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    var turn = try TurnContext.init(alloc, &writable, 0);
    defer turn.deinit();
    turn.active_work_id = "work-checkpoint";
    try turn.commitContextCompaction(.{
        .summary = @constCast("<context_handoff>continue child work</context_handoff>"),
        .removed_turn_count = 0,
        .compaction_count = 1,
    }, .{ .user = .{ .text = @constCast("child request") }, .assistant = @constCast("") }, null, 2);
    try std.testing.expect(!turn.committed);
    try turn.setRecoveryCheckpoint(.{
        .turn_id = 7,
        .user = .{ .text = @constCast("child request") },
        .assistant_source = @constCast("partial"),
        .cause = .network_interrupted,
        .action = .paused,
        .authority = .{ .provider = .gateway, .model = @constCast("test") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    }, 2);
    try std.testing.expectEqualStrings("work-checkpoint", writable.state.recovery_checkpoint.?.user.work_id.?);
    try turn.commit("work-checkpoint", .{ .assistant = .{
        .user = .{ .text = @constCast("child request") },
        .assistant = @constCast("child done"),
    } }, 10, 5, 3);
    try std.testing.expect(turn.committed);
    const bytes = try writable.conversation_writer.readAllForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "child request"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "work-checkpoint"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "child done") != null);
}

test "child recovery admission distinguishes work identity from repeated prompt text" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "old-work", "new-work" }) |work_id| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(root);
        var store = try session_store.Store.initFromHome(alloc, root, root);
        defer store.deinit(alloc);
        const session_id = "child-recovery-admission";
        const user = types.UserTurn{ .text = @constCast("same prompt"), .work_id = @constCast("old-work") };
        {
            var writable = try store.startWritableSession(alloc, .{
                .id = @constCast(session_id),
                .origin_workspace_root = @constCast(root),
                .workspace_root = @constCast(root),
                .created_at_ms = 1,
                .updated_at_ms = 1,
                .conversation_language = session.ConversationLanguage.literal("en"),
                .history = &.{},
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
            });
            defer writable.deinit(alloc);
            _ = try writable.commitContextCompaction(alloc, .{
                .summary = @constCast("<context_handoff>old work checkpoint</context_handoff>"),
                .removed_turn_count = 0,
                .compaction_count = 1,
            }, .{ .user = user, .assistant = @constCast("") }, null, 2);
            _ = try writable.appendEvent(alloc, .{ .recovery_checkpoint_set = .{ .checkpoint = .{
                .turn_id = 7,
                .user = user,
                .assistant_source = @constCast("old partial answer"),
                .cause = .network_interrupted,
                .action = .paused,
                .authority = .{ .provider = .gateway, .model = @constCast("test") },
                .requested_fast_mode = false,
                .fast_mode = false,
                .max_provider_attempts = 3,
                .consumed_provider_attempts = 1,
            } } }, 3);
        }
        const same_work = std.mem.eql(u8, work_id, "old-work");
        {
            var writable = try store.resumeForWrite(alloc, session_id);
            defer writable.deinit(alloc);
            var turn = try TurnContext.init(alloc, &writable, 0);
            defer turn.deinit();
            turn.active_work_id = work_id;
            var recovery = try turn.prepareRecoveryForActiveWork(alloc);
            defer if (recovery) |*checkpoint| checkpoint.deinit(alloc);
            try std.testing.expectEqual(same_work, recovery != null);
            try std.testing.expect(!turn.committed);
            try std.testing.expectEqual(same_work, writable.conversation_writer.turn_open);
            try turn.commit(work_id, .{ .assistant = .{
                .user = .{ .text = @constCast("same prompt") },
                .assistant = @constCast("new answer"),
            } }, 0, 0, 4);
            try std.testing.expect(turn.committed);
        }
        var restored = try store.loadReadOnly(alloc, session_id);
        defer restored.deinit(alloc);
        try std.testing.expectEqual(@as(usize, if (same_work) 2 else 3), restored.history.len);
        if (!same_work) {
            try std.testing.expectEqualStrings("old-work", restored.history[1].interrupted.user.work_id.?);
            try std.testing.expectEqualStrings("old partial answer", restored.history[1].interrupted.assistant.?);
        }
        try std.testing.expectEqualStrings(work_id, restored.history[restored.history.len - 1].assistant.user.work_id.?);
        try std.testing.expectEqualStrings(work_id, restored.last_subagent_work_id.?);
    }
}

pub const TurnPreferences = struct {
    provider: @import("../config/model_provider.zig").ProviderId = .gateway,
    model: []const u8,
    effort: types.ReasoningEffort,
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
    loaded: *session_store.LoadedWritableSession,
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
    failure_diagnostic: ?types.ModelFailureDiagnostic = null,
    committed: bool = false,

    pub fn init(
        alloc: Allocator,
        loaded: *session_store.LoadedWritableSession,
        max_history_turns: usize,
    ) !TurnContext {
        var runtime = session.SessionRuntime{ .max_history_turns = max_history_turns };
        errdefer runtime.deinit(alloc);
        try runtime.restoreWithPermissionState(
            alloc,
            loaded.state.conversation_language,
            loaded.state.history,
            loaded.state.permission_state,
        );
        loaded.releaseHydrationHistory(alloc);
        return .{
            .alloc = alloc,
            .runtime = runtime,
            .managed_executions = managed_execution.Runtime.init(alloc),
            .loaded = loaded,
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

    pub fn prepareRecoveryForActiveWork(
        self: *TurnContext,
        alloc: Allocator,
    ) CommitError!?session_codec.RecoveryCheckpoint {
        const checkpoint = self.loaded.state.recovery_checkpoint orelse return null;
        if (self.loaded.conversation_writer.turn_open) {
            const prior_work_id = checkpoint.user.work_id orelse return error.InvalidWorkId;
            const work_id = self.active_work_id orelse return error.InvalidWorkId;
            if (!std.mem.eql(u8, prior_work_id, work_id)) {
                try self.appendCommittedHistory(
                    prior_work_id,
                    checkpoint.interruptedTurn(),
                    self.loaded.state.total_input_tokens,
                    self.loaded.state.total_output_tokens,
                    io_mod.milliTimestamp(),
                );
                return null;
            }
        }
        return try checkpoint.dupe(alloc);
    }

    pub fn childCapability(
        self: *TurnContext,
    ) !*session_child_store.SessionChildCapability {
        return self.loaded.childCapability();
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

    pub fn commit(
        self: *TurnContext,
        work_id: []const u8,
        turn: types.HistoryTurn,
        total_input_tokens: u64,
        total_output_tokens: u64,
        timestamp_ms: i64,
    ) CommitError!void {
        if (self.committed) return error.TurnAlreadyCommitted;
        try self.appendCommittedHistory(work_id, turn, total_input_tokens, total_output_tokens, timestamp_ms);
        self.committed = true;
    }

    fn appendCommittedHistory(
        self: *TurnContext,
        work_id: []const u8,
        turn: types.HistoryTurn,
        total_input_tokens: u64,
        total_output_tokens: u64,
        timestamp_ms: i64,
    ) CommitError!void {
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
        self.loaded.prepareHistoryTurnForCommit(self.alloc, &prepared) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionCommitFailed,
            };
        };
        _ = self.loaded.appendEvent(
            self.alloc,
            .{ .history_turn_committed = .{
                .conversation_language = self.runtime.languageSnapshot(),
                .total_input_tokens = total_input_tokens,
                .total_output_tokens = total_output_tokens,
                .work_id = @constCast(work_id),
                .turn = prepared,
            } },
            timestamp_ms,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionCommitFailed,
        };
        self.runtime.commitPreparedHistoryEntry(self.alloc, prepared);
        prepared_owned = false;
    }

    pub fn commitContextCompaction(
        self: *TurnContext,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
        timestamp_ms: i64,
    ) !void {
        var prefix: ?types.HistoryTurn = if (active_prefix) |value|
            try session.dupeHistoryTurn(self.alloc, .{ .assistant = value })
        else
            null;
        defer if (prefix) |value| session.freeHistoryTurn(self.alloc, value);
        if (prefix) |*value| {
            try session.copyWorkIdToTurn(self.alloc, value, self.active_work_id orelse return error.InvalidWorkId);
        }
        const prepared = try session.prepareCompactedHistory(self.alloc, self.runtime.agent.history.items, summary, retained_from orelse .{ .turns = session.rawHistoryTurnCount(self.runtime.agent.history.items) });
        errdefer types.freeHistoryTurnSlice(self.alloc, prepared);
        _ = try self.loaded.commitContextCompaction(
            self.alloc,
            summary,
            if (prefix) |value| value.assistant else null,
            retained_from,
            timestamp_ms,
        );
        self.runtime.commitCompactedHistory(self.alloc, prepared);
    }

    pub fn setRecoveryCheckpoint(
        self: *TurnContext,
        checkpoint: session_codec.RecoveryCheckpoint,
        timestamp_ms: i64,
    ) CommitError!void {
        const work_id = self.active_work_id orelse return error.InvalidWorkId;
        session.validateWorkId(work_id) catch return error.InvalidWorkId;
        if (checkpoint.user.work_id) |checkpoint_work_id| {
            if (!std.mem.eql(u8, checkpoint_work_id, work_id)) return error.InvalidWorkId;
        }
        var bound = checkpoint;
        bound.user.work_id = @constCast(work_id);
        _ = self.loaded.appendEvent(
            self.alloc,
            .{ .recovery_checkpoint_set = .{ .checkpoint = bound } },
            timestamp_ms,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionCommitFailed,
        };
    }
};

pub fn failureDiagnosticValue(code: []const u8, detail: []const u8) types.ModelFailureDiagnostic {
    const max_bytes = types.ModelFailureDiagnostic.max_bytes;
    const prefix = text_utils.utf8PrefixByBytes(code, max_bytes);
    const safe_detail = if (text_utils.isTerminalSafe(detail))
        text_utils.utf8PrefixByBytes(detail, max_bytes -| prefix.len -| 2)
    else
        "";
    if (safe_detail.len == 0) return types.ModelFailureDiagnostic.init(prefix);
    var buffer: [max_bytes]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ prefix, safe_detail }) catch unreachable;
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
    const long = failureDiagnosticValue("stage", "界" ** 200);
    try std.testing.expect(long.view().len <= types.ModelFailureDiagnostic.max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long.view()));
    const unsafe = failureDiagnosticValue("provider_http_error", "unsafe\x1b[31m");
    try std.testing.expectEqualStrings("provider_http_error", unsafe.view());
}
