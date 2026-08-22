const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const auth_runtime = @import("../../auth/auth_runtime.zig");
const session_usage = @import("../../session/session_usage.zig");
const session_codec = @import("../../session/session_codec.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const types = @import("../../shared/types.zig");
const worker_runtime = @import("../worker_runtime.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const tool_admission = @import("../../tooling/tool_admission.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_contracts = @import("tool_contracts.zig");
const context_contract = @import("../../workspace/context_contract.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const WorkerEvent = worker_runtime.WorkerEvent;

const DeferredToolCompletion = tool_contracts.DeferredToolCompletion;
const DiffEntryPayload = tool_contracts.DiffEntryPayload;
const ToolCallValidationResult = tool_contracts.ToolCallValidationResult;
const ToolExecutionRequest = tool_contracts.ToolExecutionRequest;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;
const TransportPublicationOutcome = tool_contracts.TransportPublicationOutcome;
pub const LiveToolAuthority = tool_contracts.LiveToolAuthority;

pub const RecoveryCheckpointEffect = struct {
    set: *const fn (ctx: *anyopaque, checkpoint: session_codec.RecoveryCheckpoint) anyerror!void,
};

pub const LiveToolAuthorityDecision = enum {
    allow,
    ask,
    deny,
    unavailable,
};

pub const ResolvedLiveToolAuthority = struct {
    authority: LiveToolAuthority,
    decision: LiveToolAuthorityDecision,
};

/// Child-only provider. Any returned slices borrow `alloc`, whose action arena
/// remains alive through permission admission and tool execution.
pub const LiveToolAuthorityProvider = struct {
    context: *anyopaque,
    resolve_fn: *const fn (
        *anyopaque,
        Allocator,
        ToolCall,
        []const u8,
        []const u8,
        tool_dispatch.PermissionTargetKind,
    ) anyerror!ResolvedLiveToolAuthority,

    pub fn resolve(
        self: LiveToolAuthorityProvider,
        alloc: Allocator,
        call: ToolCall,
        workspace_root: []const u8,
        target: []const u8,
        target_kind: tool_dispatch.PermissionTargetKind,
    ) !ResolvedLiveToolAuthority {
        return self.resolve_fn(
            self.context,
            alloc,
            call,
            workspace_root,
            target,
            target_kind,
        );
    }
};

pub const ToolActivityPhase = enum { started, succeeded, failed, denied };

pub const ToolActivityRecorder = struct {
    context: *anyopaque,
    record_fn: *const fn (
        *anyopaque,
        []const u8,
        []const u8,
        ToolActivityPhase,
    ) anyerror!void,

    pub fn record(
        self: ToolActivityRecorder,
        call_id: []const u8,
        tool_name: []const u8,
        phase: ToolActivityPhase,
    ) !void {
        return self.record_fn(self.context, call_id, tool_name, phase);
    }
};

fn acknowledgePromptFinalization(_: *anyopaque, _: u64, _: types.TurnPresentationOutcome, _: ?types.ProviderCompletionDisposition) !void {}
fn discardToolLifecycle(_: *anyopaque, _: types.ToolLifecycleEvent) !void {}
fn discardRouteRecoveryStatus(_: *anyopaque, _: types.RouteRecoveryStatus) !void {}
fn localAvailableModelCapabilities(_: *anyopaque, model: []const u8) model_capabilities.Capabilities {
    return model_capabilities.capabilitiesForModel(model);
}
fn localModelCapabilities(_: *anyopaque, _: Allocator, model: []const u8) !model_capabilities.Capabilities {
    return model_capabilities.capabilitiesForModel(model);
}

pub const RouteRecoveryDecision = enum {
    disable_fast,
    switch_model,
    cancel,
};

pub const ParentTurnDeliveryAck = struct {
    child_id: []const u8,
    target_session_id: []const u8,
    through_sequence: u64,
    delivery_id: []const u8,
    start_offset: u64,
    end_offset: u64,
    total_bytes: u64,
    discovery_start_offset: ?u64 = null,
    discovery_next_offset: ?u64 = null,
};

/// Slices are owned by the allocator passed to `prepare_parent_turn_context`
/// and remain valid until that allocator is reset or deinitialized. The caller
/// must finish every acknowledgement callback before ending that lifetime;
/// acknowledgement callbacks borrow these slices only for the callback.
pub const PreparedParentTurnContext = struct {
    content: []const u8,
    acknowledgements: []const ParentTurnDeliveryAck,
};

pub const RouteRecoveryRequest = struct {
    selected_model: []const u8,
    route_model: []const u8,
    fast_mode: bool,
    replay_safe: bool,
    finish_reason: types.ProviderFinishReason,
    semantic_attempts: usize,
    unsafe_no_retry_reason: ?types.RouteRecoveryUnsafeReason = null,
    provider_failure_detail: ?[]const u8 = null,
};

pub const CredentialRefreshMode = auth_runtime.CredentialRefreshMode;

/// Ordered text emitted by the agent runtime. Payloads are borrowed for the
/// duration of the callback.
pub const TextEmission = union(enum) {
    assistant_source: []const u8,
    assistant_rendered: []const u8,
    operational: []const u8,
};

/// Accent colors for diff add/remove markers. Named fields so the two styles
/// cannot be swapped silently at a call site. Empty means the neutral accent.
pub const DiffMarkerStyles = struct {
    added: []const u8 = "",
    removed: []const u8 = "",
};

pub const AgentRuntimeDeps = struct {
    ctx: *anyopaque,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    flush_assistant_stream_per_content_chunk: bool = false,
    cooperative_transport_pulse: ?agent_stream_provider.CooperativePulse = null,
    tool_registry: tool_dispatch.Registry = .{},
    context_registry: ?context_contract.Registry = null,
    context_enabled: bool = false,
    live_tool_authority: ?LiveToolAuthorityProvider = null,
    tool_activity_recorder: ?ToolActivityRecorder = null,
    finalize_turn: *const fn (ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) anyerror!void = acknowledgePromptFinalization,
    prepare_parent_turn_context: ?*const fn (ctx: *anyopaque, arena: Allocator) anyerror!?PreparedParentTurnContext = null,
    acknowledge_parent_turn_context: ?*const fn (ctx: *anyopaque, arena: Allocator, acknowledgements: []const ParentTurnDeliveryAck) void = null,
    append_runtime_context: *const fn (ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) anyerror!void,
    append_static_context: ?*const fn (ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) anyerror!void = null,
    validate_tool_call: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall) anyerror!ToolCallValidationResult = null,
    check_tool_availability: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall) anyerror!?[]const u8 = null,
    request_tool_permission: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?LiveToolAuthority, revalidation: ?tool_contracts.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) anyerror!command_admission.PermissionOutcome,
    /// Admission consumes `prepared`; callers must not retry the same value through the raw callback.
    request_prepared_file_mutation_permission: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) anyerror!command_admission.PermissionOutcome = null,
    resolve_tool_action_display_target: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall) anyerror!?[]const u8 = null,
    describe_tool_action: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) anyerror![]const u8,
    describe_tool_action_completed: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) anyerror![]const u8,
    describe_tool_action_denied: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) anyerror![]const u8,
    permission_target_for_call: *const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) anyerror![]const u8,
    execute_tool_call: *const fn (ctx: *anyopaque, request: ToolExecutionRequest) anyerror!ToolExecutionResult,
    publish_committed_file_handoff: *const fn (ctx: *anyopaque, handoff: file_mutation.CommittedFileHandoff) tool_contracts.SecondaryPublicationReport,
    publish_deferred_tool_completion: ?*const fn (ctx: *anyopaque, completion: DeferredToolCompletion) TransportPublicationOutcome = null,
    propagate_history_turn: *const fn (ctx: *anyopaque, turn: HistoryTurn) anyerror!void,
    recovery_checkpoint: ?RecoveryCheckpointEffect = null,
    propagate_grant: *const fn (ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) anyerror!void,
    push_event: *const fn (ctx: *anyopaque, event: WorkerEvent) anyerror!void,
    push_text: *const fn (ctx: *anyopaque, emission: TextEmission) anyerror!void,
    push_tool_lifecycle: *const fn (ctx: *anyopaque, event: types.ToolLifecycleEvent) anyerror!void = discardToolLifecycle,
    push_diff_block: *const fn (ctx: *anyopaque, payload: DiffEntryPayload) anyerror!void,
    push_system_notice: *const fn (ctx: *anyopaque, text: []const u8) anyerror!void,
    push_interactive_notice: ?*const fn (ctx: *anyopaque, notice: types.SemanticNotice) anyerror!void = null,
    /// Source-limit notices use a session-scoped deduplicating path when the
    /// host provides one; ordinary system notices remain unaffected.
    push_context_notice: ?*const fn (ctx: *anyopaque, text: []const u8) anyerror!void = null,
    push_route_recovery_status: *const fn (ctx: *anyopaque, status: types.RouteRecoveryStatus) anyerror!void = discardRouteRecoveryStatus,
    push_command_output_complete: *const fn (ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) anyerror!void,
    push_http_error: *const fn (ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) anyerror!void,
    refresh_gateway_credential: ?*const fn (ctx: *anyopaque, alloc: Allocator, source: types.CredentialSource, mode: CredentialRefreshMode, expected_account_id: ?[]const u8) anyerror!?[]u8 = null,
    request_route_recovery: ?*const fn (ctx: *anyopaque, arena: Allocator, request: RouteRecoveryRequest) anyerror!RouteRecoveryDecision = null,
    available_model_capabilities: *const fn (ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities = localAvailableModelCapabilities,
    resolve_model_capabilities: *const fn (ctx: *anyopaque, arena: Allocator, model: []const u8) anyerror!model_capabilities.Capabilities = localModelCapabilities,
    format_tool_execution_error: *const fn (ctx: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) anyerror![]const u8,
    record_tool_call_rejected: ?*const fn (ctx: *anyopaque, arena: Allocator, call: ToolCall, model_output: []const u8, command_result_json: ?[]const u8) anyerror!void = null,
    report_usage: ?*const fn (ctx: *anyopaque, usage: types.Usage) void = null,
    report_inner_tool_usage: ?*const fn (ctx: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void = null,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    // Accent for the +N / -N counts in a committed file's status line.
    // Captured by value at construction; that is safe only while the marker
    // colors never change after startup (they are theme-independent).
    diff_marker_styles: DiffMarkerStyles = .{},

    pub fn pushContextNotice(self: *const AgentRuntimeDeps, text: []const u8) !void {
        if (self.push_context_notice) |push| return push(self.ctx, text);
        return self.push_system_notice(self.ctx, text);
    }
};
