const std = @import("std");
const builtin = @import("builtin");
const agent_stream_provider = @import("../../stream_provider.zig");
const command_admission = @import("../../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../../permissions/auto_classifier.zig");
const types = @import("../../../shared/types.zig");
const permissions = @import("../../../permissions/permissions.zig");
const worker_runtime = @import("../../worker_runtime.zig");
const background_runtime = @import("../../../background/background_runtime.zig");
const builtin_context = @import("../../../../builtins/context.zig");
const builtin_gateway = @import("../../../../builtins/gateway.zig");
const gateway_client = @import("../../../../gateway/client.zig");
const builtin_tools = @import("../../../../builtins/tools.zig");
const session_runtime = @import("../../../session/session.zig");
const session_codec = @import("../../../session/session_codec.zig");
const command_replay_store = @import("../../../session/command_replay_store.zig");
const session_child_store = @import("../../../session/session_child_store.zig");
const gateway_json = @import("../../../gateway/gateway_json.zig");
const gateway_failure_diagnostics = @import("../../../gateway/gateway_failure_diagnostics.zig");
const lifecycle_hooks = @import("../../../hooks/hooks.zig");
const model_capabilities = @import("../../../config/model_capabilities.zig");
const file_mutation = @import("../../../tooling/file_mutation.zig");
const file_mutation_contract = @import("../../../tooling/file_mutation_contract.zig");
const context_contract = @import("../../../workspace/context_contract.zig");
const io_mod = @import("../../../shared/io.zig");
const pathing = @import("../../../workspace/pathing.zig");
const tool_dispatch = @import("../../../tooling/tool_dispatch.zig");
const tool_runtime = @import("../../../tooling/tool_runtime.zig");
const command_output_content = @import("../../../tooling/command_output_content.zig");
const testing_write_file = if (builtin.is_test)
    @import("../../../../tools/filesystem/write_file.zig")
else
    struct {};
const testing_edit_file = if (builtin.is_test)
    @import("../../../../tools/filesystem/edit_file.zig")
else
    struct {};

const runtime_config = @import("../config.zig");
const runtime_deps = @import("../deps.zig");
const runtime_lifecycle = @import("../lifecycle.zig");
const model_response_recovery = @import("../model_response_recovery.zig");
const runtime_orchestrator = @import("../orchestrator.zig");
const runtime_tool_contracts = @import("../tool_contracts.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;
const QueuedPrompt = worker_runtime.QueuedPrompt;
const WorkerEvent = worker_runtime.WorkerEvent;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const Config = runtime_config.Config;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;
const ToolExecutionRequest = runtime_tool_contracts.ToolExecutionRequest;
const ToolCallValidationResult = runtime_tool_contracts.ToolCallValidationResult;
const DiffEntryPayload = runtime_tool_contracts.DiffEntryPayload;
const SecondaryPublicationReport = runtime_tool_contracts.SecondaryPublicationReport;

pub const vision_agent_test_tools = [_]tool_dispatch.Tool{builtin_tools.vision};

pub const VisionAgentToolRuntime = struct {
    alloc: Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    session_id: ?[]const u8 = null,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    result_allocator_override: ?Allocator = null,
    execution_count: usize = 0,
    result_count: usize = 0,
    worker: worker_runtime.WorkerRuntime = .{},
    background: background_runtime.BackgroundRuntime = .{},
    session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },

    pub fn deinit(self: *VisionAgentToolRuntime) void {
        self.worker.deinit(self.alloc);
        self.background.deinit(self.alloc);
        self.session.deinit(self.alloc);
    }

    pub fn delegate(self: *VisionAgentToolRuntime) ExecuteDelegate {
        return .{
            .ctx = self,
            .run = execute,
            .set_agent_stream_provider = setAgentStreamProvider,
        };
    }

    fn setAgentStreamProvider(raw: *anyopaque, provider: agent_stream_provider.Provider) void {
        const self: *VisionAgentToolRuntime = @ptrCast(@alignCast(raw));
        self.agent_stream_provider = provider;
    }

    fn execute(raw: *anyopaque, request: ToolExecutionRequest) !ToolExecutionResult {
        const self: *VisionAgentToolRuntime = @ptrCast(@alignCast(raw));
        self.execution_count += 1;
        var effective_request = request;
        effective_request.result_allocator = self.result_allocator_override orelse
            request.result_allocator;
        const result = try tool_runtime.executeToolCallAuthorized(
            self.context(),
            effective_request,
        );
        self.result_count += 1;
        return result;
    }

    fn context(self: *VisionAgentToolRuntime) tool_runtime.Context {
        return .{
            .workspace_root = self.workspace_root,
            .ignored_list_entries = &.{},
            .max_list_entries = 100,
            .max_read_file_bytes = 64 * 1024,
            .max_read_file_lines = 400,
            .max_read_file_line_len = 2000,
            .max_command_output_bytes = 64 * 1024,
            .max_tool_result_bytes = 64 * 1024,
            .api_key = "key",
            .agent_stream_provider = self.agent_stream_provider,
            .model = "anthropic/claude-opus-4.6",
            .gateway_retry_count = 1,
            .gateway_chat_url = "https://example.invalid",
            .agent_step_limit = 8,
            .tool_registry = .{ .tools = vision_agent_test_tools[0..] },
            .permission_mode = .ask,
            .permission_grants = &.{},
            .permission_rules = .{},
            .worker = &self.worker,
            .background = &self.background,
            .session = &self.session,
            .session_allocator = self.alloc,
            .context_limits = .{ .image_adapter_output_bytes = .{
                .value = .{ .bytes = 64 * 1024 },
                .source = .command_line,
            } },
            .context_registry = .{ .default_provider = builtin_context.provider },
            .lifecycle_scope = .{
                .kind = .interactive,
                .workspace_root = self.workspace_root,
                .session_id = self.session_id,
            },
            .output_chunk_ctx = undefined,
            .on_output_chunk = discardVisionToolOutput,
            .background_url_ctx = undefined,
            .on_background_url_ready = discardVisionBackgroundUrl,
        };
    }
};

fn discardVisionToolOutput(
    _: *anyopaque,
    _: ?types.ToolLifecycleId,
    _: command_output_content.Stream,
    _: []const u8,
) anyerror!void {}

fn discardVisionBackgroundUrl(_: *anyopaque, _: u64, _: []const u8) void {}

const test_tools = [_]tool_dispatch.Tool{
    builtin_tools.list_files,
    builtin_tools.glob_files,
    builtin_tools.grep_files,
    builtin_tools.read_file,
    builtin_tools.write_file,
    builtin_tools.edit_file,
    builtin_tools.delete_file,
    builtin_tools.rename_file,
    builtin_tools.copy_file,
    builtin_tools.create_folder,
    builtin_tools.file_info,
    builtin_tools.memory,
    builtin_tools.semantic_search,
    builtin_tools.open_file,
    builtin_tools.web_fetch,
    builtin_tools.web_search,
    builtin_tools.terminal,
    builtin_tools.skill,
    builtin_tools.install_skill,
    builtin_tools.subagent,
    builtin_tools.mcp_search_tools,
    builtin_tools.mcp_select_tool,
    builtin_tools.ask_user_question,
    builtin_tools.read_tool_result,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };

fn testExecutionAuthority(call: ToolCall) command_admission.ToolExecutionAuthority {
    if (!std.mem.eql(u8, call.name, "terminal")) return .ordinary;
    return .{ .run_command = .{ .shell_allowed = .{
        .fingerprint = .{
            .command = call.arguments_json,
            .resolved_cwd = "",
            .background = false,
            .target_os = builtin.os.tag,
        },
        .source = .interactive_once,
    } } };
}

pub const FakeCompletion = struct {
    status: std.http.Status = .ok,
    err_body: ?[]const u8 = null,
    retry_after_seconds: ?u64 = null,
    pre_send_error: ?anyerror = null,
    stream_error: ?anyerror = null,
    stream_error_after_chunks: ?anyerror = null,
    stream_error_after_tool_starts: ?anyerror = null,
    chunks: []const []const u8 = &.{},
    reasoning_chunks: []const []const u8 = &.{},
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    streamed_tool_starts: []const ToolCall = &.{},
    provider_result_identity_failure: ?types.ProviderResultIdentityFailure = null,
    provider_failure_detail: ?[]const u8 = null,
    finish_reason: ?types.ProviderFinishReason = null,
    omit_finish: bool = false,
    usage: types.Usage = .{},
    delivery_ambiguous: bool = false,
    pause_before_output: bool = false,
    cancel_before_output: bool = false,
    cancel_after_chunks: bool = false,
    cancel_during_tool_stream: bool = false,
};

pub const FakeGateway = struct {
    alloc: Allocator,
    completions: []const FakeCompletion,
    index: usize = 0,
    request_bodies: std.ArrayList([]u8) = .empty,
    request_models: std.ArrayList([]u8) = .empty,
    request_api_keys: std.ArrayList([]u8) = .empty,
    request_session_ids: std.ArrayList(?[]u8) = .empty,
    recovery_pause_flag: ?*std.atomic.Value(bool) = null,

    pub fn init(alloc: Allocator, completions: []const FakeCompletion) FakeGateway {
        return .{ .alloc = alloc, .completions = completions };
    }

    pub fn deinit(self: *FakeGateway) void {
        for (self.request_bodies.items) |body| self.alloc.free(body);
        self.request_bodies.deinit(self.alloc);
        for (self.request_models.items) |model| self.alloc.free(model);
        self.request_models.deinit(self.alloc);
        for (self.request_api_keys.items) |api_key| self.alloc.free(api_key);
        self.request_api_keys.deinit(self.alloc);
        for (self.request_session_ids.items) |session_id| {
            if (session_id) |id| self.alloc.free(id);
        }
        self.request_session_ids.deinit(self.alloc);
    }

    pub fn provider(self: *FakeGateway) agent_stream_provider.Provider {
        var result = builtin_gateway.agent_stream_provider;
        result.context = self;
        result.stream_fn = fakeGatewayStream;
        return result;
    }

    fn stream(
        self: *FakeGateway,
        alloc: Allocator,
        request: agent_stream_provider.Request,
    ) !agent_stream_provider.Result {
        try self.request_bodies.append(self.alloc, try self.alloc.dupe(u8, request.payload));
        try self.request_models.append(self.alloc, try self.alloc.dupe(u8, request.model));
        try self.request_api_keys.append(self.alloc, try self.alloc.dupe(u8, request.api_key));
        const session_id = if (request.session_id) |id| try self.alloc.dupe(u8, id) else null;
        errdefer if (session_id) |id| self.alloc.free(id);
        try self.request_session_ids.append(self.alloc, session_id);
        if (self.index >= self.completions.len) return error.TestUnexpectedGatewayRequest;
        const completion = self.completions[self.index];
        self.index += 1;

        if (completion.pre_send_error) |err| {
            recordNetworkFailureEvidence(request, err);
            return err;
        }
        request.delivery.markPossiblySent();

        if (completion.stream_error) |err| {
            recordNetworkFailureEvidence(request, err);
            return err;
        }

        if (completion.pause_before_output) {
            if (self.recovery_pause_flag) |flag| flag.store(true, .seq_cst);
            request.cancel_flag.store(true, .seq_cst);
            return error.Cancelled;
        }
        if (completion.cancel_before_output) {
            request.cancel_flag.store(true, .seq_cst);
            return .{ .status = .ok };
        }

        if (request.on_reasoning_chunk) |reasoning| {
            for (completion.reasoning_chunks) |chunk| reasoning(request.callback_ctx, chunk);
        }
        for (completion.chunks) |chunk| {
            request.on_content_chunk(request.callback_ctx, chunk);
        }
        if (completion.cancel_after_chunks) request.cancel_flag.store(true, .seq_cst);
        if (completion.stream_error_after_chunks) |err| {
            recordNetworkFailureEvidence(request, err);
            return err;
        }
        if (request.on_tool_start) |start| {
            for (completion.streamed_tool_starts) |call| {
                start(request.callback_ctx, call.id, call.name, null);
            }
        }
        if (completion.stream_error_after_tool_starts) |err| {
            recordNetworkFailureEvidence(request, err);
            return err;
        }
        if (completion.cancel_during_tool_stream) {
            request.cancel_flag.store(true, .seq_cst);
            return error.Cancelled;
        }
        if (completion.status != .ok) {
            const err_body = if (completion.err_body) |body| try alloc.dupe(u8, body) else null;
            const diagnostics = gateway_failure_diagnostics.collect(alloc, request.payload, err_body);
            return .{
                .status = completion.status,
                .err_body = err_body,
                .retry_after_seconds = completion.retry_after_seconds,
                .failure_schema = diagnostics.schema,
                .failure_request_shape = diagnostics.request_shape,
                .ownership = .owned,
            };
        }

        return .{
            .status = .ok,
            .completion = .{
                .content = completion.content,
                .tool_calls = completion.tool_calls,
                .provider_result_identity_failure = completion.provider_result_identity_failure,
                .provider_failure_detail = completion.provider_failure_detail,
                .delivery_ambiguous = completion.delivery_ambiguous,
                .finish_reason = if (completion.omit_finish)
                    null
                else
                    completion.finish_reason orelse if (completion.tool_calls.len > 0) .tool_calls else .stop,
                .usage = completion.usage,
            },
            .generation_origin = "https://ai-gateway.vercel.sh",
        };
    }

    fn recordNetworkFailureEvidence(
        request: agent_stream_provider.Request,
        err: anyerror,
    ) void {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
    }
};

pub const ModelCapabilityOverride = struct {
    model: []const u8,
    capabilities: model_capabilities.Capabilities,
};

fn fakeGatewayStream(
    context: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider.Request,
) !agent_stream_provider.Result {
    const gateway: *FakeGateway = @ptrCast(@alignCast(context.?));
    return gateway.stream(alloc, request);
}

pub const FakeExecPlan = union(enum) {
    result: ToolExecutionResult,
    err: anyerror,
};

pub const ExecuteDelegate = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, ToolExecutionRequest) anyerror!ToolExecutionResult,
    set_agent_stream_provider: ?*const fn (*anyopaque, agent_stream_provider.Provider) void = null,
};

pub const PermissionRequestOverride = struct {
    context: *anyopaque,
    request_fn: *const fn (
        *anyopaque,
        Allocator,
        ToolCall,
        permission_auto_classifier.ReviewTurnContext,
        PermissionMode,
        []const PermissionGrant,
        ?runtime_tool_contracts.LiveToolAuthority,
        ?runtime_tool_contracts.LivePermissionRevalidation,
        []const []const u8,
    ) anyerror!command_admission.PermissionOutcome,
};

pub const ToolExecutionOverride = struct {
    context: *anyopaque,
    execute_fn: *const fn (
        *anyopaque,
        ToolExecutionRequest,
    ) anyerror!ToolExecutionResult,
};

fn captureReviewAuthority(
    alloc: Allocator,
    review_turn: permission_auto_classifier.ReviewTurnContext,
) ![]u8 {
    var captured: std.ArrayList(u8) = .empty;
    errdefer captured.deinit(alloc);
    if (review_turn.current_root_request.len > 0) {
        try captured.appendSlice(alloc, review_turn.current_root_request);
        try captured.append(alloc, '\n');
    }
    return captured.toOwnedSlice(alloc);
}

pub const FakeAgentRuntimeDeps = struct {
    alloc: Allocator,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    live_tool_authority: ?runtime_deps.LiveToolAuthorityProvider = null,
    tool_activity_recorder: ?runtime_deps.ToolActivityRecorder = null,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    context_registry: ?context_contract.Registry = null,
    context_enabled: bool = false,
    execute_mutex: std.Io.Mutex = .init,
    log: std.ArrayList([]u8) = .empty,
    texts: std.ArrayList([]u8) = .empty,
    system_notices: std.ArrayList([]u8) = .empty,
    interactive_notices: std.ArrayList(types.SemanticNotice) = .empty,
    context_notices: std.ArrayList([]u8) = .empty,
    route_recovery_statuses: std.ArrayList(types.RouteRecoveryStatus) = .empty,
    permission_names: std.ArrayList([]u8) = .empty,
    permission_call_ids: std.ArrayList([]u8) = .empty,
    permission_user_intent_contexts: std.ArrayList([]u8) = .empty,
    permission_review_models: std.ArrayList([]u8) = .empty,
    permission_review_target_call_ids: std.ArrayList([]u8) = .empty,
    permission_review_origins: std.ArrayList(permission_auto_classifier.ReviewOrigin) = .empty,
    permission_review_phases: std.ArrayList(permission_auto_classifier.AutoPermissionPhase) = .empty,
    permission_review_root_authority_counts: std.ArrayList(usize) = .empty,
    permission_review_feedback_counts: std.ArrayList(usize) = .empty,
    permission_review_pending_call_counts: std.ArrayList(usize) = .empty,
    executed_names: std.ArrayList([]u8) = .empty,
    executed_call_ids: std.ArrayList([]u8) = .empty,
    rejected_names: std.ArrayList([]u8) = .empty,
    inner_usage_names: std.ArrayList([]u8) = .empty,
    inner_usages: std.ArrayList(types.ToolUsage) = .empty,
    validated_names: std.ArrayList([]u8) = .empty,
    availability_checked_names: std.ArrayList([]u8) = .empty,
    execution_classification_complete: std.ArrayList(bool) = .empty,
    last_validated_arguments: ?[]u8 = null,
    last_permission_arguments: ?[]u8 = null,
    last_executed_arguments: ?[]u8 = null,
    last_execute_root_user_intent_context: ?[]u8 = null,
    last_execute_root_user_messages: std.ArrayList([]u8) = .empty,
    last_execute_root_user_evidence_complete: bool = false,
    propagated_grants: std.ArrayList(PermissionGrant) = .empty,
    event_grants: std.ArrayList(PermissionGrant) = .empty,
    last_execute_grants: std.ArrayList(PermissionGrant) = .empty,
    last_live_authority_generation: ?u64 = null,
    last_live_authority_tool_count: usize = 0,
    last_live_authority_integration_count: usize = 0,
    last_live_authority_rule_count: usize = 0,
    last_live_authority_grant_count: usize = 0,
    last_frozen_file_grants: std.ArrayList(PermissionGrant) = .empty,
    permission_decisions: []const ToolPermissionDecision = &.{},
    permission_auto_review_results: []const ?permission_auto_classifier.Result = &.{},
    permission_denial_reasons: []const types.ToolPermissionDenialReason = &.{},
    permission_feedback: []const []const u8 = &.{},
    permission_errors: []const ?anyerror = &.{},
    permission_human_approvals: []const command_admission.HumanApprovalProvenance = &.{},
    permission_request_override: ?PermissionRequestOverride = null,
    permission_wait_index: ?usize = null,
    permission_waiting: ?*std.atomic.Value(bool) = null,
    permission_release: ?*std.atomic.Value(bool) = null,
    tool_execution_override: ?ToolExecutionOverride = null,
    permission_failure_names: []const []const u8 = &.{},
    permission_index: usize = 0,
    exec_plans: []const FakeExecPlan = &.{},
    execute_delegate: ?ExecuteDelegate = null,
    exec_index: usize = 0,
    successful_effect_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    execute_timeout_started_ms: std.ArrayList(?i64) = .empty,
    permission_target: []const u8 = "/tmp/workspace/file.txt",
    resolve_permission_target: bool = false,
    tool_display_target: ?[]const u8 = null,
    tool_display_target_after_execute: ?[]const u8 = null,
    tool_display_target_resolve_count: usize = 0,
    swap_link_on_permission: ?[]const u8 = null,
    swap_link_target_on_permission: ?[]const u8 = null,
    swap_link_on_execute_name: ?[]const u8 = null,
    swap_link_on_execute: ?[]const u8 = null,
    swap_link_target_on_execute: ?[]const u8 = null,
    static_context_text: ?[]const u8 = null,
    parent_turn_context_text: ?[]const u8 = null,
    parent_turn_context_texts: []const []const u8 = &.{},
    parent_turn_context_index: usize = 0,
    parent_turn_context_after_execute: ?[]const u8 = null,
    parent_turn_context_sequence: ?u64 = null,
    parent_turn_prepare_count: usize = 0,
    parent_turn_ack_count: usize = 0,
    parent_turn_last_ack_sequence: u64 = 0,
    parent_turn_last_ack_prepare_count: usize = 0,
    parent_turn_ack_contract_valid: bool = true,
    runtime_context_text: ?[]const u8 = null,
    runtime_context_texts: []const []const u8 = &.{},
    runtime_context_index: usize = 0,
    runtime_context_error: ?anyerror = null,
    last_execute_grant_count: usize = 0,
    command_complete_count: usize = 0,
    route_recovery_clear_count: usize = 0,
    finish_event_count: usize = 0,
    finish_event_attempt_count: usize = 0,
    finish_event_error: ?anyerror = null,
    finalization_count: usize = 0,
    finalized_turn_id: u64 = 0,
    finalized_outcome: ?types.TurnPresentationOutcome = null,
    finalized_disposition: ?types.ProviderCompletionDisposition = null,
    finalization_error: ?anyerror = null,
    finish_assistant_text: ?[]u8 = null,
    finish_summary: ?types.TurnSummary = null,
    finish_projection: ?types.FinishedPromptProjection = null,
    finish_terminal_outcome: ?types.TurnPresentationOutcome = null,
    history_assistant_text: ?[]u8 = null,
    history_propagation_count: usize = 0,
    history_propagation_error: ?anyerror = null,
    background_history_log_path: ?[]u8 = null,
    background_event_log_path: ?[]u8 = null,
    history_turns: std.ArrayList(HistoryTurn) = .empty,
    interrupted_history_count: usize = 0,
    interrupted_event_count: usize = 0,
    interrupted_tool_name: ?[]u8 = null,
    http_status: ?std.http.Status = null,
    http_detail: ?[]u8 = null,
    http_credential_source: ?types.CredentialSource = null,
    diff_count: usize = 0,
    diff_preview: ?[]u8 = null,
    token_updates: std.ArrayList(types.TurnTokenProgress) = .empty,
    lifecycle_events: std.ArrayList(types.ToolLifecycleEvent) = .empty,
    cancel_on_text: ?*std.atomic.Value(bool) = null,
    cancel_on_text_match: ?[]const u8 = null,
    cancel_on_auto_retry_status: ?*std.atomic.Value(bool) = null,
    cancel_on_auto_retry_attempt: ?usize = null,
    cancel_on_permission: ?*std.atomic.Value(bool) = null,
    cancel_on_permission_name: ?[]const u8 = null,
    cancel_on_execute: ?*std.atomic.Value(bool) = null,
    cancel_on_execute_name: ?[]const u8 = null,
    cancel_on_execute_index: ?usize = null,
    cancel_on_execute_delay_ms: u64 = 0,
    ordinary_cancel_on_execute_name: ?[]const u8 = null,
    session_context: ?*session_runtime.SessionRuntime = null,
    validation_not_registered_names: []const []const u8 = &.{},
    validation_failure_names: []const []const u8 = &.{},
    validation_results: []const ?[]const u8 = &.{},
    validation_result_index: usize = 0,
    validation_error: ?anyerror = null,
    availability_failure_names: []const []const u8 = &.{},
    workspace_root: []const u8 = "/tmp/workspace",
    committed_publication_report: SecondaryPublicationReport = .{
        .diff = .published,
        .tracker = .published,
    },
    stream_output_token_error: ?anyerror = null,
    fail_status_finished: bool = false,
    command_replay_output: ?[]const u8 = null,
    command_replay_capability: ?*session_child_store.SessionChildCapability = null,
    last_file_request_allocators_distinct: bool = false,
    route_recovery_decisions: []const runtime_deps.RouteRecoveryDecision = &.{},
    enable_route_recovery: bool = true,
    route_recovery_index: usize = 0,
    route_recovery_count: usize = 0,
    last_route_recovery_replay_safe: bool = false,
    last_route_recovery_fast_mode: bool = false,
    last_route_recovery_finish_reason: ?types.ProviderFinishReason = null,
    last_route_recovery_unsafe_reason: ?types.RouteRecoveryUnsafeReason = null,
    capability_overrides: []const ModelCapabilityOverride = &.{},
    available_capability_overrides: []const ModelCapabilityOverride = &.{},
    capability_queries: std.ArrayList([]u8) = .empty,
    cancel_on_capability_resolution: ?*std.atomic.Value(bool) = null,
    cancel_after_capability_resolution: ?*std.atomic.Value(bool) = null,
    credential_refresh_tokens: []const []const u8 = &.{},
    credential_refresh_index: usize = 0,
    credential_refresh_sources: std.ArrayList(types.CredentialSource) = .empty,
    credential_refresh_modes: std.ArrayList(runtime_deps.CredentialRefreshMode) = .empty,
    credential_refresh_error: ?anyerror = null,
    last_credential_refresh_expected_account: ?[]const u8 = null,
    enable_interactive_notices: bool = false,
    enable_recovery_checkpoint: bool = false,
    recovery_checkpoints: std.ArrayList(session_codec.RecoveryCheckpoint) = .empty,
    recovery_checkpoint_error: ?anyerror = null,
    cancel_on_recovery_reservation: ?*std.atomic.Value(bool) = null,
    pause_on_auto_retry_status: bool = false,
    recovery_pause_flag: ?*std.atomic.Value(bool) = null,

    pub fn init(alloc: Allocator) FakeAgentRuntimeDeps {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *FakeAgentRuntimeDeps) void {
        freeStringList(self.alloc, &self.log);
        freeStringList(self.alloc, &self.texts);
        freeStringList(self.alloc, &self.system_notices);
        for (self.interactive_notices.items) |notice| types.freeSemanticNotice(self.alloc, notice);
        self.interactive_notices.deinit(self.alloc);
        freeStringList(self.alloc, &self.context_notices);
        self.route_recovery_statuses.deinit(self.alloc);
        freeStringList(self.alloc, &self.permission_names);
        freeStringList(self.alloc, &self.permission_call_ids);
        freeStringList(self.alloc, &self.permission_user_intent_contexts);
        freeStringList(self.alloc, &self.permission_review_models);
        freeStringList(self.alloc, &self.permission_review_target_call_ids);
        self.permission_review_origins.deinit(self.alloc);
        self.permission_review_phases.deinit(self.alloc);
        self.permission_review_root_authority_counts.deinit(self.alloc);
        self.permission_review_feedback_counts.deinit(self.alloc);
        self.permission_review_pending_call_counts.deinit(self.alloc);
        freeStringList(self.alloc, &self.executed_names);
        freeStringList(self.alloc, &self.executed_call_ids);
        freeStringList(self.alloc, &self.rejected_names);
        freeStringList(self.alloc, &self.inner_usage_names);
        self.inner_usages.deinit(self.alloc);
        freeStringList(self.alloc, &self.validated_names);
        freeStringList(self.alloc, &self.availability_checked_names);
        self.execution_classification_complete.deinit(self.alloc);
        if (self.last_validated_arguments) |value| self.alloc.free(value);
        if (self.last_permission_arguments) |value| self.alloc.free(value);
        if (self.last_executed_arguments) |value| self.alloc.free(value);
        if (self.last_execute_root_user_intent_context) |value| self.alloc.free(value);
        freeStringList(self.alloc, &self.last_execute_root_user_messages);
        freeGrantList(self.alloc, &self.propagated_grants);
        freeGrantList(self.alloc, &self.event_grants);
        freeGrantList(self.alloc, &self.last_execute_grants);
        freeGrantList(self.alloc, &self.last_frozen_file_grants);
        self.execute_timeout_started_ms.deinit(self.alloc);
        if (self.finish_assistant_text) |value| self.alloc.free(value);
        if (self.history_assistant_text) |value| self.alloc.free(value);
        if (self.background_history_log_path) |value| self.alloc.free(value);
        if (self.background_event_log_path) |value| self.alloc.free(value);
        for (self.history_turns.items) |turn| types.freeHistoryTurn(self.alloc, turn);
        self.history_turns.deinit(self.alloc);
        if (self.interrupted_tool_name) |value| self.alloc.free(value);
        if (self.http_detail) |value| self.alloc.free(value);
        if (self.diff_preview) |value| self.alloc.free(value);
        self.token_updates.deinit(self.alloc);
        for (self.lifecycle_events.items) |event| {
            worker_runtime.freeToolLifecycleEvent(self.alloc, event);
        }
        self.lifecycle_events.deinit(self.alloc);
        freeStringList(self.alloc, &self.capability_queries);
        self.credential_refresh_sources.deinit(self.alloc);
        self.credential_refresh_modes.deinit(self.alloc);
        for (self.recovery_checkpoints.items) |*checkpoint| checkpoint.deinit(self.alloc);
        self.recovery_checkpoints.deinit(self.alloc);
    }

    pub fn deps(self: *FakeAgentRuntimeDeps) AgentRuntimeDeps {
        return .{
            .ctx = self,
            .agent_stream_provider = self.agent_stream_provider,
            .tool_registry = self.tool_registry,
            .live_tool_authority = self.live_tool_authority,
            .tool_activity_recorder = self.tool_activity_recorder,
            .context_registry = self.context_registry,
            .context_enabled = self.context_enabled,
            .finalize_turn = finalizeTurn,
            .prepare_parent_turn_context = prepareParentTurnContext,
            .acknowledge_parent_turn_context = acknowledgeParentTurnContext,
            .append_runtime_context = appendRuntimeContext,
            .append_static_context = appendStaticContext,
            .validate_tool_call = validateToolCall,
            .check_tool_availability = checkToolAvailability,
            .request_tool_permission = requestPermission,
            .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
            .describe_tool_action = describeAction,
            .describe_tool_action_completed = describeCompleted,
            .describe_tool_action_denied = describeDenied,
            .permission_target_for_call = permissionTarget,
            .execute_tool_call = execute,
            .publish_committed_file_handoff = publishCommittedFileHandoff,
            .propagate_history_turn = propagateHistory,
            .recovery_checkpoint = if (self.enable_recovery_checkpoint) .{
                .set = setRecoveryCheckpoint,
            } else null,
            .propagate_grant = @This().propagateGrant,
            .push_event = pushEvent,
            .push_text = pushText,
            .push_tool_lifecycle = pushToolLifecycle,
            .push_diff_block = pushDiff,
            .push_system_notice = systemNotice,
            .push_interactive_notice = if (self.enable_interactive_notices) interactiveNotice else null,
            .push_context_notice = contextNotice,
            .push_route_recovery_status = routeRecoveryStatus,
            .push_command_output_complete = commandOutputComplete,
            .push_http_error = httpError,
            .refresh_gateway_credential = refreshGatewayCredential,
            .request_route_recovery = if (self.enable_route_recovery) requestRouteRecovery else null,
            .available_model_capabilities = availableModelCapabilities,
            .resolve_model_capabilities = resolveModelCapabilities,
            .format_tool_execution_error = formatError,
            .record_tool_call_rejected = recordRejected,
            .report_inner_tool_usage = reportCapturedInnerToolUsage,
        };
    }

    fn setRecoveryCheckpoint(
        raw: *anyopaque,
        checkpoint: session_codec.RecoveryCheckpoint,
    ) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        if (self.recovery_checkpoint_error) |err| return err;
        try self.recovery_checkpoints.append(
            self.alloc,
            try checkpoint.dupe(self.alloc),
        );
        if (checkpoint.outstanding_reservation) {
            if (self.cancel_on_recovery_reservation) |cancel_flag| {
                cancel_flag.store(true, .seq_cst);
            }
        }
    }

    fn resolveModelCapabilities(raw: *anyopaque, _: Allocator, model: []const u8) !model_capabilities.Capabilities {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try self.capability_queries.append(self.alloc, try self.alloc.dupe(u8, model));
        if (self.cancel_on_capability_resolution) |cancel_flag| {
            cancel_flag.store(true, .seq_cst);
            return error.Cancelled;
        }
        const capabilities = blk: {
            for (self.capability_overrides) |override| {
                if (std.mem.eql(u8, override.model, model)) break :blk override.capabilities;
            }
            break :blk model_capabilities.capabilitiesForModel(model);
        };
        if (self.cancel_after_capability_resolution) |cancel_flag| {
            cancel_flag.store(true, .seq_cst);
        }
        return capabilities;
    }

    fn availableModelCapabilities(raw: *anyopaque, model: []const u8) model_capabilities.Capabilities {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        for (self.available_capability_overrides) |override| {
            if (std.mem.eql(u8, override.model, model)) return override.capabilities;
        }
        return model_capabilities.capabilitiesForModel(model);
    }

    fn refreshGatewayCredential(raw: *anyopaque, alloc: Allocator, source: types.CredentialSource, mode: runtime_deps.CredentialRefreshMode, expected_account_id: ?[]const u8) !?[]u8 {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try self.credential_refresh_sources.append(self.alloc, source);
        try self.credential_refresh_modes.append(self.alloc, mode);
        self.last_credential_refresh_expected_account = expected_account_id;
        if (self.credential_refresh_error) |err| return err;
        if (self.credential_refresh_index >= self.credential_refresh_tokens.len) return null;
        const token = self.credential_refresh_tokens[self.credential_refresh_index];
        self.credential_refresh_index += 1;
        return try alloc.dupe(u8, token);
    }

    fn requestRouteRecovery(raw: *anyopaque, _: Allocator, request: runtime_deps.RouteRecoveryRequest) !runtime_deps.RouteRecoveryDecision {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.route_recovery_count += 1;
        self.last_route_recovery_replay_safe = request.replay_safe;
        self.last_route_recovery_fast_mode = request.fast_mode;
        self.last_route_recovery_finish_reason = request.finish_reason;
        self.last_route_recovery_unsafe_reason = request.unsafe_no_retry_reason;
        if (self.route_recovery_index < self.route_recovery_decisions.len) {
            const decision = self.route_recovery_decisions[self.route_recovery_index];
            self.route_recovery_index += 1;
            return decision;
        }
        return .cancel;
    }

    fn finalizeTurn(raw: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.finalization_count += 1;
        self.finalized_turn_id = turn_id;
        self.finalized_outcome = outcome;
        self.finalized_disposition = disposition;
        try self.record("event:turn_finished", .{});
        if (self.finalization_error) |err| return err;
    }

    fn appendStaticContext(raw: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        if (self.static_context_text) |text| {
            try messages.append(arena, .{ .role = .system, .content = try arena.dupe(u8, text) });
        }
    }

    fn record(self: *FakeAgentRuntimeDeps, comptime fmt: []const u8, args: anytype) !void {
        try self.log.append(self.alloc, try std.fmt.allocPrint(self.alloc, fmt, args));
    }

    fn prepareParentTurnContext(raw: *anyopaque, arena: Allocator) !?runtime_deps.PreparedParentTurnContext {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.parent_turn_prepare_count += 1;
        const text = if (self.parent_turn_context_texts.len > 0) blk: {
            const index = @min(self.parent_turn_context_index, self.parent_turn_context_texts.len - 1);
            self.parent_turn_context_index += 1;
            break :blk self.parent_turn_context_texts[index];
        } else self.parent_turn_context_text orelse return null;
        const acknowledgements = try arena.alloc(runtime_deps.ParentTurnDeliveryAck, 1);
        acknowledgements[0] = .{
            .child_id = try arena.dupe(u8, "child"),
            .target_session_id = try arena.dupe(u8, "parent"),
            .through_sequence = self.parent_turn_context_sequence orelse
                @as(u64, @intCast(self.parent_turn_prepare_count)),
            .delivery_id = try arena.dupe(u8, "delivery"),
            .start_offset = 0,
            .end_offset = 0,
            .total_bytes = 0,
        };
        return .{
            .content = try arena.dupe(u8, text),
            .acknowledgements = acknowledgements,
        };
    }

    fn acknowledgeParentTurnContext(
        raw: *anyopaque,
        _: Allocator,
        acknowledgements: []const runtime_deps.ParentTurnDeliveryAck,
    ) void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.parent_turn_ack_count += acknowledgements.len;
        self.parent_turn_ack_contract_valid = self.parent_turn_ack_contract_valid and
            self.parent_turn_prepare_count == self.parent_turn_last_ack_prepare_count + 1;
        self.parent_turn_last_ack_prepare_count = self.parent_turn_prepare_count;
        for (acknowledgements) |ack| {
            self.parent_turn_ack_contract_valid = self.parent_turn_ack_contract_valid and
                std.mem.eql(u8, ack.child_id, "child") and
                std.mem.eql(u8, ack.target_session_id, "parent") and
                std.mem.eql(u8, ack.delivery_id, "delivery");
        }
        if (acknowledgements.len != 0) {
            self.parent_turn_last_ack_sequence = acknowledgements[acknowledgements.len - 1].through_sequence;
        }
    }

    fn appendRuntimeContext(raw: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        if (self.runtime_context_error) |err| return err;
        if (self.runtime_context_texts.len > 0) {
            const index = @min(self.runtime_context_index, self.runtime_context_texts.len - 1);
            const text = self.runtime_context_texts[index];
            self.runtime_context_index += 1;
            try messages.append(arena, .{ .role = .system, .content = try arena.dupe(u8, text) });
        } else if (self.runtime_context_text) |text| {
            try messages.append(arena, .{ .role = .system, .content = try arena.dupe(u8, text) });
        }
    }

    fn validateToolCall(raw: *anyopaque, arena: Allocator, call: ToolCall) !ToolCallValidationResult {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try self.validated_names.append(self.alloc, try self.alloc.dupe(u8, call.name));
        if (self.validation_error) |err| return err;
        if (self.last_validated_arguments) |value| self.alloc.free(value);
        self.last_validated_arguments = try self.alloc.dupe(u8, call.arguments_json);
        try self.record("validate:{s}", .{call.name});
        if (self.validation_result_index < self.validation_results.len) {
            const result = self.validation_results[self.validation_result_index];
            self.validation_result_index += 1;
            if (result) |failure| {
                return .{ .failure = try arena.dupe(u8, failure) };
            }
        }
        for (self.validation_not_registered_names) |name| {
            if (std.mem.eql(u8, name, call.name)) return .not_registered;
        }
        for (self.validation_failure_names) |name| {
            if (std.mem.eql(u8, name, call.name)) {
                return .{ .failure = try std.fmt.allocPrint(arena, "{s} arguments failed registered-tool validation", .{call.name}) };
            }
        }
        return .valid;
    }

    fn checkToolAvailability(raw: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try self.availability_checked_names.append(self.alloc, try self.alloc.dupe(u8, call.name));
        try self.record("availability:{s}", .{call.name});
        for (self.availability_failure_names) |name| {
            if (std.mem.eql(u8, name, call.name)) {
                return try arena.dupe(u8, tool_dispatch.web_search_unavailable_message);
            }
        }
        return null;
    }

    fn scriptedAutoReview(
        arena: Allocator,
        results: []const ?permission_auto_classifier.Result,
        index: usize,
    ) !?permission_auto_classifier.Result {
        if (index >= results.len) return null;
        const result = results[index] orelse return null;
        return permission_auto_classifier.Result{
            .risk = result.risk,
            .authorization = result.authorization,
            .decision = result.decision,
            .rationale = try arena.dupe(u8, result.rationale),
        };
    }

    fn requestPermission(
        raw: *anyopaque,
        arena: Allocator,
        call: ToolCall,
        review_turn: permission_auto_classifier.ReviewTurnContext,
        permission_mode: PermissionMode,
        local_grants: []const PermissionGrant,
        live_authority: ?runtime_tool_contracts.LiveToolAuthority,
        revalidation: ?runtime_tool_contracts.LivePermissionRevalidation,
        advertised_dynamic_tool_names: []const []const u8,
    ) !command_admission.PermissionOutcome {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        if (self.permission_request_override) |override| {
            return override.request_fn(
                override.context,
                arena,
                call,
                review_turn,
                permission_mode,
                local_grants,
                live_authority,
                revalidation,
                advertised_dynamic_tool_names,
            );
        }
        try self.permission_names.append(self.alloc, try self.alloc.dupe(u8, call.name));
        try self.permission_call_ids.append(self.alloc, try self.alloc.dupe(u8, call.id));
        try self.permission_user_intent_contexts.append(
            self.alloc,
            try captureReviewAuthority(self.alloc, review_turn),
        );
        try self.permission_review_models.append(
            self.alloc,
            try self.alloc.dupe(u8, review_turn.model),
        );
        try self.permission_review_target_call_ids.append(
            self.alloc,
            try self.alloc.dupe(u8, review_turn.target_call_id),
        );
        try self.permission_review_origins.append(self.alloc, review_turn.origin);
        try self.permission_review_phases.append(
            self.alloc,
            review_turn.auto_permission_phase,
        );
        try self.permission_review_root_authority_counts.append(
            self.alloc,
            @intFromBool(review_turn.current_root_request.len > 0),
        );
        try self.permission_review_feedback_counts.append(
            self.alloc,
            0,
        );
        try self.permission_review_pending_call_counts.append(
            self.alloc,
            review_turn.pending_assistant.tool_calls.len,
        );
        if (self.last_permission_arguments) |value| self.alloc.free(value);
        self.last_permission_arguments = try self.alloc.dupe(u8, call.arguments_json);
        try self.record("permission:{s}", .{call.name});
        for (self.permission_failure_names) |name| {
            if (std.mem.eql(u8, name, call.name)) {
                return .{ .tool_failure = try arena.dupe(
                    u8,
                    "permission preflight failed",
                ) };
            }
        }
        const permission_index = self.permission_index;
        const decision = if (permission_index < self.permission_decisions.len)
            self.permission_decisions[permission_index]
        else
            ToolPermissionDecision.once;
        const feedback = if (permission_index < self.permission_feedback.len)
            self.permission_feedback[permission_index]
        else
            "";
        const denial_reason = if (decision.isDenied() and permission_index < self.permission_denial_reasons.len)
            self.permission_denial_reasons[permission_index]
        else
            null;
        const auto_review_result = try scriptedAutoReview(
            arena,
            self.permission_auto_review_results,
            permission_index,
        );
        self.permission_index += 1;
        if (self.permission_wait_index == permission_index) {
            if (self.permission_waiting) |waiting| waiting.store(true, .seq_cst);
            const release = self.permission_release orelse
                return error.PermissionPromptUnavailable;
            while (!release.load(.seq_cst)) {
                std.Thread.yield() catch std.atomic.spinLoopHint();
            }
        }
        const execution_authority = if (decision.isDenied()) null else if (revalidation) |request| switch (request) {
            .action => |action| action.authority,
        } else if (file_mutation_contract.isToolName(call.name))
            command_admission.ToolExecutionAuthority{
                .file_mutation = try self.fileMutationAuthorization(
                    arena,
                    call,
                    permission_mode,
                    local_grants,
                ),
            }
        else if (try self.testVisionPathAuthority(arena, call)) |authority|
            command_admission.ToolExecutionAuthority{ .vision_paths = authority }
        else
            testExecutionAuthority(call);
        if (self.swap_link_on_permission) |link| {
            if (self.swap_link_target_on_permission) |target| {
                var cwd = std.Io.Dir.cwd();
                cwd.deleteFile(io_mod.getIo(), link) catch {};
                try cwd.symLink(io_mod.getIo(), target, link, .{ .is_directory = true });
                self.swap_link_on_permission = null;
                self.swap_link_target_on_permission = null;
            }
        }
        if (self.cancel_on_permission) |flag| {
            const should_cancel = if (self.cancel_on_permission_name) |name|
                std.mem.eql(u8, name, call.name)
            else
                true;
            if (should_cancel) flag.store(true, .seq_cst);
        }
        if (permission_index < self.permission_errors.len) {
            if (self.permission_errors[permission_index]) |err| return err;
        }
        return .{
            .decision = decision,
            .execution_authority = execution_authority,
            .human_approval = if (permission_index < self.permission_human_approvals.len)
                self.permission_human_approvals[permission_index]
            else if (decision == .once)
                .once
            else if (decision == .always)
                .always
            else
                .none,
            .denial_reason = denial_reason,
            .feedback = if (feedback.len == 0) null else try arena.dupe(u8, feedback),
            .auto_review_result = auto_review_result,
        };
    }

    fn testVisionPathAuthority(
        self: *FakeAgentRuntimeDeps,
        arena: Allocator,
        call: ToolCall,
    ) !?command_admission.VisionPathExecutionAuthority {
        if (!std.mem.eql(u8, call.name, "vision")) return null;
        const request = runtime_tool_contracts.vision.parse_vision_request(
            arena,
            call.arguments_json,
        ) catch return null;
        defer request.deinit(arena);
        if (request.paths() == null) return null;

        var targets = try permissions.permissionTargetsForCall(
            arena,
            self.workspace_root,
            call,
            .none,
        );
        defer targets.deinit(arena);
        const execution_targets = try arena.alloc(
            command_admission.VisionPathExecutionTarget,
            targets.items.len,
        );
        for (targets.items, execution_targets) |target, *execution_target| {
            if (!std.mem.eql(u8, target.role, "image")) {
                return error.InvalidToolArguments;
            }
            var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), target.path, .{
                .allow_directory = false,
                .follow_symlinks = false,
            });
            defer file.close(io_mod.getIo());
            const stat = try file.stat(io_mod.getIo());
            execution_target.* = .{
                .canonical_path = try arena.dupe(u8, target.path),
                .identity = pathing.fileIdentity(
                    try pathing.descriptorDevice(file.handle),
                    stat,
                ),
            };
        }
        return .{ .targets = execution_targets };
    }

    fn fileMutationAuthorization(
        self: *FakeAgentRuntimeDeps,
        arena: Allocator,
        call: ToolCall,
        permission_mode: PermissionMode,
        local_grants: []const PermissionGrant,
    ) !file_mutation_contract.FileExecutionAuthorization {
        const kind: file_mutation_contract.Kind =
            if (std.mem.eql(u8, call.name, "write_file"))
                .write
            else if (std.mem.eql(u8, call.name, "edit_file"))
                .edit
            else
                return error.InvalidToolArguments;
        const tool = switch (kind) {
            .write => &builtin_tools.write_file,
            .edit => &builtin_tools.edit_file,
        };
        const decoded = try tool.decode(
            .{ .allocator = arena },
            call.arguments_json,
        );
        const input: file_mutation_contract.FileMutationInput = switch (decoded) {
            .failure => return error.InvalidToolArguments,
            .input => |tool_input| blk: {
                break :blk switch (kind) {
                    .write => testing_write_file.takeFileMutationInput(
                        tool_input,
                        arena,
                    ),
                    .edit => testing_edit_file.takeFileMutationInput(
                        tool_input,
                        arena,
                    ),
                };
            },
        };
        const evaluated = try permissions.evaluateFileMutationTargets(
            arena,
            self.workspace_root,
            input,
            permission_mode,
            .{},
            &.{},
            local_grants,
        );
        const policy_targets = switch (evaluated) {
            .evaluated => |targets| targets,
            .policy_denied, .target_resolution_failure => try syntheticFileMutationTargets(
                arena,
                self.permission_target,
            ),
        };
        const authorization: file_mutation_contract.FileExecutionAuthorization = .{
            .input = input,
            .policy_targets = policy_targets,
            .grant_offer = try permissions.structuredFileGrantOffer(
                arena,
                self.workspace_root,
                call.name,
                policy_targets,
            ),
            .approval_intent = .mutation,
        };
        for (self.last_frozen_file_grants.items) |grant| {
            self.alloc.free(grant.tool_name);
            self.alloc.free(grant.target_path);
        }
        self.last_frozen_file_grants.clearRetainingCapacity();
        for (authorization.grant_offer.?.grants) |grant| {
            try appendGrant(
                self.alloc,
                &self.last_frozen_file_grants,
                grant,
            );
        }
        return authorization;
    }

    fn resolveToolActionDisplayTarget(raw: *anyopaque, arena: Allocator, _: ToolCall) !?[]const u8 {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.tool_display_target_resolve_count += 1;
        const value = self.tool_display_target orelse return null;
        return try arena.dupe(u8, value);
    }

    fn describeAction(_: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, _: []const []const u8) ![]const u8 {
        return if (display_target) |target|
            std.fmt.allocPrint(arena, "start {s} {s}", .{ call.name, target })
        else
            std.fmt.allocPrint(arena, "start {s}", .{call.name});
    }

    fn describeCompleted(_: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, _: []const []const u8) ![]const u8 {
        return if (display_target) |target|
            std.fmt.allocPrint(arena, "done {s} {s}", .{ call.name, target })
        else
            std.fmt.allocPrint(arena, "done {s}", .{call.name});
    }

    fn describeDenied(_: *anyopaque, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s} {s}", .{ label, call.name });
    }

    fn permissionTarget(raw: *anyopaque, arena: Allocator, call: ToolCall, _: []const []const u8) ![]const u8 {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        if (self.resolve_permission_target) {
            return permissions.permissionTargetForCall(
                arena,
                self.permission_target,
                call,
                .none,
            );
        }
        return arena.dupe(u8, self.permission_target);
    }

    fn execute(
        raw: *anyopaque,
        request: ToolExecutionRequest,
    ) !ToolExecutionResult {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        if (self.tool_execution_override) |override| {
            return override.execute_fn(override.context, request);
        }
        const execute_delegate = self.execute_delegate;
        const call = request.call;
        var plan: FakeExecPlan = undefined;
        var should_cancel = false;
        var should_return_ordinary_cancel = false;
        var swap_link: ?[]const u8 = null;
        var swap_target: ?[]const u8 = null;
        {
            self.execute_mutex.lockUncancelable(io_mod.getIo());
            defer self.execute_mutex.unlock(io_mod.getIo());

            try self.executed_names.append(self.alloc, try self.alloc.dupe(u8, call.name));
            try self.executed_call_ids.append(self.alloc, try self.alloc.dupe(u8, call.id));
            try self.execution_classification_complete.append(
                self.alloc,
                request.classification_complete,
            );
            try self.execute_timeout_started_ms.append(
                self.alloc,
                request.command_timeout_started_ms,
            );
            if (self.last_executed_arguments) |value| self.alloc.free(value);
            self.last_executed_arguments = try self.alloc.dupe(u8, call.arguments_json);
            if (self.last_execute_root_user_intent_context) |value| self.alloc.free(value);
            self.last_execute_root_user_intent_context = try self.alloc.dupe(
                u8,
                request.root_user_intent_context,
            );
            freeStringList(self.alloc, &self.last_execute_root_user_messages);
            self.last_execute_root_user_messages = .empty;
            for (request.root_user_messages) |message| {
                try self.last_execute_root_user_messages.append(
                    self.alloc,
                    try self.alloc.dupe(u8, message),
                );
            }
            self.last_execute_root_user_evidence_complete =
                request.root_user_evidence_complete;
            try self.record("execute:{s}", .{call.name});
            self.last_execute_grant_count = request.session_grants.len;
            for (self.last_execute_grants.items) |grant| {
                self.alloc.free(grant.tool_name);
                self.alloc.free(grant.target_path);
            }
            self.last_execute_grants.clearRetainingCapacity();
            for (request.session_grants) |grant| {
                try self.last_execute_grants.append(self.alloc, .{
                    .tool_name = try self.alloc.dupe(u8, grant.tool_name),
                    .target_path = try self.alloc.dupe(u8, grant.target_path),
                });
            }
            if (request.live_authority) |live| {
                self.last_live_authority_generation = live.generation;
                self.last_live_authority_tool_count = live.tools.len;
                self.last_live_authority_integration_count = live.integrations.len;
                self.last_live_authority_rule_count = live.rules.rules.len;
                self.last_live_authority_grant_count = live.grants.len;
            } else {
                self.last_live_authority_generation = null;
                self.last_live_authority_tool_count = 0;
                self.last_live_authority_integration_count = 0;
                self.last_live_authority_rule_count = 0;
                self.last_live_authority_grant_count = 0;
            }
            const execution_index = self.exec_index;
            plan = if (execution_index < self.exec_plans.len)
                self.exec_plans[execution_index]
            else
                .{ .result = .{ .model_output = "ok" } };
            self.exec_index += 1;
            should_cancel = (self.cancel_on_execute_index == null or
                self.cancel_on_execute_index.? == execution_index) and if (self.cancel_on_execute != null)
                if (self.cancel_on_execute_name) |name|
                    std.mem.eql(u8, name, call.name)
                else
                    true
            else
                false;
            should_return_ordinary_cancel = if (self.ordinary_cancel_on_execute_name) |name|
                std.mem.eql(u8, name, call.name)
            else
                false;
            if (self.swap_link_on_execute_name) |name| {
                if (std.mem.eql(u8, name, call.name)) {
                    swap_link = self.swap_link_on_execute;
                    swap_target = self.swap_link_target_on_execute;
                    self.swap_link_on_execute_name = null;
                    self.swap_link_on_execute = null;
                    self.swap_link_target_on_execute = null;
                }
            }
            if (self.parent_turn_context_after_execute) |text| {
                self.parent_turn_context_text = text;
                self.parent_turn_context_texts = &.{};
                self.parent_turn_context_after_execute = null;
            }
        }

        if (swap_link) |link| {
            const target = swap_target orelse return error.InvalidToolArguments;
            var cwd = std.Io.Dir.cwd();
            cwd.deleteFile(io_mod.getIo(), link) catch {};
            try cwd.symLink(io_mod.getIo(), target, link, .{ .is_directory = true });
        }
        if (should_return_ordinary_cancel) return error.Cancelled;
        if (should_cancel) {
            if (self.cancel_on_execute_delay_ms > 0) {
                io_mod.sleep(self.cancel_on_execute_delay_ms * std.time.ns_per_ms);
            }
            self.cancel_on_execute.?.store(true, .seq_cst);
        }
        if (execute_delegate) |delegate| {
            return delegate.run(delegate.ctx, request);
        }
        var result = switch (plan) {
            .result => |result| result,
            .err => |err| return err,
        };
        if (self.command_replay_output) |output| {
            const capture = try command_replay_store.Capture.create(
                request.result_allocator,
                1,
                self.command_replay_capability,
            );
            capture.appendAccepted(request.result_allocator, .stdout, output);
            capture.seal(request.result_allocator);
            result.command_replay_capture = capture;
        }
        if (result.committed_file_handoff != null) {
            self.last_file_request_allocators_distinct =
                request.call_allocator.ptr != request.result_allocator.ptr or
                request.call_allocator.vtable != request.result_allocator.vtable;
            result.model_output = try request.result_allocator.dupe(
                u8,
                result.model_output,
            );
            if (result.prepared_result_memory) |*memory| {
                if (memory.output_handle) |handle| {
                    memory.output_handle = try request.result_allocator.dupe(
                        u8,
                        handle,
                    );
                }
                if (memory.preview) |preview| {
                    memory.preview = try request.result_allocator.dupe(
                        u8,
                        preview,
                    );
                }
            }
        }
        if (result.status == .success and !result.cancelled) {
            _ = self.successful_effect_count.fetchAdd(1, .seq_cst);
        }
        if (self.tool_display_target_after_execute) |target| {
            self.tool_display_target = target;
        }
        return result;
    }

    fn publishCommittedFileHandoff(
        raw: *anyopaque,
        _: file_mutation.CommittedFileHandoff,
    ) SecondaryPublicationReport {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.record("publish:committed_file", .{}) catch
            return .{ .diff = .failed, .tracker = .failed };
        return self.committed_publication_report;
    }

    fn reportCapturedInnerToolUsage(raw: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.inner_usage_names.append(self.alloc, self.alloc.dupe(u8, tool_name) catch return) catch return;
        self.inner_usages.append(self.alloc, usage) catch return;
    }

    fn recordRejected(raw: *anyopaque, _: Allocator, call: ToolCall, _: []const u8, _: ?[]const u8) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try self.rejected_names.append(self.alloc, try self.alloc.dupe(u8, call.name));
        try self.record("rejected:{s}", .{call.name});
    }

    fn propagateHistory(raw: *anyopaque, turn: HistoryTurn) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.history_propagation_count += 1;
        if (self.history_propagation_error) |err| return err;
        const copied_turn = try types.dupeHistoryTurn(self.alloc, turn);
        errdefer types.freeHistoryTurn(self.alloc, copied_turn);
        try self.history_turns.append(self.alloc, copied_turn);
        switch (turn) {
            .assistant => |entry| {
                if (self.history_assistant_text) |value| self.alloc.free(value);
                self.history_assistant_text = try self.alloc.dupe(u8, entry.assistant);
                try self.record("history:assistant", .{});
            },
            .background_command => |entry| {
                if (self.background_history_log_path) |value| self.alloc.free(value);
                self.background_history_log_path = try self.alloc.dupe(u8, entry.log_path);
                try self.record("history:background", .{});
            },
            .interrupted => |entry| {
                self.interrupted_history_count += 1;
                if (entry.tool_call) |tool_call| {
                    if (self.interrupted_tool_name) |value| self.alloc.free(value);
                    self.interrupted_tool_name = try self.alloc.dupe(u8, tool_call.name);
                }
                try self.record("history:interrupted", .{});
            },
            .compacted_summary => {},
        }
    }

    fn propagateGrant(raw: *anyopaque, tool_name: []const u8, target_path: []const u8) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try appendGrant(self.alloc, &self.propagated_grants, .{
            .tool_name = @constCast(tool_name),
            .target_path = @constCast(target_path),
        });
        try self.record("propagate_grant:{s}:{s}", .{ tool_name, target_path });
    }

    fn pushEvent(raw: *anyopaque, event: WorkerEvent) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        defer worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        switch (event) {
            .clear_route_recovery_status => {
                self.route_recovery_clear_count += 1;
                try self.record("event:clear_route_recovery_status", .{});
            },
            .finish_prompt => |finished| {
                self.finish_event_attempt_count += 1;
                if (self.finish_event_error) |err| return err;
                self.finish_event_count += 1;
                self.finish_summary = finished.summary;
                self.finish_projection = finished.terminal_projection;
                self.finish_terminal_outcome = finished.terminal_outcome;
                switch (finished.turn) {
                    .assistant => |entry| {
                        if (self.finish_assistant_text) |value| self.alloc.free(value);
                        self.finish_assistant_text = try self.alloc.dupe(u8, entry.assistant);
                    },
                    .background_command => |entry| {
                        if (self.background_event_log_path) |value| self.alloc.free(value);
                        self.background_event_log_path = try self.alloc.dupe(u8, entry.log_path);
                    },
                    .interrupted => self.interrupted_event_count += 1,
                    .compacted_summary => {},
                }
                try self.record("event:finish_prompt", .{});
            },
            .session_grant => |grant| {
                try appendGrant(self.alloc, &self.event_grants, grant);
                try self.record("event:session_grant:{s}:{s}", .{ grant.tool_name, grant.target_path });
            },
            .turn_token_update => |update| {
                if (update.output_tokens > 0) {
                    if (self.stream_output_token_error) |err| return err;
                }
                try self.token_updates.append(self.alloc, update);
                try self.record(
                    "event:turn_tokens:{d}:{d}:{s}:{s}",
                    .{
                        update.input_tokens,
                        update.output_tokens,
                        if (update.input_exact) "exact" else "approx",
                        if (update.output_exact) "exact" else "approx",
                    },
                );
            },
            else => {},
        }
    }

    fn pushText(raw: *anyopaque, emission: runtime_deps.TextEmission) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        const text = switch (emission) {
            .assistant_source => return,
            .assistant_rendered => |text| text,
            .operational => |text| text,
        };
        try self.texts.append(self.alloc, try self.alloc.dupe(u8, text));
        if (self.cancel_on_text) |flag| {
            const should_cancel = if (self.cancel_on_text_match) |expected|
                std.mem.eql(u8, expected, text)
            else
                true;
            if (should_cancel) flag.store(true, .seq_cst);
        }
        if (std.mem.eql(u8, text, "\n")) {
            try self.record("text:newline", .{});
        } else {
            try self.record("text:{s}", .{text});
        }
    }

    fn pushToolLifecycle(
        raw: *anyopaque,
        event: types.ToolLifecycleEvent,
    ) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        switch (event) {
            .provisional, .authoritative_started => try self.record("status:started", .{}),
            .terminal => |terminal| {
                try self.record("status:finished:{s}", .{terminal.outcome.summary});
                if (self.fail_status_finished) return error.TestStatusPublicationFailure;
            },
            .progress, .turn_finished => {},
        }
        const owned = try worker_runtime.dupeToolLifecycleEvent(self.alloc, event);
        errdefer worker_runtime.freeToolLifecycleEvent(self.alloc, owned);
        try self.lifecycle_events.append(self.alloc, owned);
    }

    fn pushDiff(raw: *anyopaque, payload: DiffEntryPayload) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.diff_count += 1;
        if (self.diff_preview) |value| self.alloc.free(value);
        self.diff_preview = try self.alloc.dupe(u8, payload.preview);
        try self.record("diff", .{});
    }

    fn systemNotice(raw: *anyopaque, text: []const u8) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try self.system_notices.append(self.alloc, try self.alloc.dupe(u8, text));
        try self.record("system_notice:{s}", .{text});
    }

    fn interactiveNotice(raw: *anyopaque, notice: types.SemanticNotice) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        const owned = try types.dupeSemanticNotice(self.alloc, notice);
        errdefer types.freeSemanticNotice(self.alloc, owned);
        try self.record("interactive_notice:{s}:{s}", .{ notice.topic, notice.body });
        try self.interactive_notices.append(self.alloc, owned);
    }

    fn contextNotice(raw: *anyopaque, text: []const u8) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try self.context_notices.append(self.alloc, try self.alloc.dupe(u8, text));
        try self.record("context_notice:{s}", .{text});
    }

    fn routeRecoveryStatus(raw: *anyopaque, status: types.RouteRecoveryStatus) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        try self.route_recovery_statuses.append(self.alloc, status);
        if (status.kind == .auto_retry) {
            if (self.cancel_on_auto_retry_status) |flag| {
                if (self.cancel_on_auto_retry_attempt == null or
                    self.cancel_on_auto_retry_attempt.? == status.failed_attempt)
                {
                    flag.store(true, .seq_cst);
                }
            }
        }
        if (self.pause_on_auto_retry_status and status.kind == .auto_retry) {
            if (self.recovery_pause_flag) |flag| flag.store(true, .seq_cst);
        }
        var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
        try self.record("route_recovery_status:{s}", .{status.label(&label_buf)});
    }

    fn commandOutputComplete(raw: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.command_complete_count += 1;
        if (lifecycle_id) |id| {
            try self.record("command_output_complete:{d}:{s}", .{ id.turn_id, id.call_id });
        } else {
            try self.record("command_output_complete", .{});
        }
    }

    fn httpError(raw: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
        const self: *FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        self.http_status = status;
        self.http_credential_source = credential_source;
        if (self.http_detail) |value| self.alloc.free(value);
        self.http_detail = try self.alloc.dupe(u8, detail);
        try self.record("http_error", .{});
    }

    fn formatError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        return std.fmt.allocPrint(arena, "Tool {s} failed: {s}", .{ tool_name, @errorName(err) });
    }
};

pub const PromptFixture = struct {
    images: [0]types.ImageAttachment = .{},
    history: [0]HistoryTurn = .{},
    grants: [0]PermissionGrant = .{},
    cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    workspace_root: []const u8 = "/tmp/workspace",

    pub fn job(self: *PromptFixture) QueuedPrompt {
        return .{
            .prompt = @constCast("user prompt"),
            .images = self.images[0..],
            .model = @constCast("anthropic/claude-opus-4.6"),
            .api_key = @constCast("key"),
            .permission_mode = .ask,
            .history = self.history[0..],
            .grants = self.grants[0..],
        };
    }

    pub fn config(self: *PromptFixture) Config {
        return .{
            .system_prompt = "system",
            .gateway_retry_count = 1,
            .max_provider_attempts = model_response_recovery.default_max_provider_attempts,
            .gateway_chat_url = "https://example.invalid",
            .gateway_tools_json = "[]",
            .agent_step_limit = 8,
            .cancel_flag = &self.cancel_flag,
            .workspace_root = self.workspace_root,
        };
    }
};

pub const PreToolUseTestHandler = struct {
    pub const Action = union(enum) {
        continue_,
        rewrite: []const u8,
        block: []const u8,
        fail,
        cancel_error,
        cancel_continue,
    };

    alloc: Allocator,
    action: Action,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    calls: usize = 0,
    seen_arguments: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *PreToolUseTestHandler) void {
        freeStringList(self.alloc, &self.seen_arguments);
    }

    fn run(
        raw: *anyopaque,
        input: lifecycle_hooks.PreToolUseInput,
    ) lifecycle_hooks.HandlerError!lifecycle_hooks.PreToolUseAction {
        const self: *PreToolUseTestHandler = @ptrCast(@alignCast(raw));
        self.calls += 1;
        const arguments = self.alloc.dupe(u8, input.arguments_json) catch
            return error.Failed;
        self.seen_arguments.append(self.alloc, arguments) catch {
            self.alloc.free(arguments);
            return error.Failed;
        };

        return switch (self.action) {
            .continue_ => .continue_,
            .rewrite => |arguments_json| .{ .rewrite_arguments = arguments_json },
            .block => |reason| .{ .block = reason },
            .fail => error.Failed,
            .cancel_error => blk: {
                if (self.cancel_flag) |flag| flag.store(true, .seq_cst);
                break :blk error.Cancelled;
            },
            .cancel_continue => blk: {
                if (self.cancel_flag) |flag| flag.store(true, .seq_cst);
                break :blk .continue_;
            },
        };
    }
};

pub const StopTestHandler = struct {
    pub const Action = union(enum) {
        allow,
        continue_once: []const u8,
        fail,
        cancel_error,
        cancel_allow,
        cancel_continue: []const u8,
    };

    alloc: Allocator,
    action: Action,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    calls: usize = 0,
    seen_text: ?[]u8 = null,
    seen_step_index: usize = 0,
    seen_can_continue: bool = false,
    seen_disposition: ?types.ProviderCompletionDisposition = null,

    pub fn deinit(self: *StopTestHandler) void {
        if (self.seen_text) |text| self.alloc.free(text);
    }

    fn run(
        raw: *anyopaque,
        input: lifecycle_hooks.StopInput,
    ) lifecycle_hooks.HandlerError!lifecycle_hooks.StopAction {
        const self: *StopTestHandler = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.seen_text) |text| self.alloc.free(text);
        self.seen_text = self.alloc.dupe(u8, input.assistant_text) catch
            return error.Failed;
        self.seen_step_index = input.step_index;
        self.seen_can_continue = input.can_continue;
        self.seen_disposition = input.provider_disposition;

        return switch (self.action) {
            .allow => .allow,
            .continue_once => |context| .{ .continue_once = context },
            .fail => error.Failed,
            .cancel_error => error.Cancelled,
            .cancel_allow => blk: {
                if (self.cancel_flag) |flag| flag.store(true, .seq_cst);
                break :blk .allow;
            },
            .cancel_continue => |context| blk: {
                if (self.cancel_flag) |flag| flag.store(true, .seq_cst);
                break :blk .{ .continue_once = context };
            },
        };
    }
};

pub fn registerPreToolUseTestHandler(
    runtime: *lifecycle_hooks.Runtime,
    handler: *PreToolUseTestHandler,
) !lifecycle_hooks.RuntimeView {
    try runtime.registerPreToolUse(.{
        .name = "test-pre-tool-use",
        .ctx = handler,
        .run = PreToolUseTestHandler.run,
    });
    return runtime.freeze();
}

pub fn registerStopTestHandler(
    runtime: *lifecycle_hooks.Runtime,
    handler: *StopTestHandler,
) !lifecycle_hooks.RuntimeView {
    try runtime.registerStop(.{
        .name = "test-stop",
        .ctx = handler,
        .run = StopTestHandler.run,
    });
    return runtime.freeze();
}

pub fn testLifecycleContext(
    view: lifecycle_hooks.RuntimeView,
    alloc: Allocator,
    workspace_root: []const u8,
) runtime_lifecycle.LifecycleContext {
    return .{
        .view = view,
        .scope = .{
            .kind = .interactive,
            .workspace_root = workspace_root,
        },
        .outcome_allocator = alloc,
    };
}

pub fn runFakePrompt(gateway: *FakeGateway, hooks: *FakeAgentRuntimeDeps, config: Config, job: QueuedPrompt) !void {
    return runFakePromptWithLifecycle(
        gateway,
        hooks,
        config,
        job,
        testLifecycleContext(
            lifecycle_hooks.RuntimeView.empty(),
            hooks.alloc,
            config.workspace_root,
        ),
    );
}

pub fn runFakePromptWithLifecycle(
    gateway: *FakeGateway,
    hooks: *FakeAgentRuntimeDeps,
    config: Config,
    job: QueuedPrompt,
    lifecycle: runtime_lifecycle.LifecycleContext,
) !void {
    hooks.workspace_root = config.workspace_root;
    var deps = hooks.deps();
    deps.agent_stream_provider = gateway.provider();
    if (hooks.execute_delegate) |delegate| {
        if (delegate.set_agent_stream_provider) |set_provider| {
            set_provider(delegate.ctx, deps.agent_stream_provider);
        }
    }
    try runtime_orchestrator.processQueuedPrompt(
        &deps,
        null,
        lifecycle,
        config,
        job,
    );
}

fn syntheticFileMutationTargets(
    arena: Allocator,
    target_path: []const u8,
) !file_mutation_contract.PolicyEvaluatedFileTargets {
    const canonical_target_path = try arena.dupe(u8, target_path);
    const items = try arena.alloc(file_mutation_contract.EvaluatedPermissionTarget, 1);
    items[0] = .{
        .kind = .target,
        .disposition = .target_entry,
        .path_end = canonical_target_path.len,
        .expected_identity = null,
        .rule = .ask,
        .session_grant_allowed = true,
    };
    return .{
        .canonical_target_path = canonical_target_path,
        .anchor = .{
            .scope = .workspace,
            .path_end = canonical_target_path.len,
            .identity = .{
                .device = 0,
                .inode = 0,
                .kind = .directory,
            },
            .relative_components = &.{},
        },
        .traversal_directories = &.{},
        .items = items,
        .prompt_required = true,
    };
}

fn freeStringList(alloc: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| alloc.free(item);
    list.deinit(alloc);
}

fn appendGrant(alloc: Allocator, list: *std.ArrayList(PermissionGrant), grant: PermissionGrant) !void {
    try list.append(alloc, .{
        .tool_name = try alloc.dupe(u8, grant.tool_name),
        .target_path = try alloc.dupe(u8, grant.target_path),
    });
}

fn freeGrantList(alloc: Allocator, list: *std.ArrayList(PermissionGrant)) void {
    for (list.items) |grant| {
        alloc.free(grant.tool_name);
        alloc.free(grant.target_path);
    }
    list.deinit(alloc);
}

pub fn expectBodyContains(gateway: *const FakeGateway, index: usize, needle: []const u8) !void {
    try std.testing.expect(index < gateway.request_bodies.items.len);
    try std.testing.expect(std.mem.find(u8, gateway.request_bodies.items[index], needle) != null);
}

pub fn expectBodyNotContains(gateway: *const FakeGateway, index: usize, needle: []const u8) !void {
    try std.testing.expect(index < gateway.request_bodies.items.len);
    try std.testing.expect(std.mem.find(u8, gateway.request_bodies.items[index], needle) == null);
}
pub fn expectBodyContainsInOrder(gateway: *const FakeGateway, index: usize, needles: []const []const u8) !void {
    try std.testing.expect(index < gateway.request_bodies.items.len);
    const body = gateway.request_bodies.items[index];
    var cursor: usize = 0;
    for (needles) |needle| {
        const found = std.mem.indexOfPos(u8, body, cursor, needle) orelse return error.TestExpectedBodyNeedleMissing;
        cursor = found + needle.len;
    }
}

fn countPromptContentText(value: std.json.Value, needle: []const u8) usize {
    return switch (value) {
        .string => |text| std.mem.count(u8, text, needle),
        .array => |array| count: {
            var total: usize = 0;
            for (array.items) |part| {
                if (part != .object) continue;
                if (part.object.get("text")) |text| {
                    if (text == .string) total += std.mem.count(u8, text.string, needle);
                }
                if (part.object.get("output")) |output| {
                    if (output == .object) {
                        if (output.object.get("value")) |value_text| {
                            if (value_text == .string) total += std.mem.count(u8, value_text.string, needle);
                        }
                    }
                }
            }
            break :count total;
        },
        else => 0,
    };
}

pub fn countPromptEntryText(entry: std.json.Value, needle: []const u8) usize {
    if (entry != .object) return 0;
    const content = entry.object.get("content") orelse return 0;
    return countPromptContentText(content, needle);
}
pub fn expectGatewayPromptFinalUserText(gateway: *const FakeGateway, index: usize, expected_text: []const u8) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expect(prompt.len > 0);
    var i = prompt.len;
    while (i > 0) {
        i -= 1;
        const entry = prompt[i];
        if (entry != .object) continue;
        const role = entry.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, gateway_json.roleName(.user))) continue;
        try std.testing.expectEqual(@as(usize, 1), countPromptEntryText(entry, expected_text));
        return;
    }
    return error.TestExpectedPromptMessageMissing;
}

pub fn countText(hooks: *const FakeAgentRuntimeDeps, needle: []const u8) usize {
    var count: usize = 0;
    for (hooks.texts.items) |text| {
        if (std.mem.eql(u8, text, needle)) count += 1;
    }
    return count;
}

pub fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |found| {
        count += 1;
        pos = found + needle.len;
    }
    return count;
}

pub fn readTraceFile(alloc: Allocator, trace_path: []const u8, max_bytes: usize) ![]u8 {
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &trace_file, max_bytes);
}

pub fn textContains(hooks: *const FakeAgentRuntimeDeps, needle: []const u8) bool {
    for (hooks.texts.items) |text| {
        if (std.mem.find(u8, text, needle) != null) return true;
    }
    return false;
}

pub fn logIndex(hooks: *const FakeAgentRuntimeDeps, needle: []const u8) ?usize {
    for (hooks.log.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry, needle)) return i;
    }
    return null;
}

pub fn toolCall(id: []const u8, name: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}
