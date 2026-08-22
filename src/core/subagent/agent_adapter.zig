const std = @import("std");
const agent_runtime = @import("../agent/agent_runtime.zig");
const stream_provider = @import("../agent/stream_provider.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const auto_classifier = @import("../permissions/auto_classifier.zig");
const command_admission = @import("../permissions/command_admission.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const model_catalog = @import("../mcp/model_catalog.zig");
const context_contract = @import("../workspace/context_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const execution_memory = @import("../agent/execution_memory.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const io_mod = @import("../shared/io.zig");
const session_codec = @import("../session/session_codec.zig");
const types = @import("../shared/types.zig");
const diff_mod = @import("../output/diff.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const parent_delivery_projector = @import("parent_delivery_projector.zig");
const tool_host = @import("tool_host.zig");

const Allocator = std.mem.Allocator;

pub const ProviderRoute = struct {
    agent_stream_provider: stream_provider.Provider,
    permission_reviewer_provider: ?auto_classifier.Provider,
};

pub const ProviderRoutes = struct {
    gateway: ProviderRoute,
    codex: ProviderRoute,
    grok: ProviderRoute,
    claude: ProviderRoute,

    pub fn select(self: ProviderRoutes, provider: model_provider.ProviderId) ProviderRoute {
        return switch (provider) {
            .gateway => self.gateway,
            .codex => self.codex,
            .grok => self.grok,
            .claude => self.claude,
        };
    }
};

test "provider routes select independent streams and reviewers" {
    var gateway_tag: u8 = 0;
    var codex_tag: u8 = 0;
    var grok_tag: u8 = 0;
    var claude_tag: u8 = 0;
    var gateway_stream = stream_provider.unavailable_provider;
    gateway_stream.context = &gateway_tag;
    var codex_stream = stream_provider.unavailable_provider;
    codex_stream.context = &codex_tag;
    var grok_stream = stream_provider.unavailable_provider;
    grok_stream.context = &grok_tag;
    var claude_stream = stream_provider.unavailable_provider;
    claude_stream.context = &claude_tag;
    const Reviewer = struct {
        fn review(
            _: ?*anyopaque,
            _: Allocator,
            _: auto_classifier.ProviderInput,
            _: auto_classifier.ReviewRequest,
        ) anyerror!auto_classifier.ParseOutcome {
            return .invalid;
        }
    };
    const gateway_reviewer = auto_classifier.Provider{ .context = &gateway_tag, .review_fn = Reviewer.review };
    const codex_reviewer = auto_classifier.Provider{ .context = &codex_tag, .review_fn = Reviewer.review };
    const grok_reviewer = auto_classifier.Provider{ .context = &grok_tag, .review_fn = Reviewer.review };
    const claude_reviewer = auto_classifier.Provider{ .context = &claude_tag, .review_fn = Reviewer.review };
    const routes = ProviderRoutes{
        .gateway = .{ .agent_stream_provider = gateway_stream, .permission_reviewer_provider = gateway_reviewer },
        .codex = .{ .agent_stream_provider = codex_stream, .permission_reviewer_provider = codex_reviewer },
        .grok = .{ .agent_stream_provider = grok_stream, .permission_reviewer_provider = grok_reviewer },
        .claude = .{ .agent_stream_provider = claude_stream, .permission_reviewer_provider = claude_reviewer },
    };

    try std.testing.expect(routes.select(.gateway).agent_stream_provider.context.? == @as(*anyopaque, @ptrCast(&gateway_tag)));
    try std.testing.expect(routes.select(.gateway).permission_reviewer_provider.?.context.? == @as(*anyopaque, @ptrCast(&gateway_tag)));
    try std.testing.expect(routes.select(.codex).agent_stream_provider.context.? == @as(*anyopaque, @ptrCast(&codex_tag)));
    try std.testing.expect(routes.select(.codex).permission_reviewer_provider.?.context.? == @as(*anyopaque, @ptrCast(&codex_tag)));
    try std.testing.expect(routes.select(.grok).agent_stream_provider.context.? == @as(*anyopaque, @ptrCast(&grok_tag)));
    try std.testing.expect(routes.select(.grok).permission_reviewer_provider.?.context.? == @as(*anyopaque, @ptrCast(&grok_tag)));
}

pub const Config = struct {
    host: *tool_host.Runtime,
    tool_context: tool_runtime.Context,
    provider_routes: ProviderRoutes,
    system_prompt: []const u8,
    model_prompt_overlay: ?[]const u8 = null,
    skills_prompt_section: []const u8 = "",
    explicit_skills_prompt_section: []const u8 = "",
    gateway_tools_json: []const u8,
    custom_tool_guidance: []const u8 = "",
    context_registry: context_contract.Registry,
    context_enabled: bool,
    project_context: []const u8 = "",
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
};

const Context = struct {
    config: Config,
    turn: *execution.TurnContext,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    turn_outcome: ?types.TurnPresentationOutcome = null,

    fn toolContext(self: *Context) tool_runtime.Context {
        var result = self.config.tool_context;
        result.worker = self.turn.workerRuntime();
        result.session = self.turn.sessionRuntime();
        result.cancel_flag = self.cancel;
        result.permission_mode = self.admission.permission_mode;
        result.permission_grants = self.admission.grants;
        result.session_grants = self.admission.grants;
        result.permission_rules = self.admission.rules;
        result.permission_state_override = &self.admission.permission_state;
        result.advertised_dynamic_tool_names = self.admission.integration_names;
        result.mcp_access = if (self.admission.mcp_view) |*view|
            .{ .scoped = .{
                .captured = view,
                .admission_authority_generation = self.admission.authority_generation,
                .live = .{ .context = self, .resolve_fn = resolveLiveMcpView },
            } }
        else
            .disabled;
        result.subagent_host = self.config.host;
        result.subagent_caller_id = self.turn.child_id;
        result.session_child_capability = self.turn.childCapability() catch null;
        result.interactive = false;
        result.output_chunk_ctx = self;
        result.on_output_chunk = pushLiveOutputChunk;
        result.background_url_ctx = self;
        result.on_background_url_ready = discardBackgroundUrl;
        result.web_search_progress_ctx = null;
        result.on_web_search_progress = null;
        result.web_fetch_progress_ctx = null;
        result.on_web_fetch_progress = null;
        result.model_capability_resolver = null;
        result.lifecycle_view = self.config.lifecycle_view;
        result.lifecycle_scope = .{
            .kind = .subagent,
            .workspace_root = result.workspace_root,
            .session_id = self.turn.child_id,
        };
        return result;
    }

    fn resolveLiveMcpView(
        raw: *anyopaque,
        alloc: Allocator,
    ) !tool_mcp_runtime.ResolvedLiveView {
        const self: *Context = @ptrCast(@alignCast(raw));
        var authority = try self.turn.resolveLiveAuthority(alloc);
        defer authority.deinit(alloc);
        const view = authority.mcp_view orelse return error.McpRuntimeUnavailable;
        authority.mcp_view = null;
        return .{
            .authority_generation = mcp_access.authorityGeneration(view),
            .action_authority_generation = authority.generation,
            .view = view,
        };
    }
};

pub fn run(
    config: Config,
    turn: *execution.TurnContext,
    message: domain.QueuedMessage,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    var arena_state = std.heap.ArenaAllocator.init(turn.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var routed_credential: ?credentials.Credential = null;
    defer if (routed_credential) |*credential| credential.deinit(turn.alloc);
    var routed_config = config;
    const route = config.provider_routes.select(admission.provider);
    routed_config.tool_context.agent_stream_provider = route.agent_stream_provider;
    routed_config.tool_context.permission_reviewer_provider = route.permission_reviewer_provider;
    routed_config.tool_context.auto_classifier = auto_classifier.Classifier.disabled();
    if (!model_provider.authorizesCredential(
        admission.provider,
        config.tool_context.credential_source,
    )) {
        const resolution = credentials.resolveForProvider(
            turn.alloc,
            config.tool_context.oauth_transport,
            config.tool_context.secret_store,
            .refresh_if_needed,
            admission.provider,
            config.tool_context.credential_source,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            turn.setFailureDiagnostic("model_credential_resolution_failed", @errorName(err)) catch
                return error.OutOfMemory;
            return error.ProviderFailed;
        };
        routed_credential = resolution.credential;
        const credential = if (routed_credential) |*value| value else {
            turn.setFailureDiagnostic("model_credential_missing", admission.model) catch
                return error.OutOfMemory;
            return error.ProviderFailed;
        };
        routed_config.tool_context.api_key = credential.token;
        routed_config.tool_context.gateway_team = credential.gatewayTeam();
        routed_config.tool_context.credential_source = credential.source;
        routed_config.tool_context.account_id = credential.accountId();
    }
    routed_config.tool_context.model = admission.model;
    routed_config.tool_context.provider = admission.provider;
    if (!model_provider.usesGatewayAuxiliaries(admission.provider)) {
        routed_config.tool_context.web_search_backend = null;
        routed_config.tool_context.web_search_runtime_ready = false;
    }
    var context = Context{
        .config = routed_config,
        .turn = turn,
        .admission = admission,
        .cancel = cancel,
    };
    const history = turn.sessionRuntime().snapshotHistory(arena) catch return error.OutOfMemory;
    const recovery_checkpoint = turn.snapshotRecoveryCheckpoint(arena) catch
        return error.OutOfMemory;
    const prompt = worker_runtime.QueuedPrompt{
        .turn_id = 1,
        .prompt = arena.dupe(u8, message.content) catch return error.OutOfMemory,
        .images = &.{},
        .model = arena.dupe(u8, admission.model) catch return error.OutOfMemory,
        .provider = admission.provider,
        .api_key = arena.dupe(u8, routed_config.tool_context.api_key) catch return error.OutOfMemory,
        .gateway_team = if (routed_config.tool_context.gateway_team) |team|
            arena.dupe(u8, team) catch return error.OutOfMemory
        else
            null,
        .credential_source = routed_config.tool_context.credential_source,
        .account_id = if (routed_config.tool_context.account_id) |account_id|
            arena.dupe(u8, account_id) catch return error.OutOfMemory
        else
            null,
        .permission_mode = admission.permission_mode,
        .history = history,
        .root_user_intent_context = if (message.root_user_intent_context.len > 0)
            arena.dupe(u8, message.root_user_intent_context) catch return error.OutOfMemory
        else
            &.{},
        .grants = types.dupePermissionGrantSlice(arena, admission.grants) catch return error.OutOfMemory,
        .agent_settings = .{
            .max_tool_result_bytes = config.tool_context.max_tool_result_bytes,
            .first_call_tool_choice = config.tool_context.first_call_tool_choice,
            .fast_mode = config.tool_context.fast_mode,
            .effort = admission.effort,
        },
        .recovery_checkpoint = recovery_checkpoint,
        .recovery_source_already_presented = recovery_checkpoint != null,
    };
    const deps = runtimeDeps(&context);
    execution.runNormalAgentTurn(
        &deps,
        null,
        .{
            .view = config.lifecycle_view,
            .scope = .{
                .kind = .subagent,
                .workspace_root = config.tool_context.workspace_root,
                .session_id = turn.child_id,
            },
            .outcome_allocator = turn.alloc,
        },
        .{
            .system_prompt = config.system_prompt,
            .model_prompt_overlay = config.model_prompt_overlay,
            .skills_prompt_section = config.skills_prompt_section,
            .explicit_skills_prompt_section = config.explicit_skills_prompt_section,
            .gateway_retry_count = config.tool_context.gateway_retry_count,
            .gateway_chat_url = config.tool_context.gateway_chat_url,
            .gateway_tools_json = config.gateway_tools_json,
            .custom_tool_guidance = config.custom_tool_guidance,
            .agent_step_limit = config.tool_context.agent_step_limit,
            .max_tool_result_bytes = config.tool_context.max_tool_result_bytes,
            .cancel_flag = cancel,
            .fast_mode = config.tool_context.fast_mode,
            .effort = admission.effort,
            .first_call_tool_choice = config.tool_context.first_call_tool_choice,
            .workspace_root = config.tool_context.workspace_root,
            .access_scope = config.tool_context.access_scope,
            .origin = .subagent,
            .root_user_intent_context = prompt.root_user_intent_context,
            .root_user_messages = message.root_user_messages,
            .root_user_evidence_complete = message.root_user_evidence_complete,
            .session_child_capability = turn.childCapability() catch null,
            .context_limits = config.tool_context.context_limits,
        },
        prompt,
    ) catch |err| {
        const mapped: execution.ServiceError = switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            else => error.ProviderFailed,
        };
        if (mapped != error.OutOfMemory) {
            turn.setFailureDiagnostic("agent_turn_failed", @errorName(err)) catch
                return error.OutOfMemory;
        }
        return mapped;
    };
    return if (context.turn_outcome == .paused) .paused else .completed;
}

fn runtimeDeps(context: *Context) agent_runtime.AgentRuntimeDeps {
    return .{
        .ctx = context,
        .agent_stream_provider = context.config.tool_context.agent_stream_provider,
        .tool_registry = context.config.tool_context.tool_registry,
        .context_registry = context.config.context_registry,
        .context_enabled = context.config.context_enabled,
        .finalize_turn = finalizeTurn,
        .live_tool_authority = context.turn.liveToolAuthorityProvider(),
        .tool_activity_recorder = context.turn.toolActivityRecorder(),
        .prepare_parent_turn_context = prepareParentTurnContext,
        .acknowledge_parent_turn_context = acknowledgeParentTurnContext,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermission,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermission,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolAction,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = executeToolCall,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .propagate_history_turn = propagateHistoryTurn,
        .recovery_checkpoint = .{
            .set = setRecoveryCheckpoint,
        },
        .propagate_grant = discardGrant,
        .push_event = pushLiveEvent,
        .push_text = pushLiveText,
        .push_tool_lifecycle = pushLiveToolLifecycle,
        .push_diff_block = pushLiveDiff,
        .push_system_notice = pushLiveNotice,
        .push_route_recovery_status = pushLiveRouteRecoveryStatus,
        .push_command_output_complete = pushLiveCommandOutputComplete,
        .push_http_error = captureHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .format_tool_execution_error = formatToolExecutionError,
        .report_usage = reportUsage,
        .usage = &context.turn.sessionRuntime().usage,
        .usage_allocator = context.turn.alloc,
    };
}

fn refreshGatewayCredential(
    raw: *anyopaque,
    alloc: Allocator,
    source: types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    return auth_runtime.refreshCredentialTokenForAccount(
        context.config.tool_context.oauth_transport,
        alloc,
        source,
        mode,
        expected_account_id,
    );
}

fn finalizeTurn(
    raw: *anyopaque,
    _: u64,
    outcome: types.TurnPresentationOutcome,
    _: ?types.ProviderCompletionDisposition,
) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    context.turn_outcome = outcome;
}

fn prepareParentTurnContext(
    raw: *anyopaque,
    arena: Allocator,
) !?agent_runtime.PreparedParentTurnContext {
    const context: *Context = @ptrCast(@alignCast(raw));
    const child_id = context.turn.child_id orelse return null;
    return parent_delivery_projector.prepare(
        arena,
        context.config.host.sessions,
        child_id,
        context.config.host.manager.options.child_store,
    );
}

fn acknowledgeParentTurnContext(
    raw: *anyopaque,
    arena: Allocator,
    acknowledgements: []const agent_runtime.ParentTurnDeliveryAck,
) void {
    const context: *Context = @ptrCast(@alignCast(raw));
    const retirement_ready = parent_delivery_projector
        .acknowledgeWithRetirementSignal(
        arena,
        context.config.host.sessions,
        context.config.host.manager.options.child_store,
        acknowledgements,
    );
    if (retirement_ready) {
        context.config.host.requestRetirementSweep(io_mod.milliTimestamp());
    }
}

fn appendRuntimeContext(raw: *anyopaque, arena: Allocator, messages: *std.ArrayList(types.ChatMessage)) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = context.toolContext();
    try context.config.context_registry.appendDefaultTransient(.{
        .workspace_root = tool_ctx.workspace_root,
        .access_scope = tool_ctx.access_scope,
        .interactive = false,
        .permission_mode = context.admission.permission_mode,
        .tracker = null,
        .background = tool_ctx.background,
        .session = context.turn.sessionRuntime(),
    }, arena, messages);
}

fn appendStaticContext(raw: *anyopaque, arena: Allocator, messages: *std.ArrayList(types.ChatMessage)) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    try context.config.context_registry.appendDefaultStatic(.{
        .project_context = context.config.project_context,
    }, arena, messages);
    var snapshot = try snapshotModelCatalogForView(
        arena,
        if (context.admission.mcp_view) |*view| view else null,
    );
    defer snapshot.deinit(arena);
    const section = try model_catalog.render(arena, snapshot);
    if (section.text.len > 0) {
        try messages.append(arena, .{ .role = .system, .content = section.text });
    }
    if (section.notice) |notice| try pushLiveNotice(raw, notice);
}

fn snapshotModelCatalogForView(
    alloc: Allocator,
    maybe_view: ?*const mcp_access.View,
) !model_catalog.Snapshot {
    const view = maybe_view orelse return model_catalog.Snapshot.empty(alloc);
    const servers = try alloc.alloc(model_catalog.ServerSummary, view.servers.len);
    var initialized: usize = 0;
    errdefer {
        for (servers[0..initialized]) |server| alloc.free(server.name);
        alloc.free(servers);
    }
    for (view.servers, 0..) |server, index| {
        var tool_count: usize = 0;
        for (view.tools) |tool| {
            if (std.mem.eql(u8, tool.server_name, server.name)) tool_count += 1;
        }
        servers[index] = .{
            .name = try alloc.dupe(u8, server.name),
            .availability = .ready,
            .tool_count = tool_count,
        };
        initialized += 1;
    }
    return .{ .servers = servers };
}

test "subagent model catalog counts only tools in the captured MCP view" {
    const alloc = std.testing.allocator;
    var servers = [_]mcp_access.ServerIdentity{.{
        .name = @constCast("chrome-devtools"),
        .source = .profile,
        .scope = .profile,
        .connection_generation = 1,
        .catalog_generation = 2,
        .auth_generation = 3,
    }};
    var tools = [_]mcp_access.ToolIdentity{
        .{ .name = @constCast("mcp_chrome_one"), .server_name = @constCast("chrome-devtools") },
        .{ .name = @constCast("mcp_chrome_two"), .server_name = @constCast("chrome-devtools") },
    };
    const view = mcp_access.View{
        .runtime_generation = 1,
        .owner_id = @constCast("child"),
        .parent_id = @constCast("parent"),
        .features_visible = false,
        .servers = &servers,
        .tools = &tools,
    };

    var snapshot = try snapshotModelCatalogForView(alloc, &view);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), snapshot.servers.len);
    try std.testing.expectEqualStrings("chrome-devtools", snapshot.servers[0].name);
    try std.testing.expectEqual(model_catalog.Availability.ready, snapshot.servers[0].availability);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.servers[0].tool_count);
}

fn validateToolCall(raw: *anyopaque, arena: Allocator, call: types.ToolCall) !agent_runtime.ToolCallValidationResult {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.validateToolCall(context.toolContext(), arena, call);
}

fn checkToolAvailability(raw: *anyopaque, arena: Allocator, call: types.ToolCall) !?[]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.checkToolAvailability(context.toolContext(), arena, call);
}

fn admissionContext(
    context: *Context,
    dynamic_names: []const []const u8,
    review: ?auto_classifier.ReviewTurnContext,
) tool_runtime.Context {
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(context.toolContext(), dynamic_names);
    tool_ctx.permission_review_turn = review;
    tool_ctx.permission_prompter = context.turn.permissionPrompter();
    return tool_ctx;
}

fn requestToolPermission(
    raw: *anyopaque,
    arena: Allocator,
    call: types.ToolCall,
    review: auto_classifier.ReviewTurnContext,
    mode: types.PermissionMode,
    grants: []const types.PermissionGrant,
    live: ?agent_runtime.LiveToolAuthority,
    revalidation: ?agent_runtime.LivePermissionRevalidation,
    dynamic_names: []const []const u8,
) !command_admission.PermissionOutcome {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = admissionContext(context, dynamic_names, review);
    if (revalidation) |request| return switch (request) {
        .action => |action| tool_admission.revalidateLiveActionPermissionOutcome(
            tool_ctx.admissionInputWithLiveAuthority(live),
            arena,
            call,
            mode,
            grants,
            action.authority,
            action.human_approval,
        ),
    };
    return tool_admission.requestPermissionOutcome(
        tool_ctx.admissionInputWithLiveAuthority(live),
        arena,
        call,
        mode,
        grants,
    );
}

fn requestPreparedFileMutationPermission(
    raw: *anyopaque,
    arena: Allocator,
    call: types.ToolCall,
    prepared: *tool_admission.PreparedFileMutationCall,
    review: auto_classifier.ReviewTurnContext,
    mode: types.PermissionMode,
    grants: []const types.PermissionGrant,
    live: ?agent_runtime.LiveToolAuthority,
    dynamic_names: []const []const u8,
) !command_admission.PermissionOutcome {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = admissionContext(context, dynamic_names, review);
    return tool_admission.requestPreparedFileMutationPermissionOutcome(
        tool_ctx.admissionInputWithLiveAuthority(live),
        arena,
        call,
        prepared,
        mode,
        grants,
    );
}

fn describeToolAction(raw: *anyopaque, arena: Allocator, call: types.ToolCall, file_path: ?[]const u8, _: []const []const u8) ![]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = context.config.tool_context.tool_registry,
        .call = call,
        .workspace_root = context.config.tool_context.workspace_root,
        .display_target = file_path,
    });
}

fn resolveToolActionDisplayTarget(raw: *anyopaque, arena: Allocator, call: types.ToolCall) !?[]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_presentation.resolveTerminalDisplayTarget(
        arena,
        context.config.tool_context.tool_registry,
        context.config.tool_context.workspace_root,
        context.config.tool_context.terminal_client,
        call,
    );
}

fn describeToolActionDenied(raw: *anyopaque, arena: Allocator, call: types.ToolCall, file_path: ?[]const u8, label: []const u8, dynamic_names: []const []const u8) ![]const u8 {
    const action = try describeToolAction(raw, arena, call, file_path, dynamic_names);
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ label, action });
}

fn permissionTargetForCall(raw: *anyopaque, arena: Allocator, call: types.ToolCall, dynamic_names: []const []const u8) ![]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(context.toolContext(), dynamic_names);
    return tool_admission.permissionTargetForLiveAuthority(
        tool_ctx.admissionInput(),
        arena,
        call,
    );
}

fn executeToolCall(raw: *anyopaque, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
    const context: *Context = @ptrCast(@alignCast(raw));
    var tool_ctx = context.toolContext();
    tool_ctx.root_user_intent_context = request.root_user_intent_context;
    tool_ctx.root_user_messages = request.root_user_messages;
    tool_ctx.root_user_evidence_complete = request.root_user_evidence_complete;
    return tool_runtime.executeToolCallAuthorized(tool_ctx, request);
}

fn propagateHistoryTurn(raw: *anyopaque, turn: types.HistoryTurn) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    try context.turn.commit(
        context.turn.active_work_id orelse return error.StaleWork,
        turn,
        context.input_tokens,
        context.output_tokens,
        io_mod.milliTimestamp(),
    );
}

fn setRecoveryCheckpoint(
    raw: *anyopaque,
    checkpoint: session_codec.RecoveryCheckpoint,
) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    try context.turn.setRecoveryCheckpoint(checkpoint, io_mod.milliTimestamp());
}

fn reportUsage(raw: *anyopaque, usage: types.Usage) void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (usage.input_tokens) |value| context.input_tokens = value;
    if (usage.output_tokens) |value| context.output_tokens = value;
}

fn publishCommittedFileHandoff(_: *anyopaque, _: file_mutation.CommittedFileHandoff) agent_runtime.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn formatToolExecutionError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return tool_result_errors.formatToolExecutionErrorJson(arena, tool_name, err);
}

fn discardGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}
fn pushLiveText(raw: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    switch (emission) {
        .assistant_source => {},
        .assistant_rendered => |text| context.turn.appendLiveText(text),
        .operational => |text| context.turn.appendLiveText(text),
    }
}
fn pushLiveNotice(raw: *anyopaque, text: []const u8) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    context.turn.appendLiveText(text);
}

fn pushLiveToolLifecycle(
    raw: *anyopaque,
    event: types.ToolLifecycleEvent,
) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    context.turn.appendLiveEvent(.{ .tool_lifecycle = event });
}

fn pushLiveDiff(
    raw: *anyopaque,
    payload: agent_runtime.DiffEntryPayload,
) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    context.turn.appendLiveEvent(.{ .diff_block = payload });
}

fn pushLiveCommandOutputComplete(
    raw: *anyopaque,
    lifecycle_id: ?types.ToolLifecycleId,
) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    context.turn.appendLiveEvent(.{
        .command_output_complete = lifecycle_id,
    });
}

fn pushLiveRouteRecoveryStatus(
    raw: *anyopaque,
    status: types.RouteRecoveryStatus,
) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    context.turn.appendLiveEvent(.{ .route_recovery_status = status });
}

fn captureHttpError(
    raw: *anyopaque,
    status: std.http.Status,
    detail: []const u8,
    _: ?types.CredentialSource,
) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    const formatted = try gateway_error_format.formatHttpErrorMessage(
        context.turn.alloc,
        status,
        detail,
    );
    defer context.turn.alloc.free(formatted);
    const redacted = try execution_memory.redactText(context.turn.alloc, formatted);
    defer context.turn.alloc.free(redacted);
    try context.turn.setFailureDiagnostic("provider_http_error", redacted);
}

fn pushLiveEvent(raw: *anyopaque, event: worker_runtime.WorkerEvent) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    context.turn.appendLiveEvent(event);
    worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
}

fn pushLiveOutputChunk(
    raw: *anyopaque,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: command_output_content.Stream,
    text: []const u8,
) anyerror!void {
    const context: *Context = @ptrCast(@alignCast(raw));
    context.turn.appendLiveEvent(.{ .command_output = .{
        .lifecycle_id = lifecycle_id,
        .stream = stream,
        .text = @constCast(text),
    } });
}
fn discardBackgroundUrl(_: *anyopaque, _: u64, _: []const u8) void {}
