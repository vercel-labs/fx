const std = @import("std");
const skill_contract = @import("../skills/skill_contract.zig");
const builtin = @import("builtin");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const host_mod = @import("../hosts/host.zig");
const command_contract = @import("../execution/command_contract.zig");
const command_environment = @import("../execution/command_environment.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const result_commit = @import("result_commit.zig");
const vision_executor = @import("../agent/runtime/vision_executor.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const glob_pattern = @import("../workspace/glob_pattern.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const permission_request = @import("../permissions/permission_request.zig");
const command_admission = @import("../permissions/command_admission.zig");
const pathing = @import("../workspace/pathing.zig");
const execution_router = @import("../execution/router.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_model_contract = @import("../subagent/model_contract.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_tool_provider = @import("../subagent/tool_provider.zig");
const session_runtime = @import("../session/session.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_codec_mod = @import("../session/session_codec.zig");
const session_child_store = @import("../session/session_child_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const mcp_access_policy = @import("../mcp/access_policy.zig");
const tool_admission = @import("tool_admission.zig");
const tool_args = @import("tool_args.zig");
const command_result_mapping = @import("command_result_mapping.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_specs = @import("tool_specs.zig");
const tool_result_errors = @import("tool_result_errors.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const file_mutation_execution = @import("file_mutation_execution.zig");
const tool_mcp_registry = @import("tool_mcp_registry.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const capability_retrieval = @import("capability_retrieval.zig");
const tool_mcp_feature_dispatch = @import("tool_mcp_feature_dispatch.zig");
const tool_presentation = @import("tool_presentation.zig");
const shell_impl = @import("../../tools/shell/shell.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const web_fetch_runtime = @import("web_fetch_runtime.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_fetch_artifacts = @import("../session/web_fetch_artifacts.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_set = @import("../gateway/provider_set.zig");
const credential_authority = @import("../auth/credential_authority.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const context_contract = @import("../workspace/context_contract.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const test_builtin_gateway = if (builtin.is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};
const test_browser_workspace_tools = if (builtin.is_test)
    @import("../../builtins/browser_workspace_tools.zig")
else
    struct {};
const js_host_workspace = @import("../hosts/js_host_workspace.zig");

const agent_test_support = if (builtin.is_test)
    @import("../agent/runtime/tests/support.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;

const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const subagent_tool_name = "subagent";
const ToolExecutionResult = tool_contracts.ToolExecutionResult;
const SessionRuntime = session_runtime.SessionRuntime;
const WorkerRuntime = worker_runtime.WorkerRuntime;
const max_file_mutation_success_bytes: usize = 8 * 1024;

const helpers = struct {
    const requiredStringArg = tool_args.requiredStringArg;
    const parseToolArgsObject = tool_args.parseToolArgsObject;
};

const optionalIntArg = tool_args.optionalIntArg;
const parseToolArgsObject = helpers.parseToolArgsObject;
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const host_capabilities = @import("../hosts/host.zig");
const terminal_client_runtime = @import("../terminal/client.zig");

test {
    _ = tool_admission;
    _ = command_result_mapping;
    _ = @import("../session/command_replay_store.zig");
    _ = @import("../session/result_store.zig");
    _ = file_mutation_execution;
    _ = tool_presentation;
}

pub const Context = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    api_key: []const u8,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    gateway_team: ?[]const u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    provider: model_provider.ProviderId = .gateway,
    provider_capabilities: provider_set.Bundle.Capabilities = .{
        .fx_search = true,
        .vision_fallback = true,
    },
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    secret_store: host_mod.SecretStore = host_mod.unavailable_secret_store,
    model: []const u8,
    permission_review_turn: ?permission_auto_classifier.ReviewTurnContext = null,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    current_turn_messages: []const ChatMessage = &.{},
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8 = "/v1/models",
    agent_step_limit: usize,
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    tool_registry: tool_dispatch.Registry = .{},
    host_tool_provider: ?tool_dispatch.HostToolProvider = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    subagent_caller_id: ?[]const u8 = null,
    permission_mode: PermissionMode,
    permission_grants: []const PermissionGrant,
    session_grants: []const PermissionGrant = &.{},
    permission_rules: types.PermissionRuleSet,
    permission_state_override: ?*const session_permission_state.State = null,
    worker: *WorkerRuntime,
    /// Sole prompt capability admission consults. When null, admission never
    /// prompts: it resolves by rule, automatic review, or fail-closed denial
    /// (e.g. ACP hosts prompt over JSON-RPC by setting this).
    permission_prompter: ?permission_prompter.Prompter = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    session: *SessionRuntime,
    session_allocator: Allocator = std.heap.c_allocator,
    skills_dir: []const u8 = "",
    skill_locations: ?*const skill_contract.Locations = null,
    context_limits: context_limits.Values = .{},
    context_registry: context_contract.Registry,
    context_enabled: bool = true,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: *anyopaque,
    on_output_chunk: command_contract.CommandOutputCallback,
    command_artifact_dir: ?[]const u8 = null,
    tool_result_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    ephemeral_command_replay: ?*command_replay_store.EphemeralStore = null,
    terminal_client: ?*terminal_client_runtime.Runtime = null,
    managed_executions: ?*managed_execution.Runtime = null,
    command_timeout_ms: ?usize = null,
    command_timeout_started_ms: ?i64 = null,
    command_replay_capture: ?*command_replay_store.Capture = null,
    command_replay_unavailable: bool = false,
    tracker: ?*change_tracker.ChangeTracker = null,
    mcp_ctx: ?*anyopaque = null,
    mcp_has_tool: ?tool_mcp_runtime.HasToolFn = null,
    mcp_validate_tool: ?tool_mcp_runtime.ValidateToolFn = null,
    mcp_call_tool: ?tool_mcp_runtime.CallToolFn = null,
    mcp_search_tools: ?tool_mcp_runtime.SearchToolsFn = null,
    mcp_tool_schema: ?tool_mcp_runtime.ToolSchemaFn = null,
    mcp_snapshot_tool: ?tool_mcp_runtime.SnapshotToolFn = null,
    expected_mcp_runtime_generation: ?u64 = null,
    expected_mcp_binding: ?types.McpToolBinding = null,
    mcp_review_schema_json: ?[]const u8 = null,
    mcp_call_feature: ?tool_mcp_runtime.FeatureCallFn = null,
    mcp_access: tool_mcp_runtime.Access = .unrestricted,
    mcp_input_responder: ?tool_mcp_runtime.InputResponder = null,
    mcp_progress_ctx: ?*anyopaque = null,
    on_mcp_progress: ?*const fn (*anyopaque, types.ToolLifecycleId, []const u8) void = null,
    advertised_dynamic_tool_names: []const []const u8 = &.{},
    permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    web_fetch_runtime: ?*web_fetch_runtime.Runtime = null,
    web_fetch_artifact_store: ?*web_fetch_artifacts.Store = null,
    web_fetch_artifact_error: ?anyerror = null,
    web_search_runtime_ready: bool = false,
    web_search_backend: ?tool_dispatch.WebSearchBackend = null,
    web_search_progress_ctx: ?*anyopaque = null,
    on_web_search_progress: ?tool_dispatch.WebSearchProgressFn = null,
    web_fetch_progress_ctx: ?*anyopaque = null,
    on_web_fetch_progress: ?tool_dispatch.WebFetchProgressFn = null,
    workspace_executor: ?js_host_workspace.Executor = null,
    host_sandbox_default: tool_admission.HostSandboxDefault = .none,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    /// False when running outside an interactive TUI (e.g. ACP). Tools
    /// that require a live user (like `ask_user_question`) short-circuit
    /// in that case.
    interactive: bool = true,
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    lifecycle_scope: hooks.Scope = .{
        .kind = .interactive,
        .workspace_root = "",
    },

    /// Projects only the borrowed capabilities consumed by admission.
    pub fn admissionInput(self: Context) tool_admission.Input {
        var input: tool_admission.Input = .{
            .workspace_root = self.workspace_root,
            .access_scope = self.access_scope,
            .permission_review_turn = self.permission_review_turn,
            .permission_grants = self.permission_grants,
            .permission_rules = self.permission_rules,
            .session_permission_state = self.permission_state_override,
            .session_permission_state_provider = .{
                .context = @ptrCast(self.session),
                .snapshot_fn = snapshotSessionPermissionState,
            },
            .tool_registry = self.tool_registry,
            .worker = self.worker,
            .mcp_review_schema_json = self.mcp_review_schema_json,
            .permission_prompter = self.permission_prompter,
            .advertised_dynamic_tool_names = self.advertised_dynamic_tool_names,
            .mcp_runtime = mcpRuntimeCapabilities(self),
            .context_limits = self.context_limits,
            .auto_classifier = self.admissionAutoClassifier(),
            .host_sandbox_default = self.host_sandbox_default,
        };
        if (self.permission_state_override != null) {
            input.session_permission_state_provider = null;
        }
        return input;
    }

    pub fn admissionInputWithLiveAuthority(
        self: Context,
        authority: ?tool_contracts.LiveToolAuthority,
    ) tool_admission.Input {
        var input = self.admissionInput();
        if (authority) |live| {
            input.permission_grants = live.grants;
            input.permission_rules = live.rules;
            input.session_permission_state = live.permission_state;
            if (live.permission_state != null) {
                input.session_permission_state_provider = null;
            }
            input.advertised_dynamic_tool_names = live.integrations;
        }
        return input;
    }

    fn admissionAutoClassifier(self: Context) permission_auto_classifier.Classifier {
        if (self.auto_classifier.enabled()) return self.auto_classifier;
        const provider = self.permission_reviewer_provider orelse
            return permission_auto_classifier.Classifier.disabled();
        return permission_auto_classifier.Classifier.withProvider(provider, .{
            .credential = self.api_key,
            .credential_source = self.credential_source,
            .account_id = self.account_id,
            .tenant = self.gateway_team,
            .endpoint = self.gateway_chat_url,
            .cancel_flag = self.cancel_flag,
            .usage = &self.session.usage,
            .usage_allocator = self.session_allocator,
        });
    }
};

fn snapshotSessionPermissionState(
    raw_session: *anyopaque,
    alloc: Allocator,
) !session_permission_state.State {
    const session: *SessionRuntime = @ptrCast(@alignCast(raw_session));
    return session.snapshotPermissionState(alloc);
}

fn registeredToolSpec(ctx: Context, name: []const u8) ?*const tool_specs.ToolSpec {
    return ctx.tool_registry.lookup(name);
}

fn providerDisablesTool(capabilities: provider_set.Bundle.Capabilities, name: []const u8) bool {
    return std.mem.eql(u8, name, "vision") and
        !capabilities.vision_fallback;
}

pub fn validateToolCall(ctx: Context, arena: Allocator, call: ToolCall) !tool_contracts.ToolCallValidationResult {
    if (providerDisablesTool(ctx.provider_capabilities, call.name)) {
        return .{ .failure = try arena.dupe(u8, "Unsupported tool: vision") };
    }
    const spec = registeredToolSpec(ctx, call.name) orelse {
        return switch (try tool_mcp_runtime.validateAdvertisedDynamicTool(.{
            .is_registered_tool = false,
            .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
            .runtime = mcpRuntimeCapabilities(ctx),
        }, arena, call.name, call.arguments_json)) {
            .valid => |generation| .{ .valid = .{ .mcp_runtime_generation = generation } },
            .invalid => |reason| .{ .failure = reason },
            .not_available => .not_registered,
        };
    };
    switch (spec.executor_kind) {
        // Preserve execution-time argument failures for MCP control tool calls.
        .mcp_select_tool, .mcp_features => return .{ .valid = .{} },
        // File mutation arguments are decoded once by shared permission preflight.
        .write_file, .edit_file => return .{ .valid = .{} },
        else => {},
    }

    var dispatch_ctx = typedDispatchContext(ctx, arena);
    dispatch_ctx.captured_command_host = spec.captured_command_host;
    return switch (try tool_dispatch.validateRegisteredToolCall(dispatch_ctx, ctx.tool_registry, call)) {
        .not_registered => .not_registered,
        .valid => .{ .valid = .{} },
        .failure => |reason| .{ .failure = reason },
    };
}

pub fn checkToolAvailability(ctx: Context, arena: Allocator, call: ToolCall) !?[]const u8 {
    if (providerDisablesTool(ctx.provider_capabilities, call.name)) {
        return try arena.dupe(u8, "Unsupported tool: vision");
    }
    return tool_dispatch.localToolAvailabilityFailureForCall(
        typedDispatchContext(ctx, arena),
        ctx.tool_registry,
        call,
    );
}

pub fn executeToolCallAuthorized(
    ctx: Context,
    request: tool_contracts.ToolExecutionRequest,
) !ToolExecutionResult {
    var replay_continuation_transferred = request.command_replay_capture == null;
    defer if (!replay_continuation_transferred) {
        request.command_replay_capture.?.abort(request.result_allocator);
    };
    var execution_ctx = ctx;
    execution_ctx.skill_locations = request.skill_locations orelse ctx.skill_locations;
    if (request.permission_mode) |permission_mode| {
        execution_ctx.permission_mode = permission_mode;
    }
    if (request.live_authority) |authority| {
        if (!containsName(authority.tools, request.call.name) and
            !containsName(authority.integrations, request.call.name))
        {
            return tool_contracts.failToolExecutionResult(
                error.LiveToolAuthorityUnavailable,
            );
        }
        execution_ctx.permission_mode = authority.permission_mode;
        execution_ctx.permission_grants = authority.grants;
        execution_ctx.session_grants = authority.grants;
        execution_ctx.permission_rules = authority.rules;
        execution_ctx.advertised_dynamic_tool_names = authority.integrations;
        execution_ctx.mcp_access = rebindMcpAuthorityGeneration(
            execution_ctx.mcp_access,
            authority.generation,
        );
    } else {
        execution_ctx.session_grants = request.session_grants;
        execution_ctx.advertised_dynamic_tool_names =
            request.advertised_dynamic_tool_names;
    }
    execution_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    execution_ctx.expected_mcp_runtime_generation = request.expected_mcp_runtime_generation;
    execution_ctx.expected_mcp_binding = request.expected_mcp_binding;
    execution_ctx.current_turn_messages = request.current_turn_messages;
    execution_ctx.output_chunk_lifecycle_id = request.lifecycle_id;
    execution_ctx.command_timeout_started_ms = request.command_timeout_started_ms;
    execution_ctx.command_replay_capture = request.command_replay_capture;
    execution_ctx.command_replay_unavailable = request.command_replay_unavailable;

    const started_at_ms = io_mod.milliTimestamp();
    const uses_file_mutation_contract = if (registeredToolSpec(
        execution_ctx,
        request.call.name,
    )) |spec|
        spec.take_file_mutation_input_fn != null
    else
        false;
    const result = (if (comptime builtin.os.tag == .wasi)
        executeWorkspaceToolCallInner(
            execution_ctx,
            request.result_allocator,
            request.call,
            request.authority,
            request.classification_complete,
        )
    else if (uses_file_mutation_contract)
        file_mutation_execution.execute(.{
            .call_allocator = request.call_allocator,
            .result_allocator = request.result_allocator,
            .call = request.call,
            .authorization = switch (request.authority) {
                .file_mutation => |value| value,
                else => null,
            },
            .maybe_cancel_flag = execution_ctx.cancel_flag,
            .lifecycle_id = request.lifecycle_id,
        })
    else
        executeToolCallInner(
            execution_ctx,
            request.result_allocator,
            request.call,
            request.authority,
            request.classification_complete,
            request.authorized_image_catalog,
        )) catch |err| {
        diagnostics.recordToolCallResult(.{
            .name = request.call.name,
            .arguments_json = request.call.arguments_json,
            .model_output = "",
            .outcome = classifyToolExecutionError(err),
            .started_at_ms = started_at_ms,
        });
        return if (err == error.CancelledBeforeExecution) error.Cancelled else err;
    };
    diagnostics.recordToolCallResult(.{
        .name = request.call.name,
        .arguments_json = request.call.arguments_json,
        .model_output = result.model_output,
        .outcome = classifyReturnedToolCallOutcome(
            uses_file_mutation_contract,
            result,
        ),
        .started_at_ms = started_at_ms,
    });
    if (request.command_replay_capture) |continued| {
        replay_continuation_transferred = result.command_replay_capture == continued;
    }
    return result;
}

fn classifyToolExecutionError(err: anyerror) diagnostics.ToolCallOutcome {
    return switch (err) {
        error.CancelledBeforeExecution => .rejected,
        error.Cancelled => .tool_failed,
        else => .runtime_failed,
    };
}

fn classifyReturnedToolCallOutcome(
    uses_file_mutation_contract: bool,
    result: ToolExecutionResult,
) diagnostics.ToolCallOutcome {
    if (result.status == .success) return .succeeded;
    if (result.command_result_json != null) return .command_failed;
    if (uses_file_mutation_contract) return .rejected;
    return .tool_failed;
}

test "returned tool results retain diagnostic outcome identity" {
    const success = ToolExecutionResult{ .model_output = "ok" };
    const rejection = ToolExecutionResult{ .model_output = "rejected", .status = .failure };
    const command_failure = ToolExecutionResult{
        .model_output = "exit 7",
        .status = .failure,
        .command_result_json = "{\"exit_code\":7}",
    };
    const tool_failure = ToolExecutionResult{ .model_output = "missing", .status = .failure };

    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.succeeded,
        classifyReturnedToolCallOutcome(false, success),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.rejected,
        classifyReturnedToolCallOutcome(true, rejection),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.command_failed,
        classifyReturnedToolCallOutcome(false, command_failure),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.tool_failed,
        classifyReturnedToolCallOutcome(false, tool_failure),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.rejected,
        classifyToolExecutionError(error.CancelledBeforeExecution),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.tool_failed,
        classifyToolExecutionError(error.Cancelled),
    );
    try std.testing.expectEqual(
        diagnostics.ToolCallOutcome.runtime_failed,
        classifyToolExecutionError(error.Unexpected),
    );
}

pub fn executeHostToolCallAuthorized(
    ctx: Context,
    request: tool_contracts.ToolExecutionRequest,
) !ToolExecutionResult {
    const spec = ctx.tool_registry.lookup(request.call.name) orelse
        return error.InvalidToolArguments;
    if (spec.executor_kind != .host) return error.InvalidToolArguments;

    var execution_ctx = ctx;
    if (request.permission_mode) |permission_mode| {
        execution_ctx.permission_mode = permission_mode;
    }
    execution_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    var dispatch_ctx = typedDispatchContextForCall(
        execution_ctx,
        request.result_allocator,
        request.call,
    );
    dispatch_ctx.execution_authority = request.authority;
    var status_detail: ?[]u8 = null;
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        execution_ctx.tool_registry,
        request.call,
        &status_detail,
    );
    var result = toolExecutionResultFromDispatch(dispatched, .{});
    result.status_detail = status_detail;
    return result;
}

fn rebindMcpAuthorityGeneration(
    access: tool_mcp_runtime.Access,
    authority_generation: u64,
) tool_mcp_runtime.Access {
    return switch (access) {
        .scoped => |scope| .{ .scoped = .{
            .captured = scope.captured,
            .admission_authority_generation = scope.admission_authority_generation,
            .live = scope.live,
            .action_authority_generation = authority_generation,
        } },
        else => access,
    };
}

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn executeToolCall(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) !ToolExecutionResult {
    return executeToolCallAuthorized(ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .ordinary,
        .current_turn_messages = ctx.current_turn_messages,
        .session_grants = ctx.session_grants,
        .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
    });
}

const ToolDispatchPrelude = union(enum) {
    completed: ToolExecutionResult,
    registered_static,
    registered_dynamic: tool_dispatch.Tool,
};

fn executeToolCallInner(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    classification_complete: bool,
    authorized_image_catalog: []const types.ImageAttachment,
) !ToolExecutionResult {
    return switch (try resolveToolDispatchPrelude(
        ctx,
        arena,
        call,
        classification_complete,
    )) {
        .completed => |result| return result,
        .registered_static => try executeRegisteredTool(
            ctx,
            arena,
            call,
            authority,
            authorized_image_catalog,
            ctx.tool_registry,
        ),
        .registered_dynamic => |dynamic_tool| blk: {
            const tools = [_]tool_dispatch.Tool{dynamic_tool};
            break :blk try executeRegisteredTool(
                ctx,
                arena,
                call,
                authority,
                authorized_image_catalog,
                .{ .tools = tools[0..] },
            );
        },
    };
}

fn executeWorkspaceToolCallInner(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    classification_complete: bool,
) !ToolExecutionResult {
    if (!classification_complete) {
        if (try checkToolAvailability(ctx, arena, call)) |reason| {
            return semanticFailure(reason);
        }
    }
    const spec = registeredToolSpec(ctx, call.name) orelse
        return semanticFailure(try std.fmt.allocPrint(arena, "Unsupported tool: {s}", .{call.name}));
    if (ctx.tool_registry.tools.len != 1 or
        !std.mem.eql(u8, spec.name, "shell") or
        spec.executor_kind != .run_command or
        spec.runtime_provider != .run_command)
    {
        return semanticFailure(try std.fmt.allocPrint(arena, "Unsupported tool: {s}", .{call.name}));
    }

    var command_backend = RunCommandBackendState{ .runtime = ctx };
    var dispatch_metadata: DispatchMetadata = .{};
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
    dispatch_metadata.attach(&dispatch_ctx);
    dispatch_ctx.execution_authority = authority;
    dispatch_ctx.captured_command_host = spec.captured_command_host;
    dispatch_ctx.run_command_backend = .{
        .ctx = &command_backend,
        .execute_fn = executeRunCommandBackend,
    };
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        ctx.tool_registry,
        call,
        &dispatch_metadata.status_detail,
    );
    if (command_backend.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    var execution = command_backend.completion orelse
        toolExecutionResultFromDispatch(dispatched, dispatch_metadata);
    execution.model_output = dispatched.body;
    if (dispatch_metadata.status_detail) |detail| execution.status_detail = detail;
    return execution;
}

fn resolveToolDispatchPrelude(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    classification_complete: bool,
) !ToolDispatchPrelude {
    if (!classification_complete) {
        if (try checkToolAvailability(ctx, arena, call)) |reason| {
            return .{ .completed = semanticFailure(reason) };
        }
    }
    if (registeredToolSpec(ctx, call.name) != null) return .registered_static;
    const mcp_runtime = mcpRuntimeCapabilities(ctx);
    return switch (tool_mcp_registry.resolve(
        ctx.advertised_dynamic_tool_names,
        mcp_runtime,
        call.name,
    )) {
        .registered => |tool| .{ .registered_dynamic = tool },
        .not_selected => .{ .completed = semanticFailure(
            try tool_mcp_runtime.notSelectedOutput(arena, call.name),
        ) },
        .unsupported => .{ .completed = semanticFailure(
            try std.fmt.allocPrint(arena, "Unsupported tool: {s}", .{call.name}),
        ) },
    };
}

const McpProgressBridge = struct {
    ctx: Context,
};

fn emitMcpProgress(raw_context: *anyopaque, progress: tool_mcp_runtime.Progress) void {
    const bridge: *McpProgressBridge = @ptrCast(@alignCast(raw_context));
    var clipped_buf: [256]u8 = undefined;
    var generated_buf: [96]u8 = undefined;
    const text = if (progress.message) |message|
        text_utils.clippedLabel(&clipped_buf, message, clipped_buf.len)
    else if (progress.total) |total|
        std.fmt.bufPrint(
            &generated_buf,
            "MCP progress {d:.2}/{d:.2}",
            .{ progress.progress, total },
        ) catch "MCP progress"
    else
        std.fmt.bufPrint(
            &generated_buf,
            "MCP progress {d:.2}",
            .{progress.progress},
        ) catch "MCP progress";
    if (bridge.ctx.on_mcp_progress) |publish| {
        if (bridge.ctx.output_chunk_lifecycle_id) |lifecycle_id| {
            publish(
                bridge.ctx.mcp_progress_ctx orelse bridge.ctx.output_chunk_ctx,
                lifecycle_id,
                text,
            );
            return;
        }
    }
    bridge.ctx.on_output_chunk(
        bridge.ctx.output_chunk_ctx,
        bridge.ctx.output_chunk_lifecycle_id,
        .stdout,
        text,
    ) catch |err| {
        debug_trace.logf("mcp", "failed to publish MCP progress err={s}", .{@errorName(err)});
    };
}

fn executeRegisteredTool(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.ToolExecutionAuthority,
    authorized_image_catalog: []const types.ImageAttachment,
    registry: tool_dispatch.Registry,
) !ToolExecutionResult {
    var selected_dynamic_tool_sink = SelectedDynamicToolSinkState{ .allocator = arena };
    var context_notice_sink = ContextNoticeSinkState{ .allocator = arena };
    var command_backend = RunCommandBackendState{ .runtime = ctx };
    var vision_provider = VisionProviderState{
        .runtime = ctx,
        .authorized_image_catalog = authorized_image_catalog,
    };
    var subagent_provider = SubagentProviderState{ .runtime = ctx };
    var mcp_progress_bridge = McpProgressBridge{ .ctx = ctx };
    var mcp_call_status: ?tool_mcp_runtime.CallStatus = null;
    var mcp_execution_error: ?anyerror = null;
    var dispatch_metadata: DispatchMetadata = .{};
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
    dispatch_metadata.attach(&dispatch_ctx);
    var result_commit_token: ?result_commit.Token = null;
    dispatch_ctx.result_commit_sink = &result_commit_token;
    dispatch_ctx.execution_authority = authority;
    dispatch_ctx.mcp_call_options = .{
        .expected_runtime_generation = ctx.expected_mcp_runtime_generation,
        .expected_binding = ctx.expected_mcp_binding,
        .cancel_flag = dispatch_ctx.cancel_flag,
        .progress = .{
            .context = @ptrCast(&mcp_progress_bridge),
            .callback = emitMcpProgress,
        },
        .input_responder = ctx.mcp_input_responder,
        .access = ctx.mcp_access,
    };
    dispatch_ctx.mcp_call_status_sink = &mcp_call_status;
    const runtime_provider = if (registry.lookup(call.name)) |tool|
        tool.runtime_provider
    else
        .none;
    if (registry.lookup(call.name)) |tool| {
        dispatch_ctx.captured_command_host = tool.captured_command_host;
    }
    switch (runtime_provider) {
        .none => {},
        .run_command => dispatch_ctx.run_command_backend = .{
            .ctx = &command_backend,
            .execute_fn = executeRunCommandBackend,
        },
        .vision => dispatch_ctx.vision_provider = .{
            .ctx = &vision_provider,
            .execute_fn = executeVisionProvider,
        },
        .subagent => dispatch_ctx.subagent_provider = .{
            .context = &subagent_provider,
            .execute_fn = executeSubagentProvider,
        },
    }
    dispatch_ctx.mcp_execution_error_sink = &mcp_execution_error;
    attachSelectedDynamicToolSink(&dispatch_ctx, &selected_dynamic_tool_sink);
    attachContextNoticeSink(&dispatch_ctx, &context_notice_sink);
    const dispatched = try tool_dispatch.dispatchAuthorizedToolCall(
        dispatch_ctx,
        registry,
        call,
        &dispatch_metadata.status_detail,
    );
    if (command_backend.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    if (vision_provider.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    if (mcp_execution_error) |err| {
        dispatched.deinit(arena);
        if (err == error.McpAdvertisedToolChanged) return refreshChangedMcpTool(ctx, arena, call.name);
        return err;
    }

    var execution = if (command_backend.completion) |completion|
        completion
    else if (vision_provider.completion) |completion|
        completion
    else
        toolExecutionResultFromDispatch(dispatched, dispatch_metadata);
    execution.model_output = dispatched.body;
    if (dispatch_metadata.status_detail) |detail| execution.status_detail = detail;
    if (mcp_call_status == .input_required or
        (execution.status == .failure and
            tool_mcp_feature_dispatch.isInputRequiredFailure(execution.model_output)))
    {
        execution.finish_turn = true;
        execution.status_detail = "McpInputRequired";
    }
    execution.selected_dynamic_tools = selected_dynamic_tool_sink.tools.items;
    execution.context_notices = context_notice_sink.notices.items;
    execution.result_commit = result_commit_token;
    if (dispatch_ctx.cancel_flag) |cancel_flag| {
        if (cancel_flag.load(.seq_cst) and
            tool_dispatch.toolActivityKind(registry, call.name) == .command)
        {
            execution.cancelled = true;
        }
    }
    return execution;
}

const RunCommandBackendState = struct {
    runtime: Context,
    completion: ?ToolExecutionResult = null,
    execution_error: ?anyerror = null,
};

fn executeRunCommandBackend(
    maybe_ctx: ?*anyopaque,
    dispatch_ctx: tool_dispatch.DispatchContext,
    request: tool_dispatch.RunCommandRequest,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const raw_ctx = maybe_ctx orelse unreachable;
    const state: *RunCommandBackendState = @ptrCast(@alignCast(raw_ctx));
    const authority = switch (dispatch_ctx.execution_authority orelse {
        state.execution_error = error.InvalidRunCommandExecutionAuthority;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    }) {
        .run_command => |command_authority| command_authority,
        .ordinary, .file_mutation, .vision_paths => {
            state.execution_error = error.InvalidRunCommandExecutionAuthority;
            return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
        },
    };
    const execution = toolRunCommand(
        state.runtime,
        dispatch_ctx.allocator,
        request,
        authority,
    ) catch |err| {
        state.execution_error = err;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    };
    state.completion = execution;
    return switch (execution.status) {
        .success => .{ .success = @constCast(execution.model_output) },
        .failure => .{ .failure = @constCast(execution.model_output) },
    };
}

const DispatchMetadata = struct {
    model_content_kind: tool_dispatch.ModelContentKind = .ordinary,
    status_detail: ?[]u8 = null,
    inner_usage: ?types.ToolUsage = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
    tool_result_memory: ?types.ToolResultMemory = null,
    command_result_json: ?[]const u8 = null,
    turn_control: ?tool_dispatch.TurnControl = null,

    fn attach(self: *DispatchMetadata, ctx: *tool_dispatch.DispatchContext) void {
        ctx.model_content_kind_sink = &self.model_content_kind;
        ctx.inner_usage_sink = &self.inner_usage;
        ctx.web_search_completion_sink = &self.web_search_completion;
        ctx.web_fetch_completion_sink = &self.web_fetch_completion;
        ctx.tool_result_memory_sink = &self.tool_result_memory;
        ctx.command_result_json_sink = &self.command_result_json;
        ctx.turn_control_sink = &self.turn_control;
    }
};

fn toolExecutionResultFromDispatch(
    result: tool_dispatch.AuthorizedDispatchResult,
    metadata: DispatchMetadata,
) ToolExecutionResult {
    var memory = metadata.tool_result_memory;
    if (result.images.len > 0) {
        var rich_memory = memory orelse types.ToolResultMemory{};
        rich_memory.tool_images = result.images;
        memory = rich_memory;
    }
    return switch (result.status) {
        .success => .{
            .model_content_kind = metadata.model_content_kind,
            .model_output = result.body,
            .status_detail = metadata.status_detail,
            .inner_usage = metadata.inner_usage,
            .web_search_completion = metadata.web_search_completion,
            .web_fetch_completion = metadata.web_fetch_completion,
            .tool_result_memory = memory,
            .command_result_json = metadata.command_result_json,
            .turn_control = metadata.turn_control,
        },
        .failure => .{
            .status = .failure,
            .model_output = result.body,
            .status_detail = metadata.status_detail,
            .inner_usage = metadata.inner_usage,
            .web_search_completion = metadata.web_search_completion,
            .web_fetch_completion = metadata.web_fetch_completion,
            .tool_result_memory = memory,
            .command_result_json = metadata.command_result_json,
            .turn_control = metadata.turn_control,
        },
    };
}

pub fn snapshotMcpDefinition(ctx: Context, arena: Allocator, name: []const u8, known: tool_mcp_runtime.Binding) !tool_mcp_runtime.DefinitionSnapshot {
    const runtime = ctx.mcp_ctx orelse return .unavailable;
    const snapshot = ctx.mcp_snapshot_tool orelse return .unavailable;
    return snapshot(runtime, arena, name, known, ctx.permission_rules, ctx.context_limits, ctx.mcp_access);
}

fn refreshChangedMcpTool(ctx: Context, arena: Allocator, name: []const u8) !ToolExecutionResult {
    var unavailable_output: []const u8 = "MCP tool definition changed before execution and is no longer available. Search for current tools.";
    var notice: ?[]const u8 = null;
    if (ctx.mcp_ctx) |runtime_context| if (ctx.mcp_tool_schema) |schema_fn| {
        const current = schema_fn(runtime_context, arena, name, ctx.permission_rules, ctx.context_limits, ctx.mcp_access, runtimeCancelFlag(ctx)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (current) |projection| switch (projection) {
            .selected => |payload| {
                const selected = try arena.alloc(tool_mcp_runtime.SelectedTool, 1);
                selected[0] = .{ .name = name, .schema_json = payload.model_output, .mcp_binding = payload.mcp_binding };
                return .{
                    .status = .failure,
                    .model_output = "MCP tool definition changed before execution. Its current schema is loaded; review it before issuing a new call.",
                    .selected_dynamic_tools = selected,
                    .context_notices = if (payload.notice) |value| notices: {
                        const values = try arena.alloc([]const u8, 1);
                        values[0] = value;
                        break :notices values;
                    } else &.{},
                };
            },
            .rejected => |payload| {
                unavailable_output = payload.model_output;
                notice = payload.notice;
            },
        };
    };
    const retired = try arena.alloc([]const u8, 1);
    retired[0] = name;
    return .{
        .status = .failure,
        .model_output = unavailable_output,
        .retired_dynamic_tool_names = retired,
        .context_notices = if (notice) |value| notices: {
            const values = try arena.alloc([]const u8, 1);
            values[0] = value;
            break :notices values;
        } else &.{},
    };
}

const SelectedDynamicToolSinkState = struct {
    allocator: Allocator,
    tools: std.ArrayList(tool_mcp_runtime.SelectedTool) = .empty,
};

const ContextNoticeSinkState = struct {
    allocator: Allocator,
    notices: std.ArrayList([]const u8) = .empty,
};

fn attachContextNoticeSink(dispatch_ctx: *tool_dispatch.DispatchContext, state: *ContextNoticeSinkState) void {
    dispatch_ctx.context_notice_ctx = state;
    dispatch_ctx.on_context_notice = recordContextNoticeForDispatch;
}

fn recordContextNoticeForDispatch(raw_ctx: ?*anyopaque, notice: []const u8) error{OutOfMemory}!void {
    const state_ptr = raw_ctx orelse return;
    const state: *ContextNoticeSinkState = @ptrCast(@alignCast(state_ptr));
    const duplicate = try state.allocator.dupe(u8, notice);
    errdefer state.allocator.free(duplicate);
    try state.notices.append(state.allocator, duplicate);
}

fn attachSelectedDynamicToolSink(
    dispatch_ctx: *tool_dispatch.DispatchContext,
    state: *SelectedDynamicToolSinkState,
) void {
    dispatch_ctx.selected_dynamic_tool_ctx = state;
    dispatch_ctx.on_selected_dynamic_tool = recordSelectedDynamicToolForDispatch;
}

fn recordSelectedDynamicToolForDispatch(
    raw_ctx: ?*anyopaque,
    name: []const u8,
    schema_json: []const u8,
    binding: ?tool_mcp_runtime.Binding,
) error{OutOfMemory}!void {
    const state_ptr = raw_ctx orelse return;
    const state: *SelectedDynamicToolSinkState = @ptrCast(@alignCast(state_ptr));
    const owned_name = try state.allocator.dupe(u8, name);
    errdefer state.allocator.free(owned_name);
    const owned_schema_json = try state.allocator.dupe(u8, schema_json);
    errdefer state.allocator.free(owned_schema_json);
    try state.tools.append(state.allocator, .{ .name = owned_name, .schema_json = owned_schema_json, .mcp_binding = binding });
}

fn typedDispatchContext(ctx: Context, arena: Allocator) tool_dispatch.DispatchContext {
    var capabilities = tool_dispatch.ToolCapabilities.for_host(
        host_capabilities.current(),
    );
    capabilities.web_search_runtime_ready =
        ctx.web_search_runtime_ready and ctx.web_search_backend != null;
    return .{
        .allocator = arena,
        .permission_mode = ctx.permission_mode,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.access_scope,
        .change_tracker = ctx.tracker,
        .skills_dir = ctx.skills_dir,
        .skill_locations = ctx.skill_locations,
        .context_limits = ctx.context_limits,
        .ignored_list_entries = ctx.ignored_list_entries,
        .max_list_entries = ctx.max_list_entries,
        .max_read_file_bytes = ctx.max_read_file_bytes,
        .max_read_file_lines = ctx.max_read_file_lines,
        .max_read_file_line_len = ctx.max_read_file_line_len,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
        .tool_result_dir = ctx.tool_result_dir,
        .session_child_capability = ctx.session_child_capability,
        .ephemeral_command_replay = ctx.ephemeral_command_replay,
        .terminal_client = ctx.terminal_client,
        .managed_executions = ctx.managed_executions,
        .command_artifact_dir = ctx.command_artifact_dir,
        .terminal_owner_session_id = ctx.lifecycle_scope.session_id,
        .terminal_transport_role = switch (ctx.lifecycle_scope.kind) {
            .interactive, .subagent => .interactive,
            .ask => .headless,
            .acp => .acp,
        },
        .lifecycle_allocator = ctx.session_allocator,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .command_timeout_ms = ctx.command_timeout_ms,
        .ask_question_ctx = if (ctx.interactive) ctx.worker else null,
        .ask_question_batch = if (ctx.interactive) requestQuestionBatchWithWorker else null,
        .web_fetch_runtime = ctx.web_fetch_runtime,
        .web_fetch_artifact_store = ctx.web_fetch_artifact_store,
        .web_fetch_artifact_error = ctx.web_fetch_artifact_error,
        .tool_capabilities = capabilities,
        .web_search_backend = ctx.web_search_backend,
        .web_search_progress_ctx = ctx.web_search_progress_ctx,
        .on_web_search_progress = ctx.on_web_search_progress,
        .web_fetch_progress_ctx = ctx.web_fetch_progress_ctx,
        .on_web_fetch_progress = ctx.on_web_fetch_progress,
        .host_tool_provider = ctx.host_tool_provider,
        .mcp_ctx = ctx.mcp_ctx,
        .mcp_call_tool = ctx.mcp_call_tool,
        .mcp_search_tools = ctx.mcp_search_tools,
        .mcp_tool_schema = ctx.mcp_tool_schema,
        .mcp_call_feature = ctx.mcp_call_feature,
        .mcp_access = ctx.mcp_access,
        .mcp_input_responder = ctx.mcp_input_responder,
        .mcp_permission_rules = if (ctx.permission_mode == .yolo)
            .{}
        else
            ctx.permission_rules,
    };
}

fn terminal_lease_cleanup_dispatch_context(
    ctx: Context,
    arena: Allocator,
) tool_dispatch.DispatchContext {
    var dispatch = typedDispatchContext(ctx, arena);
    dispatch.cancel_flag = null;
    return dispatch;
}

pub fn release_agent_terminal_lease(ctx: Context, session_id: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.session_allocator);
    defer arena_state.deinit();
    return shell_impl.releaseAgentWriteLease(
        terminal_lease_cleanup_dispatch_context(ctx, arena_state.allocator()),
        session_id,
    );
}

fn requestQuestionBatchWithWorker(
    raw_ctx: ?*anyopaque,
    response_alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
) Allocator.Error!?[][]u8 {
    const worker: *WorkerRuntime = @ptrCast(@alignCast(raw_ctx.?));
    const worker_alloc = std.heap.c_allocator;
    const worker_answers = try worker.requestQuestionBatchAnswerBlocking(worker_alloc, entries);
    defer freeQuestionAnswers(worker_alloc, worker_answers);

    const answers = worker_answers orelse return null;
    const copied_answers = try dupeQuestionAnswers(response_alloc, answers);
    return copied_answers;
}

fn dupeQuestionAnswers(alloc: Allocator, answers: []const []const u8) Allocator.Error![][]u8 {
    const copy = try alloc.alloc([]u8, answers.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |answer| alloc.free(answer);
    }
    while (copied < answers.len) : (copied += 1) {
        copy[copied] = try alloc.dupe(u8, answers[copied]);
    }
    return copy;
}

fn freeQuestionAnswers(alloc: Allocator, maybe_answers: ?[][]u8) void {
    const answers = maybe_answers orelse return;
    for (answers) |answer| alloc.free(answer);
    alloc.free(answers);
}

fn runtimeCancelFlag(ctx: Context) *std.atomic.Value(bool) {
    return ctx.cancel_flag orelse &ctx.worker.worker_cancel_requested;
}

fn typedDispatchContextForCall(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) tool_dispatch.DispatchContext {
    var dispatch = typedDispatchContext(ctx, arena);
    dispatch.tool_call_id = call.id;
    dispatch.tool_call_name = call.name;
    dispatch.resolved_skill = call.resolved_skill;
    return dispatch;
}

pub fn prepareSkillCall(ctx: Context, arena: Allocator, call: ToolCall, locations: ?*const skill_contract.Locations) !skill_contract.CallPreparation {
    const tool = ctx.tool_registry.lookup(call.name) orelse return error.UnsupportedTool;
    const prepare = tool.prepare_skill_call_fn orelse return error.UnsupportedTool;
    var dispatch = typedDispatchContextForCall(ctx, arena, call);
    dispatch.skill_locations = locations;
    return prepare(dispatch, call.arguments_json);
}

const VisionProviderState = struct {
    runtime: Context,
    authorized_image_catalog: []const types.ImageAttachment,
    completion: ?ToolExecutionResult = null,
    execution_error: ?anyerror = null,
};

fn executeVisionProvider(
    maybe_ctx: ?*anyopaque,
    dispatch_ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const raw_ctx = maybe_ctx orelse unreachable;
    const state: *VisionProviderState = @ptrCast(@alignCast(raw_ctx));
    const request = input.as(tool_contracts.vision.VisionRequest);
    const execution = executeVisionRequest(
        state,
        dispatch_ctx.allocator,
        request.*,
        dispatch_ctx.execution_authority orelse {
            state.execution_error = error.InvalidVisionExecutionAuthority;
            return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
        },
    ) catch |err| {
        state.execution_error = err;
        return .{ .failure = try dispatch_ctx.allocator.dupe(u8, "") };
    };
    state.completion = execution;
    return switch (execution.status) {
        .success => .{ .success = @constCast(execution.model_output) },
        .failure => .{ .failure = @constCast(execution.model_output) },
    };
}

fn executeVisionRequest(
    state: *VisionProviderState,
    alloc: Allocator,
    request: tool_contracts.vision.VisionRequest,
    authority: command_admission.ToolExecutionAuthority,
) !ToolExecutionResult {
    const config: vision_executor.Config = .{
        .stream_provider = state.runtime.agent_stream_provider,
        .api_key = state.runtime.api_key,
        .credential_source = state.runtime.credential_source,
        .gateway_team = state.runtime.gateway_team,
        .session_id = state.runtime.lifecycle_scope.session_id,
        .retry_count = state.runtime.gateway_retry_count,
        .cancel_flag = state.runtime.cancel_flag,
        .usage = &state.runtime.session.usage,
        .usage_allocator = state.runtime.session_allocator,
        .trace_ctx = .{},
        .output_limit = state.runtime.context_limits.image_adapter_output_bytes,
    };
    if (request.image_ids() != null) {
        if (authority != .ordinary) return error.InvalidVisionExecutionAuthority;
        return vision_executor.executeRequest(
            alloc,
            request,
            state.authorized_image_catalog,
            config,
        );
    }

    const approved_targets = switch (authority) {
        .vision_paths => |vision_authority| vision_authority.targets,
        .ordinary, .run_command, .file_mutation => return error.InvalidVisionExecutionAuthority,
    };
    const raw_paths = request.paths() orelse return error.InvalidVisionExecutionAuthority;
    if (raw_paths.len != approved_targets.len) return error.InvalidVisionExecutionAuthority;
    return executeVisionPathRequest(state, alloc, request, approved_targets, config);
}

fn executeVisionPathRequest(
    state: *VisionProviderState,
    alloc: Allocator,
    request: tool_contracts.vision.VisionRequest,
    approved_targets: []const command_admission.VisionPathExecutionTarget,
    config: vision_executor.Config,
) !ToolExecutionResult {
    const catalog = try alloc.alloc(types.ImageAttachment, approved_targets.len);
    defer alloc.free(catalog);
    var initialized: usize = 0;

    const snapshot_dir = image_attachments.createTempSnapshotDir(alloc) catch |err|
        return visionPathPreparationFailure(alloc, err);
    defer alloc.free(snapshot_dir);
    defer image_attachments.cleanupSnapshotDir(snapshot_dir);
    defer {
        image_attachments.discardImageSnapshots(alloc, catalog[0..initialized]);
        for (catalog[0..initialized]) |image| types.freeImageAttachment(alloc, image);
    }

    for (approved_targets, 0..) |target, index| {
        const image = image_attachments.captureBoundImageAttachment(
            alloc,
            target.canonical_path,
            target.identity,
            index + 1,
            snapshot_dir,
            .{ .cancel_flag = state.runtime.cancel_flag },
        ) catch |err| return visionPathPreparationFailure(alloc, err);
        catalog[index] = image;
        initialized += 1;
    }

    const image_ids = try alloc.alloc(usize, catalog.len);
    defer alloc.free(image_ids);
    for (image_ids, 0..) |*image_id, index| image_id.* = index + 1;
    const id_request: tool_contracts.vision.VisionRequest = .{
        .source = .{ .image_ids = image_ids },
        .focus = request.focus,
    };
    return vision_executor.executeRequest(alloc, id_request, catalog, config);
}

fn visionPathFailure(alloc: Allocator, err: anyerror) Allocator.Error!ToolExecutionResult {
    const details = [_]tool_result_errors.Detail{
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return .{
        .status = .failure,
        .status_detail = @errorName(err),
        .model_output = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "vision",
            .message = "Vision could not load an approved image path.",
            .details = &details,
            .suggestion = "Use an existing supported image under 20 MiB, or choose another image.",
        }),
    };
}

fn visionPathImagePreparationFailure(alloc: Allocator) Allocator.Error!ToolExecutionResult {
    const details = [_]tool_result_errors.Detail{
        .{ .name = "error", .value = .{ .string = "ImagePreparationFailed" } },
    };
    return .{
        .status = .failure,
        .status_detail = "ImagePreparationFailed",
        .model_output = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "vision",
            .message = "Vision could not prepare an approved image path.",
            .details = &details,
            .suggestion = image_attachments.image_preparation_failed_notice,
        }),
    };
}

fn visionPathPreparationFailure(
    alloc: Allocator,
    err: anyerror,
) !ToolExecutionResult {
    return switch (err) {
        error.OutOfMemory, error.Cancelled, error.TimedOut => err,
        error.ImagePreparationFailed => visionPathImagePreparationFailure(alloc),
        else => visionPathFailure(alloc, err),
    };
}

test "Vision path preparation reports semantic failure and preserves operational errors" {
    const alloc = std.testing.allocator;
    const failed = try visionPathPreparationFailure(alloc, error.ImagePreparationFailed);
    defer alloc.free(@constCast(failed.model_output));
    try std.testing.expectEqualStrings("ImagePreparationFailed", failed.status_detail.?);
    try expectContains(failed.model_output, "Vision could not prepare an approved image path.");
    try expectContains(failed.model_output, image_attachments.image_preparation_failed_notice);

    const too_large = try visionPathPreparationFailure(alloc, error.ImageTooLarge);
    defer alloc.free(@constCast(too_large.model_output));
    try std.testing.expectEqualStrings("ImageTooLarge", too_large.status_detail.?);
    try expectContains(too_large.model_output, "under 20 MiB");

    try std.testing.expectError(
        error.Cancelled,
        visionPathPreparationFailure(alloc, error.Cancelled),
    );
    try std.testing.expectError(
        error.TimedOut,
        visionPathPreparationFailure(alloc, error.TimedOut),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        visionPathPreparationFailure(alloc, error.OutOfMemory),
    );
}

fn semanticFailure(output: []const u8) ToolExecutionResult {
    return .{ .status = .failure, .model_output = output };
}

fn mcpRuntimeCapabilities(ctx: Context) tool_mcp_runtime.RuntimeCapabilities {
    return .{
        .context = ctx.mcp_ctx,
        .has_tool = ctx.mcp_has_tool,
        .validate_tool = ctx.mcp_validate_tool,
        .call_tool = ctx.mcp_call_tool,
        .access = ctx.mcp_access,
    };
}

pub fn withAdvertisedDynamicToolNames(ctx: Context, advertised_dynamic_tool_names: []const []const u8) Context {
    var copy = ctx;
    copy.advertised_dynamic_tool_names = advertised_dynamic_tool_names;
    return copy;
}

const EffectiveCommandTimeout = struct {
    timeout_ms: usize,
    started_ms: i64,
};

fn effectiveCommandTimeout(
    request_timeout_ms: u64,
    ambient_timeout_ms: ?usize,
    ambient_started_ms: ?i64,
    now_ms: i64,
) !EffectiveCommandTimeout {
    const requested = std.math.cast(usize, request_timeout_ms) orelse
        return error.InvalidToolArguments;
    const ambient = ambient_timeout_ms orelse return .{
        .timeout_ms = requested,
        .started_ms = now_ms,
    };
    const ambient_started = ambient_started_ms orelse now_ms;
    const elapsed: usize = if (now_ms <= ambient_started)
        0
    else
        std.math.cast(usize, now_ms - ambient_started) orelse std.math.maxInt(usize);
    return .{
        .timeout_ms = @min(requested, ambient -| elapsed),
        .started_ms = now_ms,
    };
}

fn commandReplayPolicy(
    environment: command_environment.Environment,
    has_replay_capability: bool,
    interactive: bool,
    continued: ?command_replay_store.CapturePolicy,
) ?command_replay_store.CapturePolicy {
    if (continued) |policy| return policy;
    return switch (environment) {
        .workspace_clean => null,
        .legacy => if (has_replay_capability or interactive)
            .best_effort
        else
            null,
        .clean, .user => if (has_replay_capability)
            .required
        else if (interactive)
            .best_effort
        else
            null,
    };
}

fn toolRunCommand(
    ctx: Context,
    arena: Allocator,
    request: tool_dispatch.RunCommandRequest,
    authority: command_admission.CommandExecutionAuthority,
) !ToolExecutionResult {
    const command = request.command;
    const cwd = request.resolved_cwd;
    const command_ctx = command_admission.CommandContext{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.os.tag,
        .environment = request.environment,
    };
    const timeout = try effectiveCommandTimeout(
        request.timeout_ms,
        ctx.command_timeout_ms,
        ctx.command_timeout_started_ms,
        io_mod.milliTimestamp(),
    );
    const replay_policy = commandReplayPolicy(
        request.environment,
        ctx.session_child_capability != null or
            ctx.ephemeral_command_replay != null,
        ctx.interactive,
        if (ctx.command_replay_capture) |capture| capture.policy() else null,
    );

    if (comptime builtin.os.tag == .wasi or builtin.is_test) {
        if (ctx.workspace_executor) |executor| {
            return executeWorkspaceRunCommand(
                arena,
                request,
                command_ctx,
                authority,
                executor,
                timeout.timeout_ms,
            );
        }
    }
    if (comptime builtin.os.tag == .wasi) return error.WorkspaceUnavailable;

    try execution_router.validateConfigContext(.{
        .max_command_output_bytes = ctx.max_command_output_bytes,
    }, command_ctx);
    var route = try execution_router.prepareAuthorizedRoute(arena, command_ctx, authority);
    defer route.deinit(arena);

    const compatibility_result = try tool_dispatch.dispatchRunCommandCompatibility(
        typedDispatchContext(ctx, arena),
        ctx.tool_registry,
        request,
    );
    if (compatibility_result) |compatibility| {
        if (route != .approved_shell) return error.CommandAdmissionChanged;
        const intercepted_replay = try initCommandReplayCapture(
            arena,
            replay_policy,
            ctx.max_command_output_bytes,
            ctx.max_command_output_bytes,
            ctx.session_child_capability,
            ctx.ephemeral_command_replay,
            ctx.command_replay_capture,
            ctx.command_replay_unavailable,
        );
        const capture = intercepted_replay.capture;
        var transferred = false;
        defer if (!transferred) {
            if (capture) |candidate| candidate.abort(arena);
        };
        var callback = CommandReplayCaptureCallback{
            .alloc = arena,
            .capture = capture,
        };
        const output = switch (compatibility) {
            .success => |body| body,
            .failure => |body| body,
            .rich => {
                compatibility.deinit(arena);
                return error.RichCommandOutputUnsupported;
            },
        };
        if (compatibility == .success and capture != null and output.len > 0) {
            callback.accept(
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            ) catch |err| {
                if (err != error.CommandOutputCaptureFailed) return err;
                return finishCommandToolResult(
                    arena,
                    capture,
                    false,
                    &transferred,
                    null,
                    try command_result_mapping.Command.outputCaptureFailure(arena),
                );
            };
        }
        if (compatibility == .success and ctx.interactive and output.len > 0) {
            try ctx.on_output_chunk(
                ctx.output_chunk_ctx,
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            );
        }
        return finishCommandToolResult(
            arena,
            capture,
            intercepted_replay.unavailable and
                (ctx.command_replay_unavailable or callback.had_accepted_output),
            &transferred,
            null,
            .{
                .status = switch (compatibility) {
                    .success => .success,
                    .failure => .failure,
                    .rich => unreachable,
                },
                .model_output = output,
            },
        );
    }

    const replay_init = try initCommandReplayCapture(
        arena,
        replay_policy,
        ctx.max_command_output_bytes,
        execution_router.foregroundResultComparisonLimit(
            route,
            ctx.max_command_output_bytes,
        ),
        ctx.session_child_capability,
        ctx.ephemeral_command_replay,
        ctx.command_replay_capture,
        ctx.command_replay_unavailable,
    );
    const replay_capture = replay_init.capture;
    var replay_transferred = false;
    defer if (!replay_transferred) {
        if (replay_capture) |capture| capture.abort(arena);
    };
    var replay_callback = CommandReplayCaptureCallback{
        .alloc = arena,
        .capture = replay_capture,
    };

    const routed = execution_router.executePreparedRoute(.{
        .max_command_output_bytes = ctx.max_command_output_bytes,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .accepted_output_chunk_ctx = if (replay_capture != null) @ptrCast(&replay_callback) else null,
        .on_accepted_output_chunk = if (replay_capture != null) CommandReplayCaptureCallback.onChunk else null,
        .callback_projection = if (ctx.interactive) .raw else .model_safe,
        .timeout_ms = timeout.timeout_ms,
        .timeout_started_ms = timeout.started_ms,
        .command_artifact_capability = ctx.session_child_capability,
        .command_artifact_dir = ctx.command_artifact_dir,
    }, arena, route) catch |err| {
        if (err == error.TimeoutExpired) {
            return finishCommandToolResult(
                arena,
                replay_capture,
                replay_init.unavailable and
                    (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
                &replay_transferred,
                null,
                try command_result_mapping.Command.timeoutFailure(
                    arena,
                    command,
                    cwd,
                    timeout.timeout_ms,
                    timeout.started_ms,
                ),
            );
        }
        if (err == error.CommandOutputCaptureFailed) return finishCommandToolResult(
            arena,
            replay_capture,
            false,
            &replay_transferred,
            null,
            try command_result_mapping.Command.outputCaptureFailure(arena),
        );
        if (err == error.Cancelled and runtimeCancelFlag(ctx).load(.seq_cst)) {
            return finishCommandToolResult(
                arena,
                replay_capture,
                replay_init.unavailable and
                    (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
                &replay_transferred,
                null,
                .{
                    .status = .failure,
                    .cancelled = true,
                    .model_output = "command cancelled\n",
                },
            );
        }
        return err;
    };
    const result = routed.result;

    if (try command_result_mapping.Command.cancelledFailure(arena, result)) |cancelled| {
        return finishCommandToolResult(
            arena,
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            cancelled,
        );
    }

    if (try command_result_mapping.Command.nonZeroFailure(arena, result)) |failure| {
        return finishCommandToolResult(
            arena,
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            failure,
        );
    }

    return finishCommandToolResult(
        arena,
        replay_capture,
        replay_init.unavailable and
            (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
        &replay_transferred,
        result,
        .{
            .model_output = result.output,
            .command_result_json = if (result.command_result) |command_result| try command_result.toJson(arena) else null,
        },
    );
}

fn executeWorkspaceRunCommand(
    arena: Allocator,
    request: tool_dispatch.RunCommandRequest,
    command_ctx: command_admission.CommandContext,
    authority: command_admission.CommandExecutionAuthority,
    executor: js_host_workspace.Executor,
    configured_timeout_ms: ?usize,
) !ToolExecutionResult {
    if (std.meta.activeTag(request.environment) != .workspace_clean) return error.InvalidWorkspaceInput;
    var route = try execution_router.prepareAuthorizedRoute(
        arena,
        command_ctx,
        authority,
    );
    defer route.deinit(arena);

    const timeout_ms: u32 = @intCast(@min(
        @max(configured_timeout_ms orelse js_host_workspace.max_timeout_ms, js_host_workspace.min_timeout_ms),
        js_host_workspace.max_timeout_ms,
    ));
    const started_ms = io_mod.milliTimestamp();
    const result = executor.execute(
        arena,
        request.command,
        request.resolved_cwd,
        timeout_ms,
    ) catch |err| {
        if (err == error.WorkspaceDeadline) {
            return command_result_mapping.Command.timeoutFailure(
                arena,
                request.command,
                request.resolved_cwd,
                timeout_ms,
                started_ms,
            );
        }
        return err;
    };
    var replay_transferred = false;
    if (try command_result_mapping.Command.cancelledFailure(arena, result)) |cancelled| {
        return finishCommandToolResult(
            arena,
            null,
            false,
            &replay_transferred,
            result,
            cancelled,
        );
    }
    if (try command_result_mapping.Command.nonZeroFailure(arena, result)) |failure| {
        return finishCommandToolResult(
            arena,
            null,
            false,
            &replay_transferred,
            result,
            failure,
        );
    }
    return finishCommandToolResult(
        arena,
        null,
        false,
        &replay_transferred,
        result,
        .{
            .model_output = result.output,
            .command_result_json = if (result.command_result) |command_result|
                try command_result.toJson(arena)
            else
                null,
        },
    );
}

const CommandReplayCaptureCallback = struct {
    alloc: Allocator,
    capture: ?*command_replay_store.Capture,
    had_accepted_output: bool = false,

    fn onChunk(
        raw_ctx: *anyopaque,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        return self.accept(lifecycle_id, stream, chunk);
    }

    fn accept(
        self: *@This(),
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        _ = lifecycle_id;
        if (chunk.len == 0) return;
        self.had_accepted_output = true;
        if (self.capture) |capture| {
            switch (capture.policy()) {
                .required => try capture.appendAcceptedRequired(
                    self.alloc,
                    stream,
                    chunk,
                ),
                .best_effort => capture.appendAccepted(self.alloc, stream, chunk),
            }
        }
    }
};

const CommandReplayCaptureInit = struct {
    capture: ?*command_replay_store.Capture = null,
    unavailable: bool = false,
};

fn initCommandReplayCapture(
    arena: Allocator,
    replay_policy: ?command_replay_store.CapturePolicy,
    inline_limit: usize,
    comparison_limit: usize,
    capability: ?*session_child_store.SessionChildCapability,
    ephemeral_store: ?*command_replay_store.EphemeralStore,
    continued_capture: ?*command_replay_store.Capture,
    continued_unavailable: bool,
) !CommandReplayCaptureInit {
    const policy = replay_policy orelse return .{};
    if (continued_unavailable) {
        if (policy == .required) return error.CommandOutputCaptureFailed;
        return .{ .unavailable = true };
    }
    if (continued_capture) |capture| {
        capture.setComparisonLimit(comparison_limit);
        return .{ .capture = capture };
    }
    const capture_inline_limit = if (policy == .required) 0 else inline_limit;
    const capture = (if (capability) |saved|
        command_replay_store.Capture.create(arena, capture_inline_limit, saved)
    else if (ephemeral_store) |ephemeral|
        command_replay_store.Capture.createEphemeral(arena, capture_inline_limit, ephemeral)
    else
        command_replay_store.Capture.create(arena, capture_inline_limit, null)) catch |err| {
        if (policy == .required) return err;
        debug_trace.logf(
            "session",
            "command replay capture initialization unavailable err={s}",
            .{@errorName(err)},
        );
        return .{ .unavailable = true };
    };
    capture.setPolicyBeforeCapture(policy);
    capture.setComparisonLimit(comparison_limit);
    return .{ .capture = capture };
}

fn finishCommandToolResult(
    arena: Allocator,
    capture: ?*command_replay_store.Capture,
    replay_unavailable: bool,
    replay_transferred: *bool,
    process_result: ?command_contract.RunCommandResult,
    result: ToolExecutionResult,
) !ToolExecutionResult {
    var owned = result;
    if (capture) |candidate| switch (candidate.policy()) {
        .required => candidate.sealRequired(arena) catch {
            owned = try command_result_mapping.Command.outputCaptureFailure(arena);
        },
        .best_effort => {},
    };
    if (process_result) |command_result| {
        if (commandProcessPresentation(command_result)) |presentation| {
            var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
            memory.command_process_presentation = presentation;
            owned.tool_result_memory = memory;
        }
    }
    if (replay_unavailable) {
        var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
        memory.command_output_replay = .unavailable;
        owned.tool_result_memory = memory;
    }
    owned.command_replay_capture = capture;
    if (capture != null) replay_transferred.* = true;
    return owned;
}

fn commandProcessPresentation(
    result: command_contract.RunCommandResult,
) ?types.CommandProcessPresentation {
    const command_result = result.command_result orelse return null;
    const foreground = command_result;
    if (foreground.timed_out) return .timed_out;
    if (foreground.signal) |signal| return .{ .signal = signal };
    if (foreground.exit_code) |exit_code| {
        if (exit_code != 0) return .{ .exit_code = exit_code };
    }
    return null;
}

test "file mutations reject ordinary execution authority without mutating" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeTestFile(tmp.dir, "workspace/existing.txt", "before\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var rt = TestRuntime{ .workspace_root = workspace };
    defer rt.deinit(alloc);

    const cases = [_]struct {
        name: []const u8,
        arguments_json: []const u8,
    }{
        .{
            .name = "write_file",
            .arguments_json = "{\"path\":\"created.txt\",\"content\":\"new\\n\"}",
        },
        .{
            .name = "edit_file",
            .arguments_json = "{\"path\":\"existing.txt\",\"old_string\":\"before\",\"new_string\":\"after\"}",
        },
    };

    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
            .id = "runtime-only",
            .name = case.name,
            .arguments_json = case.arguments_json,
        });
        try std.testing.expectEqual(
            tool_contracts.ToolExecutionStatus.failure,
            result.status,
        );
        try std.testing.expectEqualStrings(
            "file mutation execution authority is invalid",
            result.model_output,
        );
    }

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io_mod.getIo(), "workspace/created.txt", .{}),
    );
    var existing = try tmp.dir.openFile(io_mod.getIo(), "workspace/existing.txt", .{});
    defer existing.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(alloc, &existing, 64);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("before\n", content);
}

const SubagentProviderState = struct {
    runtime: Context,
};

fn subagentProviderFailure(
    alloc: Allocator,
    error_code: []const u8,
) Allocator.Error!subagent_tool_provider.Result {
    const body = subagent_model_contract.encodeResultAlloc(alloc, .{
        .ok = false,
        .error_code = error_code,
    }) catch return error.OutOfMemory;
    return .{ .status = .failure, .body = body };
}

fn executeSubagentProvider(
    raw_context: ?*anyopaque,
    arena: Allocator,
    request: *subagent_model_contract.Request,
    invocation_id: []const u8,
) subagent_tool_provider.ExecuteError!subagent_tool_provider.Result {
    const state: *SubagentProviderState = @ptrCast(@alignCast(raw_context.?));
    const ctx = state.runtime;
    const host = ctx.subagent_host orelse
        return subagentProviderFailure(arena, "host_unavailable");
    const caller_id = ctx.subagent_caller_id orelse
        return subagentProviderFailure(arena, "caller_unavailable");
    const identity_epoch = host.issueOperationIdentity(invocation_id);
    const output = host.executeManaged(arena, request, .{
        .caller_id = caller_id,
        .invocation_id = invocation_id,
        .parent_permission_mode = ctx.permission_mode,
        .root_user_intent_context = ctx.root_user_intent_context,
        .root_user_messages = ctx.root_user_messages,
        .root_user_evidence_complete = ctx.root_user_evidence_complete,
        .defaults = .{
            .provider = ctx.provider,
            .model = ctx.model,
            .effort = ctx.effort,
            .fast_mode = ctx.fast_mode,
            .conversation_language = ctx.session.languageSnapshot(),
        },
        .max_result_bytes = ctx.max_tool_result_bytes,
        .timestamp_ms = io_mod.milliTimestamp(),
        .identity_epoch = identity_epoch,
        .cancel_flag = runtimeCancelFlag(ctx),
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return error.Cancelled;
        return subagentProviderFailure(arena, "host_failure");
    };
    return .{
        .status = if (output.success) .success else .failure,
        .body = output.body,
    };
}

fn noopOutput(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_contract.CommandOutputStream, _: []const u8) !void {}
fn noopBackgroundReady(_: *anyopaque, _: u64, _: []const u8) void {}

const TestCapturedShellInput = struct {
    command: []u8,
    profile: ?command_environment.Profile,
    timeout_ms: u64,

    fn deinit(self: *TestCapturedShellInput, alloc: Allocator) void {
        alloc.free(self.command);
        alloc.destroy(self);
    }
};

fn decodeTestCapturedShell(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    }
    for (parsed.value.object.keys()) |name| {
        if (!std.mem.eql(u8, name, "action") and
            !std.mem.eql(u8, name, "command") and
            !std.mem.eql(u8, name, "profile") and
            !std.mem.eql(u8, name, "timeout_ms"))
        {
            return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
        }
    }
    const action = parsed.value.object.get("action") orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    const command = parsed.value.object.get("command") orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    if (action != .string or !std.mem.eql(u8, action.string, "run") or
        command != .string)
    {
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
    }
    const profile: ?command_environment.Profile = if (parsed.value.object.get("profile")) |value| blk: {
        if (value == .null) break :blk null;
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
        }
        break :blk std.meta.stringToEnum(
            command_environment.Profile,
            value.string,
        ) orelse return .{ .failure = try ctx.allocator.dupe(
            u8,
            "invalid captured shell input",
        ) };
    } else null;
    const timeout_ms: u64 = if (parsed.value.object.get("timeout_ms")) |value| blk: {
        if (value != .integer or value.integer <= 0) {
            return .{ .failure = try ctx.allocator.dupe(u8, "invalid captured shell input") };
        }
        break :blk @intCast(value.integer);
    } else 600_000;
    const input = try ctx.allocator.create(TestCapturedShellInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .command = try ctx.allocator.dupe(u8, command.string),
        .profile = profile,
        .timeout_ms = timeout_ms,
    };
    return .{ .input = .{
        .ptr = input,
        .deinit_fn = struct {
            fn deinit(raw: *anyopaque, alloc: Allocator) void {
                const value: *TestCapturedShellInput = @ptrCast(@alignCast(raw));
                value.deinit(alloc);
            }
        }.deinit,
    } };
}

fn validateTestCapturedShell(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

fn testCapturedShellFalse(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn callTestCapturedShell(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(TestCapturedShellInput);
    const backend = ctx.run_command_backend orelse return .{
        .failure = try ctx.allocator.dupe(u8, "captured shell backend unavailable"),
    };
    var shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&shell_buffer);
    const environment = shell_resolver.environment(
        ctx.allocator,
        configured,
        input.profile,
    ) catch return .{
        .failure = try ctx.allocator.dupe(u8, "captured shell profile unavailable"),
    };
    defer switch (environment) {
        .clean, .user => |path| ctx.allocator.free(path),
        .legacy, .workspace_clean => {},
    };
    return backend.execute(ctx, .{
        .command = input.command,
        .resolved_cwd = ctx.workspace_root,
        .environment = environment,
        .timeout_ms = input.timeout_ms,
    });
}

const test_captured_shell = blk: {
    var tool = test_builtin_tools.shell;
    tool.executor_kind = .run_command;
    tool.decode = decodeTestCapturedShell;
    tool.validate = validateTestCapturedShell;
    tool.call = callTestCapturedShell;
    tool.captured_command_fn = null;
    tool.process_local_fn = null;
    tool.authorized_result_mapper = null;
    tool.reads_only_fn = testCapturedShellFalse;
    tool.irreversible_fn = testCapturedShellFalse;
    break :blk tool;
};

const test_tool_registry = tool_dispatch.Registry{ .tools = &.{
    test_builtin_tools.glob_files,
    test_builtin_tools.grep_files,
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.web_fetch,
    test_builtin_tools.web_search,
    test_captured_shell,
    test_builtin_tools.capability_search,
    test_builtin_tools.skill,
    test_builtin_tools.install_skill,
    test_builtin_tools.subagent,
    test_builtin_tools.mcp_select_tool,
    test_builtin_tools.ask_user_question,
    test_builtin_tools.read_tool_result,
} };

fn matchesTestRunCommandCompatibility(command: []const u8) bool {
    return std.mem.startsWith(u8, command, "fx-compatibility-probe");
}

fn executeTestRunCommandCompatibility(
    ctx: tool_dispatch.DispatchContext,
    _: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, "registered compatibility\n") };
}

const test_compatible_tool = blk: {
    var tool = test_builtin_tools.install_skill;
    tool.run_command_compatibility = .{
        .matches = matchesTestRunCommandCompatibility,
        .execute = executeTestRunCommandCompatibility,
    };
    break :blk tool;
};

fn executeFailingRunCommandCompatibility(
    ctx: tool_dispatch.DispatchContext,
    _: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try tool_result_errors.formatToolExecutionErrorJson(
        ctx.allocator,
        "shell",
        error.SkillInstallFailed,
    ) };
}

const test_failing_compatible_tool = blk: {
    var tool = test_builtin_tools.install_skill;
    tool.run_command_compatibility = .{
        .matches = matchesTestRunCommandCompatibility,
        .execute = executeFailingRunCommandCompatibility,
    };
    break :blk tool;
};

const test_compatibility_registry = tool_dispatch.Registry{ .tools = &.{
    test_captured_shell,
    test_compatible_tool,
} };

const test_failing_compatibility_registry = tool_dispatch.Registry{ .tools = &.{
    test_captured_shell,
    test_failing_compatible_tool,
} };

fn gatherNoopTestContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopTestStaticContext(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTestTransientContext(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

const test_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.tool_runtime_context",
    .gather_project_context_fn = gatherNoopTestContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopTestStaticContext,
    .append_transient_fn = appendNoopTestTransientContext,
} };

const test_review_calls = [_]ToolCall{
    .{ .id = "test-review", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"printf test\",\"timeout_ms\":600000}" },
};
const test_review_root_messages = [_][]const u8{"test root request"};

fn testReviewTurn() permission_auto_classifier.ReviewTurnContext {
    return .{
        .model = "openai/gpt-5",
        .pending_assistant = .{ .role = .assistant, .tool_calls = &test_review_calls },
        .target_call_id = "test-review",
        .origin = .root,
        .trusted_root_context = test_review_root_messages[0],
    };
}

const TestRuntime = struct {
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    worker: WorkerRuntime = .{},
    session: SessionRuntime = .{ .max_history_turns = 8 },
    subagent_host: ?*subagent_tool_host.Runtime = null,
    subagent_caller_id: ?[]const u8 = null,
    model: []const u8 = "",
    session_allocator: Allocator = std.testing.allocator,
    workspace_root: []const u8 = "/tmp",
    ignored_list_entries: []const []const u8 = &.{},
    skills_dir: []const u8 = "",
    tracker: ?*change_tracker.ChangeTracker = null,
    permission_rules: types.PermissionRuleSet = .{},
    permission_grants: []const PermissionGrant = &.{},
    session_grants: []const PermissionGrant = &.{},
    cancel_flag: ?*std.atomic.Value(bool) = null,
    permission_mode: PermissionMode = .ask,
    max_command_output_bytes: usize = 64 * 1024,
    max_tool_result_bytes: usize = 64 * 1024,
    api_key: []const u8 = "",
    provider: model_provider.ProviderId = .gateway,
    provider_capabilities: provider_set.Bundle.Capabilities = .{
        .fx_search = true,
        .vision_fallback = true,
    },
    gateway_team: ?[]const u8 = null,
    gateway_retry_count: usize = 0,
    gateway_chat_url: []const u8 = "",
    context_limits: context_limits.Values = .{},
    command_artifact_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    ephemeral_command_replay: ?*command_replay_store.EphemeralStore = null,
    command_timeout_ms: ?usize = null,
    interactive: bool = true,
    mcp_ctx: ?*anyopaque = null,
    mcp_has_tool: ?tool_mcp_runtime.HasToolFn = null,
    mcp_validate_tool: ?tool_mcp_runtime.ValidateToolFn = null,
    mcp_call_tool: ?tool_mcp_runtime.CallToolFn = null,
    mcp_search_tools: ?tool_mcp_runtime.SearchToolsFn = null,
    mcp_tool_schema: ?tool_mcp_runtime.ToolSchemaFn = null,
    mcp_snapshot_tool: ?tool_mcp_runtime.SnapshotToolFn = null,
    mcp_call_feature: ?tool_mcp_runtime.FeatureCallFn = null,
    mcp_input_responder: ?tool_mcp_runtime.InputResponder = null,
    advertised_dynamic_tool_names: []const []const u8 = &.{},
    auto_classifier: permission_auto_classifier.Classifier = .disabled(),
    web_search_runtime_ready: bool = false,
    web_search_backend: ?tool_dispatch.WebSearchBackend = null,
    web_search_progress_ctx: ?*anyopaque = null,
    on_web_search_progress: ?tool_dispatch.WebSearchProgressFn = null,
    web_fetch_runtime: ?*web_fetch_runtime.Runtime = null,
    web_fetch_artifact_store: ?*web_fetch_artifacts.Store = null,
    web_fetch_artifact_error: ?anyerror = null,
    web_fetch_progress_ctx: ?*anyopaque = null,
    on_web_fetch_progress: ?tool_dispatch.WebFetchProgressFn = null,
    workspace_executor: ?js_host_workspace.Executor = null,
    host_sandbox_default: tool_admission.HostSandboxDefault = .none,

    fn deinit(self: *TestRuntime, alloc: Allocator) void {
        self.worker.deinit(alloc);
        self.session.deinit(alloc);
    }

    fn context(self: *TestRuntime) Context {
        return .{
            .workspace_root = self.workspace_root,
            .ignored_list_entries = self.ignored_list_entries,
            .max_list_entries = 100,
            .max_read_file_bytes = 64 * 1024,
            .max_read_file_lines = 400,
            .max_read_file_line_len = 2000,
            .max_command_output_bytes = self.max_command_output_bytes,
            .max_tool_result_bytes = self.max_tool_result_bytes,
            .api_key = self.api_key,
            .agent_stream_provider = self.agent_stream_provider,
            .gateway_team = self.gateway_team,
            .provider = self.provider,
            .provider_capabilities = self.provider_capabilities,
            .model = self.model,
            .gateway_retry_count = self.gateway_retry_count,
            .gateway_chat_url = self.gateway_chat_url,
            .agent_step_limit = 0,
            .permission_mode = self.permission_mode,
            .permission_grants = self.permission_grants,
            .session_grants = self.session_grants,
            .permission_rules = self.permission_rules,
            .tool_registry = self.tool_registry,
            .subagent_host = self.subagent_host,
            .subagent_caller_id = self.subagent_caller_id,
            .worker = &self.worker,
            .permission_prompter = if (self.interactive)
                tool_admission.workerPrompter(&self.worker)
            else
                null,
            .cancel_flag = self.cancel_flag,
            .session = &self.session,
            .session_allocator = self.session_allocator,
            .skills_dir = self.skills_dir,
            .context_registry = test_context_registry,
            .context_limits = self.context_limits,
            .output_chunk_ctx = undefined,
            .on_output_chunk = noopOutput,
            .command_artifact_dir = self.command_artifact_dir,
            .session_child_capability = self.session_child_capability,
            .ephemeral_command_replay = self.ephemeral_command_replay,
            .command_timeout_ms = self.command_timeout_ms,
            .tracker = self.tracker,
            .mcp_ctx = self.mcp_ctx,
            .mcp_has_tool = self.mcp_has_tool,
            .mcp_validate_tool = self.mcp_validate_tool,
            .mcp_call_tool = self.mcp_call_tool,
            .mcp_search_tools = self.mcp_search_tools,
            .mcp_tool_schema = self.mcp_tool_schema,
            .mcp_snapshot_tool = self.mcp_snapshot_tool,
            .mcp_call_feature = self.mcp_call_feature,
            .mcp_input_responder = self.mcp_input_responder,
            .advertised_dynamic_tool_names = self.advertised_dynamic_tool_names,
            .auto_classifier = self.auto_classifier,
            .permission_review_turn = testReviewTurn(),
            .web_fetch_runtime = self.web_fetch_runtime,
            .web_fetch_artifact_store = self.web_fetch_artifact_store,
            .web_fetch_artifact_error = self.web_fetch_artifact_error,
            .web_search_runtime_ready = self.web_search_runtime_ready,
            .web_search_backend = self.web_search_backend,
            .web_search_progress_ctx = self.web_search_progress_ctx,
            .on_web_search_progress = self.on_web_search_progress,
            .web_fetch_progress_ctx = self.web_fetch_progress_ctx,
            .on_web_fetch_progress = self.on_web_fetch_progress,
            .workspace_executor = self.workspace_executor,
            .host_sandbox_default = self.host_sandbox_default,
            .interactive = self.interactive,
        };
    }
};

const CancelTestCommandOnOutput = struct {
    flag: *std.atomic.Value(bool),
    needle: []const u8,
    seen: bool = false,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, _: command_contract.CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.find(u8, chunk, self.needle) == null) return;
        self.seen = true;
        self.flag.store(true, .seq_cst);
    }
};

const TestCommandOutputCapture = struct {
    alloc: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    stdout_chunks: usize = 0,
    stderr_chunks: usize = 0,

    fn deinit(self: *@This()) void {
        self.bytes.deinit(self.alloc);
    }

    fn onChunk(
        raw_ctx: *anyopaque,
        _: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        try self.bytes.appendSlice(self.alloc, chunk);
        switch (stream) {
            .stdout => self.stdout_chunks += 1,
            .stderr => self.stderr_chunks += 1,
        }
    }
};

fn runCommandArgsForTest(alloc: Allocator, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"action\":\"run\",\"command\":");
    try std.json.Stringify.value(command, .{}, &out.writer);
    try out.writer.writeAll(",\"timeout_ms\":600000}");
    return out.toOwnedSlice();
}

fn runCommandArgsWithCleanProfileForTest(alloc: Allocator, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"action\":\"run\",\"command\":");
    try std.json.Stringify.value(command, .{}, &out.writer);
    try out.writer.writeAll(",\"profile\":\"clean\",\"timeout_ms\":600000}");
    return out.toOwnedSlice();
}

fn executeTestRunCommand(
    ctx: Context,
    arena: Allocator,
    call: ToolCall,
) !ToolExecutionResult {
    const terminal_call = try terminalExecCallForTest(arena, call);
    const command_ctx = try tool_admission.runCommandContext(ctx.admissionInput(), arena, terminal_call);
    return executeToolCallAuthorized(ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = terminal_call,
        .authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .configured_rule,
        } } },
        .session_grants = ctx.session_grants,
        .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
    });
}

fn terminalExecCallForTest(arena: Allocator, call: ToolCall) !ToolCall {
    if (std.mem.eql(u8, call.name, "shell")) return call;
    if (!std.mem.eql(u8, call.name, "run_command")) return call;
    var args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        call.arguments_json,
        .{ .allocate = .alloc_always },
    );
    if (args != .object) return error.InvalidToolArguments;
    try args.object.put(arena, "action", .{ .string = "run" });
    try args.object.put(arena, "timeout_ms", .{ .integer = 600_000 });
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try std.json.Stringify.value(args, .{}, &out.writer);
    var migrated = call;
    migrated.name = "shell";
    migrated.arguments_json = try out.toOwnedSlice();
    return migrated;
}

test "registered terminal exec preserves invalid execution authority error" {
    var rt = TestRuntime{};
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = ToolCall{
        .id = "invalid-authority",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf should-not-run\",\"timeout_ms\":600000}",
    };

    try std.testing.expectError(
        error.InvalidRunCommandExecutionAuthority,
        executeToolCallAuthorized(rt.context(), .{
            .call_allocator = arena,
            .result_allocator = arena,
            .call = call,
            .authority = .ordinary,
            .session_grants = &.{},
            .advertised_dynamic_tool_names = &.{},
            .max_tool_result_bytes = rt.max_tool_result_bytes,
        }),
    );
}

test "captured command compatibility bypasses compound commands" {
    var rt = TestRuntime{ .tool_registry = test_compatibility_registry };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect((try tool_dispatch.dispatchRunCommandCompatibility(typedDispatchContext(rt.context(), arena), rt.tool_registry, .{
        .command = "fx-compatibility-probe; printf shell-fallback",
        .resolved_cwd = "/tmp",
        .environment = .legacy,
        .timeout_ms = 600_000,
    })) == null);

    for ([_]command_environment.Environment{
        .{ .clean = "/bin/zsh" },
        .{ .user = "/bin/zsh" },
    }) |environment| {
        try std.testing.expect((try tool_dispatch.dispatchRunCommandCompatibility(
            typedDispatchContext(rt.context(), arena),
            rt.tool_registry,
            .{
                .command = "fx-compatibility-probe",
                .resolved_cwd = "/tmp",
                .environment = environment,
                .timeout_ms = 600_000,
            },
        )) == null);
    }
}

test "run command compatibility returns installer failure without shell fallback" {
    var rt = TestRuntime{
        .tool_registry = test_failing_compatibility_registry,
        .interactive = false,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = (try tool_dispatch.dispatchRunCommandCompatibility(
        typedDispatchContext(rt.context(), arena_state.allocator()),
        rt.tool_registry,
        .{
            .command = "fx-compatibility-probe",
            .resolved_cwd = "/tmp",
            .environment = .legacy,
            .timeout_ms = 600_000,
        },
    )) orelse return error.TestExpectedEqual;

    const failure = result.failure;
    try expectToolErrorField(failure, "type", "tool_execution_failed");
    try expectToolErrorField(failure, "tool_name", "shell");
    try expectToolErrorDetailString(failure, "error", "SkillInstallFailed");
}

fn unexpectedTestPrompt(
    _: *anyopaque,
    _: Allocator,
    _: permission_request.PermissionRequest,
    _: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const types.PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    return error.TestUnexpectedPrompt;
}

const TestAutoReview = struct {
    calls: usize = 0,
    decision: permission_auto_classifier.Decision = .clear,
    risk: permission_auto_classifier.Risk = .low,
    rationale: []const u8 = "test automatic review",
    action_tag: ?std.meta.Tag(permission_auto_classifier.Action) = null,
    exact_command: ?[]const u8 = null,
    exact_arguments_json: ?[]const u8 = null,
    file_display_path: ?[]const u8 = null,
    file_additions: usize = 0,
    file_deletions: usize = 0,
    file_review_rows: usize = 0,
    target_path: ?[]const u8 = null,

    fn review(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        request: permission_auto_classifier.ReviewRequest,
    ) anyerror!permission_auto_classifier.ParseOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        self.target_path = if (request.targets.len > 0)
            request.targets[0].path
        else
            null;
        self.action_tag = std.meta.activeTag(request.action);
        switch (request.action) {
            .command => |command| self.exact_command = command.command,
            .file_mutation => |file| {
                self.file_display_path = file.display_path;
                self.file_additions = file.additions;
                self.file_deletions = file.deletions;
                self.file_review_rows = file.review.rowCount();
            },
            .tool => |tool| {
                self.exact_arguments_json = tool.arguments_json;
            },
        }
        return .{ .valid = .{
            .risk = self.risk,
            .decision = self.decision,
            .rationale = try alloc.dupe(u8, self.rationale),
        } };
    }

    fn classifier(self: *@This()) permission_auto_classifier.Classifier {
        return .withOverride(self, review);
    }
};

test "admission input represents prompt capability directly" {
    var rt = TestRuntime{ .interactive = false };
    defer rt.deinit(std.testing.allocator);
    var ctx = rt.context();

    try std.testing.expect(ctx.admissionInput().permission_prompter == null);

    ctx.permission_prompter = .{ .context = &rt, .request_fn = unexpectedTestPrompt };
    const admission = ctx.admissionInput();
    try std.testing.expect(admission.permission_prompter != null);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) == null);
}

fn expectCommandResultField(json: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectCommandResultBool(json: []const u8, field: []const u8, expected: bool) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .bool);
    try std.testing.expectEqual(expected, value.bool);
}

fn expectCommandResultInt(json: []const u8, field: []const u8, expected: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .integer);
    try std.testing.expectEqual(@as(i64, @intCast(expected)), value.integer);
}

fn expectCommandResultNull(json: []const u8, field: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .null);
}

fn expectCommandResultStringPrefix(json: []const u8, field: []const u8, prefix: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .string);
    try std.testing.expect(std.mem.startsWith(u8, value.string, prefix));
}

fn expectToolErrorField(json: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const error_obj = parsed.value.object.get("error").?.object;
    const value = error_obj.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectToolErrorDetailString(json: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const details = parsed.value.object.get("error").?.object.get("details").?.object;
    const value = details.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectToolErrorDetailInt(json: []const u8, field: []const u8, expected: i64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const details = parsed.value.object.get("error").?.object.get("details").?.object;
    const value = details.get(field) orelse return error.TestExpectedEqual;
    try std.testing.expect(value == .integer);
    try std.testing.expectEqual(expected, value.integer);
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn writeLargeTestFile(dir: std.Io.Dir, path: []const u8, prefix: []const u8, fill_len: usize) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), prefix);

    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'x');
    var remaining = fill_len;
    while (remaining > 0) {
        const n = @min(remaining, chunk.len);
        try file.writeStreamingAll(io_mod.getIo(), chunk[0..n]);
        remaining -= n;
    }
}

fn readTraceFileForTest(alloc: Allocator, trace_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(io_mod.getIo());
    var read_buf: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    return reader.interface.allocRemaining(alloc, std.Io.Limit.limited(64 * 1024));
}

const WebSearchBackendFixture = struct {
    calls: usize = 0,

    fn search(
        raw_ctx: *anyopaque,
        ctx: tool_dispatch.DispatchContext,
        request: web_search_contract.Request,
    ) anyerror!web_search_contract.ExecutionOutput {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        if (ctx.on_web_search_progress) |on_progress| {
            on_progress(ctx.web_search_progress_ctx.?, ctx.tool_call_id, .{ .query_started = request.query });
            on_progress(ctx.web_search_progress_ctx.?, ctx.tool_call_id, .{ .results_received = .{
                .query = request.query,
                .result_count = 3,
            } });
        }
        return .{
            .output = .{
                .query = request.query,
                .results = &.{},
                .duration_ms = 17,
                .web_search_requests = 2,
            },
            .inner_usage = .{ .input_tokens = 12, .output_tokens = 34, .web_search_requests = 2 },
        };
    }
};

const WebSearchProgressCapture = struct {
    searching_count: usize = 0,
    found_count: usize = 0,
    call_id: []const u8 = "",
    query_buf: [128]u8 = undefined,
    query_len: usize = 0,
    result_count: usize = 0,

    fn onProgress(raw_ctx: *anyopaque, call_id: []const u8, progress: types.WebSearchProgress) void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.call_id = call_id;
        switch (progress) {
            .query_started => |query| {
                self.searching_count += 1;
                self.setQuery(query);
            },
            .results_received => |update| {
                self.found_count += 1;
                self.setQuery(update.query);
                self.result_count = update.result_count;
            },
        }
    }

    fn setQuery(self: *@This(), query: []const u8) void {
        self.query_len = @min(self.query_buf.len, query.len);
        @memcpy(self.query_buf[0..self.query_len], query[0..self.query_len]);
    }

    fn queryView(self: *const @This()) []const u8 {
        return self.query_buf[0..self.query_len];
    }
};

fn expectToolOutput(ctx: Context, tool_name: []const u8, args_json: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try executeToolCall(ctx, arena, .{
        .id = "1",
        .name = tool_name,
        .arguments_json = args_json,
    });
    try std.testing.expectEqualStrings(expected, result.model_output);
    if (result.diff_entry) |payload| {
        diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    }
}

fn absolutePathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn setTestHome(home: ?[]const u8) !void {
    const map = try std.heap.c_allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(std.heap.c_allocator);
    if (home) |value| try map.put("HOME", value);
    io_mod.setEnvironMap(map);
}

test "tool runtime explicit cancellation source overrides worker fallback" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var rt = TestRuntime{ .cancel_flag = &cancel_flag };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expect(typedDispatchContext(rt.context(), arena_state.allocator()).cancel_flag.? == &cancel_flag);
}

test "agent terminal lease cleanup ignores preexisting turn cancellation" {
    var cancel_flag = std.atomic.Value(bool).init(true);
    var rt = TestRuntime{ .cancel_flag = &cancel_flag };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const cleanup = terminal_lease_cleanup_dispatch_context(
        rt.context(),
        arena_state.allocator(),
    );
    try std.testing.expect(cleanup.cancel_flag == null);
}

test "read-only local runtime tools are registered in built-in registry" {
    const cases = [_]struct {
        name: []const u8,
        kind: tool_specs.ExecutorKind,
    }{
        .{ .name = "glob_files", .kind = .glob_files },
        .{ .name = "grep_files", .kind = .grep_files },
        .{ .name = "read_file", .kind = .read_file },
        .{ .name = "read_tool_result", .kind = .read_tool_result },
    };

    var rt = TestRuntime{};
    defer rt.deinit(std.testing.allocator);
    const registry = rt.context().tool_registry;
    for (cases) |case| {
        const found = registry.lookup(case.name) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(case.kind, found.executor_kind);
    }
    const terminal_tool = test_builtin_tools.registry.lookup("shell") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(tool_specs.ExecutorKind.terminal, terminal_tool.executor_kind);
    try std.testing.expect(registry.lookup("run_command") == null);
}

test "tool runtime validates and executes only tools from supplied registry" {
    const alloc = std.testing.allocator;
    var empty_rt = TestRuntime{ .tool_registry = .{} };
    defer empty_rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const call = ToolCall{
        .id = "read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
    };
    try std.testing.expectEqual(
        tool_contracts.ToolCallValidationResult.not_registered,
        try validateToolCall(empty_rt.context(), arena, call),
    );

    const missing = try executeToolCall(empty_rt.context(), arena, call);
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, missing.status);
    try std.testing.expectEqualStrings("Unsupported tool: read_file", missing.model_output);

    const read_only_registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.read_file} };
    var read_rt = TestRuntime{ .tool_registry = read_only_registry };
    defer read_rt.deinit(alloc);
    try std.testing.expect((try validateToolCall(read_rt.context(), arena, call)) == .valid);
}

test "removed tool names are not callable" {
    var rt = TestRuntime{};
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "memory", "skill_search", "mcp_search_tools" }) |name| {
        const result = try executeToolCall(rt.context(), arena, .{
            .id = "removed-tool",
            .name = name,
            .arguments_json = "{\"query\":\"review runtime\"}",
        });
        try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
        const expected = try std.fmt.allocPrint(arena, "Unsupported tool: {s}", .{name});
        try std.testing.expectEqualStrings(expected, result.model_output);
    }
}

fn registryOwnedWebFetchCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned web_fetch") };
}

fn registryOwnedWebSearchCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned web_search") };
}

fn registryOwnedTerminalExecCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned terminal exec") };
}

fn registryOwnedAskQuestionCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    if (ctx.ask_question_ctx == null or ctx.ask_question_batch == null) {
        return error.InvalidToolArguments;
    }
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned ask_user_question") };
}

fn registryOwnedSkillCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned skill") };
}

fn registryOwnedInstallSkillCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned install_skill") };
}

fn registryOwnedCapabilitySearchCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned capability_search") };
}

fn registryOwnedMcpSelectCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned mcp_select_tool") };
}

const QuestionBridgeThreadState = struct {
    worker: *WorkerRuntime,
    entries: []const types.QuestionBatchEntry,
    answers: ?[][]u8 = null,
    err: ?Allocator.Error = null,
};

fn runQuestionBridge(state: *QuestionBridgeThreadState) void {
    state.answers = requestQuestionBatchWithWorker(
        state.worker,
        std.testing.allocator,
        state.entries,
    ) catch |err| {
        state.err = err;
        return;
    };
}

fn waitForQuestionBridgeSnapshot(worker: *WorkerRuntime) !worker_runtime.PendingQuestionBatchSnapshot {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try worker.snapshotPendingQuestionBatch(std.testing.allocator)) |snapshot| return snapshot;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

test "ask_user_question worker bridge preserves allocator ownership" {
    const worker_alloc = std.heap.c_allocator;
    const options = [_]types.QuestionOption{
        .{ .label = "Inspect repo state", .description = "Review local files first." },
        .{ .label = "Run tests", .description = "Start with verification." },
    };
    const entries = [_]types.QuestionBatchEntry{.{
        .question = "Choose next step?",
        .options = &options,
    }};

    var worker = WorkerRuntime{};
    defer worker.deinit(worker_alloc);
    var state = QuestionBridgeThreadState{
        .worker = &worker,
        .entries = &entries,
    };
    const thread = try std.Thread.spawn(.{}, runQuestionBridge, .{&state});
    var thread_joined = false;
    defer if (!thread_joined) {
        worker.requestStop();
        thread.join();
    };

    var snapshot = try waitForQuestionBridgeSnapshot(&worker);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Choose next step?", snapshot.entries[0].question);
    try worker.submitQuestionBatchAnswer(worker_alloc, &.{"Run tests"});
    thread.join();
    thread_joined = true;
    defer freeQuestionAnswers(std.testing.allocator, state.answers);

    try std.testing.expect(state.err == null);
    try std.testing.expectEqual(@as(usize, 1), state.answers.?.len);
    try std.testing.expectEqualStrings("Run tests", state.answers.?[0]);
}

test "ask_user_question execution uses supplied registry entry and interactive host capability" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_ask_question = test_builtin_tools.ask_user_question;
    registered_ask_question.call = registryOwnedAskQuestionCall;
    const tools = [_]tool_dispatch.Tool{registered_ask_question};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const call = ToolCall{
        .id = "ask-question-registry",
        .name = "ask_user_question",
        .arguments_json = "not-json",
    };

    var rt = TestRuntime{ .tool_registry = registry };
    defer rt.deinit(alloc);
    const result = try executeToolCallAuthorized(rt.context(), .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .ordinary,
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqualStrings("registry-owned ask_user_question", result.model_output);

    rt.worker.requestCancel();
    try std.testing.expectError(error.Cancelled, executeToolCallAuthorized(rt.context(), .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .ordinary,
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    }));
}

test "web_fetch execution uses supplied registry entry" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_web_fetch = test_builtin_tools.web_fetch;
    registered_web_fetch.call = registryOwnedWebFetchCall;
    const tools = [_]tool_dispatch.Tool{registered_web_fetch};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const call = ToolCall{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com/docs\"}",
    };

    var rt = TestRuntime{ .tool_registry = registry };
    defer rt.deinit(alloc);
    const direct = try executeToolCall(rt.context(), arena, call);
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, direct.status);
    try std.testing.expectEqualStrings("registry-owned web_fetch", direct.model_output);
}

test "web_search execution uses supplied registry entry" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_web_search = test_builtin_tools.web_search;
    registered_web_search.call = registryOwnedWebSearchCall;
    const tools = [_]tool_dispatch.Tool{registered_web_search};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    var backend = WebSearchBackendFixture{};
    var rt = TestRuntime{
        .tool_registry = registry,
        .web_search_runtime_ready = true,
        .web_search_backend = .{ .ctx = @ptrCast(&backend), .execute_fn = WebSearchBackendFixture.search },
    };
    defer rt.deinit(alloc);

    const result = try executeToolCall(rt.context(), arena, .{
        .id = "web-search-registry",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current news\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqualStrings("registry-owned web_search", result.model_output);
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "terminal exec execution uses supplied registry entry" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_run_command = test_builtin_tools.shell;
    registered_run_command.call = registryOwnedTerminalExecCall;
    const tools = [_]tool_dispatch.Tool{registered_run_command};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const call = ToolCall{
        .id = "run-command-registry",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf bypassed\",\"timeout_ms\":600000}",
    };

    var rt = TestRuntime{ .tool_registry = registry };
    defer rt.deinit(alloc);
    const ctx = rt.context();
    const command_ctx = try tool_admission.runCommandContext(ctx.admissionInput(), arena, call);
    const result = try executeToolCallAuthorized(ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .configured_rule,
        } } },
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqualStrings("registry-owned terminal exec", result.model_output);
}

test "stateful skill tool execution uses supplied registry entries" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_skill = test_builtin_tools.skill;
    registered_skill.call = registryOwnedSkillCall;
    var registered_install_skill = test_builtin_tools.install_skill;
    registered_install_skill.call = registryOwnedInstallSkillCall;

    const tools = [_]tool_dispatch.Tool{
        registered_skill,
        registered_install_skill,
    };
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };

    var rt = TestRuntime{ .tool_registry = registry };
    defer rt.deinit(alloc);

    const cases = [_]struct {
        name: []const u8,
        args: []const u8,
        expected: []const u8,
    }{
        .{ .name = "skill", .args = "{\"name\":\"workflow\"}", .expected = "registry-owned skill" },
        .{ .name = "install_skill", .args = "{\"source\":\"/tmp/skills\",\"skill\":\"workflow\"}", .expected = "registry-owned install_skill" },
    };

    for (cases) |case| {
        const result = try executeToolCall(rt.context(), arena, .{
            .id = "stateful",
            .name = case.name,
            .arguments_json = case.args,
        });
        try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
        try std.testing.expectEqualStrings(case.expected, result.model_output);
    }
}

test "capability and MCP selection execution preserve argument failures" {
    const alloc = std.testing.allocator;
    var rt = TestRuntime{};
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct {
        name: []const u8,
        args: []const u8,
        expected: []const u8,
    }{
        .{ .name = "capability_search", .args = "{\"query\":1}", .expected = "capability_search field \"query\" must be a string" },
        .{ .name = "mcp_select_tool", .args = "{\"name\":1}", .expected = "mcp_select_tool requires an exact dynamic tool name." },
    };

    for (cases) |case| {
        const result = try executeToolCall(rt.context(), arena, .{
            .id = "mcp_validation",
            .name = case.name,
            .arguments_json = case.args,
        });
        try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
        try std.testing.expectEqualStrings(case.expected, result.model_output);
    }
}

test "capability and MCP selection execution use supplied registry entries" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_search = test_builtin_tools.capability_search;
    registered_search.call = registryOwnedCapabilitySearchCall;
    var registered_select = test_builtin_tools.mcp_select_tool;
    registered_select.call = registryOwnedMcpSelectCall;
    const tools = [_]tool_dispatch.Tool{ registered_search, registered_select };
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };

    var rt = TestRuntime{ .tool_registry = registry };
    defer rt.deinit(alloc);

    const cases = [_]struct {
        name: []const u8,
        args: []const u8,
        expected: []const u8,
    }{
        .{ .name = "capability_search", .args = "{\"query\":\"read\"}", .expected = "registry-owned capability_search" },
        .{ .name = "mcp_select_tool", .args = "{\"name\":\"mcp_fs_read\"}", .expected = "registry-owned mcp_select_tool" },
    };

    for (cases) |case| {
        const result = try executeToolCall(rt.context(), arena, .{
            .id = "mcp_registry",
            .name = case.name,
            .arguments_json = case.args,
        });
        try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
        try std.testing.expectEqualStrings(case.expected, result.model_output);
    }
}

test "validateToolCall rejects malformed registered input without claiming unknown calls" {
    const alloc = std.testing.allocator;
    var rt = TestRuntime{};
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const invalid = try validateToolCall(rt.context(), arena, .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":1}",
    });
    try std.testing.expectEqualStrings("web_fetch field \"url\" must be a string", invalid.failure);

    try std.testing.expectEqual(tool_contracts.ToolCallValidationResult.not_registered, try validateToolCall(rt.context(), arena, .{
        .id = "dynamic",
        .name = "dynamic_tool",
        .arguments_json = "{}",
    }));
}

test "validateToolCall preserves the registered captured command host" {
    var rt = TestRuntime{ .tool_registry = test_browser_workspace_tools.registry };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expect((try validateToolCall(rt.context(), arena_state.allocator(), .{
        .id = "workspace-terminal",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf ok\"}",
    })) == .valid);
}

test "validateToolCall rejects selected MCP arguments through runtime capability" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var fixture = McpFixture.CountingContext{};
    const advertised = [_][]const u8{"mcp_fs_read"};
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&fixture),
        .mcp_validate_tool = McpFixture.validateArguments,
        .advertised_dynamic_tool_names = &advertised,
    };
    defer rt.deinit(alloc);

    const invalid = try validateToolCall(rt.context(), arena_state.allocator(), .{
        .id = "mcp-invalid",
        .name = "mcp_fs_read",
        .arguments_json = "{\"path\":7}",
    });
    try std.testing.expect(invalid == .failure);
    try std.testing.expectEqualStrings("path must be a string", invalid.failure);

    const valid = try validateToolCall(rt.context(), arena_state.allocator(), .{
        .id = "mcp-valid",
        .name = "mcp_fs_read",
        .arguments_json = "{\"path\":\"README.md\"}",
    });
    switch (valid) {
        .valid => |witness| try std.testing.expectEqual(
            @as(?u64, 41),
            witness.mcp_runtime_generation,
        ),
        .not_registered, .failure => return error.TestUnexpectedResult,
    }
}

test "checkToolAvailability rejects missing web_search runtime without catalog or network work" {
    const alloc = std.testing.allocator;
    var rt = TestRuntime{};
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const reason = try checkToolAvailability(rt.context(), arena_state.allocator(), .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current news\"}",
    }) orelse return error.TestExpectedEqual;

    try std.testing.expectEqualStrings(tool_dispatch.web_search_unavailable_message, reason);
}

test "validateToolCall rejects invalid private web_search before backend invocation" {
    const alloc = std.testing.allocator;
    var backend = WebSearchBackendFixture{};
    var rt = TestRuntime{
        .web_search_runtime_ready = true,
        .web_search_backend = .{ .ctx = @ptrCast(&backend), .execute_fn = WebSearchBackendFixture.search },
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const invalid = try validateToolCall(rt.context(), arena_state.allocator(), .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"x\"}",
    });

    try std.testing.expectEqualStrings("web_search field \"query\" must contain at least two characters", invalid.failure);
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "executeToolCall invokes injected private web_search backend" {
    const alloc = std.testing.allocator;
    var backend = WebSearchBackendFixture{};
    var rt = TestRuntime{
        .web_search_runtime_ready = true,
        .web_search_backend = .{ .ctx = @ptrCast(&backend), .execute_fn = WebSearchBackendFixture.search },
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current news\"}",
    });

    try std.testing.expectEqual(@as(usize, 1), backend.calls);
    try expectContains(result.model_output, "Web search results for query: current news");
    try std.testing.expectEqual(@as(u32, 2), result.inner_usage.?.web_search_requests);
}

test "valid allowed web_search emits searching query status" {
    const alloc = std.testing.allocator;
    var backend = WebSearchBackendFixture{};
    var progress = WebSearchProgressCapture{};
    var rt = TestRuntime{
        .web_search_runtime_ready = true,
        .web_search_backend = .{ .ctx = @ptrCast(&backend), .execute_fn = WebSearchBackendFixture.search },
        .web_search_progress_ctx = @ptrCast(&progress),
        .on_web_search_progress = WebSearchProgressCapture.onProgress,
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    _ = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "call_search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current news\"}",
    });

    try std.testing.expectEqual(@as(usize, 1), progress.searching_count);
    try std.testing.expectEqualStrings("call_search", progress.call_id);
    try std.testing.expectEqualStrings("current news", progress.queryView());
}

test "invalid web_search emits no searching status" {
    const alloc = std.testing.allocator;
    var backend = WebSearchBackendFixture{};
    var progress = WebSearchProgressCapture{};
    var rt = TestRuntime{
        .web_search_runtime_ready = true,
        .web_search_backend = .{ .ctx = @ptrCast(&backend), .execute_fn = WebSearchBackendFixture.search },
        .web_search_progress_ctx = @ptrCast(&progress),
        .on_web_search_progress = WebSearchProgressCapture.onProgress,
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const invalid = try validateToolCall(rt.context(), arena_state.allocator(), .{
        .id = "call_search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"x\"}",
    });

    try std.testing.expectEqualStrings("web_search field \"query\" must contain at least two characters", invalid.failure);
    try std.testing.expectEqual(@as(usize, 0), progress.searching_count);
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "web_search emits found result count status" {
    const alloc = std.testing.allocator;
    var backend = WebSearchBackendFixture{};
    var progress = WebSearchProgressCapture{};
    var rt = TestRuntime{
        .web_search_runtime_ready = true,
        .web_search_backend = .{ .ctx = @ptrCast(&backend), .execute_fn = WebSearchBackendFixture.search },
        .web_search_progress_ctx = @ptrCast(&progress),
        .on_web_search_progress = WebSearchProgressCapture.onProgress,
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    _ = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "call_search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current news\"}",
    });

    try std.testing.expectEqual(@as(usize, 1), progress.found_count);
    try std.testing.expectEqual(@as(usize, 3), progress.result_count);
}

test "web_search completion includes searches and duration" {
    const alloc = std.testing.allocator;
    var backend = WebSearchBackendFixture{};
    var rt = TestRuntime{
        .web_search_runtime_ready = true,
        .web_search_backend = .{ .ctx = @ptrCast(&backend), .execute_fn = WebSearchBackendFixture.search },
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "call_search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current news\"}",
    });

    const completion = result.web_search_completion orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 2), completion.searches);
    try std.testing.expectEqual(@as(u64, 17), completion.duration_ms);
}

test "web_fetch uses the configured shared runtime" {
    const alloc = std.testing.allocator;
    var fetch_runtime = web_fetch_runtime.Runtime.init(.{ .allocator = alloc });
    defer fetch_runtime.deinit(alloc);
    try fetch_runtime.insert(alloc, .{
        .submitted_url = "https://example.com/file.bin",
        .final_url = "https://example.com/file.bin",
        .status = .ok,
        .mime_type = "application/octet-stream",
        .content_kind = .binary,
    });

    const builtin_tools = @import("../../builtins/tools.zig");
    var rt = TestRuntime{ .tool_registry = builtin_tools.registry, .web_fetch_runtime = &fetch_runtime };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const ctx = rt.context();
    try std.testing.expect(ctx.web_fetch_runtime.? == &fetch_runtime);
    try std.testing.expect(ctx.web_fetch_artifact_store == null);

    const call = ToolCall{ .id = "fetch", .name = "web_fetch", .arguments_json = "{\"url\":\"https://example.com/file.bin\"}" };
    const direct = try executeToolCall(ctx, arena_state.allocator(), call);
    try std.testing.expect(direct.web_fetch_completion.?.cache_hit);
    try std.testing.expectEqualStrings("https://example.com/file.bin", direct.web_fetch_completion.?.url());
}

test "parent web_fetch tool-call metric omits URL and fetched result content" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    var fetch_runtime = web_fetch_runtime.Runtime.init(.{ .allocator = alloc });
    defer fetch_runtime.deinit(alloc);
    try fetch_runtime.insert(alloc, .{
        .submitted_url = "https://example.com/docs",
        .final_url = "https://example.com/docs",
        .status = .ok,
        .mime_type = "text/plain",
        .content_kind = .text,
        .converted_content = "FETCHED_PAGE_SECRET_RAW",
    });

    const builtin_tools = @import("../../builtins/tools.zig");
    var rt = TestRuntime{ .tool_registry = builtin_tools.registry, .web_fetch_runtime = &fetch_runtime };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com/docs\"}",
    });
    try expectContains(result.model_output, "FETCHED_PAGE_SECRET_RAW");

    var buf: [diagnostics.tool_call_ring_capacity]diagnostics.ToolCallMetric = undefined;
    const n = diagnostics.snapshotToolCalls(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("web_fetch", buf[0].name());
    try std.testing.expectEqual(diagnostics.ToolCallOutcome.succeeded, buf[0].outcome);
    try std.testing.expectEqualStrings("", buf[0].args());
    try std.testing.expectEqualStrings("", buf[0].result());
    try std.testing.expectEqual(@as(u32, 0), buf[0].args_total_bytes);
    try std.testing.expectEqual(@as(u32, 0), buf[0].result_total_bytes);
    try expectNotContains(buf[0].result(), "FETCHED_PAGE_SECRET_RAW");
}

test "non-web_fetch tool-call metrics retain bounded args and result" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    diagnostics.recordToolCallResult(.{
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
        .model_output = "<path>README.md</path>\n<content>\n# fx\nnormal result\n</content>",
        .outcome = .succeeded,
        .started_at_ms = 1000,
    });

    var buf: [diagnostics.tool_call_ring_capacity]diagnostics.ToolCallMetric = undefined;
    const n = diagnostics.snapshotToolCalls(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("read_file", buf[0].name());
    try expectContains(buf[0].args(), "README.md");
    try expectContains(buf[0].result(), "# fx");
    try expectContains(buf[0].result(), "normal result");
}

test "request tool permission keeps safe defaults while local writes bypass review" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{
        .workspace_root = root,
        .permission_mode = .auto,
        .interactive = false,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "1",
        .name = "write_file",
        .arguments_json = "{\"path\":\"fx-permission-test.txt\",\"content\":\"hello\"}",
    }, .auto, &.{})).decision);

    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "1",
        .name = "glob_files",
        .arguments_json = "{\"pattern\":\"*\"}",
    }, .ask, &.{})).decision);

    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "1",
        .name = "ask_user_question",
        .arguments_json = "{}",
    }, .ask, &.{})).decision);
}

test "run_command default user profile requires configured or reviewed shell authority" {
    const alloc = std.testing.allocator;
    var reviewer = TestAutoReview{};
    var rt = TestRuntime{
        .workspace_root = "/tmp/workspace",
        .interactive = false,
        .auto_classifier = reviewer.classifier(),
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const direct = (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "direct",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"pwd\"}",
    }, .ask, &.{}));
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, direct.decision);
    try std.testing.expect(direct.execution_authority == null);

    const blocked = (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "blocked",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"touch blocked.txt\"}",
    }, .ask, &.{}));
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, blocked.decision);
    try std.testing.expect(blocked.execution_authority == null);

    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("bash"), .pattern = @constCast("touch *"), .action = .allow },
    };
    rt.permission_rules = .{ .rules = &rules };
    const configured = (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "configured",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"touch configured.txt\"}",
    }, .ask, &.{}));
    switch ((configured.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(command_admission.ShellAuthorizationSource.configured_rule, authority.source),
    }
    try std.testing.expectEqual(@as(usize, 0), reviewer.calls);

    rt.permission_rules = .{};
    const automatic = (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "automatic",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"touch automatic.txt\"}",
    }, .auto, &.{}));
    switch ((automatic.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(command_admission.ShellAuthorizationSource.auto_classifier, authority.source),
    }
    try std.testing.expectEqual(@as(usize, 1), reviewer.calls);
    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.Action).command,
        reviewer.action_tag.?,
    );
    try std.testing.expectEqualStrings("touch automatic.txt", reviewer.exact_command.?);
}

test "tool context projects immutable session permission state into admission" {
    const alloc = std.testing.allocator;
    var rt = TestRuntime{ .workspace_root = "/tmp/workspace", .interactive = false };
    defer rt.deinit(alloc);
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("touch *"),
        .action = .allow,
    }};
    rt.permission_rules = .{ .rules = &rules };
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = ToolCall{
        .id = "runtime-session-deny",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"touch configured.txt\"}",
    };
    const key = try tool_admission.permissionStateKeyForCall(
        rt.context().admissionInput(),
        arena,
        call,
    );
    try std.testing.expectEqual(
        session_permission_state.ApplyStatus.applied,
        try rt.session.applyPermissionEvent(alloc, .{ .set = .{
            .key = key,
            .display_identity = "touch configured.txt",
            .decision = .deny,
            .expected_generation = null,
        } }),
    );

    const outcome = try tool_admission.requestPermissionOutcome(
        rt.context().admissionInput(),
        arena,
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, outcome.decision);
    try std.testing.expect(outcome.execution_authority == null);
}

test "local file mutations bypass review while external mutations use exact review" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/x");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var reviewer = TestAutoReview{};
    var rt = TestRuntime{
        .workspace_root = workspace,
        .permission_mode = .auto,
        .interactive = false,
        .auto_classifier = reviewer.classifier(),
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const targets = [_][]const u8{
        try std.fs.path.join(arena, &.{ workspace, "approved-local.txt" }),
        try std.fs.path.join(arena, &.{ external, "approved-external.txt" }),
    };
    for (targets, 0..) |target, index| {
        const args = try std.fmt.allocPrint(
            arena,
            "{{\"path\":\"{s}\",\"content\":\"alpha\\nbeta\\n\"}}",
            .{target},
        );
        const call: ToolCall = .{
            .id = if (index == 0) "approved-local-write" else "approved-external-write",
            .name = "write_file",
            .arguments_json = args,
        };
        const outcome = try tool_admission.requestPermissionOutcome(
            rt.context().admissionInput(),
            arena,
            call,
            .auto,
            &.{},
        );
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
        const authority = switch (outcome.execution_authority orelse
            return error.TestExpectedEqual) {
            .file_mutation => |value| value,
            else => return error.UnexpectedExecutionAuthority,
        };
        const prepared = authority.prepared orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(@as(usize, 2), prepared.review.additions);
        try std.testing.expectEqual(@as(usize, 0), prepared.review.deletions);
        try std.testing.expectEqual(@as(usize, 0), reviewer.calls);
        try std.testing.expect(rt.worker.pending_permission_request_shared == null);
        try std.testing.expect(!absolutePathExists(target));
    }
}

test "main file mutation producer rejects wildcard-bearing grant roots before prompt publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace = try io_mod.dirRealpathAlloc(arena, tmp.dir, "workspace");
    const Scope = enum { workspace, external };

    for ([_]u8{ '*', '?' }) |wildcard| {
        for ([_]Scope{ .workspace, .external }) |scope| {
            const prefix = if (scope == .workspace) "workspace" else "external";
            const dir_name = try std.fmt.allocPrint(
                arena,
                "{s}{c}literal",
                .{ prefix, wildcard },
            );
            try tmp.dir.createDirPath(io_mod.getIo(), dir_name);
            const literal_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, dir_name);
            const edit_path = try std.fs.path.join(arena, &.{ dir_name, "edit.txt" });
            {
                var file = try tmp.dir.createFile(
                    io_mod.getIo(),
                    edit_path,
                    .{ .truncate = true },
                );
                defer file.close(io_mod.getIo());
                try file.writeStreamingAll(io_mod.getIo(), "before\n");
            }

            for ([_]file_mutation_contract.Kind{ .write, .edit }) |kind| {
                const basename = if (kind == .write) "write.txt" else "edit.txt";
                const target_path = try std.fs.path.join(
                    arena,
                    &.{ literal_root, basename },
                );
                const preflight = try tool_admission.preflightFileMutation(
                    arena,
                    .{
                        .id = "wildcard-main",
                        .name = if (kind == .write) "write_file" else "edit_file",
                        .arguments_json = try testFileMutationArgs(
                            arena,
                            kind,
                            target_path,
                        ),
                    },
                    .{
                        .tool_registry = test_tool_registry,
                        .workspace_root = if (scope == .workspace)
                            literal_root
                        else
                            workspace,
                        .permission_rules = .{},
                        .permission_mode = .ask,
                        .can_prompt = true,
                    },
                );
                switch (preflight) {
                    .tool_failure => |reason| try std.testing.expectEqualStrings(
                        "file mutation permission scope could not be represented safely",
                        reason,
                    ),
                    else => return error.TestExpectedToolFailure,
                }
            }
        }
    }
}

test "main file mutation prompts project producer-backed workspace and external scopes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    {
        var file = try tmp.dir.createFile(
            io_mod.getIo(),
            "workspace/edit.txt",
            .{ .truncate = true },
        );
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "before\n");
    }
    {
        var file = try tmp.dir.createFile(
            io_mod.getIo(),
            "external/edit.txt",
            .{ .truncate = true },
        );
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "before\n");
    }
    {
        var file = try tmp.dir.createFile(
            io_mod.getIo(),
            "workspace/max-edit.txt",
            .{ .truncate = true },
        );
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "before\n");
    }

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace_write = try std.fs.path.join(
        arena,
        &.{ workspace, "write.txt" },
    );
    const workspace_edit = try std.fs.path.join(
        arena,
        &.{ workspace, "edit.txt" },
    );
    const external_write = try std.fs.path.join(
        arena,
        &.{ external, "write.txt" },
    );
    const external_edit = try std.fs.path.join(
        arena,
        &.{ external, "edit.txt" },
    );
    const max_write_path = try testMaxAdmittedLexicalPath(
        arena,
        "max-write.txt",
    );
    const max_edit_path = try testMaxAdmittedLexicalPath(
        arena,
        "max-edit.txt",
    );
    try std.testing.expectEqual(
        std.Io.Dir.max_path_bytes,
        max_write_path.len,
    );
    try std.testing.expectEqual(
        std.Io.Dir.max_path_bytes,
        max_edit_path.len,
    );
    const workspace_pattern = try std.fmt.allocPrint(
        arena,
        "{s}/**",
        .{workspace},
    );
    const external_pattern = try std.fmt.allocPrint(
        arena,
        "{s}/**",
        .{external},
    );

    const cases = [_]struct {
        call: ToolCall,
        kind: file_mutation_contract.Kind,
        external_scope: ?[]const u8,
        grant_target: []const u8,
        basename: []const u8,
    }{
        .{
            .call = .{
                .id = "workspace-write",
                .name = "write_file",
                .arguments_json = try testFileMutationArgs(
                    arena,
                    .write,
                    workspace_write,
                ),
            },
            .kind = .write,
            .external_scope = null,
            .grant_target = workspace_pattern,
            .basename = "write.txt",
        },
        .{
            .call = .{
                .id = "workspace-edit",
                .name = "edit_file",
                .arguments_json = try testFileMutationArgs(
                    arena,
                    .edit,
                    workspace_edit,
                ),
            },
            .kind = .edit,
            .external_scope = null,
            .grant_target = workspace_pattern,
            .basename = "edit.txt",
        },
        .{
            .call = .{
                .id = "external-write",
                .name = "write_file",
                .arguments_json = try testFileMutationArgs(
                    arena,
                    .write,
                    external_write,
                ),
            },
            .kind = .write,
            .external_scope = external,
            .grant_target = external_pattern,
            .basename = "write.txt",
        },
        .{
            .call = .{
                .id = "external-edit",
                .name = "edit_file",
                .arguments_json = try testFileMutationArgs(
                    arena,
                    .edit,
                    external_edit,
                ),
            },
            .kind = .edit,
            .external_scope = external,
            .grant_target = external_pattern,
            .basename = "edit.txt",
        },
        .{
            .call = .{
                .id = "max-workspace-write",
                .name = "write_file",
                .arguments_json = try testFileMutationArgs(
                    arena,
                    .write,
                    max_write_path,
                ),
            },
            .kind = .write,
            .external_scope = null,
            .grant_target = workspace_pattern,
            .basename = "max-write.txt",
        },
        .{
            .call = .{
                .id = "max-workspace-edit",
                .name = "edit_file",
                .arguments_json = try testFileMutationArgs(
                    arena,
                    .edit,
                    max_edit_path,
                ),
            },
            .kind = .edit,
            .external_scope = null,
            .grant_target = workspace_pattern,
            .basename = "max-edit.txt",
        },
    };

    for (cases) |case| {
        var rt = TestRuntime{
            .workspace_root = workspace,
            .permission_mode = .ask,
        };
        defer rt.deinit(alloc);
        rt.worker.worker_processing = true;

        var state: FilePermissionThreadState = .{
            .expected_grant_target = case.grant_target,
            .expected_workspace_offer = case.external_scope == null,
        };
        const thread = try std.Thread.spawn(
            .{},
            runFilePermissionOutcome,
            .{ &state, rt.context(), case.call, PermissionMode.ask },
        );
        var thread_joined = false;
        defer if (!thread_joined) {
            rt.worker.requestShutdown();
            thread.join();
        };

        const request_id = try waitForPermissionPrompt(
            &rt.worker,
            "file_mutation",
        );
        var snapshot = try rt.worker.snapshotState(alloc);
        defer snapshot.deinit(alloc);
        const request = snapshot.pending_permission_request orelse
            return error.TestExpectedEqual;
        const file_request = request.file orelse
            return error.TestExpectedEqual;
        try std.testing.expectEqualStrings("file_mutation", request.label);
        try std.testing.expectEqual(case.kind, file_request.kind);
        try std.testing.expectEqual(
            file_mutation_contract.FileApprovalIntent.mutation,
            file_request.intent,
        );
        if (case.external_scope) |expected_root| {
            switch (file_request.scope) {
                .workspace_files => return error.TestExpectedExternalScope,
                .external_tree => |root| try std.testing.expectEqualStrings(
                    expected_root,
                    root,
                ),
            }
        } else {
            try std.testing.expect(file_request.scope == .workspace_files);
        }
        try std.testing.expect(
            std.mem.find(u8, request.label, file_request.preview.path) == null,
        );
        try std.testing.expectEqualStrings(
            case.basename,
            file_request.preview.path[file_request.preview.path_basename_start..],
        );

        try std.testing.expectEqual(
            worker_runtime.PermissionSubmissionResult.accepted,
            rt.worker.submitPermissionResponse(
                request_id,
                permission_request.OwnedPermissionResponse.init(std.testing.allocator, .once, null),
            ),
        );
        thread.join();
        thread_joined = true;
        try std.testing.expect(state.err == null);
        try std.testing.expect(state.file_authority);
        try std.testing.expect(state.prepared);
        try std.testing.expect(state.frozen_offer_matches);
    }
}

test "file mutation lifecycle decodes each call at most once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    {
        var file = try tmp.dir.createFile(
            io_mod.getIo(),
            "workspace/same.txt",
            .{ .truncate = true },
        );
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "same\n");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var call_arena_state = std.heap.ArenaAllocator.init(alloc);
    var call_arena_live = true;
    defer if (call_arena_live) call_arena_state.deinit();
    const call_arena = call_arena_state.allocator();
    var result_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer result_arena_state.deinit();
    const result_arena = result_arena_state.allocator();

    var deny_rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("**"),
        .action = .deny,
    }};
    const prompted_target = try std.fs.path.join(
        call_arena,
        &.{ external, "prompted.txt" },
    );
    const prompted_args = try std.fmt.allocPrint(
        call_arena,
        "{{\"path\":\"{s}\",\"content\":\"prompted\"}}",
        .{prompted_target},
    );
    const PreflightTag = std.meta.Tag(tool_admission.FileMutationPreflight);
    const cases = [_]struct {
        call: ToolCall,
        rules: types.PermissionRuleSet = .{},
        can_prompt: bool = false,
        expected: PreflightTag,
    }{
        .{
            .call = .{ .id = "malformed", .name = "write_file", .arguments_json = "{" },
            .expected = .tool_failure,
        },
        .{
            .call = .{
                .id = "denied",
                .name = "write_file",
                .arguments_json = "{\"path\":\"denied.txt\",\"content\":\"blocked\"}",
            },
            .rules = .{ .rules = &deny_rules },
            .expected = .policy_denied,
        },
        .{
            .call = .{
                .id = "prompted",
                .name = "write_file",
                .arguments_json = prompted_args,
            },
            .can_prompt = true,
            .expected = .prompt,
        },
        .{
            .call = .{
                .id = "no-op",
                .name = "write_file",
                .arguments_json = "{\"path\":\"same.txt\",\"content\":\"same\\n\"}",
            },
            .expected = .allowed,
        },
        .{
            .call = .{
                .id = "allowed",
                .name = "write_file",
                .arguments_json = "{\"path\":\"allowed.txt\",\"content\":\"allowed\"}",
            },
            .expected = .permission_required,
        },
    };
    for (cases) |case| {
        const outcome = try tool_admission.preflightFileMutation(call_arena, case.call, .{
            .tool_registry = test_tool_registry,
            .workspace_root = workspace,
            .permission_rules = case.rules,
            .permission_mode = .auto,
            .can_prompt = case.can_prompt,
        });
        try std.testing.expectEqual(case.expected, std.meta.activeTag(outcome));
    }
    try std.testing.expect(!absolutePathExists(prompted_target));

    const committed_call: ToolCall = .{
        .id = "committed",
        .name = "write_file",
        .arguments_json = "{\"path\":\"committed.txt\",\"content\":\"committed\\n\"}",
    };
    var allow_rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("**"),
        .action = .allow,
    }};
    const committed_authorization = switch (try tool_admission.preflightFileMutation(
        call_arena,
        committed_call,
        .{
            .tool_registry = test_tool_registry,
            .workspace_root = workspace,
            .permission_rules = .{ .rules = &allow_rules },
            .permission_mode = .auto,
            .can_prompt = false,
        },
    )) {
        .allowed => |authorization| authorization,
        else => return error.TestExpectedAllowed,
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    var rt = TestRuntime{
        .workspace_root = workspace,
        .permission_mode = .auto,
        .cancel_flag = &cancel_flag,
    };
    defer rt.deinit(alloc);
    const applied = try executeToolCallAuthorized(rt.context(), .{
        .call_allocator = call_arena,
        .result_allocator = result_arena,
        .call = committed_call,
        .authority = .{ .file_mutation = committed_authorization },
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = 64 * 1024,
    });
    try std.testing.expectEqual(
        tool_contracts.ToolExecutionStatus.success,
        applied.status,
    );
    try std.testing.expect(applied.committed_file_handoff != null);
    try std.testing.expect(applied.tool_result_memory_prepared);
    try std.testing.expect(applied.tool_result_memory != null);
    call_arena_state.deinit();
    call_arena_live = false;
    try std.testing.expectEqualStrings(
        "wrote committed.txt (10 bytes)",
        applied.model_output,
    );
    try std.testing.expectEqualStrings(
        "committed.txt",
        applied.committed_file_handoff.?.preview.path,
    );
    var committed_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "workspace/committed.txt",
        .{},
    );
    defer committed_file.close(io_mod.getIo());
    const committed_content = try io_mod.readFileToEnd(
        result_arena,
        &committed_file,
        64,
    );
    try std.testing.expectEqualStrings("committed\n", committed_content);
}

test "file mutation preflight separates edit approval from equality disclosure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    {
        var file = try tmp.dir.createFile(
            io_mod.getIo(),
            "workspace/same.txt",
            .{ .truncate = true },
        );
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "same\n");
    }
    {
        var file = try tmp.dir.createFile(
            io_mod.getIo(),
            "external/private.txt",
            .{ .truncate = true },
        );
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "private\n");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const private_target = try std.fs.path.join(
        arena,
        &.{ external, "private.txt" },
    );
    const private_pattern = try std.fmt.allocPrint(
        arena,
        "{s}/**",
        .{external},
    );
    var equality_rules = [_]types.PermissionRule{
        .{
            .permission = @constCast("read"),
            .pattern = private_pattern,
            .action = .deny,
        },
        .{
            .permission = @constCast("edit"),
            .pattern = private_pattern,
            .action = .allow,
        },
    };
    const private_noop_args = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"private\\n\"}}",
        .{private_target},
    );
    const private_changed_args = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"changed\\n\"}}",
        .{private_target},
    );
    const PreflightTag = std.meta.Tag(tool_admission.FileMutationPreflight);
    const cases = [_]struct {
        call: ToolCall,
        rules: types.PermissionRuleSet = .{},
        permission_mode: PermissionMode,
        can_prompt: bool,
        expected: PreflightTag,
    }{
        .{
            .call = .{
                .id = "authorized-no-op",
                .name = "write_file",
                .arguments_json = "{\"path\":\"same.txt\",\"content\":\"same\\n\"}",
            },
            .permission_mode = .ask,
            .can_prompt = true,
            .expected = .allowed,
        },
        .{
            .call = .{
                .id = "read-denied-no-op",
                .name = "write_file",
                .arguments_json = private_noop_args,
            },
            .rules = .{ .rules = &equality_rules },
            .permission_mode = .auto,
            .can_prompt = true,
            .expected = .prompt,
        },
        .{
            .call = .{
                .id = "read-denied-no-op-noninteractive",
                .name = "write_file",
                .arguments_json = private_noop_args,
            },
            .rules = .{ .rules = &equality_rules },
            .permission_mode = .auto,
            .can_prompt = false,
            .expected = .permission_required,
        },
        .{
            .call = .{
                .id = "read-denied-changed",
                .name = "write_file",
                .arguments_json = private_changed_args,
            },
            .rules = .{ .rules = &equality_rules },
            .permission_mode = .auto,
            .can_prompt = false,
            .expected = .allowed,
        },
    };

    for (cases) |case| {
        const outcome = try tool_admission.preflightFileMutation(arena, case.call, .{
            .tool_registry = test_tool_registry,
            .workspace_root = workspace,
            .permission_rules = case.rules,
            .permission_mode = case.permission_mode,
            .can_prompt = case.can_prompt,
        });
        try std.testing.expectEqual(case.expected, std.meta.activeTag(outcome));
        const authorization = switch (outcome) {
            .allowed => |value| value,
            .prompt => |value| value,
            .permission_required => |value| value,
            .policy_denied, .tool_failure => return error.TestExpectedAuthorization,
        };
        try std.testing.expect(authorization.prepared != null);
    }
}

test "disabled automatic reviewer returns a recoverable denial without a human prompt" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var rt = TestRuntime{ .workspace_root = root, .interactive = false };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try std.fs.path.join(arena, &.{ external, "created.txt" });
    {
        var existing = try tmp.dir.createFile(
            io_mod.getIo(),
            "external/created.txt",
            .{ .truncate = true },
        );
        defer existing.close(io_mod.getIo());
        try existing.writeStreamingAll(io_mod.getIo(), "before");
    }
    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"content\":\"hello\"}}", .{target});

    const outcome = try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "external-write",
        .name = "write_file",
        .arguments_json = args,
    }, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.review_unavailable, outcome.denial_reason.?);
    try std.testing.expect(outcome.requirement == null);
    try std.testing.expect(outcome.execution_authority == null);
    try std.testing.expect(outcome.auto_review_result == null);
    try std.testing.expect(rt.worker.pending_permission_request_shared == null);
}

test "web_fetch permits valid public hosts by default" {
    var rt = TestRuntime{ .workspace_root = "/tmp/workspace", .permission_mode = .auto, .interactive = false };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://docs.vercel.com/frameworks/nextjs\"}",
    }, .auto, &.{})).decision);
}

test "web_fetch exact session grant authorizes only matching canonical domain" {
    var rt = TestRuntime{ .workspace_root = "/tmp/workspace", .permission_mode = .auto, .interactive = false };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const grants = [_]PermissionGrant{
        .{ .tool_name = @constCast("web_fetch"), .target_path = @constCast("domain:example.com") },
    };
    var ask_rules = [_]types.PermissionRule{
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:example.com"), .action = .ask },
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:example.org"), .action = .ask },
    };
    rt.permission_rules = .{ .rules = &ask_rules };

    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com/docs\"}",
    }, .auto, &grants)).decision);

    try std.testing.expectEqual(ToolPermissionDecision.permission_required, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "fetch_other",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.org/docs\"}",
    }, .auto, &grants)).decision);
}

test "request tool permission honors configured deny and allow rules" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/src");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/src/app.zig", .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "pub fn main() void {}\n");
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{
        .workspace_root = root,
        .permission_mode = .auto,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var deny_rules = [_]types.PermissionRule{
        .{ .permission = @constCast("grep"), .pattern = @constCast("src"), .action = .deny },
    };
    rt.permission_rules = .{ .rules = &deny_rules };
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "1",
        .name = "grep_files",
        .arguments_json = "{\"pattern\":\"TODO\",\"path\":\"src\"}",
    }, .ask, &.{})).decision);

    var allow_rules = [_]types.PermissionRule{
        .{ .permission = @constCast("*"), .pattern = @constCast("*"), .action = .ask },
        .{ .permission = @constCast("read"), .pattern = @constCast("src/app.zig"), .action = .allow },
    };
    rt.permission_rules = .{ .rules = &allow_rules };
    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/app.zig\"}",
    }, .ask, &.{})).decision);
}

test "executeToolCall rejects overlong glob pattern with failure status" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    const pattern = try alloc.alloc(u8, glob_pattern.max_pattern_bytes + 1);
    defer alloc.free(pattern);
    @memset(pattern, 'a');

    var rt = TestRuntime{ .workspace_root = root };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.fmt.allocPrint(arena, "{{\"pattern\":\"{s}\"}}", .{pattern});

    const result = try executeToolCall(rt.context(), arena, .{
        .id = "glob",
        .name = "glob_files",
        .arguments_json = args,
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    const expected = try std.fmt.allocPrint(arena, "glob_files field \"pattern\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes});
    try std.testing.expectEqualStrings(expected, result.model_output);
}

test "executeToolCall glob_files finds match beyond former traversal cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var i: usize = 0;
    while (i < 2050) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "workspace/many/file-{d:0>4}.txt", .{i});
        try writeTestFile(tmp.dir, name, "not here\n");
    }
    try writeTestFile(tmp.dir, "workspace/zzzz/target.zig", "target\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{ .workspace_root = root };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "glob",
        .name = "glob_files",
        .arguments_json = "{\"pattern\":\"**/*.zig\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try expectContains(result.model_output, "zzzz/target.zig");
    try std.testing.expect(std.mem.find(u8, result.model_output, "traversal cap") == null);
}

test "executeToolCall carries authoritative read coverage metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeTestFile(tmp.dir, "workspace/notes.txt", "one\ntwo\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{ .workspace_root = root };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const full = try executeToolCall(rt.context(), arena, .{
        .id = "full",
        .name = "read_file",
        .arguments_json = "{\"path\":\"notes.txt\"}",
    });
    try std.testing.expect(
        full.tool_result_memory.?.model_view_covers_full_file.?,
    );

    const partial = try executeToolCall(rt.context(), arena, .{
        .id = "partial",
        .name = "read_file",
        .arguments_json = "{\"path\":\"notes.txt\",\"start_line\":2,\"line_count\":1}",
    });
    try std.testing.expect(
        !partial.tool_result_memory.?.model_view_covers_full_file.?,
    );
}

test "executeToolCall traces non-text grep skips in normal runtime" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/binaryish/blob.bin", "binary\x00needle\x01\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var rt = TestRuntime{ .workspace_root = root };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "grep",
        .name = "grep_files",
        .arguments_json = "{\"pattern\":\"needle\",\"path\":\"binaryish\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n", result.model_output);

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try expectContains(trace, "grep_files skipped non-text file path=");
    try expectContains(trace, "binaryish/blob.bin");
}

test "executeToolCall traces oversized grep skips in normal runtime" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeLargeTestFile(tmp.dir, "workspace/oversized/huge.txt", "needle hidden\n", 260 * 1024);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var rt = TestRuntime{ .workspace_root = root };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "grep",
        .name = "grep_files",
        .arguments_json = "{\"pattern\":\"needle\",\"path\":\"oversized\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqualStrings("[grep] no matches for needle\n", result.model_output);

    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try expectContains(trace, "grep_files skipped oversized file path=");
    try expectContains(trace, "oversized/huge.txt");
}

test "executeToolCall returns failure status for missing grep path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{ .workspace_root = root };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "grep",
        .name = "grep_files",
        .arguments_json = "{\"pattern\":\"needle\",\"path\":\"missing/nope.txt\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "Unable to resolve grep search root: missing/nope.txt (FileNotFound)");
}

test "executeToolCall returns friendly failure for missing read_file path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{ .workspace_root = root };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"missing/nope.txt\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try std.testing.expect(!result.finish_turn);
    try expectToolErrorField(result.model_output, "type", "tool_execution_failed");
    try expectToolErrorField(result.model_output, "tool_name", "read_file");
    try expectToolErrorDetailString(result.model_output, "field", "path");
    try expectToolErrorDetailString(result.model_output, "path", "missing/nope.txt");
    try expectToolErrorDetailString(result.model_output, "error", "FileNotFound");
    try expectContains(result.model_output, "glob_files");
    try expectNotContains(result.model_output, "Tool read_file failed: FileNotFound");
}

test "executeToolCall preserves explicit ignored directory grep roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/node_modules/pkg/index.js", "needle module\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{ .workspace_root = root };
    rt.ignored_list_entries = &.{"node_modules"};
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "grep",
        .name = "grep_files",
        .arguments_json = "{\"pattern\":\"needle\",\"path\":\"node_modules\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try expectContains(result.model_output, "node_modules/pkg/index.js:1: needle module");
}

test "effective command timeout uses the earlier remaining budget" {
    try std.testing.expectEqual(
        EffectiveCommandTimeout{ .timeout_ms = 5000, .started_ms = 700 },
        try effectiveCommandTimeout(5000, null, null, 700),
    );
    try std.testing.expectEqual(
        EffectiveCommandTimeout{ .timeout_ms = 700, .started_ms = 400 },
        try effectiveCommandTimeout(5000, 1000, 100, 400),
    );
    try std.testing.expectEqual(
        EffectiveCommandTimeout{ .timeout_ms = 100, .started_ms = 400 },
        try effectiveCommandTimeout(100, 5000, 100, 400),
    );
    try std.testing.expectEqual(
        EffectiveCommandTimeout{ .timeout_ms = 0, .started_ms = 1200 },
        try effectiveCommandTimeout(5000, 1000, 100, 1200),
    );
}

test "command replay policy is decided once from typed execution context" {
    const Case = struct {
        environment: command_environment.Environment,
        has_replay_capability: bool,
        interactive: bool,
        continued: ?command_replay_store.CapturePolicy = null,
        expected: ?command_replay_store.CapturePolicy,
    };
    const cases = [_]Case{
        .{
            .environment = .{ .clean = "/bin/zsh" },
            .has_replay_capability = true,
            .interactive = false,
            .expected = .required,
        },
        .{
            .environment = .{ .user = "/bin/zsh" },
            .has_replay_capability = false,
            .interactive = true,
            .expected = .best_effort,
        },
        .{
            .environment = .{ .clean = "/bin/zsh" },
            .has_replay_capability = false,
            .interactive = false,
            .expected = null,
        },
        .{
            .environment = .legacy,
            .has_replay_capability = true,
            .interactive = false,
            .expected = .best_effort,
        },
        .{
            .environment = .workspace_clean,
            .has_replay_capability = true,
            .interactive = true,
            .expected = null,
        },
        .{
            .environment = .{ .clean = "/bin/zsh" },
            .has_replay_capability = true,
            .interactive = false,
            .continued = .best_effort,
            .expected = .best_effort,
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            commandReplayPolicy(
                case.environment,
                case.has_replay_capability,
                case.interactive,
                case.continued,
            ),
        );
    }
}

test "terminal exec request timeout reaches execution without an ambient timeout" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var rt = TestRuntime{};
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try executeTestRunCommand(rt.context(), arena, .{
        .id = "request-timeout",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"sleep 1\",\"profile\":\"clean\",\"timeout_ms\":25}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "timeout=true\n");
    try expectContains(result.model_output, "timeout_ms=25\n");
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultBool(structured, "timed_out", true);
}

test "saved noninteractive terminal exec captures replay by capability" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var rt = TestRuntime{
        .interactive = false,
        .session_child_capability = &capability,
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "saved-noninteractive",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf replay\",\"profile\":\"clean\",\"timeout_ms\":600000}",
    });
    defer if (result.command_replay_capture) |capture| {
        capture.abort(arena_state.allocator());
    };

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqual(
        command_replay_store.CapturePolicy.required,
        result.command_replay_capture.?.policy(),
    );
}

test "registered read_tool_result restores an omitted stored-result suffix" {
    const result_store = @import("../session/result_store.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "integration-call",
        "web_fetch",
        "integration suffix needle",
    );
    defer alloc.free(handle);
    try std.testing.expect(std.mem.endsWith(u8, handle, ".txt"));
    const suffixless_handle = handle[0 .. handle.len - ".txt".len];

    var rt = TestRuntime{ .session_child_capability = &capability };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments_json = try std.fmt.allocPrint(
        arena,
        "{{\"handle\":\"{s}\",\"query\":\"suffix needle\"}}",
        .{suffixless_handle},
    );

    const result = try executeToolCall(rt.context(), arena, .{
        .id = "suffixless-result-read",
        .name = "read_tool_result",
        .arguments_json = arguments_json,
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try expectContains(result.model_output, "integration suffix needle");
    try expectContains(result.model_output, handle);
}

test "no-save terminal exec publishes one readable ephemeral replay" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const runtime_execution_memory = @import("../agent/runtime/execution_memory.zig");
    const read_tool_result = @import("../../tools/session/read_tool_result.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(temp_path);
    var store = command_replay_store.EphemeralStore.initForTesting(alloc, temp_path);
    defer store.deinit();
    var rt = TestRuntime{
        .interactive = false,
        .ephemeral_command_replay = &store,
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tool_call = ToolCall{
        .id = "no-save-replay",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf ephemeral-needle\",\"profile\":\"clean\",\"timeout_ms\":600000}",
    };

    const result = try executeTestRunCommand(rt.context(), arena, tool_call);
    const capture = result.command_replay_capture orelse return error.TestExpectedReplay;
    var handed_off = false;
    defer if (!handed_off) capture.discard(arena);
    var cancel = std.atomic.Value(bool).init(false);
    var prepared = try runtime_execution_memory.prepareCapturedToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .cancel_flag = &cancel,
            .ephemeral_command_replay = &store,
        },
        tool_call,
        result.model_output,
        capture,
    );
    try std.testing.expect(prepared.memory.output_handle == null);
    try runtime_execution_memory.finalizeCommandReplay(
        arena,
        tool_call,
        &prepared,
        null,
        capture,
    );
    const replay = prepared.memory.command_output_replay orelse
        return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    try std.testing.expect(std.mem.find(u8, prepared.model_output, descriptor.handle) != null);
    const read_arguments = try std.fmt.allocPrint(
        arena,
        "{{\"handle\":\"{s}\",\"start_byte\":1,\"byte_count\":4096}}",
        .{descriptor.handle},
    );
    const read_ctx = tool_dispatch.DispatchContext{
        .allocator = arena,
        .ephemeral_command_replay = &store,
    };
    const decoded = try read_tool_result.decode(read_ctx, read_arguments);
    const read_input = switch (decoded) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer read_input.deinit(arena);
    const read_result = try read_tool_result.call(read_ctx, read_input);
    defer read_result.deinit(arena);
    switch (read_result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => |page| try expectContains(page, "ephemeral-needle"),
        .failure => return error.TestExpectedReplay,
    }
    capture.releaseRetained(arena);
    handed_off = true;

    var inspect_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), temp_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer inspect_dir.close(io_mod.getIo());
    var entries = inspect_dir.iterate();
    try std.testing.expect(try entries.next(io_mod.getIo()) == null);
}

test "required replay spill failure returns recoverable capture failure" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var store = command_replay_store.EphemeralStore.initForTesting(
        alloc,
        "/definitely/missing/fx-replay-dir",
    );
    defer store.deinit();
    var rt = TestRuntime{
        .interactive = false,
        .ephemeral_command_replay = &store,
        .max_command_output_bytes = 1,
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "capture-failure",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf xx\",\"profile\":\"clean\",\"timeout_ms\":600000}",
    });
    defer if (result.command_replay_capture) |capture| {
        capture.abort(arena_state.allocator());
    };

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "\"output_capture_failed\":true");
}

test "run_command timeout returns model-visible failure" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var rt = TestRuntime{
        .command_timeout_ms = 1000,
        .session_child_capability = &capability,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tool_call: ToolCall = .{
        .id = "cmd",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf 'PRE-TIMEOUT-OUT\\n'; printf 'PRE-TIMEOUT-ERR\\n' >&2; sleep 5\",\"profile\":\"clean\",\"timeout_ms\":5000}",
    };

    const result = try executeTestRunCommand(rt.context(), arena, tool_call);

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "timeout=true\n");
    try expectContains(result.model_output, "timeout_ms=1000\n");
    try expectContains(
        result.model_output,
        "cleanup_scope=process_group_and_tracked_descendants\n",
    );
    try expectContains(result.model_output, "cleanup_guarantee=best_effort\n");
    try expectContains(result.model_output, "fully detached descendants may remain\n");
    try expectNotContains(result.model_output, "command timed out and was terminated");
    try expectNotContains(result.model_output, "PRE-TIMEOUT-OUT");
    try expectNotContains(result.model_output, "PRE-TIMEOUT-ERR");
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "command");
    try expectCommandResultField(
        structured,
        "command",
        "printf 'PRE-TIMEOUT-OUT\n'; printf 'PRE-TIMEOUT-ERR\n' >&2; sleep 5",
    );
    try expectCommandResultBool(structured, "timed_out", true);
    try expectCommandResultInt(structured, "stdout_bytes", 0);
    try expectCommandResultInt(structured, "stderr_bytes", 0);

    const capture = result.command_replay_capture orelse
        return error.TestExpectedReplay;
    var canonical = (try capture.canonicalizeForComparison(
        arena_state.allocator(),
    )) orelse return error.TestExpectedReplay;
    defer canonical.deinit(arena_state.allocator());
    var saw_stdout = false;
    var saw_stderr = false;
    for (canonical.records.items) |record| {
        if (record.stream == .stdout and
            std.mem.eql(u8, record.text.items, "PRE-TIMEOUT-OUT")) saw_stdout = true;
        if (record.stream == .stderr and
            std.mem.eql(u8, record.text.items, "PRE-TIMEOUT-ERR")) saw_stderr = true;
    }
    try std.testing.expect(saw_stdout);
    try std.testing.expect(saw_stderr);

    const runtime_execution_memory = @import("../agent/runtime/execution_memory.zig");
    const runtime_config = @import("../agent/runtime/config.zig");
    const execution_memory = @import("../agent/execution_memory.zig");
    const session_codec = @import("../session/session_codec.zig");

    var cancel = std.atomic.Value(bool).init(false);
    const config = runtime_config.Config{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 1,
        .cancel_flag = &cancel,
        .session_child_capability = &capability,
    };
    var prepared = try runtime_execution_memory.prepareCapturedToolModelOutput(
        arena,
        config,
        tool_call,
        result.model_output,
        capture,
    );
    runtime_execution_memory.applyToolResultMemory(
        &prepared.memory,
        result.tool_result_memory,
    );
    var replay_finalized = false;
    defer if (!replay_finalized) capture.abort(arena);
    try runtime_execution_memory.finalizeCommandReplay(
        arena,
        tool_call,
        &prepared,
        &capability,
        capture,
    );
    replay_finalized = true;

    const terminal_replay = prepared.memory.command_output_replay orelse
        return error.TestExpectedReplay;
    const terminal_descriptor = switch (terminal_replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    var terminal_reader = try command_replay_store.Reader.open(
        alloc,
        &capability,
        terminal_descriptor,
    );
    defer terminal_reader.deinit();
    var terminal_stdout: std.ArrayList(u8) = .empty;
    defer terminal_stdout.deinit(alloc);
    var terminal_stderr: std.ArrayList(u8) = .empty;
    defer terminal_stderr.deinit(alloc);
    while (try terminal_reader.next(alloc)) |frame| {
        defer alloc.free(frame.payload);
        switch (frame.stream) {
            .stdout => try terminal_stdout.appendSlice(alloc, frame.payload),
            .stderr => try terminal_stderr.appendSlice(alloc, frame.payload),
        }
    }
    try expectContains(terminal_stdout.items, "PRE-TIMEOUT-OUT\n");
    try expectContains(terminal_stderr.items, "PRE-TIMEOUT-ERR\n");

    const persisted = try execution_memory.makePersistedToolResult(
        alloc,
        tool_call.id,
        tool_call.name,
        .failure,
        prepared.model_output,
        prepared.memory,
    );
    defer execution_memory.freeTransientPersistedToolResult(alloc, persisted);
    var calls = [_]types.ToolCall{tool_call};
    var results = [_]types.PersistedToolResult{persisted};
    var steps = [_]types.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("run the timeout fixture") },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = steps[0..] },
    } };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try session_codec.writeHistoryTurn(&encoded.writer, turn);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer parsed.deinit();
    const decoded = try session_codec.parseHistoryTurn(alloc, parsed.value);
    defer session_runtime.freeHistoryTurn(alloc, decoded);
    const decoded_result = decoded.assistant.execution.tool_steps[0].tool_results[0];
    try expectNotContains(decoded_result.output, "PRE-TIMEOUT-OUT");
    try expectNotContains(decoded_result.output, "PRE-TIMEOUT-ERR");
    const decoded_replay = decoded_result.command_output_replay orelse
        return error.TestExpectedReplay;
    const decoded_descriptor = switch (decoded_replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    var resumed_reader = try command_replay_store.Reader.open(
        alloc,
        &capability,
        decoded_descriptor,
    );
    defer resumed_reader.deinit();
    var resumed_stdout: std.ArrayList(u8) = .empty;
    defer resumed_stdout.deinit(alloc);
    var resumed_stderr: std.ArrayList(u8) = .empty;
    defer resumed_stderr.deinit(alloc);
    while (try resumed_reader.next(alloc)) |frame| {
        defer alloc.free(frame.payload);
        switch (frame.stream) {
            .stdout => try resumed_stdout.appendSlice(alloc, frame.payload),
            .stderr => try resumed_stderr.appendSlice(alloc, frame.payload),
        }
    }
    try std.testing.expectEqualStrings(terminal_stdout.items, resumed_stdout.items);
    try std.testing.expectEqualStrings(terminal_stderr.items, resumed_stderr.items);
}

test "interactive command replay capture allocation fails open" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const init = try initCommandReplayCapture(
        failing.allocator(),
        .best_effort,
        64 * 1024,
        64 * 1024,
        null,
        null,
        null,
        false,
    );
    try std.testing.expect(init.capture == null);
    try std.testing.expect(init.unavailable);

    var callback = CommandReplayCaptureCallback{
        .alloc = std.testing.allocator,
        .capture = null,
    };
    try CommandReplayCaptureCallback.onChunk(
        @ptrCast(&callback),
        null,
        .stdout,
        "accepted output\n",
    );
    try std.testing.expect(callback.had_accepted_output);

    var transferred = false;
    const result = try finishCommandToolResult(
        std.testing.allocator,
        null,
        init.unavailable and callback.had_accepted_output,
        &transferred,
        null,
        .{ .model_output = "exit_code=0\n(no output)\n" },
    );
    try std.testing.expect(!transferred);
    switch (result.tool_result_memory.?.command_output_replay.?) {
        .unavailable => {},
        .available => return error.TestExpectedUnavailableReplay,
    }
}

test "required replay finalizer overrides every recoverable command result" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const initial_results = [_]ToolExecutionResult{
        .{ .status = .success, .model_output = "compatibility success\n" },
        .{ .status = .failure, .model_output = "timeout\n" },
        .{ .status = .failure, .cancelled = true, .model_output = "cancelled\n" },
        .{ .status = .failure, .model_output = "nonzero\n" },
        .{ .status = .success, .model_output = "success\n" },
    };

    for (initial_results) |initial| {
        const capture = try command_replay_store.Capture.create(arena, 0, null);
        defer capture.abort(arena);
        capture.setPolicyBeforeCapture(.required);
        try std.testing.expectError(
            error.CommandOutputCaptureFailed,
            capture.appendAcceptedRequired(arena, .stdout, "accepted\n"),
        );
        var transferred = false;
        const result = try finishCommandToolResult(
            arena,
            capture,
            false,
            &transferred,
            null,
            initial,
        );
        try std.testing.expect(transferred);
        try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
        try expectContains(result.model_output, "\"output_capture_failed\":true");
    }
}

test "run_command post-spawn cancellation returns structured evidence in every mode" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "artifacts");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const artifact_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "artifacts");
    defer alloc.free(artifact_dir);

    var cancel = std.atomic.Value(bool).init(false);
    var rt = TestRuntime{
        .workspace_root = workspace,
        .cancel_flag = &cancel,
        .permission_mode = .auto,
        .command_artifact_dir = artifact_dir,
    };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const interactive_marker = try std.fs.path.join(arena, &.{ workspace, "interactive-ready" });
    const interactive_command = try std.fmt.allocPrint(
        arena,
        "trap 'exit 0' TERM; printf ready > '{s}'; printf 'RUNTIME-READY\\n'; while :; do :; done",
        .{interactive_marker},
    );
    const interactive_args = try runCommandArgsForTest(arena, interactive_command);
    var interactive_trigger = CancelTestCommandOnOutput{
        .flag = &cancel,
        .needle = "RUNTIME-READY",
    };
    var interactive_ctx = rt.context();
    interactive_ctx.output_chunk_ctx = @ptrCast(&interactive_trigger);
    interactive_ctx.on_output_chunk = CancelTestCommandOnOutput.onChunk;
    const interactive = try executeTestRunCommand(interactive_ctx, arena, .{
        .id = "cancel-interactive",
        .name = "shell",
        .arguments_json = interactive_args,
    });

    try std.testing.expect(interactive_trigger.seen);
    try std.testing.expect(absolutePathExists(interactive_marker));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, interactive.status);
    try std.testing.expect(interactive.cancelled);
    try std.testing.expectEqualStrings("command cancelled\n", interactive.model_output);
    const structured = interactive.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "command");
    try expectCommandResultBool(structured, "truncated", false);
    try expectCommandResultStringPrefix(structured, "output_file", artifact_dir);

    cancel.store(false, .seq_cst);
    rt.interactive = false;
    const headless_marker = try std.fs.path.join(arena, &.{ workspace, "headless-ready" });
    const headless_command = try std.fmt.allocPrint(
        arena,
        "trap 'exit 0' TERM; printf ready > '{s}'; printf 'HEADLESS-READY\\n'; while :; do :; done",
        .{headless_marker},
    );
    const headless_args = try runCommandArgsForTest(arena, headless_command);
    var headless_trigger = CancelTestCommandOnOutput{
        .flag = &cancel,
        .needle = "HEADLESS-READY",
    };
    var headless_ctx = rt.context();
    headless_ctx.output_chunk_ctx = @ptrCast(&headless_trigger);
    headless_ctx.on_output_chunk = CancelTestCommandOnOutput.onChunk;
    const headless = try executeTestRunCommand(headless_ctx, arena, .{
        .id = "cancel-headless",
        .name = "shell",
        .arguments_json = headless_args,
    });
    try std.testing.expect(headless_trigger.seen);
    try std.testing.expect(absolutePathExists(headless_marker));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, headless.status);
    try std.testing.expect(headless.cancelled);
    try std.testing.expectEqualStrings("command cancelled\n", headless.model_output);
    const headless_structured = headless.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(headless_structured, "kind", "command");
    try expectCommandResultField(headless_structured, "command", headless_command);
    try expectCommandResultBool(headless_structured, "truncated", false);
    try expectCommandResultStringPrefix(headless_structured, "output_file", artifact_dir);

    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    cancel.store(false, .seq_cst);
    headless_trigger.seen = false;
    var retry_ctx = rt.context();
    retry_ctx.output_chunk_ctx = @ptrCast(&headless_trigger);
    retry_ctx.on_output_chunk = CancelTestCommandOnOutput.onChunk;
    const command_ctx = try tool_admission.runCommandContext(
        retry_ctx.admissionInput(),
        arena,
        .{
            .id = "cancel-broader-retry",
            .name = "shell",
            .arguments_json = headless_args,
        },
    );
    const retry = try executeToolCallAuthorized(retry_ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = .{
            .id = "cancel-broader-retry",
            .name = "shell",
            .arguments_json = headless_args,
        },
        .authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .auto_classifier,
        } } },
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });
    try std.testing.expect(headless_trigger.seen);
    try std.testing.expect(retry.cancelled);
    var metrics: [1]diagnostics.ToolCallMetric = undefined;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.snapshotToolCalls(&metrics));
}

test "run_command success exposes structured foreground metadata" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var rt = TestRuntime{
        .permission_mode = .auto,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf '\\\\150\\\\145\\\\154\\\\154\\\\157'\",\"timeout_ms\":600000}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "command");
    try expectCommandResultField(structured, "command", "printf '\\150\\145\\154\\154\\157'");
    try expectCommandResultField(structured, "cwd", "/tmp");
    try expectCommandResultInt(structured, "exit_code", 0);
    try expectCommandResultNull(structured, "signal");
    try expectCommandResultBool(structured, "timed_out", false);
    try expectCommandResultInt(structured, "stdout_bytes", 5);
    try expectCommandResultInt(structured, "stderr_bytes", 0);
    try expectCommandResultBool(structured, "truncated", false);
    try std.testing.expect(std.mem.find(u8, structured, "hello") == null);
}

fn fakeWorkspaceNonzero(
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    timeout_ms: u32,
) js_host_workspace.ExecuteError!command_contract.RunCommandResult {
    if (timeout_ms != js_host_workspace.max_timeout_ms) return error.InvalidWorkspaceResult;
    return command_contract.formatCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = .{ .exit_code = 7 },
        .stdout_display = "partial",
        .stderr_display = "failed",
        .stdout_bytes = 7,
        .stderr_bytes = 6,
        .duration_ms = 12,
    });
}

fn fakeWorkspaceTruncated(
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    _: u32,
) js_host_workspace.ExecuteError!command_contract.RunCommandResult {
    var result = try command_contract.formatCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = .{ .exit_code = 0 },
        .stdout_display = "preview",
        .stderr_display = "",
        .stdout_bytes = 70_000,
        .stderr_bytes = 0,
        .duration_ms = 4,
    });
    var metadata = result.command_result.?;
    metadata.truncated = true;
    result.command_result = metadata;
    return result;
}

fn fakeWorkspaceCancelled(
    _: Allocator,
    command: []const u8,
    cwd: []const u8,
    _: u32,
) js_host_workspace.ExecuteError!command_contract.RunCommandResult {
    return .{
        .output = "",
        .cancelled = true,
        .command_result = .{
            .command = command,
            .cwd = cwd,
            .duration_ms = 3,
        },
    };
}

fn fakeWorkspaceDeadline(
    _: Allocator,
    _: []const u8,
    _: []const u8,
    timeout_ms: u32,
) js_host_workspace.ExecuteError!command_contract.RunCommandResult {
    if (timeout_ms != js_host_workspace.max_timeout_ms) return error.InvalidWorkspaceResult;
    return error.WorkspaceDeadline;
}

test "browser run_command uses only the admitted host executor for nonzero and truncated results" {
    var rt = TestRuntime{
        .workspace_root = "/virtual/workspace",
        .tool_registry = test_browser_workspace_tools.registry,
        .workspace_executor = .{ .execute_fn = fakeWorkspaceNonzero },
    };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const failed = try executeTestRunCommand(rt.context(), arena, .{
        .id = "browser-failed",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"exit 7\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, failed.status);
    try expectToolErrorDetailInt(failed.model_output, "exit_code", 7);
    const failed_json = failed.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(failed_json, "cwd", "/virtual/workspace");
    try expectCommandResultNull(failed_json, "signal");
    try expectCommandResultNull(failed_json, "output_file");

    rt.workspace_executor = .{ .execute_fn = fakeWorkspaceTruncated };
    const truncated = try executeTestRunCommand(rt.context(), arena, .{
        .id = "browser-truncated",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"generate output\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, truncated.status);
    const truncated_json = truncated.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultBool(truncated_json, "truncated", true);
    try expectCommandResultInt(truncated_json, "stdout_bytes", 70_000);
    try expectCommandResultNull(truncated_json, "output_file");
}

test "browser run_command maps host cancellation and deadline without signal or fallback" {
    var rt = TestRuntime{
        .workspace_root = "/virtual/workspace",
        .tool_registry = test_browser_workspace_tools.registry,
        .workspace_executor = .{ .execute_fn = fakeWorkspaceCancelled },
    };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cancelled = try executeTestRunCommand(rt.context(), arena, .{
        .id = "browser-cancelled",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"long command\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, cancelled.status);
    try std.testing.expect(cancelled.cancelled);
    const cancelled_json = cancelled.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultNull(cancelled_json, "signal");
    try expectCommandResultBool(cancelled_json, "timed_out", false);

    rt.workspace_executor = .{ .execute_fn = fakeWorkspaceDeadline };
    const timed_out = try executeTestRunCommand(rt.context(), arena, .{
        .id = "browser-timeout",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"long command\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, timed_out.status);
    try expectContains(timed_out.model_output, "timeout=true\n");
    try expectContains(timed_out.model_output, "timeout_ms=30000\n");
    const timeout_json = timed_out.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultBool(timeout_json, "timed_out", true);
    try expectCommandResultNull(timeout_json, "signal");
}

test "run_command preserves result when presentation callback fails" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const FailOutput = struct {
        calls: usize = 0,

        fn write(raw_ctx: *anyopaque, _: ?types.ToolLifecycleId, _: command_contract.CommandOutputStream, _: []const u8) error{Unexpected}!void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            return error.Unexpected;
        }
    };

    var rt = TestRuntime{
        .permission_mode = .auto,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var presentation = FailOutput{};
    var ctx = rt.context();
    ctx.output_chunk_ctx = @ptrCast(&presentation);
    ctx.on_output_chunk = FailOutput.write;
    const result = try executeTestRunCommand(ctx, arena_state.allocator(), .{
        .id = "cmd",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf 'handoff\\\\nsecond\\\\n'\",\"timeout_ms\":600000}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), presentation.calls);
    try expectContains(result.model_output, "handoff\nsecond");
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultInt(structured, "exit_code", 0);
}

test "run_command returns model output and structured metadata" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var rt = TestRuntime{
        .permission_mode = .auto,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf 'quiet-stdout\\\\n'; printf 'quiet-stderr\\\\n' >&2\",\"timeout_ms\":600000}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try expectContains(result.model_output, "exit_code=0\n");
    try expectContains(result.model_output, "<stdout>\nquiet-stdout\n</stdout>\n");
    try expectContains(result.model_output, "<stderr>\nquiet-stderr\n</stderr>\n");

    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "command");
    try expectCommandResultInt(structured, "exit_code", 0);
    try expectCommandResultInt(structured, "stdout_bytes", 13);
    try expectCommandResultInt(structured, "stderr_bytes", 13);
    try expectCommandResultBool(structured, "timed_out", false);
    try expectCommandResultBool(structured, "truncated", false);
}

test "run_command nonzero exit returns structured masked failure" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var rt = TestRuntime{
        .permission_mode = .auto,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf 'bad AKIA0123456789ABCDEF\\\\n' >&2; exit 7\",\"timeout_ms\":600000}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectToolErrorField(result.model_output, "type", "tool_execution_failed");
    try expectToolErrorField(result.model_output, "tool_name", "shell");
    try expectToolErrorDetailString(result.model_output, "command", "printf 'bad [redacted]\\n' >&2; exit 7");
    try expectToolErrorDetailString(result.model_output, "cwd", "/tmp");
    try expectToolErrorDetailInt(result.model_output, "exit_code", 7);
    try expectToolErrorDetailString(result.model_output, "stderr", "bad [redacted]");
    try expectContains(result.model_output, "Inspect stderr");
    try expectNotContains(result.model_output, "AKIA0123456789ABCDEF");
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "command");
    try expectCommandResultInt(structured, "exit_code", 7);
    try expectCommandResultInt(structured, "stdout_bytes", 0);
    try expectCommandResultInt(structured, "stderr_bytes", 25);
    try std.testing.expect(std.mem.find(u8, structured, "\"stdout\":") == null);
    try std.testing.expect(std.mem.find(u8, structured, "\"stderr\":") == null);
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .exit_code = 7 },
        result.tool_result_memory.?.command_process_presentation.?,
    );
}

test "run_command huge output exposes truncation and artifact paths without stdout body" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "session/logs/commands");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const artifact_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session/logs/commands");
    defer alloc.free(artifact_dir);

    var rt = TestRuntime{
        .workspace_root = workspace,
        .permission_mode = .auto,
    };
    rt.max_command_output_bytes = 16;
    rt.command_artifact_dir = artifact_dir;
    defer rt.deinit(alloc);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf %026d 0\",\"timeout_ms\":600000}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultBool(structured, "truncated", true);
    try expectCommandResultInt(structured, "stdout_bytes", 26);
    try expectCommandResultInt(structured, "stderr_bytes", 0);
    try expectCommandResultStringPrefix(structured, "output_file", artifact_dir);
    try expectCommandResultStringPrefix(structured, "stdout_file", artifact_dir);
    try expectCommandResultStringPrefix(structured, "stderr_file", artifact_dir);
    try std.testing.expect(std.mem.find(u8, structured, "00000000000000000000000000") == null);
}

test "shell run rejects legacy background input without creating state" {
    var rt = TestRuntime{ .tool_registry = test_builtin_tools.registry };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf row07-headless-bg\",\"background\":true}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "\"code\":\"invalid_shell_request\"");
    try expectContains(result.model_output, "request.background is not accepted for run.");
    try std.testing.expect(std.mem.find(u8, result.model_output, "retry_with") == null);
}

const PermissionThreadState = struct {
    decision: ?ToolPermissionDecision = null,
    err: ?anyerror = null,
};

const FilePermissionThreadState = struct {
    decision: ?ToolPermissionDecision = null,
    file_authority: bool = false,
    prepared: bool = false,
    additions: usize = 0,
    expected_grant_target: []const u8 = "",
    expected_workspace_offer: bool = false,
    frozen_offer_matches: bool = false,
    err: ?anyerror = null,
};

fn runFilePermissionOutcome(
    state: *FilePermissionThreadState,
    req_ctx: Context,
    call: ToolCall,
    mode: PermissionMode,
) void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const outcome = tool_admission.requestPermissionOutcome(
        req_ctx.admissionInput(),
        arena_state.allocator(),
        call,
        mode,
        &.{},
    ) catch |err| {
        state.err = err;
        return;
    };
    if (outcome.tool_failure != null) {
        state.err = error.UnexpectedToolFailure;
        return;
    }
    state.decision = outcome.decision;
    const authority = outcome.execution_authority orelse return;
    switch (authority) {
        .file_mutation => |file_authority| {
            state.file_authority = true;
            state.prepared = file_authority.prepared != null;
            if (file_authority.prepared) |prepared| {
                state.additions = prepared.preview.additions;
            }
            if (file_authority.grant_offer) |offer| {
                state.frozen_offer_matches = fileGrantOfferMatchesExpectation(
                    offer,
                    state.expected_grant_target,
                    state.expected_workspace_offer,
                );
            }
        },
        else => state.err = error.UnexpectedExecutionAuthority,
    }
}

fn fileGrantOfferMatchesExpectation(
    offer: file_mutation_contract.FileGrantOffer,
    expected_target: []const u8,
    expected_workspace: bool,
) bool {
    const workspace_permissions = [_][]const u8{ "edit", "read", "glob", "grep" };
    for (offer.grants) |grant| {
        if (!std.mem.eql(u8, grant.target_path, expected_target)) return false;
    }
    if (expected_workspace) {
        if (offer.scope != .workspace_files) return false;
        if (offer.grants.len != workspace_permissions.len) return false;
        for (workspace_permissions) |permission| {
            var found = false;
            for (offer.grants) |grant| {
                found = found or std.mem.eql(
                    u8,
                    grant.tool_name,
                    permission,
                );
            }
            if (!found) return false;
        }
        return true;
    }
    return switch (offer.scope) {
        .workspace_files => false,
        .external_tree => |root| offer.grants.len == 1 and
            std.mem.eql(u8, offer.grants[0].tool_name, "edit") and
            std.mem.eql(
                u8,
                root,
                expected_target[0 .. expected_target.len - "/**".len],
            ),
    };
}

fn testFileMutationArgs(
    alloc: Allocator,
    kind: file_mutation_contract.Kind,
    path: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    switch (kind) {
        .write => {
            try out.writer.writeAll(",\"content\":\"after\\n\"}");
        },
        .edit => {
            try out.writer.writeAll(
                ",\"old_string\":\"before\\n\",\"new_string\":\"after\\n\"}",
            );
        },
    }
    return try out.toOwnedSlice();
}

fn testMaxAdmittedLexicalPath(
    alloc: Allocator,
    basename: []const u8,
) ![]u8 {
    if (basename.len > std.Io.Dir.max_path_bytes) {
        return error.NameTooLong;
    }
    const path = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
    var cursor: usize = 0;
    var remaining = path.len - basename.len;
    if (remaining % 2 != 0) {
        if (remaining < "x/../".len) return error.NameTooLong;
        @memcpy(path[cursor..][0.."x/../".len], "x/../");
        cursor += "x/../".len;
        remaining -= "x/../".len;
    }
    while (remaining > 0) : (remaining -= 2) {
        @memcpy(path[cursor..][0..2], "./");
        cursor += 2;
    }
    @memcpy(path[cursor..][0..basename.len], basename);
    return path;
}

fn runPermissionRequest(state: *PermissionThreadState, req_ctx: Context, call: ToolCall, mode: PermissionMode) void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const outcome = tool_admission.requestPermissionOutcome(req_ctx.admissionInput(), arena_state.allocator(), call, mode, &.{}) catch |err| {
        state.err = err;
        return;
    };
    state.decision = outcome.decision;
}

fn waitForPermissionPrompt(worker: *WorkerRuntime, expected: []const u8) !u64 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var snapshot = try worker.snapshotState(std.testing.allocator);
        defer snapshot.deinit(std.testing.allocator);
        if (snapshot.pending_permission_request) |request| {
            try expectContains(request.label, expected);
            return request.id;
        }
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

test "configured ask rule prompts the worker" {
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("glob"), .pattern = @constCast("."), .action = .ask },
    };
    var rt = TestRuntime{
        .workspace_root = "/tmp/workspace",
        .permission_rules = .{ .rules = &rules },
        .permission_mode = .auto,
    };
    defer rt.deinit(std.testing.allocator);

    var state = PermissionThreadState{};
    const thread = try std.Thread.spawn(.{}, runPermissionRequest, .{ &state, rt.context(), ToolCall{ .id = "1", .name = "glob_files", .arguments_json = "{\"pattern\":\"*\"}" }, PermissionMode.auto });
    var thread_joined = false;
    defer if (!thread_joined) {
        rt.worker.requestShutdown();
        thread.join();
    };

    rt.worker.worker_processing = true;
    const request_id = try waitForPermissionPrompt(&rt.worker, "glob_files");
    try std.testing.expectEqual(
        worker_runtime.PermissionSubmissionResult.accepted,
        rt.worker.submitPermissionResponse(
            request_id,
            permission_request.OwnedPermissionResponse.init(std.testing.allocator, .once, null),
        ),
    );
    thread.join();
    thread_joined = true;
    try std.testing.expect(state.err == null);
    try std.testing.expectEqual(ToolPermissionDecision.once, state.decision.?);
}

const McpFixture = struct {
    const CountingContext = struct {
        calls: usize = 0,
        runtime_generation: u64 = 41,
    };

    const PermissionContext = struct {
        search_rule_count: usize = 0,
        schema_rule_count: usize = 0,
    };

    const AuthorityContext = struct {
        calls: usize = 0,
        admission_generation: u64 = 0,
        action_generation: u64 = 0,
        expected_runtime_generation: ?u64 = null,
    };

    fn hasTrue(_: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
        return true;
    }

    fn hasFalse(_: *anyopaque, _: []const u8) bool {
        return false;
    }

    fn validateArguments(raw_ctx: *anyopaque, arena: Allocator, _: []const u8, arguments_json: []const u8, _: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
        if (std.mem.eql(u8, arguments_json, "{\"path\":7}")) {
            return .{ .invalid = try arena.dupe(u8, "path must be a string") };
        }
        const ctx: *CountingContext = @ptrCast(@alignCast(raw_ctx));
        return .{ .valid = ctx.runtime_generation };
    }

    fn callOk(_: *anyopaque, arena: Allocator, _: []const u8, _: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
        return .{ .model_output = try arena.dupe(u8, "mcp ok") };
    }

    fn callCounting(raw_ctx: *anyopaque, arena: Allocator, _: []const u8, _: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
        const ctx: *CountingContext = @ptrCast(@alignCast(raw_ctx));
        ctx.calls += 1;
        return .{ .model_output = try arena.dupe(u8, "mcp ok") };
    }

    fn callRecordingAuthority(raw_ctx: *anyopaque, arena: Allocator, _: []const u8, _: []const u8, _: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
        const ctx: *AuthorityContext = @ptrCast(@alignCast(raw_ctx));
        const scope = switch (options.access) {
            .scoped => |value| value,
            else => return error.McpScopedAccessExpected,
        };
        ctx.calls += 1;
        ctx.admission_generation = scope.admission_authority_generation;
        ctx.action_generation = scope.action_authority_generation;
        ctx.expected_runtime_generation = options.expected_runtime_generation;
        return .{ .model_output = try arena.dupe(u8, "mcp ok") };
    }

    fn callNull(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
        return null;
    }

    fn callFailure(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
        return error.McpFixtureFailure;
    }

    fn search(_: *anyopaque, arena: Allocator, request: capability_retrieval.Request, _: types.PermissionRuleSet, _: context_limits.Values) anyerror!tool_mcp_runtime.SearchResult {
        return .{ .model_output = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\",\"tools\":[{{\"name\":\"mcp_fs_read\",\"server\":\"fs\",\"description\":\"Read\",\"input_schema\":{{\"type\":\"object\"}},\"tags\":[\"fs\",\"read\"]}}],\"count\":1}}", .{request.query.raw}) };
    }

    fn schema(_: *anyopaque, arena: Allocator, name: []const u8, _: types.PermissionRuleSet, _: context_limits.Values, _: tool_mcp_runtime.Access, _: ?*std.atomic.Value(bool)) anyerror!?tool_mcp_runtime.ToolSchemaResult {
        if (!std.mem.eql(u8, name, "mcp_fs_read")) return null;
        return .{ .selected = .{ .model_output = try arena.dupe(u8, "{\"type\":\"function\",\"name\":\"mcp_fs_read\",\"description\":\"Read <context_limit action='literal' />\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"context_limit_rejection\":{\"type\":\"string\"}}}}") } };
    }

    fn searchRecordingRules(raw_ctx: *anyopaque, arena: Allocator, request: capability_retrieval.Request, permission_rules: types.PermissionRuleSet, limits: context_limits.Values, _: tool_mcp_runtime.Access, _: ?*std.atomic.Value(bool)) anyerror!tool_mcp_runtime.SearchResult {
        const ctx: *PermissionContext = @ptrCast(@alignCast(raw_ctx));
        ctx.search_rule_count = permission_rules.rules.len;
        return search(raw_ctx, arena, request, permission_rules, limits);
    }

    fn schemaRecordingRules(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, permission_rules: types.PermissionRuleSet, limits: context_limits.Values, access: tool_mcp_runtime.Access, cancel_flag: ?*std.atomic.Value(bool)) anyerror!?tool_mcp_runtime.ToolSchemaResult {
        const ctx: *PermissionContext = @ptrCast(@alignCast(raw_ctx));
        ctx.schema_rule_count = permission_rules.rules.len;
        return schema(raw_ctx, arena, name, permission_rules, limits, access, cancel_flag);
    }
};

test "capability search and MCP selection forward permission rules through registered execution" {
    var permission_context = McpFixture.PermissionContext{};
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("mcp_other"), .pattern = @constCast("*"), .action = .deny },
    };
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&permission_context),
        .mcp_search_tools = McpFixture.searchRecordingRules,
        .mcp_tool_schema = McpFixture.schemaRecordingRules,
        .permission_rules = .{ .rules = &rules },
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try executeToolCall(rt.context(), arena, .{
        .id = "search",
        .name = "capability_search",
        .arguments_json = "{\"query\":\"read\",\"server\":\"fixture\"}",
    });
    _ = try executeToolCall(rt.context(), arena, .{
        .id = "select",
        .name = "mcp_select_tool",
        .arguments_json = "{\"name\":\"mcp_fs_read\"}",
    });

    try std.testing.expectEqual(@as(usize, 1), permission_context.search_rule_count);
    try std.testing.expectEqual(@as(usize, 1), permission_context.schema_rule_count);

    rt.permission_mode = .yolo;
    permission_context = .{};
    _ = try executeToolCall(rt.context(), arena, .{
        .id = "yolo-search",
        .name = "capability_search",
        .arguments_json = "{\"query\":\"read\",\"server\":\"fixture\"}",
    });
    _ = try executeToolCall(rt.context(), arena, .{
        .id = "yolo-select",
        .name = "mcp_select_tool",
        .arguments_json = "{\"name\":\"mcp_fs_read\"}",
    });

    try std.testing.expectEqual(@as(usize, 0), permission_context.search_rule_count);
    try std.testing.expectEqual(@as(usize, 0), permission_context.schema_rule_count);
}

test "MCP dynamic tool cannot execute before it is advertised" {
    var counting = McpFixture.CountingContext{};
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&counting),
        .mcp_has_tool = McpFixture.hasTrue,
        .mcp_call_tool = McpFixture.callCounting,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try executeToolCall(rt.context(), arena, .{
        .id = "dynamic",
        .name = "mcp_fs_read",
        .arguments_json = "{}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "not selected");
    try std.testing.expectEqual(@as(usize, 0), counting.calls);
}

test "MCP select does not authorize same-response dynamic execution" {
    var counting = McpFixture.CountingContext{};
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&counting),
        .mcp_has_tool = McpFixture.hasTrue,
        .mcp_call_tool = McpFixture.callCounting,
        .mcp_tool_schema = McpFixture.schema,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const selected = try executeToolCall(rt.context(), arena, .{
        .id = "select",
        .name = "mcp_select_tool",
        .arguments_json = "{\"name\":\"mcp_fs_read\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, selected.status);
    try std.testing.expectEqualStrings("mcp_fs_read", selected.selected_dynamic_tools[0].name);
    try expectContains(selected.selected_dynamic_tools[0].schema_json, "context_limit_rejection");
    try expectContains(selected.selected_dynamic_tools[0].schema_json, "<context_limit action='literal' />");

    const result = try executeToolCall(rt.context(), arena, .{
        .id = "dynamic",
        .name = "mcp_fs_read",
        .arguments_json = "{}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "not selected");
    try std.testing.expectEqual(@as(usize, 0), counting.calls);
}

test "MCP unadvertised dynamic names stay unsupported without a runtime call" {
    var marker: u8 = 0;

    var null_rt = TestRuntime{
        .mcp_ctx = @ptrCast(&marker),
        .mcp_has_tool = McpFixture.hasTrue,
        .mcp_call_tool = McpFixture.callNull,
    };
    defer null_rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try executeToolCall(null_rt.context(), arena, .{
        .id = "dynamic",
        .name = "mcp_unknown",
        .arguments_json = "{}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "not selected");

    var no_rt = TestRuntime{};
    defer no_rt.deinit(std.testing.allocator);
    try expectToolOutput(no_rt.context(), "mcp_unknown", "{}", "Unsupported tool: mcp_unknown");
}

test "MCP dynamic tool executes after its schema was advertised" {
    var counting = McpFixture.CountingContext{};
    const advertised = [_][]const u8{"mcp_fs_read"};
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&counting),
        .mcp_has_tool = McpFixture.hasTrue,
        .mcp_call_tool = McpFixture.callCounting,
        .advertised_dynamic_tool_names = &advertised,
    };
    defer rt.deinit(std.testing.allocator);

    try expectToolOutput(rt.context(), "mcp_fs_read", "{}", "mcp ok");
    try std.testing.expectEqual(@as(usize, 1), counting.calls);
}

test "MCP execution binds the last live action generation before transport" {
    const alloc = std.testing.allocator;
    var captured = mcp_access_policy.View{
        .runtime_generation = 1,
        .owner_id = try alloc.dupe(u8, "child"),
        .parent_id = try alloc.dupe(u8, "parent"),
        .features_visible = false,
        .servers = try alloc.alloc(mcp_access_policy.ServerIdentity, 0),
        .tools = try alloc.alloc(mcp_access_policy.ToolIdentity, 0),
    };
    defer captured.deinit(alloc);
    const UnusedLiveProvider = struct {
        fn resolve(_: *anyopaque, _: Allocator) !tool_mcp_runtime.ResolvedLiveView {
            return error.TestUnexpectedResult;
        }
    };
    var marker: u8 = 0;
    var authority = McpFixture.AuthorityContext{};
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&authority),
        .mcp_call_tool = McpFixture.callRecordingAuthority,
    };
    defer rt.deinit(alloc);
    var tool_ctx = rt.context();
    tool_ctx.mcp_access = .{ .scoped = .{
        .captured = &captured,
        .admission_authority_generation = 17,
        .live = .{
            .context = @ptrCast(&marker),
            .resolve_fn = UnusedLiveProvider.resolve,
        },
    } };
    const integrations = [_][]const u8{"mcp_fs_read"};
    const result = try executeToolCallAuthorized(tool_ctx, .{
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = .{
            .id = "dynamic-authority",
            .name = "mcp_fs_read",
            .arguments_json = "{}",
        },
        .authority = .ordinary,
        .session_grants = &.{},
        .live_authority = .{
            .generation = 41,
            .root_id = "root",
            .tools = &.{},
            .integrations = &integrations,
            .rules = .{},
            .grants = &.{},
            .permission_mode = .auto,
        },
        .advertised_dynamic_tool_names = &integrations,
        .max_tool_result_bytes = rt.max_tool_result_bytes,
        .expected_mcp_runtime_generation = 73,
    });
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqualStrings("mcp ok", result.model_output);
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(u64, 17), authority.admission_generation);
    try std.testing.expectEqual(@as(u64, 41), authority.action_generation);
    try std.testing.expectEqual(@as(?u64, 73), authority.expected_runtime_generation);
    const original_scope = switch (tool_ctx.mcp_access) {
        .scoped => |scope| scope,
        else => return error.McpScopedAccessExpected,
    };
    try std.testing.expectEqual(@as(u64, 17), original_scope.admission_authority_generation);
    try std.testing.expectEqual(@as(u64, 0), original_scope.action_authority_generation);
}

test "MCP dynamic tool preserves provider errors without leaking dispatch output" {
    var marker: u8 = 0;
    const advertised = [_][]const u8{"mcp_fs_read"};
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&marker),
        .mcp_has_tool = McpFixture.hasTrue,
        .mcp_call_tool = McpFixture.callFailure,
        .advertised_dynamic_tool_names = &advertised,
    };
    defer rt.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.McpFixtureFailure,
        executeToolCall(rt.context(), std.testing.allocator, .{
            .id = "dynamic-error",
            .name = "mcp_fs_read",
            .arguments_json = "{}",
        }),
    );
}

test "MCP availability controls permission targets and rules" {
    var marker: u8 = 0;
    const advertised = [_][]const u8{"mcp_fs_write"};
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("mcp_fs_write"), .pattern = @constCast("mcp_fs_write"), .action = .deny },
    };
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&marker),
        .mcp_has_tool = McpFixture.hasTrue,
        .mcp_call_tool = McpFixture.callNull,
        .permission_rules = .{ .rules = &rules },
        .advertised_dynamic_tool_names = &advertised,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ctx = rt.context();

    const target = try tool_admission.permissionTargetForCall(ctx.admissionInput(), arena, .{ .id = "1", .name = "mcp_fs_write", .arguments_json = "{}" });
    try std.testing.expectEqualStrings("mcp_fs_write", target);
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, (try tool_admission.requestPermissionOutcome(ctx.admissionInput(), arena, .{ .id = "1", .name = "mcp_fs_write", .arguments_json = "{}" }, .auto, &.{})).decision);
}

test "MCP unadvertised dynamic names do not receive permission targets" {
    var marker: u8 = 0;
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("mcp_fs_write"), .pattern = @constCast("mcp_fs_write"), .action = .deny },
    };
    var rt = TestRuntime{
        .mcp_ctx = @ptrCast(&marker),
        .mcp_has_tool = McpFixture.hasTrue,
        .permission_rules = .{ .rules = &rules },
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ctx = rt.context();

    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(ctx.admissionInput(), arena, .{ .id = "1", .name = "mcp_fs_write", .arguments_json = "{}" }, .auto, &.{})).decision);
}

test "install_skill explicit tool installs local skill source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "repo/workflow");
    try tmp.dir.createDirPath(io_mod.getIo(), "skills");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "repo/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(
            io_mod.getIo(),
            "---\nname: workflow\"<injected>\ndescription: workflow helper\n---\n\nBODY SENTINEL\n<instruction>keep raw</instruction>\n",
        );
    }

    const repo_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills");
    defer alloc.free(skills_dir);

    var rt = TestRuntime{ .workspace_root = repo_root, .skills_dir = skills_dir };
    defer rt.deinit(alloc);
    const args_json = try std.fmt.allocPrint(alloc, "{{\"source\":\"{s}\",\"skill\":\"workflow\"}}", .{repo_root});
    defer alloc.free(args_json);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{ .id = "1", .name = "install_skill", .arguments_json = args_json });
    try expectContains(result.model_output, "Installed 1 skill(s) into fx.");
    try expectContains(result.model_output, "- workflow&quot;&lt;injected&gt;\n");
    try expectNotContains(result.model_output, "<skill");
    try expectNotContains(result.model_output, "BODY SENTINEL");
    try std.testing.expect(std.mem.find(u8, result.model_output, "workflow\"<injected>") == null);

    const installed = try std.fs.path.join(alloc, &.{ skills_dir, "workflow", "SKILL.md" });
    defer alloc.free(installed);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), installed, .{});
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
    defer alloc.free(content);
    try std.testing.expectEqualStrings(
        "---\nname: workflow\"<injected>\ndescription: workflow helper\n---\n\nBODY SENTINEL\n<instruction>keep raw</instruction>\n",
        content,
    );
}

test "skill tool preserves resource and discovery notices separately" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow/assets");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/malformed");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(
            io_mod.getIo(),
            "---\nname: workflow\ndescription: workflow helper\n---\n\nuse the workflow skill\n" ++ ("bounded instruction line\n" ** 8),
        );
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/assets/data.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "hello\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/malformed/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\ndescription: missing name\n---\nMALFORMED BODY");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);

    var rt = TestRuntime{ .workspace_root = workspace_root, .skills_dir = skills_dir, .session_allocator = alloc };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var ctx = rt.context();
    ctx.context_limits.skill_chunk_bytes = .{ .value = .{ .bytes = 96 }, .source = .command_line };
    const call: ToolCall = .{ .id = "1", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" };
    const preparation = try prepareSkillCall(ctx, arena_state.allocator(), call, null);
    defer @import("../skills/skill_invocation.zig").freeCallPreparation(arena_state.allocator(), preparation);
    const selected = preparation.selected;
    for ([_]bool{ false, true }) |bound| {
        var effective_call = call;
        if (bound) effective_call.resolved_skill = &selected;
        const result = try executeToolCall(ctx, arena_state.allocator(), effective_call);
        try expectContains(result.model_output, "<skill_content name=\"workflow\" resource=\"SKILL.md\" offset=\"0\"");
        try expectContains(result.model_output, "use the workflow skill");
        try expectNotContains(result.model_output, "assets/data.txt");
        try std.testing.expect(result.system_notice == null);
        try std.testing.expectEqual(@as(usize, 2), result.context_notices.len);
        try expectContains(result.context_notices[0], "[context] skill resource \"workflow/SKILL.md\" truncated");
        try expectContains(result.context_notices[1], "skill discovery warning:");
    }
}

test "skill tool loads the exact advertised duplicate and rejects ambiguous or untrusted locations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace/.agents/skills/workflow/assets");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow/assets");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/outside/workflow/assets");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/workspace/.agents/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: workspace workflow\n---\n\nWORKSPACE BODY A\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/workspace/.agents/skills/workflow/assets/a-only.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "WORKSPACE COMPANION A\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: managed workflow\n---\n\nMANAGED BODY B\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/assets/b-only.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "MANAGED COMPANION B\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/outside/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: outside workflow\n---\n\nOUTSIDE BODY SENTINEL\n");
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/outside/workflow/assets/outside-only.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "OUTSIDE COMPANION SENTINEL\n");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    const workspace_skill = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace/.agents/skills/workflow");
    defer alloc.free(workspace_skill);
    const managed_skill = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills/workflow");
    defer alloc.free(managed_skill);
    const outside_skill = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/outside/workflow");
    defer alloc.free(outside_skill);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var rt = TestRuntime{ .workspace_root = workspace_root, .skills_dir = skills_dir, .session_allocator = alloc };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exact_managed_args = try std.fmt.allocPrint(arena, "{{\"name\":\"workflow\",\"location\":\"{s}\"}}", .{managed_skill});
    const exact = try executeToolCall(rt.context(), arena, .{ .id = "exact", .name = "skill", .arguments_json = exact_managed_args });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, exact.status);
    try expectContains(exact.model_output, "MANAGED BODY B");
    try expectNotContains(exact.model_output, "b-only.txt");
    try expectNotContains(exact.model_output, "WORKSPACE BODY A");
    try expectNotContains(exact.model_output, "a-only.txt");

    const duplicate = try executeToolCall(rt.context(), arena, .{ .id = "duplicate", .name = "skill", .arguments_json = exact_managed_args });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, duplicate.status);
    try expectContains(duplicate.model_output, "MANAGED BODY B");
    try expectNotContains(duplicate.model_output, "already loaded");

    const ambiguous = try executeToolCall(rt.context(), arena, .{ .id = "ambiguous", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, ambiguous.status);
    try expectContains(ambiguous.model_output, "ambiguous");
    try expectContains(ambiguous.model_output, workspace_skill);
    try expectContains(ambiguous.model_output, managed_skill);

    const outside_args = try std.fmt.allocPrint(arena, "{{\"name\":\"workflow\",\"location\":\"{s}\"}}", .{outside_skill});
    const outside = try executeToolCall(rt.context(), arena, .{ .id = "outside", .name = "skill", .arguments_json = outside_args });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, outside.status);
    try expectNotContains(outside.model_output, "OUTSIDE BODY SENTINEL");
    try expectNotContains(outside.model_output, "outside-only.txt");

    const mismatch_args = try std.fmt.allocPrint(arena, "{{\"name\":\"other\",\"location\":\"{s}\"}}", .{managed_skill});
    const mismatch = try executeToolCall(rt.context(), arena, .{ .id = "mismatch", .name = "skill", .arguments_json = mismatch_args });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, mismatch.status);
    try expectContains(mismatch.model_output, "does not match");
    try expectNotContains(mismatch.model_output, "MANAGED BODY B");
}

test "name-only skill call rediscovers a duplicate added after the first read" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/workflow");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: managed workflow\n---\n\nMANAGED BODY A\n");
    }

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var rt = TestRuntime{ .workspace_root = workspace_root, .skills_dir = skills_dir, .session_allocator = alloc };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = try executeToolCall(rt.context(), arena, .{ .id = "first", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, first.status);
    try expectContains(first.model_output, "MANAGED BODY A");

    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace/.agents/skills/workflow");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "home/workspace/.agents/skills/workflow/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "---\nname: workflow\ndescription: workspace workflow\n---\n\nWORKSPACE BODY B\n");
    }

    const rediscovered = try executeToolCall(rt.context(), arena, .{ .id = "rediscovered", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, rediscovered.status);
    try expectContains(rediscovered.model_output, "ambiguous");
    try expectNotContains(rediscovered.model_output, "already loaded");
}

test "supplied session grant authorizes skill in a fresh session" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var rt = TestRuntime{};
    defer rt.deinit(alloc);

    const grants = [_]PermissionGrant{
        .{ .tool_name = @constCast("skill"), .target_path = @constCast("workflow") },
    };

    const decision = (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena_state.allocator(), .{
        .id = "1",
        .name = "skill",
        .arguments_json = "{\"name\":\"workflow\"}",
    }, .ask, &grants)).decision;

    try std.testing.expectEqual(ToolPermissionDecision.once, decision);
}

test "skill tool reports missing skill" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(skills_dir);
    try setTestHome(null);
    defer setTestHome(null) catch {};

    var rt = TestRuntime{ .workspace_root = workspace_root, .skills_dir = skills_dir };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{ .id = "1", .name = "skill", .arguments_json = "{\"name\":\"missing\"}" });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "Skill \"missing\" not found.");
    try expectContains(result.model_output, "Refresh available skills");
}

const vision_test_registry_tools = [_]tool_dispatch.Tool{test_builtin_tools.vision};

const VisionGatewayResponse = struct {
    status: std.http.Status = .ok,
    content: ?[]const u8 = null,
    usage: types.Usage = .{},
    generation_id: ?[]const u8 = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
};

const VisionGatewayFixture = struct {
    alloc: Allocator,
    responses: []const VisionGatewayResponse,
    allocation_probe: ?*std.testing.FailingAllocator = null,
    allocation_index_at_stream: ?usize = null,
    payloads: std.ArrayList([]u8) = .empty,
    call_count: usize = 0,
    cancel_after_call: ?usize = null,
    last_api_key: []const u8 = "",
    last_team: ?[]const u8 = null,
    last_model: []const u8 = "",
    last_retry_count: usize = 0,

    fn deinit(self: *VisionGatewayFixture) void {
        for (self.payloads.items) |payload| self.alloc.free(payload);
        self.payloads.deinit(self.alloc);
    }

    fn provider(self: *VisionGatewayFixture) agent_stream_provider.Provider {
        var result = test_builtin_gateway.agent_stream_provider;
        result.context = self;
        result.stream_fn = stream;
        return result;
    }

    fn stream(
        context: ?*anyopaque,
        _: Allocator,
        request: agent_stream_provider.ModelRequest,
    ) anyerror!agent_stream_provider.Result {
        const self: *VisionGatewayFixture = @ptrCast(@alignCast(context.?));
        if (self.allocation_probe) |probe| {
            self.allocation_index_at_stream = probe.alloc_index;
        }
        const response_index = self.call_count;
        self.call_count += 1;
        const payload = try test_builtin_gateway.buildAgentRequest(self.alloc, request.data());
        defer self.alloc.free(payload);
        try self.payloads.append(self.alloc, try self.alloc.dupe(u8, payload));
        self.last_api_key = request.credential.secret() orelse "";
        self.last_team = request.credential.tenant();
        self.last_model = request.model;
        self.last_retry_count = request.retry_count;
        if (self.cancel_after_call == self.call_count) request.cancel_flag.store(true, .seq_cst);
        if (response_index >= self.responses.len) return error.UnexpectedVisionGatewayCall;
        const response = self.responses[response_index];
        try request.admission.admit();
        request.delivery.markPossiblySent();
        if (response.status != .ok) return .{ .failed = .{ .kind = .provider_error } };
        const credential_source = request.credential.credentialSource() orelse
            return error.MissingCredentialSource;
        return .{ .completed = .{
            .completion = .{
                .content = response.content,
                .generation_id = response.generation_id,
                .finish_reason = .stop,
                .usage = response.usage,
            },
            .usage = .{ .deferred = .{
                .provider = .gateway,
                .generation_id = response.generation_id orelse "gen_test",
                .scope = "https://ai-gateway.vercel.sh",
                .tenant = request.credential.tenant(),
                .credential_source = credential_source,
                .credential_identity = credential_authority.derive(
                    credential_source,
                    request.credential.accountId(),
                ),
            } },
        } };
    }
};

fn makeVisionCatalog(
    alloc: Allocator,
    dir: std.Io.Dir,
    count: usize,
) ![]types.ImageAttachment {
    const catalog = try alloc.alloc(types.ImageAttachment, count);
    errdefer alloc.free(catalog);
    var initialized: usize = 0;
    errdefer for (catalog[0..initialized]) |image| types.freeImageAttachment(alloc, image);
    const root = try io_mod.dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);
    for (catalog, 0..) |*image, index| {
        const name = try std.fmt.allocPrint(alloc, "vision-{d}.png", .{index + 1});
        defer alloc.free(name);
        try dir.writeFile(io_mod.getIo(), .{ .sub_path = name, .data = "\x89PNG\r\n\x1a\nimage bytes" });
        const path = try io_mod.dirRealpathAlloc(alloc, dir, name);
        var path_owned = true;
        errdefer if (path_owned) alloc.free(path);
        const media_type = try alloc.dupe(u8, "image/png");
        var media_type_owned = true;
        errdefer if (media_type_owned) alloc.free(media_type);
        image.* = .{ .id = index + 1, .path = path, .media_type = media_type };
        path_owned = false;
        media_type_owned = false;
        var image_initialized = false;
        errdefer if (!image_initialized) types.freeImageAttachment(alloc, image.*);
        try image_attachments.captureImageSnapshot(alloc, image, snapshot_dir);
        initialized += 1;
        image_initialized = true;
    }
    return catalog;
}

fn visionArgs(alloc: Allocator, image_ids: []const usize, focus: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"image_ids\":");
    try std.json.Stringify.value(image_ids, .{}, &out.writer);
    try out.writer.writeAll(",\"focus\":");
    try std.json.Stringify.value(focus, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn visionProviderSuccess(alloc: Allocator, image_ids: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"images\":[");
    for (image_ids, 0..) |image_id, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"image_id\":{d},\"status\":\"ok\",\"summary\":\"evidence {d}\",\"visible_text\":[],\"details\":[]}}",
            .{ image_id, image_id },
        );
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn visionProviderSuccessReversed(alloc: Allocator, image_ids: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"images\":[");
    var index = image_ids.len;
    while (index > 0) {
        index -= 1;
        if (index + 1 < image_ids.len) try out.writer.writeByte(',');
        const image_id = image_ids[index];
        try out.writer.print(
            "{{\"image_id\":{d},\"status\":\"ok\",\"summary\":\"evidence {d}\",\"visible_text\":[],\"details\":[]}}",
            .{ image_id, image_id },
        );
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn executeVisionForTest(
    rt: *TestRuntime,
    alloc: Allocator,
    args_json: []const u8,
    catalog: []const types.ImageAttachment,
) !ToolExecutionResult {
    return executeToolCallAuthorized(rt.context(), .{
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = .{ .id = "vision-call", .name = "vision", .arguments_json = args_json },
        .authority = .ordinary,
        .authorized_image_catalog = catalog,
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });
}

fn executeVisionPathForTest(
    rt: *TestRuntime,
    alloc: Allocator,
    args_json: []const u8,
    canonical_paths: []const []const u8,
) !ToolExecutionResult {
    const targets = try alloc.alloc(
        command_admission.VisionPathExecutionTarget,
        canonical_paths.len,
    );
    var initialized: usize = 0;
    defer {
        for (targets[0..initialized]) |target| {
            alloc.free(@constCast(target.canonical_path));
        }
        alloc.free(targets);
    }
    for (canonical_paths, targets) |path, *target| {
        var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        target.* = .{
            .canonical_path = try alloc.dupe(u8, path),
            .identity = pathing.fileIdentity(
                try pathing.descriptorDevice(file.handle),
                stat,
            ),
        };
        initialized += 1;
    }
    return executeVisionPathTargetsForTest(rt, alloc, args_json, targets);
}

fn executeVisionPathTargetsForTest(
    rt: *TestRuntime,
    alloc: Allocator,
    args_json: []const u8,
    targets: []const command_admission.VisionPathExecutionTarget,
) !ToolExecutionResult {
    return executeToolCallAuthorized(rt.context(), .{
        .call_allocator = alloc,
        .result_allocator = alloc,
        .call = .{ .id = "vision-call", .name = "vision", .arguments_json = args_json },
        .authority = .{ .vision_paths = .{ .targets = targets } },
        .authorized_image_catalog = &.{},
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });
}

test "Codex vision calls fail before provider access" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 1);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const provider_json = try visionProviderSuccess(alloc, &.{1});
    defer alloc.free(provider_json);
    const responses = [_]VisionGatewayResponse{.{ .content = provider_json }};
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .provider = .codex,
        .provider_capabilities = .{},
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = alloc,
    };
    defer rt.deinit(alloc);
    const args = try visionArgs(alloc, &.{1}, "Read the image");
    defer alloc.free(args);

    const result = try executeVisionForTest(&rt, alloc, args, catalog);
    defer alloc.free(@constCast(result.model_output));

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try std.testing.expectEqualStrings("Unsupported tool: vision", result.model_output);
    try std.testing.expectEqual(@as(usize, 0), fixture.call_count);
}

fn visionRequestAllocationCount(args_json: []const u8) !usize {
    var probe = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .resize_fail_index = 0 },
    );
    const alloc = probe.allocator();
    const request = try tool_contracts.vision.parse_vision_request(alloc, args_json);
    request.deinit(alloc);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);
    return probe.alloc_index;
}

fn visionProviderParseAllocationCount(provider_json: []const u8) !usize {
    var probe = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .resize_fail_index = 0 },
    );
    const alloc = probe.allocator();
    const parsed = try tool_contracts.vision.parse_vision_provider_result(
        alloc,
        provider_json,
        provider_json.len,
    );
    parsed.deinit(alloc);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);
    return probe.alloc_index;
}

fn visionAllocationIndexAtGateway(
    catalog: []const types.ImageAttachment,
    args_json: []const u8,
    provider_json: []const u8,
) !usize {
    const base = std.testing.allocator;
    var probe = std.testing.FailingAllocator.init(
        base,
        .{ .resize_fail_index = 0 },
    );
    const responses = [_]VisionGatewayResponse{.{ .content = provider_json }};
    var fixture = VisionGatewayFixture{
        .alloc = base,
        .responses = &responses,
        .allocation_probe = &probe,
    };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = base,
        .context_limits = .{ .image_adapter_output_bytes = .{
            .value = .{ .bytes = 64 * 1024 },
            .source = .command_line,
        } },
    };
    defer rt.deinit(base);
    const alloc = probe.allocator();

    const result = try executeVisionForTest(&rt, alloc, args_json, catalog);
    alloc.free(@constCast(result.model_output));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);
    return fixture.allocation_index_at_stream orelse error.TestExpectedEqual;
}

const OneShotFailingAllocator = struct {
    failing: std.testing.FailingAllocator,

    fn init(alloc: Allocator, fail_index: usize) OneShotFailingAllocator {
        return .{ .failing = .init(alloc, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        }) };
    }

    fn allocator(self: *OneShotFailingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn allocate(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        const result = self.failing.allocator().rawAlloc(
            len,
            alignment,
            return_address,
        );
        if (result == null and self.failing.has_induced_failure) {
            self.failing.fail_index = std.math.maxInt(usize);
        }
        return result;
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        return self.failing.allocator().rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        return self.failing.allocator().rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        self.failing.allocator().rawFree(memory, alignment, return_address);
    }
};

fn expectVisionOutOfMemoryAt(
    fail_index: usize,
    expected_gateway_calls: usize,
    catalog: []const types.ImageAttachment,
    args_json: []const u8,
    provider_json: []const u8,
) !void {
    const base = std.testing.allocator;
    var failing = OneShotFailingAllocator.init(base, fail_index);
    const responses = [_]VisionGatewayResponse{.{ .content = provider_json }};
    var fixture = VisionGatewayFixture{ .alloc = base, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = base,
        .context_limits = .{ .image_adapter_output_bytes = .{
            .value = .{ .bytes = 64 * 1024 },
            .source = .command_line,
        } },
    };
    defer rt.deinit(base);
    const alloc = failing.allocator();

    if (executeVisionForTest(&rt, alloc, args_json, catalog)) |result| {
        alloc.free(@constCast(result.model_output));
        if (result.interactive_notice != null or result.system_notice != null) {
            return error.OutOfMemoryProducedVisionNotice;
        }
        return error.OutOfMemoryReturnedVisionResult;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(failing.failing.has_induced_failure);
    try std.testing.expectEqual(expected_gateway_calls, fixture.call_count);
    try std.testing.expectEqual(
        failing.failing.allocated_bytes,
        failing.failing.freed_bytes,
    );
}

test "vision runtime propagates request and authorized catalog allocation failures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 1);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const args_json = "{\"image_ids\":[1],\"focus\":\"inspect\"}";
    const provider_json = "{\"images\":[]}";

    try expectVisionOutOfMemoryAt(0, 0, catalog, args_json, provider_json);
    try expectVisionOutOfMemoryAt(
        try visionRequestAllocationCount(args_json),
        0,
        catalog,
        args_json,
        provider_json,
    );
}

test "vision runtime propagates provider and parser allocation failures without outage notices" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 1);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const args_json = "{\"image_ids\":[1],\"focus\":\"inspect\"}";
    const provider_json = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"read\",\"visible_text\":[],\"details\":[]}]}";
    const stream_alloc_index = try visionAllocationIndexAtGateway(
        catalog,
        args_json,
        provider_json,
    );

    try expectVisionOutOfMemoryAt(
        stream_alloc_index,
        1,
        catalog,
        args_json,
        provider_json,
    );
    try expectVisionOutOfMemoryAt(
        stream_alloc_index + 1,
        1,
        catalog,
        args_json,
        provider_json,
    );
}

test "vision parsed record transfer allocation failure releases the parsed owner" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 1);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const args_json = "{\"image_ids\":[1],\"focus\":\"inspect\"}";
    const provider_json = "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"read\",\"visible_text\":[],\"details\":[]}]}";
    const transfer_capacity_fail_index =
        try visionAllocationIndexAtGateway(catalog, args_json, provider_json) +
        1 +
        try visionProviderParseAllocationCount(provider_json);

    try expectVisionOutOfMemoryAt(
        transfer_capacity_fail_index,
        1,
        catalog,
        args_json,
        provider_json,
    );
}

test "vision authorized catalog retains historical access outside budgeted model history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_images = try makeVisionCatalog(alloc, tmp.dir, 1);
    defer types.freeImageAttachmentSlice(alloc, source_images);
    source_images[0].id = 41;
    const history = [_]types.HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("historical turn"), .images = source_images },
            .assistant = @constCast("historical answer"),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("newer turn without images") },
            .assistant = @constCast("newer answer"),
        } },
    };
    const catalog = try session_runtime.collect_image_catalog(alloc, &history, &.{});
    defer types.freeImageAttachmentSlice(alloc, catalog);
    var budget_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer budget_arena_state.deinit();
    var budgeted_messages: std.ArrayList(ChatMessage) = .empty;
    try session_runtime.appendHistoryChatMessagesBudgeted(
        budget_arena_state.allocator(),
        &budgeted_messages,
        &history,
        .{ .max_tokens = 1 },
    );
    for (budgeted_messages.items) |message| {
        try std.testing.expectEqual(@as(usize, 0), message.images.len);
    }

    const provider_json = try visionProviderSuccess(alloc, &.{41});
    defer alloc.free(provider_json);
    const responses = [_]VisionGatewayResponse{.{ .content = provider_json }};
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = alloc,
    };
    defer rt.deinit(alloc);

    const result = try executeVisionForTest(
        &rt,
        alloc,
        "{\"image_ids\":[41],\"focus\":\"inspect historical evidence\"}",
        catalog,
    );
    defer alloc.free(@constCast(result.model_output));

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try expectContains(result.model_output, "\"image_id\":41");
    try std.testing.expectEqual(@as(usize, 1), fixture.call_count);
}

test "vision runtime resolves historical authorized images and batches twenty as eight eight four" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 20);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const requested = [_]usize{ 20, 1, 19, 2, 18, 3, 17, 4, 16, 5, 15, 6, 14, 7, 13, 8, 12, 9, 11, 10 };
    const first = try visionProviderSuccessReversed(alloc, requested[0..8]);
    defer alloc.free(first);
    const second = try visionProviderSuccessReversed(alloc, requested[8..16]);
    defer alloc.free(second);
    const third = try visionProviderSuccessReversed(alloc, requested[16..20]);
    defer alloc.free(third);
    const responses = [_]VisionGatewayResponse{
        .{ .content = first, .usage = .{ .input_tokens = 2, .output_tokens = 3 } },
        .{
            .content = second,
            .usage = .{ .input_tokens = 5, .output_tokens = 7 },
            .generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        },
        .{
            .content = third,
            .usage = .{ .input_tokens = 11, .output_tokens = 13 },
            .generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAX",
        },
    };
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .api_key = "gateway-key",
        .gateway_team = "team_vision",
        .gateway_retry_count = 2,
        .gateway_chat_url = "https://gateway.invalid/chat",
        .session_allocator = alloc,
        .context_limits = .{ .image_adapter_output_bytes = .{
            .value = .{ .bytes = 64 * 1024 },
            .source = .command_line,
        } },
    };
    defer rt.deinit(alloc);
    const args = try visionArgs(alloc, &requested, "Read the build state");
    defer alloc.free(args);

    const result = try executeVisionForTest(&rt, alloc, args, catalog);
    defer alloc.free(@constCast(result.model_output));

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 3), fixture.call_count);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, fixture.payloads.items[0], "\"type\":\"file\""));
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, fixture.payloads.items[1], "\"type\":\"file\""));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, fixture.payloads.items[2], "\"type\":\"file\""));
    try std.testing.expectEqualStrings("google/gemini-2.5-flash", fixture.last_model);
    try std.testing.expectEqualStrings("gateway-key", fixture.last_api_key);
    try std.testing.expectEqualStrings("team_vision", fixture.last_team.?);
    try std.testing.expectEqual(@as(usize, 2), fixture.last_retry_count);
    try expectContains(fixture.payloads.items[0], "Read the build state");
    try expectContains(fixture.payloads.items[0], "\"mediaType\":\"image/png\"");
    for (fixture.payloads.items) |payload| {
        for (catalog) |image| try expectNotContains(payload, image.path);
    }
    var previous_offset: usize = 0;
    for (requested) |image_id| {
        const needle = try std.fmt.allocPrint(alloc, "\"image_id\":{d}", .{image_id});
        defer alloc.free(needle);
        const relative = std.mem.findPos(u8, result.model_output, previous_offset, needle) orelse return error.TestExpectedEqual;
        previous_offset = relative + needle.len;
    }
    try std.testing.expectEqual(@as(u64, 18), result.inner_usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 23), result.inner_usage.?.output_tokens);
    var usage_snapshot = try rt.session.usage.snapshot(alloc);
    defer usage_snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), usage_snapshot.pending.len);
}

test "vision runtime rejects unauthorized ids before filesystem or provider access" {
    const alloc = std.testing.allocator;
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &.{} };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
    };
    defer rt.deinit(alloc);

    const result = try executeVisionForTest(&rt, alloc, "{\"image_ids\":[91],\"focus\":\"inspect\"}", &.{});
    defer alloc.free(@constCast(result.model_output));

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "UnauthorizedImageId");
    try std.testing.expectEqual(@as(usize, 0), fixture.call_count);
}

test "vision runtime rejects a path source without canonical path authority" {
    const alloc = std.testing.allocator;
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &.{} };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .workspace_root = "/tmp",
    };
    defer rt.deinit(alloc);

    try std.testing.expectError(
        error.InvalidVisionExecutionAuthority,
        executeVisionForTest(
            &rt,
            alloc,
            "{\"paths\":[\"unapproved.png\"],\"focus\":\"inspect\"}",
            &.{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fixture.call_count);
}

test "vision runtime loads approved paths into a transient authorized catalog" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "photo.png",
        .data = "\x89PNG\r\n\x1a\nimage bytes",
    });
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "photo.png");
    defer alloc.free(source_path);
    const provider_json = try visionProviderSuccess(alloc, &.{1});
    defer alloc.free(provider_json);
    const responses = [_]VisionGatewayResponse{.{ .content = provider_json }};
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .workspace_root = workspace,
        .session_allocator = alloc,
        .context_limits = .{ .image_adapter_output_bytes = .{
            .value = .{ .bytes = 64 * 1024 },
            .source = .command_line,
        } },
    };
    defer rt.deinit(alloc);

    const result = try executeVisionPathForTest(
        &rt,
        alloc,
        "{\"paths\":[\"photo.png\"],\"focus\":\"inspect\"}",
        &.{source_path},
    );
    defer alloc.free(@constCast(result.model_output));

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try expectContains(result.model_output, "\"image_id\":1");
    try std.testing.expectEqual(@as(usize, 1), fixture.call_count);
    try expectContains(fixture.payloads.items[0], "\"type\":\"file\"");
    try expectNotContains(fixture.payloads.items[0], source_path);
}

test "vision runtime returns bounded failures for unavailable approved paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "removed.png",
        .data = "\x89PNG\r\n\x1a\nimage bytes",
    });
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const removed_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "removed.png");
    defer alloc.free(removed_path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), removed_path, .{
        .follow_symlinks = false,
    });
    const stat = try file.stat(io_mod.getIo());
    const target: command_admission.VisionPathExecutionTarget = .{
        .canonical_path = removed_path,
        .identity = pathing.fileIdentity(
            try pathing.descriptorDevice(file.handle),
            stat,
        ),
    };
    file.close(io_mod.getIo());
    try tmp.dir.deleteFile(io_mod.getIo(), "removed.png");

    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &.{} };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .workspace_root = workspace,
    };
    defer rt.deinit(alloc);

    const result = try executeVisionPathTargetsForTest(
        &rt,
        alloc,
        "{\"paths\":[\"removed.png\"],\"focus\":\"inspect\"}",
        &.{target},
    );
    defer alloc.free(@constCast(result.model_output));

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "FileNotFound");
    try std.testing.expectEqual(@as(usize, 0), fixture.call_count);
}

test "vision runtime propagates cancellation while preparing approved paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "photo.png",
        .data = "\x89PNG\r\n\x1a\nimage bytes",
    });
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const source_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "photo.png");
    defer alloc.free(source_path);
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &.{} };
    defer fixture.deinit();
    var cancel_flag = std.atomic.Value(bool).init(true);
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .workspace_root = workspace,
        .cancel_flag = &cancel_flag,
    };
    defer rt.deinit(alloc);

    try std.testing.expectError(
        error.Cancelled,
        executeVisionPathForTest(
            &rt,
            alloc,
            "{\"paths\":[\"photo.png\"],\"focus\":\"inspect\"}",
            &.{source_path},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fixture.call_count);
}

test "vision runtime preserves partial success and exact total outage notices" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 2);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const partial_json =
        "{\"images\":[" ++
        "{\"image_id\":1,\"status\":\"ok\",\"summary\":\"read\",\"visible_text\":[],\"details\":[]}]}";
    // The malformed response is scripted twice because a structurally invalid
    // successful response is retried once. The outage before it is not retried.
    const responses = [_]VisionGatewayResponse{
        .{ .content = partial_json },
        .{ .status = .service_unavailable },
        .{ .content = "not-json" },
        .{ .content = "not-json" },
    };
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = alloc,
    };
    defer rt.deinit(alloc);

    const partial = try executeVisionForTest(&rt, alloc, "{\"image_ids\":[1,2],\"focus\":\"inspect\"}", catalog);
    defer alloc.free(@constCast(partial.model_output));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, partial.status);
    try std.testing.expect(partial.interactive_notice == null);
    try expectContains(partial.model_output, "\"status\":\"ok\"");
    try expectContains(partial.model_output, "\"code\":\"missing_provider_record\"");
    try expectContains(partial.model_output, "\"retryable\":true");
    try std.testing.expect(partial.status_detail == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.call_count);

    const outage = try executeVisionForTest(&rt, alloc, "{\"image_ids\":[1],\"focus\":\"inspect\"}", catalog);
    defer alloc.free(@constCast(outage.model_output));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, outage.status);
    try std.testing.expectEqualStrings(vision_executor.outage_tip, outage.interactive_notice.?.body);
    try std.testing.expectEqualStrings(vision_executor.outage_system_notice, outage.system_notice.?);
    try expectContains(outage.model_output, "\"code\":\"vision_unavailable\"");
    try std.testing.expectEqualStrings("Vision is unavailable right now", outage.status_detail.?);
    try expectContains(outage.system_notice.?, "None of the requested images were read");
    try expectContains(outage.system_notice.?, "retry Vision");
    try expectContains(outage.system_notice.?, "change strategy");
    try expectContains(outage.system_notice.?, "without making visual claims");
    try std.testing.expectEqual(@as(usize, 2), fixture.call_count);

    const malformed = try executeVisionForTest(&rt, alloc, "{\"image_ids\":[2],\"focus\":\"inspect\"}", catalog);
    defer alloc.free(@constCast(malformed.model_output));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, malformed.status);
    try expectContains(malformed.model_output, "\"code\":\"provider_response_invalid\"");
    try expectContains(malformed.model_output, "\"retryable\":true");
    try std.testing.expectEqualStrings("provider response stayed invalid after one retry", malformed.status_detail.?);
    try std.testing.expect(malformed.interactive_notice == null);
    try std.testing.expect(malformed.system_notice == null);
    try std.testing.expectEqual(@as(usize, 4), fixture.call_count);
}

test "vision runtime classifies an empty successful provider result as invalid" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 1);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const responses = [_]VisionGatewayResponse{
        .{ .content = "{\"images\":[]}" },
        .{ .content = "{\"images\":[]}" },
    };
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = alloc,
    };
    defer rt.deinit(alloc);

    const result = try executeVisionForTest(
        &rt,
        alloc,
        "{\"image_ids\":[1],\"focus\":\"inspect\"}",
        catalog,
    );
    defer alloc.free(@constCast(result.model_output));

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "\"code\":\"provider_response_invalid\"");
    try std.testing.expectEqualStrings("provider response stayed invalid after one retry", result.status_detail.?);
    try std.testing.expect(
        std.mem.find(u8, result.model_output, "\"image_id\":1") != null,
    );
    try std.testing.expect(result.interactive_notice == null);
    try std.testing.expect(result.system_notice == null);
    // An empty successful response is structurally invalid, so it earns the single retry.
    try std.testing.expectEqual(@as(usize, 2), fixture.call_count);
}

test "vision runtime honors configured provider bounds without a hidden twenty KiB ceiling" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 1);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const evidence = "x" ** 3500;
    var large_out: std.Io.Writer.Allocating = .init(alloc);
    defer large_out.deinit();
    try large_out.writer.writeAll("{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"large\",\"visible_text\":[");
    for (0..7) |index| {
        if (index > 0) try large_out.writer.writeByte(',');
        try std.json.Stringify.value(evidence, .{}, &large_out.writer);
    }
    try large_out.writer.writeAll("],\"details\":[]}]}");
    const large_json = try large_out.toOwnedSlice();
    defer alloc.free(large_json);
    try std.testing.expect(large_json.len > 20 * 1024);
    const responses = [_]VisionGatewayResponse{
        .{ .content = large_json },
        .{ .content = large_json },
        .{ .content = large_json },
    };
    var fixture = VisionGatewayFixture{ .alloc = alloc, .responses = &responses };
    defer fixture.deinit();
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .session_allocator = alloc,
        .context_limits = .{ .image_adapter_output_bytes = .{
            .value = .{ .bytes = large_json.len },
            .source = .command_line,
        } },
    };
    defer rt.deinit(alloc);

    const accepted = try executeVisionForTest(&rt, alloc, "{\"image_ids\":[1],\"focus\":\"inspect\"}", catalog);
    defer alloc.free(@constCast(accepted.model_output));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, accepted.status);
    try std.testing.expectEqual(@as(usize, 1), fixture.call_count);
    rt.context_limits.image_adapter_output_bytes.value = .{ .bytes = large_json.len - 1 };
    const rejected = try executeVisionForTest(&rt, alloc, "{\"image_ids\":[1],\"focus\":\"inspect\"}", catalog);
    defer alloc.free(@constCast(rejected.model_output));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, rejected.status);
    try expectContains(rejected.model_output, "\"code\":\"output_limit_exceeded\"");
    try expectContains(rejected.model_output, "Call Vision again with a narrower focus or fewer images.");
    try std.testing.expectEqualStrings("response exceeded the configured output budget", rejected.status_detail.?);
    try std.testing.expectEqual(@as(usize, 2), fixture.call_count);
    rt.context_limits.image_adapter_output_bytes.value = .off;
    const unbounded = try executeVisionForTest(&rt, alloc, "{\"image_ids\":[1],\"focus\":\"inspect\"}", catalog);
    defer alloc.free(@constCast(unbounded.model_output));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, unbounded.status);
    try std.testing.expectEqual(@as(usize, 3), fixture.call_count);
}

test "vision cancellation stops later batches and does not surface the outage tip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog = try makeVisionCatalog(alloc, tmp.dir, 9);
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const first = try visionProviderSuccess(alloc, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    defer alloc.free(first);
    const responses = [_]VisionGatewayResponse{.{ .content = first }};
    var fixture = VisionGatewayFixture{
        .alloc = alloc,
        .responses = &responses,
        .cancel_after_call = 1,
    };
    defer fixture.deinit();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var rt = TestRuntime{
        .agent_stream_provider = fixture.provider(),
        .tool_registry = .{ .tools = vision_test_registry_tools[0..] },
        .cancel_flag = &cancel_flag,
        .session_allocator = alloc,
        .context_limits = .{ .image_adapter_output_bytes = .{
            .value = .{ .bytes = 64 * 1024 },
            .source = .command_line,
        } },
    };
    defer rt.deinit(alloc);

    try std.testing.expectError(
        error.Cancelled,
        executeVisionForTest(
            &rt,
            alloc,
            "{\"image_ids\":[1,2,3,4,5,6,7,8,9],\"focus\":\"inspect\"}",
            catalog,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), fixture.call_count);
}
