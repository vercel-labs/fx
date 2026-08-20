const std = @import("std");
const builtin = @import("builtin");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const oauth_transport = @import("../../gateway/auth/oauth_transport.zig");
const command_contract = @import("../execution/command_contract.zig");
const command_environment = @import("../execution/command_environment.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const vision_executor = @import("../agent/runtime/vision_executor.zig");
const background_runtime = @import("../background/background_runtime.zig");
const background_launch_identity = @import("../background/background_launch_identity.zig");
const process_supervisor = @import("../background/process_supervisor.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const gateway_schema = @import("gateway_schema.zig");
const hooks = @import("../hooks/hooks.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const glob_pattern = @import("../workspace/glob_pattern.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const permission_request = @import("../permissions/permission_request.zig");
const command_admission = @import("../permissions/command_admission.zig");
const pathing = @import("../workspace/pathing.zig");
const devbox_executor = @import("../execution/devbox_executor.zig");
const execution_router = @import("../execution/router.zig");
const sandbox = @import("../permissions/sandbox.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_communication_store = @import("../subagent/communication_store.zig");
const subagent_control_store = @import("../subagent/control_store.zig");
const subagent_create_store = @import("../subagent/create_store.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_tool_provider = @import("../subagent/tool_provider.zig");
const subagent_tool_result = @import("../subagent/tool_result.zig");
const session_runtime = @import("../session/session.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_codec_mod = @import("../session/session_codec.zig");
const task_helpers = @import("../tasks/task_helpers.zig");
const session_child_store = @import("../session/session_child_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const route_snapshot = @import("../gateway/route_snapshot.zig");
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
const tool_mcp_feature_dispatch = @import("tool_mcp_feature_dispatch.zig");
const tool_presentation = @import("tool_presentation.zig");
const web_fetch_runtime = @import("web_fetch_runtime.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_fetch_artifacts = @import("../session/web_fetch_artifacts.zig");
const types = @import("../shared/types.zig");
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
const BackgroundRuntime = background_runtime.BackgroundRuntime;
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
    provider_adapter: agent_stream_provider.ProviderAdapter = agent_stream_provider.unavailable_adapter,
    route: ?*const route_snapshot.RouteSnapshot = null,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    gateway_team: ?[]const u8 = null,
    credential_source: ?types.CredentialSource = null,
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
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
    background: *BackgroundRuntime,
    session: *SessionRuntime,
    session_allocator: Allocator = std.heap.c_allocator,
    skills_dir: []const u8 = "",
    context_limits: context_limits.Values = .{},
    context_registry: context_contract.Registry,
    context_enabled: bool = true,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: *anyopaque,
    on_output_chunk: command_contract.CommandOutputCallback,
    background_url_ctx: *anyopaque,
    on_background_url_ready: *const fn (*anyopaque, u64, []const u8) void,
    command_artifact_dir: ?[]const u8 = null,
    tool_result_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    terminal_client: ?*terminal_client_runtime.Runtime = null,
    command_timeout_ms: ?usize = null,
    command_timeout_started_ms: ?i64 = null,
    command_replay_capture: ?*command_replay_store.Capture = null,
    command_replay_unavailable: bool = false,
    sandbox_backend: sandbox.BackendKind = .none,
    devbox_provider: ?devbox_executor.Provider = null,
    tracker: ?*change_tracker.ChangeTracker = null,
    mcp_ctx: ?*anyopaque = null,
    mcp_has_tool: ?tool_mcp_runtime.HasToolFn = null,
    mcp_validate_tool: ?tool_mcp_runtime.ValidateToolFn = null,
    mcp_call_tool: ?tool_mcp_runtime.CallToolFn = null,
    mcp_search_tools: ?tool_mcp_runtime.SearchToolsFn = null,
    mcp_tool_schema: ?tool_mcp_runtime.ToolSchemaFn = null,
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
    model_descriptor_resolver: ?model_capabilities.Resolver = null,
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
            .permission_prompter = self.permission_prompter,
            .background = self.background,
            .sandbox_backend = self.sandbox_backend,
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
            input.sandbox_backend = live.sandbox_backend;
            input.advertised_dynamic_tool_names = live.integrations;
        }
        return input;
    }

    fn admissionAutoClassifier(self: Context) permission_auto_classifier.Classifier {
        if (self.auto_classifier.enabled()) return self.auto_classifier;
        if (self.permission_review_turn) |turn| {
            if (turn.adapter_input) |input| {
                return permission_auto_classifier.Classifier.withAdapter(input);
            }
        }
        const provider = self.permission_reviewer_provider orelse
            return permission_auto_classifier.Classifier.disabled();
        return permission_auto_classifier.Classifier.withProvider(provider, .{
            .credential = self.api_key,
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

pub fn validateToolCall(ctx: Context, arena: Allocator, call: ToolCall) !tool_contracts.ToolCallValidationResult {
    const spec = registeredToolSpec(ctx, call.name) orelse {
        return switch (try tool_mcp_runtime.validateAdvertisedDynamicTool(.{
            .is_registered_tool = false,
            .advertised_dynamic_tool_names = ctx.advertised_dynamic_tool_names,
            .runtime = mcpRuntimeCapabilities(ctx),
        }, arena, call.name, call.arguments_json)) {
            .valid => .valid,
            .invalid => |reason| .{ .failure = reason },
            .not_available => .not_registered,
        };
    };
    switch (spec.executor_kind) {
        // Preserve execution-time argument failures for MCP control tool calls.
        .mcp_search_tools, .mcp_select_tool, .mcp_features => return .valid,
        // File mutation arguments are decoded once by shared permission preflight.
        .write_file, .edit_file => return .valid,
        else => {},
    }

    var dispatch_ctx = typedDispatchContext(ctx, arena);
    dispatch_ctx.captured_command_host = spec.captured_command_host;
    return switch (try tool_dispatch.validateRegisteredToolCall(dispatch_ctx, ctx.tool_registry, call)) {
        .not_registered => .not_registered,
        .valid => .valid,
        .failure => |reason| .{ .failure = reason },
    };
}

pub fn checkToolAvailability(ctx: Context, arena: Allocator, call: ToolCall) !?[]const u8 {
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
    if (request.live_authority) |authority| {
        if (!containsName(authority.tools, request.call.name) and
            !containsName(authority.integrations, request.call.name))
        {
            return error.LiveToolAuthorityUnavailable;
        }
        execution_ctx.permission_mode = authority.permission_mode;
        execution_ctx.permission_grants = authority.grants;
        execution_ctx.session_grants = authority.grants;
        execution_ctx.permission_rules = authority.rules;
        execution_ctx.sandbox_backend = authority.sandbox_backend;
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
    if (request.route) |route| {
        execution_ctx.route = route;
        execution_ctx.provider_adapter = request.provider_adapter orelse
            return error.MissingRouteAdapter;
        execution_ctx.api_key = request.route_credential;
        execution_ctx.gateway_team = request.route_tenant;
        execution_ctx.gateway_chat_url = route.endpoint;
        execution_ctx.model = route.primary_model_id;
    }
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
        if (request.isSandboxWideningRetryCancellationError(err)) return err;
        diagnostics.recordToolCallResult(.{
            .name = request.call.name,
            .arguments_json = request.call.arguments_json,
            .model_output = "",
            .ok = false,
            .started_at_ms = started_at_ms,
        });
        return if (err == error.CancelledBeforeExecution) error.Cancelled else err;
    };
    if (!request.resultAwaitsSandboxWidening(result)) {
        const ok = switch (result.status) {
            .success => true,
            else => false,
        };
        diagnostics.recordToolCallResult(.{
            .name = request.call.name,
            .arguments_json = request.call.arguments_json,
            .model_output = result.model_output,
            .ok = ok,
            .started_at_ms = started_at_ms,
        });
    }
    if (request.command_replay_capture) |continued| {
        replay_continuation_transferred = result.command_replay_capture == continued or
            (result.sandbox_scope_required != null and
                result.sandbox_scope_required.?.command_replay_capture == continued);
    }
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
        !std.mem.eql(u8, spec.name, "terminal") or
        spec.executor_kind != .run_command or
        spec.runtime_provider != .run_command)
    {
        return semanticFailure(try std.fmt.allocPrint(arena, "Unsupported tool: {s}", .{call.name}));
    }

    var command_backend = RunCommandBackendState{ .runtime = ctx };
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
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
    );
    if (command_backend.execution_error) |err| {
        dispatched.deinit(arena);
        return err;
    }
    var execution = command_backend.completion orelse
        toolExecutionResultFromDispatch(dispatched);
    execution.model_output = dispatched.body;
    if (dispatched.status_detail) |detail| execution.status_detail = detail;
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
    var dispatch_ctx = typedDispatchContextForCall(ctx, arena, call);
    dispatch_ctx.execution_authority = authority;
    dispatch_ctx.mcp_call_options = .{
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
        return err;
    }

    var execution = if (command_backend.completion) |completion|
        completion
    else if (vision_provider.completion) |completion|
        completion
    else
        toolExecutionResultFromDispatch(dispatched);
    execution.model_output = dispatched.body;
    if (dispatched.status_detail) |detail| execution.status_detail = detail;
    if (mcp_call_status == .input_required or
        (execution.status == .failure and
            tool_mcp_feature_dispatch.isInputRequiredFailure(execution.model_output)))
    {
        execution.finish_turn = true;
        execution.status_detail = "McpInputRequired";
    }
    execution.selected_dynamic_tool = selected_dynamic_tool_sink.descriptor;
    execution.context_notices = context_notice_sink.notices.items;
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

fn toolExecutionResultFromDispatch(result: tool_dispatch.DispatchResult) ToolExecutionResult {
    return switch (result.status) {
        .success => .{
            .model_output = result.body,
            .status_detail = result.status_detail,
            .inner_usage = result.inner_usage,
            .web_search_completion = result.web_search_completion,
            .web_fetch_completion = result.web_fetch_completion,
            .tool_result_memory = result.tool_result_memory,
        },
        .failure => .{
            .status = .failure,
            .model_output = result.body,
            .status_detail = result.status_detail,
            .inner_usage = result.inner_usage,
            .web_search_completion = result.web_search_completion,
            .web_fetch_completion = result.web_fetch_completion,
            .tool_result_memory = result.tool_result_memory,
        },
    };
}

const SelectedDynamicToolSinkState = struct {
    allocator: Allocator,
    descriptor: ?gateway_schema.FunctionSchema = null,
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
    description: []const u8,
    input_schema_json: []const u8,
) tool_dispatch.DispatchError!void {
    const state_ptr = raw_ctx orelse return;
    const state: *SelectedDynamicToolSinkState = @ptrCast(@alignCast(state_ptr));
    const owned_name = try state.allocator.dupe(u8, name);
    const owned_description = try state.allocator.dupe(u8, description);
    const input_schema = std.json.parseFromSliceLeaky(
        std.json.Value,
        state.allocator,
        input_schema_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolArguments,
    };
    const descriptor: gateway_schema.FunctionSchema = .{
        .name = owned_name,
        .description = owned_description,
        .dynamic_input_schema = input_schema,
    };
    descriptor.validate() catch return error.InvalidToolArguments;
    state.descriptor = descriptor;
}

fn typedDispatchContext(ctx: Context, arena: Allocator) tool_dispatch.DispatchContext {
    var capabilities = tool_dispatch.ToolCapabilities.for_host(
        host_capabilities.current(),
    );
    capabilities.web_search_runtime_ready =
        ctx.web_search_runtime_ready and ctx.web_search_backend != null and
        ctx.provider_adapter.web_search != null;
    // Availability preflight has no route; invocation still requires an exact match.
    const web_search_route_compatible = if (ctx.route) |route|
        ctx.provider_adapter.acceptsRoute(route)
    else
        true;
    const web_search_invocation: ?tool_dispatch.WebSearchInvocation = if (ctx.route) |route|
        if (ctx.provider_adapter.acceptsRoute(route))
            if (ctx.provider_adapter.web_search) |provider| .{
                .provider = provider,
                .inputs = .{
                    .connection_id = route.connection_id,
                    .credential = ctx.api_key,
                    .tenant = ctx.gateway_team,
                    .model = route.primary_model_id,
                    .retry_count = ctx.gateway_retry_count,
                    .endpoint = route.endpoint,
                    .usage = &ctx.session.usage,
                    .usage_allocator = ctx.session_allocator,
                },
            } else null
        else
            null
    else
        null;
    capabilities.web_search_runtime_ready =
        capabilities.web_search_runtime_ready and web_search_route_compatible;
    return .{
        .allocator = arena,
        .permission_mode = ctx.permission_mode,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.access_scope,
        .change_tracker = ctx.tracker,
        .skills_dir = ctx.skills_dir,
        .context_limits = ctx.context_limits,
        .ignored_list_entries = ctx.ignored_list_entries,
        .max_list_entries = ctx.max_list_entries,
        .max_read_file_bytes = ctx.max_read_file_bytes,
        .max_read_file_lines = ctx.max_read_file_lines,
        .max_read_file_line_len = ctx.max_read_file_line_len,
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
        .tool_result_dir = ctx.tool_result_dir,
        .session_child_capability = ctx.session_child_capability,
        .terminal_client = ctx.terminal_client,
        .terminal_owner_session_id = ctx.lifecycle_scope.session_id,
        .terminal_transport_role = switch (ctx.lifecycle_scope.kind) {
            .interactive, .subagent => .interactive,
            .ask => .headless,
            .acp => .acp,
        },
        .background_lifecycle_allocator = ctx.session_allocator,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .command_timeout_ms = ctx.command_timeout_ms,
        .sandbox_backend = ctx.sandbox_backend,
        .devbox_provider = ctx.devbox_provider,
        .ask_question_ctx = if (ctx.interactive) ctx.worker else null,
        .ask_question_batch = if (ctx.interactive) requestQuestionBatchWithWorker else null,
        .web_fetch_runtime = ctx.web_fetch_runtime,
        .web_fetch_artifact_store = ctx.web_fetch_artifact_store,
        .web_fetch_artifact_error = ctx.web_fetch_artifact_error,
        .tool_capabilities = capabilities,
        .web_search_backend = ctx.web_search_backend,
        .web_search_invocation = web_search_invocation,
        .web_search_progress_ctx = ctx.web_search_progress_ctx,
        .on_web_search_progress = ctx.on_web_search_progress,
        .web_fetch_progress_ctx = ctx.web_fetch_progress_ctx,
        .on_web_fetch_progress = ctx.on_web_fetch_progress,
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
    return dispatch;
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
    const route = state.runtime.route orelse return visionRouteUnavailable(alloc);
    const config: vision_executor.Config = .{
        .adapter = state.runtime.provider_adapter,
        .route = route,
        .credential = state.runtime.api_key,
        .tenant = state.runtime.gateway_team,
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

fn visionRouteUnavailable(alloc: Allocator) Allocator.Error!ToolExecutionResult {
    return .{
        .status = .failure,
        .status_detail = "the parent turn has no admitted Vision route",
        .model_output = try alloc.dupe(
            u8,
            "Vision is unavailable because the parent turn has no admitted Vision route.",
        ),
        .system_notice = "Vision is unavailable on the pinned parent route.",
        .interactive_notice = .{
            .topic = "vision",
            .tone = .@"error",
            .body = "The selected connection and model do not provide Vision for this turn.",
        },
    };
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

fn visionPathPreparationFailure(
    alloc: Allocator,
    err: anyerror,
) !ToolExecutionResult {
    return switch (err) {
        error.OutOfMemory, error.Cancelled => err,
        else => visionPathFailure(alloc, err),
    };
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
        .tool_schema = ctx.mcp_tool_schema,
        .access = ctx.mcp_access,
    };
}

pub fn withAdvertisedDynamicToolNames(ctx: Context, advertised_dynamic_tool_names: []const []const u8) Context {
    var copy = ctx;
    copy.advertised_dynamic_tool_names = advertised_dynamic_tool_names;
    return copy;
}

fn toolRunCommand(
    ctx: Context,
    arena: Allocator,
    request: tool_dispatch.RunCommandRequest,
    authority: command_admission.CommandExecutionAuthority,
) !ToolExecutionResult {
    const command = request.command;
    const cwd = request.resolved_cwd;
    const resolved_backend = sandbox.resolveBackend(ctx.sandbox_backend);
    const authority_scope = commandAuthorityFingerprint(authority).scope;
    const needs_preflight_widening = authority_scope == .restricted and
        resolved_backend == .macos and
        sandbox.needsBroaderFileAccess(command);
    const command_ctx = command_admission.CommandContext{
        .command = command,
        .resolved_cwd = cwd,
        .background = false,
        .resolved_backend = resolved_backend,
        .target_os = builtin.os.tag,
        .environment = request.environment,
        .scope = authority_scope,
    };
    const timeout_started_ms = ctx.command_timeout_started_ms orelse
        if (ctx.command_timeout_ms != null) io_mod.milliTimestamp() else null;

    if (comptime builtin.os.tag == .wasi or builtin.is_test) {
        if (ctx.workspace_executor) |executor| {
            return executeWorkspaceRunCommand(
                arena,
                request,
                command_ctx,
                authority,
                executor,
                ctx.command_timeout_ms,
            );
        }
    }
    if (comptime builtin.os.tag == .wasi) return error.WorkspaceUnavailable;

    try execution_router.validateConfigContext(.{
        .backend = ctx.sandbox_backend,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.access_scope,
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
        const intercepted_replay = initCommandReplayCapture(
            arena,
            ctx.interactive,
            ctx.max_command_output_bytes,
            ctx.max_command_output_bytes,
            ctx.session_child_capability,
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
        };
        if (compatibility == .success and ctx.interactive and output.len > 0) {
            try callback.accept(
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            );
            try ctx.on_output_chunk(
                ctx.output_chunk_ctx,
                ctx.output_chunk_lifecycle_id,
                .stdout,
                output,
            );
        }
        return finishCommandToolResult(
            capture,
            intercepted_replay.unavailable and
                (ctx.command_replay_unavailable or callback.had_accepted_output),
            &transferred,
            null,
            .{
                .status = switch (compatibility) {
                    .success => .success,
                    .failure => .failure,
                },
                .model_output = output,
            },
        );
    }

    if (route == .approved_shell and needs_preflight_widening) {
        return sandboxScopeRequiredPreflight(
            arena,
            authority,
            timeout_started_ms,
        );
    }
    const use_permissive = authority_scope == .broader;

    const replay_init = initCommandReplayCapture(
        arena,
        ctx.interactive,
        ctx.max_command_output_bytes,
        execution_router.foregroundResultComparisonLimit(
            route,
            ctx.max_command_output_bytes,
        ),
        ctx.session_child_capability,
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
        .backend = ctx.sandbox_backend,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.access_scope,
        .max_command_output_bytes = ctx.max_command_output_bytes,
        .cancel_flag = runtimeCancelFlag(ctx),
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .accepted_output_chunk_ctx = if (ctx.interactive) @ptrCast(&replay_callback) else null,
        .on_accepted_output_chunk = if (ctx.interactive) CommandReplayCaptureCallback.onChunk else null,
        .callback_projection = if (ctx.interactive) .raw else .model_safe,
        .permissive = use_permissive,
        .timeout_ms = ctx.command_timeout_ms,
        .timeout_started_ms = timeout_started_ms,
        .devbox_provider = ctx.devbox_provider,
        .command_artifact_capability = ctx.session_child_capability,
        .command_artifact_dir = ctx.command_artifact_dir,
    }, arena, route) catch |err| {
        if (err == error.TimeoutExpired) return finishCommandToolResult(
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            null,
            try command_result_mapping.Foreground.timeoutFailure(
                arena,
                command,
                cwd,
                ctx.command_timeout_ms,
                timeout_started_ms,
            ),
        );
        return err;
    };
    const result = routed.result;

    if (try command_result_mapping.Foreground.cancelledFailure(arena, result)) |cancelled| {
        return cancelled;
    }

    if (routed.route == .approved_shell and
        authority_scope == .restricted and
        resolved_backend == .macos and
        sandbox.looksLikeSandboxError(result.output))
    {
        return finishCommandToolResult(
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            try sandboxScopeRequiredReactive(
                arena,
                authority,
                timeout_started_ms,
                result,
            ),
        );
    }

    if (try command_result_mapping.Foreground.nonZeroFailure(arena, result)) |failure| {
        return finishCommandToolResult(
            replay_capture,
            replay_init.unavailable and
                (ctx.command_replay_unavailable or replay_callback.had_accepted_output),
            &replay_transferred,
            result,
            failure,
        );
    }

    return finishCommandToolResult(
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
            return command_result_mapping.Foreground.timeoutFailure(
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
    if (try command_result_mapping.Foreground.cancelledFailure(arena, result)) |cancelled| {
        return finishCommandToolResult(
            null,
            false,
            &replay_transferred,
            result,
            cancelled,
        );
    }
    if (try command_result_mapping.Foreground.nonZeroFailure(arena, result)) |failure| {
        return finishCommandToolResult(
            null,
            false,
            &replay_transferred,
            result,
            failure,
        );
    }
    return finishCommandToolResult(
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

fn commandAuthorityFingerprint(
    authority: command_admission.CommandExecutionAuthority,
) command_admission.AdmissionFingerprint {
    return switch (authority) {
        .direct_only => |fingerprint| fingerprint,
        .shell_allowed => |allowed| allowed.fingerprint,
    };
}

fn dupedAdmittedFingerprint(
    arena: Allocator,
    authority: command_admission.CommandExecutionAuthority,
) !command_admission.AdmissionFingerprint {
    var admitted = commandAuthorityFingerprint(authority);
    admitted.command = try arena.dupe(u8, admitted.command);
    admitted.resolved_cwd = try arena.dupe(u8, admitted.resolved_cwd);
    admitted.environment = switch (admitted.environment) {
        .legacy => .legacy,
        .workspace_clean => .workspace_clean,
        .clean => |path| .{ .clean = try arena.dupe(u8, path) },
        .user => |path| .{ .user = try arena.dupe(u8, path) },
    };
    return admitted;
}

fn sandboxScopeRequiredPreflight(
    arena: Allocator,
    authority: command_admission.CommandExecutionAuthority,
    timeout_started_ms: ?i64,
) !ToolExecutionResult {
    return .{
        .status = .failure,
        .model_output = "",
        .sandbox_scope_required = .{
            .phase = .preflight,
            .restricted_fingerprint = try dupedAdmittedFingerprint(arena, authority),
            .command_timeout_started_ms = timeout_started_ms,
        },
    };
}

fn sandboxScopeRequiredReactive(
    arena: Allocator,
    authority: command_admission.CommandExecutionAuthority,
    timeout_started_ms: ?i64,
    result: command_contract.RunCommandResult,
) !ToolExecutionResult {
    const command_result_json = if (result.command_result) |command_result|
        try command_result.toJson(arena)
    else
        null;
    return .{
        .status = .failure,
        .model_output = result.output,
        .command_result_json = command_result_json,
        .sandbox_scope_required = .{
            .phase = .reactive,
            .restricted_fingerprint = try dupedAdmittedFingerprint(arena, authority),
            .command_timeout_started_ms = timeout_started_ms,
            .restricted_model_output = result.output,
            .restricted_command_result_json = command_result_json,
        },
    };
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
            capture.appendAccepted(self.alloc, stream, chunk);
        }
    }
};

const CommandReplayCaptureInit = struct {
    capture: ?*command_replay_store.Capture = null,
    unavailable: bool = false,
};

fn initCommandReplayCapture(
    arena: Allocator,
    interactive: bool,
    inline_limit: usize,
    comparison_limit: usize,
    capability: ?*session_child_store.SessionChildCapability,
    continued_capture: ?*command_replay_store.Capture,
    continued_unavailable: bool,
) CommandReplayCaptureInit {
    if (!interactive) return .{};
    if (continued_unavailable) return .{ .unavailable = true };
    if (continued_capture) |capture| {
        capture.setComparisonLimit(comparison_limit);
        return .{ .capture = capture };
    }
    const capture = command_replay_store.Capture.create(
        arena,
        inline_limit,
        capability,
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay capture initialization unavailable err={s}",
            .{@errorName(err)},
        );
        return .{ .unavailable = true };
    };
    capture.setComparisonLimit(comparison_limit);
    return .{ .capture = capture };
}

fn finishCommandToolResult(
    capture: ?*command_replay_store.Capture,
    replay_unavailable: bool,
    replay_transferred: *bool,
    process_result: ?command_contract.RunCommandResult,
    result: ToolExecutionResult,
) !ToolExecutionResult {
    var owned = result;
    if (process_result) |command_result| {
        if (commandProcessPresentation(command_result)) |presentation| {
            var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
            memory.command_process_presentation = presentation;
            owned.tool_result_memory = memory;
        }
    }
    if (owned.sandbox_scope_required) |*required| {
        required.command_replay_capture = capture;
        required.command_replay_unavailable = replay_unavailable;
    } else {
        if (replay_unavailable) {
            var memory = owned.tool_result_memory orelse types.ToolResultMemory{};
            memory.command_output_replay = .unavailable;
            owned.tool_result_memory = memory;
        }
        owned.command_replay_capture = capture;
    }
    if (capture != null) replay_transferred.* = true;
    return owned;
}

fn commandProcessPresentation(
    result: command_contract.RunCommandResult,
) ?types.CommandProcessPresentation {
    const command_result = result.command_result orelse return null;
    const foreground = switch (command_result) {
        .foreground => |value| value,
        .background => return null,
    };
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
    operation_id: []const u8,
    error_code: []const u8,
    retryable: bool,
) Allocator.Error!subagent_tool_provider.Result {
    const body = subagent_tool_result.failureAlloc(
        alloc,
        operation_id,
        null,
        "rejected",
        error_code,
        retryable,
        null,
    ) catch |err| return switch (err) {
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
    };
    return .{ .status = .failure, .body = body };
}

fn executeSubagentProvider(
    raw_context: ?*anyopaque,
    arena: Allocator,
    command: *subagent_domain.Command,
    invocation_id: []const u8,
) Allocator.Error!subagent_tool_provider.Result {
    const state: *SubagentProviderState = @ptrCast(@alignCast(raw_context.?));
    const ctx = state.runtime;
    const host = ctx.subagent_host orelse
        return subagentProviderFailure(arena, invocation_id, "host_unavailable", false);
    const caller_id = ctx.subagent_caller_id orelse
        return subagentProviderFailure(arena, invocation_id, "caller_unavailable", false);
    const permission_admitted = host.admitModelCommand(
        arena,
        command,
        caller_id,
        ctx.permission_mode,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return subagentProviderFailure(
            arena,
            invocation_id,
            "host_failure",
            true,
        );
    };
    if (!permission_admitted) {
        return subagentProviderFailure(
            arena,
            invocation_id,
            "permission_escalation",
            false,
        );
    }
    const identity_epoch = if (command.* == .inspect)
        0
    else switch (try persistedSubagentIdentity(
        arena,
        ctx.current_turn_messages,
        ctx.session.history.items,
        invocation_id,
    )) {
        .absent => host.issueOperationIdentity(
            arena,
            invocation_id,
            .model,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return try subagentProviderFailure(
                arena,
                invocation_id,
                "host_failure",
                true,
            );
        },
        .replay => |epoch| epoch,
        .corrupt => return subagentProviderFailure(
            arena,
            invocation_id,
            "host_failure",
            true,
        ),
    };
    const output = host.execute(arena, command, .{
        .caller_id = caller_id,
        .invocation_id = invocation_id,
        .parent_permission_mode = ctx.permission_mode,
        .root_user_intent_context = ctx.root_user_intent_context,
        .root_user_messages = ctx.root_user_messages,
        .root_user_evidence_complete = ctx.root_user_evidence_complete,
        .defaults = .{
            .model = if (ctx.route) |route| route.subagent_model_id else ctx.model,
            .route = ctx.route,
            .effort = ctx.effort,
            .fast_mode = ctx.fast_mode,
            .conversation_language = ctx.session.languageSnapshot(),
        },
        .max_result_bytes = ctx.max_tool_result_bytes,
        .timestamp_ms = io_mod.milliTimestamp(),
        .identity_epoch = identity_epoch,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const operation_id = if (command.* == .inspect)
            invocation_id
        else
            try subagent_tool_result.boundOperationIdAlloc(
                arena,
                invocation_id,
                .model,
                identity_epoch,
            );
        return subagentProviderFailure(arena, operation_id, "host_failure", true);
    };
    return .{
        .status = if (std.mem.find(u8, output, "\"ok\":false") == null)
            .success
        else
            .failure,
        .body = output,
    };
}

const PersistedSubagentIdentity = union(enum) {
    absent,
    replay: u64,
    corrupt,
};

fn persistedSubagentIdentity(
    arena: Allocator,
    current_turn_messages: []const ChatMessage,
    history: []const session_runtime.HistoryTurn,
    invocation_id: []const u8,
) !PersistedSubagentIdentity {
    switch (try currentTurnSubagentIdentity(
        arena,
        current_turn_messages,
        invocation_id,
    )) {
        .absent => {},
        .replay => |epoch| return .{ .replay = epoch },
        .corrupt => return .corrupt,
    }

    var turn_index = history.len;
    while (turn_index != 0) {
        turn_index -= 1;
        const execution = switch (history[turn_index]) {
            .assistant => |entry| entry.execution,
            .background_command => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => continue,
        };
        var step_index = execution.tool_steps.len;
        while (step_index != 0) {
            step_index -= 1;
            const step = execution.tool_steps[step_index];
            var call_index = step.tool_calls.len;
            while (call_index != 0) {
                call_index -= 1;
                const persisted_call = step.tool_calls[call_index];
                if (!std.mem.eql(u8, persisted_call.id, invocation_id)) continue;
                var matching_calls: usize = 0;
                for (step.tool_calls) |candidate| {
                    if (std.mem.eql(u8, candidate.id, invocation_id)) {
                        matching_calls += 1;
                    }
                }
                if (matching_calls != 1) return .corrupt;
                if (!canonicalSubagentCall(persisted_call)) return .corrupt;
                const result = canonicalPersistedSubagentResult(
                    step.tool_results,
                    invocation_id,
                ) orelse
                    return .corrupt;
                const epoch = try persistedSubagentEpoch(
                    arena,
                    result.output,
                    result.status,
                    invocation_id,
                ) orelse
                    return .corrupt;
                return .{ .replay = epoch };
            }
        }
    }
    return .absent;
}

fn currentTurnSubagentIdentity(
    arena: Allocator,
    messages: []const ChatMessage,
    invocation_id: []const u8,
) !PersistedSubagentIdentity {
    var result_index = messages.len;
    while (result_index != 0) {
        result_index -= 1;
        const result = messages[result_index];
        if (result.role != .tool) continue;
        const result_call_id = result.tool_call_id orelse continue;
        if (!std.mem.eql(u8, result_call_id, invocation_id)) continue;
        const call = canonicalCurrentTurnSubagentCall(
            messages,
            result_index,
            invocation_id,
        ) orelse return .corrupt;
        if (!canonicalSubagentCall(call) or
            result.tool_name == null or
            !std.mem.eql(u8, result.tool_name.?, subagent_tool_name) or
            result.content == null or
            result.tool_result_status == null or
            result.tool_calls.len != 0 or
            result.images.len != 0 or
            result.permission_feedback)
        {
            return .corrupt;
        }
        const epoch = try persistedSubagentEpoch(
            arena,
            result.content.?,
            result.tool_result_status.?,
            invocation_id,
        ) orelse return .corrupt;
        return .{ .replay = epoch };
    }
    return .absent;
}

fn canonicalCurrentTurnSubagentCall(
    messages: []const ChatMessage,
    result_index: usize,
    invocation_id: []const u8,
) ?ToolCall {
    var assistant_index = result_index;
    while (assistant_index != 0) {
        assistant_index -= 1;
        switch (messages[assistant_index].role) {
            .tool => continue,
            .assistant => break,
            .system, .user => return null,
        }
    }
    if (messages[assistant_index].role != .assistant) return null;

    var matching_call: ?ToolCall = null;
    for (messages[assistant_index].tool_calls) |call| {
        if (!std.mem.eql(u8, call.id, invocation_id)) continue;
        if (matching_call != null) return null;
        matching_call = call;
    }

    var matching_results: usize = 0;
    var index = assistant_index + 1;
    while (index < messages.len and messages[index].role == .tool) : (index += 1) {
        const call_id = messages[index].tool_call_id orelse continue;
        if (std.mem.eql(u8, call_id, invocation_id)) matching_results += 1;
    }
    if (matching_results != 1) return null;
    return matching_call;
}

fn canonicalSubagentCall(call: ToolCall) bool {
    return std.mem.eql(u8, call.name, subagent_tool_name) and
        call.argument_integrity == .valid and
        call.provider_result == null and
        call.final_identity == .valid and
        call.provenance == .fx_local;
}

fn canonicalPersistedSubagentResult(
    results: []const session_runtime.PersistedToolResult,
    call_id: []const u8,
) ?session_runtime.PersistedToolResult {
    var matching: ?session_runtime.PersistedToolResult = null;
    for (results) |result| {
        if (!std.mem.eql(u8, result.tool_call_id, call_id)) continue;
        if (matching != null or
            !std.mem.eql(u8, result.tool_name, subagent_tool_name) or
            result.provider_native)
        {
            return null;
        }
        matching = result;
    }
    return matching;
}

fn persistedSubagentEpoch(
    arena: Allocator,
    output: []const u8,
    status: session_runtime.PersistedToolStatus,
    invocation_id: []const u8,
) !?u64 {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, output, .{}) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const ok_value = parsed.value.object.get("ok") orelse return null;
    if (ok_value != .bool) return null;
    const expected_status: session_runtime.PersistedToolStatus =
        if (ok_value.bool) .success else .failure;
    if (status != expected_status) return null;
    const operation_value = parsed.value.object.get("operation_id") orelse
        return null;
    if (operation_value != .string) return null;
    const child_value = parsed.value.object.get("child_id") orelse return null;
    if (child_value != .null and child_value != .string) return null;
    const status_value = parsed.value.object.get("status") orelse return null;
    if (status_value != .string or status_value.string.len == 0) return null;
    const error_value = parsed.value.object.get("error_code") orelse return null;
    if (error_value != .null and error_value != .string) return null;
    const retryable_value = parsed.value.object.get("retryable") orelse
        return null;
    if (retryable_value != .bool) return null;
    const requested_value = parsed.value.object.get("requested") orelse
        return null;
    if (requested_value != .null and requested_value != .object) return null;
    const cursor_value = parsed.value.object.get("cursor") orelse return null;
    if (cursor_value != .null and cursor_value != .string) return null;
    const operation_id = operation_value.string;
    const identity = subagent_tool_result.parseBoundOperationId(operation_id) orelse
        return null;
    if (identity.source != .model or
        identity.authority != .manager or
        identity.epoch == 0 or
        !subagent_tool_result.boundOperationMatchesInvocation(
            operation_id,
            invocation_id,
            .model,
        ))
    {
        return null;
    }
    return identity.epoch;
}

fn splitConversationLanguage(language: session_runtime.ConversationLanguage) task_helpers.ConversationLanguage {
    return task_helpers.ConversationLanguage.fromSlice(language.view()) catch task_helpers.ConversationLanguage.default();
}

fn noopOutput(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_contract.CommandOutputStream, _: []const u8) !void {}
fn noopBackgroundReady(_: *anyopaque, _: u64, _: []const u8) void {}

const test_tool_registry = tool_dispatch.Registry{ .tools = &.{
    test_builtin_tools.list_files,
    test_builtin_tools.glob_files,
    test_builtin_tools.grep_files,
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.delete_file,
    test_builtin_tools.rename_file,
    test_builtin_tools.copy_file,
    test_builtin_tools.create_folder,
    test_builtin_tools.file_info,
    test_builtin_tools.memory,
    test_builtin_tools.semantic_search,
    test_builtin_tools.open_file,
    test_builtin_tools.web_fetch,
    test_builtin_tools.web_search,
    test_builtin_tools.terminal,
    test_builtin_tools.skill,
    test_builtin_tools.install_skill,
    test_builtin_tools.subagent,
    test_builtin_tools.mcp_search_tools,
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
        "terminal",
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
    test_builtin_tools.terminal,
    test_compatible_tool,
} };

const test_failing_compatibility_registry = tool_dispatch.Registry{ .tools = &.{
    test_builtin_tools.terminal,
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
    .{ .id = "test-review", .name = "terminal", .arguments_json = "{\"action\":\"exec\",\"command\":\"printf test\"}" },
};
const test_review_root_messages = [_][]const u8{"test root request"};

fn testReviewTurn() permission_auto_classifier.ReviewTurnContext {
    return .{
        .model = "openai/gpt-5",
        .pending_assistant = .{ .role = .assistant, .tool_calls = &test_review_calls },
        .target_call_id = "test-review",
        .origin = .root,
        .current_root_request = test_review_root_messages[0],
    };
}

const TestRuntime = struct {
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    worker: WorkerRuntime = .{},
    background: BackgroundRuntime = .{},
    session: SessionRuntime = .{ .max_history_turns = 8 },
    subagent_host: ?*subagent_tool_host.Runtime = null,
    subagent_caller_id: ?[]const u8 = null,
    model: []const u8 = "",
    session_allocator: Allocator = std.testing.allocator,
    workspace_root: []const u8 = "/tmp",
    ignored_list_entries: []const []const u8 = &.{},
    skills_dir: []const u8 = "",
    sandbox_backend: sandbox.BackendKind = .none,
    tracker: ?*change_tracker.ChangeTracker = null,
    permission_rules: types.PermissionRuleSet = .{},
    permission_grants: []const PermissionGrant = &.{},
    session_grants: []const PermissionGrant = &.{},
    cancel_flag: ?*std.atomic.Value(bool) = null,
    permission_mode: PermissionMode = .ask,
    max_command_output_bytes: usize = 64 * 1024,
    max_tool_result_bytes: usize = 64 * 1024,
    api_key: []const u8 = "",
    gateway_team: ?[]const u8 = null,
    gateway_retry_count: usize = 0,
    gateway_chat_url: []const u8 = "",
    route: route_snapshot.RouteSnapshot = .{
        .connection_id = "test-connection",
        .adapter_kind = "vercel_ai_gateway",
        .endpoint = "https://gateway.invalid/chat",
        .protocol = "vercel_ai_gateway",
        .credential_ref = "test",
        .primary_model_id = "google/gemini-2.5-flash",
        .permission_review_model_id = "openai/gpt-5.4",
        .vision_model_id = "google/gemini-2.5-flash",
        .subagent_model_id = "google/gemini-2.5-flash",
        .capabilities = .{
            .supports_tool_use = true,
            .supports_vision = true,
            .supports_file_input = true,
        },
        .capability_source = .configured,
        .selected_fast_mode = false,
        .fast_model_suffix = null,
    },
    context_limits: context_limits.Values = .{},
    command_artifact_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    command_timeout_ms: ?usize = null,
    interactive: bool = true,
    mcp_ctx: ?*anyopaque = null,
    mcp_has_tool: ?tool_mcp_runtime.HasToolFn = null,
    mcp_validate_tool: ?tool_mcp_runtime.ValidateToolFn = null,
    mcp_call_tool: ?tool_mcp_runtime.CallToolFn = null,
    mcp_search_tools: ?tool_mcp_runtime.SearchToolsFn = null,
    mcp_tool_schema: ?tool_mcp_runtime.ToolSchemaFn = null,
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
        self.background.deinit(alloc);
        self.session.deinit(alloc);
    }

    fn context(self: *TestRuntime) Context {
        var provider_adapter = test_builtin_gateway.provider_adapter;
        provider_adapter.legacy_provider = self.agent_stream_provider;
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
            .provider_adapter = provider_adapter,
            .route = &self.route,
            .agent_stream_provider = self.agent_stream_provider,
            .gateway_team = self.gateway_team,
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
            .background = &self.background,
            .session = &self.session,
            .session_allocator = self.session_allocator,
            .skills_dir = self.skills_dir,
            .context_registry = test_context_registry,
            .context_limits = self.context_limits,
            .output_chunk_ctx = undefined,
            .on_output_chunk = noopOutput,
            .background_url_ctx = undefined,
            .on_background_url_ready = noopBackgroundReady,
            .command_artifact_dir = self.command_artifact_dir,
            .session_child_capability = self.session_child_capability,
            .command_timeout_ms = self.command_timeout_ms,
            .sandbox_backend = self.sandbox_backend,
            .tracker = self.tracker,
            .mcp_ctx = self.mcp_ctx,
            .mcp_has_tool = self.mcp_has_tool,
            .mcp_validate_tool = self.mcp_validate_tool,
            .mcp_call_tool = self.mcp_call_tool,
            .mcp_search_tools = self.mcp_search_tools,
            .mcp_tool_schema = self.mcp_tool_schema,
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

fn subagentTestState(
    alloc: Allocator,
    id: []const u8,
    workspace: []const u8,
) !session_codec_mod.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, workspace);
    errdefer alloc.free(origin);
    const current = try alloc.dupe(u8, workspace);
    errdefer alloc.free(current);
    const model = try alloc.dupe(u8, "test/model");
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .preferences = .{ .model = model, .effort = types.ReasoningEffort.literal("high"), .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

const SubagentTestEnvironment = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    store: session_store.Store,

    fn init(alloc: Allocator) !SubagentTestEnvironment {
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

    fn deinit(self: *SubagentTestEnvironment, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn createSession(
        self: *SubagentTestEnvironment,
        alloc: Allocator,
        id: []const u8,
    ) !void {
        var state = try subagentTestState(alloc, id, self.workspace);
        defer state.deinit(alloc);
        var loaded = try self.store.startWritableSession(alloc, state);
        loaded.deinit(alloc);
    }
};

const SubagentTestAuthority = struct {
    root_id: []const u8,

    fn resolver(self: *SubagentTestAuthority) subagent_authority.HostResolver {
        return .{ .context = self, .resolve_fn = resolve };
    }

    fn resolve(
        raw: ?*anyopaque,
        alloc: Allocator,
        root_id: []const u8,
    ) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
        const self: *SubagentTestAuthority = @ptrCast(@alignCast(raw.?));
        if (!std.mem.eql(u8, self.root_id, root_id)) {
            return error.HostAuthorityUnavailable;
        }
        return subagent_tool_host.captureHostAuthority(
            alloc,
            .{
                .tool_set = .{
                    .registry = test_tool_registry,
                    .order = &.{},
                    .read_only_tool_names = &.{},
                },
                .mode = .full,
            },
            .none,
            &.{},
            .{},
            &.{},
        );
    }
};

fn subagentResultStringAlloc(
    alloc: Allocator,
    result_json: []const u8,
    field: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result_json, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.TestUnexpectedResult;
    if (value != .string) return error.TestUnexpectedResult;
    return alloc.dupe(u8, value.string);
}

fn persistSubagentToolResult(
    runtime: *TestRuntime,
    alloc: Allocator,
    call: ToolCall,
    result: ToolExecutionResult,
) !void {
    var calls = [_]ToolCall{call};
    var results = [_]session_runtime.PersistedToolResult{.{
        .tool_call_id = @constCast(call.id),
        .tool_name = @constCast(call.name),
        .status = switch (result.status) {
            .success => .success,
            .failure => .failure,
        },
        .output = @constCast(result.model_output),
        .output_bytes = result.model_output.len,
        .stored_output_bytes = result.model_output.len,
    }};
    var steps = [_]session_runtime.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const turn: session_runtime.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("test"), .images = &.{} },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = steps[0..] },
    } };
    try runtime.session.appendHistoryEntry(alloc, turn);
}

fn expectSingleSubagentCreateEffects(
    alloc: Allocator,
    env: *SubagentTestEnvironment,
    child_id: []const u8,
) !void {
    var child_ids = try env.store.listSubagentControlSessionIds(alloc);
    defer {
        for (child_ids.items) |id| alloc.free(id);
        child_ids.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 2), child_ids.items.len);

    var capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const control = subagent_control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var record = try control.load(alloc);
    defer record.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), record.operations.len);
    try std.testing.expectEqual(@as(usize, 1), record.events.len);
    try std.testing.expectEqual(@as(usize, 0), record.queue.len);

    const communications = subagent_communication_store.Store{
        .capability = &capability,
        .expected_session_id = child_id,
    };
    if (try communications.loadOptional(alloc)) |loaded| {
        var ledger = loaded;
        defer ledger.deinit(alloc);
        return error.TestUnexpectedCommunicationEffect;
    }

    var child = try env.store.loadReadOnly(alloc, child_id);
    defer child.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), child.history.len);
}

test "subagent production identity inspections leave no mutation reservations" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try SubagentTestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = SubagentTestAuthority{ .root_id = root_id };
    const host = try subagent_tool_host.Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    var runtime = TestRuntime{
        .workspace_root = env.workspace,
        .subagent_host = host,
        .subagent_caller_id = root_id,
        .model = "test/model",
    };
    defer runtime.deinit(alloc);

    var create_arena = std.heap.ArenaAllocator.init(alloc);
    defer create_arena.deinit();
    const created = try executeToolCall(runtime.context(), create_arena.allocator(), .{
        .id = "inspect-fixture-create",
        .name = "subagent",
        .arguments_json =
        \\{"command":{"create":{"name":"inspect-fixture","mode":"persistent"}}}
        ,
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, created.status);
    const child_id = try subagentResultStringAlloc(alloc, created.model_output, "child_id");
    defer alloc.free(child_id);

    const inspect_args = try std.fmt.allocPrint(
        alloc,
        "{{\"command\":{{\"inspect\":{{\"id\":\"{s}\",\"sections\":[\"status\"]}}}}}}",
        .{child_id},
    );
    defer alloc.free(inspect_args);
    for (0..3) |index| {
        var invocation_buffer: [64]u8 = undefined;
        const invocation_id = try std.fmt.bufPrint(
            &invocation_buffer,
            "inspect-{d}",
            .{index},
        );
        var inspect_arena = std.heap.ArenaAllocator.init(alloc);
        defer inspect_arena.deinit();
        const inspected = try executeToolCall(
            runtime.context(),
            inspect_arena.allocator(),
            .{
                .id = invocation_id,
                .name = "subagent",
                .arguments_json = inspect_args,
            },
        );
        try std.testing.expectEqual(
            tool_contracts.ToolExecutionStatus.success,
            inspected.status,
        );
    }

    const configure_args = try std.fmt.allocPrint(
        alloc,
        "{{\"command\":{{\"configure\":{{\"id\":\"{s}\",\"name\":\"renamed\"}}}}}}",
        .{child_id},
    );
    defer alloc.free(configure_args);
    var configure_arena = std.heap.ArenaAllocator.init(alloc);
    defer configure_arena.deinit();
    const configured = try executeToolCall(
        runtime.context(),
        configure_arena.allocator(),
        .{
            .id = "mutation-after-inspections",
            .name = "subagent",
            .arguments_json = configure_args,
        },
    );
    try std.testing.expectEqual(
        tool_contracts.ToolExecutionStatus.success,
        configured.status,
    );

    var root_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        root_id,
        .{},
    );
    defer root_capability.deinit();
    const identity_store = subagent_create_store.Store{
        .capability = &root_capability,
        .expected_root_id = root_id,
    };
    var identities = (try identity_store.loadOptional(alloc)).?;
    defer identities.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        identities.outstanding_operations.len,
    );
}

test "subagent production stable failures leave no mutation reservations" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    var env = try SubagentTestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = SubagentTestAuthority{ .root_id = root_id };
    const host = try subagent_tool_host.Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    var runtime = TestRuntime{
        .workspace_root = env.workspace,
        .subagent_host = host,
        .subagent_caller_id = root_id,
        .model = "test/model",
    };
    defer runtime.deinit(alloc);

    var create_arena = std.heap.ArenaAllocator.init(alloc);
    defer create_arena.deinit();
    const created = try executeToolCall(runtime.context(), create_arena.allocator(), .{
        .id = "stable-failure-fixture-create",
        .name = "subagent",
        .arguments_json =
        \\{"command":{"create":{"name":"stable-failure-fixture","mode":"persistent"}}}
        ,
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, created.status);
    const child_id = try subagentResultStringAlloc(alloc, created.model_output, "child_id");
    defer alloc.free(child_id);

    const missing_args =
        \\{"command":{"configure":{"id":"01J00000000000000000009999","name":"never applied"}}}
    ;
    for (0..3) |index| {
        var invocation_buffer: [64]u8 = undefined;
        const invocation_id = try std.fmt.bufPrint(
            &invocation_buffer,
            "stable-model-failure-{d}",
            .{index},
        );
        var failure_arena = std.heap.ArenaAllocator.init(alloc);
        defer failure_arena.deinit();
        const rejected = try executeToolCall(
            runtime.context(),
            failure_arena.allocator(),
            .{
                .id = invocation_id,
                .name = "subagent",
                .arguments_json = missing_args,
            },
        );
        try std.testing.expectEqual(
            tool_contracts.ToolExecutionStatus.failure,
            rejected.status,
        );
        try expectContains(
            rejected.model_output,
            "\"error_code\":\"child_unavailable\"",
        );
    }

    const configure_args = try std.fmt.allocPrint(
        alloc,
        "{{\"command\":{{\"configure\":{{\"id\":\"{s}\",\"name\":\"still writable\"}}}}}}",
        .{child_id},
    );
    defer alloc.free(configure_args);
    var configure_arena = std.heap.ArenaAllocator.init(alloc);
    defer configure_arena.deinit();
    const configured = try executeToolCall(
        runtime.context(),
        configure_arena.allocator(),
        .{
            .id = "model-mutation-after-stable-failures",
            .name = "subagent",
            .arguments_json = configure_args,
        },
    );
    try std.testing.expectEqual(
        tool_contracts.ToolExecutionStatus.success,
        configured.status,
    );

    var root_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        root_id,
        .{},
    );
    defer root_capability.deinit();
    const identity_store = subagent_create_store.Store{
        .capability = &root_capability,
        .expected_root_id = root_id,
    };
    var identities = (try identity_store.loadOptional(alloc)).?;
    defer identities.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        identities.outstanding_operations.len,
    );
}

const SubagentAgentLoopExecutor = struct {
    runtime: *TestRuntime,

    fn execute(
        raw: *anyopaque,
        request: tool_contracts.ToolExecutionRequest,
    ) !ToolExecutionResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return executeToolCallAuthorized(self.runtime.context(), request);
    }
};

test "subagent production identity replays one invocation within an active agent turn" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    const invocation_id = "production-active-turn-replay";
    const create_args =
        \\{"command":{"create":{"name":"active-turn-worker","mode":"persistent"}}}
    ;
    const changed_args =
        \\{"command":{"create":{"name":"changed-active-turn-worker","mode":"persistent"}}}
    ;
    var repeated_calls = [_]ToolCall{.{
        .id = invocation_id,
        .name = "subagent",
        .arguments_json = create_args,
    }};
    var changed_calls = [_]ToolCall{.{
        .id = invocation_id,
        .name = "subagent",
        .arguments_json = changed_args,
    }};
    const completions = [_]agent_test_support.FakeCompletion{
        .{ .tool_calls = repeated_calls[0..] },
        .{ .tool_calls = repeated_calls[0..] },
        .{ .tool_calls = changed_calls[0..] },
        .{ .content = "active turn complete" },
    };

    var env = try SubagentTestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = SubagentTestAuthority{ .root_id = root_id };
    const host = try subagent_tool_host.Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    var runtime = TestRuntime{
        .workspace_root = env.workspace,
        .subagent_host = host,
        .subagent_caller_id = root_id,
        .model = "test/model",
    };
    defer runtime.deinit(alloc);
    var executor = SubagentAgentLoopExecutor{ .runtime = &runtime };
    var test_deps = agent_test_support.FakeAgentRuntimeDeps.init(alloc);
    defer test_deps.deinit();
    test_deps.tool_execution_override = .{
        .context = &executor,
        .execute_fn = SubagentAgentLoopExecutor.execute,
    };
    var gateway = agent_test_support.FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var fixture = agent_test_support.PromptFixture{
        .workspace_root = env.workspace,
    };
    var config = fixture.config();
    config.agent_step_limit = completions.len;
    try agent_test_support.runFakePrompt(
        &gateway,
        &test_deps,
        config,
        fixture.job(),
    );

    try std.testing.expectEqual(completions.len, gateway.index);
    try std.testing.expectEqual(@as(usize, 1), test_deps.history_turns.items.len);
    const history = test_deps.history_turns.items[0].assistant;
    try std.testing.expectEqual(
        @as(usize, 3),
        history.execution.tool_steps.len,
    );
    const first = history.execution.tool_steps[0].tool_results[0];
    const replay = history.execution.tool_steps[1].tool_results[0];
    const conflict = history.execution.tool_steps[2].tool_results[0];
    try std.testing.expectEqualStrings(first.output, replay.output);
    try std.testing.expectEqual(
        session_runtime.PersistedToolStatus.success,
        first.status,
    );
    try std.testing.expectEqual(
        session_runtime.PersistedToolStatus.success,
        replay.status,
    );
    try std.testing.expectEqual(
        session_runtime.PersistedToolStatus.failure,
        conflict.status,
    );
    try expectContains(
        conflict.output,
        "\"error_code\":\"operation_conflict\"",
    );
    const first_operation_id = try subagentResultStringAlloc(
        alloc,
        first.output,
        "operation_id",
    );
    defer alloc.free(first_operation_id);
    const replay_operation_id = try subagentResultStringAlloc(
        alloc,
        replay.output,
        "operation_id",
    );
    defer alloc.free(replay_operation_id);
    try std.testing.expectEqualStrings(
        first_operation_id,
        replay_operation_id,
    );
    const child_id = try subagentResultStringAlloc(
        alloc,
        first.output,
        "child_id",
    );
    defer alloc.free(child_id);
    try expectSingleSubagentCreateEffects(
        alloc,
        &env,
        child_id,
    );
    var root_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        root_id,
        .{},
    );
    defer root_capability.deinit();
    const identity_store = subagent_create_store.Store{
        .capability = &root_capability,
        .expected_root_id = root_id,
    };
    var identities = (try identity_store.loadOptional(alloc)).?;
    defer identities.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), identities.entries.len);
    try std.testing.expectEqual(
        @as(usize, 0),
        identities.outstanding_operations.len,
    );
}

test "subagent production identity rejects malformed active-turn evidence before effects" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    const invocation_id = "production-active-turn-corrupt";
    const create_args =
        \\{"command":{"create":{"name":"must-not-exist","mode":"persistent"}}}
    ;
    var calls = [_]ToolCall{.{
        .id = invocation_id,
        .name = "subagent",
        .arguments_json = create_args,
    }};
    const malformed_output =
        \\{"ok":true,"operation_id":"production-active-turn-corrupt","child_id":null,"status":"created","error_code":null,"retryable":false,"requested":null,"cursor":null}
    ;
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{
            .role = .tool,
            .content = malformed_output,
            .tool_call_id = invocation_id,
            .tool_name = "subagent",
            .tool_result_status = .success,
        },
    };

    var env = try SubagentTestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = SubagentTestAuthority{ .root_id = root_id };
    const host = try subagent_tool_host.Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer host.deinit();
    var runtime = TestRuntime{
        .workspace_root = env.workspace,
        .subagent_host = host,
        .subagent_caller_id = root_id,
        .model = "test/model",
    };
    defer runtime.deinit(alloc);
    var ctx = runtime.context();
    ctx.current_turn_messages = &messages;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try executeToolCall(ctx, arena_state.allocator(), calls[0]);
    try std.testing.expectEqual(
        tool_contracts.ToolExecutionStatus.failure,
        result.status,
    );
    try expectContains(result.model_output, "\"error_code\":\"host_failure\"");

    var session_ids = try env.store.listSubagentControlSessionIds(alloc);
    defer {
        for (session_ids.items) |id| alloc.free(id);
        session_ids.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), session_ids.items.len);
    var root_capability = try env.store.openSubagentControlCapabilityReadOnly(
        alloc,
        root_id,
        .{},
    );
    defer root_capability.deinit();
    const identity_store = subagent_create_store.Store{
        .capability = &root_capability,
        .expected_root_id = root_id,
    };
    try std.testing.expect((try identity_store.loadOptional(alloc)) == null);
}

test "subagent identity evidence prefers canonical active-turn results and authenticates bindings" {
    const alloc = std.testing.allocator;
    const invocation_id = "active-turn-identity-evidence";
    const current_operation_id = try subagent_tool_result.boundOperationIdAlloc(
        alloc,
        invocation_id,
        .model,
        7,
    );
    defer alloc.free(current_operation_id);
    const history_operation_id = try subagent_tool_result.boundOperationIdAlloc(
        alloc,
        invocation_id,
        .model,
        3,
    );
    defer alloc.free(history_operation_id);
    const current_output = try subagent_tool_result.outcomeAlloc(alloc, .{
        .ok = true,
        .operation_id = current_operation_id,
        .child_id = "current-child",
        .status = "created",
        .error_code = null,
        .retryable = false,
        .requested_json = "null",
        .cursor = null,
    });
    defer alloc.free(current_output);
    const history_output = try subagent_tool_result.outcomeAlloc(alloc, .{
        .ok = true,
        .operation_id = history_operation_id,
        .child_id = "history-child",
        .status = "created",
        .error_code = null,
        .retryable = false,
        .requested_json = "null",
        .cursor = null,
    });
    defer alloc.free(history_output);
    var current_calls = [_]ToolCall{.{
        .id = invocation_id,
        .name = "subagent",
        .arguments_json = "{}",
    }};
    var current_messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = current_calls[0..] },
        .{
            .role = .tool,
            .content = current_output,
            .tool_call_id = invocation_id,
            .tool_name = "subagent",
            .tool_result_status = .success,
        },
    };
    var history_calls = [_]ToolCall{current_calls[0]};
    var history_results = [_]session_runtime.PersistedToolResult{.{
        .tool_call_id = @constCast(invocation_id),
        .tool_name = @constCast("subagent"),
        .status = .success,
        .output = history_output,
        .output_bytes = history_output.len,
        .stored_output_bytes = history_output.len,
    }};
    var history_steps = [_]session_runtime.ToolExecutionStep{.{
        .tool_calls = history_calls[0..],
        .tool_results = history_results[0..],
    }};
    const history = [_]session_runtime.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("test") },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = history_steps[0..] },
    } }};

    switch (try persistedSubagentIdentity(
        alloc,
        &current_messages,
        &history,
        invocation_id,
    )) {
        .replay => |epoch| try std.testing.expectEqual(@as(u64, 7), epoch),
        .absent, .corrupt => return error.TestUnexpectedResult,
    }

    const human_operation_id = try subagent_tool_result.boundOperationIdAlloc(
        alloc,
        invocation_id,
        .human,
        7,
    );
    defer alloc.free(human_operation_id);
    const wrong_digest_id = try subagent_tool_result.boundOperationIdAlloc(
        alloc,
        "different-invocation",
        .model,
        7,
    );
    defer alloc.free(wrong_digest_id);
    const zero_epoch_id = try subagent_tool_result.boundOperationIdAlloc(
        alloc,
        invocation_id,
        .model,
        0,
    );
    defer alloc.free(zero_epoch_id);
    const process_local_id = try std.fmt.allocPrint(
        alloc,
        "fxop:{s}",
        .{current_operation_id["fxop:2:".len..]},
    );
    defer alloc.free(process_local_id);
    const invalid_operation_ids = [_][]const u8{
        human_operation_id,
        wrong_digest_id,
        zero_epoch_id,
        process_local_id,
    };
    for (invalid_operation_ids) |operation_id| {
        const invalid_output = try subagent_tool_result.outcomeAlloc(alloc, .{
            .ok = true,
            .operation_id = operation_id,
            .child_id = "invalid-child",
            .status = "created",
            .error_code = null,
            .retryable = false,
            .requested_json = "null",
            .cursor = null,
        });
        defer alloc.free(invalid_output);
        current_messages[1].content = invalid_output;
        switch (try persistedSubagentIdentity(
            alloc,
            &current_messages,
            &history,
            invocation_id,
        )) {
            .corrupt => {},
            .absent, .replay => return error.TestUnexpectedResult,
        }
    }

    const invalid_requested_output = try subagent_tool_result.outcomeAlloc(alloc, .{
        .ok = true,
        .operation_id = current_operation_id,
        .child_id = "invalid-child",
        .status = "created",
        .error_code = null,
        .retryable = false,
        .requested_json = "\"invalid\"",
        .cursor = null,
    });
    defer alloc.free(invalid_requested_output);
    current_messages[1].content = invalid_requested_output;
    switch (try persistedSubagentIdentity(
        alloc,
        &current_messages,
        &history,
        invocation_id,
    )) {
        .corrupt => {},
        .absent, .replay => return error.TestUnexpectedResult,
    }

    current_messages[1].content = current_output;
    current_calls[0].provenance = .provider_executed;
    switch (try persistedSubagentIdentity(
        alloc,
        &current_messages,
        &history,
        invocation_id,
    )) {
        .corrupt => {},
        .absent, .replay => return error.TestUnexpectedResult,
    }
}

test "subagent production identity replays persisted invocation across restart without effects" {
    const alloc = std.testing.allocator;
    const root_id = "01J00000000000000000000000";
    const invocation_id = "production-adapter-replay";
    const create_args =
        \\{"command":{"create":{"name":"replayed-worker","mode":"persistent"}}}
    ;
    const call = ToolCall{
        .id = invocation_id,
        .name = "subagent",
        .arguments_json = create_args,
    };
    var env = try SubagentTestEnvironment.init(alloc);
    defer env.deinit(alloc);
    try env.createSession(alloc, root_id);
    var test_authority = SubagentTestAuthority{ .root_id = root_id };
    var first_output: []u8 = undefined;
    var child_id: []u8 = undefined;
    var history: []session_runtime.HistoryTurn = undefined;
    {
        const host = try subagent_tool_host.Runtime.create(
            alloc,
            &env.store,
            root_id,
            test_authority.resolver(),
            .{},
        );
        defer host.deinit();
        var runtime = TestRuntime{
            .workspace_root = env.workspace,
            .subagent_host = host,
            .subagent_caller_id = root_id,
            .model = "test/model",
        };
        defer runtime.deinit(alloc);

        var first_arena = std.heap.ArenaAllocator.init(alloc);
        defer first_arena.deinit();
        const first = try executeToolCall(
            runtime.context(),
            first_arena.allocator(),
            call,
        );
        try std.testing.expectEqual(
            tool_contracts.ToolExecutionStatus.success,
            first.status,
        );
        first_output = try alloc.dupe(u8, first.model_output);
        errdefer alloc.free(first_output);
        child_id = try subagentResultStringAlloc(alloc, first.model_output, "child_id");
        errdefer alloc.free(child_id);
        try persistSubagentToolResult(&runtime, alloc, call, first);

        var replay_arena = std.heap.ArenaAllocator.init(alloc);
        defer replay_arena.deinit();
        const replay = try executeToolCall(
            runtime.context(),
            replay_arena.allocator(),
            call,
        );
        try std.testing.expectEqualStrings(first_output, replay.model_output);
        try expectSingleSubagentCreateEffects(alloc, &env, child_id);
        history = try runtime.session.snapshotHistory(alloc);
    }
    defer alloc.free(first_output);
    defer alloc.free(child_id);
    defer session_runtime.freeHistoryTurnSlice(alloc, history);

    const restarted_host = try subagent_tool_host.Runtime.create(
        alloc,
        &env.store,
        root_id,
        test_authority.resolver(),
        .{},
    );
    defer restarted_host.deinit();
    var resumed = TestRuntime{
        .workspace_root = env.workspace,
        .subagent_host = restarted_host,
        .subagent_caller_id = root_id,
        .model = "test/model",
    };
    defer resumed.deinit(alloc);
    try resumed.session.restore(
        alloc,
        session_runtime.ConversationLanguage.literal("en"),
        history,
    );

    var resumed_arena = std.heap.ArenaAllocator.init(alloc);
    defer resumed_arena.deinit();
    const durable_replay = try executeToolCall(
        resumed.context(),
        resumed_arena.allocator(),
        call,
    );
    try std.testing.expectEqualStrings(first_output, durable_replay.model_output);
    try expectSingleSubagentCreateEffects(alloc, &env, child_id);

    var conflict_arena = std.heap.ArenaAllocator.init(alloc);
    defer conflict_arena.deinit();
    const conflict = try executeToolCall(
        resumed.context(),
        conflict_arena.allocator(),
        .{
            .id = invocation_id,
            .name = "subagent",
            .arguments_json =
            \\{"command":{"create":{"name":"different-worker","mode":"persistent"}}}
            ,
        },
    );
    try expectContains(conflict.model_output, "\"error_code\":\"operation_conflict\"");
    try expectSingleSubagentCreateEffects(alloc, &env, child_id);

    {
        var capability = try env.store.openSubagentControlCapabilityWritable(
            alloc,
            root_id,
            .{},
        );
        defer capability.deinit();
        const store = subagent_create_store.Store{
            .capability = &capability,
            .expected_root_id = root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)).?;
        defer record.deinit(alloc);
        const operation_id = try subagentResultStringAlloc(
            alloc,
            first_output,
            "operation_id",
        );
        defer alloc.free(operation_id);
        const identity = subagent_tool_result.parseBoundOperationId(operation_id).?;
        for (record.entries) |entry| {
            alloc.free(entry.operation_id);
            alloc.free(entry.child_id);
        }
        alloc.free(record.entries);
        record.entries = try alloc.alloc(subagent_create_store.Entry, 0);
        record.model_replay_floor = identity.epoch +| 1;
        try store.save(alloc, record);
    }

    var expired_arena = std.heap.ArenaAllocator.init(alloc);
    defer expired_arena.deinit();
    const expired = try executeToolCall(
        resumed.context(),
        expired_arena.allocator(),
        call,
    );
    try expectContains(
        expired.model_output,
        "\"error_code\":\"operation_replay_expired\"",
    );
    try expectSingleSubagentCreateEffects(alloc, &env, child_id);
}

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

const TestDevboxProvider = struct {
    calls: usize = 0,
};

fn executeTestDevboxProvider(
    raw_ctx: ?*anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    control: devbox_executor.Control,
) devbox_executor.ProviderError!devbox_executor.VercelOutcome {
    try control.check();
    const state: *TestDevboxProvider = @ptrCast(@alignCast(raw_ctx.?));
    state.calls += 1;
    const stdout = try alloc.dupe(u8, "DEVBOX_COMPACT_ONE\nDEVBOX_COMPACT_TWO\n");
    errdefer alloc.free(stdout);
    const stderr = try alloc.dupe(u8, "");
    return .{ .success = .{
        .exit_code = 0,
        .stdout = stdout,
        .stderr = stderr,
        .duration_ms = 9,
    } };
}

fn runCommandArgsForTest(alloc: Allocator, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"action\":\"exec\",\"command\":");
    try std.json.Stringify.value(command, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn runCommandArgsWithCleanProfileForTest(alloc: Allocator, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"action\":\"exec\",\"command\":");
    try std.json.Stringify.value(command, .{}, &out.writer);
    try out.writer.writeAll(",\"profile\":\"clean\"}");
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
    if (std.mem.eql(u8, call.name, "terminal")) return call;
    if (!std.mem.eql(u8, call.name, "run_command")) return call;
    var args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        call.arguments_json,
        .{ .allocate = .alloc_always },
    );
    if (args != .object) return error.InvalidToolArguments;
    try args.object.put(arena, "action", .{ .string = "exec" });
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try std.json.Stringify.value(args, .{}, &out.writer);
    var migrated = call;
    migrated.name = "terminal";
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
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf should-not-run\"}",
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
        },
    )) orelse return error.TestExpectedEqual;

    const failure = result.failure;
    try expectToolErrorField(failure, "type", "tool_execution_failed");
    try expectToolErrorField(failure, "tool_name", "terminal");
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
    decision: permission_auto_classifier.Decision = .allow,
    risk: permission_auto_classifier.Risk = .low,
    authorization: permission_auto_classifier.Authorization = .medium,
    rationale: []const u8 = "test automatic review",
    action_tag: ?std.meta.Tag(permission_auto_classifier.Action) = null,
    exact_command: ?[]const u8 = null,
    exact_arguments_json: ?[]const u8 = null,
    file_display_path: ?[]const u8 = null,
    file_additions: usize = 0,
    file_deletions: usize = 0,
    file_review_rows: usize = 0,
    escalation_reason: ?[]const u8 = null,
    target_path: ?[]const u8 = null,

    fn review(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        request: permission_auto_classifier.ReviewRequest,
    ) anyerror!permission_auto_classifier.ParseOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        if (request.workspace_root.len == 0 or request.escalation_reason.len == 0) {
            return error.TestExpectedReviewContext;
        }
        self.calls += 1;
        self.escalation_reason = request.escalation_reason;
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
            .sandbox_widening => {},
        }
        return .{ .valid = .{
            .risk = self.risk,
            .authorization = self.authorization,
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

test "background imports come from background and task modules" {
    try std.testing.expect(BackgroundRuntime == @import("../background/background_runtime.zig").BackgroundRuntime);
    try std.testing.expect(task_helpers.TaskState == @import("../tasks/task_helpers.zig").TaskState);

    const language = splitConversationLanguage(session_runtime.ConversationLanguage.literal("es"));
    try std.testing.expectEqualStrings("es", language.view());
}

test "tool runtime explicit cancellation source overrides worker fallback" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var rt = TestRuntime{ .cancel_flag = &cancel_flag };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expect(typedDispatchContext(rt.context(), arena_state.allocator()).cancel_flag.? == &cancel_flag);
}

test "read-only local runtime tools are registered in built-in registry" {
    const cases = [_]struct {
        name: []const u8,
        kind: tool_specs.ExecutorKind,
    }{
        .{ .name = "list_files", .kind = .list_files },
        .{ .name = "glob_files", .kind = .glob_files },
        .{ .name = "grep_files", .kind = .grep_files },
        .{ .name = "read_file", .kind = .read_file },
        .{ .name = "read_tool_result", .kind = .read_tool_result },
        .{ .name = "file_info", .kind = .file_info },
    };

    var rt = TestRuntime{};
    defer rt.deinit(std.testing.allocator);
    const registry = rt.context().tool_registry;
    for (cases) |case| {
        const found = registry.lookup(case.name) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(case.kind, found.executor_kind);
    }
    const terminal_tool = registry.lookup("terminal") orelse return error.TestExpectedEqual;
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
        .id = "list",
        .name = "list_files",
        .arguments_json = "{}",
    };
    try std.testing.expectEqual(
        tool_contracts.ToolCallValidationResult.not_registered,
        try validateToolCall(empty_rt.context(), arena, call),
    );

    const missing = try executeToolCall(empty_rt.context(), arena, call);
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, missing.status);
    try std.testing.expectEqualStrings("Unsupported tool: list_files", missing.model_output);

    const list_only_registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.list_files} };
    var list_rt = TestRuntime{ .tool_registry = list_only_registry };
    defer list_rt.deinit(alloc);
    try std.testing.expectEqual(
        tool_contracts.ToolCallValidationResult.valid,
        try validateToolCall(list_rt.context(), arena, call),
    );
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

fn registryOwnedFileInfoCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned file_info") };
}

fn registryOwnedCreateFolderCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    if (ctx.subagent_provider != null) return error.InvalidToolArguments;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned create_folder") };
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

fn registryOwnedSemanticSearchCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned semantic_search") };
}

const RegistryOwnedLauncherInput = struct {};

fn decodeRegistryOwnedLauncher(
    ctx: tool_dispatch.DispatchContext,
    _: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(RegistryOwnedLauncherInput);
    input.* = .{};
    return .{ .input = .{
        .ptr = input,
        .deinit_fn = deinitRegistryOwnedLauncherInput,
    } };
}

fn deinitRegistryOwnedLauncherInput(ptr: *anyopaque, alloc: Allocator) void {
    const input: *RegistryOwnedLauncherInput = @ptrCast(@alignCast(ptr));
    alloc.destroy(input);
}

fn registryOwnedLauncherCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned launcher") };
}

fn registryOwnedMemoryCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned memory") };
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

fn registryOwnedMcpSearchCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "registry-owned mcp_search_tools") };
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

test "file_info execution uses supplied registry entry" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_file_info = test_builtin_tools.file_info;
    registered_file_info.call = registryOwnedFileInfoCall;
    const tools = [_]tool_dispatch.Tool{registered_file_info};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const call = ToolCall{
        .id = "info",
        .name = "file_info",
        .arguments_json = "{\"path\":\".\"}",
    };

    var rt = TestRuntime{ .tool_registry = registry };
    defer rt.deinit(alloc);
    const direct = try executeToolCall(rt.context(), arena, call);
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, direct.status);
    try std.testing.expectEqualStrings("registry-owned file_info", direct.model_output);
}

test "create_folder supplied registry entry has no subagent capability" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_create_folder = test_builtin_tools.create_folder;
    registered_create_folder.call = registryOwnedCreateFolderCall;
    const tools = [_]tool_dispatch.Tool{registered_create_folder};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const call = ToolCall{
        .id = "create-folder-registry",
        .name = "create_folder",
        .arguments_json = "{\"path\":\"created\"}",
    };

    var rt = TestRuntime{
        .tool_registry = registry,
        .workspace_root = workspace,
    };
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
    try std.testing.expectEqualStrings("registry-owned create_folder", result.model_output);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io_mod.getIo(), "created", .{}),
    );
}

test "real tool runtime enforces refreshed live authority before filesystem effect" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var rt = TestRuntime{ .workspace_root = workspace };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = ToolCall{
        .id = "live-create",
        .name = "create_folder",
        .arguments_json = "{\"path\":\"created\"}",
    };
    const denied_tools = [_][]const u8{"read_file"};
    try std.testing.expectError(
        error.LiveToolAuthorityUnavailable,
        executeToolCallAuthorized(rt.context(), .{
            .call_allocator = arena,
            .result_allocator = arena,
            .call = call,
            .authority = .ordinary,
            .session_grants = &.{},
            .live_authority = .{
                .generation = 2,
                .root_id = "root",
                .tools = &denied_tools,
                .sandbox_backend = .none,
                .integrations = &.{},
                .rules = .{},
                .grants = &.{},
                .permission_mode = .auto,
            },
            .advertised_dynamic_tool_names = &.{},
            .max_tool_result_bytes = rt.max_tool_result_bytes,
        }),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io_mod.getIo(), "created", .{}),
    );

    const allowed_tools = [_][]const u8{"create_folder"};
    const result = try executeToolCallAuthorized(rt.context(), .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .ordinary,
        .session_grants = &.{},
        .live_authority = .{
            .generation = 3,
            .root_id = "root",
            .tools = &allowed_tools,
            .sandbox_backend = .none,
            .integrations = &.{},
            .rules = .{},
            .grants = &.{},
            .permission_mode = .auto,
        },
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    _ = try tmp.dir.statFile(io_mod.getIo(), "created", .{});
}

test "semantic_search execution uses supplied registry entry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_semantic_search = test_builtin_tools.semantic_search;
    registered_semantic_search.call = registryOwnedSemanticSearchCall;
    const tools = [_]tool_dispatch.Tool{registered_semantic_search};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const call = ToolCall{
        .id = "semantic-search",
        .name = "semantic_search",
        .arguments_json = "{\"query\":\"registry\"}",
    };

    var rt = TestRuntime{
        .tool_registry = registry,
        .workspace_root = workspace,
    };
    defer rt.deinit(alloc);
    const result = try executeToolCall(rt.context(), arena, call);
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqualStrings("registry-owned semantic_search", result.model_output);
}

test "launcher execution uses supplied registry entries after ordinary authorization" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_open_file = test_builtin_tools.open_file;
    registered_open_file.decode = decodeRegistryOwnedLauncher;
    registered_open_file.validate = null;
    registered_open_file.call = registryOwnedLauncherCall;
    const tools = [_]tool_dispatch.Tool{
        registered_open_file,
    };
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };

    var rt = TestRuntime{ .tool_registry = registry };
    defer rt.deinit(alloc);
    for ([_][]const u8{"open_file"}) |name| {
        const result = try executeToolCallAuthorized(rt.context(), .{
            .call_allocator = arena,
            .result_allocator = arena,
            .call = .{
                .id = "launcher-registry",
                .name = name,
                .arguments_json = "{}",
            },
            .authority = .ordinary,
            .session_grants = &.{},
            .advertised_dynamic_tool_names = &.{},
            .max_tool_result_bytes = rt.max_tool_result_bytes,
        });

        try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
        try std.testing.expectEqualStrings("registry-owned launcher", result.model_output);
    }
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

    var registered_run_command = test_builtin_tools.terminal;
    registered_run_command.call = registryOwnedTerminalExecCall;
    const tools = [_]tool_dispatch.Tool{registered_run_command};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const call = ToolCall{
        .id = "run-command-registry",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf bypassed\"}",
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

test "stateful local tool execution uses supplied registry entries" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_memory = test_builtin_tools.memory;
    registered_memory.call = registryOwnedMemoryCall;
    var registered_skill = test_builtin_tools.skill;
    registered_skill.call = registryOwnedSkillCall;
    var registered_install_skill = test_builtin_tools.install_skill;
    registered_install_skill.call = registryOwnedInstallSkillCall;

    const tools = [_]tool_dispatch.Tool{
        registered_memory,
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
        .{ .name = "memory", .args = "{\"action\":\"save\",\"fact\":\"likes registries\"}", .expected = "registry-owned memory" },
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

test "MCP control tool execution preserves argument failures" {
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
        .{ .name = "mcp_search_tools", .args = "{\"query\":1}", .expected = "mcp_search_tools requires a string query." },
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

test "MCP control tool execution uses supplied registry entries" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registered_search = test_builtin_tools.mcp_search_tools;
    registered_search.call = registryOwnedMcpSearchCall;
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
        .{ .name = "mcp_search_tools", .args = "{\"query\":\"read\"}", .expected = "registry-owned mcp_search_tools" },
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

    try std.testing.expectEqual(
        tool_contracts.ToolCallValidationResult.valid,
        try validateToolCall(rt.context(), arena_state.allocator(), .{
            .id = "workspace-terminal",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"printf ok\"}",
        }),
    );
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

test "web search invocation projects the pinned route after another route is selected" {
    const alloc = std.testing.allocator;
    var backend = WebSearchBackendFixture{};
    var connection_a = TestRuntime{
        .api_key = "credential-a",
        .gateway_team = "tenant-a",
        .gateway_retry_count = 2,
        .web_search_runtime_ready = true,
        .web_search_backend = .{
            .ctx = @ptrCast(&backend),
            .execute_fn = WebSearchBackendFixture.search,
        },
    };
    defer connection_a.deinit(alloc);
    connection_a.route.connection_id = "connection-a";
    connection_a.route.endpoint = "https://connection-a.invalid/chat";
    connection_a.route.primary_model_id = "provider/model-a";

    var connection_b = TestRuntime{ .api_key = "credential-b" };
    defer connection_b.deinit(alloc);
    connection_b.route.connection_id = "connection-b";
    _ = connection_b.context();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const dispatch = typedDispatchContext(connection_a.context(), arena_state.allocator());
    const invocation = dispatch.web_search_invocation orelse return error.TestExpectedEqual;

    try std.testing.expectEqualStrings("connection-a", invocation.inputs.connection_id);
    try std.testing.expectEqualStrings("credential-a", invocation.inputs.credential);
    try std.testing.expectEqualStrings("tenant-a", invocation.inputs.tenant.?);
    try std.testing.expectEqualStrings("provider/model-a", invocation.inputs.model);
    try std.testing.expectEqualStrings("https://connection-a.invalid/chat", invocation.inputs.endpoint);
    try std.testing.expect(invocation.inputs.usage == &connection_a.session.usage);
}

test "unsupported route blocks Fx search while route-free preflight stays available" {
    const alloc = std.testing.allocator;
    var backend = WebSearchBackendFixture{};
    var rt = TestRuntime{
        .web_search_runtime_ready = true,
        .web_search_backend = .{
            .ctx = @ptrCast(&backend),
            .execute_fn = WebSearchBackendFixture.search,
        },
    };
    defer rt.deinit(alloc);
    rt.route.adapter_kind = "unsupported";

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const dispatch = typedDispatchContext(rt.context(), arena_state.allocator());
    try std.testing.expect(dispatch.web_search_invocation == null);
    try std.testing.expect(!dispatch.tool_capabilities.web_search_runtime_ready);

    var no_route = rt.context();
    no_route.route = null;
    const missing = typedDispatchContext(no_route, arena_state.allocator());
    try std.testing.expect(missing.web_search_invocation == null);
    try std.testing.expect(missing.tool_capabilities.web_search_runtime_ready);
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
    try std.testing.expect(buf[0].ok);
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
        .ok = true,
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
        .name = "list_files",
        .arguments_json = "{}",
    }, .ask, &.{})).decision);

    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "1",
        .name = "ask_user_question",
        .arguments_json = "{}",
    }, .ask, &.{})).decision);
}

test "CLI headless ordinary admission preserves multi-target deny precedence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    {
        var source = try tmp.dir.createFile(io_mod.getIo(), "workspace/source.txt", .{ .truncate = true });
        defer source.close(io_mod.getIo());
        try source.writeStreamingAll(io_mod.getIo(), "source\n");
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{ .workspace_root = root, .interactive = false };
    defer rt.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct {
        tool_name: []const u8,
        arguments_json: []const u8,
        source_action: types.PermissionAction,
        destination_action: types.PermissionAction,
    }{
        .{
            .tool_name = "copy_file",
            .arguments_json = "{\"source\":\"source.txt\",\"destination\":\"destination.txt\"}",
            .source_action = .ask,
            .destination_action = .deny,
        },
        .{
            .tool_name = "copy_file",
            .arguments_json = "{\"source\":\"source.txt\",\"destination\":\"destination.txt\"}",
            .source_action = .deny,
            .destination_action = .ask,
        },
        .{
            .tool_name = "rename_file",
            .arguments_json = "{\"old_path\":\"source.txt\",\"new_path\":\"destination.txt\"}",
            .source_action = .ask,
            .destination_action = .deny,
        },
        .{
            .tool_name = "rename_file",
            .arguments_json = "{\"old_path\":\"source.txt\",\"new_path\":\"destination.txt\"}",
            .source_action = .deny,
            .destination_action = .ask,
        },
    };

    for (cases, 0..) |case, index| {
        var rules = [_]types.PermissionRule{
            .{
                .permission = @constCast(case.tool_name),
                .pattern = @constCast("source.txt"),
                .action = case.source_action,
            },
            .{
                .permission = @constCast(case.tool_name),
                .pattern = @constCast("destination.txt"),
                .action = case.destination_action,
            },
        };
        rt.permission_rules = .{ .rules = &rules };

        const outcome = try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
            .id = try std.fmt.allocPrint(arena, "multi-target-{d}", .{index}),
            .name = case.tool_name,
            .arguments_json = case.arguments_json,
        }, .ask, &.{});
        try std.testing.expectEqual(ToolPermissionDecision.policy_denied, outcome.decision);
        try std.testing.expect(outcome.execution_authority == null);
    }
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
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"pwd\"}",
    }, .ask, &.{}));
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, direct.decision);
    try std.testing.expect(direct.execution_authority == null);

    const blocked = (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "blocked",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch blocked.txt\"}",
    }, .ask, &.{}));
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, blocked.decision);
    try std.testing.expect(blocked.execution_authority == null);

    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("bash"), .pattern = @constCast("touch *"), .action = .allow },
    };
    rt.permission_rules = .{ .rules = &rules };
    const configured = (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "configured",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch configured.txt\"}",
    }, .ask, &.{}));
    switch ((configured.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(command_admission.ShellAuthorizationSource.configured_rule, authority.source),
    }
    try std.testing.expectEqual(@as(usize, 0), reviewer.calls);

    rt.permission_rules = .{};
    const automatic = (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "automatic",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch automatic.txt\"}",
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
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch configured.txt\"}",
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
    try std.testing.expect(applied.prepared_result_memory != null);
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

test "request tool permission combines configured external copy target with workspace automatic review" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    {
        var source = try tmp.dir.createFile(io_mod.getIo(), "workspace/source.txt", .{ .truncate = true });
        defer source.close(io_mod.getIo());
        try source.writeStreamingAll(io_mod.getIo(), "source\n");
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const pattern = try std.fmt.allocPrint(alloc, "{s}/**", .{external});
    defer alloc.free(pattern);
    var rules = [_]types.PermissionRule{
        .{
            .permission = @constCast("copy_file"),
            .pattern = pattern,
            .action = .allow,
        },
    };

    var reviewer = TestAutoReview{};
    var rt = TestRuntime{
        .workspace_root = root,
        .permission_mode = .auto,
        .permission_rules = .{ .rules = &rules },
        .interactive = false,
        .auto_classifier = reviewer.classifier(),
    };
    defer rt.deinit(alloc);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(ToolPermissionDecision.once, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "copy-external",
        .name = "copy_file",
        .arguments_json = "{\"source\":\"source.txt\",\"destination\":\"../external/copied.txt\"}",
    }, .auto, &.{})).decision);
    try std.testing.expectEqual(@as(usize, 1), reviewer.calls);
    try std.testing.expectEqualStrings("tool_requires_approval", reviewer.escalation_reason.?);
    try std.testing.expect(rt.worker.pending_permission_request_shared == null);
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
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, outcome.denial_reason.?);
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

test "request tool permission denies semantic_search outside workspace target" {
    const alloc = std.testing.allocator;
    var workspace_tmp = std.testing.tmpDir(.{});
    defer workspace_tmp.cleanup();
    try workspace_tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var external_tmp = std.testing.tmpDir(.{});
    defer external_tmp.cleanup();
    {
        var file = try external_tmp.dir.createFile(io_mod.getIo(), "outside.txt", .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "needle external\n");
    }
    const root = try io_mod.dirRealpathAlloc(alloc, workspace_tmp.dir, "workspace");
    defer alloc.free(root);
    const external = try io_mod.dirRealpathAlloc(alloc, external_tmp.dir, ".");
    defer alloc.free(external);

    var rt = TestRuntime{
        .workspace_root = root,
        .permission_mode = .auto,
    };
    defer rt.deinit(alloc);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.fmt.allocPrint(arena, "{{\"query\":\"needle\",\"path\":\"{s}\"}}", .{external});

    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "semantic",
        .name = "semantic_search",
        .arguments_json = args,
    }, .auto, &.{})).decision);
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

test "request tool permission checks copy and rename destinations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/src");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/src/source.txt", .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "source\n");
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var rt = TestRuntime{ .workspace_root = root };
    defer rt.deinit(std.testing.allocator);
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("copy_file"), .pattern = @constCast("blocked/*"), .action = .deny },
        .{ .permission = @constCast("rename_file"), .pattern = @constCast("blocked/*"), .action = .deny },
    };
    rt.permission_rules = .{ .rules = &rules };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "copy",
        .name = "copy_file",
        .arguments_json = "{\"source\":\"src/source.txt\",\"destination\":\"blocked/copied.txt\"}",
    }, .auto, &.{})).decision);
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, (try tool_admission.requestPermissionOutcome(rt.context().admissionInput(), arena, .{
        .id = "rename",
        .name = "rename_file",
        .arguments_json = "{\"old_path\":\"src/source.txt\",\"new_path\":\"blocked/renamed.txt\"}",
    }, .auto, &.{})).decision);

    try std.testing.expect(!absolutePathExists(try std.fs.path.join(arena, &.{ root, "blocked/copied.txt" })));
    try std.testing.expect(!absolutePathExists(try std.fs.path.join(arena, &.{ root, "blocked/renamed.txt" })));
    try std.testing.expect(absolutePathExists(try std.fs.path.join(arena, &.{ root, "src/source.txt" })));
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
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf 'PRE-TIMEOUT-OUT\\n'; printf 'PRE-TIMEOUT-ERR\\n' >&2; sleep 5\",\"profile\":\"clean\"}",
    };

    const result = try executeTestRunCommand(rt.context(), arena, tool_call);

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "timeout=true\n");
    try expectContains(result.model_output, "timeout_ms=1000\n");
    try expectContains(result.model_output, "command timed out and was terminated\n");
    try expectNotContains(result.model_output, "PRE-TIMEOUT-OUT");
    try expectNotContains(result.model_output, "PRE-TIMEOUT-ERR");
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "foreground");
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
        .model_tools = &.{},
        .agent_step_limit = 1,
        .cancel_flag = &cancel,
        .session_child_capability = &capability,
    };
    var prepared = try runtime_execution_memory.prepareToolModelOutput(
        arena,
        config,
        tool_call,
        result.model_output,
    );
    runtime_execution_memory.applyToolResultMemory(
        &prepared.memory,
        result.tool_result_memory,
    );
    var replay_finalized = false;
    defer if (!replay_finalized) capture.abort(arena);
    runtime_execution_memory.finalizeCommandReplay(
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
    const init = initCommandReplayCapture(
        failing.allocator(),
        true,
        64 * 1024,
        64 * 1024,
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

test "interactive devbox success emits raw provider output once" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rt = TestRuntime{
        .workspace_root = "/tmp",
        .permission_mode = .auto,
        .sandbox_backend = .vercel,
    };
    defer rt.deinit(alloc);
    var provider = TestDevboxProvider{};
    var captured = TestCommandOutputCapture{ .alloc = alloc };
    defer captured.deinit();
    var ctx = rt.context();
    ctx.devbox_provider = .{
        .ctx = @ptrCast(&provider),
        .execute_fn = executeTestDevboxProvider,
    };
    ctx.output_chunk_ctx = @ptrCast(&captured);
    ctx.on_output_chunk = TestCommandOutputCapture.onChunk;

    const result = try executeTestRunCommand(ctx, arena, .{
        .id = "devbox-compact",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf remote > provider-output.txt\"}",
    });

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqualStrings(
        "DEVBOX_COMPACT_ONE\nDEVBOX_COMPACT_TWO\n",
        captured.bytes.items,
    );
    try std.testing.expectEqual(@as(usize, 1), captured.stdout_chunks);
    try std.testing.expectEqual(@as(usize, 0), captured.stderr_chunks);
    try expectContains(result.model_output, "<stdout>\nDEVBOX_COMPACT_ONE\nDEVBOX_COMPACT_TWO\n</stdout>\n");
    const replay = result.command_replay_capture orelse
        return error.TestExpectedReplay;
    try std.testing.expect(replay.hasOutput());
}

test "run_command reactive sandbox retry timeout retains both attempts" {
    if (builtin.os.tag != .macos) return;

    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    const fixture_root = try std.fmt.allocPrint(
        alloc,
        "/var/tmp/fx-sandbox-retry-{d}-{d}",
        .{ std.c.getpid(), io_mod.nanoTimestamp() },
    );
    defer alloc.free(fixture_root);
    try std.Io.Dir.cwd().createDirPath(zio, fixture_root);
    defer std.Io.Dir.cwd().deleteTree(zio, fixture_root) catch {};

    const home_path = try std.fs.path.join(alloc, &.{ fixture_root, "home" });
    defer alloc.free(home_path);
    const cache_path = try std.fs.path.join(alloc, &.{ home_path, ".cache" });
    defer alloc.free(cache_path);
    const workspace_path = try std.fs.path.join(alloc, &.{ fixture_root, "workspace" });
    defer alloc.free(workspace_path);

    // The restricted profile permits /tmp and /private/tmp, so a fixture there
    // cannot prove that the retry widens access to the user's cache directory.
    try std.Io.Dir.cwd().createDirPath(zio, cache_path);
    try std.Io.Dir.cwd().createDirPath(zio, workspace_path);
    const home = try io_mod.realpathAlloc(alloc, home_path);
    defer alloc.free(home);
    const workspace = try io_mod.realpathAlloc(alloc, workspace_path);
    defer alloc.free(workspace);
    try setTestHome(home);
    defer setTestHome(null) catch {};
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const marker = try std.fmt.allocPrint(
        arena,
        "{s}/.cache/fx-replay-retry-{d}",
        .{ home, io_mod.nanoTimestamp() },
    );
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), marker) catch {};
    const command = try std.fmt.allocPrint(
        arena,
        "printf 'FIRST-ATTEMPT\\n'; printf x > '{s}' || exit 1; printf 'RETRY-ATTEMPT\\n'; sleep 5",
        .{marker},
    );
    const args = try runCommandArgsWithCleanProfileForTest(arena, command);

    var rt = TestRuntime{
        .workspace_root = workspace,
        .permission_mode = .auto,
        .sandbox_backend = .macos,
        .command_timeout_ms = 750,
    };
    defer rt.deinit(alloc);
    const call = ToolCall{
        .id = "retry-timeout",
        .name = "terminal",
        .arguments_json = args,
    };
    const restricted = try executeTestRunCommand(rt.context(), arena, call);
    const required = restricted.sandbox_scope_required orelse
        return error.TestExpectedSandboxScopeRequired;
    try std.testing.expectEqual(
        tool_contracts.SandboxWideningPhase.reactive,
        required.phase,
    );

    var broader_context = try tool_admission.runCommandContext(
        rt.context().admissionInput(),
        arena,
        call,
    );
    broader_context.scope = .broader;
    var restricted_capture_owned = required.command_replay_capture != null;
    defer if (restricted_capture_owned) {
        required.command_replay_capture.?.abort(arena);
    };
    restricted_capture_owned = false;
    const result = try executeToolCallAuthorized(rt.context(), .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(broader_context),
            .source = .auto_classifier,
        } } },
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
        .command_timeout_started_ms = required.command_timeout_started_ms,
        .command_replay_capture = required.command_replay_capture,
        .command_replay_unavailable = required.command_replay_unavailable,
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "timeout=true\n");
    try expectNotContains(result.model_output, "FIRST-ATTEMPT");
    try expectNotContains(result.model_output, "RETRY-ATTEMPT");

    const capture = result.command_replay_capture orelse
        return error.TestExpectedReplay;
    defer capture.abort(arena);
    var canonical = (try capture.canonicalizeForComparison(
        arena,
    )) orelse return error.TestExpectedReplay;
    defer canonical.deinit(arena);
    var first_attempts: usize = 0;
    var retry_attempts: usize = 0;
    for (canonical.records.items) |record| {
        if (record.stream == .stdout and
            std.mem.eql(u8, record.text.items, "FIRST-ATTEMPT")) first_attempts += 1;
        if (record.stream == .stdout and
            std.mem.eql(u8, record.text.items, "RETRY-ATTEMPT")) retry_attempts += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), first_attempts);
    try std.testing.expectEqual(@as(usize, 1), retry_attempts);
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
        .sandbox_backend = .none,
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
        .name = "terminal",
        .arguments_json = interactive_args,
    });

    try std.testing.expect(interactive_trigger.seen);
    try std.testing.expect(absolutePathExists(interactive_marker));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, interactive.status);
    try std.testing.expect(interactive.cancelled);
    try std.testing.expectEqualStrings("command cancelled\n", interactive.model_output);
    const structured = interactive.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "foreground");
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
        .name = "terminal",
        .arguments_json = headless_args,
    });
    try std.testing.expect(headless_trigger.seen);
    try std.testing.expect(absolutePathExists(headless_marker));
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, headless.status);
    try std.testing.expect(headless.cancelled);
    try std.testing.expectEqualStrings("command cancelled\n", headless.model_output);
    const headless_structured = headless.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(headless_structured, "kind", "foreground");
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
    var command_ctx = try tool_admission.runCommandContext(
        retry_ctx.admissionInput(),
        arena,
        .{
            .id = "cancel-broader-retry",
            .name = "terminal",
            .arguments_json = headless_args,
        },
    );
    command_ctx.scope = .broader;
    const retry = try executeToolCallAuthorized(retry_ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = .{
            .id = "cancel-broader-retry",
            .name = "terminal",
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
    try std.testing.expectEqual(@as(usize, 0), diagnostics.snapshotToolCalls(&metrics));
}

test "broader sandbox retry consumes the original command timeout budget" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var rt = TestRuntime{
        .command_timeout_ms = 1,
        .sandbox_backend = .none,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = ToolCall{
        .id = "broader-timeout",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"sleep 5\"}",
    };
    var command_ctx = try tool_admission.runCommandContext(
        rt.context().admissionInput(),
        arena,
        call,
    );
    command_ctx.scope = .broader;
    const original_start_ms = io_mod.milliTimestamp() - 50;

    const result = try executeToolCallAuthorized(rt.context(), .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .auto_classifier,
        } } },
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
        .command_timeout_started_ms = original_start_ms,
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "timeout=true\n");
    try expectContains(result.model_output, "timeout_ms=1\n");
}

test "pre-spawn broader retry cancellation defers tool diagnostics" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    var cancel = std.atomic.Value(bool).init(true);
    var rt = TestRuntime{
        .cancel_flag = &cancel,
        .permission_mode = .auto,
        .sandbox_backend = .none,
    };
    defer rt.deinit(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = ToolCall{
        .id = "cancel-before-broader-retry",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf never > cancelled-before-retry\"}",
    };
    var command_ctx = try tool_admission.runCommandContext(
        rt.context().admissionInput(),
        arena,
        call,
    );
    command_ctx.scope = .broader;
    var request: tool_contracts.ToolExecutionRequest = .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = call,
        .authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .auto_classifier,
        } } },
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    };

    try std.testing.expectError(
        error.CancelledBeforeExecution,
        executeToolCallAuthorized(rt.context(), request),
    );
    var metrics: [1]diagnostics.ToolCallMetric = undefined;
    try std.testing.expectEqual(@as(usize, 0), diagnostics.snapshotToolCalls(&metrics));

    command_ctx.scope = .restricted;
    request.authority = .{ .run_command = .{ .shell_allowed = .{
        .fingerprint = .init(command_ctx),
        .source = .auto_classifier,
    } } };
    try std.testing.expectError(
        error.Cancelled,
        executeToolCallAuthorized(rt.context(), request),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostics.snapshotToolCalls(&metrics));
}

test "run_command success exposes structured foreground metadata" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var rt = TestRuntime{
        .permission_mode = .auto,
        .sandbox_backend = .none,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf '\\\\150\\\\145\\\\154\\\\154\\\\157'\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "foreground");
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
    return command_contract.formatForegroundCommandResult(alloc, .{
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
    var result = try command_contract.formatForegroundCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = .{ .exit_code = 0 },
        .stdout_display = "preview",
        .stderr_display = "",
        .stdout_bytes = 70_000,
        .stderr_bytes = 0,
        .duration_ms = 4,
    });
    var metadata = result.command_result.?.foreground;
    metadata.truncated = true;
    result.command_result = .{ .foreground = metadata };
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
        .command_result = .{ .foreground = .{
            .command = command,
            .cwd = cwd,
            .duration_ms = 3,
        } },
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
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"exit 7\"}",
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
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"generate output\"}",
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
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"long command\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, cancelled.status);
    try std.testing.expect(cancelled.cancelled);
    const cancelled_json = cancelled.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultNull(cancelled_json, "signal");
    try expectCommandResultBool(cancelled_json, "timed_out", false);

    rt.workspace_executor = .{ .execute_fn = fakeWorkspaceDeadline };
    const timed_out = try executeTestRunCommand(rt.context(), arena, .{
        .id = "browser-timeout",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"long command\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, timed_out.status);
    try expectContains(timed_out.model_output, "timeout=true\n");
    try expectContains(timed_out.model_output, "timeout_ms=30000\n");
    const timeout_json = timed_out.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultBool(timeout_json, "timed_out", true);
    try expectCommandResultNull(timeout_json, "signal");
}

test "run_command propagates output callback failure" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const FailOutput = struct {
        fn write(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_contract.CommandOutputStream, _: []const u8) error{OutOfMemory}!void {
            return error.OutOfMemory;
        }
    };

    var rt = TestRuntime{
        .permission_mode = .auto,
        .sandbox_backend = .none,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var ctx = rt.context();
    ctx.output_chunk_ctx = @ptrCast(&rt);
    ctx.on_output_chunk = FailOutput.write;
    try std.testing.expectError(
        error.OutOfMemory,
        executeTestRunCommand(ctx, arena_state.allocator(), .{
            .id = "cmd",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"printf 'handoff\\\\n'\"}",
        }),
    );
}

test "run_command returns model output and structured metadata" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var rt = TestRuntime{
        .permission_mode = .auto,
        .sandbox_backend = .none,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf 'quiet-stdout\\\\n'; printf 'quiet-stderr\\\\n' >&2\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try expectContains(result.model_output, "exit_code=0\n");
    try expectContains(result.model_output, "<stdout>\nquiet-stdout\n</stdout>\n");
    try expectContains(result.model_output, "<stderr>\nquiet-stderr\n</stderr>\n");

    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "foreground");
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
        .sandbox_backend = .none,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf 'bad AKIA0123456789ABCDEF\\\\n' >&2; exit 7\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectToolErrorField(result.model_output, "type", "tool_execution_failed");
    try expectToolErrorField(result.model_output, "tool_name", "terminal");
    try expectToolErrorDetailString(result.model_output, "command", "printf 'bad [redacted]\\n' >&2; exit 7");
    try expectToolErrorDetailString(result.model_output, "cwd", "/tmp");
    try expectToolErrorDetailInt(result.model_output, "exit_code", 7);
    try expectToolErrorDetailString(result.model_output, "stderr", "bad [redacted]");
    try expectContains(result.model_output, "Inspect stderr");
    try expectNotContains(result.model_output, "AKIA0123456789ABCDEF");
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try expectCommandResultField(structured, "kind", "foreground");
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
        .sandbox_backend = .none,
    };
    rt.max_command_output_bytes = 16;
    rt.command_artifact_dir = artifact_dir;
    defer rt.deinit(alloc);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf %026d 0\"}",
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

test "run_command reactive sandbox widening preserves the restricted attempt" {
    if (builtin.os.tag != .macos) return;

    var rt = TestRuntime{
        .permission_mode = .auto,
        .sandbox_backend = .macos,
        .interactive = false,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf 'Operation not permitted\\\\n' >&2; exit 1\",\"profile\":\"clean\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "Operation not permitted");
    const widening = result.sandbox_scope_required orelse
        return error.TestExpectedSandboxScopeRequired;
    try std.testing.expectEqual(tool_contracts.SandboxWideningPhase.reactive, widening.phase);
    try std.testing.expectEqualStrings(
        "printf 'Operation not permitted\\n' >&2; exit 1",
        widening.restricted_fingerprint.command,
    );
    try std.testing.expectEqualStrings("/tmp", widening.restricted_fingerprint.resolved_cwd);
    try std.testing.expectEqualStrings(
        result.model_output,
        widening.restricted_model_output orelse return error.TestExpectedRestrictedResult,
    );
    const structured = result.command_result_json orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(
        structured,
        widening.restricted_command_result_json orelse
            return error.TestExpectedRestrictedResult,
    );
    try expectCommandResultField(structured, "kind", "foreground");
    try expectCommandResultField(structured, "command", "printf 'Operation not permitted\\n' >&2; exit 1");
    try expectCommandResultInt(structured, "exit_code", 1);
    try expectCommandResultInt(structured, "stdout_bytes", 0);
    try expectCommandResultInt(structured, "stderr_bytes", 24);
    try std.testing.expect(rt.worker.pending_permission_request_shared == null);
}

test "run_command preflight sandbox widening reports that no attempt ran" {
    if (builtin.os.tag != .macos) return;

    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    var rt = TestRuntime{
        .permission_mode = .auto,
        .sandbox_backend = .macos,
        .interactive = false,
    };
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try executeTestRunCommand(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"npm test\"}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try std.testing.expectEqualStrings("", result.model_output);
    try std.testing.expect(result.command_result_json == null);
    const widening = result.sandbox_scope_required orelse
        return error.TestExpectedSandboxScopeRequired;
    try std.testing.expectEqual(tool_contracts.SandboxWideningPhase.preflight, widening.phase);
    try std.testing.expectEqualStrings("npm test", widening.restricted_fingerprint.command);
    try std.testing.expectEqualStrings("/tmp", widening.restricted_fingerprint.resolved_cwd);
    try std.testing.expect(widening.restricted_model_output == null);
    try std.testing.expect(widening.restricted_command_result_json == null);
    try std.testing.expect(rt.worker.pending_permission_request_shared == null);
    var metrics: [1]diagnostics.ToolCallMetric = undefined;
    try std.testing.expectEqual(@as(usize, 0), diagnostics.snapshotToolCalls(&metrics));
}

test "terminal exec rejects legacy background input without creating state" {
    var rt = TestRuntime{};
    defer rt.deinit(std.testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf row07-headless-bg\",\"background\":true}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "\"code\":\"invalid_action_fields\"");
    try expectContains(result.model_output, "\"invalid_fields\":[\"background\"]");
    var tasks = try rt.background.snapshotTasks(std.testing.allocator);
    defer tasks.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), tasks.items.len);
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
    const workspace_permissions = [_][]const u8{
        "edit",
        "create_folder",
        "open_file",
        "rename_file",
        "copy_file",
        "read",
        "list",
        "glob",
        "grep",
    };
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
        .{ .permission = @constCast("list"), .pattern = @constCast("."), .action = .ask },
    };
    var rt = TestRuntime{
        .workspace_root = "/tmp/workspace",
        .permission_rules = .{ .rules = &rules },
        .permission_mode = .auto,
    };
    defer rt.deinit(std.testing.allocator);

    var state = PermissionThreadState{};
    const thread = try std.Thread.spawn(.{}, runPermissionRequest, .{ &state, rt.context(), ToolCall{ .id = "1", .name = "list_files", .arguments_json = "{}" }, PermissionMode.auto });
    var thread_joined = false;
    defer if (!thread_joined) {
        rt.worker.requestShutdown();
        thread.join();
    };

    rt.worker.worker_processing = true;
    const request_id = try waitForPermissionPrompt(&rt.worker, "list_files");
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
    };

    const PermissionContext = struct {
        search_rule_count: usize = 0,
        schema_rule_count: usize = 0,
    };

    const AuthorityContext = struct {
        calls: usize = 0,
        admission_generation: u64 = 0,
        action_generation: u64 = 0,
    };

    fn hasTrue(_: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
        return true;
    }

    fn hasFalse(_: *anyopaque, _: []const u8) bool {
        return false;
    }

    fn validateArguments(_: *anyopaque, arena: Allocator, _: []const u8, arguments_json: []const u8, _: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
        if (std.mem.eql(u8, arguments_json, "{\"path\":7}")) {
            return .{ .invalid = try arena.dupe(u8, "path must be a string") };
        }
        return .valid;
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
        return .{ .model_output = try arena.dupe(u8, "mcp ok") };
    }

    fn callNull(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
        return null;
    }

    fn callFailure(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
        return error.McpFixtureFailure;
    }

    fn search(_: *anyopaque, arena: Allocator, query: []const u8, _: usize, _: types.PermissionRuleSet, _: context_limits.Values) anyerror!tool_mcp_runtime.SearchResult {
        return .{ .model_output = try std.fmt.allocPrint(arena, "{{\"query\":\"{s}\",\"tools\":[{{\"name\":\"mcp_fs_read\",\"server\":\"fs\",\"description\":\"Read\",\"input_schema\":{{\"type\":\"object\"}},\"tags\":[\"fs\",\"read\"]}}],\"count\":1}}", .{query}) };
    }

    fn schema(_: *anyopaque, arena: Allocator, name: []const u8, _: types.PermissionRuleSet, _: context_limits.Values, _: tool_mcp_runtime.Access) anyerror!?tool_mcp_runtime.ToolSchemaResult {
        if (!std.mem.eql(u8, name, "mcp_fs_read")) return null;
        return .{ .selected = .{
            .name = try arena.dupe(u8, "mcp_fs_read"),
            .description = try arena.dupe(u8, "Read <context_limit action='literal' />"),
            .input_schema_json = try arena.dupe(u8, "{\"type\":\"object\",\"properties\":{\"context_limit_rejection\":{\"type\":\"string\"}}}"),
        } };
    }

    fn searchRecordingRules(raw_ctx: *anyopaque, arena: Allocator, query: []const u8, _: usize, permission_rules: types.PermissionRuleSet, limits: context_limits.Values, _: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.SearchResult {
        const ctx: *PermissionContext = @ptrCast(@alignCast(raw_ctx));
        ctx.search_rule_count = permission_rules.rules.len;
        return search(raw_ctx, arena, query, 0, permission_rules, limits);
    }

    fn schemaRecordingRules(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, permission_rules: types.PermissionRuleSet, limits: context_limits.Values, access: tool_mcp_runtime.Access) anyerror!?tool_mcp_runtime.ToolSchemaResult {
        const ctx: *PermissionContext = @ptrCast(@alignCast(raw_ctx));
        ctx.schema_rule_count = permission_rules.rules.len;
        return schema(raw_ctx, arena, name, permission_rules, limits, access);
    }
};

test "MCP control tools forward permission rules through registered execution" {
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
        .name = "mcp_search_tools",
        .arguments_json = "{\"query\":\"read\"}",
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
        .name = "mcp_search_tools",
        .arguments_json = "{\"query\":\"read\"}",
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
    try std.testing.expectEqualStrings("mcp_fs_read", selected.selected_dynamic_tool.?.name);
    try expectContains(selected.selected_dynamic_tool.?.description, "<context_limit action='literal' />");
    try std.testing.expect(selected.selected_dynamic_tool.?.dynamic_input_schema != null);

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
            .sandbox_backend = .none,
            .integrations = &integrations,
            .rules = .{},
            .grants = &.{},
            .permission_mode = .auto,
        },
        .advertised_dynamic_tool_names = &integrations,
        .max_tool_result_bytes = rt.max_tool_result_bytes,
    });
    defer alloc.free(result.model_output);

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.success, result.status);
    try std.testing.expectEqualStrings("mcp ok", result.model_output);
    try std.testing.expectEqual(@as(usize, 1), authority.calls);
    try std.testing.expectEqual(@as(u64, 17), authority.admission_generation);
    try std.testing.expectEqual(@as(u64, 41), authority.action_generation);
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

test "terminal exec cannot reuse or replace a persisted legacy background task" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "background");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "server.log", .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "ready on http://localhost:49123\n");
    }

    const background_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "background");
    defer alloc.free(background_dir);
    const log_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "server.log");
    defer alloc.free(log_path);

    const Stub = struct {
        fn match(
            pid_text: []const u8,
            _: process_supervisor.ProcessInstanceToken,
        ) process_supervisor.TokenMatch {
            return if (std.mem.eql(u8, pid_text, "12345"))
                .matched
            else
                .missing;
        }
    };
    process_supervisor.process_token_match_for_test = Stub.match;
    defer process_supervisor.process_token_match_for_test = null;
    const token = try process_supervisor.ProcessInstanceToken.parse(
        "linux:00112233445566778899aabbccddeeff:12345",
    );
    const pid_text = "12345";

    var rt = TestRuntime{
        .workspace_root = "/tmp/fx",
        .interactive = false,
        .background = BackgroundRuntime.init(
            background_process_provider.process_supervisor_test_provider,
        ),
    };
    defer rt.deinit(alloc);
    try rt.background.enablePersistence(alloc, background_dir);
    const task_id = try rt.background.registerBackgroundDurably(alloc, .{
        .pid = pid_text,
        .process_token = token,
        .command = "npm run dev",
        .cwd = "/tmp/fx",
        .log_path = log_path,
        .expect_url = true,
        .url = "http://localhost:49123",
    });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
        .id = "1",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"npm run dev\",\"background\":true}",
    });

    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
    try expectContains(result.model_output, "\"code\":\"invalid_action_fields\"");
    try expectContains(result.model_output, "\"invalid_fields\":[\"background\"]");
    var tasks = try rt.background.snapshotTasks(alloc);
    defer tasks.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
    try std.testing.expectEqual(task_id, tasks.items[0].id);
}

test "external absolute non-write tracked mutations capture resolved paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var allow_rules = [_]types.PermissionRule{
        .{ .permission = @constCast("*"), .pattern = @constCast("*"), .action = .allow },
    };
    var rt = TestRuntime{ .workspace_root = root, .tracker = &tracker };
    rt.permission_rules = .{ .rules = &allow_rules };
    defer rt.deinit(alloc);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeTestFile(tmp.dir, "external/delete.txt", "delete\n");
    const delete_path = try std.fs.path.join(arena, &.{ external, "delete.txt" });
    const delete_args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{delete_path});
    _ = try executeToolCall(rt.context(), arena, .{
        .id = "external-delete",
        .name = "delete_file",
        .arguments_json = delete_args,
    });
    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expectEqual(change_tracker.OperationKind.delete, tracker.stack.items[0].kind);
    try std.testing.expectEqualStrings(delete_path, tracker.stack.items[0].path);
    try std.testing.expectEqualStrings("delete\n", tracker.stack.items[0].previous_content.?);

    try writeTestFile(tmp.dir, "external/rename.txt", "rename\n");
    const rename_source = try std.fs.path.join(arena, &.{ external, "rename.txt" });
    const rename_dest = try std.fs.path.join(arena, &.{ external, "renamed.txt" });
    const rename_args = try std.fmt.allocPrint(arena, "{{\"old_path\":\"{s}\",\"new_path\":\"{s}\"}}", .{ rename_source, rename_dest });
    _ = try executeToolCall(rt.context(), arena, .{
        .id = "external-rename",
        .name = "rename_file",
        .arguments_json = rename_args,
    });
    try std.testing.expectEqual(@as(usize, 2), tracker.stack.items.len);
    try std.testing.expectEqual(change_tracker.OperationKind.rename, tracker.stack.items[1].kind);
    try std.testing.expectEqualStrings(rename_source, tracker.stack.items[1].path);
    try std.testing.expectEqualStrings(rename_dest, tracker.stack.items[1].new_path.?);

    try writeTestFile(tmp.dir, "external/copy-source.txt", "copy\n");
    const copy_source = try std.fs.path.join(arena, &.{ external, "copy-source.txt" });
    const copy_dest = try std.fs.path.join(arena, &.{ external, "copy-dest.txt" });
    const copy_args = try std.fmt.allocPrint(arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{ copy_source, copy_dest });
    _ = try executeToolCall(rt.context(), arena, .{
        .id = "external-copy",
        .name = "copy_file",
        .arguments_json = copy_args,
    });
    try std.testing.expectEqual(@as(usize, 3), tracker.stack.items.len);
    try std.testing.expectEqual(change_tracker.OperationKind.write, tracker.stack.items[2].kind);
    try std.testing.expectEqualStrings(copy_dest, tracker.stack.items[2].path);
}

test "invalid tracked mutations do not push tracker operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var rt = TestRuntime{ .workspace_root = root, .tracker = &tracker };
    defer rt.deinit(alloc);

    const calls = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "delete_file", .args = "{}" },
        .{ .name = "rename_file", .args = "{}" },
        .{ .name = "copy_file", .args = "{}" },
    };

    for (calls) |call| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        try std.testing.expectError(error.InvalidToolArguments, executeToolCall(rt.context(), arena_state.allocator(), .{
            .id = "1",
            .name = call.name,
            .arguments_json = call.args,
        }));
        try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    }
}

test "failed tracked delete rename and copy skip tracker publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/non-empty");
    try writeTestFile(tmp.dir, "workspace/non-empty/child.txt", "keep\n");
    try writeTestFile(tmp.dir, "workspace/rename-source.txt", "rename\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/rename-destination");
    try writeTestFile(tmp.dir, "workspace/rename-destination/child.txt", "keep\n");
    try writeTestFile(tmp.dir, "workspace/copy-source.txt", "copy\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/copy-destination");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var rt = TestRuntime{ .workspace_root = root, .tracker = &tracker };
    defer rt.deinit(alloc);

    const calls = [_]struct {
        name: []const u8,
        args: []const u8,
        failure_prefix: []const u8,
    }{
        .{
            .name = "delete_file",
            .args = "{\"path\":\"non-empty\"}",
            .failure_prefix = "delete_file failed:",
        },
        .{
            .name = "rename_file",
            .args = "{\"old_path\":\"rename-source.txt\",\"new_path\":\"rename-destination\"}",
            .failure_prefix = "rename_file failed:",
        },
        .{
            .name = "copy_file",
            .args = "{\"source\":\"copy-source.txt\",\"destination\":\"copy-destination\"}",
            .failure_prefix = "copy_file failed:",
        },
    };

    for (calls) |call| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const result = try executeToolCall(rt.context(), arena_state.allocator(), .{
            .id = "tracked-failure",
            .name = call.name,
            .arguments_json = call.args,
        });
        try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, result.status);
        try std.testing.expect(std.mem.startsWith(u8, result.model_output, call.failure_prefix));
        try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    }
}

test "memory tool uses isolated HOME and preserves outputs" {
    const alloc = std.testing.allocator;
    var no_home_rt = TestRuntime{};
    defer no_home_rt.deinit(alloc);
    try setTestHome(null);
    try expectToolOutput(no_home_rt.context(), "memory", "{\"action\":\"list\"}", "memory unavailable: HOME not set");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    try setTestHome(home);

    var rt = TestRuntime{};
    defer rt.deinit(alloc);
    const ctx = rt.context();
    try expectToolOutput(ctx, "memory", "{\"action\":\"list\"}", "No saved memories");

    var rejected_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer rejected_arena_state.deinit();
    const rejected = try executeToolCall(ctx, rejected_arena_state.allocator(), .{
        .id = "invalid-memory-action",
        .name = "memory",
        .arguments_json = "{\"action\":\"replace\",\"fact\":\"new value\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, rejected.status);
    try std.testing.expectEqualStrings(
        "memory field \"action\" must be one of: save, list, clear",
        rejected.model_output,
    );

    try expectToolOutput(ctx, "memory", "{\"action\":\"save\",\"fact\":\"likes Zig\"}", "remembered");
    try expectToolOutput(ctx, "memory", "{\"action\":\"save\",\"fact\":\"likes Zig\"}", "remembered");
    try expectToolOutput(ctx, "memory", "{\"action\":\"list\"}", "- likes Zig\n");

    const memories_path = try std.fs.path.join(alloc, &.{ home, ".fx", "memories.json" });
    defer alloc.free(memories_path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), memories_path, .{});
    const content = blk: {
        defer file.close(io_mod.getIo());
        break :blk try io_mod.readFileToEnd(alloc, &file, 4096);
    };
    defer alloc.free(content);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("likes Zig", parsed.value.array.items[0].string);

    try expectToolOutput(ctx, "memory", "{\"action\":\"clear\"}", "memories cleared");
    try expectToolOutput(ctx, "memory", "{\"action\":\"clear\"}", "memories cleared");
    try expectToolOutput(ctx, "memory", "{\"action\":\"list\"}", "No saved memories");

    try std.Io.Dir.createDirAbsolute(io_mod.getIo(), memories_path, .default_dir);
    const survivor_path = try std.fs.path.join(alloc, &.{ memories_path, "must-survive.txt" });
    defer alloc.free(survivor_path);
    {
        var survivor = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), survivor_path, .{});
        survivor.close(io_mod.getIo());
    }

    var failed_clear_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer failed_clear_arena_state.deinit();
    const failed_clear = try executeToolCall(ctx, failed_clear_arena_state.allocator(), .{
        .id = "failed-memory-clear",
        .name = "memory",
        .arguments_json = "{\"action\":\"clear\"}",
    });
    try std.testing.expectEqual(tool_contracts.ToolExecutionStatus.failure, failed_clear.status);
    try std.testing.expectEqualStrings(
        "memory clear failed: saved memories were not removed; ensure ~/.fx/memories.json is a removable file and retry",
        failed_clear.model_output,
    );

    var survivor = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), survivor_path, .{});
    survivor.close(io_mod.getIo());
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
    const result = try executeToolCall(ctx, arena_state.allocator(), .{ .id = "1", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" });
    try expectContains(result.model_output, "<skill_content name=\"workflow\" resource=\"SKILL.md\" offset=\"0\"");
    try expectContains(result.model_output, "use the workflow skill");
    try expectNotContains(result.model_output, "assets/data.txt");
    try std.testing.expect(result.system_notice == null);
    try std.testing.expectEqual(@as(usize, 2), result.context_notices.len);
    try expectContains(result.context_notices[0], "[context] skill resource \"workflow/SKILL.md\" truncated");
    try expectContains(result.context_notices[1], "skill discovery warning:");
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
    last_chat_url: []const u8 = "",

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
        request: agent_stream_provider.Request,
    ) anyerror!agent_stream_provider.Result {
        const self: *VisionGatewayFixture = @ptrCast(@alignCast(context.?));
        if (self.allocation_probe) |probe| {
            self.allocation_index_at_stream = probe.alloc_index;
        }
        const response_index = self.call_count;
        self.call_count += 1;
        try self.payloads.append(self.alloc, try self.alloc.dupe(u8, request.payload));
        self.last_api_key = request.api_key;
        self.last_team = request.team;
        self.last_model = request.model;
        self.last_retry_count = request.retry_count;
        self.last_chat_url = request.chat_url;
        if (self.cancel_after_call == self.call_count) request.cancel_flag.store(true, .seq_cst);
        if (response_index >= self.responses.len) return error.UnexpectedVisionGatewayCall;
        const response = self.responses[response_index];
        request.delivery.markPossiblySent();
        return .{
            .status = response.status,
            .completion = .{
                .content = response.content,
                .generation_id = response.generation_id,
                .finish_reason = .stop,
                .usage = response.usage,
            },
            .generation_origin = "https://ai-gateway.vercel.sh",
        };
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
    try std.testing.expectEqualStrings("https://gateway.invalid/chat", fixture.last_chat_url);
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
