const std = @import("std");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const provider_set = @import("../gateway/provider_set.zig");
const auto_classifier = @import("../permissions/auto_classifier.zig");
const command_admission = @import("../permissions/command_admission.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const model_catalog = @import("../mcp/model_catalog.zig");
const context_contract = @import("../workspace/context_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const execution_memory = @import("../agent/execution_memory.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const types = @import("../shared/types.zig");
const diff_mod = @import("../output/diff.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const profiles = @import("../profiles/profiles.zig");
const authority_mod = @import("authority.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_host = @import("tool_host.zig");
const child_state = @import("child_state.zig");

const Allocator = std.mem.Allocator;

// A parent disable caps resumed children too; durable child opt-ins cannot bypass it.
fn childUltrafastMode(parent_requested: bool, child_preference: bool) bool {
    return parent_requested and child_preference;
}

test "Ultrafast parent disable caps durable child opt-ins" {
    try std.testing.expect(childUltrafastMode(true, true));
    try std.testing.expect(!childUltrafastMode(false, true));
    try std.testing.expect(!childUltrafastMode(true, false));
    try std.testing.expect(!childUltrafastMode(false, false));
}

fn childModelCapabilityResolver(
    parent: ?model_capabilities.Resolver,
) ?model_capabilities.Resolver {
    return parent;
}

pub const Config = struct {
    host: *tool_host.Runtime,
    tool_context: tool_runtime.Context,
    provider_set: provider_set.Set,
    system_prompt: []const u8,
    model_prompt_overlay: ?[]const u8 = null,
    skill_catalog: skill_invocation.Catalog = .{ .skills = &.{} },
    advertised_tool_names: []const []const u8 = &.{},
    advertised_functions: []const model_tool_schema.FunctionSchema = &.{},
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
    subagent_id: u64,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    turn_outcome: ?types.TurnPresentationOutcome = null,
    refreshed_credential: ?credentials.Credential = null,

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
        result.web_search_progress_ctx = null;
        result.on_web_search_progress = null;
        result.web_fetch_progress_ctx = null;
        result.on_web_fetch_progress = null;
        result.model_capability_resolver = childModelCapabilityResolver(
            result.model_capability_resolver,
        );
        result.lifecycle_view = self.config.lifecycle_view;
        result.lifecycle_scope = .{
            .kind = .subagent,
            .workspace_root = result.workspace_root,
            .session_id = self.turn.child_id,
            .subagent_id = self.subagent_id,
        };
        return result;
    }

    fn resolveLiveMcpView(
        raw: *anyopaque,
        alloc: Allocator,
    ) !tool_mcp_runtime.ResolvedLiveView {
        const self: *Context = @ptrCast(@alignCast(raw));
        var authority = try self.turn.resolveLiveAuthority(alloc);
        return execution.liveMcpViewFrom(alloc, &authority);
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
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();
    var routed_credential: ?credentials.Credential = null;
    defer if (routed_credential) |*credential| credential.deinit(turn.alloc);
    var routed_config = config;
    const provider = config.provider_set.select(admission.provider);
    routed_config.tool_context.agent_stream_provider = provider.agent_stream_or_unavailable();
    routed_config.tool_context.permission_reviewer_provider = provider.permission_reviewer;
    routed_config.tool_context.auto_classifier = auto_classifier.Classifier.disabled();
    if (admission.provider == .configured or !model_provider.authorizesCredential(
        admission.provider,
        config.tool_context.credential_source,
    )) {
        routed_credential = auth_runtime.prepareCredential(
            turn.alloc,
            config.tool_context.oauth_transport,
            config.tool_context.secret_store,
            admission.provider,
            config.tool_context.credential_source,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            turn.setFailureDiagnostic("model_credential_resolution_failed", @errorName(err));
            return error.ProviderFailed;
        };
        const credential = if (routed_credential) |*value| value else {
            turn.setFailureDiagnostic("model_credential_missing", admission.model);
            return error.ProviderFailed;
        };
        routed_config.tool_context.api_key = credential.token;
        routed_config.tool_context.gateway_team = credential.gatewayTeam();
        routed_config.tool_context.credential_source = credential.source;
        routed_config.tool_context.account_id = credential.accountId();
    }
    const ultrafast_mode = childUltrafastMode(config.tool_context.ultrafast_mode, admission.ultrafast_mode);
    routed_config.tool_context.model = admission.model;
    routed_config.tool_context.provider = admission.provider;
    routed_config.tool_context.ultrafast_mode = ultrafast_mode;
    routed_config.tool_context.provider_capabilities = config.provider_set.select(admission.provider).capabilities;
    debug_trace.logf(
        "subagent",
        "child turn routed child_id={s} provider={s} model={s} effort={s}",
        .{
            turn.child_id orelse "unknown",
            @tagName(admission.provider),
            admission.model,
            admission.effort.label(),
        },
    );
    if (!routed_config.tool_context.provider_capabilities.fx_search) {
        routed_config.tool_context.web_search_backend = null;
        routed_config.tool_context.web_search_runtime_ready = false;
    }
    const trace_context = debug_trace.TraceContext{
        .turn_id = debug_trace.nextTurnId(),
        .subagent_id = debug_trace.nextSubagentId(),
    };
    if (!turn.workerRuntime().beginDirectProcessing(trace_context.turn_id)) {
        return error.ProviderFailed;
    }
    defer turn.workerRuntime().finishProcessing();
    var context = Context{
        .config = routed_config,
        .turn = turn,
        .admission = admission,
        .cancel = cancel,
        .subagent_id = trace_context.subagent_id,
    };
    defer if (context.refreshed_credential) |*credential| credential.deinit(turn.alloc);
    turn.beginTurn() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        turn.setFailureDiagnostic("turn_open_failed", @errorName(err));
        return error.ProviderFailed;
    };
    const history = turn.sessionRuntime().snapshotHistory(arena) catch return error.OutOfMemory;
    const prompt = worker_runtime.QueuedPrompt{
        .turn_id = trace_context.turn_id,
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
        .unversioned_history_count = turn.sessionRuntime().unversionedHistoryEnd(),
        .root_user_intent_context = if (message.root_user_intent_context.len > 0)
            arena.dupe(u8, message.root_user_intent_context) catch return error.OutOfMemory
        else
            &.{},
        .grants = types.dupePermissionGrantSlice(arena, admission.grants) catch return error.OutOfMemory,
        .agent_settings = .{
            .max_tool_result_bytes = config.tool_context.max_tool_result_bytes,
            .auto_compact_percent = config.tool_context.auto_compact_percent,
            .first_call_tool_choice = config.tool_context.first_call_tool_choice,
            .fast_mode = config.tool_context.fast_mode,
            .ultrafast_mode = ultrafast_mode,
            .effort = admission.effort,
            .provider_order = if (admission.provider == .gateway) config.tool_context.provider_order else &.{},
            .provider_strict = admission.provider == .gateway and config.tool_context.provider_strict,
        },
    };
    // The profile the child started in, cached when its admission resolved.
    // The child is shown only the built-in tools it allows, the ones its live
    // authority lets it call.
    const profile = childProfile(turn.live_authority, turn.child_id);
    const child_tool_names = try childToolNames(
        arena,
        config.advertised_tool_names,
        config.tool_context.tool_registry,
        .{ .profile = profile },
    );
    const child_functions = try childFunctions(
        arena,
        config.advertised_functions,
        config.tool_context.tool_registry,
        .{ .profile = profile },
    );
    // This engine never gives a child subagents of its own, so main
    // started every child it runs.
    const child_system_prompt = childSystemPrompt(
        arena,
        profile,
        config.system_prompt,
        .{ .name = turn.child_name orelse turn.child_id orelse "subagent", .parent = profiles.main_name },
        message.system_prompt_overlay,
    ) catch return error.OutOfMemory;
    debug_trace.eventf(
        "subagent",
        "trace_identity",
        trace_context,
        "child_id={s} parent_id={s} work_id={s}",
        .{
            turn.child_id orelse "unknown",
            admission.parent_id,
            turn.active_work_id orelse "unknown",
        },
    );
    const deps = runtimeDeps(&context);
    agent_runtime.processAgentPrompt(
        &turn.sessionRuntime().agent,
        &deps,
        null,
        .{
            .view = config.lifecycle_view,
            .scope = .{
                .kind = .subagent,
                .workspace_root = config.tool_context.workspace_root,
                .session_id = turn.child_id,
                .subagent_id = trace_context.subagent_id,
            },
            .outcome_allocator = turn.alloc,
        },
        .{
            .system_prompt = child_system_prompt,
            .model_prompt_overlay = config.model_prompt_overlay,
            .skill_catalog = config.skill_catalog,
            .gateway_retry_count = config.tool_context.gateway_retry_count,
            .gateway_chat_url = config.tool_context.gateway_chat_url,
            .advertised_tool_names = child_tool_names,
            .advertised_functions = child_functions,
            .provider_capabilities = config.provider_set.select(admission.provider).capabilities,
            .custom_tool_guidance = config.custom_tool_guidance,
            .agent_step_limit = config.tool_context.agent_step_limit,
            .max_tool_result_bytes = config.tool_context.max_tool_result_bytes,
            .auto_compact_percent = config.tool_context.auto_compact_percent,
            .cancel_flag = cancel,
            .fast_mode = config.tool_context.fast_mode,
            .ultrafast_mode = ultrafast_mode,
            .effort = admission.effort,
            .provider_order = if (admission.provider == .gateway) config.tool_context.provider_order else &.{},
            .provider_strict = admission.provider == .gateway and config.tool_context.provider_strict,
            .first_call_tool_choice = config.tool_context.first_call_tool_choice,
            .workspace_root = config.tool_context.workspace_root,
            .access_scope = config.tool_context.access_scope,
            .origin = .subagent,
            .root_user_intent_context = prompt.root_user_intent_context,
            .root_user_messages = message.root_user_messages,
            .root_user_evidence_complete = message.root_user_evidence_complete,
            .session_child_capability = turn.childCapability() catch null,
            .subagent_id = trace_context.subagent_id,
            .context_limits = config.tool_context.context_limits,
        },
        prompt,
    ) catch |err| {
        const mapped: execution.ServiceError = switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            else => error.ProviderFailed,
        };
        turn.setFailureDiagnostic("agent_turn_failed", @errorName(err));
        debug_trace.eventf("subagent", "child_execution_failed", trace_context, "child_id={s} err={s}", .{ turn.child_id orelse "unknown", @errorName(err) });
        return mapped;
    };
    return finalRunOutcome(context.turn_outcome);
}

fn finalRunOutcome(outcome: ?types.TurnPresentationOutcome) error{ProviderFailed}!execution.RunOutcome {
    return switch (outcome orelse return error.ProviderFailed) {
        .completed => .completed,
        .failed => error.ProviderFailed,
        .interrupted, .paused => .paused,
    };
}

test "subagent finalization preserves every outcome and fails closed on absence" {
    const cases = [_]struct {
        outcome: ?types.TurnPresentationOutcome,
        expected: error{ProviderFailed}!execution.RunOutcome,
    }{
        .{ .outcome = .completed, .expected = .completed },
        .{ .outcome = .failed, .expected = error.ProviderFailed },
        .{ .outcome = .interrupted, .expected = .paused },
        .{ .outcome = .paused, .expected = .paused },
        .{ .outcome = null, .expected = error.ProviderFailed },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, finalRunOutcome(case.outcome));
    }
}

/// The profile child `child_id` started in, cached when its admission resolved.
pub fn childProfile(resolver: ?*authority_mod.Resolver, child_id: ?[]const u8) ?*const profiles.Profile {
    const value = resolver orelse return null;
    const cache = value.profiles orelse return null;
    return cache.find(child_id orelse return null);
}

/// Who a subagent is, for its system prompt: its own name, and the name of
/// the agent that started it, `main` unless that is another subagent.
pub const Role = struct { name: []const u8, parent: []const u8 };

/// A child's system prompt: `base`, or its profile's prompt in its place or
/// added to it, then what it is and who started it, whatever its profile,
/// then the run's `<subagent_instructions>` overlay.
pub fn childSystemPrompt(
    alloc: Allocator,
    profile: ?*const profiles.Profile,
    base: []const u8,
    role: Role,
    overlay: []const u8,
) Allocator.Error![]const u8 {
    const base_prompt = if (profile) |value| try profiles.systemPrompt(alloc, value, base) else base;
    const with_role = try alloc.print(
        "{s}\n\n<subagent_role>\nYou are the subagent \"{s}\", started by \"{s}\". When work it gives you " ++
            "ends, your output reaches it on its own as your report. To message it sooner, for example when the " ++
            "user asks you to tell {s} something, call the subagent tool with action \"message\" and agent " ++
            "\"parent\", if you have that tool.\n</subagent_role>",
        .{ base_prompt, role.name, role.parent, role.parent },
    );
    if (overlay.len == 0) return with_role;
    return alloc.print(
        "{s}\n\n<subagent_instructions>\n{s}\n</subagent_instructions>",
        .{ with_role, overlay },
    );
}

/// Which built-in tools a child is shown. MCP and dynamic tools follow its
/// integrations instead.
pub const Shown = union(enum) {
    /// The old engine's: the ones its profile allows, never `subagent`,
    /// because it has no host for a child's own subagents.
    profile: ?*const profiles.Profile,
    /// The interactive app's: the ones its run was admitted with, its
    /// parent's narrowed by its profile, so it is never shown a tool its
    /// parent lacks. `subagent` is among them
    /// only once it has its own host to start subagents on.
    admitted: struct { tools: []const []const u8, starts_subagents: bool },
};

fn childSees(registry: tool_dispatch.Registry, shown: Shown, name: []const u8) bool {
    const subagent = std.mem.eql(u8, name, "subagent");
    switch (shown) {
        .profile => |profile| {
            if (subagent) return false;
            const value = profile orelse return true;
            if (registry.lookup(name) == null) return true;
            return profiles.allowsTool(value, name);
        },
        .admitted => |admitted| {
            if (subagent and !admitted.starts_subagents) return false;
            if (registry.lookup(name) == null) return true;
            for (admitted.tools) |tool| if (std.mem.eql(u8, tool, name)) return true;
            return false;
        },
    }
}

pub fn childToolNames(
    alloc: Allocator,
    names: []const []const u8,
    registry: tool_dispatch.Registry,
    shown: Shown,
) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (names) |name| if (childSees(registry, shown, name)) try kept.append(alloc, name);
    return kept.items;
}

pub fn childFunctions(
    alloc: Allocator,
    functions: []const model_tool_schema.FunctionSchema,
    registry: tool_dispatch.Registry,
    shown: Shown,
) ![]const model_tool_schema.FunctionSchema {
    var kept: std.ArrayList(model_tool_schema.FunctionSchema) = .empty;
    for (functions) |function| if (childSees(registry, shown, function.name)) try kept.append(alloc, function);
    return kept.items;
}

fn runtimeDeps(context: *Context) agent_runtime.AgentRuntimeDeps {
    return .{
        .ctx = context,
        .observer = context.config.tool_context.observer,
        .agent_stream_provider = context.config.tool_context.agent_stream_provider,
        .tool_registry = context.config.tool_context.tool_registry,
        .context_registry = context.config.context_registry,
        .context_enabled = context.config.context_enabled,
        .available_model_capabilities = availableModelCapabilities,
        .resolve_model_capabilities = resolveModelCapabilities,
        .finalize_turn = finalizeTurn,
        .take_steering_boundary = takeChildSteeringBoundary,
        .release_agent_terminal_lease = releaseAgentTerminalLease,
        .live_tool_authority = context.turn.liveToolAuthorityProvider(),
        .tool_activity_recorder = context.turn.toolActivityRecorder(),
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .snapshot_mcp_definition = snapshotMcpDefinition,
        .prepare_skill_call = prepareSkillCall,
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
        .commit_context_compaction = .{ .commit = commitContextCompaction },
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
        .record_usage = recordUsage,
    };
}

fn availableModelCapabilities(raw: *anyopaque, model: []const u8) model_capabilities.Capabilities {
    const context: *Context = @ptrCast(@alignCast(raw));
    const provider = context.config.provider_set.select(context.admission.provider);
    if (provider.model_catalog) |catalog| {
        if (catalog.lookupCapabilities(model)) |capabilities| return capabilities;
    }
    return model_capabilities.capabilitiesForModel(model);
}

fn resolveModelCapabilities(raw: *anyopaque, arena: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (context.cancel.load(.seq_cst)) return error.Cancelled;
    // Prefer the host's shared resolver: it waits for the provider catalog and
    // merges the loaded model cache, so gateway-hosted children resolve the
    // same capabilities as the parent. The provider bundle's synchronous
    // lookup is empty for providers that only fetch asynchronously (gateway),
    // which previously left every gateway child at "unknown" support.
    if (context.config.tool_context.model_capability_resolver) |resolver| {
        return resolver.resolve(arena, model);
    }
    return availableModelCapabilities(raw, model);
}

test "child runtime capability callbacks preserve fallback and child cancellation" {
    const catalog = @import("../gateway/model_catalog.zig");
    const authority = @import("authority.zig");
    const Fixture = struct {
        fetches: usize = 0,
        lookups: usize = 0,
        resolutions: usize = 0,

        fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
            return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
        }
        fn fetch(raw: ?*anyopaque, _: Allocator, _: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.fetches += 1;
            return .{ .failure = .{ .category = .runtime } };
        }
        fn lookup(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.lookups += 1;
            return if (std.mem.eql(u8, model, "child-model")) .{ .context_window = 32768, .max_output_tokens = 512 } else .{};
        }
        fn resolveCapabilities(raw: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.resolutions += 1;
            return if (std.mem.eql(u8, model, "child-model")) .{ .supports_vision = true, .image_input_support = .native } else .{};
        }
        fn output(_: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, _: []const u8) anyerror!void {}
    };
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const root = parent.home;
    const host = try tool_host.Runtime.create(alloc, &parent.children, .{ .resolve_fn = Fixture.resolve }, .{});
    defer host.deinit();
    const child = try parent.openChild("capability-child", &.{});
    defer child.close();
    var turn = try execution.TurnContext.init(alloc, child, 0);
    defer turn.deinit();
    var admission = try domain.captureAdmission(alloc, .{ .parent_id = parent.parent.id(), .source_id = parent.parent.id(), .model = "parent-model", .effort = .auto });
    defer admission.deinit(alloc);
    var fixture: Fixture = .{};
    var cancel = std.atomic.Value(bool).init(false);
    var parent_cancel = std.atomic.Value(bool).init(false);
    const registry = context_contract.Registry{ .default_provider = context_contract.empty_provider };
    var context = Context{
        .config = .{
            .host = host,
            .tool_context = .{
                .workspace_root = root,
                .ignored_list_entries = &.{},
                .max_list_entries = 100,
                .max_read_file_bytes = 65536,
                .max_read_file_lines = 400,
                .max_read_file_line_len = 2000,
                .max_command_output_bytes = 65536,
                .api_key = "",
                .model = "parent-model",
                .provider = .grok,
                .gateway_retry_count = 1,
                .gateway_chat_url = "",
                .agent_step_limit = 8,
                .permission_mode = .ask,
                .permission_grants = &.{},
                .permission_rules = .{},
                .worker = turn.workerRuntime(),
                .session = turn.sessionRuntime(),
                .context_registry = registry,
                .output_chunk_ctx = &fixture,
                .on_output_chunk = Fixture.output,
                .cancel_flag = &parent_cancel,
            },
            .provider_set = .{ .gateway = .{ .model_catalog = .{ .context = &fixture, .fetch_fn = Fixture.fetch } }, .codex = .{}, .grok = .{} },
            .system_prompt = "",
            .context_registry = registry,
            .context_enabled = false,
        },
        .turn = &turn,
        .admission = admission,
        .cancel = &cancel,
        .subagent_id = 1,
    };
    const deps = runtimeDeps(&context);
    const fallback = model_capabilities.capabilitiesForModel("legacy-fast");
    try std.testing.expectEqualDeep(fallback, deps.available_model_capabilities(deps.ctx, "legacy-fast"));
    try std.testing.expectEqualDeep(fallback, try deps.resolve_model_capabilities(deps.ctx, alloc, "legacy-fast"));
    context.config.provider_set.gateway.model_catalog.?.lookup_capabilities_fn = Fixture.lookup;
    const available = deps.available_model_capabilities(deps.ctx, "child-model");
    try std.testing.expectEqual(@as(?u32, 512), available.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, 32768), available.context_window);
    try std.testing.expectEqualDeep(available, try deps.resolve_model_capabilities(deps.ctx, alloc, "child-model"));
    try std.testing.expectEqualDeep(model_capabilities.Capabilities{}, deps.available_model_capabilities(deps.ctx, "unknown-fast"));
    context.config.tool_context.model_capability_resolver = .{ .ctx = &fixture, .resolve_fn = Fixture.resolveCapabilities };
    const resolved = try deps.resolve_model_capabilities(deps.ctx, alloc, "child-model");
    try std.testing.expectEqual(model_capabilities.ImageInputSupport.native, resolved.image_input_support);
    try std.testing.expectEqual(@as(usize, 1), fixture.resolutions);
    try std.testing.expectEqual(@as(?u32, 512), deps.available_model_capabilities(deps.ctx, "child-model").max_output_tokens);
    const lookups = fixture.lookups;
    cancel.store(true, .seq_cst);
    try std.testing.expectError(error.Cancelled, deps.resolve_model_capabilities(deps.ctx, alloc, "child-model"));
    try std.testing.expectEqual(lookups, fixture.lookups);
    try std.testing.expectEqual(@as(usize, 1), fixture.resolutions);
    try std.testing.expectEqual(@as(usize, 0), fixture.fetches);
}

fn takeChildSteeringBoundary(
    raw: *anyopaque,
    arena: Allocator,
    turn_id: u64,
    kind: worker_runtime.SteeringBoundaryKind,
) !worker_runtime.SteeringBoundaryResult {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (context.cancel.load(.seq_cst)) return if (kind == .cancelled) .interrupt else .none;
    return context.turn.workerRuntime().takeSteeringBoundaryInto(context.turn.alloc, arena, turn_id, kind);
}

fn releaseAgentTerminalLease(raw: *anyopaque, session_id: []const u8) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.release_agent_terminal_lease(context.toolContext(), session_id);
}

fn refreshGatewayCredential(
    raw: *anyopaque,
    alloc: Allocator,
    source: types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (mode == .if_needed and auth_runtime.requestPathCredentialVerifiedRecently(source)) {
        debug_trace.logf("auth", "credential refresh skipped source={t} reason=verified_recently", .{source});
        return null;
    }
    var refreshed = (try auth_runtime.refreshCredentialForAccount(
        context.config.tool_context.oauth_transport,
        context.turn.alloc,
        source,
        mode,
        expected_account_id,
    )) orelse return null;
    defer refreshed.deinit(context.turn.alloc);
    if (context.config.tool_context.credential_source != refreshed.source or
        !optionalCredentialFieldEqual(
            context.config.tool_context.account_id,
            refreshed.accountId(),
        ) or
        !optionalCredentialFieldEqual(
            context.config.tool_context.gateway_team,
            refreshed.gatewayTeam(),
        ))
    {
        return error.CredentialAuthorityChanged;
    }

    const worker_token = try alloc.dupe(u8, refreshed.token);
    errdefer secret.zeroAndFree(alloc, worker_token);
    if (context.refreshed_credential) |*current| current.deinit(context.turn.alloc);
    context.refreshed_credential = refreshed;
    refreshed.token = &.{};
    refreshed.account_id = null;
    refreshed.team_id = null;
    refreshed.team_slug = null;
    const current = &context.refreshed_credential.?;
    context.config.tool_context.api_key = current.token;
    context.config.tool_context.credential_source = current.source;
    context.config.tool_context.account_id = current.accountId();
    context.config.tool_context.gateway_team = current.gatewayTeam();
    return worker_token;
}

fn optionalCredentialFieldEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
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

fn appendRuntimeContext(raw: *anyopaque, arena: Allocator, messages: *std.ArrayList(types.ChatMessage)) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    const tool_ctx = context.toolContext();
    try context.config.context_registry.appendDefaultTransient(.{
        .workspace_root = tool_ctx.workspace_root,
        .access_scope = tool_ctx.access_scope,
        .interactive = false,
        .permission_mode = context.admission.permission_mode,
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
        // Generation 0: the server's list hadn't loaded when the view was
        // taken, so it starts when the subagent first needs it.
        const on_demand = tool_count == 0 and server.catalog_generation == 0;
        servers[index] = .{
            .name = try alloc.dupe(u8, server.name),
            .availability = if (on_demand) .available_on_demand else .ready,
            .tool_count = if (on_demand) null else tool_count,
        };
        initialized += 1;
    }
    return .{ .servers = servers };
}

test "subagent model catalog counts the captured view's tools and offers servers not yet listed" {
    const alloc = std.testing.allocator;
    var servers = [_]mcp_access.ServerIdentity{ .{
        .name = @constCast("chrome-devtools"),
        .source = .profile,
        .scope = .profile,
        .connection_generation = 1,
        .catalog_generation = 2,
        .auth_generation = 3,
    }, .{
        .name = @constCast("later"),
        .source = .profile,
        .scope = .profile,
        .connection_generation = 0,
        .catalog_generation = 0,
        .auth_generation = 0,
    } };
    var tools = [_]mcp_access.ToolIdentity{
        .{ .name = @constCast("mcp_chrome_one"), .server_name = @constCast("chrome-devtools") },
        .{ .name = @constCast("mcp_chrome_two"), .server_name = @constCast("chrome-devtools") },
    };
    const view = mcp_access.View{
        .runtime_generation = 1,
        .owner_id = @constCast("child"),
        .parent_id = @constCast("parent"),
        .servers = &servers,
        .tools = &tools,
    };

    var snapshot = try snapshotModelCatalogForView(alloc, &view);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), snapshot.servers.len);
    try std.testing.expectEqualStrings("chrome-devtools", snapshot.servers[0].name);
    try std.testing.expectEqual(model_catalog.Availability.ready, snapshot.servers[0].availability);
    try std.testing.expectEqual(@as(?usize, 2), snapshot.servers[0].tool_count);
    // A server whose list hadn't loaded is offered, not shown as empty.
    try std.testing.expectEqual(model_catalog.Availability.available_on_demand, snapshot.servers[1].availability);
    try std.testing.expectEqual(@as(?usize, null), snapshot.servers[1].tool_count);
}

test "subagent inherits model capabilities" {
    const ResolverFixture = struct {
        fn resolve(
            _: *anyopaque,
            _: Allocator,
            _: []const u8,
        ) model_capabilities.ResolveError!model_capabilities.Capabilities {
            return .{};
        }
    };
    var resolver_context: u8 = 0;
    const resolver = model_capabilities.Resolver{
        .ctx = &resolver_context,
        .resolve_fn = ResolverFixture.resolve,
    };
    const inherited = childModelCapabilityResolver(resolver);
    try std.testing.expect(inherited != null);
    try std.testing.expectEqual(resolver.ctx, inherited.?.ctx);
    try std.testing.expectEqual(resolver.resolve_fn, inherited.?.resolve_fn);
}

fn snapshotMcpDefinition(raw: *anyopaque, arena: Allocator, name: []const u8, known: tool_mcp_runtime.Binding) !tool_mcp_runtime.DefinitionSnapshot {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.snapshotMcpDefinition(context.toolContext(), arena, name, known);
}

fn validateToolCall(raw: *anyopaque, arena: Allocator, call: types.ToolCall) !agent_runtime.ToolCallValidationResult {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.validateToolCall(context.toolContext(), arena, call);
}

fn checkToolAvailability(raw: *anyopaque, arena: Allocator, call: types.ToolCall) !?[]const u8 {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.checkToolAvailability(context.toolContext(), arena, call);
}

fn prepareSkillCall(raw: *anyopaque, arena: Allocator, call: types.ToolCall, locations: ?*const skill_contract.Locations) !skill_contract.CallPreparation {
    const context: *Context = @ptrCast(@alignCast(raw));
    return tool_runtime.prepareSkillCall(context.toolContext(), arena, call, locations);
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
    mcp_review_schema_json: ?[]const u8,
) !command_admission.PermissionOutcome {
    const context: *Context = @ptrCast(@alignCast(raw));
    var tool_ctx = admissionContext(context, dynamic_names, review);
    tool_ctx.mcp_review_schema_json = mcp_review_schema_json;
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
        context.config.tool_context.managed_executions,
        call,
    );
}

fn describeToolActionDenied(raw: *anyopaque, arena: Allocator, call: types.ToolCall, file_path: ?[]const u8, label: []const u8, dynamic_names: []const []const u8) ![]const u8 {
    const action = try describeToolAction(raw, arena, call, file_path, dynamic_names);
    return arena.print("{s}: {s}", .{ label, action });
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
    try context.turn.commit(context.turn.active_work_id orelse return error.StaleWork, turn);
}

fn commitContextCompaction(
    raw: *anyopaque,
    summary: types.CompactedSummaryHistoryTurn,
    active_prefix: ?types.AssistantHistoryTurn,
    retained_from: ?types.ContextHistoryCut,
) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    try context.turn.commitContextCompaction(summary, active_prefix, retained_from);
}

fn reportUsage(raw: *anyopaque, usage: types.Usage) void {
    const context: *Context = @ptrCast(@alignCast(raw));
    if (usage.input_tokens) |value| context.input_tokens = value;
    if (usage.output_tokens) |value| context.output_tokens = value;
    if (context.turn.live_metrics) |metrics| {
        metrics.input_tokens.store(context.input_tokens, .monotonic);
    }
}

/// Saves each reply's usage in the child's own log, as the root saves its
/// own (D92). The parent's total leaves the child's out.
fn recordUsage(raw: *anyopaque, usage: types.Usage) !void {
    const context: *Context = @ptrCast(@alignCast(raw));
    // A hosted run has no session here; its own agent saves its usage.
    const child = context.turn.child orelse return;
    try child.recordUsage(usage);
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
        .assistant_started => {},
        .assistant_source => {},
        .assistant_rendered => |text| context.turn.appendLiveText(text),
        .assistant_restarted => |text| context.turn.appendLiveText(text),
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
    const masked = try execution_memory.maskTextForDisplay(context.turn.alloc, formatted);
    defer context.turn.alloc.free(masked);
    context.turn.setFailureDiagnostic("provider_http_error", masked);
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

test "a child's system prompt names it and who started it, then wraps the run's overlay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const role: Role = .{ .name = "reviewer", .parent = "main" };
    const expected_role = "<subagent_role>\nYou are the subagent \"reviewer\", started by \"main\". When work it " ++
        "gives you ends, your output reaches it on its own as your report. To message it sooner, for example when " ++
        "the user asks you to tell main something, call the subagent tool with action \"message\" and agent " ++
        "\"parent\", if you have that tool.\n</subagent_role>";
    try std.testing.expectEqualStrings(
        "base prompt\n\n" ++ expected_role,
        try childSystemPrompt(arena.allocator(), null, "base prompt", role, ""),
    );
    try std.testing.expectEqualStrings(
        "base prompt\n\n" ++ expected_role ++ "\n\n<subagent_instructions>\nbe brief\n</subagent_instructions>",
        try childSystemPrompt(arena.allocator(), null, "base prompt", role, "be brief"),
    );
}

test "a profile that replaces the system prompt still leaves a child its role" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const profile: profiles.Profile = .{ .name = "review", .description = "", .source = .home, .prompt = "Review only.", .prompt_mode = .replace };
    const prompt = try childSystemPrompt(arena.allocator(), &profile, "base prompt", .{ .name = "helper", .parent = "lead" }, "");
    try std.testing.expect(std.mem.startsWith(u8, prompt, "Review only.\n\n<subagent_role>\n"));
    try std.testing.expect(std.mem.find(u8, prompt, "You are the subagent \"helper\", started by \"lead\".") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "base prompt") == null);
}
