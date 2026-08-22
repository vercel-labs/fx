const std = @import("std");
const builtin = @import("builtin");
const agent_runtime = @import("../agent/agent_runtime.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const command_admission = @import("../permissions/command_admission.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const runtime_assistant_stream = @import("../agent/runtime/assistant_stream.zig");
const runtime_config = @import("../agent/runtime/config.zig");
const runtime_deps = @import("../agent/runtime/deps.zig");
const runtime_lifecycle = @import("../agent/runtime/lifecycle.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const model_provider = @import("../config/model_provider.zig");
const session_event = @import("../session/session_event.zig");
const session_store = @import("../session/session_store.zig");
const permissions = @import("../permissions/permissions.zig");
const tooling_tool_admission = @import("../tooling/tool_admission.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const background_runtime = @import("../background/background_runtime.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const types = @import("../shared/types.zig");
const control_store = @import("control_store.zig");
const authority_mod = @import("authority.zig");
const approval_persistence = @import("approval_persistence.zig");
const approval_registry_mod = @import("approval_registry.zig");
const communication = @import("communication.zig");
const communication_manager = @import("communication_manager.zig");
const communication_store = @import("communication_store.zig");
const domain = @import("domain.zig");
const manager_mod = @import("manager.zig");
const relationship_index = @import("relationship_index.zig");
const work_events = @import("work_events.zig");
const agent_test_support = if (builtin.is_test)
    @import("../agent/runtime/tests/support.zig")
else
    struct {};
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;

pub const TurnPreferences = struct {
    provider: model_provider.ProviderId = .gateway,
    model: []const u8,
    effort: types.ReasoningEffort,
};

/// Resolves child overrides without allocating. The returned model is borrowed
/// from either the control record or ordinary session metadata.
pub fn resolveTurnPreferences(
    configuration: domain.Configuration,
    persisted: session_codec.DurableSessionPreferences,
) TurnPreferences {
    return .{
        .provider = persisted.provider,
        .model = configuration.model orelse persisted.model,
        .effort = configuration.effort orelse persisted.effort,
    };
}

test "turn preference overrides preserve the persisted provider" {
    var command = try domain.validateCommand(std.testing.allocator, .{ .create = .{
        .name = "child",
        .mode = .persistent,
        .model = "gpt-5.4-mini",
    } });
    defer command.deinit(std.testing.allocator);
    const preferences = resolveTurnPreferences(
        command.create.configuration,
        .{
            .provider = .codex,
            .model = @constCast("gpt-5.6-sol"),
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
    );
    try std.testing.expectEqual(model_provider.ProviderId.codex, preferences.provider);
    try std.testing.expectEqualStrings("gpt-5.4-mini", preferences.model);
}

pub const WorkOutcome = enum {
    completed,
    failed,
    awaiting_approval,
    paused,
};

pub const CompletionDecision = enum {
    committed,
    cancellation_won,
    stale_work,
};

pub const TransitionError = error{
    OutOfMemory,
    InvalidWorkState,
    InvalidCancellationReason,
};

/// Finds the next FIFO item. Interrupted or approval-blocked work is eligible
/// only after an explicit retry/resume request.
pub fn nextRunnableIndex(
    queue: []const domain.QueuedMessage,
    retry_interrupted: bool,
) ?usize {
    for (queue, 0..) |message, index| {
        switch (message.status) {
            .completed, .failed, .cancelled => continue,
            .pending => return index,
            .interrupted, .awaiting_approval => return if (retry_interrupted) index else null,
            .running => return null,
        }
    }
    return null;
}

/// Pure admission reduction over an owned record value.
pub fn admitWork(
    alloc: Allocator,
    record: *control_store.Record,
    index: usize,
    timestamp_ms: i64,
) TransitionError!void {
    if (index >= record.queue.len) return error.InvalidWorkState;
    const message = &record.queue[index];
    const previous = message.status;
    switch (message.status) {
        .pending, .interrupted, .awaiting_approval => {},
        .running, .completed, .failed, .cancelled => return error.InvalidWorkState,
    }
    if (message.cancellation_reason) |reason| {
        if (message.status != .interrupted) return error.InvalidWorkState;
        alloc.free(reason);
        message.cancellation_reason = null;
    }
    message.status = .running;
    record.state = .running;
    record.updated_at_ms = timestamp_ms;
    manager_mod.appendWorkRevision(alloc, record, &.{.{
        .work_item_id = message.id,
        .previous = previous,
        .current = .running,
    }}, timestamp_ms) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.GenerationExhausted => error.InvalidWorkState,
    };
}

/// Pure completion reduction. A durable cancellation always wins over a late
/// worker result and is never rewritten as success.
pub fn finishWork(
    alloc: Allocator,
    record: *control_store.Record,
    work_id: []const u8,
    outcome: WorkOutcome,
    timestamp_ms: i64,
) TransitionError!CompletionDecision {
    return finishWorkWithFailureReason(
        alloc,
        record,
        work_id,
        outcome,
        null,
        timestamp_ms,
    );
}

fn finishWorkWithFailureReason(
    alloc: Allocator,
    record: *control_store.Record,
    work_id: []const u8,
    outcome: WorkOutcome,
    failure_reason: ?[]const u8,
    timestamp_ms: i64,
) TransitionError!CompletionDecision {
    if (outcome != .failed and failure_reason != null) {
        return error.InvalidCancellationReason;
    }
    if (failure_reason) |reason| {
        if (reason.len == 0 or reason.len > domain.max_cancellation_reason_bytes or
            !text_utils.isModelSafeText(reason))
        {
            return error.InvalidCancellationReason;
        }
    }
    const message = findWork(record.queue, work_id) orelse return .stale_work;
    if (message.status == .cancelled) return .cancellation_won;
    if (message.status != .running) return .stale_work;

    if (outcome == .paused) {
        const owned_reason = try alloc.dupe(u8, recovery_paused_reason);
        if (message.cancellation_reason) |old| alloc.free(old);
        message.cancellation_reason = owned_reason;
    }

    message.status = switch (outcome) {
        .completed => .completed,
        .failed => .failed,
        .awaiting_approval => .awaiting_approval,
        .paused => .interrupted,
    };
    const current = message.status;
    record.updated_at_ms = timestamp_ms;
    if (outcome == .awaiting_approval or outcome == .paused) {
        record.state = if (outcome == .awaiting_approval) .awaiting_approval else .interrupted;
        try appendSingleTransition(
            alloc,
            record,
            message.id,
            .running,
            current,
            message.cancellation_reason,
            timestamp_ms,
        );
        return .committed;
    }
    if (remainingWorkState(record.queue)) |state| {
        record.state = state;
    } else if (record.mode == .one_off) {
        record.state = if (outcome == .completed) .completed else .failed;
    } else {
        record.state = .idle;
    }
    try appendSingleTransition(
        alloc,
        record,
        message.id,
        .running,
        current,
        failure_reason,
        timestamp_ms,
    );
    return .committed;
}

/// Pure cancellation reduction over an owned record. Allocation failures leave
/// the caller-owned candidate disposable; the shell never publishes it.
pub fn cancelWork(
    alloc: Allocator,
    record: *control_store.Record,
    reason: []const u8,
    timestamp_ms: i64,
) TransitionError!usize {
    if (reason.len == 0 or reason.len > domain.max_cancellation_reason_bytes or
        !std.unicode.utf8ValidateSlice(reason) or std.mem.indexOfScalar(u8, reason, 0) != null)
    {
        return error.InvalidCancellationReason;
    }
    var transitions: std.ArrayList(manager_mod.WorkTransitionInput) = .empty;
    defer transitions.deinit(alloc);
    for (record.queue) |*message| {
        switch (message.status) {
            .pending, .running, .awaiting_approval => {},
            .completed, .failed, .cancelled, .interrupted => continue,
        }
        const owned_reason = try alloc.dupe(u8, reason);
        if (message.cancellation_reason) |old| alloc.free(old);
        message.cancellation_reason = owned_reason;
        const previous = message.status;
        message.status = .cancelled;
        try transitions.append(alloc, .{
            .work_item_id = message.id,
            .previous = previous,
            .current = .cancelled,
            .reason = message.cancellation_reason,
        });
    }
    if (transitions.items.len == 0) return 0;
    record.updated_at_ms = timestamp_ms;
    record.state = if (record.mode == .one_off)
        .cancelled
    else
        remainingWorkState(record.queue) orelse .idle;
    manager_mod.appendWorkRevision(alloc, record, transitions.items, timestamp_ms) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.GenerationExhausted => error.InvalidWorkState,
        };
    return transitions.items.len;
}

pub const RestartRecovery = struct {
    interrupted: usize = 0,
    completed: usize = 0,
};

/// Pure restart reduction. No work becomes runnable and no model/tool callback
/// is involved. The caller commits the candidate under the control lock.
pub fn recoverAfterRestart(
    alloc: Allocator,
    record: *control_store.Record,
    committed_work_id: ?[]const u8,
    timestamp_ms: i64,
) TransitionError!RestartRecovery {
    const reason = "interrupted by process restart";
    var result: RestartRecovery = .{};
    var transitions: std.ArrayList(manager_mod.WorkTransitionInput) = .empty;
    defer transitions.deinit(alloc);
    for (record.queue) |*message| {
        switch (message.status) {
            .pending, .running, .awaiting_approval => {},
            .completed, .failed, .cancelled, .interrupted => continue,
        }
        const previous = message.status;
        if (committed_work_id) |work_id| {
            if (previous != .pending and std.mem.eql(u8, message.id, work_id)) {
                if (message.cancellation_reason) |old| alloc.free(old);
                message.cancellation_reason = null;
                message.status = .completed;
                result.completed += 1;
                try transitions.append(alloc, .{
                    .work_item_id = message.id,
                    .previous = previous,
                    .current = .completed,
                });
                continue;
            }
        }
        const owned_reason = try alloc.dupe(u8, reason);
        if (message.cancellation_reason) |old| alloc.free(old);
        message.cancellation_reason = owned_reason;
        message.status = .interrupted;
        result.interrupted += 1;
        try transitions.append(alloc, .{
            .work_item_id = message.id,
            .previous = previous,
            .current = .interrupted,
            .reason = message.cancellation_reason,
        });
    }
    if (transitions.items.len != 0) {
        record.state = if (result.interrupted != 0)
            .interrupted
        else if (record.mode == .one_off)
            .completed
        else
            .idle;
        record.updated_at_ms = timestamp_ms;
        manager_mod.appendWorkRevision(alloc, record, transitions.items, timestamp_ms) catch |err|
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.GenerationExhausted => error.InvalidWorkState,
            };
    }
    return result;
}

fn appendSingleTransition(
    alloc: Allocator,
    record: *control_store.Record,
    work_id: []const u8,
    previous: ?domain.QueueStatus,
    current: domain.QueueStatus,
    reason: ?[]const u8,
    timestamp_ms: i64,
) TransitionError!void {
    manager_mod.appendWorkRevision(alloc, record, &.{.{
        .work_item_id = work_id,
        .previous = previous,
        .current = current,
        .reason = reason,
    }}, timestamp_ms) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.GenerationExhausted => error.InvalidWorkState,
    };
}

fn findWork(queue: []domain.QueuedMessage, id: []const u8) ?*domain.QueuedMessage {
    for (queue) |*message| if (std.mem.eql(u8, message.id, id)) return message;
    return null;
}

fn hasPending(queue: []const domain.QueuedMessage) bool {
    for (queue) |message| if (message.status == .pending) return true;
    return false;
}

fn remainingWorkState(queue: []const domain.QueuedMessage) ?domain.State {
    for (queue) |message| switch (message.status) {
        .running => return .running,
        .awaiting_approval => return .awaiting_approval,
        .interrupted => return .interrupted,
        .pending => return .queued,
        .completed, .failed, .cancelled => {},
    };
    return null;
}

pub const CaptureRequest = struct {
    child_id: []const u8,
    parent_id: []const u8,
    source_id: []const u8,
    configuration: domain.Configuration,
    preferences: TurnPreferences,
};

pub const RunOutcome = enum {
    completed,
    awaiting_approval,
    paused,
};

pub const ServiceError = error{
    OutOfMemory,
    AdmissionFailed,
    ProviderFailed,
    Cancelled,
};

pub const Services = struct {
    context: ?*anyopaque = null,
    capture_fn: *const fn (?*anyopaque, Allocator, CaptureRequest) ServiceError!domain.AdmissionSnapshot,
    run_fn: *const fn (?*anyopaque, *TurnContext, domain.QueuedMessage, domain.AdmissionSnapshot, *std.atomic.Value(bool)) ServiceError!RunOutcome,

    fn capture(self: Services, alloc: Allocator, request: CaptureRequest) ServiceError!domain.AdmissionSnapshot {
        return self.capture_fn(self.context, alloc, request);
    }

    fn run(
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

pub const max_live_presentation_bytes: usize = 64 * 1024;
pub const max_live_tool_activity: usize = 32;
pub const max_live_tool_name_bytes: usize = 128;
pub const max_live_presentation_events: usize = 256;
pub const max_live_presentation_event_bytes: usize = 128 * 1024;
const recovery_paused_reason = "model response recovery paused; resume this subagent to continue";

pub const LiveToolActivity = struct {
    tool_name: []u8,
    phase: runtime_deps.ToolActivityPhase,

    pub fn deinit(self: *LiveToolActivity, alloc: Allocator) void {
        alloc.free(self.tool_name);
        self.* = undefined;
    }

    fn clone(self: LiveToolActivity, alloc: Allocator) !LiveToolActivity {
        return .{
            .tool_name = try alloc.dupe(u8, self.tool_name),
            .phase = self.phase,
        };
    }
};

/// Allocator-owned copy of presentation that has not entered canonical
/// history. It exists only while the corresponding execution slot is live.
pub const LivePresentation = struct {
    work_id: []u8,
    revision: u64,
    text: []u8,
    text_truncated: bool,
    tools: []LiveToolActivity,
    tools_truncated: bool,
    events: []worker_runtime.WorkerEvent,
    events_truncated: bool,

    pub fn deinit(self: *LivePresentation, alloc: Allocator) void {
        alloc.free(self.work_id);
        alloc.free(self.text);
        for (self.tools) |*tool| tool.deinit(alloc);
        alloc.free(self.tools);
        for (self.events) |event| worker_runtime.freeWorkerEvent(alloc, event);
        alloc.free(self.events);
        self.* = undefined;
    }
};

const LivePresentationSink = struct {
    context: *anyopaque,
    append_text_fn: *const fn (*anyopaque, []const u8) void,
    append_tool_fn: *const fn (
        *anyopaque,
        []const u8,
        runtime_deps.ToolActivityPhase,
    ) void,
    append_event_fn: *const fn (
        *anyopaque,
        worker_runtime.WorkerEvent,
    ) void,

    fn appendText(self: LivePresentationSink, text: []const u8) void {
        self.append_text_fn(self.context, text);
    }

    fn appendTool(
        self: LivePresentationSink,
        tool_name: []const u8,
        phase: runtime_deps.ToolActivityPhase,
    ) void {
        self.append_tool_fn(self.context, tool_name, phase);
    }

    fn appendEvent(
        self: LivePresentationSink,
        event: worker_runtime.WorkerEvent,
    ) void {
        self.append_event_fn(self.context, event);
    }
};

/// One live ordinary child session. It is never shared with the main App or a
/// sibling child and is destroyed immediately when the child queue goes idle.
pub const TurnContext = struct {
    alloc: Allocator,
    runtime: session.SessionRuntime,
    worker: worker_runtime.WorkerRuntime = .{},
    loaded: *session_store.LoadedWritableSession,
    live_authority: ?*authority_mod.Resolver = null,
    approval_registry: ?*approval_registry_mod.Registry = null,
    tool_activity_store: ?*const communication_store.Store = null,
    child_id: ?[]const u8 = null,
    active_work_id: ?[]const u8 = null,
    live_presentation: ?LivePresentationSink = null,
    failure_diagnostic: ?[]u8 = null,
    committed: bool = false,

    fn init(
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
            loaded.state.context_history_start,
            loaded.state.permission_state,
        );
        return .{ .alloc = alloc, .runtime = runtime, .loaded = loaded };
    }

    fn deinit(self: *TurnContext) void {
        if (self.failure_diagnostic) |diagnostic| self.alloc.free(diagnostic);
        self.worker.deinit(self.alloc);
        self.runtime.deinit(self.alloc);
        self.* = undefined;
    }

    /// Retains the first bounded, model-safe diagnostic for the current child
    /// turn. Durable publication remains owned by the completion reducer.
    pub fn setFailureDiagnostic(
        self: *TurnContext,
        code: []const u8,
        detail: []const u8,
    ) Allocator.Error!void {
        if (self.failure_diagnostic != null) return;
        const safe_detail = if (text_utils.isModelSafeText(detail))
            text_utils.utf8PrefixByBytes(
                detail,
                domain.max_cancellation_reason_bytes -| code.len -| 2,
            )
        else
            "";
        self.failure_diagnostic = if (safe_detail.len == 0)
            try self.alloc.dupe(u8, text_utils.utf8PrefixByBytes(
                code,
                domain.max_cancellation_reason_bytes,
            ))
        else
            try std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ code, safe_detail });
    }

    pub fn failureDiagnostic(self: *const TurnContext) ?[]const u8 {
        return self.failure_diagnostic;
    }

    pub fn sessionRuntime(self: *TurnContext) *session.SessionRuntime {
        return &self.runtime;
    }

    pub fn snapshotRecoveryCheckpoint(
        self: *const TurnContext,
        alloc: Allocator,
    ) Allocator.Error!?session_codec.RecoveryCheckpoint {
        const checkpoint = self.loaded.state.recovery_checkpoint orelse return null;
        return try checkpoint.dupe(alloc);
    }

    pub fn childCapability(self: *TurnContext) !*session_child_store.SessionChildCapability {
        return self.loaded.childCapability();
    }

    pub fn workerRuntime(self: *TurnContext) *worker_runtime.WorkerRuntime {
        return &self.worker;
    }

    /// Presentation-only output. Allocation pressure never changes execution
    /// semantics; the bounded live owner records truncation instead.
    pub fn appendLiveText(self: *TurnContext, text: []const u8) void {
        if (self.live_presentation) |sink| sink.appendText(text);
    }

    /// Presentation-only event. The execution owner retains a bounded clone,
    /// while the caller keeps ownership of the supplied worker event.
    pub fn appendLiveEvent(
        self: *TurnContext,
        event: worker_runtime.WorkerEvent,
    ) void {
        if (self.live_presentation) |sink| sink.appendEvent(event);
    }

    /// Returns an owned current authority snapshot. Normal-agent permission,
    /// availability and integration adapters call this for every
    /// child tool action rather than retaining the admission-time copy.
    pub fn resolveLiveAuthority(
        self: *TurnContext,
        alloc: Allocator,
    ) authority_mod.Error!authority_mod.Snapshot {
        const resolver = self.live_authority orelse
            return error.HostAuthorityUnavailable;
        return resolver.resolve(alloc, self.child_id orelse
            return error.ChildNotAttached);
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
        const prepared = communication.preparedRequestFingerprint(request);
        const grant = types.PermissionGrant{
            .tool_name = @constCast(call.name),
            .target_path = @constCast(request.command orelse call.name),
        };
        var context = PermissionObservation{
            .turn = self,
            .stable_id = communication.stableApprovalId(child_id, work_id, prepared),
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
                io_mod.milliTimestamp(),
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
        const decision = try communication.decideToolAuthority(
            alloc,
            snapshot.view(),
            workspace_root,
            call.name,
            target,
            target_kind,
        );
        // LiveToolAuthority is returned by value, so its state header cannot
        // point at the local snapshot even though the rule storage uses alloc.
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
        raw: *anyopaque,
        call_id: []const u8,
        tool_name: []const u8,
        phase: runtime_deps.ToolActivityPhase,
    ) !void {
        const self: *TurnContext = @ptrCast(@alignCast(raw));
        if (self.live_presentation) |sink| sink.appendTool(tool_name, phase);
        const child_id = self.child_id orelse return error.ChildNotAttached;
        const work_id = self.active_work_id orelse return error.StaleRequest;
        const store = if (self.tool_activity_store) |value|
            value.*
        else blk: {
            const capability = try self.childCapability();
            break :blk communication_store.Store{
                .capability = capability,
                .expected_session_id = child_id,
            };
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var authority = try self.resolveLiveAuthority(self.alloc);
        defer authority.deinit(self.alloc);
        const existing = try store.loadOptional(self.alloc);
        var ledger = if (existing) |value|
            value
        else
            try communication.Ledger.init(self.alloc, child_id);
        defer ledger.deinit(self.alloc);
        const activity_phase: communication.ToolActivityPhase = switch (phase) {
            .started => .started,
            .succeeded => .succeeded,
            .failed => .failed,
            .denied => .denied,
        };
        const id = communication.stableToolActivityId(
            child_id,
            work_id,
            call_id,
            activity_phase,
        );
        const appended = try communication.appendDelivery(self.alloc, &ledger, .{
            .id = &id,
            .source_id = child_id,
            .target_id = authority.root_id,
            .work_id = work_id,
            .timestamp_ms = io_mod.milliTimestamp(),
            .payload = .{ .tool_activity = .{
                .tool_name = tool_name,
                .phase = activity_phase,
            } },
        });
        if (appended == .appended) try store.save(self.alloc, ledger);
    }

    /// Registers one canonical unresolved request using authenticated runtime
    /// child/work/root identity. Model fields cannot select any of these IDs.
    pub fn registerApproval(
        self: *TurnContext,
        alloc: Allocator,
        stable_request_id: []const u8,
        request: permission_request.PermissionRequest,
        grants: []const types.PermissionGrant,
        timestamp_ms: i64,
    ) (approval_registry_mod.Error || authority_mod.Error)!void {
        const registry = self.approval_registry orelse
            return error.RegistryClosed;
        const child_id = self.child_id orelse return error.ChildNotAttached;
        const work_id = self.active_work_id orelse return error.StaleRequest;
        var authority = try self.resolveLiveAuthority(alloc);
        defer authority.deinit(alloc);
        try self.transitionApprovalWork(work_id, .awaiting_approval, timestamp_ms);
        registry.registerTool(
            stable_request_id,
            child_id,
            authority.root_id,
            work_id,
            request,
            grants,
            &self.worker,
            timestamp_ms,
        ) catch |err| {
            try self.transitionApprovalWork(work_id, .running, timestamp_ms);
            return err;
        };
    }

    fn transitionApprovalWork(
        self: *TurnContext,
        work_id: []const u8,
        target: domain.QueueStatus,
        timestamp_ms: i64,
    ) (approval_registry_mod.Error || authority_mod.Error)!void {
        const capability = self.childCapability() catch return error.CommitFailed;
        var store = control_store.Store{
            .capability = capability,
            .expected_child_id = self.child_id orelse return error.ChildNotAttached,
        };
        var lock = store.acquireLock() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CommitFailed,
        };
        defer lock.release();
        var record = store.load(self.alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CommitFailed,
        };
        defer record.deinit(self.alloc);
        const transition = switch (target) {
            .awaiting_approval => work_events.awaitApproval(
                self.alloc,
                &record,
                work_id,
                timestamp_ms,
            ),
            .running => work_events.resumeApproval(
                self.alloc,
                &record,
                work_id,
                timestamp_ms,
            ),
            else => unreachable,
        } catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.GenerationExhausted => error.CommitFailed,
        };
        switch (transition) {
            .changed => store.save(self.alloc, record) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.CommitFailed,
            },
            .already_in_state => {},
            .cancellation_won, .stale_work => return error.StaleRequest,
        }
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
        var committed_turn = session.dupeHistoryTurn(self.alloc, turn) catch
            return error.OutOfMemory;
        defer session.freeHistoryTurn(self.alloc, committed_turn);
        session.copyWorkIdToTurn(self.alloc, &committed_turn, work_id) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidWorkId, error.ConflictingWorkId => error.InvalidWorkId,
            };
        };
        self.runtime.appendHistoryEntry(self.alloc, committed_turn) catch
            return error.OutOfMemory;
        _ = self.loaded.appendEvent(
            self.alloc,
            .{ .history_turn_committed = .{
                .conversation_language = self.runtime.languageSnapshot(),
                .total_input_tokens = total_input_tokens,
                .total_output_tokens = total_output_tokens,
                .work_id = @constCast(work_id),
                .turn = committed_turn,
            } },
            timestamp_ms,
            .retry_expected_tail,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionCommitFailed,
        };
        self.committed = true;
    }

    pub fn setRecoveryCheckpoint(
        self: *TurnContext,
        checkpoint: session_codec.RecoveryCheckpoint,
        timestamp_ms: i64,
    ) CommitError!void {
        _ = self.loaded.appendEvent(
            self.alloc,
            .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
            timestamp_ms,
            .retry_expected_tail,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EventFrameTooLarge => {
                var current = self.loaded.state.dupe(self.alloc) catch
                    return error.OutOfMemory;
                defer current.deinit(self.alloc);
                if (current.recovery_checkpoint) |*old| old.deinit(self.alloc);
                current.recovery_checkpoint = checkpoint.dupe(self.alloc) catch
                    return error.OutOfMemory;
                current.updated_at_ms = timestamp_ms;
                _ = self.loaded.commitStateReplacement(
                    self.alloc,
                    current,
                    .compaction,
                    .retry_expected_tail,
                    .{},
                ) catch |replacement_err| return switch (replacement_err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SessionCommitFailed,
                };
            },
            else => return error.SessionCommitFailed,
        };
    }
};

/// The production adapter uses the same orchestrator as interactive, ask, and
/// ACP execution. Host-specific dependency assembly stays outside the manager.
pub const NormalAgentError = error{
    OutOfMemory,
    Cancelled,
    AgentExecutionFailed,
};

pub fn runNormalAgentTurn(
    deps: *const runtime_deps.AgentRuntimeDeps,
    semantic_presentation: ?runtime_assistant_stream.SemanticPresentationSink,
    lifecycle: runtime_lifecycle.LifecycleContext,
    config: runtime_config.Config,
    prompt: worker_runtime.QueuedPrompt,
) NormalAgentError!void {
    agent_runtime.processQueuedPrompt(
        deps,
        semantic_presentation,
        lifecycle,
        config,
        prompt,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        else => error.AgentExecutionFailed,
    };
}

pub const StartResult = enum {
    started,
    already_running,
};

pub const StartError = error{
    OutOfMemory,
    OwnerClosed,
    ThreadSpawnFailed,
};

pub const ChildResult = enum {
    idle,
    completed,
    failed,
    cancelled,
    awaiting_approval,
    paused,
    external_busy,
    no_work,
    session_failed,
    control_failed,
    admission_failed,
    owner_stopped,
};

pub const JoinError = error{
    ChildNotActive,
    JoinInProgress,
};

pub const ControlError = error{
    OutOfMemory,
    ChildNotFound,
    ControlLockBusy,
    ControlLockUnsupported,
    ControlStoreFailed,
    ExternalBusy,
};

pub const RecoveryReport = struct {
    sessions_changed: usize = 0,
    work_interrupted: usize = 0,
    work_completed: usize = 0,
    sessions_external_busy: usize = 0,
    sessions_failed: usize = 0,

    pub fn fullyReconciled(self: RecoveryReport) bool {
        return self.sessions_external_busy == 0 and self.sessions_failed == 0;
    }
};

pub const RecoveryError = error{
    OutOfMemory,
    SessionStoreUnavailable,
};

pub const NotificationClock = struct {
    context: ?*anyopaque = null,
    now_fn: *const fn (?*anyopaque) i64,

    fn now_ms(self: NotificationClock) i64 {
        return self.now_fn(self.context);
    }
};

pub const NotificationPoller = struct {
    context: ?*anyopaque = null,
    poll_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        []const u8,
        i64,
    ) communication_manager.Error!communication_manager.PollOutcome,

    fn poll(
        self: NotificationPoller,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        now_ms: i64,
    ) communication_manager.Error!communication_manager.PollOutcome {
        return self.poll_fn(self.context, alloc, child_id, work_id, now_ms);
    }
};

pub const NotificationPollReport = struct {
    registered: usize = 0,
    due: usize = 0,
    emitted: usize = 0,
    stopped: usize = 0,
    retryable_failures: usize = 0,
};

const SlotFinalizer = enum {
    none,
    caller,
    reaper,
};

const LivePresentationState = struct {
    work_id: ?[]u8 = null,
    revision: u64 = 0,
    text: std.ArrayList(u8) = .empty,
    text_truncated: bool = false,
    tools: std.ArrayList(LiveToolActivity) = .empty,
    tools_truncated: bool = false,
    events: std.ArrayList(worker_runtime.WorkerEvent) = .empty,
    event_bytes: usize = 0,
    events_truncated: bool = false,

    fn deinit(self: *LivePresentationState, alloc: Allocator) void {
        self.clear(alloc);
        self.text.deinit(alloc);
        self.tools.deinit(alloc);
        self.events.deinit(alloc);
        self.* = .{};
    }

    fn clear(self: *LivePresentationState, alloc: Allocator) void {
        if (self.work_id) |work_id| alloc.free(work_id);
        self.work_id = null;
        self.text.clearRetainingCapacity();
        self.text_truncated = false;
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.clearRetainingCapacity();
        self.tools_truncated = false;
        for (self.events.items) |event| worker_runtime.freeWorkerEvent(alloc, event);
        self.events.clearRetainingCapacity();
        self.event_bytes = 0;
        self.events_truncated = false;
        self.revision +%= 1;
    }

    fn begin(self: *LivePresentationState, alloc: Allocator, work_id: []const u8) !void {
        self.clear(alloc);
        self.work_id = try alloc.dupe(u8, work_id);
    }

    fn appendText(self: *LivePresentationState, alloc: Allocator, value: []const u8) void {
        if (self.work_id == null or value.len == 0) return;
        const remaining = max_live_presentation_bytes -| self.text.items.len;
        const take = @min(remaining, value.len);
        if (take > 0) self.text.appendSlice(alloc, value[0..take]) catch {
            self.text_truncated = true;
            return;
        };
        if (take < value.len) self.text_truncated = true;
        self.revision +%= 1;
    }

    fn appendTool(
        self: *LivePresentationState,
        alloc: Allocator,
        tool_name: []const u8,
        phase: runtime_deps.ToolActivityPhase,
    ) void {
        if (self.work_id == null) return;
        if (self.tools.items.len >= max_live_tool_activity) {
            self.tools_truncated = true;
            self.revision +%= 1;
            return;
        }
        const bounded_name = tool_name[0..@min(tool_name.len, max_live_tool_name_bytes)];
        const owned_name = alloc.dupe(u8, bounded_name) catch {
            self.tools_truncated = true;
            return;
        };
        self.tools.append(alloc, .{
            .tool_name = owned_name,
            .phase = phase,
        }) catch {
            alloc.free(owned_name);
            self.tools_truncated = true;
            return;
        };
        self.revision +%= 1;
    }

    fn appendEvent(
        self: *LivePresentationState,
        alloc: Allocator,
        event: worker_runtime.WorkerEvent,
    ) void {
        if (self.work_id == null) return;
        const event_bytes = livePresentationEventBytes(event) orelse return;
        if (self.events.items.len >= max_live_presentation_events or
            event_bytes > max_live_presentation_event_bytes -| self.event_bytes)
        {
            self.events_truncated = true;
            self.revision +%= 1;
            return;
        }
        const owned = worker_runtime.dupeWorkerEvent(alloc, event) catch {
            self.events_truncated = true;
            self.revision +%= 1;
            return;
        };
        self.events.append(alloc, owned) catch {
            worker_runtime.freeWorkerEvent(alloc, owned);
            self.events_truncated = true;
            self.revision +%= 1;
            return;
        };
        self.event_bytes += event_bytes;
        self.revision +%= 1;
    }

    fn clone(self: LivePresentationState, alloc: Allocator) !?LivePresentation {
        const source_work_id = self.work_id orelse return null;
        const work_id = try alloc.dupe(u8, source_work_id);
        errdefer alloc.free(work_id);
        const text = try alloc.dupe(u8, self.text.items);
        errdefer alloc.free(text);
        const tools = try alloc.alloc(LiveToolActivity, self.tools.items.len);
        var built: usize = 0;
        errdefer {
            for (tools[0..built]) |*tool| tool.deinit(alloc);
            alloc.free(tools);
        }
        for (self.tools.items) |tool| {
            tools[built] = try tool.clone(alloc);
            built += 1;
        }
        const events = try alloc.alloc(
            worker_runtime.WorkerEvent,
            self.events.items.len,
        );
        var events_built: usize = 0;
        errdefer {
            for (events[0..events_built]) |event| {
                worker_runtime.freeWorkerEvent(alloc, event);
            }
            alloc.free(events);
        }
        for (self.events.items) |event| {
            events[events_built] = try worker_runtime.dupeWorkerEvent(
                alloc,
                event,
            );
            events_built += 1;
        }
        return .{
            .work_id = work_id,
            .revision = self.revision,
            .text = text,
            .text_truncated = self.text_truncated,
            .tools = tools,
            .tools_truncated = self.tools_truncated,
            .events = events,
            .events_truncated = self.events_truncated,
        };
    }
};

fn livePresentationEventBytes(event: worker_runtime.WorkerEvent) ?usize {
    return switch (event) {
        .assistant_presentation => |presentation| presentation.retainedByteCount(),
        .append_user_feedback,
        .api_status_text,
        => |text| text.len,
        .command_output_complete,
        .clear_route_recovery_status,
        .route_recovery_status,
        .turn_token_update,
        .tool_payload_started,
        => 1,
        .semantic_notice, .error_text => |notice| notice.topic.len +| notice.body.len,
        .command_output => |chunk| chunk.text.len +|
            if (chunk.lifecycle_id) |id| id.call_id.len else 0,
        .tool_lifecycle => |lifecycle| switch (lifecycle) {
            .provisional => |value| value.id.call_id.len +|
                if (value.tool_name) |name| name.len else 0,
            .authoritative_started => |value| value.id.call_id.len +|
                value.tool_name.len +|
                (if (value.reconciles_provisional_call_id) |id| id.len else 0) +|
                (if (value.arguments_json) |arguments| arguments.len else 0),
            .progress => |value| value.id.call_id.len +| value.text.len,
            .terminal => |value| value.id.call_id.len +|
                value.outcome.summary.len +|
                (if (value.result) |result| result.len else 0) +|
                (if (value.command_artifact_handle) |handle| handle.len else 0),
            .turn_finished => 1,
        },
        .diff_block => |payload| payload.preview.len +|
            if (payload.full) |full| full.content.len +| full.lifecycle_id.call_id.len else 0,
        .begin_prompt,
        .begin_prompt_with_skill_bindings,
        .finish_prompt,
        .notification,
        .question_requested,
        .open_model_picker,
        .session_grant,
        => null,
    };
}

const Slot = struct {
    owner: *Owner,
    child_id: []u8,
    retry_interrupted: bool,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_worker: ?*worker_runtime.WorkerRuntime = null,
    result: ChildResult = .no_work,
    thread: ?std.Thread = null,
    finalizer: SlotFinalizer = .none,
    finished: bool = false,
    wake_requested: bool = false,
    restart_failed: bool = false,
    live: LivePresentationState = .{},
};

const completion_capacity = 64;

const Completion = struct {
    child_id: []u8,
    result: ChildResult,
};

const NotificationSchedule = struct {
    child_id: []u8,
    work_id: []u8,
    next_check_ms: i64,

    fn deinit(self: *NotificationSchedule, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.work_id);
        self.* = undefined;
    }
};

const DueNotification = struct {
    child_id: []u8,
    work_id: []u8,

    fn deinit(self: *DueNotification, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.work_id);
        self.* = undefined;
    }
};

const notification_retry_delay_ms: i64 = 25;
const max_recovery_snapshot_restarts: usize = 3;

pub const ChildWaitResult = enum {
    signaled,
    timed_out,
};

pub const ChildWaiter = struct {
    child_id: []const u8,
    event: std.Io.Event = .unset,
    registered: bool = false,

    pub fn wait(
        self: *ChildWaiter,
        duration: std.Io.Clock.Duration,
    ) error{Canceled}!ChildWaitResult {
        self.event.waitTimeout(
            io_mod.getIo(),
            .{ .duration = duration },
        ) catch |err| return switch (err) {
            error.Timeout => .timed_out,
            error.Canceled => error.Canceled,
        };
        return .signaled;
    }
};

/// Manager-owned live execution owner. Callers must not move an Owner after the
/// first `start`; child threads retain its address until `join`/`deinit`.
pub const Owner = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    manager: *manager_mod.Manager,
    services: Services,
    child_store_options: session_child_store.Options = .{},
    communication_store_options: session_child_store.Options = .{},
    /// Canonical session-resume controls. Production keeps the store defaults;
    /// lock-contention tests inject an immediate deadline.
    session_resume_options: session_store.ResumeOptions = .{},
    /// Borrowed and must outlive all started child threads.
    live_authority: ?*authority_mod.Resolver = null,
    /// Borrowed and must outlive all started child threads.
    approval_registry: ?*approval_registry_mod.Registry = null,
    notification_clock: ?NotificationClock = null,
    notification_poller: ?NotificationPoller = null,
    /// Borrowed from the host and valid until `deinit` joins the reaper.
    retirement_root_id: ?[]const u8 = null,
    retirement_cursor: ?[]u8 = null,
    retirement_scan_pending: bool = false,
    retirement_due_ms: ?i64 = null,
    retirement_retry_after_scan: bool = false,
    max_history_turns: usize = 8,
    mutex: std.Io.Mutex = .init,
    reaper_cond: std.Io.Condition = .init,
    reaper_wake: std.Io.Event = .unset,
    reaper_thread: ?std.Thread = null,
    slots: std.ArrayList(*Slot) = .empty,
    child_waiters: std.ArrayList(*ChildWaiter) = .empty,
    notification_schedules: std.ArrayList(NotificationSchedule) = .empty,
    recovery_external_busy: std.ArrayList([]u8) = .empty,
    completions: [completion_capacity]?Completion = [_]?Completion{null} ** completion_capacity,
    completion_cursor: usize = 0,
    started_any: bool = false,
    closed: bool = false,

    pub fn start(
        self: *Owner,
        child_id: []const u8,
        retry_interrupted: bool,
    ) StartError!StartResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.OwnerClosed;
        try self.ensureReaperLocked();
        self.dropCompletionLocked(child_id);
        for (self.slots.items) |slot| {
            if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
            slot.retry_interrupted = slot.retry_interrupted or retry_interrupted;
            slot.wake_requested = true;
            slot.restart_failed = false;
            self.reaper_cond.broadcast(io_mod.getIo());
            self.reaper_wake.set(io_mod.getIo());
            return .already_running;
        }

        const slot = try self.alloc.create(Slot);
        errdefer self.alloc.destroy(slot);
        const owned_id = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_id);
        slot.* = .{
            .owner = self,
            .child_id = owned_id,
            .retry_interrupted = retry_interrupted,
        };
        try self.slots.append(self.alloc, slot);
        errdefer _ = self.slots.pop();
        slot.thread = std.Thread.spawn(.{}, slotMain, .{slot}) catch
            return error.ThreadSpawnFailed;
        self.started_any = true;
        return .started;
    }

    pub fn join(self: *Owner, child_id: []const u8) JoinError!ChildResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        while (true) {
            const slot = self.findSlotLocked(child_id) orelse {
                if (self.takeCompletionLocked(child_id)) |result| {
                    self.mutex.unlock(io_mod.getIo());
                    return result;
                }
                self.mutex.unlock(io_mod.getIo());
                return error.ChildNotActive;
            };
            switch (slot.finalizer) {
                .caller => {
                    self.mutex.unlock(io_mod.getIo());
                    return error.JoinInProgress;
                },
                .reaper => {
                    self.reaper_cond.wait(io_mod.getIo(), &self.mutex) catch {};
                    continue;
                },
                .none => {},
            }
            slot.finalizer = .caller;
            self.mutex.unlock(io_mod.getIo());
            if (slot.thread) |thread| thread.join();
            const result = slot.result;
            self.mutex.lockUncancelable(io_mod.getIo());
            if (self.shouldRestartLocked(slot)) {
                self.restartJoinedSlotLocked(slot);
                self.reaper_cond.broadcast(io_mod.getIo());
                self.mutex.unlock(io_mod.getIo());
                return result;
            }
            self.removeSlotLocked(slot);
            slot.live.deinit(self.alloc);
            self.alloc.free(slot.child_id);
            self.alloc.destroy(slot);
            self.reaper_cond.broadcast(io_mod.getIo());
            self.mutex.unlock(io_mod.getIo());
            return result;
        }
    }

    pub fn requestRetirementSweep(
        self: *Owner,
        timestamp_ms: i64,
    ) StartError!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.OwnerClosed;
        if (self.retirement_root_id == null) return;
        try self.ensureReaperLocked();
        self.scheduleRetirementSweepLocked(timestamp_ms);
    }

    /// Returns the latest in-memory execution outcome without consuming it.
    /// Durable child lifecycle remains authoritative for every other state;
    /// this narrow observation exists for outcomes such as external writer
    /// contention that cannot be committed to the child control record.
    pub fn lastResult(self: *Owner, child_id: []const u8) ?ChildResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.findSlotLocked(child_id)) |slot| {
            if (slot.finished) return slot.result;
        }
        for (self.completions) |maybe_completion| {
            const completion = maybe_completion orelse continue;
            if (std.mem.eql(u8, completion.child_id, child_id)) {
                return completion.result;
            }
        }
        return null;
    }

    /// Returns whether this process has observed another live session writer
    /// for the child, either through local execution or restart recovery.
    pub fn externalBusy(self: *Owner, child_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.findSlotLocked(child_id)) |slot| {
            if (slot.finished and slot.result == .external_busy) return true;
        }
        for (self.completions) |maybe_completion| {
            const completion = maybe_completion orelse continue;
            if (completion.result == .external_busy and
                std.mem.eql(u8, completion.child_id, child_id))
            {
                return true;
            }
        }
        for (self.recovery_external_busy.items) |observed_child_id| {
            if (std.mem.eql(u8, observed_child_id, child_id)) return true;
        }
        return false;
    }

    pub fn registerChildWaiter(
        self: *Owner,
        waiter: *ChildWaiter,
    ) error{ OutOfMemory, OwnerClosed }!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.OwnerClosed;
        std.debug.assert(!waiter.registered);
        try self.child_waiters.append(self.alloc, waiter);
        waiter.registered = true;
    }

    pub fn unregisterChildWaiter(self: *Owner, waiter: *ChildWaiter) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!waiter.registered) return;
        for (self.child_waiters.items, 0..) |registered, index| {
            if (registered != waiter) continue;
            _ = self.child_waiters.swapRemove(index);
            waiter.registered = false;
            self.reaper_cond.broadcast(io_mod.getIo());
            return;
        }
        unreachable;
    }

    /// Returns a deep copy of active, uncommitted presentation. Completed
    /// slots deliberately have no transcript cache.
    pub fn snapshotLivePresentation(
        self: *Owner,
        alloc: Allocator,
        child_id: []const u8,
    ) !?LivePresentation {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const slot = self.findSlotLocked(child_id) orelse return null;
        if (slot.finished) return null;
        return slot.live.clone(alloc);
    }

    /// Commits cancellation under `subagent-control.lock` before signaling the
    /// child worker. Late success observes the durable cancelled item and loses.
    pub fn cancel(
        self: *Owner,
        child_id: []const u8,
        reason: []const u8,
        timestamp_ms: i64,
    ) ControlError!usize {
        const count = try self.cancelDurable(child_id, reason, timestamp_ms);
        try self.completeCommittedCancellation(child_id, timestamp_ms);
        return count;
    }

    /// Completes the live side of an already committed cancellation. The live
    /// worker and waiters are signaled before fallible approval cleanup so a
    /// durable cancellation can never leave the child running.
    pub fn completeCommittedCancellation(
        self: *Owner,
        child_id: []const u8,
        timestamp_ms: i64,
    ) ControlError!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) {
                slot.cancel.store(true, .seq_cst);
                if (slot.active_worker) |worker| worker.requestCancel();
                break;
            }
        }
        self.signalChildWaitersLocked(child_id);
        self.mutex.unlock(io_mod.getIo());

        self.wakeNotificationSchedules(child_id, timestamp_ms);
        if (self.approval_registry) |registry| {
            _ = registry.invalidateChild(
                child_id,
                .cancelled,
                timestamp_ms,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.ControlStoreFailed,
            };
        }
    }

    /// Commits the approved Part 1 archive transition before cancelling and
    /// joining live work. The returned manager result is allocator-owned.
    pub fn close(
        self: *Owner,
        alloc: Allocator,
        child_id: []const u8,
        context: manager_mod.Context,
    ) (ControlError || manager_mod.ExecuteError)!manager_mod.Result {
        const command: domain.Command = .{ .lifecycle = .{
            .id = @constCast(child_id),
            .action = .close,
        } };
        var result = try self.manager.execute(alloc, command, context);
        errdefer result.deinit(alloc);
        if (result == .receipt) {
            try self.completeCommittedClose(child_id, context.timestamp_ms);
        }
        return result;
    }

    fn completeCommittedClose(
        self: *Owner,
        child_id: []const u8,
        timestamp_ms: i64,
    ) ControlError!void {
        try self.completeCommittedCancellation(child_id, timestamp_ms);
        self.mutex.lockUncancelable(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) {
                slot.shutdown.store(true, .seq_cst);
                break;
            }
        }
        self.mutex.unlock(io_mod.getIo());
        _ = self.join(child_id) catch |err| switch (err) {
            error.ChildNotActive => {},
            error.JoinInProgress => return error.ControlStoreFailed,
        };
        self.stopNotificationPolicies(child_id, timestamp_ms);
    }

    /// Detaches through the durable manager, then removes periodic policy only
    /// after its stopped state is committed.
    pub fn detach(
        self: *Owner,
        alloc: Allocator,
        child_id: []const u8,
        context: manager_mod.Context,
    ) manager_mod.ExecuteError!manager_mod.Result {
        const command: domain.Command = .{ .relationship = .{
            .action = .detach,
            .id = @constCast(child_id),
            .parent_id = null,
        } };
        const result = try self.manager.execute(alloc, command, context);
        if (result == .receipt) {
            self.stopNotificationPolicies(child_id, context.timestamp_ms);
        }
        return result;
    }

    /// Reconciles unfinished durable work without starting any child thread.
    pub fn recover(self: *Owner, timestamp_ms: i64) RecoveryError!RecoveryReport {
        var ids = self.sessions.listSubagentControlSessionIds(self.alloc) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.SessionStoreUnavailable => error.SessionStoreUnavailable,
            };
        };
        defer {
            for (ids.items) |id| self.alloc.free(id);
            ids.deinit(self.alloc);
        }
        var report: RecoveryReport = .{};
        for (ids.items) |id| {
            try self.recoverCandidate(&report, id, timestamp_ms);
        }
        return report;
    }

    /// Reconciles only canonical descendants of `root_id`. Relationship-index
    /// traversal is authoritative; ordinary chats outside the tree are never
    /// opened or replayed. Concurrent relationship changes restart the bounded
    /// traversal without duplicating durable effects.
    pub fn recoverTree(
        self: *Owner,
        root_id: []const u8,
        timestamp_ms: i64,
    ) RecoveryError!RecoveryReport {
        domain.validateId(root_id) catch return error.SessionStoreUnavailable;
        var root_capability = self.sessions.openSubagentControlCapabilityReadOnly(
            self.alloc,
            root_id,
            self.child_store_options,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionNotFound => .{},
            else => error.SessionStoreUnavailable,
        };
        root_capability.deinit();

        var report: RecoveryReport = .{};
        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.alloc.free(value);
        var restarts: usize = 0;

        while (true) {
            var result = self.manager.snapshot(self.alloc, .{
                .root_id = root_id,
                .cursor = cursor,
                .limit = domain.max_page_limit,
            }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
            };
            defer result.deinit(self.alloc);

            const snapshot = switch (result) {
                .failure => return error.SessionStoreUnavailable,
                .snapshot => |*value| value,
            };
            if (snapshot.restart_required) {
                restarts += 1;
                if (restarts > max_recovery_snapshot_restarts) {
                    return error.SessionStoreUnavailable;
                }
                if (cursor) |value| self.alloc.free(value);
                cursor = null;
                continue;
            }

            for (snapshot.nodes) |node| {
                try self.recoverCandidate(&report, node.child_id, timestamp_ms);
            }
            const next_cursor = if (snapshot.next_cursor) |value|
                try self.alloc.dupe(u8, value)
            else
                null;
            if (cursor) |value| self.alloc.free(value);
            cursor = next_cursor;
            if (cursor == null) return report;
        }
    }

    pub fn deinit(self: *Owner) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.retirement_scan_pending and self.retirement_root_id != null) {
            self.retirement_due_ms = reaperNowMs(self);
            self.mutex.unlock(io_mod.getIo());
            self.runRetirementSweep(reaperNowMs(self));
            self.mutex.lockUncancelable(io_mod.getIo());
        }
        self.closed = true;
        for (self.slots.items) |slot| {
            slot.shutdown.store(true, .seq_cst);
            slot.cancel.store(true, .seq_cst);
            if (slot.active_worker) |worker| worker.requestCancel();
        }
        self.signalChildWaitersLocked(null);
        self.reaper_cond.broadcast(io_mod.getIo());
        self.reaper_wake.set(io_mod.getIo());
        const reaper_thread = self.reaper_thread;
        self.mutex.unlock(io_mod.getIo());

        if (self.approval_registry) |registry| registry.detachWorkerRoutes();
        self.mutex.lockUncancelable(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (slot.active_worker) |worker| worker.requestShutdown();
        }
        self.mutex.unlock(io_mod.getIo());

        if (reaper_thread) |thread| thread.join();

        // Process teardown does not invent a user cancellation. Unfinished
        // durable state is reconciled after a later writer proves ownership.
        self.mutex.lockUncancelable(io_mod.getIo());
        while (self.slots.items.len != 0) {
            var selected: ?usize = null;
            for (self.slots.items, 0..) |slot, index| {
                if (slot.finalizer == .none) {
                    selected = index;
                    break;
                }
            }
            if (selected == null) {
                self.reaper_cond.wait(io_mod.getIo(), &self.mutex) catch {};
                continue;
            }
            const slot = self.slots.swapRemove(selected.?);
            slot.finalizer = .caller;
            self.mutex.unlock(io_mod.getIo());
            if (slot.thread) |thread| thread.join();
            slot.live.deinit(self.alloc);
            self.alloc.free(slot.child_id);
            self.alloc.destroy(slot);
            self.mutex.lockUncancelable(io_mod.getIo());
        }
        for (&self.completions) |*maybe_completion| {
            if (maybe_completion.*) |completion| self.alloc.free(completion.child_id);
            maybe_completion.* = null;
        }
        for (self.recovery_external_busy.items) |child_id| self.alloc.free(child_id);
        while (self.child_waiters.items.len != 0) {
            self.reaper_cond.waitUncancelable(io_mod.getIo(), &self.mutex);
        }
        self.mutex.unlock(io_mod.getIo());
        self.child_waiters.deinit(self.alloc);
        self.recovery_external_busy.deinit(self.alloc);
        for (self.notification_schedules.items) |*schedule| {
            schedule.deinit(self.alloc);
        }
        self.notification_schedules.deinit(self.alloc);
        if (self.retirement_cursor) |cursor| self.alloc.free(cursor);
        self.slots.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn pollNotifications(self: *Owner) error{OutOfMemory}!NotificationPollReport {
        const clock = self.notification_clock orelse return .{};
        const poller = self.notification_poller orelse return .{};
        const now_ms = clock.now_ms();
        var due: std.ArrayList(DueNotification) = .empty;
        defer {
            for (due.items) |*notification| notification.deinit(self.alloc);
            due.deinit(self.alloc);
        }

        var report = NotificationPollReport{};
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            if (self.closed) return report;
            report.registered = self.notification_schedules.items.len;
            for (self.notification_schedules.items) |schedule| {
                if (schedule.next_check_ms > now_ms) continue;
                const child_id = try self.alloc.dupe(u8, schedule.child_id);
                errdefer self.alloc.free(child_id);
                const work_id = try self.alloc.dupe(u8, schedule.work_id);
                errdefer self.alloc.free(work_id);
                try due.append(self.alloc, .{
                    .child_id = child_id,
                    .work_id = work_id,
                });
            }
        }

        for (due.items) |notification| {
            report.due += 1;
            const outcome = poller.poll(
                self.alloc,
                notification.child_id,
                notification.work_id,
                now_ms,
            ) catch |err| {
                if (isRetryableNotificationPollError(err)) {
                    report.retryable_failures += 1;
                    self.retryNotificationSchedule(
                        notification.child_id,
                        notification.work_id,
                        now_ms,
                    );
                    debug_trace.logf(
                        "subagent",
                        "periodic notification poll deferred child_id={s} work_id={s} outcome={s}",
                        .{ notification.child_id, notification.work_id, @errorName(err) },
                    );
                } else {
                    report.stopped += 1;
                    self.removeNotificationSchedules(
                        notification.child_id,
                        notification.work_id,
                    );
                    debug_trace.logf(
                        "subagent",
                        "periodic notification poll stopped child_id={s} work_id={s} outcome={s}",
                        .{ notification.child_id, notification.work_id, @errorName(err) },
                    );
                }
                continue;
            };
            switch (outcome) {
                .inactive => {
                    report.stopped += 1;
                    self.removeNotificationSchedules(
                        notification.child_id,
                        notification.work_id,
                    );
                },
                .pending => |next_check_ms| self.updateNotificationSchedule(
                    notification.child_id,
                    notification.work_id,
                    next_check_ms,
                ),
                .emitted => |emitted| {
                    report.emitted += 1;
                    if (emitted.next_check_ms) |next_check_ms| {
                        self.updateNotificationSchedule(
                            notification.child_id,
                            notification.work_id,
                            next_check_ms,
                        );
                    } else {
                        report.stopped += 1;
                        self.removeNotificationSchedules(
                            notification.child_id,
                            notification.work_id,
                        );
                    }
                },
                .stopped => {
                    report.stopped += 1;
                    self.removeNotificationSchedules(
                        notification.child_id,
                        notification.work_id,
                    );
                },
            }
        }
        return report;
    }

    fn ensureReaperLocked(self: *Owner) StartError!void {
        if (self.reaper_thread != null) return;
        self.reaper_thread = std.Thread.spawn(.{}, reaperMain, .{self}) catch
            return error.ThreadSpawnFailed;
    }

    fn scheduleRetirementSweepLocked(self: *Owner, due_ms: i64) void {
        self.retirement_scan_pending = true;
        self.retirement_due_ms = if (self.retirement_due_ms) |current|
            @min(current, due_ms)
        else
            due_ms;
        self.reaper_wake.set(io_mod.getIo());
    }

    fn registerNotificationSchedule(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        next_check_ms: ?i64,
    ) error{OutOfMemory}!void {
        const due_ms = next_check_ms orelse return;
        if (self.notification_clock == null or self.notification_poller == null) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.notification_schedules.items) |*schedule| {
            if (!std.mem.eql(u8, schedule.child_id, child_id) or
                !std.mem.eql(u8, schedule.work_id, work_id))
            {
                continue;
            }
            schedule.next_check_ms = due_ms;
            self.reaper_wake.set(io_mod.getIo());
            return;
        }
        const owned_child_id = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_child_id);
        const owned_work_id = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(owned_work_id);
        try self.notification_schedules.append(self.alloc, .{
            .child_id = owned_child_id,
            .work_id = owned_work_id,
            .next_check_ms = due_ms,
        });
        self.reaper_wake.set(io_mod.getIo());
    }

    fn wakeNotificationSchedules(
        self: *Owner,
        child_id: []const u8,
        now_ms: i64,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var changed = false;
        for (self.notification_schedules.items) |*schedule| {
            if (!std.mem.eql(u8, schedule.child_id, child_id)) continue;
            schedule.next_check_ms = @min(schedule.next_check_ms, now_ms);
            changed = true;
        }
        if (changed) self.reaper_wake.set(io_mod.getIo());
    }

    fn stopNotificationPolicies(
        self: *Owner,
        child_id: []const u8,
        timestamp_ms: i64,
    ) void {
        var delivery_manager = communication_manager.Manager{
            .sessions = self.sessions,
            .child_store_options = self.communication_store_options,
        };
        delivery_manager.stopAndCompactNotifications(
            self.alloc,
            child_id,
        ) catch |err| {
            self.wakeNotificationSchedules(child_id, timestamp_ms);
            debug_trace.logf(
                "subagent",
                "notification cleanup deferred child_id={s} outcome={s}",
                .{ child_id, @errorName(err) },
            );
            return;
        };
        self.removeNotificationSchedules(child_id, null);
    }

    fn updateNotificationSchedule(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        next_check_ms: i64,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.notification_schedules.items) |*schedule| {
            if (std.mem.eql(u8, schedule.child_id, child_id) and
                std.mem.eql(u8, schedule.work_id, work_id))
            {
                schedule.next_check_ms = next_check_ms;
                self.reaper_wake.set(io_mod.getIo());
                return;
            }
        }
    }

    fn retryNotificationSchedule(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        now_ms: i64,
    ) void {
        const retry_at_ms = std.math.add(
            i64,
            now_ms,
            notification_retry_delay_ms,
        ) catch std.math.maxInt(i64);
        self.updateNotificationSchedule(child_id, work_id, retry_at_ms);
    }

    fn removeNotificationSchedules(
        self: *Owner,
        child_id: []const u8,
        work_id: ?[]const u8,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var index = self.notification_schedules.items.len;
        var changed = false;
        while (index > 0) {
            index -= 1;
            const schedule = &self.notification_schedules.items[index];
            if (!std.mem.eql(u8, schedule.child_id, child_id) or
                (work_id != null and
                    !std.mem.eql(u8, schedule.work_id, work_id.?)))
            {
                continue;
            }
            var removed = self.notification_schedules.swapRemove(index);
            removed.deinit(self.alloc);
            changed = true;
        }
        if (changed) self.reaper_wake.set(io_mod.getIo());
    }

    fn nextNotificationCheckLocked(self: *Owner) ?i64 {
        var next_check_ms: ?i64 = null;
        for (self.notification_schedules.items) |schedule| {
            next_check_ms = if (next_check_ms) |current|
                @min(current, schedule.next_check_ms)
            else
                schedule.next_check_ms;
        }
        return next_check_ms;
    }

    fn findSlotLocked(self: *Owner, child_id: []const u8) ?*Slot {
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) return slot;
        }
        return null;
    }

    fn signalChildWaitersLocked(self: *Owner, child_id: ?[]const u8) void {
        for (self.child_waiters.items) |waiter| {
            if (child_id) |expected| {
                if (!std.mem.eql(u8, waiter.child_id, expected)) continue;
            }
            waiter.event.set(io_mod.getIo());
        }
    }

    fn removeSlotLocked(self: *Owner, selected: *Slot) void {
        for (self.slots.items, 0..) |slot, index| {
            if (slot == selected) {
                _ = self.slots.swapRemove(index);
                return;
            }
        }
    }

    fn shouldRestartLocked(self: *Owner, slot: *const Slot) bool {
        return slot.wake_requested and
            !self.closed and
            !slot.shutdown.load(.seq_cst);
    }

    fn restartJoinedSlotLocked(self: *Owner, slot: *Slot) void {
        slot.thread = null;
        slot.finished = false;
        slot.finalizer = .none;
        slot.cancel.store(false, .seq_cst);
        slot.thread = std.Thread.spawn(.{}, slotMain, .{slot}) catch |err| {
            slot.finished = true;
            slot.wake_requested = true;
            slot.restart_failed = true;
            debug_trace.logf(
                "subagent",
                "joined child restart failed child_id={s} outcome={s}",
                .{ slot.child_id, @errorName(err) },
            );
            return;
        };
        slot.wake_requested = false;
        slot.restart_failed = false;
        self.started_any = true;
    }

    fn cacheCompletionLocked(self: *Owner, child_id: []u8, result: ChildResult) void {
        const index = self.completion_cursor;
        if (self.completions[index]) |completion| self.alloc.free(completion.child_id);
        self.completions[index] = .{ .child_id = child_id, .result = result };
        self.completion_cursor = (index + 1) % completion_capacity;
    }

    fn takeCompletionLocked(self: *Owner, child_id: []const u8) ?ChildResult {
        for (&self.completions) |*maybe_completion| {
            const completion = maybe_completion.* orelse continue;
            if (!std.mem.eql(u8, completion.child_id, child_id)) continue;
            const result = completion.result;
            self.alloc.free(completion.child_id);
            maybe_completion.* = null;
            return result;
        }
        return null;
    }

    fn dropCompletionLocked(self: *Owner, child_id: []const u8) void {
        _ = self.takeCompletionLocked(child_id);
    }

    fn markRecoveryExternalBusy(
        self: *Owner,
        child_id: []const u8,
    ) error{OutOfMemory}!void {
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            for (self.recovery_external_busy.items) |observed_child_id| {
                if (std.mem.eql(u8, observed_child_id, child_id)) return;
            }
            const owned_child_id = try self.alloc.dupe(u8, child_id);
            errdefer self.alloc.free(owned_child_id);
            try self.recovery_external_busy.append(self.alloc, owned_child_id);
        }
        debug_trace.logf(
            "subagent",
            "external child ownership observed child_id={s} source=recovery",
            .{child_id},
        );
    }

    fn hasLocalExecution(self: *Owner, child_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.findSlotLocked(child_id) != null;
    }

    fn clearRecoveryExternalBusy(
        self: *Owner,
        child_id: []const u8,
        reason: []const u8,
    ) void {
        var cleared = false;
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            for (self.recovery_external_busy.items, 0..) |observed_child_id, index| {
                if (!std.mem.eql(u8, observed_child_id, child_id)) continue;
                const removed = self.recovery_external_busy.swapRemove(index);
                self.alloc.free(removed);
                cleared = true;
                break;
            }
        }
        if (cleared) {
            debug_trace.logf(
                "subagent",
                "external child ownership cleared child_id={s} reason={s}",
                .{ child_id, reason },
            );
        }
    }

    fn cancelDurable(
        self: *Owner,
        child_id: []const u8,
        reason: []const u8,
        timestamp_ms: i64,
    ) ControlError!usize {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            self.alloc,
            child_id,
            self.child_store_options,
        ) catch |err| return mapOpenControlError(err);
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = store.acquireLock() catch |err| return mapControlLockError(err);
        defer lock.release();
        var record = store.load(self.alloc) catch |err| return mapControlLoadError(err);
        defer record.deinit(self.alloc);
        const count = cancelWork(self.alloc, &record, reason, timestamp_ms) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidCancellationReason, error.InvalidWorkState => error.ControlStoreFailed,
            };
        };
        if (count != 0) {
            store.save(self.alloc, record) catch |err| return mapControlSaveError(err);
        }
        var communication_capability = self.sessions.openSubagentControlCapabilityWritable(
            self.alloc,
            child_id,
            self.communication_store_options,
        ) catch |err| {
            debug_trace.logf(
                "subagent",
                "terminal reconciliation deferred child_id={s} outcome={s}",
                .{ child_id, @errorName(err) },
            );
            return count;
        };
        defer communication_capability.deinit();
        const communication_state = communication_store.Store{
            .capability = &communication_capability,
            .expected_session_id = child_id,
        };
        if (count != 0 and self.approval_registry == null) {
            _ = communication_manager.invalidateApprovalsLocked(
                self.alloc,
                communication_state,
                child_id,
                .cancelled,
                timestamp_ms,
            ) catch |err| debug_trace.logf(
                "subagent",
                "approval invalidation deferred child_id={s} outcome={s}",
                .{ child_id, @errorName(err) },
            );
        }
        _ = communication_manager.reconcileTerminalsLocked(
            self.alloc,
            communication_state,
            record,
        ) catch |err| debug_trace.logf(
            "subagent",
            "terminal reconciliation deferred child_id={s} outcome={s}",
            .{ child_id, @errorName(err) },
        );
        _ = reconcileOneOffFinalResultLocked(
            self.alloc,
            communication_state,
            record,
            &.{},
        ) catch |err| debug_trace.logf(
            "subagent",
            "final result reconciliation deferred child_id={s} outcome={s}",
            .{ child_id, @errorName(err) },
        );
        return count;
    }

    fn recoverChild(
        self: *Owner,
        child_id: []const u8,
        timestamp_ms: i64,
    ) ControlError!RestartRecovery {
        // Ordinary chats share the session namespace. Prove this session owns
        // subagent control state before a writable resume can rebind it.
        {
            var read_capability = self.sessions.openSubagentControlCapabilityReadOnly(
                self.alloc,
                child_id,
                self.child_store_options,
            ) catch |err| return mapOpenControlError(err);
            defer read_capability.deinit();
            const read_store = control_store.Store{
                .capability = &read_capability,
                .expected_child_id = child_id,
            };
            const existing = read_store.loadOptional(self.alloc) catch |err|
                return mapControlLoadError(err);
            if (existing) |value| {
                var record = value;
                record.deinit(self.alloc);
            } else {
                return .{};
            }
        }

        var loaded = self.sessions.resumeTargetForWrite(
            self.alloc,
            .{ .id = child_id },
            self.sessions.workspace_root,
            self.session_resume_options,
        ) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.SessionBusy => error.ExternalBusy,
                else => error.ControlStoreFailed,
            };
        };
        defer {
            loaded.log.park();
            loaded.deinit(self.alloc);
        }
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            self.alloc,
            child_id,
            self.child_store_options,
        ) catch |err| return mapOpenControlError(err);
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = store.acquireLock() catch |err| return mapControlLockError(err);
        defer lock.release();
        var record = store.load(self.alloc) catch |err| return mapControlLoadError(err);
        defer record.deinit(self.alloc);
        var communication_capability = self.sessions.openSubagentControlCapabilityWritable(
            self.alloc,
            child_id,
            self.communication_store_options,
        ) catch |err| return mapOpenControlError(err);
        defer communication_capability.deinit();
        const communication_state = communication_store.Store{
            .capability = &communication_capability,
            .expected_session_id = child_id,
        };
        _ = reconcileToolActivityLocked(
            self.alloc,
            communication_state,
            child_id,
            loaded.state.last_subagent_work_id,
            loaded.state.history,
        ) catch |err| blk: {
            debug_trace.logf(
                "subagent",
                "tool activity reconciliation deferred child_id={s} outcome={s}",
                .{ child_id, @errorName(err) },
            );
            break :blk 0;
        };
        const changed = recoverAfterRestart(
            self.alloc,
            &record,
            completedWorkIdForRecovery(
                loaded.state.last_subagent_work_id,
                loaded.state.history,
            ),
            timestamp_ms,
        ) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidCancellationReason, error.InvalidWorkState => error.ControlStoreFailed,
            };
        };
        if (changed.interrupted != 0 or changed.completed != 0) {
            store.save(self.alloc, record) catch |err| return mapControlSaveError(err);
        }
        _ = communication_manager.reconcileApprovalsLocked(
            self.alloc,
            communication_state,
            record,
            timestamp_ms,
        ) catch return error.ControlStoreFailed;
        _ = communication_manager.reconcileTerminalsLocked(
            self.alloc,
            communication_state,
            record,
        ) catch return error.ControlStoreFailed;
        _ = reconcileOneOffFinalResultLocked(
            self.alloc,
            communication_state,
            record,
            loaded.state.history,
        ) catch return error.ControlStoreFailed;
        return changed;
    }

    fn recoverCandidate(
        self: *Owner,
        report: *RecoveryReport,
        child_id: []const u8,
        timestamp_ms: i64,
    ) RecoveryError!void {
        const changed = self.recoverChild(child_id, timestamp_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ExternalBusy => {
                if (!self.hasLocalExecution(child_id)) {
                    try self.markRecoveryExternalBusy(child_id);
                }
                report.sessions_external_busy += 1;
                return;
            },
            else => {
                report.sessions_failed += 1;
                return;
            },
        };
        self.clearRecoveryExternalBusy(child_id, "recovery_writer_acquired");
        if (changed.interrupted == 0 and changed.completed == 0) return;
        report.sessions_changed += 1;
        report.work_interrupted += changed.interrupted;
        report.work_completed += changed.completed;
    }

    fn runRetirementSweep(self: *Owner, now_ms: i64) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (!self.retirement_scan_pending or
            (self.retirement_due_ms orelse now_ms) > now_ms)
        {
            self.mutex.unlock(io_mod.getIo());
            return;
        }
        self.retirement_scan_pending = false;
        self.retirement_due_ms = null;
        const root_id = self.retirement_root_id orelse {
            self.mutex.unlock(io_mod.getIo());
            return;
        };
        const owned_root = self.alloc.dupe(u8, root_id) catch {
            self.scheduleRetirementSweepLocked(now_ms + retirement_retry_delay_ms);
            self.mutex.unlock(io_mod.getIo());
            return;
        };
        const cursor = self.retirement_cursor;
        self.retirement_cursor = null;
        self.mutex.unlock(io_mod.getIo());
        defer self.alloc.free(owned_root);
        defer if (cursor) |value| self.alloc.free(value);

        var result = self.manager.snapshot(self.alloc, .{
            .root_id = owned_root,
            .cursor = cursor,
            .limit = domain.default_page_limit,
        }) catch |err| {
            debug_trace.logf(
                "subagent",
                "retirement sweep deferred root_id={s} outcome={s}",
                .{ owned_root, @errorName(err) },
            );
            self.finishRetirementSweep(null, true, now_ms);
            return;
        };
        defer result.deinit(self.alloc);
        const snapshot = switch (result) {
            .failure => |failure| {
                const retry = failure.code == .store_failure or
                    failure.code == .graph_changed;
                debug_trace.logf(
                    "subagent",
                    "retirement sweep retained root_id={s} reason={s} retryable={}",
                    .{ owned_root, @tagName(failure.code), retry },
                );
                self.finishRetirementSweep(null, retry, now_ms);
                return;
            },
            .snapshot => |*value| value,
        };
        if (snapshot.restart_required) {
            self.finishRetirementSweep(null, true, now_ms);
            return;
        }

        var retry = false;
        for (snapshot.nodes) |node| {
            if (!isTerminalOneOff(node.mode, node.state)) continue;
            retry = self.tryRetireOneOff(node.child_id) or retry;
        }
        for (snapshot.diagnostics) |diagnostic| {
            if (diagnostic.code != .session_unavailable) continue;
            const parent_id = diagnostic.parent_id orelse continue;
            _ = relationship_index.removeChild(
                self.alloc,
                self.sessions,
                parent_id,
                diagnostic.session_id,
                self.child_store_options,
            ) catch |err| {
                traceRetirementRetain(
                    diagnostic.session_id,
                    "stale_relationship_remove",
                    err,
                );
                retry = shouldScheduleRetirementRetry(err) or retry;
            };
        }
        const next_cursor = if (snapshot.next_cursor) |next|
            self.alloc.dupe(u8, next) catch {
                self.finishRetirementSweep(null, true, now_ms);
                return;
            }
        else
            null;
        self.finishRetirementSweep(next_cursor, retry, now_ms);
    }

    fn finishRetirementSweep(
        self: *Owner,
        next_cursor: ?[]u8,
        retry: bool,
        now_ms: i64,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) {
            if (next_cursor) |cursor| self.alloc.free(cursor);
            return;
        }
        if (self.retirement_scan_pending) {
            self.retirement_retry_after_scan =
                self.retirement_retry_after_scan or retry;
            if (next_cursor) |cursor| self.alloc.free(cursor);
            return;
        }
        if (self.retirement_cursor) |cursor| self.alloc.free(cursor);
        self.retirement_cursor = next_cursor;
        if (next_cursor != null) {
            self.retirement_retry_after_scan =
                self.retirement_retry_after_scan or retry;
            self.scheduleRetirementSweepLocked(now_ms);
        } else {
            const should_retry = retry or self.retirement_retry_after_scan;
            self.retirement_retry_after_scan = false;
            if (should_retry) {
                self.scheduleRetirementSweepLocked(
                    now_ms + retirement_retry_delay_ms,
                );
            }
        }
    }

    /// Returns true only when another automatic bounded attempt is warranted.
    fn tryRetireOneOff(self: *Owner, child_id: []const u8) bool {
        _ = relationship_index.migrateLegacyPage(
            self.alloc,
            self.sessions,
            child_id,
            self.child_store_options,
        ) catch |err| {
            if (err == error.StoreUnavailable) {
                var page = self.sessions.listResumablePage(
                    self.alloc,
                    null,
                    null,
                ) catch |backfill_err| {
                    traceRetirementRetain(
                        child_id,
                        "migration_backfill",
                        backfill_err,
                    );
                    return shouldScheduleRetirementRetry(backfill_err);
                };
                page.deinit(self.alloc);
                return true;
            }
            traceRetirementRetain(child_id, "migration", err);
            return shouldScheduleRetirementRetry(err);
        };

        var loaded = self.sessions.resumeTargetForWrite(
            self.alloc,
            .{ .id = child_id },
            self.sessions.workspace_root,
            self.session_resume_options,
        ) catch |err| {
            traceRetirementRetain(child_id, "writer", err);
            return shouldScheduleRetirementRetry(err);
        };
        var loaded_consumed = false;
        defer if (!loaded_consumed) loaded.deinit(self.alloc);

        var capability = self.sessions.openSubagentControlCapabilityWritable(
            self.alloc,
            child_id,
            self.child_store_options,
        ) catch |err| {
            traceRetirementRetain(child_id, "control_open", err);
            return shouldScheduleRetirementRetry(err);
        };
        defer capability.deinit();
        const control = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = control.acquireLock() catch |err| {
            traceRetirementRetain(child_id, "control_lock", err);
            return shouldScheduleRetirementRetry(err);
        };
        defer lock.release();
        var record = control.load(self.alloc) catch |err| {
            traceRetirementRetain(child_id, "control_load", err);
            return shouldScheduleRetirementRetry(err);
        };
        defer record.deinit(self.alloc);
        if (!isTerminalOneOff(record.mode, record.state)) return false;
        const parent_id = record.parent_id orelse return false;

        var communication_capability = self.sessions.openSubagentControlCapabilityWritable(
            self.alloc,
            child_id,
            self.communication_store_options,
        ) catch |err| {
            traceRetirementRetain(child_id, "communication_open", err);
            return shouldScheduleRetirementRetry(err);
        };
        defer communication_capability.deinit();
        const communication_state = communication_store.Store{
            .capability = &communication_capability,
            .expected_session_id = child_id,
        };
        _ = reconcileOneOffFinalResultLocked(
            self.alloc,
            communication_state,
            record,
            loaded.state.history,
        ) catch |err| {
            traceRetirementRetain(child_id, "result_reconcile", err);
            return shouldScheduleRetirementRetry(err);
        };
        var ledger = communication_state.loadOptional(self.alloc) catch |err| {
            traceRetirementRetain(child_id, "communication_load", err);
            return shouldScheduleRetirementRetry(err);
        } orelse return true;
        defer ledger.deinit(self.alloc);
        const work_id = terminalOneOffWorkId(record) orelse return false;
        const delivery_id = communication.stableDeliveryId(
            child_id,
            work_id,
            "final-result",
        );
        const result_acknowledged = communication.parentTurnDeliveryFullyAcknowledged(
            ledger,
            "parent-model",
            parent_id,
            &delivery_id,
        );
        if (!result_acknowledged) return false;

        const active_count = relationship_index.activeCountIfMigrationComplete(
            self.alloc,
            self.sessions,
            child_id,
            self.child_store_options,
        ) catch |err| {
            traceRetirementRetain(child_id, "descendant_proof", err);
            return shouldScheduleRetirementRetry(err);
        };
        const facts = OneOffRetirementFacts{
            .mode = record.mode,
            .state = record.state,
            .result_acknowledged = result_acknowledged,
            .migration_complete = active_count != null,
            .active_count = active_count,
        };
        if (!canRetireOneOff(facts)) return active_count == null;

        const disposition = self.sessions.deleteCommittedSession(
            self.alloc,
            &loaded,
        );
        loaded_consumed = true;
        switch (disposition) {
            .retained => return false,
            .indeterminate => return true,
            .discarded => {},
        }
        _ = relationship_index.removeChild(
            self.alloc,
            self.sessions,
            parent_id,
            child_id,
            self.child_store_options,
        ) catch |err| {
            traceRetirementRetain(child_id, "relationship_remove", err);
            return shouldScheduleRetirementRetry(err);
        };
        debug_trace.logf(
            "subagent",
            "one-off retirement committed child_id={s} parent_id={s}",
            .{ child_id, parent_id },
        );
        return false;
    }
};

const retirement_retry_delay_ms: i64 = 100;

fn isTerminalOneOff(mode: domain.Mode, state: domain.State) bool {
    if (mode != .one_off) return false;
    return switch (state) {
        .completed, .failed, .cancelled => true,
        else => false,
    };
}

const OneOffRetirementFacts = struct {
    mode: domain.Mode,
    state: domain.State,
    result_acknowledged: bool,
    migration_complete: bool,
    active_count: ?u64,
};

fn canRetireOneOff(facts: OneOffRetirementFacts) bool {
    return isTerminalOneOff(facts.mode, facts.state) and
        facts.result_acknowledged and
        facts.migration_complete and
        facts.active_count != null and
        facts.active_count.? == 0;
}

fn terminalOneOffWorkId(record: control_store.Record) ?[]const u8 {
    var index = record.queue.len;
    while (index > 0) {
        index -= 1;
        switch (record.queue[index].status) {
            .completed, .failed, .cancelled => return record.queue[index].id,
            else => {},
        }
    }
    return null;
}

fn shouldScheduleRetirementRetry(err: anyerror) bool {
    return switch (err) {
        error.SessionBusy,
        error.ExternalBusy,
        error.ControlLockBusy,
        error.LockBusy,
        error.SessionStoreUnavailable,
        error.StoreUnavailable,
        error.CommitIndeterminate,
        error.RecoveryRequired,
        error.StaleCursor,
        error.OutOfMemory,
        => true,
        else => false,
    };
}

fn traceRetirementRetain(
    child_id: []const u8,
    stage: []const u8,
    err: anyerror,
) void {
    debug_trace.logf(
        "subagent",
        "one-off retirement retained child_id={s} stage={s} outcome={s} retryable={}",
        .{ child_id, stage, @errorName(err), shouldScheduleRetirementRetry(err) },
    );
}

fn isRetryableNotificationPollError(err: communication_manager.Error) bool {
    return switch (err) {
        error.OutOfMemory,
        error.LockBusy,
        error.StoreUnavailable,
        error.CommitIndeterminate,
        => true,
        error.SessionNotFound,
        error.InvalidRequest,
        error.CapacityExceeded,
        error.LockUnsupported,
        error.InvalidRecord,
        error.StaleCursor,
        error.ContextTooLarge,
        error.OperationReplayExpired,
        => false,
    };
}

fn reaperMain(owner: *Owner) void {
    owner.mutex.lockUncancelable(io_mod.getIo());
    while (true) {
        owner.reaper_wake.reset();
        if (owner.closed) {
            owner.mutex.unlock(io_mod.getIo());
            return;
        }
        var selected: ?*Slot = null;
        for (owner.slots.items) |slot| {
            if (!slot.finished or slot.finalizer != .none or
                (slot.wake_requested and slot.restart_failed)) continue;
            selected = slot;
            break;
        }
        const slot = selected orelse {
            const now_ms = reaperNowMs(owner);
            if (owner.retirement_scan_pending and
                (owner.retirement_due_ms orelse now_ms) <= now_ms)
            {
                owner.mutex.unlock(io_mod.getIo());
                owner.runRetirementSweep(now_ms);
                owner.mutex.lockUncancelable(io_mod.getIo());
                continue;
            }
            const notification_check_ms = owner.nextNotificationCheckLocked();
            const next_check_ms = if (owner.retirement_scan_pending)
                if (notification_check_ms) |notification_due|
                    @min(notification_due, owner.retirement_due_ms orelse now_ms)
                else
                    owner.retirement_due_ms
            else
                notification_check_ms;
            if (next_check_ms != null and next_check_ms.? <= now_ms) {
                owner.mutex.unlock(io_mod.getIo());
                _ = owner.pollNotifications() catch |err| {
                    debug_trace.logf(
                        "subagent",
                        "periodic notification due scan deferred outcome={s}",
                        .{@errorName(err)},
                    );
                };
                owner.mutex.lockUncancelable(io_mod.getIo());
                continue;
            }
            owner.mutex.unlock(io_mod.getIo());
            if (next_check_ms) |due_ms| {
                const delay_ms = due_ms -| now_ms;
                owner.reaper_wake.waitTimeout(io_mod.getIo(), .{ .duration = .{
                    .clock = .awake,
                    .raw = .fromMilliseconds(delay_ms),
                } }) catch {};
            } else {
                owner.reaper_wake.waitUncancelable(io_mod.getIo());
            }
            owner.mutex.lockUncancelable(io_mod.getIo());
            continue;
        };
        slot.finalizer = .reaper;
        const thread = slot.thread;
        owner.mutex.unlock(io_mod.getIo());
        if (thread) |joinable| joinable.join();

        owner.mutex.lockUncancelable(io_mod.getIo());
        if (owner.shouldRestartLocked(slot)) {
            owner.restartJoinedSlotLocked(slot);
            owner.reaper_cond.broadcast(io_mod.getIo());
            continue;
        }
        owner.removeSlotLocked(slot);
        owner.cacheCompletionLocked(slot.child_id, slot.result);
        if (owner.retirement_root_id != null) {
            owner.scheduleRetirementSweepLocked(reaperNowMs(owner));
        }
        owner.reaper_cond.broadcast(io_mod.getIo());
        owner.mutex.unlock(io_mod.getIo());
        slot.live.deinit(owner.alloc);
        owner.alloc.destroy(slot);
        owner.mutex.lockUncancelable(io_mod.getIo());
    }
}

fn reaperNowMs(owner: *const Owner) i64 {
    return if (owner.notification_clock) |clock|
        clock.now_ms()
    else
        io_mod.milliTimestamp();
}

fn appendSlotLiveText(raw: *anyopaque, value: []const u8) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (!slot.finished) {
        slot.live.appendText(owner.alloc, value);
        slot.live.appendEvent(owner.alloc, .{
            .assistant_presentation = .{ .text = @constCast(value) },
        });
    }
}

fn appendSlotLiveTool(
    raw: *anyopaque,
    tool_name: []const u8,
    phase: runtime_deps.ToolActivityPhase,
) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (!slot.finished) slot.live.appendTool(owner.alloc, tool_name, phase);
}

fn appendSlotLiveEvent(
    raw: *anyopaque,
    event: worker_runtime.WorkerEvent,
) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (!slot.finished) slot.live.appendEvent(owner.alloc, event);
}

test "live child presentation is bounded deep copied and cleared" {
    const alloc = std.testing.allocator;
    var state = LivePresentationState{};
    defer state.deinit(alloc);
    try state.begin(alloc, "work-live");
    state.appendText(alloc, "hello");
    state.appendTool(alloc, "read_file", .started);
    state.appendEvent(alloc, .{ .assistant_presentation = .{
        .text = @constCast("hello"),
    } });
    state.appendEvent(alloc, .{ .tool_lifecycle = .{
        .authoritative_started = .{
            .id = .{ .turn_id = 1, .call_id = "call-live" },
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
            .arguments_json = "{\"path\":\"README.md\"}",
        },
    } });

    var first = (try state.clone(alloc)).?;
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("work-live", first.work_id);
    try std.testing.expectEqualStrings("hello", first.text);
    try std.testing.expectEqualStrings("read_file", first.tools[0].tool_name);
    try std.testing.expectEqual(@as(usize, 2), first.events.len);
    try std.testing.expect(first.events[0] == .assistant_presentation);
    try std.testing.expect(first.events[0].assistant_presentation == .text);
    try std.testing.expect(first.events[1] == .tool_lifecycle);

    state.appendText(alloc, " world");
    state.appendTool(alloc, "read_file", .succeeded);
    try std.testing.expectEqualStrings("hello", first.text);
    try std.testing.expectEqual(@as(usize, 1), first.tools.len);

    var oversized: [max_live_presentation_bytes + 8]u8 = undefined;
    @memset(&oversized, 'x');
    state.appendText(alloc, &oversized);
    for (0..max_live_tool_activity + 2) |_| {
        state.appendTool(alloc, "bounded-tool", .started);
    }
    for (0..max_live_presentation_events + 2) |_| {
        state.appendEvent(alloc, .{ .assistant_presentation = .thematic_rule });
    }
    var bounded = (try state.clone(alloc)).?;
    defer bounded.deinit(alloc);
    try std.testing.expectEqual(max_live_presentation_bytes, bounded.text.len);
    try std.testing.expect(bounded.text_truncated);
    try std.testing.expectEqual(max_live_tool_activity, bounded.tools.len);
    try std.testing.expect(bounded.tools_truncated);
    try std.testing.expectEqual(max_live_presentation_events, bounded.events.len);
    try std.testing.expect(bounded.events_truncated);

    state.clear(alloc);
    try std.testing.expect((try state.clone(alloc)) == null);
}

fn checkLivePresentationCloneAllocationFailures(alloc: Allocator) !void {
    var state = LivePresentationState{};
    defer state.deinit(alloc);
    try state.begin(alloc, "work-allocation");
    state.appendText(alloc, "partial assistant output");
    state.appendTool(alloc, "read_file", .started);
    state.appendTool(alloc, "read_file", .succeeded);
    state.appendEvent(
        alloc,
        .{ .assistant_presentation = .{
            .text = @constCast("partial assistant output"),
        } },
    );
    state.appendEvent(alloc, .{ .tool_lifecycle = .{
        .authoritative_started = .{
            .id = .{ .turn_id = 1, .call_id = "call-live" },
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
            .arguments_json = "{\"path\":\"README.md\"}",
        },
    } });
    var snapshot = (try state.clone(alloc)) orelse return error.TestUnexpectedResult;
    snapshot.deinit(alloc);
}

test "live child presentation clone frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLivePresentationCloneAllocationFailures,
        .{},
    );
}

fn slotMain(slot: *Slot) void {
    var prior_result: ?ChildResult = null;
    while (true) {
        const result = runChild(slot);
        const owner = slot.owner;
        owner.mutex.lockUncancelable(io_mod.getIo());
        if (slot.wake_requested and
            !slot.shutdown.load(.seq_cst) and
            !owner.closed and
            result != .awaiting_approval and
            result != .paused and
            result != .owner_stopped)
        {
            prior_result = result;
            slot.wake_requested = false;
            slot.cancel.store(false, .seq_cst);
            owner.mutex.unlock(io_mod.getIo());
            continue;
        }
        slot.result = if (result == .no_work) prior_result orelse result else result;
        slot.finished = true;
        owner.signalChildWaitersLocked(slot.child_id);
        owner.reaper_cond.broadcast(io_mod.getIo());
        owner.reaper_wake.set(io_mod.getIo());
        owner.mutex.unlock(io_mod.getIo());
        return;
    }
}

fn runChild(slot: *Slot) ChildResult {
    while (true) {
        const result = runOne(slot);
        switch (result) {
            .more_work => continue,
            .idle => return .idle,
            .completed => return .completed,
            .no_work => return .no_work,
            .failed,
            .cancelled,
            .awaiting_approval,
            .paused,
            .external_busy,
            .session_failed,
            .control_failed,
            .admission_failed,
            .owner_stopped,
            => return switch (result) {
                .failed => .failed,
                .cancelled => .cancelled,
                .awaiting_approval => .awaiting_approval,
                .paused => .paused,
                .external_busy => .external_busy,
                .session_failed => .session_failed,
                .control_failed => .control_failed,
                .admission_failed => .admission_failed,
                .owner_stopped => .owner_stopped,
                .more_work, .idle, .completed, .no_work => unreachable,
            },
        }
    }
}

const OneResult = enum {
    more_work,
    idle,
    completed,
    failed,
    cancelled,
    awaiting_approval,
    paused,
    external_busy,
    no_work,
    session_failed,
    control_failed,
    admission_failed,
    owner_stopped,
};

fn runOne(slot: *Slot) OneResult {
    const owner = slot.owner;
    var loaded = owner.sessions.resumeTargetForWrite(
        owner.alloc,
        .{ .id = slot.child_id },
        owner.sessions.workspace_root,
        owner.session_resume_options,
    ) catch |err| {
        return switch (err) {
            error.SessionBusy => .external_busy,
            else => .session_failed,
        };
    };
    owner.clearRecoveryExternalBusy(slot.child_id, "local_writer_acquired");
    defer {
        loaded.log.park();
        loaded.deinit(owner.alloc);
    }
    var turn = TurnContext.init(
        owner.alloc,
        &loaded,
        owner.max_history_turns,
    ) catch return .session_failed;
    defer turn.deinit();
    turn.live_authority = owner.live_authority;
    turn.approval_registry = owner.approval_registry;
    turn.child_id = slot.child_id;
    turn.worker.worker_processing = true;
    defer turn.worker.finishProcessing();
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.active_worker = turn.workerRuntime();
    owner.mutex.unlock(io_mod.getIo());
    defer {
        owner.mutex.lockUncancelable(io_mod.getIo());
        slot.active_worker = null;
        owner.mutex.unlock(io_mod.getIo());
    }

    var capability = owner.sessions.openSubagentControlCapabilityWritable(
        owner.alloc,
        slot.child_id,
        owner.child_store_options,
    ) catch return .control_failed;
    defer capability.deinit();
    const store = control_store.Store{
        .capability = &capability,
        .expected_child_id = slot.child_id,
    };
    var lock = store.acquireLock() catch return .control_failed;
    var lock_held = true;
    defer if (lock_held) lock.release();
    var record = store.load(owner.alloc) catch return .control_failed;
    defer record.deinit(owner.alloc);
    var communication_capability = owner.sessions.openSubagentControlCapabilityWritable(
        owner.alloc,
        slot.child_id,
        owner.communication_store_options,
    ) catch return .control_failed;
    defer communication_capability.deinit();
    const communication_state = communication_store.Store{
        .capability = &communication_capability,
        .expected_session_id = slot.child_id,
    };
    turn.tool_activity_store = &communication_state;
    _ = reconcileToolActivityLocked(
        owner.alloc,
        communication_state,
        slot.child_id,
        loaded.state.last_subagent_work_id,
        loaded.state.history,
    ) catch |err| blk: {
        debug_trace.logf(
            "subagent",
            "tool activity reconciliation deferred child_id={s} outcome={s}",
            .{ slot.child_id, @errorName(err) },
        );
        break :blk 0;
    };
    _ = communication_manager.reconcileTerminalsLocked(
        owner.alloc,
        communication_state,
        record,
    ) catch return .control_failed;
    _ = reconcileOneOffFinalResultLocked(
        owner.alloc,
        communication_state,
        record,
        loaded.state.history,
    ) catch return .control_failed;
    const index = nextRunnableIndex(record.queue, slot.retry_interrupted) orelse
        return if (record.mode == .one_off and record.state == .completed)
            .completed
        else
            .no_work;
    const preferences = resolveTurnPreferences(
        record.configuration,
        loaded.state.preferences,
    );
    const parent_id = record.parent_id orelse return .admission_failed;
    var admission = owner.services.capture(owner.alloc, .{
        .child_id = record.child_id,
        .parent_id = parent_id,
        .source_id = record.queue[index].source_id,
        .configuration = record.configuration,
        .preferences = preferences,
    }) catch {
        failAdmission(owner.alloc, &record, index, io_mod.milliTimestamp()) catch
            return .control_failed;
        store.save(owner.alloc, record) catch return .control_failed;
        return .admission_failed;
    };
    defer admission.deinit(owner.alloc);
    if (admission.provider != preferences.provider or
        admission.permission_mode != record.configuration.permission_mode or
        !std.mem.eql(u8, admission.parent_id, parent_id) or
        !std.mem.eql(u8, admission.source_id, record.queue[index].source_id) or
        !std.mem.eql(u8, admission.model, preferences.model) or
        !admission.effort.eql(preferences.effort))
    {
        failAdmission(owner.alloc, &record, index, io_mod.milliTimestamp()) catch
            return .control_failed;
        store.save(owner.alloc, record) catch return .control_failed;
        return .admission_failed;
    }
    const admitted_at_ms = io_mod.milliTimestamp();
    const next_notification_check_ms = communication_manager.captureWorkPolicyLocked(
        owner.alloc,
        communication_state,
        record.child_id,
        record.queue[index].id,
        record.configuration.notifications,
        admitted_at_ms,
    ) catch return .control_failed;
    owner.registerNotificationSchedule(
        record.child_id,
        record.queue[index].id,
        next_notification_check_ms,
    ) catch return .control_failed;
    admitWork(owner.alloc, &record, index, admitted_at_ms) catch
        return .control_failed;
    const work_id = owner.alloc.dupe(u8, record.queue[index].id) catch return .control_failed;
    defer owner.alloc.free(work_id);
    turn.active_work_id = work_id;
    const run_message = record.queue[index];
    store.save(owner.alloc, record) catch return .control_failed;
    lock.release();
    lock_held = false;

    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.live.begin(owner.alloc, work_id) catch {};
    turn.live_presentation = .{
        .context = slot,
        .append_text_fn = appendSlotLiveText,
        .append_tool_fn = appendSlotLiveTool,
        .append_event_fn = appendSlotLiveEvent,
    };
    owner.mutex.unlock(io_mod.getIo());
    defer {
        turn.live_presentation = null;
        owner.mutex.lockUncancelable(io_mod.getIo());
        slot.live.clear(owner.alloc);
        owner.mutex.unlock(io_mod.getIo());
    }

    var run_error: ?ServiceError = null;
    const run_outcome = owner.services.run(
        &turn,
        run_message,
        admission,
        &slot.cancel,
    ) catch |err| blk: {
        run_error = err;
        break :blk null;
    };
    if (slot.shutdown.load(.seq_cst)) return .owner_stopped;
    const outcome: WorkOutcome = if (run_outcome) |value| switch (value) {
        .completed => if (turn.committed) .completed else .failed,
        .awaiting_approval => .awaiting_approval,
        .paused => .paused,
    } else .failed;
    const failure_reason: ?[]const u8 = if (outcome == .failed)
        turn.failureDiagnostic() orelse if (run_error) |err|
            serviceFailureReason(err)
        else
            "turn_not_committed"
    else
        null;

    var completion_lock = store.acquireLock() catch return .control_failed;
    defer completion_lock.release();
    var current = store.load(owner.alloc) catch return .control_failed;
    defer current.deinit(owner.alloc);
    const completed_at_ms = io_mod.milliTimestamp();
    switch (finishWorkWithFailureReason(
        owner.alloc,
        &current,
        work_id,
        outcome,
        failure_reason,
        completed_at_ms,
    ) catch
        return .control_failed) {
        .cancellation_won => return .cancelled,
        .stale_work => return .control_failed,
        .committed => {},
    }
    store.save(owner.alloc, current) catch return .control_failed;
    if (outcome == .awaiting_approval) return .awaiting_approval;
    if (outcome == .paused) return .paused;
    _ = reconcileToolActivityLocked(
        owner.alloc,
        communication_state,
        slot.child_id,
        work_id,
        loaded.state.history,
    ) catch |err| blk: {
        debug_trace.logf(
            "subagent",
            "tool activity reconciliation deferred child_id={s} outcome={s}",
            .{ slot.child_id, @errorName(err) },
        );
        break :blk 0;
    };
    _ = communication_manager.reconcileTerminalsLocked(
        owner.alloc,
        communication_state,
        current,
    ) catch {
        owner.wakeNotificationSchedules(slot.child_id, completed_at_ms);
        return .control_failed;
    };
    _ = reconcileOneOffFinalResultLocked(
        owner.alloc,
        communication_state,
        current,
        loaded.state.history,
    ) catch {
        owner.wakeNotificationSchedules(slot.child_id, completed_at_ms);
        return .control_failed;
    };
    owner.wakeNotificationSchedules(slot.child_id, completed_at_ms);
    if (outcome == .failed) return .failed;
    if (current.mode == .one_off) return .completed;
    if (hasPending(current.queue) or
        (slot.retry_interrupted and nextRunnableIndex(current.queue, true) != null))
    {
        return .more_work;
    }
    return .idle;
}

const ActivityReconcileError = communication_store.LoadError ||
    communication_store.SaveError || communication.MutationError;

fn reconcileToolActivityLocked(
    alloc: Allocator,
    store: communication_store.Store,
    child_id: []const u8,
    maybe_work_id: ?[]const u8,
    history: []const types.HistoryTurn,
) ActivityReconcileError!usize {
    const work_id = maybe_work_id orelse return 0;
    if (history.len == 0) return 0;
    var ledger = (try store.loadOptional(alloc)) orelse return 0;
    defer ledger.deinit(alloc);
    var repaired: usize = 0;
    var history_index = history.len;
    while (history_index > 0) {
        history_index -= 1;
        const execution = historyExecution(history[history_index]) orelse continue;
        var matched_work = false;
        for (execution.tool_steps) |step| {
            for (step.tool_results) |result| {
                const started_id = communication.stableToolActivityId(
                    child_id,
                    work_id,
                    result.tool_call_id,
                    .started,
                );
                const started = findDeliveryById(ledger.deliveries, &started_id) orelse
                    continue;
                matched_work = true;
                const phase: communication.ToolActivityPhase = switch (result.status) {
                    .success => .succeeded,
                    .failure => .failed,
                };
                const final_id = communication.stableToolActivityId(
                    child_id,
                    work_id,
                    result.tool_call_id,
                    phase,
                );
                const appended = try communication.appendDelivery(alloc, &ledger, .{
                    .id = &final_id,
                    .source_id = child_id,
                    .target_id = started.target_id,
                    .work_id = work_id,
                    .timestamp_ms = started.timestamp_ms,
                    .payload = .{ .tool_activity = .{
                        .tool_name = result.tool_name,
                        .phase = phase,
                    } },
                });
                if (appended == .appended) repaired += 1;
            }
        }
        if (matched_work) break;
    }
    if (repaired != 0) try store.save(alloc, ledger);
    return repaired;
}

fn historyExecution(turn: types.HistoryTurn) ?types.ExecutionMemory {
    return switch (turn) {
        .assistant => |value| value.execution,
        .background_command => |value| value.execution,
        .interrupted => |value| value.execution,
        .compacted_summary => null,
    };
}

fn completedWorkIdForRecovery(
    last_work_id: ?[]const u8,
    history: []const types.HistoryTurn,
) ?[]const u8 {
    const work_id = last_work_id orelse return null;
    if (history.len == 0 or history[history.len - 1] == .interrupted) return null;
    return work_id;
}

const TerminalTransition = struct {
    timestamp_ms: i64,
    reason: ?[]const u8,
};

fn terminalTransitionForWork(
    events: []const domain.Event,
    work_id: []const u8,
    status: domain.QueueStatus,
) ?TerminalTransition {
    var index = events.len;
    while (index > 0) {
        index -= 1;
        const transition = switch (events[index].kind) {
            .work_transition => |value| value,
            else => continue,
        };
        if (transition.current != status or
            !std.mem.eql(u8, transition.work_item_id, work_id))
        {
            continue;
        }
        return .{
            .timestamp_ms = events[index].timestamp_ms,
            .reason = transition.reason,
        };
    }
    return null;
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
            .background_command => |value| value.assistant orelse "",
            .interrupted => |value| value.assistant orelse "",
            .compacted_summary => null,
        };
    }
    return null;
}

fn boundedFinalResultAlloc(
    alloc: Allocator,
    content: []const u8,
) Allocator.Error![]u8 {
    if (content.len <= communication.max_delivery_content_bytes) {
        return alloc.dupe(u8, content);
    }
    const suffix = try std.fmt.allocPrint(
        alloc,
        "\n\n[truncated; original_bytes={d}]",
        .{content.len},
    );
    defer alloc.free(suffix);
    std.debug.assert(suffix.len < communication.max_delivery_content_bytes);
    const prefix = text_utils.utf8PrefixByBytes(
        content,
        communication.max_delivery_content_bytes - suffix.len,
    );
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, suffix });
}

fn oneOffFinalResultAlloc(
    alloc: Allocator,
    work: domain.QueuedMessage,
    transition: TerminalTransition,
    history: []const types.HistoryTurn,
) (Allocator.Error || error{InvalidRecord})![]u8 {
    const fallback_completed = "One-off subagent completed without a final text response.";
    var formatted: ?[]u8 = null;
    defer if (formatted) |value| alloc.free(value);
    const raw = switch (work.status) {
        .completed => blk: {
            const assistant = assistantTextForWork(history, work.id) orelse
                fallback_completed;
            break :blk if (assistant.len != 0 and text_utils.isModelSafeText(assistant))
                assistant
            else
                fallback_completed;
        },
        .failed => blk: {
            formatted = try std.fmt.allocPrint(
                alloc,
                "One-off subagent failed: {s}",
                .{transition.reason orelse "unknown failure"},
            );
            break :blk formatted.?;
        },
        .cancelled => blk: {
            formatted = try std.fmt.allocPrint(
                alloc,
                "One-off subagent cancelled: {s}",
                .{work.cancellation_reason orelse transition.reason orelse "cancelled"},
            );
            break :blk formatted.?;
        },
        .pending, .running, .awaiting_approval, .interrupted => return error.InvalidRecord,
    };
    return boundedFinalResultAlloc(alloc, raw);
}

fn reconcileOneOffFinalResultLocked(
    alloc: Allocator,
    store: communication_store.Store,
    record: control_store.Record,
    history: []const types.HistoryTurn,
) communication_manager.Error!bool {
    if (record.mode != .one_off) return false;
    var index = record.queue.len;
    while (index > 0) {
        index -= 1;
        const work = record.queue[index];
        switch (work.status) {
            .completed, .failed, .cancelled => {},
            else => continue,
        }
        const parent_id = record.parent_id orelse return error.InvalidRecord;
        const transition = terminalTransitionForWork(
            record.events,
            work.id,
            work.status,
        ) orelse return error.InvalidRecord;
        const content = oneOffFinalResultAlloc(
            alloc,
            work,
            transition,
            history,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidRecord => error.InvalidRecord,
        };
        defer alloc.free(content);
        return communication_manager.reconcileFinalResultLocked(alloc, store, .{
            .child_id = record.child_id,
            .parent_id = parent_id,
            .work_id = work.id,
            .timestamp_ms = transition.timestamp_ms,
            .content = content,
        });
    }
    return false;
}

fn findDeliveryById(
    deliveries: []const communication.Delivery,
    id: []const u8,
) ?communication.Delivery {
    for (deliveries) |delivery| {
        if (std.mem.eql(u8, delivery.id, id)) return delivery;
    }
    return null;
}

fn failAdmission(
    alloc: Allocator,
    record: *control_store.Record,
    index: usize,
    timestamp_ms: i64,
) TransitionError!void {
    const previous = record.queue[index].status;
    record.queue[index].status = .failed;
    record.updated_at_ms = timestamp_ms;
    record.state = if (record.mode == .one_off)
        .failed
    else
        remainingWorkState(record.queue) orelse .idle;
    try appendSingleTransition(
        alloc,
        record,
        record.queue[index].id,
        previous,
        .failed,
        "admission_failed",
        timestamp_ms,
    );
}

fn serviceFailureReason(err: ServiceError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out_of_memory",
        error.AdmissionFailed => "admission_failed",
        error.ProviderFailed => "provider_failed",
        error.Cancelled => "cancelled",
    };
}

test "one off terminal results and retry classification stay bounded" {
    const alloc = std.testing.allocator;
    const transition = TerminalTransition{ .timestamp_ms = 2, .reason = "provider_failed" };
    const failed = domain.QueuedMessage{
        .id = @constCast("failed-work"),
        .source_id = @constCast("parent"),
        .content = @constCast("work"),
        .status = .failed,
        .created_at_ms = 1,
    };
    const failed_result = try oneOffFinalResultAlloc(alloc, failed, transition, &.{});
    defer alloc.free(failed_result);
    try std.testing.expectEqualStrings(
        "One-off subagent failed: provider_failed",
        failed_result,
    );

    const cancelled = domain.QueuedMessage{
        .id = @constCast("cancelled-work"),
        .source_id = @constCast("parent"),
        .content = @constCast("work"),
        .status = .cancelled,
        .cancellation_reason = @constCast("user cancelled"),
        .created_at_ms = 1,
    };
    const cancelled_result = try oneOffFinalResultAlloc(
        alloc,
        cancelled,
        .{ .timestamp_ms = 2, .reason = "user cancelled" },
        &.{},
    );
    defer alloc.free(cancelled_result);
    try std.testing.expectEqualStrings(
        "One-off subagent cancelled: user cancelled",
        cancelled_result,
    );

    const oversized = try alloc.alloc(u8, communication.max_delivery_content_bytes + 100);
    defer alloc.free(oversized);
    @memset(oversized, 'a');
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("work"), .work_id = @constCast("completed-work") },
        .assistant = oversized,
    } }};
    const completed = domain.QueuedMessage{
        .id = @constCast("completed-work"),
        .source_id = @constCast("parent"),
        .content = @constCast("work"),
        .status = .completed,
        .created_at_ms = 1,
    };
    const completed_result = try oneOffFinalResultAlloc(
        alloc,
        completed,
        .{ .timestamp_ms = 2, .reason = null },
        &history,
    );
    defer alloc.free(completed_result);
    try std.testing.expectEqual(
        communication.max_delivery_content_bytes,
        completed_result.len,
    );
    try std.testing.expect(std.mem.endsWith(u8, completed_result, "]"));

    try std.testing.expect(shouldScheduleRetirementRetry(error.LockBusy));
    try std.testing.expect(shouldScheduleRetirementRetry(error.CommitIndeterminate));
    try std.testing.expect(!shouldScheduleRetirementRetry(error.LockUnsupported));
    try std.testing.expect(!shouldScheduleRetirementRetry(error.PathUnsafe));
    try std.testing.expect(!shouldScheduleRetirementRetry(error.InvalidRecord));

    const eligible = OneOffRetirementFacts{
        .mode = .one_off,
        .state = .completed,
        .result_acknowledged = true,
        .migration_complete = true,
        .active_count = 0,
    };
    try std.testing.expect(canRetireOneOff(eligible));
    var rejected = eligible;
    rejected.mode = .persistent;
    try std.testing.expect(!canRetireOneOff(rejected));
    rejected = eligible;
    rejected.state = .running;
    try std.testing.expect(!canRetireOneOff(rejected));
    rejected = eligible;
    rejected.result_acknowledged = false;
    try std.testing.expect(!canRetireOneOff(rejected));
    rejected = eligible;
    rejected.migration_complete = false;
    try std.testing.expect(!canRetireOneOff(rejected));
    rejected = eligible;
    rejected.active_count = null;
    try std.testing.expect(!canRetireOneOff(rejected));
    rejected = eligible;
    rejected.active_count = 1;
    try std.testing.expect(!canRetireOneOff(rejected));
}

fn mapOpenControlError(err: session_store.OpenSubagentControlError) ControlError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionNotFound => error.ChildNotFound,
        error.InvalidSessionId,
        error.SessionPathUnsafe,
        error.SessionStoreUnavailable,
        error.PrivateStatePermissionsUnsupported,
        error.SessionChildStoreFailed,
        => error.ControlStoreFailed,
    };
}

fn mapControlLockError(err: control_store.LockError) ControlError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlLockBusy => error.ControlLockBusy,
        error.ControlLockUnsupported => error.ControlLockUnsupported,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlStoreFailed,
        => error.ControlStoreFailed,
    };
}

fn mapControlLoadError(err: control_store.LoadError) ControlError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlNotFound => error.ChildNotFound,
        error.InvalidControlRecord,
        error.UnsupportedControlSchema,
        error.ControlRecordTooLarge,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlStoreFailed,
        => error.ControlStoreFailed,
    };
}

fn mapControlSaveError(err: control_store.SaveError) ControlError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlIdentityMismatch,
        error.ControlRecordTooLarge,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlCommitIndeterminate,
        error.ControlStoreFailed,
        => error.ControlStoreFailed,
    };
}

test "pure execution reductions preserve FIFO cancellation precedence and restart safety" {
    const alloc = std.testing.allocator;
    var record = try testRecord(alloc, .persistent, &.{ "first", "second" });
    defer record.deinit(alloc);

    try std.testing.expectEqual(@as(?usize, 0), nextRunnableIndex(record.queue, false));
    try admitWork(alloc, &record, 0, 2);
    try std.testing.expectEqual(domain.State.running, record.state);
    try std.testing.expect(record.events[record.events.len - 1].kind == .work_transition);
    try std.testing.expectEqual(CompletionDecision.committed, try finishWork(alloc, &record, "first", .completed, 3));
    try std.testing.expectEqual(domain.State.queued, record.state);
    try std.testing.expectEqual(@as(?usize, 1), nextRunnableIndex(record.queue, false));

    try admitWork(alloc, &record, 1, 4);
    try std.testing.expectEqual(@as(usize, 1), try cancelWork(alloc, &record, "stop", 5));
    try std.testing.expectEqual(CompletionDecision.cancellation_won, try finishWork(alloc, &record, "second", .completed, 6));
    try std.testing.expectEqual(domain.QueueStatus.cancelled, record.queue[1].status);
    try std.testing.expectEqualStrings(
        "stop",
        record.events[record.events.len - 1].kind.work_transition.reason.?,
    );

    var awaiting = try testRecord(alloc, .persistent, &.{"approval"});
    defer awaiting.deinit(alloc);
    try admitWork(alloc, &awaiting, 0, 6);
    try std.testing.expectEqual(
        CompletionDecision.committed,
        try finishWork(alloc, &awaiting, "approval", .awaiting_approval, 7),
    );
    try std.testing.expectEqual(domain.State.awaiting_approval, awaiting.state);
    try std.testing.expectEqual(
        domain.QueueStatus.awaiting_approval,
        awaiting.events[awaiting.events.len - 1].kind.work_transition.current,
    );

    var paused = try testRecord(alloc, .one_off, &.{"provider-recovery"});
    defer paused.deinit(alloc);
    try admitWork(alloc, &paused, 0, 8);
    try std.testing.expectEqual(
        CompletionDecision.committed,
        try finishWork(alloc, &paused, "provider-recovery", .paused, 9),
    );
    try std.testing.expectEqual(domain.State.interrupted, paused.state);
    try std.testing.expectEqual(domain.QueueStatus.interrupted, paused.queue[0].status);
    try std.testing.expectEqualStrings(
        recovery_paused_reason,
        paused.queue[0].cancellation_reason.?,
    );
    try std.testing.expectEqualStrings(
        recovery_paused_reason,
        paused.events[paused.events.len - 1].kind.work_transition.reason.?,
    );

    var restart = try testRecord(alloc, .persistent, &.{"queued"});
    defer restart.deinit(alloc);
    const recovered = try recoverAfterRestart(alloc, &restart, null, 7);
    try std.testing.expectEqual(@as(usize, 1), recovered.interrupted);
    try std.testing.expectEqual(domain.QueueStatus.interrupted, restart.queue[0].status);
    try std.testing.expectEqualStrings(
        "interrupted by process restart",
        restart.events[restart.events.len - 1].kind.work_transition.reason.?,
    );
    try std.testing.expect(nextRunnableIndex(restart.queue, false) == null);
    try std.testing.expectEqual(@as(?usize, 0), nextRunnableIndex(restart.queue, true));

    var restart_fifo = try testRecord(alloc, .persistent, &.{ "first", "second" });
    defer restart_fifo.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 2),
        (try recoverAfterRestart(alloc, &restart_fifo, null, 8)).interrupted,
    );
    try admitWork(alloc, &restart_fifo, 0, 9);
    try std.testing.expectEqual(
        CompletionDecision.committed,
        try finishWork(alloc, &restart_fifo, "first", .completed, 10),
    );
    try std.testing.expectEqual(domain.State.interrupted, restart_fifo.state);
    try admitWork(alloc, &restart_fifo, 1, 11);
    try std.testing.expectEqual(@as(usize, 1), try cancelWork(alloc, &restart_fifo, "stop retry", 12));
    try std.testing.expectEqual(domain.State.idle, restart_fifo.state);

    var cancel_fifo = try testRecord(alloc, .persistent, &.{ "first", "second" });
    defer cancel_fifo.deinit(alloc);
    _ = try recoverAfterRestart(alloc, &cancel_fifo, null, 13);
    try admitWork(alloc, &cancel_fifo, 0, 14);
    try std.testing.expectEqual(@as(usize, 1), try cancelWork(alloc, &cancel_fifo, "cancel active", 15));
    try std.testing.expectEqual(domain.State.interrupted, cancel_fifo.state);
    try std.testing.expectEqual(domain.QueueStatus.interrupted, cancel_fifo.queue[1].status);
}

test "restart recovery never promotes a committed interrupted transcript to completion" {
    const interrupted_history = [_]types.HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("interrupted work") },
    } }};
    try std.testing.expect(completedWorkIdForRecovery(
        "work-id",
        &interrupted_history,
    ) == null);

    const completed_history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("completed work") },
        .assistant = @constCast("done"),
    } }};
    try std.testing.expectEqualStrings(
        "work-id",
        completedWorkIdForRecovery("work-id", &completed_history).?,
    );
}

test "admission snapshot is isolated owned and preserves configured permission mode" {
    const alloc = std.testing.allocator;
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("run_command"),
        .pattern = @constCast("git status"),
        .action = .allow,
    }};
    var grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("write_file"),
        .target_path = @constCast("/tmp/a"),
    }};
    var snapshot = try domain.captureAdmission(alloc, .{
        .parent_id = "parent",
        .source_id = "source",
        .model = "test/model",
        .effort = types.ReasoningEffort.literal("high"),
        .permission_mode = .ask,
        .tool_names = &.{ "read_file", "write_file" },
        .rules = .{ .rules = &rules },
        .grants = &grants,
        .integration_names = &.{"mcp:test"},
    });
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.ask, snapshot.permission_mode);
    try std.testing.expectEqualStrings("test/model", snapshot.model);
    try std.testing.expectEqualStrings("write_file", snapshot.tool_names[1]);
    try std.testing.expectEqualStrings("/tmp/a", snapshot.grants[0].target_path);
}

fn testRecord(
    alloc: Allocator,
    mode: domain.Mode,
    ids: []const []const u8,
) !control_store.Record {
    var configuration = try makeTestConfiguration(alloc);
    errdefer configuration.deinit(alloc);
    const queue = try alloc.alloc(domain.QueuedMessage, ids.len);
    var initialized: usize = 0;
    errdefer {
        for (queue[0..initialized]) |*message| message.deinit(alloc);
        alloc.free(queue);
    }
    for (ids, queue) |id, *message| {
        message.* = try makeTestMessage(alloc, id);
        initialized += 1;
    }
    const child_id = try alloc.dupe(u8, "child");
    errdefer alloc.free(child_id);
    const events = try alloc.alloc(domain.Event, 0);
    errdefer alloc.free(events);
    const operations = try alloc.alloc(domain.OperationReceipt, 0);
    return .{
        .child_id = child_id,
        .generation = 0,
        .parent_id = null,
        .mode = mode,
        .configuration = configuration,
        .state = if (ids.len == 0) .idle else .queued,
        .queue = queue,
        .events = events,
        .operations = operations,
        .next_event_sequence = 1,
        .notification_cursor = 0,
        .created_at_ms = 1,
        .updated_at_ms = 1,
    };
}

fn makeTestConfiguration(alloc: Allocator) !domain.Configuration {
    var notifications = try makeTestNotifications(alloc);
    errdefer notifications.deinit(alloc);
    return .{
        .name = try alloc.dupe(u8, "child"),
        .notifications = notifications,
    };
}

fn makeTestNotifications(alloc: Allocator) !domain.NotificationPolicy {
    const milestones = try alloc.alloc([]u8, 0);
    errdefer alloc.free(milestones);
    return .{
        .milestones = milestones,
        .stop_conditions = try alloc.dupe(domain.StopCondition, &.{.terminal}),
    };
}

fn makeTestMessage(alloc: Allocator, id: []const u8) !domain.QueuedMessage {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const source_id = try alloc.dupe(u8, "parent");
    errdefer alloc.free(source_id);
    return .{
        .id = owned_id,
        .source_id = source_id,
        .content = try alloc.dupe(u8, id),
        .created_at_ms = 1,
    };
}

const TestEnvironment = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    store: session_store.Store,

    fn init(alloc: Allocator) !TestEnvironment {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        return .{
            .tmp = tmp,
            .home = home,
            .workspace = workspace,
            .store = try session_store.Store.initFromHome(alloc, home, workspace),
        };
    }

    fn deinit(self: *TestEnvironment, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn createSession(self: *TestEnvironment, alloc: Allocator, id: []const u8) !void {
        var state = try testSessionState(alloc, id, self.workspace);
        defer state.deinit(alloc);
        var loaded = try self.store.startWritableSession(alloc, state);
        loaded.deinit(alloc);
    }

    fn installControl(
        self: *TestEnvironment,
        alloc: Allocator,
        child_id: []const u8,
        mode: domain.Mode,
        model: []const u8,
        effort: types.ReasoningEffort,
        messages: []const []const u8,
    ) !void {
        var record = try testRecord(alloc, mode, messages);
        defer record.deinit(alloc);
        alloc.free(record.child_id);
        record.child_id = try alloc.dupe(u8, child_id);
        record.parent_id = try alloc.dupe(u8, "parent");
        record.configuration.model = try alloc.dupe(u8, model);
        record.configuration.effort = effort;
        if (record.queue.len != 0) {
            const transitions = try alloc.alloc(manager_mod.WorkTransitionInput, record.queue.len);
            defer alloc.free(transitions);
            for (record.queue, transitions) |message, *transition| transition.* = .{
                .work_item_id = message.id,
                .previous = null,
                .current = .pending,
            };
            try manager_mod.appendWorkRevision(alloc, &record, transitions, 1);
        }
        var capability = try self.store.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const storage = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = try storage.acquireLock();
        defer lock.release();
        try storage.save(alloc, record);
    }

    fn setNotificationPolicy(
        self: *TestEnvironment,
        alloc: Allocator,
        child_id: []const u8,
        policy: domain.NotificationPolicy,
    ) !void {
        var capability = try self.store.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const storage = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = try storage.acquireLock();
        defer lock.release();
        var record = try storage.load(alloc);
        defer record.deinit(alloc);
        const replacement = try policy.clone(alloc);
        record.configuration.notifications.deinit(alloc);
        record.configuration.notifications = replacement;
        try storage.save(alloc, record);
    }

    fn setPermissionMode(
        self: *TestEnvironment,
        alloc: Allocator,
        child_id: []const u8,
        permission_mode: types.PermissionMode,
    ) !void {
        var capability = try self.store.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const storage = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = try storage.acquireLock();
        defer lock.release();
        var record = try storage.load(alloc);
        defer record.deinit(alloc);
        record.configuration.permission_mode = permission_mode;
        try storage.save(alloc, record);
    }

    fn loadControl(
        self: *TestEnvironment,
        alloc: Allocator,
        child_id: []const u8,
    ) !control_store.Record {
        var capability = try self.store.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const storage = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        return storage.load(alloc);
    }

    fn loadCommunication(
        self: *TestEnvironment,
        alloc: Allocator,
        session_id: []const u8,
    ) !communication.Ledger {
        var capability = try self.store.openSubagentControlCapabilityReadOnly(
            alloc,
            session_id,
            .{},
        );
        defer capability.deinit();
        const storage = communication_store.Store{
            .capability = &capability,
            .expected_session_id = session_id,
        };
        return storage.load(alloc);
    }
};

fn testSessionState(
    alloc: Allocator,
    id: []const u8,
    workspace: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, workspace);
    errdefer alloc.free(origin);
    const current = try alloc.dupe(u8, workspace);
    errdefer alloc.free(current);
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "session/default"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

const Observation = struct {
    child_id: []u8,
    content: []u8,
    model: []u8,
    effort: types.ReasoningEffort,
    tool_name: []u8,
    rule_pattern: []u8,
    grant_target: []u8,
    integration_name: []u8,

    fn deinit(self: *Observation, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.content);
        alloc.free(self.model);
        alloc.free(self.tool_name);
        alloc.free(self.rule_pattern);
        alloc.free(self.grant_target);
        alloc.free(self.integration_name);
        self.* = undefined;
    }
};

const FakeExecution = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    observations: std.ArrayList(Observation) = .empty,
    entered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    barrier: bool = false,
    capture_fails: bool = false,
    run_fails: bool = false,
    authority_epoch: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    worker_active_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn services(self: *FakeExecution) Services {
        return .{
            .context = self,
            .capture_fn = capture,
            .run_fn = run,
        };
    }

    fn deinit(self: *FakeExecution) void {
        for (self.observations.items) |*observation| observation.deinit(self.alloc);
        self.observations.deinit(self.alloc);
        self.* = undefined;
    }

    fn capture(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        const self: *FakeExecution = @ptrCast(@alignCast(raw.?));
        if (self.capture_fails) return error.AdmissionFailed;
        const current = self.authority_epoch.load(.seq_cst);
        var rules = [_]types.PermissionRule{.{
            .permission = @constCast(if (current == 0) "read" else "write"),
            .pattern = @constCast(if (current == 0) "old.txt" else "new.txt"),
            .action = .allow,
        }};
        var grants = [_]types.PermissionGrant{.{
            .tool_name = @constCast(if (current == 0) "read_file" else "write_file"),
            .target_path = @constCast(if (current == 0) "/tmp/old.txt" else "/tmp/new.txt"),
        }};
        return domain.captureAdmission(alloc, .{
            .parent_id = request.parent_id,
            .source_id = request.source_id,
            .model = request.preferences.model,
            .effort = request.preferences.effort,
            .tool_names = if (current == 0) &.{"read_file"} else &.{"write_file"},
            .rules = .{ .rules = &rules },
            .grants = &grants,
            .integration_names = if (current == 0) &.{"mcp:old"} else &.{"mcp:new"},
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.AdmissionFailed,
        };
    }

    fn run(
        raw: ?*anyopaque,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        return runImpl(raw, turn, message, admission, cancel) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            else => error.ProviderFailed,
        };
    }

    fn runImpl(
        raw: ?*anyopaque,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) !RunOutcome {
        const self: *FakeExecution = @ptrCast(@alignCast(raw.?));
        if (turn.worker.worker_processing) {
            self.worker_active_seen.store(true, .seq_cst);
        }
        var observation = try makeObservation(
            self.alloc,
            turn.loaded.active_id,
            message.content,
            admission,
        );
        self.mutex.lockUncancelable(io_mod.getIo());
        self.observations.append(self.alloc, observation) catch |err| {
            self.mutex.unlock(io_mod.getIo());
            observation.deinit(self.alloc);
            return err;
        };
        self.mutex.unlock(io_mod.getIo());
        _ = self.entered.fetchAdd(1, .seq_cst);
        if (self.barrier) {
            while (!self.release.load(.seq_cst) and !cancel.load(.seq_cst)) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }
        if (cancel.load(.seq_cst)) return error.Cancelled;
        if (self.run_fails) return error.ProviderFailed;

        const response = try std.fmt.allocPrint(
            self.alloc,
            "model={s} effort={s} tool=read_file content={s}",
            .{ admission.model, admission.effort.label(), message.content },
        );
        defer self.alloc.free(response);
        var history_turn = try session.makeAssistantTurn(
            self.alloc,
            message.content,
            response,
        );
        defer session.freeHistoryTurn(self.alloc, history_turn);
        var calls = [_]types.ToolCall{.{
            .id = "call_read",
            .name = "read_file",
            .arguments_json = "{\"path\":\"fixture\"}",
        }};
        var results = [_]types.PersistedToolResult{.{
            .tool_call_id = @constCast("call_read"),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = message.content,
            .output_bytes = message.content.len,
            .stored_output_bytes = message.content.len,
        }};
        var steps = [_]types.ToolExecutionStep{.{
            .tool_calls = &calls,
            .tool_results = &results,
        }};
        history_turn.assistant.execution = try types.dupeExecutionMemory(
            self.alloc,
            .{ .tool_steps = &steps },
        );
        try turn.commit(message.id, history_turn, 1, 1, 2);
        return .completed;
    }
};

const ApprovalBlockingExecution = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    permission_resolved: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    denied: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_mutex: std.Io.Mutex = .init,
    active_worker: ?*worker_runtime.WorkerRuntime = null,

    fn services(self: *@This()) Services {
        return .{
            .context = self,
            .capture_fn = capture,
            .run_fn = run,
        };
    }

    fn capture(
        _: ?*anyopaque,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        return domain.captureAdmission(alloc, .{
            .parent_id = request.parent_id,
            .source_id = request.source_id,
            .model = request.preferences.model,
            .effort = request.preferences.effort,
            .tool_names = &.{"create_folder"},
            .rules = .{ .rules = &.{} },
            .grants = &.{},
            .integration_names = &.{},
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.AdmissionFailed,
        };
    }

    fn run(
        raw: ?*anyopaque,
        turn: *TurnContext,
        _: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        self.active_worker = turn.workerRuntime();
        self.worker_mutex.unlock(io_mod.getIo());
        defer {
            self.worker_mutex.lockUncancelable(io_mod.getIo());
            self.active_worker = null;
            self.worker_mutex.unlock(io_mod.getIo());
        }
        self.entered.store(true, .seq_cst);
        var response = turn.permissionPrompter().request(
            turn.alloc,
            .{
                .label = "create_folder blocked",
                .command = "mkdir blocked",
            },
            .{
                .id = "approval-blocked-call",
                .name = "create_folder",
                .arguments_json = "{\"path\":\"blocked\"}",
            },
            null,
            null,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProviderFailed,
        };
        defer response.deinit();
        self.denied.store(response.decision == .deny, .seq_cst);
        self.permission_resolved.store(true, .seq_cst);
        if (cancel.load(.seq_cst)) return error.Cancelled;
        return error.ProviderFailed;
    }

    fn requestShutdown(self: *@This()) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.active_worker) |worker| worker.requestShutdown();
    }
};

fn makeObservation(
    alloc: Allocator,
    child_id: []const u8,
    content: []const u8,
    admission: domain.AdmissionSnapshot,
) !Observation {
    const owned_child_id = try alloc.dupe(u8, child_id);
    errdefer alloc.free(owned_child_id);
    const owned_content = try alloc.dupe(u8, content);
    errdefer alloc.free(owned_content);
    const model = try alloc.dupe(u8, admission.model);
    errdefer alloc.free(model);
    const tool_name = try alloc.dupe(u8, admission.tool_names[0]);
    errdefer alloc.free(tool_name);
    const rule_pattern = try alloc.dupe(u8, admission.rules.rules[0].pattern);
    errdefer alloc.free(rule_pattern);
    const grant_target = try alloc.dupe(u8, admission.grants[0].target_path);
    errdefer alloc.free(grant_target);
    return .{
        .child_id = owned_child_id,
        .content = owned_content,
        .model = model,
        .effort = admission.effort,
        .tool_name = tool_name,
        .rule_pattern = rule_pattern,
        .grant_target = grant_target,
        .integration_name = try alloc.dupe(u8, admission.integration_names[0]),
    };
}

fn findObservation(
    observations: []const Observation,
    child_id: []const u8,
    content: []const u8,
) ?Observation {
    for (observations) |observation| {
        if (std.mem.eql(u8, observation.child_id, child_id) and
            std.mem.eql(u8, observation.content, content)) return observation;
    }
    return null;
}

fn waitForEntries(execution: *FakeExecution, expected: usize) !void {
    const deadline = io_mod.milliTimestamp() + 5000;
    while (execution.entered.load(.seq_cst) < expected and
        io_mod.milliTimestamp() < deadline)
    {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    if (execution.entered.load(.seq_cst) < expected) return error.TestUnexpectedResult;
}

fn waitForNoLiveSlots(owner: *Owner) !void {
    const deadline = io_mod.milliTimestamp() + 5000;
    while (io_mod.milliTimestamp() < deadline) {
        owner.mutex.lockUncancelable(io_mod.getIo());
        const live_slots = owner.slots.items.len;
        owner.mutex.unlock(io_mod.getIo());
        if (live_slots == 0) return;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    return error.TestUnexpectedResult;
}

const FakeNotificationClock = struct {
    now_ms: i64,

    fn now(raw: ?*anyopaque) i64 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.now_ms;
    }

    fn clock(self: *@This()) NotificationClock {
        return .{ .context = self, .now_fn = now };
    }
};

const FakeNotificationPoller = struct {
    calls: usize = 0,
    failures_remaining: usize = 0,
    outcome: communication_manager.PollOutcome,

    fn poll(
        raw: ?*anyopaque,
        _: Allocator,
        _: []const u8,
        _: []const u8,
        _: i64,
    ) communication_manager.Error!communication_manager.PollOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.failures_remaining != 0) {
            self.failures_remaining -= 1;
            return error.LockBusy;
        }
        return self.outcome;
    }

    fn poller(self: *@This()) NotificationPoller {
        return .{ .context = self, .poll_fn = poll };
    }
};

const DurableNotificationPoller = struct {
    manager: communication_manager.Manager,

    fn poll(
        raw: ?*anyopaque,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        now_ms: i64,
    ) communication_manager.Error!communication_manager.PollOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.manager.poll(alloc, child_id, work_id, now_ms);
    }

    fn poller(self: *@This()) NotificationPoller {
        return .{ .context = self, .poll_fn = poll };
    }
};

const NotificationLockClock = struct {
    now_ms: i64 = 0,

    fn alwaysBusy(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
        return false;
    }

    fn now(raw: ?*anyopaque) i64 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.now_ms;
    }

    fn sleep(raw: ?*anyopaque, millis: u64) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.now_ms += @intCast(millis);
    }

    fn options(self: *@This()) session_child_store.Options {
        return .{ .lock_ops = .{
            .ctx = self,
            .try_lock = alwaysBusy,
            .now_ms = now,
            .sleep_ms = sleep,
        } };
    }
};

const BlockingNotificationPoller = struct {
    calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn poll(
        raw: ?*anyopaque,
        _: Allocator,
        _: []const u8,
        _: []const u8,
        _: i64,
    ) communication_manager.Error!communication_manager.PollOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        return .{ .pending = 0 };
    }

    fn poller(self: *@This()) NotificationPoller {
        return .{ .context = self, .poll_fn = poll };
    }
};

fn captureTestNotificationPolicy(
    alloc: Allocator,
    env: *TestEnvironment,
    child_id: []const u8,
    work_id: []const u8,
    policy: domain.NotificationPolicy,
    started_at_ms: i64,
) !i64 {
    var delivery_manager = communication_manager.Manager{ .sessions = &env.store };
    return (try delivery_manager.captureWorkPolicy(
        alloc,
        child_id,
        work_id,
        policy,
        started_at_ms,
    )).?;
}

test "notification owner keeps exact child and work schedule identities" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 0 };
    var poller = FakeNotificationPoller{ .outcome = .{ .pending = 1000 } };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    defer owner.deinit();

    try owner.registerNotificationSchedule("child", "work-a", 100);
    try owner.registerNotificationSchedule("child", "work-b", 200);
    try owner.registerNotificationSchedule("child", "work-a", 150);

    try std.testing.expectEqual(@as(usize, 2), owner.notification_schedules.items.len);
    var work_a_due: ?i64 = null;
    var work_b_due: ?i64 = null;
    for (owner.notification_schedules.items) |schedule| {
        if (std.mem.eql(u8, schedule.work_id, "work-a")) {
            work_a_due = schedule.next_check_ms;
        } else if (std.mem.eql(u8, schedule.work_id, "work-b")) {
            work_b_due = schedule.next_check_ms;
        }
    }
    try std.testing.expectEqual(@as(?i64, 150), work_a_due);
    try std.testing.expectEqual(@as(?i64, 200), work_b_due);
}

test "duration-only notification reports cancelled state until its duration boundary" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "duration-cancel");
    try env.installControl(
        alloc,
        "duration-cancel",
        .persistent,
        "model/duration",
        types.ReasoningEffort.literal("medium"),
        &.{"duration-work"},
    );
    var policy = try domain.validateNotificationPolicy(alloc, .{
        .terminal = .{ .completed = false, .failed = false, .cancelled = false },
        .report_interval_ms = 100,
        .report_duration_ms = 250,
        .stop_conditions = &.{.duration_elapsed},
    });
    defer policy.deinit(alloc);
    const next_check_ms = try captureTestNotificationPolicy(
        alloc,
        &env,
        "duration-cancel",
        "duration-work",
        policy,
        0,
    );

    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 10 };
    var durable_poller = DurableNotificationPoller{
        .manager = .{ .sessions = &env.store },
    };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = durable_poller.poller(),
    };
    defer owner.deinit();
    try owner.registerNotificationSchedule(
        "duration-cancel",
        "duration-work",
        next_check_ms,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        try owner.cancel("duration-cancel", "cancelled before first report", 10),
    );
    try std.testing.expectEqual(@as(usize, 1), owner.notification_schedules.items.len);
    const cancellation_check = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 0), cancellation_check.emitted);

    clock.now_ms = 100;
    const report = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), report.emitted);
    var after_report = try env.loadCommunication(alloc, "duration-cancel");
    defer after_report.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), after_report.deliveries.len);
    try std.testing.expectEqual(
        domain.State.cancelled,
        after_report.deliveries[0].payload.interval.state,
    );

    clock.now_ms = 250;
    const stopped = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), stopped.stopped);
    try std.testing.expectEqual(@as(usize, 0), owner.notification_schedules.items.len);
    var compacted = try env.loadCommunication(alloc, "duration-cancel");
    defer compacted.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), compacted.work_notifications.len);
}

test "terminal notification cancellation removes schedule after durable compaction" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "terminal-schedule");
    try env.installControl(
        alloc,
        "terminal-schedule",
        .persistent,
        "model/terminal",
        types.ReasoningEffort.literal("medium"),
        &.{"terminal-work"},
    );
    var policy = try domain.validateNotificationPolicy(alloc, .{
        .report_interval_ms = 100,
        .stop_conditions = &.{.terminal},
    });
    defer policy.deinit(alloc);
    const next_check_ms = try captureTestNotificationPolicy(
        alloc,
        &env,
        "terminal-schedule",
        "terminal-work",
        policy,
        0,
    );

    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 10 };
    var durable_poller = DurableNotificationPoller{
        .manager = .{ .sessions = &env.store },
    };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = durable_poller.poller(),
    };
    defer owner.deinit();
    try owner.registerNotificationSchedule(
        "terminal-schedule",
        "terminal-work",
        next_check_ms,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        try owner.cancel("terminal-schedule", "terminal cancellation", 10),
    );
    try std.testing.expectEqual(@as(usize, 1), owner.notification_schedules.items.len);
    const stopped = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), stopped.stopped);
    try std.testing.expectEqual(@as(usize, 0), owner.notification_schedules.items.len);
    var ledger = try env.loadCommunication(alloc, "terminal-schedule");
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), ledger.work_notifications.len);
    try std.testing.expectEqual(@as(usize, 1), ledger.deliveries.len);
    try std.testing.expectEqual(
        domain.State.cancelled,
        ledger.deliveries[0].payload.terminal,
    );
}

test "cancellation polling retries lock and indeterminate compaction exactly once" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "cancel-retry");
    try env.installControl(
        alloc,
        "cancel-retry",
        .persistent,
        "model/retry",
        types.ReasoningEffort.literal("medium"),
        &.{"retry-work"},
    );
    var policy = try domain.validateNotificationPolicy(alloc, .{
        .report_interval_ms = 100,
        .stop_conditions = &.{.terminal},
    });
    defer policy.deinit(alloc);
    const next_check_ms = try captureTestNotificationPolicy(
        alloc,
        &env,
        "cancel-retry",
        "retry-work",
        policy,
        0,
    );

    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 10 };
    var durable_poller = DurableNotificationPoller{
        .manager = .{ .sessions = &env.store },
    };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = durable_poller.poller(),
    };
    defer owner.deinit();
    try owner.registerNotificationSchedule(
        "cancel-retry",
        "retry-work",
        next_check_ms,
    );
    var reconciliation_failure = FailNthControlSync{ .fail_at = 1 };
    owner.communication_store_options = .{ .replace_ops = .{
        .ctx = &reconciliation_failure,
        .sync_file = FailNthControlSync.syncFile,
    } };
    try std.testing.expectEqual(
        @as(usize, 1),
        try owner.cancel("cancel-retry", "retry cancellation", 10),
    );
    owner.communication_store_options = .{};

    var lock_clock = NotificationLockClock{};
    durable_poller.manager.child_store_options = lock_clock.options();
    const contended = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), contended.retryable_failures);
    try std.testing.expectEqual(@as(usize, 1), owner.notification_schedules.items.len);

    var commit_failure = FailNthControlSync{ .fail_at = 1 };
    durable_poller.manager.child_store_options = .{ .replace_ops = .{
        .ctx = &commit_failure,
        .sync_dir = FailNthControlSync.syncDir,
    } };
    clock.now_ms = 35;
    const indeterminate = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), indeterminate.retryable_failures);
    try std.testing.expectEqual(@as(usize, 1), owner.notification_schedules.items.len);

    durable_poller.manager.child_store_options = .{};
    clock.now_ms = 60;
    const retried = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), retried.stopped);
    try std.testing.expectEqual(@as(usize, 0), owner.notification_schedules.items.len);
    var ledger = try env.loadCommunication(alloc, "cancel-retry");
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), ledger.work_notifications.len);
    try std.testing.expectEqual(@as(usize, 1), ledger.deliveries.len);
    try std.testing.expectEqual(
        domain.State.cancelled,
        ledger.deliveries[0].payload.terminal,
    );
}

test "sequential work notification policies coexist for one child" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "sequential-policy");
    try env.installControl(
        alloc,
        "sequential-policy",
        .persistent,
        "model/sequential",
        types.ReasoningEffort.literal("medium"),
        &.{ "work-a", "work-b" },
    );
    var policy = try domain.validateNotificationPolicy(alloc, .{
        .report_interval_ms = 3_600_000,
        .report_duration_ms = 7_200_000,
        .stop_conditions = &.{.duration_elapsed},
    });
    defer policy.deinit(alloc);
    try env.setNotificationPolicy(alloc, "sequential-policy", policy);

    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 0 };
    var poller = FakeNotificationPoller{ .outcome = .{ .pending = 1 } };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    defer owner.deinit();

    try std.testing.expectEqual(
        StartResult.started,
        try owner.start("sequential-policy", false),
    );
    try std.testing.expectEqual(
        ChildResult.idle,
        try owner.join("sequential-policy"),
    );
    try std.testing.expectEqual(@as(usize, 2), owner.notification_schedules.items.len);
    var ledger = try env.loadCommunication(alloc, "sequential-policy");
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), ledger.work_notifications.len);
    try std.testing.expect(
        communication.findWorkNotification(
            ledger.work_notifications,
            "work-a",
        ) != null,
    );
    try std.testing.expect(
        communication.findWorkNotification(
            ledger.work_notifications,
            "work-b",
        ) != null,
    );
}

test "close and detach compact timer state before dropping schedules" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var policy = try domain.validateNotificationPolicy(alloc, .{
        .terminal = .{ .completed = false, .failed = false, .cancelled = false },
        .report_interval_ms = 100,
        .report_duration_ms = 1000,
        .stop_conditions = &.{.duration_elapsed},
    });
    defer policy.deinit(alloc);
    inline for (.{ "close-policy", "detach-policy" }) |child_id| {
        try env.createSession(alloc, child_id);
        try env.installControl(
            alloc,
            child_id,
            .persistent,
            "model/cleanup",
            types.ReasoningEffort.literal("medium"),
            &.{"cleanup-work"},
        );
        _ = try captureTestNotificationPolicy(
            alloc,
            &env,
            child_id,
            "cleanup-work",
            policy,
            0,
        );
    }

    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 10 };
    var durable_poller = DurableNotificationPoller{
        .manager = .{ .sessions = &env.store },
    };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = durable_poller.poller(),
    };
    defer owner.deinit();
    try owner.registerNotificationSchedule("close-policy", "cleanup-work", 100);
    try owner.registerNotificationSchedule("detach-policy", "cleanup-work", 100);

    var close_cleanup_failure = FailNthControlSync{ .fail_at = 1 };
    owner.communication_store_options = .{ .replace_ops = .{
        .ctx = &close_cleanup_failure,
        .sync_dir = FailNthControlSync.syncDir,
    } };
    var closed = try owner.close(alloc, "close-policy", .{
        .actor_id = "parent",
        .operation_id = "close-cleanup",
        .timestamp_ms = 10,
    });
    defer closed.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.lifecycle_changed, closed.receipt.code);
    try std.testing.expectEqual(@as(usize, 2), owner.notification_schedules.items.len);
    owner.communication_store_options = .{};
    const close_retry = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), close_retry.stopped);
    try std.testing.expectEqual(@as(usize, 1), owner.notification_schedules.items.len);
    var closed_ledger = try env.loadCommunication(alloc, "close-policy");
    defer closed_ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), closed_ledger.work_notifications.len);

    try std.testing.expectEqual(
        @as(usize, 1),
        try owner.cancel("detach-policy", "cancel before detach", 11),
    );
    var detach_cleanup_failure = FailNthControlSync{ .fail_at = 1 };
    owner.communication_store_options = .{ .replace_ops = .{
        .ctx = &detach_cleanup_failure,
        .sync_file = FailNthControlSync.syncFile,
    } };
    var detached = try owner.detach(alloc, "detach-policy", .{
        .actor_id = "parent",
        .operation_id = "detach-cleanup",
        .timestamp_ms = 11,
    });
    defer detached.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.relationship_changed, detached.receipt.code);
    try std.testing.expectEqual(@as(usize, 1), owner.notification_schedules.items.len);
    owner.communication_store_options = .{};
    clock.now_ms = 11;
    const detach_retry = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), detach_retry.stopped);
    try std.testing.expectEqual(@as(usize, 0), owner.notification_schedules.items.len);
    var detached_record = try env.loadControl(alloc, "detach-policy");
    defer detached_record.deinit(alloc);
    try std.testing.expect(detached_record.parent_id == null);
    var detached_ledger = try env.loadCommunication(alloc, "detach-policy");
    defer detached_ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), detached_ledger.work_notifications.len);
    try std.testing.expectEqual(@as(usize, 0), detached_ledger.deliveries.len);

    clock.now_ms = 1000;
    const after_cleanup = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 0), after_cleanup.registered);
    try std.testing.expectEqual(@as(usize, 0), after_cleanup.emitted);
}

fn checkNotificationScheduleRegistrationAllocationFailures(alloc: Allocator) !void {
    const durable_alloc = std.testing.allocator;
    var env = try TestEnvironment.init(durable_alloc);
    defer env.deinit(durable_alloc);
    var fake_execution = FakeExecution{ .alloc = durable_alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 0 };
    var poller = FakeNotificationPoller{ .outcome = .{ .pending = 100 } };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    defer owner.deinit();
    try owner.registerNotificationSchedule("child", "work-a", 100);
    try owner.registerNotificationSchedule("child", "work-b", 200);
    try owner.registerNotificationSchedule("child", "work-a", 150);
    try std.testing.expectEqual(@as(usize, 2), owner.notification_schedules.items.len);
}

test "notification schedule registration frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkNotificationScheduleRegistrationAllocationFailures,
        .{},
    );
}

fn checkNotificationCleanupAllocationFailures(alloc: Allocator) !void {
    const durable_alloc = std.testing.allocator;
    var env = try TestEnvironment.init(durable_alloc);
    defer env.deinit(durable_alloc);
    try env.createSession(durable_alloc, "cleanup-allocation");
    try env.installControl(
        durable_alloc,
        "cleanup-allocation",
        .persistent,
        "model/cleanup",
        types.ReasoningEffort.literal("medium"),
        &.{"cleanup-work"},
    );
    var policy = try domain.validateNotificationPolicy(durable_alloc, .{
        .report_interval_ms = 100,
    });
    defer policy.deinit(durable_alloc);
    _ = try captureTestNotificationPolicy(
        durable_alloc,
        &env,
        "cleanup-allocation",
        "cleanup-work",
        policy,
        0,
    );
    var delivery_manager = communication_manager.Manager{
        .sessions = &env.store,
    };
    delivery_manager.stopAndCompactNotifications(
        alloc,
        "cleanup-allocation",
    ) catch |err| return switch (err) {
        error.OutOfMemory, error.StoreUnavailable => error.OutOfMemory,
        else => err,
    };
}

test "notification cleanup frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkNotificationCleanupAllocationFailures,
        .{},
    );
}

test "notification reaper shutdown racing a wake never double polls" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 0 };
    var poller = BlockingNotificationPoller{};
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    try owner.registerNotificationSchedule("child", "work", 0);
    owner.mutex.lockUncancelable(io_mod.getIo());
    try owner.ensureReaperLocked();
    owner.mutex.unlock(io_mod.getIo());
    while (!poller.entered.load(.seq_cst)) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    owner.wakeNotificationSchedules("child", 0);

    const Shutdown = struct {
        owner: *Owner,
        started: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            self.started.store(true, .seq_cst);
            self.owner.deinit();
        }
    };
    var shutdown_started = std.atomic.Value(bool).init(false);
    const shutdown_thread = try std.Thread.spawn(.{}, Shutdown.run, .{Shutdown{
        .owner = &owner,
        .started = &shutdown_started,
    }});
    while (!shutdown_started.load(.seq_cst)) std.atomic.spinLoopHint();
    while (true) {
        owner.mutex.lockUncancelable(io_mod.getIo());
        const closed = owner.closed;
        owner.mutex.unlock(io_mod.getIo());
        if (closed) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    poller.release.store(true, .seq_cst);
    shutdown_thread.join();
    try std.testing.expectEqual(@as(usize, 1), poller.calls.load(.seq_cst));
}

test "notification owner polls exact fake time and retries without model execution" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 99 };
    var poller = FakeNotificationPoller{
        .outcome = .{ .emitted = .{
            .coalesced_ticks = 1,
            .next_check_ms = 200,
        } },
    };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    defer owner.deinit();
    try owner.registerNotificationSchedule("child", "work", 100);

    const early = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), early.registered);
    try std.testing.expectEqual(@as(usize, 0), early.due);
    try std.testing.expectEqual(@as(usize, 0), poller.calls);

    clock.now_ms = 100;
    const due = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), due.due);
    try std.testing.expectEqual(@as(usize, 1), due.emitted);
    try std.testing.expectEqual(@as(usize, 1), poller.calls);
    try std.testing.expectEqual(@as(usize, 0), fake_execution.entered.load(.seq_cst));

    poller.failures_remaining = 1;
    clock.now_ms = 200;
    const contended = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), contended.retryable_failures);
    clock.now_ms = 224;
    try std.testing.expectEqual(@as(usize, 0), (try owner.pollNotifications()).due);
    clock.now_ms = 225;
    try std.testing.expectEqual(@as(usize, 1), (try owner.pollNotifications()).emitted);
    try std.testing.expectEqual(@as(usize, 0), fake_execution.entered.load(.seq_cst));
}

test "notification owner bounds hundreds of active schedules and excludes idle sessions" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 100 };
    var poller = FakeNotificationPoller{ .outcome = .{ .pending = 1000 } };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    defer owner.deinit();

    for (0..600) |index| {
        var child_buffer: [32]u8 = undefined;
        const child_id = try std.fmt.bufPrint(&child_buffer, "active-{d}", .{index});
        var work_buffer: [32]u8 = undefined;
        const work_id = try std.fmt.bufPrint(&work_buffer, "work-{d}", .{index});
        try owner.registerNotificationSchedule(
            child_id,
            work_id,
            if (index < 300) 100 else 1000,
        );
    }

    const report = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 600), report.registered);
    try std.testing.expectEqual(@as(usize, 300), report.due);
    try std.testing.expectEqual(@as(usize, 300), poller.calls);
    try std.testing.expectEqual(@as(usize, 600), owner.notification_schedules.items.len);

    var idle_owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    defer idle_owner.deinit();
    for (0..100) |_| {
        const idle_report = try idle_owner.pollNotifications();
        try std.testing.expectEqual(@as(usize, 0), idle_report.registered);
        try std.testing.expectEqual(@as(usize, 0), idle_report.due);
    }
    try std.testing.expectEqual(@as(usize, 300), poller.calls);
}

test "notification owner shutdown wakes a future timer without polling" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var fake_execution = FakeExecution{ .alloc = alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 0 };
    var poller = FakeNotificationPoller{ .outcome = .{ .pending = 10_000 } };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    try owner.registerNotificationSchedule("child", "work", 10_000);
    owner.mutex.lockUncancelable(io_mod.getIo());
    try owner.ensureReaperLocked();
    owner.mutex.unlock(io_mod.getIo());
    owner.deinit();
    try std.testing.expectEqual(@as(usize, 0), poller.calls);
}

fn checkNotificationOwnerPollAllocationFailures(alloc: Allocator) !void {
    const durable_alloc = std.testing.allocator;
    var env = try TestEnvironment.init(durable_alloc);
    defer env.deinit(durable_alloc);
    var fake_execution = FakeExecution{ .alloc = durable_alloc };
    defer fake_execution.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var clock = FakeNotificationClock{ .now_ms = 100 };
    var poller = FakeNotificationPoller{ .outcome = .{ .pending = 200 } };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake_execution.services(),
        .notification_clock = clock.clock(),
        .notification_poller = poller.poller(),
    };
    defer owner.deinit();
    try owner.registerNotificationSchedule("child", "work", 100);
    const report = try owner.pollNotifications();
    try std.testing.expectEqual(@as(usize, 1), report.due);
}

test "notification owner poll frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkNotificationOwnerPollAllocationFailures,
        .{},
    );
}

test "child waiter subscription is filtered sticky and bounded" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();

    var matching = ChildWaiter{ .child_id = "child-a" };
    try owner.registerChildWaiter(&matching);
    owner.mutex.lockUncancelable(io_mod.getIo());
    owner.signalChildWaitersLocked("child-a");
    owner.mutex.unlock(io_mod.getIo());
    try std.testing.expectEqual(
        ChildWaitResult.signaled,
        try matching.wait(.{
            .clock = .awake,
            .raw = .fromMilliseconds(5),
        }),
    );
    owner.unregisterChildWaiter(&matching);

    var unrelated = ChildWaiter{ .child_id = "child-b" };
    try owner.registerChildWaiter(&unrelated);
    owner.mutex.lockUncancelable(io_mod.getIo());
    owner.signalChildWaitersLocked("child-a");
    owner.mutex.unlock(io_mod.getIo());
    try std.testing.expectEqual(
        ChildWaitResult.timed_out,
        try unrelated.wait(.{
            .clock = .awake,
            .raw = .fromMilliseconds(1),
        }),
    );
    owner.unregisterChildWaiter(&unrelated);
}

test "owner reaps many distinct completed child threads before shutdown" {
    const alloc = std.testing.allocator;
    const child_count = completion_capacity + 1;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();

    for (0..child_count) |index| {
        const child_id = try std.fmt.allocPrint(alloc, "reaped-child-{d}", .{index});
        defer alloc.free(child_id);
        try env.createSession(alloc, child_id);
        try env.installControl(
            alloc,
            child_id,
            if (index % 2 == 0) .one_off else .persistent,
            "model/reaping",
            types.ReasoningEffort.literal("medium"),
            &.{"work"},
        );
        try std.testing.expectEqual(StartResult.started, try owner.start(child_id, false));
    }

    try waitForEntries(&fake, child_count);
    try waitForNoLiveSlots(&owner);
    var completion_count: usize = 0;
    for (owner.completions) |completion| {
        if (completion != null) completion_count += 1;
    }
    try std.testing.expectEqual(@as(usize, completion_capacity), completion_count);
}

test "persistent wakes racing finished-slot reaping execute every queued turn" {
    const alloc = std.testing.allocator;
    const child_id = "wake-reap-child";
    const turn_count = 16;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, child_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/reaping",
        types.ReasoningEffort.literal("medium"),
        &.{"turn-0"},
    );
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();

    try std.testing.expectEqual(StartResult.started, try owner.start(child_id, false));
    try waitForEntries(&fake, 1);
    for (1..turn_count) |index| {
        const content = try std.fmt.allocPrint(alloc, "turn-{d}", .{index});
        defer alloc.free(content);
        const operation_id = try std.fmt.allocPrint(alloc, "wake-reap-{d}", .{index});
        defer alloc.free(operation_id);
        var send = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
            .id = child_id,
            .content = content,
        } } });
        defer send.deinit(alloc);
        var queued = try manager.execute(alloc, send, .{
            .actor_id = "parent",
            .operation_id = operation_id,
            .timestamp_ms = std.math.cast(i64, index + 2).?,
        });
        defer queued.deinit(alloc);
        try std.testing.expect(queued == .receipt);
        _ = try owner.start(child_id, false);
        try waitForEntries(&fake, index + 1);
    }
    try waitForNoLiveSlots(&owner);

    var loaded = try env.store.loadReadOnly(alloc, child_id);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, turn_count), loaded.history.len);
    try std.testing.expectEqualStrings(
        "turn-15",
        loaded.history[turn_count - 1].assistant.user.text,
    );
}

test "start wakes a reaper retry after a joined child restart failed" {
    const alloc = std.testing.allocator;
    const child_id = "restart-wake-child";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, child_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/restart-wake",
        types.ReasoningEffort.literal("medium"),
        &.{"work"},
    );
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();

    const slot = try alloc.create(Slot);
    var slot_transferred = false;
    defer if (!slot_transferred) alloc.destroy(slot);
    const owned_id = try alloc.dupe(u8, child_id);
    defer if (!slot_transferred) alloc.free(owned_id);
    slot.* = .{
        .owner = &owner,
        .child_id = owned_id,
        .retry_interrupted = false,
        .finished = true,
        .wake_requested = true,
        .restart_failed = true,
    };
    owner.mutex.lockUncancelable(io_mod.getIo());
    owner.slots.append(alloc, slot) catch |err| {
        owner.mutex.unlock(io_mod.getIo());
        return err;
    };
    slot_transferred = true;
    owner.ensureReaperLocked() catch |err| {
        owner.mutex.unlock(io_mod.getIo());
        return err;
    };
    owner.mutex.unlock(io_mod.getIo());

    try std.testing.expectEqual(
        StartResult.already_running,
        try owner.start(child_id, false),
    );
    try waitForEntries(&fake, 1);
    try waitForNoLiveSlots(&owner);
}

test "owner shutdown waits for a concurrent caller join without double joining" {
    const alloc = std.testing.allocator;
    const child_id = "shutdown-join-race";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, child_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/shutdown",
        types.ReasoningEffort.literal("medium"),
        &.{"work"},
    );
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    try std.testing.expectEqual(StartResult.started, try owner.start(child_id, false));
    try waitForEntries(&fake, 1);

    const JoinThread = struct {
        owner: *Owner,
        child_id: []const u8,
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            _ = self.owner.join(self.child_id) catch {
                self.failed.store(true, .seq_cst);
                return;
            };
        }
    };
    var join_context = JoinThread{ .owner = &owner, .child_id = child_id };
    const join_thread = try std.Thread.spawn(.{}, JoinThread.run, .{&join_context});
    const deadline = io_mod.milliTimestamp() + 5000;
    while (io_mod.milliTimestamp() < deadline) {
        owner.mutex.lockUncancelable(io_mod.getIo());
        const claimed = owner.findSlotLocked(child_id).?.finalizer == .caller;
        owner.mutex.unlock(io_mod.getIo());
        if (claimed) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    } else return error.TestUnexpectedResult;

    owner.deinit();
    join_thread.join();
    try std.testing.expect(!join_context.failed.load(.seq_cst));
}

fn expectOwnerStartAllocationFailure(fail_index: usize) !void {
    const durable_alloc = std.testing.allocator;
    const child_id = "allocation-reap-child";
    var env = try TestEnvironment.init(durable_alloc);
    defer env.deinit(durable_alloc);
    try env.createSession(durable_alloc, child_id);
    try env.installControl(
        durable_alloc,
        child_id,
        .one_off,
        "model/allocation",
        types.ReasoningEffort.literal("medium"),
        &.{"work"},
    );
    var fake = FakeExecution{ .alloc = durable_alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var failing_allocator = std.testing.FailingAllocator.init(durable_alloc, .{
        .fail_index = fail_index,
    });
    var owner = Owner{
        .alloc = failing_allocator.allocator(),
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    try std.testing.expectError(error.OutOfMemory, owner.start(child_id, false));
    owner.deinit();
    try std.testing.expectEqual(
        failing_allocator.allocated_bytes,
        failing_allocator.freed_bytes,
    );
}

test "owner start and reaping clean every failing-allocation path" {
    // Slot allocation, child-id ownership, and live-slot registration are the
    // three owner-shell allocations before a worker can observe the slot.
    for (0..3) |fail_index| try expectOwnerStartAllocationFailure(fail_index);
}

test "session-backed owner keeps child histories settings and FIFO isolated then parks" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "child-a");
    try env.createSession(alloc, "child-b");
    try env.createSession(alloc, "child-once");
    try env.installControl(alloc, "child-a", .persistent, "model/a", types.ReasoningEffort.literal("high"), &.{ "a1", "a2" });
    try env.installControl(alloc, "child-b", .persistent, "model/b", types.ReasoningEffort.literal("low"), &.{"b1"});
    try env.installControl(alloc, "child-once", .one_off, "model/once", types.ReasoningEffort.literal("medium"), &.{"once"});

    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("child-a", false));
    try std.testing.expectEqual(StartResult.already_running, try owner.start("child-a", false));
    try std.testing.expectEqual(StartResult.started, try owner.start("child-b", false));
    try std.testing.expectEqual(StartResult.started, try owner.start("child-once", false));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("child-a"));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("child-b"));
    try std.testing.expectEqual(ChildResult.completed, try owner.join("child-once"));
    try std.testing.expect(fake.worker_active_seen.load(.seq_cst));

    // A direct ordinary resume proves the child owner released session.lock.
    var child_a = try env.store.resumeForWrite(alloc, "child-a");
    defer child_a.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), child_a.state.history.len);
    try std.testing.expectEqualStrings("a1", child_a.state.history[0].assistant.user.text);
    try std.testing.expectEqualStrings("a2", child_a.state.history[1].assistant.user.text);
    try std.testing.expectEqualStrings(
        "a1",
        child_a.state.history[0].assistant.user.work_id.?,
    );
    try std.testing.expectEqualStrings(
        "a2",
        child_a.state.history[1].assistant.user.work_id.?,
    );
    try std.testing.expectEqualStrings("a2", child_a.state.last_subagent_work_id.?);
    try std.testing.expect(
        child_a.state.history[1].assistant.user.work_id.?.ptr !=
            child_a.state.last_subagent_work_id.?.ptr,
    );
    try std.testing.expect(std.mem.find(u8, child_a.state.history[0].assistant.assistant, "model=model/a") != null);
    try std.testing.expectEqualStrings(
        "a1",
        child_a.state.history[0].assistant.execution.tool_steps[0].tool_results[0].output,
    );
    child_a.log.park();

    var child_b = try env.store.resumeForWrite(alloc, "child-b");
    defer child_b.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), child_b.state.history.len);
    try std.testing.expectEqualStrings(
        "b1",
        child_b.state.history[0].assistant.user.work_id.?,
    );
    try std.testing.expect(std.mem.find(u8, child_b.state.history[0].assistant.assistant, "effort=low") != null);
    try std.testing.expectEqualStrings(
        "b1",
        child_b.state.history[0].assistant.execution.tool_steps[0].tool_results[0].output,
    );

    var once_record = try env.loadControl(alloc, "child-once");
    defer once_record.deinit(alloc);
    try std.testing.expectEqual(domain.State.completed, once_record.state);
    try std.testing.expectEqual(domain.QueueStatus.completed, once_record.queue[0].status);
}

test "different child turns overlap at a deterministic barrier" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "overlap-a");
    try env.createSession(alloc, "overlap-b");
    try env.installControl(alloc, "overlap-a", .persistent, "model/a", types.ReasoningEffort.literal("high"), &.{"a"});
    try env.installControl(alloc, "overlap-b", .persistent, "model/b", types.ReasoningEffort.literal("low"), &.{"b"});
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("overlap-a", false));
    try std.testing.expectEqual(StartResult.started, try owner.start("overlap-b", false));
    waitForEntries(&fake, 2) catch |err| {
        fake.release.store(true, .seq_cst);
        return err;
    };
    fake.release.store(true, .seq_cst);
    try std.testing.expectEqual(ChildResult.idle, try owner.join("overlap-a"));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("overlap-b"));
}

test "authority snapshots isolate siblings and refresh only at turn admission" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "authority-a");
    try env.createSession(alloc, "authority-b");
    try env.installControl(alloc, "authority-a", .persistent, "model/a", types.ReasoningEffort.literal("high"), &.{ "a-old", "a-new" });
    try env.installControl(alloc, "authority-b", .persistent, "model/b", types.ReasoningEffort.literal("low"), &.{"b-new"});
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer owner.deinit();

    try std.testing.expectEqual(StartResult.started, try owner.start("authority-a", false));
    try waitForEntries(&fake, 1);
    fake.authority_epoch.store(1, .seq_cst);
    try std.testing.expectEqual(StartResult.started, try owner.start("authority-b", false));
    try waitForEntries(&fake, 2);
    fake.release.store(true, .seq_cst);
    try std.testing.expectEqual(ChildResult.idle, try owner.join("authority-a"));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("authority-b"));
    try std.testing.expectEqual(@as(usize, 3), fake.observations.items.len);

    const first = findObservation(fake.observations.items, "authority-a", "a-old").?;
    const second = findObservation(fake.observations.items, "authority-a", "a-new").?;
    const sibling = findObservation(fake.observations.items, "authority-b", "b-new").?;
    try std.testing.expectEqualStrings("read_file", first.tool_name);
    try std.testing.expectEqualStrings("old.txt", first.rule_pattern);
    try std.testing.expectEqualStrings("/tmp/old.txt", first.grant_target);
    try std.testing.expectEqualStrings("mcp:old", first.integration_name);
    for ([_]Observation{ second, sibling }) |observation| {
        try std.testing.expectEqualStrings("write_file", observation.tool_name);
        try std.testing.expectEqualStrings("new.txt", observation.rule_pattern);
        try std.testing.expectEqualStrings("/tmp/new.txt", observation.grant_target);
        try std.testing.expectEqualStrings("mcp:new", observation.integration_name);
    }
    try std.testing.expectEqualStrings("read_file", first.tool_name);
}

test "durable active and queued cancellation wins a successful worker race" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "cancel-child");
    try env.installControl(alloc, "cancel-child", .persistent, "model/cancel", types.ReasoningEffort.literal("high"), &.{ "active", "queued" });
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("cancel-child", false));
    try waitForEntries(&fake, 1);
    try std.testing.expectEqual(@as(usize, 2), try owner.cancel("cancel-child", "user cancelled", 3));
    fake.release.store(true, .seq_cst);
    try std.testing.expectEqual(ChildResult.cancelled, try owner.join("cancel-child"));
    var record = try env.loadControl(alloc, "cancel-child");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.State.idle, record.state);
    for (record.queue) |message| {
        try std.testing.expectEqual(domain.QueueStatus.cancelled, message.status);
        try std.testing.expectEqualStrings("user cancelled", message.cancellation_reason.?);
    }
}

test "committed lifecycle cancellation signals live work without reopening control" {
    const alloc = std.testing.allocator;
    const child_id = "committed-cancel-child";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, child_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/committed-cancel",
        types.ReasoningEffort.literal("high"),
        &.{"active"},
    );
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();
    try std.testing.expectEqual(
        StartResult.started,
        try owner.start(child_id, false),
    );
    try waitForEntries(&fake, 1);

    var command = try domain.validateCommand(alloc, .{ .lifecycle = .{
        .id = child_id,
        .action = .cancel,
    } });
    defer command.deinit(alloc);
    var committed = try manager.execute(alloc, command, .{
        .actor_id = "parent",
        .operation_id = "committed-cancel",
        .timestamp_ms = 3,
    });
    defer committed.deinit(alloc);
    try std.testing.expectEqual(
        domain.OutcomeCode.lifecycle_changed,
        committed.receipt.code,
    );

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();

        try owner.completeCommittedCancellation(child_id, 3);
        owner.mutex.lockUncancelable(io_mod.getIo());
        const live_slot = owner.findSlotLocked(child_id);
        const signaled = if (live_slot) |slot|
            slot.cancel.load(.seq_cst)
        else
            false;
        owner.mutex.unlock(io_mod.getIo());
        try std.testing.expect(live_slot != null);
        try std.testing.expect(signaled);
    }

    fake.release.store(true, .seq_cst);
    try std.testing.expectEqual(
        ChildResult.cancelled,
        try owner.join(child_id),
    );
}

test "committed lifecycle cancellation releases a production permission waiter" {
    const alloc = std.testing.allocator;
    const child_id = "approval-cancel-child";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, child_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/approval-cancel",
        types.ReasoningEffort.literal("high"),
        &.{"approval-work"},
    );
    var execution = ApprovalBlockingExecution{};
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var authority = authority_mod.Resolver{
        .sessions = &env.store,
        .host = .{ .resolve_fn = ToolEffectAuthority.resolve },
    };
    var durable = approval_persistence.DurableRegistry{
        .alloc = alloc,
        .sessions = &env.store,
    };
    var registry = approval_registry_mod.Registry{
        .alloc = alloc,
        .persistence = durable.interface(),
    };
    defer registry.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = execution.services(),
        .live_authority = &authority,
        .approval_registry = &registry,
    };
    defer {
        execution.requestShutdown();
        owner.deinit();
    }

    try std.testing.expectEqual(
        StartResult.started,
        try owner.start(child_id, false),
    );
    const approval_id = try waitForPendingToolApproval(
        alloc,
        &env,
        child_id,
    );
    defer alloc.free(approval_id);
    try std.testing.expect(execution.entered.load(.seq_cst));

    try std.testing.expectEqual(
        @as(usize, 1),
        try owner.cancel(child_id, "user cancelled", 3),
    );
    const deadline = io_mod.milliTimestamp() + 5_000;
    while (!execution.permission_resolved.load(.seq_cst) and
        io_mod.milliTimestamp() < deadline)
    {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    const released_by_cancel = execution.permission_resolved.load(.seq_cst);
    if (!released_by_cancel) execution.requestShutdown();

    try std.testing.expectEqual(
        ChildResult.cancelled,
        try owner.join(child_id),
    );
    try std.testing.expect(released_by_cancel);
    try std.testing.expect(execution.denied.load(.seq_cst));
    var ledger = try env.loadCommunication(alloc, child_id);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.ApprovalStatus.cancelled,
        communication.findApproval(ledger.approvals, approval_id).?.status,
    );
    try std.testing.expectError(
        error.RequestNotFound,
        registry.resolve(
            approval_id,
            child_id,
            .once,
            null,
            4,
        ),
    );
}

test "owner shutdown releases a production permission waiter before joining" {
    const DeinitThread = struct {
        owner: *Owner,
        finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.owner.deinit();
            self.finished.store(true, .seq_cst);
        }
    };

    const alloc = std.testing.allocator;
    const child_id = "approval-shutdown-child";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, child_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/approval-shutdown",
        types.ReasoningEffort.literal("high"),
        &.{"approval-work"},
    );
    var execution = ApprovalBlockingExecution{};
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var authority = authority_mod.Resolver{
        .sessions = &env.store,
        .host = .{ .resolve_fn = ToolEffectAuthority.resolve },
    };
    var durable = approval_persistence.DurableRegistry{
        .alloc = alloc,
        .sessions = &env.store,
    };
    var registry = approval_registry_mod.Registry{
        .alloc = alloc,
        .persistence = durable.interface(),
    };
    defer registry.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = execution.services(),
        .live_authority = &authority,
        .approval_registry = &registry,
    };
    var owner_deinitialized = false;
    defer if (!owner_deinitialized) {
        execution.requestShutdown();
        owner.deinit();
    };

    try std.testing.expectEqual(
        StartResult.started,
        try owner.start(child_id, false),
    );
    const approval_id = try waitForPendingToolApproval(
        alloc,
        &env,
        child_id,
    );
    defer alloc.free(approval_id);

    var finished = std.atomic.Value(bool).init(false);
    var deinit_thread = DeinitThread{
        .owner = &owner,
        .finished = &finished,
    };
    const thread = try std.Thread.spawn(.{}, DeinitThread.run, .{&deinit_thread});
    var joined = false;
    defer if (!joined) {
        execution.requestShutdown();
        thread.join();
        owner_deinitialized = true;
    };
    const deadline = io_mod.milliTimestamp() + 5_000;
    while (!finished.load(.seq_cst) and io_mod.milliTimestamp() < deadline) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    const released_by_shutdown = finished.load(.seq_cst);
    if (!released_by_shutdown) execution.requestShutdown();
    thread.join();
    joined = true;
    owner_deinitialized = true;

    try std.testing.expect(released_by_shutdown);
    try std.testing.expect(execution.permission_resolved.load(.seq_cst));
    try std.testing.expect(execution.denied.load(.seq_cst));
    try std.testing.expectError(
        error.RequestNotFound,
        registry.resolve(
            approval_id,
            child_id,
            .once,
            null,
            4,
        ),
    );
    var pending = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer pending.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), pending.total);
    var late_worker = worker_runtime.WorkerRuntime{};
    defer late_worker.deinit(alloc);
    try std.testing.expectError(
        error.RegistryClosed,
        registry.registerTool(
            "late-shutdown-approval",
            child_id,
            "parent",
            "approval-work",
            .{ .id = 9, .label = "late action" },
            &.{},
            &late_worker,
            5,
        ),
    );
}

test "restart recovery interrupts without execution and explicit resume runs once" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "restart-child");
    try env.installControl(alloc, "restart-child", .persistent, "model/restart", types.ReasoningEffort.literal("medium"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer owner.deinit();
    const report = try owner.recover(4);
    try std.testing.expectEqual(@as(usize, 1), report.work_interrupted);
    try std.testing.expectEqual(@as(usize, 0), fake.entered.load(.seq_cst));
    var interrupted = try env.loadControl(alloc, "restart-child");
    try std.testing.expectEqual(domain.QueueStatus.interrupted, interrupted.queue[0].status);
    interrupted.deinit(alloc);
    try std.testing.expectEqual(StartResult.started, try owner.start("restart-child", true));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("restart-child"));
    try std.testing.expectEqual(@as(usize, 1), fake.entered.load(.seq_cst));
}

test "root recovery ignores ordinary chats and unrelated subagent trees" {
    const alloc = std.testing.allocator;
    const root_id = "recovery-root";
    const other_root_id = "other-recovery-root";
    const child_id = "recovery-child";
    const unrelated_id = "unrelated-recovery-child";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    for ([_][]const u8{
        root_id,
        other_root_id,
        child_id,
        unrelated_id,
        "ordinary-session",
    }) |session_id| try env.createSession(alloc, session_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/recovery",
        types.ReasoningEffort.literal("medium"),
        &.{"root-work"},
    );
    try env.installControl(
        alloc,
        unrelated_id,
        .persistent,
        "model/recovery",
        types.ReasoningEffort.literal("medium"),
        &.{"unrelated-work"},
    );

    const setParent = struct {
        fn apply(
            allocator: Allocator,
            store: *session_store.Store,
            target_id: []const u8,
            parent_id: []const u8,
        ) !void {
            var capability = try store.openSubagentControlCapabilityWritable(
                allocator,
                target_id,
                .{},
            );
            defer capability.deinit();
            const control = control_store.Store{
                .capability = &capability,
                .expected_child_id = target_id,
            };
            var lock = try control.acquireLock();
            defer lock.release();
            var record = try control.load(allocator);
            defer record.deinit(allocator);
            if (record.parent_id) |current| allocator.free(current);
            record.parent_id = try allocator.dupe(u8, parent_id);
            try control.save(allocator, record);
        }
    }.apply;
    try setParent(alloc, &env.store, child_id, root_id);
    try setParent(alloc, &env.store, unrelated_id, other_root_id);
    _ = try relationship_index.ensureChild(
        alloc,
        &env.store,
        root_id,
        child_id,
        .{},
    );
    _ = try relationship_index.ensureChild(
        alloc,
        &env.store,
        other_root_id,
        unrelated_id,
        .{},
    );

    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();

    const report = try owner.recoverTree(root_id, 4);
    try std.testing.expectEqual(@as(usize, 1), report.sessions_changed);
    try std.testing.expectEqual(@as(usize, 1), report.work_interrupted);
    try std.testing.expectEqual(@as(usize, 0), report.sessions_failed);

    var recovered = try env.loadControl(alloc, child_id);
    defer recovered.deinit(alloc);
    try std.testing.expectEqual(domain.State.interrupted, recovered.state);
    try std.testing.expectEqual(
        domain.QueueStatus.interrupted,
        recovered.queue[0].status,
    );

    var unrelated = try env.loadControl(alloc, unrelated_id);
    defer unrelated.deinit(alloc);
    try std.testing.expectEqual(domain.State.queued, unrelated.state);
    try std.testing.expectEqual(
        domain.QueueStatus.pending,
        unrelated.queue[0].status,
    );
    var ordinary = try env.store.loadReadOnly(alloc, "ordinary-session");
    defer ordinary.deinit(alloc);
    try std.testing.expectEqualStrings(env.workspace, ordinary.workspace_root);
}

test "restart recovery does not rebind ordinary sessions across workspaces" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "ordinary-session");
    try env.tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const workspace_b = try io_mod.dirRealpathAlloc(
        alloc,
        env.tmp.dir,
        "workspace-b",
    );
    defer alloc.free(workspace_b);
    var store_b = try session_store.Store.initFromHome(
        alloc,
        env.home,
        workspace_b,
    );
    defer store_b.deinit(alloc);
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &store_b };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &store_b,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();

    const report = try owner.recover(4);
    try std.testing.expectEqual(@as(usize, 0), report.sessions_changed);
    try std.testing.expectEqual(@as(usize, 0), report.sessions_failed);
    var ordinary = try env.store.loadReadOnly(alloc, "ordinary-session");
    defer ordinary.deinit(alloc);
    try std.testing.expectEqualStrings(env.workspace, ordinary.workspace_root);
}

test "restart recovery reconciles interrupted and cancelled approvals by work identity" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "approval-restart-child");
    try env.installControl(
        alloc,
        "approval-restart-child",
        .persistent,
        "model/restart",
        types.ReasoningEffort.literal("medium"),
        &.{ "approval-work", "cancelled-work" },
    );

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "approval-restart-child",
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = "approval-restart-child",
    };
    var control_lock = try control.acquireLock();
    {
        defer control_lock.release();
        var record = try control.load(alloc);
        defer record.deinit(alloc);
        try admitWork(alloc, &record, 0, 2);
        try std.testing.expectEqual(
            CompletionDecision.committed,
            try finishWork(alloc, &record, "approval-work", .awaiting_approval, 3),
        );
        record.queue[1].status = .cancelled;
        record.queue[1].cancellation_reason = try alloc.dupe(
            u8,
            "cancelled before restart",
        );
        try appendSingleTransition(
            alloc,
            &record,
            "cancelled-work",
            .pending,
            .cancelled,
            record.queue[1].cancellation_reason,
            3,
        );
        try control.save(alloc, record);

        var ledger = try communication.Ledger.init(alloc, "approval-restart-child");
        defer ledger.deinit(alloc);
        try std.testing.expectEqual(
            communication.RegisterApprovalResult.registered,
            try communication.registerApproval(alloc, &ledger, .{
                .id = "approval-restart",
                .kind = .tool,
                .child_id = "approval-restart-child",
                .root_id = "parent",
                .work_id = "approval-work",
                .prepared_fingerprint = [_]u8{4} ** 32,
                .label = "prepared child action",
                .explanation = null,
                .grants = &.{},
                .created_at_ms = 3,
            }),
        );
        try std.testing.expectEqual(
            communication.RegisterApprovalResult.registered,
            try communication.registerApproval(alloc, &ledger, .{
                .id = "approval-cancelled-before-restart",
                .kind = .tool,
                .child_id = "approval-restart-child",
                .root_id = "parent",
                .work_id = "cancelled-work",
                .prepared_fingerprint = [_]u8{5} ** 32,
                .label = "cancelled child action",
                .explanation = null,
                .grants = &.{},
                .created_at_ms = 3,
            }),
        );
        const communication_state = communication_store.Store{
            .capability = &capability,
            .expected_session_id = "approval-restart-child",
        };
        try communication_state.save(alloc, ledger);
    }

    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();
    const report = try owner.recover(4);
    try std.testing.expectEqual(@as(usize, 1), report.work_interrupted);
    try std.testing.expectEqual(@as(usize, 0), fake.entered.load(.seq_cst));
    var ledger = try env.loadCommunication(alloc, "approval-restart-child");
    defer ledger.deinit(alloc);
    const approval = communication.findApproval(
        ledger.approvals,
        "approval-restart",
    ).?;
    try std.testing.expectEqual(communication.ApprovalStatus.stale, approval.status);
    try std.testing.expectEqual(
        communication.ApprovalStatus.cancelled,
        communication.findApproval(
            ledger.approvals,
            "approval-cancelled-before-restart",
        ).?.status,
    );
}

test "restart recovery finishes cancelled approval cleanup without model replay" {
    const alloc = std.testing.allocator;
    const child_id = "approval-cancel-restart-child";
    const approval_id = "approval-cancel-restart";
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, child_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/restart",
        types.ReasoningEffort.literal("medium"),
        &.{"approval-work"},
    );

    var capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var control_lock = try control.acquireLock();
    {
        defer control_lock.release();
        var record = try control.load(alloc);
        defer record.deinit(alloc);
        try admitWork(alloc, &record, 0, 2);
        try std.testing.expectEqual(
            @as(usize, 1),
            try cancelWork(alloc, &record, "cancelled before cleanup", 3),
        );
        try control.save(alloc, record);

        var ledger = try communication.Ledger.init(alloc, child_id);
        defer ledger.deinit(alloc);
        try std.testing.expectEqual(
            communication.RegisterApprovalResult.registered,
            try communication.registerApproval(alloc, &ledger, .{
                .id = approval_id,
                .kind = .tool,
                .child_id = child_id,
                .root_id = "parent",
                .work_id = "approval-work",
                .prepared_fingerprint = [_]u8{5} ** 32,
                .label = "prepared child action",
                .explanation = null,
                .grants = &.{},
                .created_at_ms = 2,
            }),
        );
        const communication_state = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        try communication_state.save(alloc, ledger);
    }

    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();
    const report = try owner.recover(4);
    try std.testing.expectEqual(@as(usize, 0), report.work_interrupted);
    try std.testing.expectEqual(@as(usize, 0), fake.entered.load(.seq_cst));
    var ledger = try env.loadCommunication(alloc, child_id);
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.ApprovalStatus.cancelled,
        communication.findApproval(ledger.approvals, approval_id).?.status,
    );

    var durable = approval_persistence.DurableRegistry{
        .alloc = alloc,
        .sessions = &env.store,
    };
    const persistence = durable.interface();
    try persistence.invalidate_fn(
        persistence.context,
        approval_id,
        child_id,
        .cancelled,
        5,
    );
}

test "canonical approval wait refreshes revoked authority and races reject relationship changes" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "parent-next");
    try env.createSession(alloc, "approval-child");
    try env.installControl(
        alloc,
        "approval-child",
        .persistent,
        "model/approval",
        types.ReasoningEffort.literal("medium"),
        &.{"approval-work"},
    );

    var setup_capability = try env.store.openSubagentControlCapabilityWritable(
        alloc,
        "approval-child",
        .{},
    );
    defer setup_capability.deinit();
    const setup_store = control_store.Store{
        .capability = &setup_capability,
        .expected_child_id = "approval-child",
    };
    var setup_lock = try setup_store.acquireLock();
    {
        defer setup_lock.release();
        var record = try setup_store.load(alloc);
        defer record.deinit(alloc);
        try admitWork(alloc, &record, 0, 2);
        try setup_store.save(alloc, record);
    }

    const FakeHost = struct {
        revoked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn resolve(
            raw: ?*anyopaque,
            output_alloc: Allocator,
            _: []const u8,
        ) !authority_mod.HostAuthority {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const revoked = self.revoked.load(.seq_cst);
            const tools = try output_alloc.alloc([]u8, if (revoked) 0 else 1);
            errdefer output_alloc.free(tools);
            if (!revoked) {
                tools[0] = try output_alloc.dupe(u8, "run_command");
                errdefer output_alloc.free(tools[0]);
            }
            const integrations = try output_alloc.alloc([]u8, 0);
            errdefer output_alloc.free(integrations);
            const rules = try output_alloc.alloc(types.PermissionRule, 0);
            errdefer output_alloc.free(rules);
            const grants = try output_alloc.alloc(types.PermissionGrant, 0);
            errdefer output_alloc.free(grants);
            return .{
                .generation = if (revoked) 2 else 1,
                .tools = tools,
                .integrations = integrations,
                .rules = .{ .rules = rules },
                .grants = grants,
            };
        }
    };
    var fake_host = FakeHost{};
    var authority = authority_mod.Resolver{
        .sessions = &env.store,
        .host = .{ .context = &fake_host, .resolve_fn = FakeHost.resolve },
    };
    var durable = approval_persistence.DurableRegistry{
        .alloc = alloc,
        .sessions = &env.store,
    };
    var registry = approval_registry_mod.Registry{
        .alloc = alloc,
        .persistence = durable.interface(),
    };
    defer registry.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var loaded = try env.store.resumeForWrite(alloc, "approval-child");
    defer {
        loaded.log.park();
        loaded.deinit(alloc);
    }
    var turn = try TurnContext.init(alloc, &loaded, 8);
    defer turn.deinit();
    turn.live_authority = &authority;
    turn.approval_registry = &registry;
    turn.child_id = "approval-child";
    turn.active_work_id = "approval-work";
    turn.worker.worker_processing = true;
    var initial_authority = try turn.resolveLiveAuthority(alloc);
    const initial_authority_generation = initial_authority.generation;
    initial_authority.deinit(alloc);
    var background: background_runtime.BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("*"),
        .action = .ask,
    }};
    const AdmissionThread = struct {
        input: tooling_tool_admission.Input,
        start: *std.atomic.Value(bool),
        ready: *std.atomic.Value(usize),
        decision: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) std.atomic.spinLoopHint();
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const outcome = tooling_tool_admission.requestPermissionOutcome(
                self.input,
                arena_state.allocator(),
                .{
                    .id = "canonical-call",
                    .name = "terminal",
                    .arguments_json = "{\"action\":\"exec\",\"command\":\"git status\"}",
                },
                .auto,
                &.{},
            ) catch {
                self.decision.store(3, .seq_cst);
                return;
            };
            self.decision.store(if (outcome.decision == .once) 1 else 2, .seq_cst);
        }
    };
    const RelationshipThread = struct {
        manager: *manager_mod.Manager,
        command: domain.Command,
        context: manager_mod.Context,
        start: *std.atomic.Value(bool),
        ready: *std.atomic.Value(usize),
        rejected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) std.atomic.spinLoopHint();
            var result = self.manager.execute(
                std.testing.allocator,
                self.command,
                self.context,
            ) catch return;
            defer result.deinit(std.testing.allocator);
            self.rejected.store(switch (result) {
                .failure => |failure| failure.code == .invalid_state,
                else => false,
            }, .seq_cst);
        }
    };
    var registration_start = std.atomic.Value(bool).init(false);
    var registration_ready = std.atomic.Value(usize).init(0);
    var admission = AdmissionThread{ .input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{ .rules = &rules },
        .tool_registry = .{ .tools = &.{test_builtin_tools.terminal} },
        .worker = &turn.worker,
        .permission_prompter = turn.permissionPrompter(),
        .background = &background,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
    }, .start = &registration_start, .ready = &registration_ready };
    var detach_command = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = "approval-child",
    } });
    defer detach_command.deinit(alloc);
    var detach = RelationshipThread{
        .manager = &manager,
        .command = detach_command,
        .context = .{
            .actor_id = "parent",
            .operation_id = "detach-registration-race",
            .timestamp_ms = 4,
        },
        .start = &registration_start,
        .ready = &registration_ready,
    };
    const admission_thread = try std.Thread.spawn(.{}, AdmissionThread.run, .{&admission});
    var admission_joined = false;
    defer if (!admission_joined) {
        registration_start.store(true, .seq_cst);
        turn.worker.requestCancel();
        admission_thread.join();
    };
    const detach_thread = try std.Thread.spawn(.{}, RelationshipThread.run, .{&detach});
    var detach_joined = false;
    defer if (!detach_joined) {
        registration_start.store(true, .seq_cst);
        detach_thread.join();
    };
    while (registration_ready.load(.seq_cst) != 2) std.atomic.spinLoopHint();
    registration_start.store(true, .seq_cst);
    var approval_id: ?[]u8 = null;
    defer if (approval_id) |id| alloc.free(id);
    for (0..1_000) |_| {
        const maybe_ledger = env.loadCommunication(alloc, "approval-child") catch null;
        if (maybe_ledger) |loaded_ledger| {
            var ledger = loaded_ledger;
            defer ledger.deinit(alloc);
            for (ledger.approvals) |pending| {
                if (pending.status == .pending) {
                    approval_id = try alloc.dupe(u8, pending.id);
                    break;
                }
            }
        }
        if (approval_id != null) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    const stable_approval_id = approval_id orelse return error.TestApprovalNotRegistered;
    detach_thread.join();
    detach_joined = true;
    try std.testing.expect(detach.rejected.load(.seq_cst));
    var waiting = try env.loadControl(alloc, "approval-child");
    try std.testing.expectEqual(domain.State.awaiting_approval, waiting.state);
    try std.testing.expectEqual(
        domain.QueueStatus.awaiting_approval,
        waiting.queue[0].status,
    );
    waiting.deinit(alloc);

    const ResponseThread = struct {
        registry: *approval_registry_mod.Registry,
        request_id: []const u8,
        start: *std.atomic.Value(bool),
        ready: *std.atomic.Value(usize),
        accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) std.atomic.spinLoopHint();
            const result = self.registry.resolve(
                self.request_id,
                "approval-child",
                .once,
                null,
                5,
            ) catch return;
            self.accepted.store(result == .accepted, .seq_cst);
        }
    };
    var reparent_command = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .reparent,
        .id = "approval-child",
        .parent_id = "parent-next",
    } });
    defer reparent_command.deinit(alloc);
    var response_start = std.atomic.Value(bool).init(false);
    var response_ready = std.atomic.Value(usize).init(0);
    var response = ResponseThread{
        .registry = &registry,
        .request_id = stable_approval_id,
        .start = &response_start,
        .ready = &response_ready,
    };
    var reparent = RelationshipThread{
        .manager = &manager,
        .command = reparent_command,
        .context = .{
            .actor_id = "parent",
            .operation_id = "reparent-response-race",
            .relationship_authorization = .direct,
            .timestamp_ms = 5,
        },
        .start = &response_start,
        .ready = &response_ready,
    };
    const response_thread = try std.Thread.spawn(.{}, ResponseThread.run, .{&response});
    var response_joined = false;
    defer if (!response_joined) {
        response_start.store(true, .seq_cst);
        response_thread.join();
    };
    const reparent_thread = try std.Thread.spawn(.{}, RelationshipThread.run, .{&reparent});
    var reparent_joined = false;
    defer if (!reparent_joined) {
        response_start.store(true, .seq_cst);
        reparent_thread.join();
    };
    while (response_ready.load(.seq_cst) != 2) std.atomic.spinLoopHint();
    fake_host.revoked.store(true, .seq_cst);
    response_start.store(true, .seq_cst);
    response_thread.join();
    response_joined = true;
    reparent_thread.join();
    reparent_joined = true;
    try std.testing.expect(response.accepted.load(.seq_cst));
    try std.testing.expect(reparent.rejected.load(.seq_cst));
    admission_thread.join();
    admission_joined = true;
    try std.testing.expectEqual(@as(u8, 1), admission.decision.load(.seq_cst));
    var refreshed_arena = std.heap.ArenaAllocator.init(alloc);
    defer refreshed_arena.deinit();
    const refreshed = try turn.liveToolAuthorityProvider().resolve(
        refreshed_arena.allocator(),
        .{
            .id = "canonical-call",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"git status\"}",
        },
        "/tmp/workspace",
        "/tmp/workspace",
        .none,
    );
    try std.testing.expectEqual(runtime_deps.LiveToolAuthorityDecision.unavailable, refreshed.decision);
    try std.testing.expect(refreshed.authority.generation != initial_authority_generation);
    try std.testing.expectEqual(@as(usize, 0), refreshed.authority.tools.len);
    var resumed = try env.loadControl(alloc, "approval-child");
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(domain.State.running, resumed.state);
    try std.testing.expectEqual(domain.QueueStatus.running, resumed.queue[0].status);
    try std.testing.expect(turn.worker.pending_permission_response == null);
    var resolved_ledger = try env.loadCommunication(alloc, "approval-child");
    defer resolved_ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.ApprovalStatus.allowed_once,
        communication.findApproval(resolved_ledger.approvals, stable_approval_id).?.status,
    );
    try std.testing.expectError(
        error.RequestNotFound,
        registry.resolve(
            stable_approval_id,
            "approval-child",
            .once,
            null,
            6,
        ),
    );
}

const FailNthControlSync = struct {
    fail_at: usize,
    calls: usize = 0,

    fn syncFile(raw: ?*anyopaque, file: std.Io.File) anyerror!void {
        const self: *FailNthControlSync = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.InjectedControlFileSyncFailure;
        try file.sync(io_mod.getIo());
    }

    fn syncDir(raw: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
        const self: *FailNthControlSync = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.InjectedControlDirectorySyncFailure;
        try io_mod.syncVerifiedDir(dir);
    }
};

const FailCommunicationFrom = struct {
    fail_from: usize,
    calls: usize = 0,

    fn syncFile(raw: ?*anyopaque, file: std.Io.File) anyerror!void {
        const self: *FailCommunicationFrom = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls >= self.fail_from) return error.InjectedCommunicationFileSyncFailure;
        try file.sync(io_mod.getIo());
    }

    fn syncDir(raw: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
        const self: *FailCommunicationFrom = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls >= self.fail_from) return error.InjectedCommunicationDirectorySyncFailure;
        try io_mod.syncVerifiedDir(dir);
    }
};

const ToolEffectExecution = struct {
    dir: std.Io.Dir,
    effects: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn services(self: *ToolEffectExecution) Services {
        return .{ .context = self, .capture_fn = capture, .run_fn = run };
    }

    fn capture(
        _: ?*anyopaque,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        return domain.captureAdmission(alloc, .{
            .parent_id = request.parent_id,
            .source_id = request.source_id,
            .model = request.preferences.model,
            .effort = request.preferences.effort,
            .tool_names = &.{"create_folder"},
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.AdmissionFailed,
        };
    }

    fn run(
        raw: ?*anyopaque,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        _: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        const self: *ToolEffectExecution = @ptrCast(@alignCast(raw.?));
        const recorder = turn.toolActivityRecorder();
        recorder.record("effect-call", "create_folder", .started) catch
            return error.ProviderFailed;
        self.dir.createDirPath(io_mod.getIo(), "effect") catch
            return error.ProviderFailed;
        _ = self.effects.fetchAdd(1, .seq_cst);
        recorder.record("effect-call", "create_folder", .succeeded) catch {};

        var history_turn = session.makeAssistantTurn(
            turn.alloc,
            message.content,
            "effect completed",
        ) catch return error.OutOfMemory;
        defer session.freeHistoryTurn(turn.alloc, history_turn);
        const calls = [_]types.ToolCall{.{
            .id = "effect-call",
            .name = "create_folder",
            .arguments_json = "{\"path\":\"effect\"}",
        }};
        const results = [_]types.PersistedToolResult{.{
            .tool_call_id = @constCast("effect-call"),
            .tool_name = @constCast("create_folder"),
            .status = .success,
            .output = @constCast("created"),
            .output_bytes = 7,
            .stored_output_bytes = 7,
            .created_at_ms = 3,
        }};
        const steps = [_]types.ToolExecutionStep{.{
            .tool_calls = @constCast(&calls),
            .tool_results = @constCast(&results),
        }};
        history_turn.assistant.execution = types.dupeExecutionMemory(
            turn.alloc,
            .{ .tool_steps = @constCast(&steps) },
        ) catch return error.OutOfMemory;
        turn.commit(message.id, history_turn, 1, 1, 3) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProviderFailed,
        };
        return .completed;
    }
};

const ToolEffectAuthority = struct {
    fn resolve(
        _: ?*anyopaque,
        alloc: Allocator,
        _: []const u8,
    ) !authority_mod.HostAuthority {
        const tools = try cloneTestStrings(alloc, &.{"create_folder"});
        errdefer freeTestStrings(alloc, tools);
        const integrations = try alloc.alloc([]u8, 0);
        errdefer alloc.free(integrations);
        const rules = try alloc.alloc(types.PermissionRule, 0);
        errdefer alloc.free(rules);
        const grants = try alloc.alloc(types.PermissionGrant, 0);
        errdefer alloc.free(grants);
        return .{
            .generation = 1,
            .tools = tools,
            .integrations = integrations,
            .rules = .{ .rules = rules },
            .grants = grants,
        };
    }
};

fn runToolActivityProjectionFailure(indeterminate: bool) !void {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    const child_id = if (indeterminate) "activity-indeterminate" else "activity-definite";
    try env.createSession(alloc, child_id);
    try env.installControl(
        alloc,
        child_id,
        .persistent,
        "model/activity",
        types.ReasoningEffort.literal("high"),
        &.{"work"},
    );
    var effect_tmp = std.testing.tmpDir(.{});
    defer effect_tmp.cleanup();
    var execution = ToolEffectExecution{ .dir = effect_tmp.dir };
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var authority = authority_mod.Resolver{
        .sessions = &env.store,
        .host = .{ .resolve_fn = ToolEffectAuthority.resolve },
    };
    var failure = FailCommunicationFrom{ .fail_from = 3 };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = execution.services(),
        .live_authority = &authority,
        .communication_store_options = .{ .replace_ops = if (indeterminate) .{
            .ctx = &failure,
            .sync_dir = FailCommunicationFrom.syncDir,
        } else .{
            .ctx = &failure,
            .sync_file = FailCommunicationFrom.syncFile,
        } },
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start(child_id, false));
    try std.testing.expectEqual(ChildResult.control_failed, try owner.join(child_id));
    try std.testing.expectEqual(@as(usize, 1), execution.effects.load(.seq_cst));
    _ = try effect_tmp.dir.statFile(io_mod.getIo(), "effect", .{});

    var durable = try env.store.loadReadOnly(alloc, child_id);
    defer durable.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), durable.history.len);
    const stored_result = durable.history[0].assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(types.PersistedToolStatus.success, stored_result.status);
    try std.testing.expectEqualStrings("created", stored_result.output);

    owner.communication_store_options = .{};
    _ = try owner.recover(10);
    _ = try owner.recover(11);
    try std.testing.expectEqual(StartResult.started, try owner.start(child_id, false));
    try std.testing.expectEqual(ChildResult.no_work, try owner.join(child_id));
    try std.testing.expectEqual(@as(usize, 1), execution.effects.load(.seq_cst));
    var ledger = try env.loadCommunication(alloc, child_id);
    defer ledger.deinit(alloc);
    var final_count: usize = 0;
    for (ledger.deliveries) |delivery| switch (delivery.payload) {
        .tool_activity => |activity| if (activity.phase == .succeeded) {
            final_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), final_count);
}

test "definite final activity save failure preserves result and repairs exactly once" {
    try runToolActivityProjectionFailure(false);
}

test "indeterminate final activity save preserves result and repairs without duplicate" {
    try runToolActivityProjectionFailure(true);
}

test "restart before history commit interrupts without replay" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "crash-before-history");
    try env.installControl(alloc, "crash-before-history", .persistent, "model/crash", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var first = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    try std.testing.expectEqual(StartResult.started, try first.start("crash-before-history", false));
    try waitForEntries(&fake, 1);
    first.deinit();

    var recovery = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer recovery.deinit();
    const report = try recovery.recover(5);
    try std.testing.expectEqual(@as(usize, 1), report.work_interrupted);
    try std.testing.expectEqual(@as(usize, 0), report.work_completed);
    try std.testing.expectEqual(@as(usize, 1), fake.entered.load(.seq_cst));
    var record = try env.loadControl(alloc, "crash-before-history");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.interrupted, record.queue[0].status);
}

test "history commit followed by failed control save recovers completion without replay" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "crash-after-history");
    try env.installControl(alloc, "crash-after-history", .persistent, "model/crash", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var failure = FailNthControlSync{ .fail_at = 2 };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
        .child_store_options = .{ .replace_ops = .{
            .ctx = &failure,
            .sync_file = FailNthControlSync.syncFile,
        } },
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("crash-after-history", false));
    try std.testing.expectEqual(ChildResult.control_failed, try owner.join("crash-after-history"));
    var durable = try env.store.loadReadOnly(alloc, "crash-after-history");
    defer durable.deinit(alloc);
    try std.testing.expectEqualStrings("work", durable.last_subagent_work_id.?);

    owner.child_store_options = .{};
    const report = try owner.recover(6);
    try std.testing.expectEqual(@as(usize, 1), report.work_completed);
    try std.testing.expectEqual(@as(usize, 0), report.work_interrupted);
    try std.testing.expectEqual(@as(usize, 1), fake.entered.load(.seq_cst));
    var record = try env.loadControl(alloc, "crash-after-history");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.completed, record.queue[0].status);
}

test "indeterminate completion save reconciles without replay" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "indeterminate-completion");
    try env.installControl(alloc, "indeterminate-completion", .persistent, "model/crash", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var failure = FailNthControlSync{ .fail_at = 2 };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
        .child_store_options = .{ .replace_ops = .{
            .ctx = &failure,
            .sync_dir = FailNthControlSync.syncDir,
        } },
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("indeterminate-completion", false));
    try std.testing.expectEqual(ChildResult.control_failed, try owner.join("indeterminate-completion"));
    owner.child_store_options = .{};
    const report = try owner.recover(7);
    try std.testing.expectEqual(@as(usize, 0), report.work_completed);
    try std.testing.expectEqual(@as(usize, 0), report.work_interrupted);
    try std.testing.expectEqual(@as(usize, 1), fake.entered.load(.seq_cst));
    var record = try env.loadControl(alloc, "indeterminate-completion");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.completed, record.queue[0].status);
}

test "definite terminal projection failure repairs on restart exactly once" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "terminal-definite");
    try env.installControl(alloc, "terminal-definite", .persistent, "model/crash", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var failure = FailNthControlSync{ .fail_at = 2 };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
        .communication_store_options = .{ .replace_ops = .{
            .ctx = &failure,
            .sync_file = FailNthControlSync.syncFile,
        } },
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("terminal-definite", false));
    try std.testing.expectEqual(ChildResult.control_failed, try owner.join("terminal-definite"));
    var before = try env.loadCommunication(alloc, "terminal-definite");
    defer before.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), before.deliveries.len);

    owner.communication_store_options = .{};
    const first_recovery = try owner.recover(8);
    try std.testing.expectEqual(@as(usize, 0), first_recovery.work_completed);
    var repaired = try env.loadCommunication(alloc, "terminal-definite");
    defer repaired.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), repaired.deliveries.len);
    try std.testing.expectEqual(domain.State.completed, repaired.deliveries[0].payload.terminal);
    _ = try owner.recover(9);
    var replayed = try env.loadCommunication(alloc, "terminal-definite");
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.deliveries.len);
    try std.testing.expectEqual(@as(usize, 1), fake.entered.load(.seq_cst));
}

test "indeterminate terminal projection restart repair does not duplicate" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "terminal-indeterminate");
    try env.installControl(alloc, "terminal-indeterminate", .persistent, "model/crash", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var failure = FailNthControlSync{ .fail_at = 2 };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
        .communication_store_options = .{ .replace_ops = .{
            .ctx = &failure,
            .sync_dir = FailNthControlSync.syncDir,
        } },
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("terminal-indeterminate", false));
    try std.testing.expectEqual(ChildResult.control_failed, try owner.join("terminal-indeterminate"));
    var committed = try env.loadCommunication(alloc, "terminal-indeterminate");
    defer committed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), committed.deliveries.len);

    owner.communication_store_options = .{};
    _ = try owner.recover(10);
    _ = try owner.recover(11);
    var replayed = try env.loadCommunication(alloc, "terminal-indeterminate");
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.deliveries.len);
    try std.testing.expectEqual(@as(usize, 1), fake.entered.load(.seq_cst));
}

test "cancel signals execution and later retry repairs failed terminal projection" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "terminal-cancel");
    try env.installControl(alloc, "terminal-cancel", .persistent, "model/cancel", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("terminal-cancel", false));
    try waitForEntries(&fake, 1);
    var failure = FailNthControlSync{ .fail_at = 1 };
    owner.communication_store_options = .{ .replace_ops = .{
        .ctx = &failure,
        .sync_file = FailNthControlSync.syncFile,
    } };
    try std.testing.expectEqual(@as(usize, 1), try owner.cancel("terminal-cancel", "stop", 12));
    try std.testing.expectEqual(ChildResult.cancelled, try owner.join("terminal-cancel"));
    var before = try env.loadCommunication(alloc, "terminal-cancel");
    defer before.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), before.deliveries.len);

    owner.communication_store_options = .{};
    try std.testing.expectEqual(@as(usize, 0), try owner.cancel("terminal-cancel", "stop", 13));
    try std.testing.expectEqual(@as(usize, 0), try owner.cancel("terminal-cancel", "stop", 14));
    var repaired = try env.loadCommunication(alloc, "terminal-cancel");
    defer repaired.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), repaired.deliveries.len);
    try std.testing.expectEqual(domain.State.cancelled, repaired.deliveries[0].payload.terminal);
}

test "provider and admission failures release resources and persist typed work state" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "provider-child");
    try env.installControl(alloc, "provider-child", .persistent, "model/provider", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc, .run_fails = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("provider-child", false));
    try std.testing.expectEqual(ChildResult.failed, try owner.join("provider-child"));
    var record = try env.loadControl(alloc, "provider-child");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.failed, record.queue[0].status);
    try std.testing.expectEqual(domain.State.idle, record.state);
    var notifications = try env.loadCommunication(alloc, "provider-child");
    defer notifications.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), notifications.deliveries.len);
    try std.testing.expectEqual(
        domain.State.failed,
        notifications.deliveries[0].payload.terminal,
    );
    var resumed = try env.store.resumeForWrite(alloc, "provider-child");
    resumed.deinit(alloc);

    try env.createSession(alloc, "admission-child");
    try env.installControl(alloc, "admission-child", .persistent, "model/admission", types.ReasoningEffort.literal("low"), &.{"work"});
    fake.capture_fails = true;
    fake.run_fails = false;
    try std.testing.expectEqual(StartResult.started, try owner.start("admission-child", false));
    try std.testing.expectEqual(ChildResult.admission_failed, try owner.join("admission-child"));
    var admission_record = try env.loadControl(alloc, "admission-child");
    defer admission_record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.failed, admission_record.queue[0].status);
}

test "process-held session lock preserves queue until explicit exactly-once retry" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "locked-child");
    try env.installControl(alloc, "locked-child", .persistent, "model/locked", types.ReasoningEffort.literal("high"), &.{});
    const lock_path = try std.fs.path.join(
        alloc,
        &.{ env.store.sessions_dir, "locked-child", "session.lock" },
    );
    defer alloc.free(lock_path);
    const locker_script =
        \\import fcntl, os, sys
        \\lock_file = open(sys.argv[1], "a+b")
        \\fcntl.flock(lock_file, fcntl.LOCK_EX)
        \\os.write(1, b"R")
        \\os.read(0, 1)
    ;
    const argv = [_][]const u8{
        "/usr/bin/env",
        "python3",
        "-c",
        locker_script,
        lock_path,
    };
    var locker = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var locker_reaped = false;
    defer if (!locker_reaped) {
        if (locker.stdin) |stdin_file| stdin_file.writeStreamingAll(
            io_mod.getIo(),
            "X",
        ) catch {};
        _ = locker.wait(io_mod.getIo()) catch {};
    };
    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try std.posix.read(locker.stdout.?.handle, &ready),
    );
    try std.testing.expectEqual(@as(u8, 'R'), ready[0]);

    var manager = manager_mod.Manager{ .sessions = &env.store };
    var send = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = "locked-child",
        .content = "queued while externally owned",
    } } });
    defer send.deinit(alloc);
    var admitted = try manager.execute(alloc, send, .{
        .actor_id = "parent",
        .operation_id = "locked-send",
        .timestamp_ms = 2,
    });
    defer admitted.deinit(alloc);

    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
        .session_resume_options = .{ .log = .{ .session_lock_deadline_ms = 0 } },
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("locked-child", false));
    try std.testing.expectEqual(ChildResult.external_busy, try owner.join("locked-child"));
    var queued = try env.loadControl(alloc, "locked-child");
    try std.testing.expectEqual(domain.QueueStatus.pending, queued.queue[0].status);
    queued.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), fake.entered.load(.seq_cst));

    try locker.stdin.?.writeStreamingAll(io_mod.getIo(), "X");
    _ = try locker.wait(io_mod.getIo());
    locker_reaped = true;
    try std.testing.expectEqual(StartResult.started, try owner.start("locked-child", false));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("locked-child"));
    try std.testing.expectEqual(@as(usize, 1), fake.entered.load(.seq_cst));
    var completed = try env.loadControl(alloc, "locked-child");
    defer completed.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.completed, completed.queue[0].status);
}

const ProcessBoundaryExecution = struct {
    ready_fd: std.c.fd_t,
    release_fd: std.c.fd_t,

    fn services(self: *ProcessBoundaryExecution) Services {
        return .{ .context = self, .capture_fn = capture, .run_fn = run };
    }

    fn capture(
        _: ?*anyopaque,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        return domain.captureAdmission(alloc, .{
            .parent_id = request.parent_id,
            .source_id = request.source_id,
            .model = request.preferences.model,
            .effort = request.preferences.effort,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.AdmissionFailed,
        };
    }

    fn run(
        raw: ?*anyopaque,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        _: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        const self: *ProcessBoundaryExecution = @ptrCast(@alignCast(raw.?));
        writeExecutionProcessPipe(self.ready_fd, &.{1}) catch return error.ProviderFailed;
        var release: [1]u8 = undefined;
        readExecutionProcessPipe(self.release_fd, &release) catch return error.ProviderFailed;
        const history_turn = session.makeAssistantTurn(
            turn.alloc,
            message.content,
            "completed by external execution owner",
        ) catch return error.OutOfMemory;
        defer session.freeHistoryTurn(turn.alloc, history_turn);
        turn.commit(message.id, history_turn, 1, 1, 2) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProviderFailed,
        };
        return .completed;
    }
};

fn writeExecutionProcessPipe(fd: std.c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        switch (std.c.errno(count)) {
            .SUCCESS => offset += @intCast(count),
            .INTR => continue,
            else => return error.ProcessPipeFailed,
        }
    }
}

fn readExecutionProcessPipe(fd: std.c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.read(fd, bytes.ptr + offset, bytes.len - offset);
        switch (std.c.errno(count)) {
            .SUCCESS => {
                if (count == 0) return error.ProcessPipeFailed;
                offset += @intCast(count);
            },
            .INTR => continue,
            else => return error.ProcessPipeFailed,
        }
    }
}

fn closeExecutionProcessFd(fd: std.c.fd_t) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(io_mod.getIo());
}

fn runExternalExecutionProcess(
    home: []const u8,
    workspace: []const u8,
    ready_fd: std.c.fd_t,
    release_fd: std.c.fd_t,
) u8 {
    const alloc = std.heap.c_allocator;
    var store = session_store.Store.initFromHome(alloc, home, workspace) catch return 90;
    defer store.deinit(alloc);
    var manager = manager_mod.Manager{ .sessions = &store };
    var process_execution = ProcessBoundaryExecution{
        .ready_fd = ready_fd,
        .release_fd = release_fd,
    };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &store,
        .manager = &manager,
        .services = process_execution.services(),
    };
    var slot = Slot{
        .owner = &owner,
        .child_id = @constCast("live-child"),
        .retry_interrupted = false,
    };
    return if (runOne(&slot) == .idle) 0 else 91;
}

fn waitExternalExecutionProcess(pid: std.c.pid_t) !u8 {
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(pid, &status, 0);
        switch (std.c.errno(waited)) {
            .SUCCESS => {
                if (waited != pid or (status & 0x7f) != 0) return error.ProcessWaitFailed;
                return @intCast((status >> 8) & 0xff);
            },
            .INTR => continue,
            else => return error.ProcessWaitFailed,
        }
    }
}

test "recovery skips execution owned by another live process" {
    if (comptime !@hasDecl(std.c, "fork")) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "live-child");
    try env.installControl(alloc, "live-child", .persistent, "model/live", types.ReasoningEffort.literal("high"), &.{"work"});
    var ready_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&ready_pipe) != 0) return error.ProcessPipeFailed;
    defer closeExecutionProcessFd(ready_pipe[0]);
    defer closeExecutionProcessFd(ready_pipe[1]);
    var release_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&release_pipe) != 0) return error.ProcessPipeFailed;
    defer closeExecutionProcessFd(release_pipe[0]);
    defer closeExecutionProcessFd(release_pipe[1]);
    const pid = std.c.fork();
    if (pid < 0) return error.ProcessForkFailed;
    if (pid == 0) std.c._exit(runExternalExecutionProcess(
        env.home,
        env.workspace,
        ready_pipe[1],
        release_pipe[0],
    ));
    var reaped = false;
    defer if (!reaped) {
        writeExecutionProcessPipe(release_pipe[1], &.{1}) catch {};
        _ = waitExternalExecutionProcess(pid) catch {};
    };
    var ready: [1]u8 = undefined;
    try readExecutionProcessPipe(ready_pipe[0], &ready);

    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var recovery = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
        .session_resume_options = .{ .log = .{ .session_lock_deadline_ms = 0 } },
    };
    defer recovery.deinit();
    const report = try recovery.recover(8);
    try std.testing.expectEqual(@as(usize, 1), report.sessions_external_busy);
    try std.testing.expectEqual(@as(usize, 0), report.sessions_changed);
    try std.testing.expect(recovery.lastResult("live-child") == null);
    try std.testing.expect(recovery.externalBusy("live-child"));
    const repeated = try recovery.recover(9);
    try std.testing.expectEqual(@as(usize, 1), repeated.sessions_external_busy);
    try std.testing.expect(recovery.externalBusy("live-child"));
    var record = try env.loadControl(alloc, "live-child");
    try std.testing.expectEqual(domain.QueueStatus.running, record.queue[0].status);
    record.deinit(alloc);

    try writeExecutionProcessPipe(release_pipe[1], &.{1});
    try std.testing.expectEqual(@as(u8, 0), try waitExternalExecutionProcess(pid));
    reaped = true;
    const settled = try recovery.recover(10);
    try std.testing.expect(settled.fullyReconciled());
    try std.testing.expect(!recovery.externalBusy("live-child"));
    var completed = try env.loadControl(alloc, "live-child");
    defer completed.deinit(alloc);
    try std.testing.expectEqual(domain.State.idle, completed.state);
    try std.testing.expectEqual(domain.QueueStatus.completed, completed.queue[0].status);
    var loaded = try env.store.resumeForWrite(alloc, "live-child");
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    try std.testing.expectEqualStrings(
        "work",
        loaded.state.history[0].assistant.user.work_id.?,
    );
    try std.testing.expect(
        loaded.state.history[0].assistant.user.work_id.?.ptr !=
            loaded.state.last_subagent_work_id.?.ptr,
    );
    try std.testing.expectEqualStrings("work", loaded.state.last_subagent_work_id.?);
}

test "recovery does not classify a locally owned child as externally busy" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "local-live-child");
    try env.installControl(
        alloc,
        "local-live-child",
        .persistent,
        "model/live",
        types.ReasoningEffort.literal("high"),
        &.{"work"},
    );
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
        .session_resume_options = .{ .log = .{ .session_lock_deadline_ms = 0 } },
    };
    defer owner.deinit();
    defer fake.release.store(true, .seq_cst);
    try std.testing.expectEqual(
        StartResult.started,
        try owner.start("local-live-child", false),
    );
    try waitForEntries(&fake, 1);

    const report = try owner.recover(8);
    try std.testing.expectEqual(@as(usize, 1), report.sessions_external_busy);
    try std.testing.expect(!owner.externalBusy("local-live-child"));

    fake.release.store(true, .seq_cst);
    try std.testing.expectEqual(
        ChildResult.idle,
        try owner.join("local-live-child"),
    );
    const settled = try owner.recover(9);
    try std.testing.expect(settled.fullyReconciled());
    try std.testing.expect(!owner.externalBusy("local-live-child"));
}

test "shutdown joins while control locking and control writes are unavailable" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "shutdown-unavailable");
    try env.installControl(alloc, "shutdown-unavailable", .persistent, "model/live", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    try std.testing.expectEqual(StartResult.started, try owner.start("shutdown-unavailable", false));
    try waitForEntries(&fake, 1);
    const lock_path = try std.fs.path.join(alloc, &.{
        env.store.sessions_dir,
        "shutdown-unavailable",
        "subagent",
        "subagent-control.lock",
    });
    defer alloc.free(lock_path);
    const script =
        \\import fcntl, os, sys
        \\lock_file = open(sys.argv[1], "a+b")
        \\fcntl.flock(lock_file, fcntl.LOCK_EX)
        \\os.write(1, b"R")
        \\os.read(0, 1)
    ;
    const argv = [_][]const u8{ "/usr/bin/env", "python3", "-c", script, lock_path };
    var locker = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var locker_reaped = false;
    defer if (!locker_reaped) {
        if (locker.stdin) |stdin_file| stdin_file.writeStreamingAll(io_mod.getIo(), "X") catch {};
        _ = locker.wait(io_mod.getIo()) catch {};
    };
    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(locker.stdout.?.handle, &ready));
    var write_failure = FailNthControlSync{ .fail_at = 1 };
    owner.child_store_options = .{ .replace_ops = .{
        .ctx = &write_failure,
        .sync_file = FailNthControlSync.syncFile,
    } };
    owner.deinit();
    try std.testing.expectEqual(@as(usize, 0), write_failure.calls);
    try locker.stdin.?.writeStreamingAll(io_mod.getIo(), "X");
    _ = try locker.wait(io_mod.getIo());
    locker_reaped = true;
    var resumed = try env.store.resumeForWrite(alloc, "shutdown-unavailable");
    resumed.deinit(alloc);
    var record = try env.loadControl(alloc, "shutdown-unavailable");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.running, record.queue[0].status);
}

test "shutdown joins without consulting an injected failing control writer" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "shutdown-write-failure");
    try env.installControl(alloc, "shutdown-write-failure", .persistent, "model/live", types.ReasoningEffort.literal("high"), &.{"work"});
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var write_failure = FailNthControlSync{ .fail_at = 1 };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    try std.testing.expectEqual(StartResult.started, try owner.start("shutdown-write-failure", false));
    try waitForEntries(&fake, 1);
    owner.child_store_options = .{ .replace_ops = .{
        .ctx = &write_failure,
        .sync_file = FailNthControlSync.syncFile,
    } };
    owner.deinit();
    try std.testing.expectEqual(@as(usize, 0), write_failure.calls);
    var resumed = try env.store.resumeForWrite(alloc, "shutdown-write-failure");
    resumed.deinit(alloc);
    var record = try env.loadControl(alloc, "shutdown-write-failure");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.running, record.queue[0].status);
}

test "execution transitions advance revision and stale inspect cursors" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "event-child");
    try env.installControl(alloc, "event-child", .persistent, "model/events", types.ReasoningEffort.literal("high"), &.{ "one", "two" });
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "event-child",
        .sections = &.{.events},
        .limit = 1,
    } });
    defer inspect.deinit(alloc);
    var first_page = try manager.execute(alloc, inspect, .{
        .actor_id = "parent",
        .timestamp_ms = 2,
    });
    defer first_page.deinit(alloc);
    const stale_cursor = try alloc.dupe(u8, first_page.inspection.next_cursor.?);
    defer alloc.free(stale_cursor);
    const admission_revision = first_page.inspection.generation;

    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("event-child", false));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("event-child"));
    var record = try env.loadControl(alloc, "event-child");
    defer record.deinit(alloc);
    try std.testing.expect(record.generation > admission_revision);
    try std.testing.expectEqual(
        std.math.cast(u64, record.events.len + 1).?,
        record.next_event_sequence,
    );
    var prior_sequence: u64 = 0;
    var prior_revision: u64 = 0;
    for (record.events) |event| {
        try std.testing.expectEqual(prior_sequence + 1, event.sequence);
        try std.testing.expect(event.revision >= prior_revision);
        prior_sequence = event.sequence;
        prior_revision = event.revision;
    }

    var reload_store = try session_store.Store.initFromHome(alloc, env.home, env.workspace);
    defer reload_store.deinit(alloc);
    var reload_manager = manager_mod.Manager{ .sessions = &reload_store };
    var page_one_command = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "event-child",
        .sections = &.{.events},
        .limit = 2,
    } });
    defer page_one_command.deinit(alloc);
    var page_one = try reload_manager.execute(alloc, page_one_command, .{
        .actor_id = "parent",
        .timestamp_ms = 3,
    });
    defer page_one.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), page_one.inspection.events.len);
    try std.testing.expectEqual(@as(u64, 1), page_one.inspection.events[0].sequence);
    var page_two_command = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "event-child",
        .sections = &.{.events},
        .cursor = page_one.inspection.next_cursor,
        .limit = 2,
    } });
    defer page_two_command.deinit(alloc);
    var page_two = try reload_manager.execute(alloc, page_two_command, .{
        .actor_id = "parent",
        .timestamp_ms = 3,
    });
    defer page_two.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), page_two.inspection.events.len);
    try std.testing.expectEqual(@as(u64, 3), page_two.inspection.events[0].sequence);

    var stale_inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "event-child",
        .sections = &.{.events},
        .cursor = stale_cursor,
        .limit = 1,
    } });
    defer stale_inspect.deinit(alloc);
    var stale = try manager.execute(alloc, stale_inspect, .{
        .actor_id = "parent",
        .timestamp_ms = 3,
    });
    defer stale.deinit(alloc);
    try std.testing.expect(stale.inspection.restart_required);
}

test "operation replay remains stable after autonomous execution revisions" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "other-parent");
    try env.createSession(alloc, "replay-child");
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = "replay",
        .mode = .persistent,
        .prompt = "run once",
    } });
    defer create.deinit(alloc);
    var original = try manager.execute(alloc, create, .{
        .actor_id = "parent",
        .operation_id = "stable-operation",
        .created_child_id = "replay-child",
        .timestamp_ms = 1,
    });
    defer original.deinit(alloc);

    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("replay-child", false));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("replay-child"));
    var current = try env.loadControl(alloc, "replay-child");
    try std.testing.expect(current.generation > original.receipt.generation);
    current.deinit(alloc);

    var replay = try manager.execute(alloc, create, .{
        .actor_id = "parent",
        .operation_id = "stable-operation",
        .created_child_id = "replay-child",
        .expected_generation = original.receipt.generation,
        .timestamp_ms = 2,
    });
    defer replay.deinit(alloc);
    try std.testing.expectEqual(original.receipt.generation, replay.receipt.generation);
    try std.testing.expectEqual(original.receipt.event_sequence, replay.receipt.event_sequence);
    try std.testing.expectEqualSlices(
        u8,
        &original.receipt.fingerprint,
        &replay.receipt.fingerprint,
    );

    var actor_conflict = try manager.execute(alloc, create, .{
        .actor_id = "other-parent",
        .operation_id = "stable-operation",
        .created_child_id = "replay-child",
        .timestamp_ms = 3,
    });
    defer actor_conflict.deinit(alloc);
    try std.testing.expectEqual(
        manager_mod.FailureCode.operation_conflict,
        actor_conflict.failure.code,
    );
}

test "close authorizes and archives before cancelling live work" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "close-child");
    try env.installControl(alloc, "close-child", .persistent, "model/close", types.ReasoningEffort.literal("high"), &.{ "active", "queued" });
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("close-child", false));
    try waitForEntries(&fake, 1);
    var result = try owner.close(alloc, "close-child", .{
        .actor_id = "parent",
        .operation_id = "close-op",
        .timestamp_ms = 3,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(domain.OutcomeCode.lifecycle_changed, result.receipt.code);
    var record = try env.loadControl(alloc, "close-child");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.State.archived, record.state);
    try std.testing.expectEqual(domain.State.idle, record.archived_from.?);
    for (record.queue) |message| try std.testing.expectEqual(domain.QueueStatus.cancelled, message.status);
}

test "unauthorized close leaves a detached child unchanged" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "detached-close-child");
    try env.installControl(
        alloc,
        "detached-close-child",
        .persistent,
        "model/close",
        types.ReasoningEffort.literal("high"),
        &.{},
    );
    var fake = FakeExecution{ .alloc = alloc };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = fake.services(),
    };
    defer owner.deinit();

    var detach = try domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = "detached-close-child",
    } });
    defer detach.deinit(alloc);
    var detached = try manager.execute(alloc, detach, .{
        .actor_id = "parent",
        .operation_id = "detach-before-close",
        .timestamp_ms = 2,
    });
    defer detached.deinit(alloc);
    try std.testing.expect(detached == .receipt);
    var before = try env.loadControl(alloc, "detached-close-child");
    defer before.deinit(alloc);

    var rejected = try owner.close(alloc, "detached-close-child", .{
        .actor_id = "parent",
        .operation_id = "unauthorized-close",
        .target_authorization = .{ .attached_to_root = "parent" },
        .timestamp_ms = 3,
    });
    defer rejected.deinit(alloc);
    try std.testing.expect(rejected == .failure);
    try std.testing.expectEqual(
        manager_mod.FailureCode.child_unavailable,
        rejected.failure.code,
    );
    var after = try env.loadControl(alloc, "detached-close-child");
    defer after.deinit(alloc);
    try std.testing.expectEqual(before.generation, after.generation);
    try std.testing.expectEqual(domain.State.idle, after.state);
    try std.testing.expect(after.parent_id == null);
}

test "owner deinit joins and preserves unfinished durable work for recovery" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "shutdown-child");
    try env.installControl(alloc, "shutdown-child", .persistent, "model/shutdown", types.ReasoningEffort.literal("high"), &.{ "active", "queued" });
    var fake = FakeExecution{ .alloc = alloc, .barrier = true };
    defer fake.deinit();
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var owner = Owner{ .alloc = alloc, .sessions = &env.store, .manager = &manager, .services = fake.services() };
    try std.testing.expectEqual(StartResult.started, try owner.start("shutdown-child", false));
    try waitForEntries(&fake, 1);
    owner.deinit();
    var record = try env.loadControl(alloc, "shutdown-child");
    defer record.deinit(alloc);
    try std.testing.expectEqual(domain.QueueStatus.running, record.queue[0].status);
    try std.testing.expectEqual(domain.QueueStatus.pending, record.queue[1].status);
    try std.testing.expect(record.queue[0].cancellation_reason == null);
    try std.testing.expect(record.queue[1].cancellation_reason == null);
    var resumed = try env.store.resumeForWrite(alloc, "shutdown-child");
    resumed.deinit(alloc);
}

fn ownLiveRevalidationRule(
    alloc: Allocator,
    permission: []const u8,
    pattern: []const u8,
    action: types.PermissionAction,
) !types.PermissionRule {
    const owned_permission = try alloc.dupe(u8, permission);
    errdefer alloc.free(owned_permission);
    return .{
        .permission = owned_permission,
        .pattern = try alloc.dupe(u8, pattern),
        .action = action,
    };
}

const LiveRevalidationHost = struct {
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    changed_action: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    tool_name: []const u8,
    source_pattern: ?[]const u8 = null,
    destination_pattern: ?[]const u8 = null,

    fn action(code: u8) ?types.PermissionAction {
        return switch (code) {
            0 => null,
            1 => .ask,
            2 => .deny,
            else => unreachable,
        };
    }

    fn change(self: *@This(), next: types.PermissionAction) void {
        self.changed_action.store(switch (next) {
            .ask => 1,
            .deny => 2,
            .allow => unreachable,
        }, .seq_cst);
        self.generation.store(2, .seq_cst);
    }

    fn resolve(
        raw: ?*anyopaque,
        alloc: Allocator,
        _: []const u8,
    ) authority_mod.HostResolveError!authority_mod.HostAuthority {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const generation = self.generation.load(.seq_cst);
        const changed_action = if (generation == 1)
            null
        else
            action(self.changed_action.load(.seq_cst));
        const rule_count: usize = @as(usize, @intFromBool(self.source_pattern != null)) +
            @as(usize, @intFromBool(changed_action != null));
        const rules = try alloc.alloc(types.PermissionRule, rule_count);
        errdefer alloc.free(rules);
        var initialized: usize = 0;
        errdefer for (rules[0..initialized]) |rule| {
            alloc.free(rule.permission);
            alloc.free(rule.pattern);
        };

        if (self.source_pattern) |source| {
            rules[initialized] = try ownLiveRevalidationRule(
                alloc,
                self.tool_name,
                source,
                .allow,
            );
            initialized += 1;
        }
        if (changed_action) |value| {
            rules[initialized] = try ownLiveRevalidationRule(
                alloc,
                self.tool_name,
                self.destination_pattern.?,
                value,
            );
            initialized += 1;
        }

        const tools = try cloneTestStrings(alloc, &.{self.tool_name});
        errdefer freeTestStrings(alloc, tools);
        const integrations = try alloc.alloc([]u8, 0);
        errdefer alloc.free(integrations);
        const grants = try alloc.alloc(types.PermissionGrant, 0);
        errdefer types.freePermissionGrantSlice(alloc, grants);
        return .{
            .generation = generation,
            .tools = tools,
            .integrations = integrations,
            .rules = .{ .rules = rules },
            .grants = grants,
        };
    }
};

const ProductionPermissionAdapter = struct {
    turn: *TurnContext,
    background: *background_runtime.BackgroundRuntime,
    workspace_root: []const u8,
    tool_registry: tool_dispatch.Registry,

    fn input(
        self: *@This(),
        review_turn: permission_auto_classifier.ReviewTurnContext,
        live_authority: ?agent_runtime.LiveToolAuthority,
    ) !tooling_tool_admission.Input {
        const authority = live_authority orelse return error.HostAuthorityUnavailable;
        return .{
            .workspace_root = self.workspace_root,
            .permission_review_turn = review_turn,
            .permission_grants = authority.grants,
            .permission_rules = authority.rules,
            .tool_registry = self.tool_registry,
            .worker = &self.turn.worker,
            .permission_prompter = self.turn.permissionPrompter(),
            .background = self.background,
            .advertised_dynamic_tool_names = &.{},
            .mcp_runtime = .{},
        };
    }

    fn requestPermission(
        raw: *anyopaque,
        arena: Allocator,
        call: types.ToolCall,
        review_turn: permission_auto_classifier.ReviewTurnContext,
        permission_mode: types.PermissionMode,
        local_grants: []const types.PermissionGrant,
        live_authority: ?agent_runtime.LiveToolAuthority,
        revalidation: ?agent_runtime.LivePermissionRevalidation,
        _: []const []const u8,
    ) !command_admission.PermissionOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const admission = try self.input(review_turn, live_authority);
        return if (revalidation) |request| switch (request) {
            .action => |action_request| tooling_tool_admission.revalidateLiveActionPermissionOutcome(
                admission,
                arena,
                call,
                permission_mode,
                local_grants,
                action_request.authority,
                action_request.human_approval,
            ),
        } else tooling_tool_admission.requestPermissionOutcome(
            admission,
            arena,
            call,
            permission_mode,
            local_grants,
        );
    }
};

const ProductionPromptThread = struct {
    gateway: *agent_test_support.FakeGateway,
    hooks: *agent_test_support.FakeAgentRuntimeDeps,
    config: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *@This()) void {
        defer self.finished.store(true, .seq_cst);
        agent_test_support.runFakePrompt(
            self.gateway,
            self.hooks,
            self.config,
            self.job,
        ) catch self.failed.store(true, .seq_cst);
    }
};

fn waitForPendingToolApproval(
    alloc: Allocator,
    env: *TestEnvironment,
    child_id: []const u8,
) ![]u8 {
    return waitForPendingToolApprovalWithin(alloc, env, child_id, 100_000);
}

fn waitForPendingToolApprovalWithin(
    alloc: Allocator,
    env: *TestEnvironment,
    child_id: []const u8,
    attempts: usize,
) ![]u8 {
    for (0..attempts) |_| {
        const maybe_ledger = env.loadCommunication(alloc, child_id) catch null;
        if (maybe_ledger) |loaded| {
            var ledger = loaded;
            defer ledger.deinit(alloc);
            for (ledger.approvals) |approval| {
                if (approval.kind == .tool and approval.status == .pending) {
                    return alloc.dupe(u8, approval.id);
                }
            }
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    return error.TestApprovalNotRegistered;
}

const ObservedDurableApprovalRegistry = struct {
    durable: approval_persistence.DurableRegistry,
    registrations: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn interface(self: *@This()) approval_registry_mod.Persistence {
        return .{
            .context = self,
            .register_fn = register,
            .commit_response_fn = commitResponse,
            .invalidate_fn = invalidate,
        };
    }

    fn register(
        raw: ?*anyopaque,
        input: communication.ApprovalInput,
    ) approval_registry_mod.PersistenceError!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const delegate = self.durable.interface();
        try delegate.register_fn(delegate.context, input);
        _ = self.registrations.fetchAdd(1, .seq_cst);
    }

    fn commitResponse(
        raw: ?*anyopaque,
        response: communication.ApprovalResponse,
        identity_fingerprint: [32]u8,
    ) approval_registry_mod.PersistenceError!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const delegate = self.durable.interface();
        return delegate.commit_response_fn(
            delegate.context,
            response,
            identity_fingerprint,
        );
    }

    fn invalidate(
        raw: ?*anyopaque,
        request_id: []const u8,
        child_id: []const u8,
        status: communication.ApprovalStatus,
        timestamp_ms: i64,
    ) approval_registry_mod.PersistenceError!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const delegate = self.durable.interface();
        return delegate.invalidate_fn(
            delegate.context,
            request_id,
            child_id,
            status,
            timestamp_ms,
        );
    }
};

fn waitForObservedToolApproval(
    alloc: Allocator,
    env: *TestEnvironment,
    child_id: []const u8,
    observed: *const ObservedDurableApprovalRegistry,
    expected_registrations: usize,
    prompt_finished: *const std.atomic.Value(bool),
) ![]u8 {
    const deadline = io_mod.milliTimestamp() + 5000;
    while (io_mod.milliTimestamp() < deadline) {
        if (observed.registrations.load(.seq_cst) >= expected_registrations) {
            return waitForPendingToolApprovalWithin(alloc, env, child_id, 1);
        }
        if (prompt_finished.load(.seq_cst)) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    return error.TestApprovalNotRegistered;
}

fn runProductionActionGenerationCase(
    tool_name: []const u8,
    changed_action: types.PermissionAction,
    approval_decision: types.ToolPermissionDecision,
) !void {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "permission-child");
    try env.installControl(
        alloc,
        "permission-child",
        .persistent,
        "model/permission",
        types.ReasoningEffort.literal("medium"),
        &.{"permission-work"},
    );
    try env.setPermissionMode(alloc, "permission-child", .ask);
    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            "permission-child",
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = "permission-child",
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = try store.load(alloc);
        defer record.deinit(alloc);
        try admitWork(alloc, &record, 0, 2);
        try store.save(alloc, record);
    }
    {
        var source = try env.tmp.dir.createFile(
            io_mod.getIo(),
            "workspace/source.txt",
            .{ .truncate = true },
        );
        defer source.close(io_mod.getIo());
        try source.writeStreamingAll(io_mod.getIo(), "source\n");
    }
    const destination = try std.fs.path.join(
        alloc,
        &.{ env.home, "destination.txt" },
    );
    defer alloc.free(destination);
    const arguments = if (std.mem.eql(u8, tool_name, "copy_file"))
        try std.fmt.allocPrint(
            alloc,
            "{{\"source\":\"source.txt\",\"destination\":\"{s}\"}}",
            .{destination},
        )
    else
        try std.fmt.allocPrint(
            alloc,
            "{{\"old_path\":\"source.txt\",\"new_path\":\"{s}\"}}",
            .{destination},
        );
    defer alloc.free(arguments);

    var host = LiveRevalidationHost{
        .tool_name = tool_name,
        .source_pattern = "source.txt",
        .destination_pattern = destination,
    };
    var authority = authority_mod.Resolver{
        .sessions = &env.store,
        .host = .{ .context = &host, .resolve_fn = LiveRevalidationHost.resolve },
    };
    var durable = approval_persistence.DurableRegistry{
        .alloc = alloc,
        .sessions = &env.store,
    };
    var registry = approval_registry_mod.Registry{
        .alloc = alloc,
        .persistence = durable.interface(),
    };
    defer registry.deinit();
    var loaded = try env.store.resumeForWrite(alloc, "permission-child");
    defer {
        loaded.log.park();
        loaded.deinit(alloc);
    }
    var turn = try TurnContext.init(alloc, &loaded, 8);
    defer turn.deinit();
    turn.live_authority = &authority;
    turn.approval_registry = &registry;
    turn.child_id = "permission-child";
    turn.active_work_id = "permission-work";
    turn.worker.worker_processing = true;
    var background: background_runtime.BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var hooks = agent_test_support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.live_tool_authority = turn.liveToolAuthorityProvider();
    hooks.permission_target = try std.fs.path.join(
        alloc,
        &.{ env.workspace, "source.txt" },
    );
    defer alloc.free(@constCast(hooks.permission_target));
    hooks.workspace_root = env.workspace;
    hooks.exec_plans = &.{.{ .result = .{ .model_output = "effect" } }};
    var adapter = ProductionPermissionAdapter{
        .turn = &turn,
        .background = &background,
        .workspace_root = env.workspace,
        .tool_registry = hooks.tool_registry,
    };
    hooks.permission_request_override = .{
        .context = &adapter,
        .request_fn = ProductionPermissionAdapter.requestPermission,
    };

    const calls = [_]types.ToolCall{.{
        .id = "generation-bound-action",
        .name = tool_name,
        .arguments_json = arguments,
    }};
    const completions = [_]agent_test_support.FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "done" },
    };
    var gateway = agent_test_support.FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var fixture = agent_test_support.PromptFixture{ .workspace_root = env.workspace };
    var job = fixture.job();
    // This fixture exercises live human-approval revalidation, not automatic
    // recovery. Start it in ask mode so the initial approval is intentional.
    job.permission_mode = .ask;
    var config = fixture.config();
    config.origin = .subagent;
    config.session_child_capability = try turn.childCapability();
    var prompt = ProductionPromptThread{
        .gateway = &gateway,
        .hooks = &hooks,
        .config = config,
        .job = job,
    };
    const thread = try std.Thread.spawn(.{}, ProductionPromptThread.run, .{&prompt});
    var joined = false;
    defer if (!joined) {
        turn.worker.requestCancel();
        thread.join();
    };
    const approval_id = try waitForPendingToolApproval(
        alloc,
        &env,
        "permission-child",
    );
    defer alloc.free(approval_id);
    try std.testing.expectEqual(
        @as(usize, 0),
        hooks.successful_effect_count.load(.seq_cst),
    );
    host.change(changed_action);
    try std.testing.expectEqual(
        approval_registry_mod.ResolveResult.accepted,
        try registry.resolve(
            approval_id,
            "permission-child",
            approval_decision,
            null,
            3,
        ),
    );
    thread.join();
    joined = true;
    try std.testing.expect(!prompt.failed.load(.seq_cst));
    const expected_effects: usize = if (changed_action == .ask) 1 else 0;
    try std.testing.expectEqual(
        expected_effects,
        hooks.successful_effect_count.load(.seq_cst),
    );
    var ledger = try env.loadCommunication(alloc, "permission-child");
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), ledger.approvals.len);
    try std.testing.expectEqual(
        if (approval_decision == .always)
            communication.ApprovalStatus.allowed_always
        else
            communication.ApprovalStatus.allowed_once,
        ledger.approvals[0].status,
    );
}

test "production child action revalidation checks changed copy and rename destinations" {
    for ([_][]const u8{ "copy_file", "rename_file" }) |tool_name| {
        try runProductionActionGenerationCase(
            tool_name,
            .ask,
            if (std.mem.eql(u8, tool_name, "rename_file")) .always else .once,
        );
        try runProductionActionGenerationCase(tool_name, .deny, .once);
    }
}

const GatewayExecution = struct {
    calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn resolveHostAuthority(
        _: ?*anyopaque,
        alloc: Allocator,
        _: []const u8,
    ) authority_mod.HostResolveError!authority_mod.HostAuthority {
        const tools = try cloneTestStrings(alloc, &.{
            "read_file",
            "grep_files",
            "mcp_select_tool",
            "mcp_fixture_echo",
        });
        errdefer freeTestStrings(alloc, tools);
        const integrations = try cloneTestStrings(alloc, &.{"mcp_fixture_echo"});
        errdefer freeTestStrings(alloc, integrations);
        const rules = try alloc.alloc(types.PermissionRule, 1);
        errdefer alloc.free(rules);
        rules[0] = .{
            .permission = try alloc.dupe(u8, "read"),
            .pattern = try alloc.dupe(u8, "file.txt"),
            .action = .allow,
        };
        errdefer {
            alloc.free(rules[0].permission);
            alloc.free(rules[0].pattern);
        }
        const grants = try alloc.alloc(types.PermissionGrant, 1);
        errdefer alloc.free(grants);
        const grant_tool = try alloc.dupe(u8, "read_file");
        errdefer alloc.free(grant_tool);
        const grant_target = try alloc.dupe(u8, "/tmp/workspace/file.txt");
        grants[0] = .{ .tool_name = grant_tool, .target_path = grant_target };
        return .{
            .generation = 1,
            .tools = tools,
            .integrations = integrations,
            .rules = .{ .rules = rules },
            .grants = grants,
        };
    }

    fn services(self: *GatewayExecution) Services {
        return .{ .context = self, .capture_fn = capture, .run_fn = run };
    }

    fn capture(
        _: ?*anyopaque,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        var rules = [_]types.PermissionRule{.{
            .permission = @constCast("read"),
            .pattern = @constCast("file.txt"),
            .action = .allow,
        }};
        var grants = [_]types.PermissionGrant{.{
            .tool_name = @constCast("read_file"),
            .target_path = @constCast("/tmp/workspace/file.txt"),
        }};
        return domain.captureAdmission(alloc, .{
            .parent_id = request.parent_id,
            .source_id = request.source_id,
            .model = request.preferences.model,
            .effort = request.preferences.effort,
            .tool_names = &.{ "read_file", "grep_files", "mcp_select_tool" },
            .rules = .{ .rules = &rules },
            .grants = &grants,
            .integration_names = &.{"mcp_fixture_echo"},
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.AdmissionFailed,
        };
    }

    fn run(
        raw: ?*anyopaque,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        return runImpl(raw, turn, message, admission, cancel) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                else => error.ProviderFailed,
            };
        };
    }

    fn runImpl(
        raw: ?*anyopaque,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) !RunOutcome {
        const self: *GatewayExecution = @ptrCast(@alignCast(raw.?));
        if (admission.permission_mode != .yolo or
            admission.tool_names.len != 3 or admission.integration_names.len != 1 or
            !std.mem.eql(u8, admission.parent_id, "parent") or
            !std.mem.eql(u8, admission.source_id, "parent")) return error.InvalidAdmissionSnapshot;
        const decision = try permissions.ruleDecisionFor(
            turn.alloc,
            admission.rules,
            "/tmp/workspace",
            "read_file",
            "/tmp/workspace/file.txt",
            .path_existing,
        );
        if (decision != .allow) return error.RuleNotInherited;
        const read_calls = [_]types.ToolCall{.{
            .id = "read",
            .name = "read_file",
            .arguments_json = "{\"path\":\"/tmp/workspace/file.txt\"}",
        }};
        const grep_calls = [_]types.ToolCall{.{
            .id = "grep",
            .name = "grep_files",
            .arguments_json = "{\"pattern\":\"fixture\",\"path\":\".\"}",
        }};
        const select_calls = [_]types.ToolCall{.{
            .id = "select",
            .name = "mcp_select_tool",
            .arguments_json = "{\"name\":\"mcp_fixture_echo\"}",
        }};
        const dynamic_calls = [_]types.ToolCall{.{
            .id = "dynamic",
            .name = "mcp_fixture_echo",
            .arguments_json = "{}",
        }};
        const chunks = [_][]const u8{"gateway child reply"};
        const completions = [_]agent_test_support.FakeCompletion{
            .{ .tool_calls = &read_calls },
            .{ .tool_calls = &grep_calls },
            .{ .tool_calls = &select_calls },
            .{ .tool_calls = &dynamic_calls },
            .{ .chunks = &chunks, .content = "gateway child reply" },
        };
        var gateway = agent_test_support.FakeGateway.init(turn.alloc, &completions);
        defer gateway.deinit();
        var hooks = agent_test_support.FakeAgentRuntimeDeps.init(turn.alloc);
        defer hooks.deinit();
        const inherited_tools = [_]tool_dispatch.Tool{
            test_builtin_tools.read_file,
            test_builtin_tools.grep_files,
            test_builtin_tools.mcp_select_tool,
        };
        hooks.tool_registry = .{ .tools = &inherited_tools };
        hooks.live_tool_authority = turn.liveToolAuthorityProvider();
        hooks.tool_activity_recorder = turn.toolActivityRecorder();
        hooks.permission_decisions = &.{ .once, .once, .once, .once };
        hooks.exec_plans = &.{
            .{ .result = .{ .model_output = "fixture contents" } },
            .{ .result = .{ .model_output = "fixture match" } },
            .{ .result = .{
                .model_output = "selected",
                .selected_dynamic_tool_name = "mcp_fixture_echo",
                .selected_dynamic_tool_schema_json = "{\"type\":\"function\",\"name\":\"mcp_fixture_echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}",
            } },
            .{ .result = .{ .model_output = "echoed" } },
        };
        hooks.session_context = turn.sessionRuntime();
        var fixture = agent_test_support.PromptFixture{};
        const history = try turn.sessionRuntime().snapshotContextHistory(turn.alloc);
        defer session.freeHistoryTurnSlice(turn.alloc, history);
        var job = fixture.job();
        job.prompt = message.content;
        job.model = admission.model;
        job.permission_mode = admission.permission_mode;
        job.history = history;
        job.grants = admission.grants;
        var config = fixture.config();
        config.cancel_flag = cancel;
        config.agent_step_limit = 8;
        config.effort = admission.effort;
        config.origin = .subagent;
        config.session_child_capability = try turn.childCapability();
        try agent_test_support.runFakePrompt(&gateway, &hooks, config, job);
        if (hooks.history_turns.items.len != 1) return error.HistoryNotCommitted;
        try turn.commit(message.id, hooks.history_turns.items[0], 1, 1, 2);
        if (!std.mem.eql(u8, admission.model, gateway.request_models.items[0]))
            return error.ModelNotInherited;
        if (hooks.executed_names.items.len != 4) return error.ToolsNotExecuted;
        if (!std.mem.eql(u8, "read_file", hooks.executed_names.items[0]) or
            !std.mem.eql(u8, "grep_files", hooks.executed_names.items[1]) or
            !std.mem.eql(u8, "mcp_select_tool", hooks.executed_names.items[2]) or
            !std.mem.eql(u8, "mcp_fixture_echo", hooks.executed_names.items[3]))
            return error.ToolIsolationFailed;
        if (hooks.last_execute_grants.items.len != 1 or !std.mem.eql(
            u8,
            "/tmp/workspace/file.txt",
            hooks.last_execute_grants.items[0].target_path,
        )) return error.GrantNotInherited;
        if (hooks.last_live_authority_generation == null or
            hooks.last_live_authority_generation.? == 0 or
            hooks.last_live_authority_tool_count != 4 or
            hooks.last_live_authority_integration_count != 1 or
            hooks.last_live_authority_rule_count != 1 or
            hooks.last_live_authority_grant_count != 1)
        {
            return error.LiveAuthorityNotPropagated;
        }
        _ = self.calls.fetchAdd(1, .seq_cst);
        return .completed;
    }
};

fn cloneTestStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, values.len);
    errdefer alloc.free(out);
    var copied: usize = 0;
    errdefer for (out[0..copied]) |value| alloc.free(value);
    for (values, 0..) |value, index| {
        out[index] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

fn freeTestStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

test "session-backed owner executes through deterministic gateway and normal agent pipeline" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "gateway-child");
    try env.installControl(alloc, "gateway-child", .persistent, "anthropic/claude-opus-4.6", types.ReasoningEffort.literal("high"), &.{"delegate-through-gateway"});
    var gateway_execution: GatewayExecution = .{};
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var live_authority = authority_mod.Resolver{
        .sessions = &env.store,
        .host = .{ .resolve_fn = GatewayExecution.resolveHostAuthority },
    };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = gateway_execution.services(),
        .live_authority = &live_authority,
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("gateway-child", false));
    try std.testing.expectEqual(ChildResult.idle, try owner.join("gateway-child"));
    try std.testing.expectEqual(@as(usize, 1), gateway_execution.calls.load(.seq_cst));
    var loaded = try env.store.resumeForWrite(alloc, "gateway-child");
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    try std.testing.expectEqualStrings(
        "delegate-through-gateway",
        loaded.state.history[0].assistant.user.work_id.?,
    );
    try std.testing.expectEqualStrings(
        "delegate-through-gateway",
        loaded.state.last_subagent_work_id.?,
    );
    try std.testing.expect(
        loaded.state.history[0].assistant.user.work_id.?.ptr !=
            loaded.state.last_subagent_work_id.?.ptr,
    );
    try std.testing.expectEqualStrings(
        "gateway child reply",
        loaded.state.history[0].assistant.assistant,
    );
    var communication_query = communication_manager.Manager{ .sessions = &env.store };
    var activity_page = try communication_query.page(
        alloc,
        "gateway-child",
        "parent-ui",
        "parent",
        null,
        16,
    );
    defer activity_page.deinit(alloc);
    var activity_count: usize = 0;
    var terminal_count: usize = 0;
    for (activity_page.deliveries) |delivery| switch (delivery.payload) {
        .tool_activity => |activity| {
            activity_count += 1;
            try std.testing.expect(
                std.mem.eql(u8, activity.tool_name, "read_file") or
                    std.mem.eql(u8, activity.tool_name, "grep_files") or
                    std.mem.eql(u8, activity.tool_name, "mcp_select_tool") or
                    std.mem.eql(u8, activity.tool_name, "mcp_fixture_echo"),
            );
        },
        .terminal => terminal_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 8), activity_count);
    try std.testing.expectEqual(@as(usize, 1), terminal_count);
    var parent_boundary = try communication_query.prepareParentBoundary(
        alloc,
        "gateway-child",
        "parent-model",
        "parent",
        .turn_boundary,
        null,
    );
    defer parent_boundary.deinit(alloc);
    try std.testing.expect(parent_boundary == .inject);
    try std.testing.expect(std.mem.indexOf(
        u8,
        parent_boundary.inject.context,
        "\"terminal\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        parent_boundary.inject.context,
        "tool_activity",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        parent_boundary.inject.context,
        "approval",
    ) == null);

    var inspect = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = "gateway-child",
        .sections = &.{.events},
        .limit = 16,
    } });
    defer inspect.deinit(alloc);
    var lifecycle = try manager.execute(alloc, inspect, .{
        .actor_id = "parent",
        .timestamp_ms = 3,
    });
    defer lifecycle.deinit(alloc);
    var saw_pending = false;
    var saw_running = false;
    var saw_completed = false;
    for (lifecycle.inspection.events) |event| switch (event.kind) {
        .work_transition => |transition| switch (transition.current) {
            .pending => saw_pending = true,
            .running => saw_running = true,
            .completed => saw_completed = true,
            else => {},
        },
        else => {},
    };
    try std.testing.expect(saw_pending and saw_running and saw_completed);
}

test "completed one off reconciles one stable final result message" {
    const alloc = std.testing.allocator;
    var env = try TestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, "parent");
    try env.createSession(alloc, "one-off-child");
    try env.installControl(
        alloc,
        "one-off-child",
        .one_off,
        "anthropic/claude-opus-4.6",
        types.ReasoningEffort.literal("high"),
        &.{"one-off-work"},
    );
    _ = try relationship_index.ensureChild(
        alloc,
        &env.store,
        "parent",
        "one-off-child",
        .{},
    );
    var gateway_execution: GatewayExecution = .{};
    var manager = manager_mod.Manager{ .sessions = &env.store };
    var live_authority = authority_mod.Resolver{
        .sessions = &env.store,
        .host = .{ .resolve_fn = GatewayExecution.resolveHostAuthority },
    };
    var owner = Owner{
        .alloc = alloc,
        .sessions = &env.store,
        .manager = &manager,
        .services = gateway_execution.services(),
        .live_authority = &live_authority,
        .retirement_root_id = "parent",
    };
    defer owner.deinit();
    try std.testing.expectEqual(StartResult.started, try owner.start("one-off-child", false));
    try std.testing.expectEqual(ChildResult.completed, try owner.join("one-off-child"));
    var indexed = try env.store.listResumablePage(alloc, null, null);
    indexed.deinit(alloc);

    var communication_query = communication_manager.Manager{ .sessions = &env.store };
    var page = try communication_query.page(
        alloc,
        "one-off-child",
        "parent-model",
        "parent",
        null,
        16,
    );
    defer page.deinit(alloc);
    var result_count: usize = 0;
    for (page.deliveries) |delivery| switch (delivery.payload) {
        .message => |message| {
            result_count += 1;
            try std.testing.expectEqualStrings("gateway child reply", message);
            try std.testing.expectEqualStrings("one-off-work", delivery.work_id.?);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), result_count);

    _ = try owner.recover(20);
    var repeated = try communication_query.page(
        alloc,
        "one-off-child",
        "parent-model",
        "parent",
        null,
        16,
    );
    defer repeated.deinit(alloc);
    var repeated_count: usize = 0;
    for (repeated.deliveries) |delivery| {
        if (delivery.payload == .message) repeated_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), repeated_count);

    while (true) {
        var pending = try communication_query.prepareParentBoundary(
            alloc,
            "one-off-child",
            "parent-model",
            "parent",
            .turn_boundary,
            null,
        );
        defer pending.deinit(alloc);
        if (pending == .wait) break;
        try communication_query.acknowledgeParentBoundary(
            alloc,
            "one-off-child",
            "parent-model",
            "parent",
            .{
                .sequence = pending.inject.through_sequence,
                .delivery_id = pending.inject.delivery_id,
                .start_offset = pending.inject.start_offset,
                .end_offset = pending.inject.end_offset,
                .total_bytes = pending.inject.total_bytes,
            },
        );
    }
    var canonical = try manager.snapshot(alloc, .{ .root_id = "parent" });
    defer canonical.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), canonical.snapshot.nodes.len);
    {
        var communication_capability = try env.store.openSubagentControlCapabilityReadOnly(
            alloc,
            "one-off-child",
            .{},
        );
        defer communication_capability.deinit();
        const communication_state = communication_store.Store{
            .capability = &communication_capability,
            .expected_session_id = "one-off-child",
        };
        var acknowledged = try communication_state.load(alloc);
        defer acknowledged.deinit(alloc);
        const result_id = communication.stableDeliveryId(
            "one-off-child",
            "one-off-work",
            "final-result",
        );
        try std.testing.expect(communication.parentTurnDeliveryFullyAcknowledged(
            acknowledged,
            "parent-model",
            "parent",
            &result_id,
        ));
    }
    try std.testing.expectEqual(
        @as(?u64, 0),
        try relationship_index.activeCountIfMigrationComplete(
            alloc,
            &env.store,
            "one-off-child",
            .{},
        ),
    );
    try std.testing.expect(!owner.tryRetireOneOff("one-off-child"));
    try std.testing.expectError(
        error.SessionNotFound,
        env.store.loadReadOnly(alloc, "one-off-child"),
    );
    try std.testing.expect((try relationship_index.lookupSlot(
        alloc,
        &env.store,
        "parent",
        "one-off-child",
        .{},
    )) == null);
}

fn checkAdmissionAllocationFailures(alloc: Allocator) !void {
    var snapshot = try domain.captureAdmission(alloc, .{
        .parent_id = "parent",
        .source_id = "source",
        .model = "model",
        .effort = types.ReasoningEffort.literal("high"),
        .tool_names = &.{ "read_file", "write_file" },
        .integration_names = &.{"mcp:test"},
    });
    snapshot.deinit(alloc);
}

test "admission snapshot cleans every failing-allocation path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAdmissionAllocationFailures,
        .{},
    );
}

fn checkRecoveryAllocationFailures(alloc: Allocator) !void {
    var record = try testRecord(alloc, .persistent, &.{ "first", "second" });
    defer record.deinit(alloc);
    const recovered = try recoverAfterRestart(alloc, &record, null, 2);
    try std.testing.expectEqual(@as(usize, 2), recovered.interrupted);
}

fn checkCancellationAllocationFailures(alloc: Allocator) !void {
    var record = try testRecord(alloc, .persistent, &.{ "first", "second" });
    defer record.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), try cancelWork(alloc, &record, "stop", 2));
}

test "recovery and cancellation reducers clean failing-allocation paths" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRecoveryAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCancellationAllocationFailures,
        .{},
    );
}
