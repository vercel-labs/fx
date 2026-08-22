const std = @import("std");
const acp_runner = @import("../core/cli/acp_runner.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const io_mod = @import("../core/shared/io.zig");
const host_target = @import("../core/hosts/target.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const sessions = @import("sessions.zig");
const session_test_controls = @import("session_test_controls.zig");
const prompt_handler = @import("prompt.zig");
const prompt_test_controls = @import("prompt_test_controls.zig");
const app_lifecycle = @import("../core/app/app_lifecycle.zig");
const app_runtime_setup = @import("../core/app/app_runtime_setup.zig");
const builtin_skills = @import("../builtins/skills.zig");
const builtin_tools = @import("../builtins/tools.zig");
const credentials = @import("../core/auth/credentials.zig");
const secret = @import("../core/auth/secret.zig");
const auth_runtime = @import("../core/auth/auth_runtime.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const hooks = @import("../core/hooks/hooks.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_log = @import("../core/session/session_log.zig");
const session_store = @import("../core/session/session_store.zig");
const session_runtime = @import("../core/session/session.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const background_runtime = @import("../core/background/background_runtime.zig");
const terminal_client_runtime = @import("../core/terminal/client.zig");
const subagent_tool_host = @import("../core/subagent/tool_host.zig");
const subagent_authority = @import("../core/subagent/authority.zig");
const types = @import("../core/shared/types.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const workspace_access = @import("../core/workspace/workspace_access.zig");
const web_fetch_runtime = @import("../core/tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../core/tooling/web_search_runtime.zig");
const elicitation = @import("../core/mcp/elicitation.zig");
const tool_mcp_runtime = @import("../core/tooling/tool_mcp_runtime.zig");
const permissions = @import("../core/permissions/permissions.zig");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;
const writeJsonStr = jsonrpc.writeJsonStr;
const legacy_url_completion_timeout_ms: i64 = 10 * 60 * 1000;

const AcpMethod = enum {
    initialize,
    session_cancel,
    session_new,
    session_load,
    session_resume,
    session_close,
    session_list,
    session_remove,
    session_prompt,
    session_set_config_option,
    session_set_mode,
    unknown,

    fn parse(method: []const u8) AcpMethod {
        if (std.mem.eql(u8, method, "initialize")) return .initialize;
        if (std.mem.eql(u8, method, "session/cancel")) return .session_cancel;
        if (std.mem.eql(u8, method, "session/new")) return .session_new;
        if (std.mem.eql(u8, method, "session/load")) return .session_load;
        if (std.mem.eql(u8, method, "session/resume")) return .session_resume;
        if (std.mem.eql(u8, method, "session/close")) return .session_close;
        if (std.mem.eql(u8, method, "session/list")) return .session_list;
        if (std.mem.eql(u8, method, "session/remove")) return .session_remove;
        if (std.mem.eql(u8, method, "session/prompt")) return .session_prompt;
        if (std.mem.eql(u8, method, "session/set_config_option")) return .session_set_config_option;
        if (std.mem.eql(u8, method, "session/set_mode")) return .session_set_mode;
        return .unknown;
    }

    fn waitsForActivePrompt(self: AcpMethod) bool {
        return switch (self) {
            .initialize,
            .session_cancel,
            .session_set_mode,
            .session_new,
            .session_load,
            .session_resume,
            .session_close,
            => false,
            .session_list,
            .session_remove,
            .session_prompt,
            .session_set_config_option,
            .unknown,
            => true,
        };
    }
};

pub const Config = acp_runner.Config;

pub const OutboundKind = enum {
    permission,
    elicitation,
};

pub const OutboundResponse = struct {
    result_json: ?[]u8 = null,
    error_json: ?[]u8 = null,
    cancelled: bool = false,

    pub fn deinit(self: *OutboundResponse, alloc: Allocator) void {
        if (self.result_json) |value| alloc.free(value);
        if (self.error_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

const PendingOutbound = struct {
    kind: OutboundKind,
    response: ?OutboundResponse = null,
};

const max_pending_outbound = 32;

const PendingLegacyUrl = struct {
    server_name: []u8,
    source_id: []u8,
    acp_id: []u8,
    session_id: []u8,
    tool_call_id: []u8,
    binding: elicitation.Binding,
    accepted: bool = false,
    completed: bool = false,

    fn deinit(self: *PendingLegacyUrl, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.source_id);
        alloc.free(self.acp_id);
        alloc.free(self.session_id);
        alloc.free(self.tool_call_id);
        self.* = undefined;
    }
};

pub const ActiveSessionState = struct {
    session_id: []u8,
    store: ?session_store.Store = null,
    writable: ?session_store.LoadedWritableSession = null,
    wasm_state: ?session_codec.DurableSessionState = null,
    wasm_revision: ?[]u8 = null,
    session_write_mutex: std.Io.Mutex = .init,
    model: []u8,
    provider: model_provider.ProviderId = .gateway,
    mode: []const u8,
    workspace_root: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    agent_step_limit: usize,
    max_tool_result_bytes: usize,
    fast_mode: bool,
    effort: types.ReasoningEffort,
    first_call_tool_choice: types.ToolChoice,
    permission_mode: types.PermissionMode,
    permission_rules: types.PermissionRuleSet,
    /// Runtime-only "allow for this session" grants. Never persisted to
    /// profile or project configuration.
    session_grants: []types.PermissionGrant = &.{},
    session_rt: session_runtime.SessionRuntime,
    mcp: ?*mcp_runtime.McpRuntime = null,
    cancel_flag: std.atomic.Value(bool),
    pending_prompt_id: ?jsonrpc.RequestId,

    pub fn retainGrant(self: *ActiveSessionState, alloc: Allocator, tool_name: []const u8, target_path: []const u8) !void {
        for (self.session_grants) |grant| {
            if (std.mem.eql(u8, grant.tool_name, tool_name) and
                std.mem.eql(u8, grant.target_path, target_path)) return;
        }

        const name_copy = try alloc.dupe(u8, tool_name);
        errdefer alloc.free(name_copy);
        const target_copy = try alloc.dupe(u8, target_path);
        errdefer alloc.free(target_copy);
        const next = try alloc.alloc(types.PermissionGrant, self.session_grants.len + 1);
        errdefer alloc.free(next);
        if (self.session_grants.len > 0) {
            std.mem.copyForwards(types.PermissionGrant, next[0..self.session_grants.len], self.session_grants);
            alloc.free(self.session_grants);
        }
        next[next.len - 1] = .{ .tool_name = name_copy, .target_path = target_copy };
        self.session_grants = next;
    }
};

const ActivePrompt = struct {
    state: *ServerState,
    alloc: Allocator,
    msg: jsonrpc.Message,
    /// Mode and permission policy captured when the prompt was dispatched.
    /// Mid-turn mode changes apply to the next prompt, never the running one.
    mode: []const u8,
    permission_mode: types.PermissionMode,
    thread: if (host_target.is_wasm) void else std.Thread = if (host_target.is_wasm) {} else undefined,
    reapable: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const ServerState = struct {
    alloc: Allocator,
    cfg: Config,
    writer: jsonrpc.Writer,
    initialized: bool = false,
    client_fs_read: bool = false,
    client_fs_write: bool = false,
    client_terminal: bool = false,
    client_elicitation: elicitation.Capabilities = .{},
    workspace_root: []u8 = &.{},
    workspace_access: workspace_access.WorkspaceAccess = .{},
    api_key: []u8 = &.{},
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    gateway_team: ?[]u8 = null,
    selected_model: []u8 = &.{},
    provider: model_provider.ProviderId = .gateway,
    configured_model: []u8 = &.{},
    process_model_override: bool = false,
    permission_mode: types.PermissionMode = .ask,
    permission_rules: types.PermissionRuleSet = .{},
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    context_limits: config_runtime.context_limits.Values = .{},
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    context_enabled: bool = true,
    active_session: ?ActiveSessionState = null,
    active_prompt: ?*ActivePrompt = null,
    subagent_authority_mutex: std.Io.Mutex = .init,
    skills: skill_runtime.Runtime = .{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    worker: worker_runtime.WorkerRuntime = .{},
    background: background_runtime.BackgroundRuntime = .{},
    terminal_client: terminal_client_runtime.Runtime = .{},
    subagent_store: ?session_store.Store = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    capability_resolver: gateway_provider.CapabilityResolver = .{},
    terminate_connection: bool = false,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{}),
    lifecycle_runtime: hooks.Runtime = hooks.Runtime.init(std.heap.c_allocator),
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    outbound_mutex: std.Io.Mutex = .init,
    outbound_cond: std.Io.Condition = .init,
    next_outbound_request_id: u64 = 1,
    pending_outbound: std.AutoHashMapUnmanaged(u64, PendingOutbound) = .empty,
    legacy_url_mutex: std.Io.Mutex = .init,
    pending_legacy_urls: std.ArrayListUnmanaged(PendingLegacyUrl) = .empty,

    pub fn deinit(self: *ServerState) void {
        reapActivePrompt(self, true);
        self.terminal_client.deinit();
        closeActiveSession(self) catch |err| {
            debug_trace.logf(
                "session",
                "failed to flush ACP session usage during shutdown err={s}",
                .{@errorName(err)},
            );
        };
        self.workspace_access.deinit(self.alloc);
        if (self.workspace_root.len > 0) self.alloc.free(self.workspace_root);
        if (self.api_key.len > 0) secret.zeroAndFree(self.alloc, self.api_key);
        if (self.gateway_team) |team| self.alloc.free(team);
        if (self.account_id) |account_id| self.alloc.free(account_id);
        if (self.selected_model.len > 0) self.alloc.free(self.selected_model);
        if (self.configured_model.len > 0) self.alloc.free(self.configured_model);
        self.permission_rules.deinit(self.alloc);
        self.background.deinit(std.heap.c_allocator);
        self.skills.deinit(self.alloc);
        self.context_snapshot.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.lifecycle_runtime.deinit();
        self.capability_resolver.deinit(self.alloc);
        var pending = self.pending_outbound.valueIterator();
        while (pending.next()) |entry| {
            if (entry.response) |*response| response.deinit(self.alloc);
        }
        self.pending_outbound.deinit(self.alloc);
        clearPendingLegacyUrls(self);
        self.pending_legacy_urls.deinit(self.alloc);
    }
};

fn credentialMatchesProvider(
    source: ?types.CredentialSource,
    provider: model_provider.ProviderId,
) bool {
    return model_provider.authorizesCredential(provider, source);
}

fn adoptServerCredential(state: *ServerState, credential: *credentials.Credential) void {
    if (state.active_session) |*active| active.api_key = &.{};
    if (state.api_key.len > 0) secret.zeroAndFree(state.alloc, state.api_key);
    if (state.gateway_team) |team| state.alloc.free(team);
    if (state.account_id) |account_id| state.alloc.free(account_id);

    state.api_key = credential.token;
    credential.token = &.{};
    state.credential_source = credential.source;
    state.account_id = credential.account_id;
    credential.account_id = null;
    state.gateway_team = if (credential.team_id) |team| team else credential.team_slug;
    if (credential.team_id != null) {
        credential.team_id = null;
        if (credential.team_slug) |slug| state.alloc.free(slug);
        credential.team_slug = null;
    } else {
        credential.team_slug = null;
    }
    if (state.active_session) |*active| {
        active.api_key = state.api_key;
        active.credential_source = state.credential_source;
        active.account_id = state.account_id;
        if (comptime !host_target.is_wasm) {
            if (state.credential_source == .chatgpt_subscription or state.credential_source == .grok_subscription) {
                active.session_rt.usage.clearReconciliationCredential();
            }
        }
    }
}

/// Ensures the process and active ACP session use a credential authorized for
/// the final model route. Returns false when that route has no credential.
pub fn selectCredentialForProvider(
    state: *ServerState,
    provider: model_provider.ProviderId,
) !bool {
    if (state.active_session) |active| {
        if (credentialMatchesProvider(active.credential_source, provider)) return true;
    }
    if (credentialMatchesProvider(state.credential_source, provider) and state.api_key.len > 0) return true;

    var credential = if (provider == .gateway and state.cfg.credential_override != null)
        credentials.Credential{
            .token = try state.alloc.dupe(u8, state.cfg.credential_override.?),
            .source = .ai_gateway_api_key,
        }
    else blk: {
        const resolution = try credentials.resolveForProvider(
            state.alloc,
            state.cfg.gateway_provider.oauth_transport,
            state.cfg.secret_store,
            .refresh_if_needed,
            provider,
            state.credential_source,
        );
        break :blk resolution.credential orelse return false;
    };
    defer credential.deinit(state.alloc);
    adoptServerCredential(state, &credential);
    return true;
}

pub fn streamProviderFor(
    state: *const ServerState,
    provider: model_provider.ProviderId,
) @import("../core/agent/stream_provider.zig").Provider {
    return switch (provider) {
        .gateway => state.cfg.gateway_provider.agent_stream,
        .codex => state.cfg.codex_agent_stream orelse
            @import("../core/agent/stream_provider.zig").unavailable_provider,
        .grok => state.cfg.grok_agent_stream orelse
            @import("../core/agent/stream_provider.zig").unavailable_provider,
        .claude => state.cfg.claude_agent_stream orelse
            @import("../core/agent/stream_provider.zig").unavailable_provider,
    };
}

pub fn catalogProviderFor(
    state: *const ServerState,
    provider: model_provider.ProviderId,
) ?@import("../core/gateway/model_catalog.zig").Provider {
    return switch (provider) {
        .gateway => state.cfg.gateway_provider.model_catalog,
        .codex => state.cfg.codex_model_catalog,
        .grok => state.cfg.grok_model_catalog,
        .claude => state.cfg.claude_model_catalog,
    };
}

pub fn refreshModelCredential(
    raw: *anyopaque,
    alloc: Allocator,
    source: types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const state: *ServerState = @ptrCast(@alignCast(raw));
    const refreshed = try auth_runtime.refreshCredentialTokenForAccount(
        state.cfg.gateway_provider.oauth_transport,
        alloc,
        source,
        mode,
        expected_account_id,
    ) orelse return null;
    errdefer secret.zeroAndFree(alloc, refreshed);
    if (source == .chatgpt_subscription or source == .grok_subscription) {
        try publishRefreshedSubscriptionToken(state, refreshed, source, expected_account_id);
    }
    return refreshed;
}

fn publishRefreshedSubscriptionToken(
    state: *ServerState,
    refreshed: []const u8,
    source: types.CredentialSource,
    expected_account_id: ?[]const u8,
) !void {
    const expected = expected_account_id orelse return error.ChatGptAccountChanged;
    const state_account = state.account_id orelse return error.ChatGptAccountChanged;
    if (!std.mem.eql(u8, expected, state_account)) return error.ChatGptAccountChanged;
    if (state.active_session) |active| {
        const active_account = active.account_id orelse return error.ChatGptAccountChanged;
        if (!std.mem.eql(u8, expected, active_account)) return error.ChatGptAccountChanged;
    }

    const owned = try state.alloc.dupe(u8, refreshed);
    if (state.active_session) |*active| active.api_key = &.{};
    if (state.api_key.len > 0) secret.zeroAndFree(state.alloc, state.api_key);
    state.api_key = owned;
    state.credential_source = source;
    if (state.active_session) |*active| {
        active.api_key = state.api_key;
        active.credential_source = source;
    }
}

pub fn releaseActiveSession(state: *ServerState) !void {
    clearPendingLegacyUrls(state);
    const active = if (state.active_session) |*session| session else return;
    disableSubagentHost(state);
    if (comptime !host_target.is_wasm) {
        active.session_rt.usage.cancelReconciliation();
        active.session_rt.usage.finishProfilePublicationsBeforeShutdown();
        flushActiveSessionUsage(state) catch |err| {
            if (state.credential_source == .chatgpt_subscription or state.credential_source == .grok_subscription) {
                active.session_rt.usage.clearReconciliationCredential();
            } else {
                active.session_rt.usage.startReconciliation(
                    state.alloc,
                    state.api_key,
                );
            }
            return err;
        };
        active.session_rt.usage.configurePublicationSink(null);
        active.session_rt.usage.configureCheckpointSink(null);
    }
    destroyActiveSession(state);
}

fn closeActiveSession(state: *ServerState) !void {
    const active = if (state.active_session) |*session| session else return;
    disableSubagentHost(state);
    if (comptime !host_target.is_wasm) {
        active.session_rt.usage.cancelReconciliation();
        active.session_rt.usage.finishProfilePublicationsBeforeShutdown();
        flushActiveSessionUsage(state) catch |err| {
            destroyActiveSession(state);
            return err;
        };
        active.session_rt.usage.configurePublicationSink(null);
        active.session_rt.usage.configureCheckpointSink(null);
    }
    destroyActiveSession(state);
}

fn destroyActiveSession(state: *ServerState) void {
    const active = if (state.active_session) |*session| session else return;
    state.background.detachManagedPersistence(
        std.heap.c_allocator,
        active.session_id,
    );
    state.alloc.free(active.session_id);
    state.alloc.free(active.model);
    types.freePermissionGrantSlice(state.alloc, active.session_grants);
    if (comptime !host_target.is_wasm) {
        if (active.mcp) |runtime| {
            runtime.retireAndWait();
            runtime.deinit();
            state.alloc.destroy(runtime);
        }
    }
    active.session_rt.deinit(state.alloc);
    if (active.writable) |*writable| writable.deinit(state.alloc);
    if (active.store) |*store| store.deinit(state.alloc);
    if (active.wasm_state) |*wasm_state| wasm_state.deinit(state.alloc);
    if (active.wasm_revision) |revision| state.alloc.free(revision);
    state.active_session = null;
}

pub fn enableSubagentHost(state: *ServerState) void {
    disableSubagentHost(state);
    const active = if (state.active_session) |*session| session else return;
    if (active.writable == null) return;
    state.subagent_store = session_store.Store.init(state.alloc, state.workspace_root) catch |err| {
        debug_trace.logf("acp", "subagent host store unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
        return;
    };
    state.subagent_host = subagent_tool_host.Runtime.create(
        state.alloc,
        &state.subagent_store.?,
        active.session_id,
        .{ .context = state, .resolve_fn = resolveSubagentAuthority },
        .{ .context = state, .run_fn = prompt_handler.runSubagentChild },
    ) catch |err| {
        debug_trace.logf("acp", "subagent host unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
        state.subagent_store.?.deinit(state.alloc);
        state.subagent_store = null;
        return;
    };
    state.subagent_host.?.requestBackgroundRecovery(
        io_mod.milliTimestamp(),
    ) catch |err| {
        debug_trace.logf(
            "subagent",
            "acp background recovery unavailable root_id={s} outcome={s}",
            .{ state.subagent_host.?.root_id, @errorName(err) },
        );
    };
}

fn resolveSubagentAuthority(
    raw: ?*anyopaque,
    alloc: Allocator,
    root_id: []const u8,
) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
    const state: *ServerState = @ptrCast(@alignCast(raw.?));
    const active = if (state.active_session) |*value| value else return error.HostAuthorityUnavailable;
    if (!std.mem.eql(u8, active.session_id, root_id)) {
        return error.HostAuthorityUnavailable;
    }
    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer state.subagent_authority_mutex.unlock(io_mod.getIo());
    const integrations = if (active.mcp) |mcp|
        mcp.snapshotToolNames(alloc, active.permission_rules)
    else
        alloc.alloc([]u8, 0);
    const owned_integrations = integrations catch return error.OutOfMemory;
    defer {
        for (owned_integrations) |name| alloc.free(name);
        alloc.free(owned_integrations);
    }
    var mcp_view = if (active.mcp) |mcp|
        try mcp.snapshotAccessView(
            alloc,
            root_id,
            root_id,
            active.permission_rules,
            state.cfg.mode_registry.toolAllowed(builtin_tools.advertisement_set, active.mode, "mcp_features") and
                !permissions.rulesDenyAllTargetsForTool(active.permission_rules, "mcp_features"),
        )
    else
        null;
    defer if (mcp_view) |*view| view.deinit(alloc);
    var permission_state = active.session_rt.snapshotPermissionState(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HostAuthorityUnavailable,
    };
    defer permission_state.deinit(alloc);
    return subagent_tool_host.captureHostAuthorityWithMcpView(
        alloc,
        .{
            .tool_set = builtin_tools.advertisement_set,
            .mode = .{
                .active = .{
                    .registry = state.cfg.mode_registry,
                    .id = active.mode,
                },
            },
        },
        owned_integrations,
        active.permission_rules,
        active.session_grants,
        permission_state,
        if (mcp_view) |*view| view else null,
    );
}

pub fn disableSubagentHost(state: *ServerState) void {
    if (state.subagent_host) |host| {
        host.deinit();
        state.subagent_host = null;
    }
    if (state.subagent_store) |*store| {
        store.deinit(state.alloc);
        state.subagent_store = null;
    }
}

fn flushActiveSessionUsage(state: *ServerState) !void {
    const active = if (state.active_session) |*session| session else return;
    const writable = if (active.writable) |*value| value else return;
    if (!writable.needsFinalStateReplacement(
        active.session_rt.usage.isDirty(),
    )) return;

    var current = try writable.state.dupe(state.alloc);
    defer current.deinit(state.alloc);
    const history = try active.session_rt.snapshotHistory(state.alloc);
    types.freeHistoryTurnSlice(state.alloc, current.history);
    current.history = history;
    const permission_state = try active.session_rt.snapshotPermissionState(state.alloc);
    current.permission_state.deinit(state.alloc);
    current.permission_state = permission_state;
    current.conversation_language = active.session_rt.languageSnapshot();
    const usage_snapshot = try active.session_rt.usage.snapshot(state.alloc);
    if (current.usage) |*old| old.deinit(state.alloc);
    current.usage = usage_snapshot;
    const store = if (active.store) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        state.alloc,
        writable,
        usage_snapshot,
    );
    current.updated_at_ms = recovery_checkpoint.timestamp_ms;
    _ = try writable.commitStateReplacement(
        state.alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try store.finishUsageRecoveryCheckpoint(
        writable.active_id,
        recovery_checkpoint,
    );
    if (current.usage) |usage| {
        active.session_rt.usage.markClean(usage);
    }
}

pub fn run(alloc: Allocator, cfg: Config) !void {
    return runWithTransport(alloc, cfg, jsonrpc.Reader.init(), jsonrpc.Writer.init());
}

pub fn runWithTransport(
    alloc: Allocator,
    cfg: Config,
    reader_value: jsonrpc.Reader,
    writer_value: jsonrpc.Writer,
) !void {
    if (cfg.log_file) |path| {
        try debug_trace.configure(.{ .file_path = path });
    }

    var lifecycle_runtime = hooks.Runtime.init(alloc);
    const lifecycle_view = lifecycle_runtime.freeze();
    var state = ServerState{
        .alloc = alloc,
        .cfg = cfg,
        .writer = writer_value,
        .web_search_runtime = web_search_runtime.Runtime.init(.{
            .provider = cfg.gateway_provider.web_search,
        }),
        .background = background_runtime.BackgroundRuntime.init(
            cfg.background_process_provider,
        ),
        .terminal_client = terminal_client_runtime.Runtime.init(
            cfg.background_process_provider,
        ),
        .lifecycle_runtime = lifecycle_runtime,
        .lifecycle_view = lifecycle_view,
    };
    defer state.deinit();

    var reader = reader_value;
    while (!state.terminate_connection) {
        reapActivePrompt(&state, false);
        const line_result = reader.readLine(alloc) catch break;
        if (line_result == null) break;
        const line = switch (line_result.?) {
            .overflow => {
                state.writer.writeError(alloc, null, .{
                    .code = ErrorCode.request_frame_too_large,
                    .message = "Request frame too large",
                }) catch break;
                continue;
            },
            .line => |value| value,
        };
        defer alloc.free(line);

        var msg = jsonrpc.parseMessage(alloc, line) catch |err| {
            const code = switch (err) {
                error.ParseError => ErrorCode.parse_error,
                else => ErrorCode.invalid_request,
            };
            state.writer.writeError(alloc, null, .{ .code = code, .message = "Parse error" }) catch break;
            continue;
        };
        defer jsonrpc.freeMessage(alloc, &msg);

        if (msg.isResponse()) {
            handleClientResponse(&state, alloc, &msg);
            continue;
        }

        if (!shouldRespondToMessage(&msg)) {
            dispatchNotification(&state, alloc, &msg) catch {};
            if (state.terminate_connection) break;
            continue;
        }

        dispatch(&state, alloc, &msg) catch |err| {
            state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.internal_error,
                .message = @errorName(err),
            }) catch break;
        };
        if (state.terminate_connection) break;
    }
    // Release any prompt thread parked on a pending approval before
    // state.deinit() joins it, or shutdown deadlocks.
    handleCancel(&state);
}

fn shouldRespondToMessage(msg: *const jsonrpc.Message) bool {
    return !msg.isResponse() and msg.id != null;
}

fn handleClientResponse(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) void {
    const id = msg.id orelse return;
    const numeric_id: u64 = switch (id) {
        .integer => |value| if (value > 0) @intCast(value) else return,
        else => return,
    };
    const result_copy = if (msg.result_raw) |raw| alloc.dupe(u8, raw) catch return else null;
    const error_copy = if (msg.error_raw) |raw| alloc.dupe(u8, raw) catch {
        if (result_copy) |value| alloc.free(value);
        return;
    } else null;

    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    const pending = state.pending_outbound.getPtr(numeric_id) orelse {
        if (result_copy) |value| alloc.free(value);
        if (error_copy) |value| alloc.free(value);
        return;
    };
    if (pending.response != null) {
        if (result_copy) |value| alloc.free(value);
        if (error_copy) |value| alloc.free(value);
        return;
    }
    pending.response = .{
        .result_json = result_copy,
        .error_json = error_copy,
    };
    state.outbound_cond.broadcast(io_mod.getIo());
}

fn parsePermissionDecision(root: std.json.Value) ?types.ToolPermissionDecision {
    if (root != .object) return null;
    const outcome = root.object.get("outcome") orelse return null;
    if (outcome != .object) return null;
    const kind = outcome.object.get("outcome") orelse return null;
    if (kind != .string) return null;
    if (std.mem.eql(u8, kind.string, "cancelled")) return .deny;
    if (!std.mem.eql(u8, kind.string, "selected")) return null;
    const option = outcome.object.get("optionId") orelse return null;
    if (option != .string) return null;
    if (std.mem.eql(u8, option.string, "allow_once")) return .once;
    if (std.mem.eql(u8, option.string, "allow_always")) return .always;
    if (std.mem.eql(u8, option.string, "reject_once")) return .deny;
    return null;
}

pub fn beginOutboundRequest(state: *ServerState, kind: OutboundKind) !?u64 {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    if (state.pending_outbound.count() >= max_pending_outbound or
        state.next_outbound_request_id > @as(u64, @intCast(std.math.maxInt(i64))))
    {
        return null;
    }
    const id = state.next_outbound_request_id;
    state.next_outbound_request_id += 1;
    try state.pending_outbound.put(state.alloc, id, .{ .kind = kind });
    return id;
}

pub fn awaitOutboundResponse(state: *ServerState, id: u64, kind: OutboundKind) ?OutboundResponse {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    while (true) {
        const pending = state.pending_outbound.getPtr(id) orelse return null;
        if (pending.kind != kind) return null;
        if (pending.response) |response| {
            _ = state.pending_outbound.remove(id);
            return response;
        }
        state.outbound_cond.wait(io_mod.getIo(), &state.outbound_mutex) catch {
            cancelOutboundRequestLocked(state, id);
        };
    }
}

pub fn cancelOutboundRequest(state: *ServerState, id: u64) void {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    cancelOutboundRequestLocked(state, id);
}

fn cancelOutboundRequestLocked(state: *ServerState, id: u64) void {
    const pending = state.pending_outbound.getPtr(id) orelse return;
    if (pending.response != null) return;
    pending.response = .{ .cancelled = true };
    state.outbound_cond.broadcast(io_mod.getIo());
}

fn cancelPendingOutbound(state: *ServerState) void {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    var pending = state.pending_outbound.valueIterator();
    while (pending.next()) |entry| {
        if (entry.response == null) entry.response = .{ .cancelled = true };
    }
    state.outbound_cond.broadcast(io_mod.getIo());
}

pub fn reserveLegacyUrl(
    state: *ServerState,
    origin: tool_mcp_runtime.InputOrigin,
    source_id: []const u8,
    acp_id: []const u8,
    session_id: []const u8,
    tool_call_id: []const u8,
) !bool {
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer state.legacy_url_mutex.unlock(io_mod.getIo());
    const now_ms = serverAwakeMillis();
    var pending_index: usize = 0;
    while (pending_index < state.pending_legacy_urls.items.len) {
        const pending = &state.pending_legacy_urls.items[pending_index];
        const stale_generation = std.mem.eql(u8, pending.server_name, origin.server_name) and
            (pending.binding.runtime_generation != origin.runtime_generation or
                pending.binding.connection_generation != origin.connection_generation or
                pending.binding.client_generation != origin.client_generation or
                pending.binding.auth_generation != origin.auth_generation);
        if (pending.binding.deadline_ms >= now_ms and !stale_generation) {
            pending_index += 1;
            continue;
        }
        var expired = state.pending_legacy_urls.swapRemove(pending_index);
        expired.deinit(state.alloc);
    }
    if (state.pending_legacy_urls.items.len >= max_pending_outbound) return false;
    for (state.pending_legacy_urls.items) |pending| {
        if (std.mem.eql(u8, pending.server_name, origin.server_name) and
            std.mem.eql(u8, pending.source_id, source_id)) return false;
    }

    const server_name = try state.alloc.dupe(u8, origin.server_name);
    errdefer state.alloc.free(server_name);
    const owned_source_id = try state.alloc.dupe(u8, source_id);
    errdefer state.alloc.free(owned_source_id);
    const owned_acp_id = try state.alloc.dupe(u8, acp_id);
    errdefer state.alloc.free(owned_acp_id);
    const owned_session_id = try state.alloc.dupe(u8, session_id);
    errdefer state.alloc.free(owned_session_id);
    const owned_tool_call_id = try state.alloc.dupe(u8, tool_call_id);
    errdefer state.alloc.free(owned_tool_call_id);
    try state.pending_legacy_urls.append(state.alloc, .{
        .server_name = server_name,
        .source_id = owned_source_id,
        .acp_id = owned_acp_id,
        .session_id = owned_session_id,
        .tool_call_id = owned_tool_call_id,
        .binding = .{
            .server_name = server_name,
            .scope = .{ .acp_session = .{
                .session_id = owned_session_id,
                .tool_call_id = owned_tool_call_id,
            } },
            .runtime_generation = origin.runtime_generation,
            .connection_generation = origin.connection_generation,
            .client_generation = origin.client_generation,
            .catalog_generation = origin.catalog_generation,
            .request_generation = origin.request_generation,
            .auth_generation = origin.auth_generation,
            .deadline_ms = std.math.add(i64, now_ms, legacy_url_completion_timeout_ms) catch
                std.math.maxInt(i64),
        },
    });
    return true;
}

pub fn removeLegacyUrl(
    state: *ServerState,
    acp_id: []const u8,
) void {
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer state.legacy_url_mutex.unlock(io_mod.getIo());
    for (state.pending_legacy_urls.items, 0..) |pending, index| {
        if (!std.mem.eql(u8, pending.acp_id, acp_id)) continue;
        var removed = state.pending_legacy_urls.swapRemove(index);
        removed.deinit(state.alloc);
        return;
    }
}

pub fn acceptLegacyUrl(
    state: *ServerState,
    origin: tool_mcp_runtime.InputOrigin,
    acp_id: []const u8,
) tool_mcp_runtime.LegacyUrlAcceptTransition {
    var owned_acp_id: ?[]u8 = null;
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    const result = result: for (state.pending_legacy_urls.items, 0..) |*pending, index| {
        if (!std.mem.eql(u8, pending.acp_id, acp_id)) continue;
        if (pending.binding.runtime_generation != origin.runtime_generation or
            pending.binding.connection_generation != origin.connection_generation or
            pending.binding.client_generation != origin.client_generation or
            pending.binding.catalog_generation != origin.catalog_generation or
            pending.binding.request_generation != origin.request_generation or
            pending.binding.auth_generation != origin.auth_generation)
        {
            break :result tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
        }
        pending.accepted = true;
        if (!pending.completed) {
            break :result tool_mcp_runtime.LegacyUrlAcceptTransition.awaiting_completion;
        }
        var removed = state.pending_legacy_urls.swapRemove(index);
        owned_acp_id = removed.acp_id;
        removed.acp_id = &.{};
        removed.deinit(state.alloc);
        break :result tool_mcp_runtime.LegacyUrlAcceptTransition{ .completed = owned_acp_id.? };
    } else tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
    state.legacy_url_mutex.unlock(io_mod.getIo());
    return result;
}

fn clearPendingLegacyUrls(state: *ServerState) void {
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    defer state.legacy_url_mutex.unlock(io_mod.getIo());
    for (state.pending_legacy_urls.items) |*pending| pending.deinit(state.alloc);
    state.pending_legacy_urls.clearRetainingCapacity();
}

pub fn legacyUrlCompletionSink(state: *ServerState) tool_mcp_runtime.LegacyUrlCompletionSink {
    return .{
        .context = @ptrCast(state),
        .accept = acceptLegacyUrlFromSink,
        .consume = consumeLegacyUrlCompletion,
        .publish = publishLegacyUrlCompletionFromSink,
    };
}

fn acceptLegacyUrlFromSink(
    raw_context: *anyopaque,
    origin: tool_mcp_runtime.InputOrigin,
    acp_id: []const u8,
) tool_mcp_runtime.LegacyUrlAcceptTransition {
    const state: *ServerState = @ptrCast(@alignCast(raw_context));
    return acceptLegacyUrl(state, origin, acp_id);
}

fn consumeLegacyUrlCompletion(
    raw_context: *anyopaque,
    completion: tool_mcp_runtime.LegacyUrlCompletion,
) tool_mcp_runtime.LegacyUrlConsumeTransition {
    const state: *ServerState = @ptrCast(@alignCast(raw_context));
    var acp_id: ?[]u8 = null;
    var matched = false;
    state.legacy_url_mutex.lockUncancelable(io_mod.getIo());
    for (state.pending_legacy_urls.items, 0..) |*pending, index| {
        if (!std.mem.eql(u8, pending.server_name, completion.server_name) or
            !std.mem.eql(u8, pending.source_id, completion.elicitation_id)) continue;
        if (pending.binding.runtime_generation != completion.runtime_generation or
            pending.binding.connection_generation != completion.connection_generation or
            pending.binding.client_generation != completion.client_generation or
            pending.binding.auth_generation != completion.auth_generation) break;
        const transition = elicitation.decideTransition(
            .pending,
            pending.binding,
            .{
                .server_name = completion.server_name,
                .scope = pending.binding.scope,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                .catalog_generation = pending.binding.catalog_generation,
                .request_generation = pending.binding.request_generation,
                .auth_generation = completion.auth_generation,
            },
            serverAwakeMillis(),
            true,
        );
        matched = true;
        switch (transition) {
            .consume => {
                if (pending.accepted) {
                    var removed = state.pending_legacy_urls.swapRemove(index);
                    acp_id = removed.acp_id;
                    removed.acp_id = &.{};
                    removed.deinit(state.alloc);
                } else {
                    pending.completed = true;
                }
            },
            .reject => {
                var removed = state.pending_legacy_urls.swapRemove(index);
                removed.deinit(state.alloc);
            },
        }
        break;
    }
    state.legacy_url_mutex.unlock(io_mod.getIo());

    return if (matched)
        .{ .consumed = acp_id }
    else
        .missing;
}

fn publishLegacyUrlCompletionFromSink(raw_context: *anyopaque, id: []u8) void {
    const state: *ServerState = @ptrCast(@alignCast(raw_context));
    publishLegacyUrlCompletion(state, id);
}

fn publishLegacyUrlCompletion(state: *ServerState, id: []u8) void {
    defer state.alloc.free(id);
    var params: std.Io.Writer.Allocating = .init(state.alloc);
    defer params.deinit();
    params.writer.writeAll("{\"elicitationId\":") catch return;
    std.json.Stringify.value(id, .{}, &params.writer) catch return;
    params.writer.writeByte('}') catch return;
    state.writer.writeNotification(
        state.alloc,
        "elicitation/complete",
        params.writer.buffered(),
    ) catch {};
}

fn serverAwakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

/// Permission compatibility wrapper over the shared outbound registry.
pub fn beginPermissionRequest(state: *ServerState) ?u64 {
    return beginOutboundRequest(state, .permission) catch null;
}

pub fn awaitPermissionDecision(state: *ServerState, id: u64) types.ToolPermissionDecision {
    var response = awaitOutboundResponse(state, id, .permission) orelse return .deny;
    defer response.deinit(state.alloc);
    if (response.cancelled or response.error_json != null) return .deny;
    const raw = response.result_json orelse return .deny;
    const parsed = std.json.parseFromSlice(std.json.Value, state.alloc, raw, .{}) catch return .deny;
    defer parsed.deinit();
    return parsePermissionDecision(parsed.value) orelse .deny;
}

pub fn cancelPermissionRequest(state: *ServerState, id: u64) void {
    cancelOutboundRequest(state, id);
}

fn dispatchNotification(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    _ = alloc;
    reapActivePrompt(state, false);
    if (!state.initialized) return;
    switch (AcpMethod.parse(msg.method)) {
        .session_cancel => handleCancel(state),
        else => {},
    }
}

fn dispatch(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    reapActivePrompt(state, false);
    const method = AcpMethod.parse(msg.method);

    if (method == .initialize) {
        return handleInitialize(state, alloc, msg);
    }

    if (!state.initialized) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Not initialized. Call initialize first.",
        });
    }

    if (method == .session_cancel) {
        handleCancel(state);
        return state.writer.writeResponse(alloc, msg.id, "null");
    }

    if (method.waitsForActivePrompt() and state.active_prompt != null) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Prompt already in progress",
        });
    }

    if (comptime host_target.is_wasm) {
        return switch (method) {
            .session_new => sessions.handleNewWasmSession(state, alloc, msg),
            .session_load => sessions.handleLoadWasmSession(state, alloc, msg),
            .session_list => sessions.handleListWasmSessions(state, alloc, msg),
            .session_remove => sessions.handleRemoveWasmSession(state, alloc, msg),
            .session_prompt => startPrompt(state, alloc, msg),
            .session_set_config_option => handleSetConfigOption(state, alloc, msg),
            .session_set_mode => handleSetMode(state, alloc, msg),
            else => state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.method_not_found,
                .message = "Method not available in the web core yet",
            }),
        };
    }

    return switch (method) {
        .session_new => sessions.handleNewSession(state, alloc, msg),
        .session_load => sessions.handleLoadSession(state, alloc, msg),
        .session_resume => sessions.handleResumeSession(state, alloc, msg),
        .session_close => handleCloseSession(state, alloc, msg),
        .session_list => sessions.handleListSessions(state, alloc, msg),
        .session_prompt => startPrompt(state, alloc, msg),
        .session_set_config_option => handleSetConfigOption(state, alloc, msg),
        .session_set_mode => handleSetMode(state, alloc, msg),
        .initialize,
        .session_cancel,
        .session_remove,
        .unknown,
        => state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.method_not_found,
            .message = "Method not found",
        }),
    };
}

fn startPrompt(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) !void {
    const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, prompt_handler.no_active_session_rpc_error);
    const active = try alloc.create(ActivePrompt);
    errdefer alloc.destroy(active);
    active.* = .{
        .state = state,
        .alloc = alloc,
        .msg = try cloneMessage(alloc, msg),
        .mode = session.mode,
        .permission_mode = session.permission_mode,
    };
    errdefer jsonrpc.freeMessage(alloc, &active.msg);

    session.cancel_flag.store(false, .seq_cst);
    if (comptime host_target.is_wasm) {
        promptWorkerMain(active);
        jsonrpc.freeMessage(active.alloc, &active.msg);
        active.alloc.destroy(active);
    } else {
        active.thread = try std.Thread.spawn(.{}, promptWorkerMain, .{active});
        state.active_prompt = active;
    }
}

fn promptWorkerMain(active: *ActivePrompt) void {
    const outcome: prompt_handler.TerminalOutcome = prompt_handler.handlePrompt(
        active.state,
        active.alloc,
        &active.msg,
        active.mode,
        active.permission_mode,
    ) catch |err| .{
        .rpc_error = .{
            .code = ErrorCode.internal_error,
            .message = @errorName(err),
        },
    };
    active.reapable.store(true, .seq_cst);
    publishPromptOutcome(active, outcome) catch {};
    prompt_test_controls.pauseAfterTerminalWrite();
}

fn publishPromptOutcome(active: *ActivePrompt, outcome: prompt_handler.TerminalOutcome) !void {
    switch (outcome) {
        .stop_reason => |stop_reason| {
            var response: std.Io.Writer.Allocating = .init(active.alloc);
            defer response.deinit();
            try acp_types.writePromptResponse(&response.writer, stop_reason);
            try active.state.writer.writeResponse(active.alloc, active.msg.id, response.writer.buffered());
        },
        .rpc_error => |rpc_error| {
            try active.state.writer.writeError(active.alloc, active.msg.id, rpc_error);
        },
    }
}

fn reapActivePrompt(state: *ServerState, wait: bool) void {
    if (!host_target.is_wasm) {
        const active = state.active_prompt orelse return;
        if (!wait and !active.reapable.load(.seq_cst)) return;
        prompt_test_controls.noteReapBeforeJoin();
        active.thread.join();
        jsonrpc.freeMessage(active.alloc, &active.msg);
        active.alloc.destroy(active);
        state.active_prompt = null;
    }
}

fn cloneMessage(alloc: Allocator, msg: *const jsonrpc.Message) !jsonrpc.Message {
    var copy = jsonrpc.Message{
        .method = try alloc.dupe(u8, msg.method),
    };
    errdefer jsonrpc.freeMessage(alloc, &copy);
    if (msg.params_raw) |params| copy.params_raw = try alloc.dupe(u8, params);
    if (msg.id) |id| {
        copy.id = switch (id) {
            .integer => |value| .{ .integer = value },
            .string => |value| .{ .string = try alloc.dupe(u8, value) },
            .null => .null,
        };
    }
    return copy;
}

const InitializeRequest = struct {
    client_fs_read: bool = false,
    client_fs_write: bool = false,
    client_terminal: bool = false,
    client_elicitation: elicitation.Capabilities = .{},
};

fn parseInitializeRequest(
    alloc: Allocator,
    params: ?[]const u8,
) !InitializeRequest {
    const raw = params orelse return error.InvalidInitializeParams;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return error.InvalidInitializeParams;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInitializeParams;

    const version = parsed.value.object.get("protocolVersion") orelse
        return error.InvalidInitializeParams;
    if (version != .integer) return error.InvalidInitializeParams;
    if (version.integer < 0 or version.integer > std.math.maxInt(u16))
        return error.InvalidInitializeParams;

    var request = InitializeRequest{};
    const capabilities = parsed.value.object.get("clientCapabilities") orelse
        return request;
    if (capabilities != .object) return request;
    if (capabilities.object.get("fs")) |fs| {
        if (fs == .object) {
            if (fs.object.get("readTextFile")) |value| {
                request.client_fs_read = value == .bool and value.bool;
            }
            if (fs.object.get("writeTextFile")) |value| {
                request.client_fs_write = value == .bool and value.bool;
            }
        }
    }
    if (capabilities.object.get("terminal")) |value| {
        request.client_terminal = value == .bool and value.bool;
    }
    request.client_elicitation = elicitation.parseAcpCapabilities(capabilities);
    return request;
}

fn loadConfiguredStartupState(state: *const ServerState, alloc: Allocator) !app_lifecycle.StartupState {
    if (state.cfg.home_override) |home_dir| {
        if (state.cfg.workspace_root_override) |workspace_root| {
            return app_lifecycle.loadEmbeddedStartupState(
                alloc,
                home_dir,
                workspace_root,
                state.cfg.default_model,
                state.cfg.default_agent_step_limit,
            );
        }
    }
    return app_lifecycle.loadStartupState(
        alloc,
        state.cfg.gateway_provider.oauth_transport,
        state.cfg.secret_store,
        state.cfg.default_model,
        state.cfg.default_agent_step_limit,
    );
}

fn handleInitialize(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    if (state.initialized) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Already initialized",
        });
    }

    const request = parseInitializeRequest(alloc, msg.params_raw) catch {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid initialize params",
        });
    };

    var startup = loadConfiguredStartupState(state, alloc) catch {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to load startup state",
        });
    };
    defer startup.deinit(alloc);
    try app_lifecycle.applyWorkspaceLaunch(
        &startup,
        alloc,
        state.cfg.additional_directories,
        state.cfg.saved_directories_suppressed,
    );
    for (startup.config_diagnostics) |diagnostic| {
        if (diagnostic.recovery_path != null) {
            debug_trace.logf("config", "acp startup diagnostic layer={s} cause={s} recovery_available=true", .{
                @tagName(diagnostic.layer),
                @tagName(diagnostic.cause),
            });
        } else {
            debug_trace.logf("config", "acp startup diagnostic layer={s} cause={s}", .{
                @tagName(diagnostic.layer),
                @tagName(diagnostic.cause),
            });
        }
    }

    state.workspace_root = startup.takeWorkspaceRoot();
    state.workspace_access = startup.takeWorkspaceAccess();

    if (state.cfg.model_override) |override| {
        state.selected_model = try alloc.dupe(u8, override);
        alloc.free(startup.takeSelectedModel());
        state.process_model_override = true;
    } else {
        state.selected_model = startup.takeSelectedModel();
        state.process_model_override = startup.model_source == .process_override;
    }
    state.provider = startup.provider;
    state.configured_model = try alloc.dupe(u8, startup.configured_model);

    var startup_credential = startup.takeCredential();
    defer if (startup_credential) |*credential| credential.deinit(alloc);
    var routed_credential: ?credentials.Credential = null;
    defer if (routed_credential) |*credential| credential.deinit(alloc);
    const startup_matches_model = if (startup_credential) |credential|
        credentialMatchesProvider(credential.source, state.provider)
    else
        false;
    const credential: *credentials.Credential = if (state.provider == .gateway and state.cfg.credential_override != null) override: {
        routed_credential = .{
            .token = try alloc.dupe(u8, state.cfg.credential_override.?),
            .source = .ai_gateway_api_key,
        };
        break :override &routed_credential.?;
    } else if (startup_matches_model)
        &startup_credential.?
    else routed: {
        const preferred = if (startup_credential) |value| value.source else null;
        const resolution = try credentials.resolveForProvider(
            alloc,
            state.cfg.gateway_provider.oauth_transport,
            state.cfg.secret_store,
            .refresh_if_needed,
            state.provider,
            preferred,
        );
        routed_credential = resolution.credential;
        if (routed_credential == null) {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_request,
                .message = if (state.provider == .codex)
                    credentials.missing_chatgpt_credential_message
                else if (state.provider == .grok)
                    credentials.missing_grok_credential_message
                else
                    credentials.missing_credential_message,
            });
        }
        break :routed &routed_credential.?;
    };
    if (credential.token.len == 0) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = if (state.provider == .codex)
                credentials.missing_chatgpt_credential_message
            else if (state.provider == .grok)
                credentials.missing_grok_credential_message
            else
                credentials.missing_credential_message,
        });
    }
    adoptServerCredential(state, credential);

    state.permission_mode = startup.permission_mode;
    state.permission_rules = startup.takePermissionRules();
    state.agent_step_limit = startup.agent_step_limit;
    state.max_tool_result_bytes = startup.max_tool_result_bytes;
    state.context_limits = startup.context_limits;
    state.context_limits.applyCommandLine(state.cfg.context_limit_overrides);
    state.fast_mode = startup.fast_mode and
        (state.cfg.model_override == null or startup.fast_mode_source != .compiled_default);
    state.effort = startup.effort;
    state.first_call_tool_choice = startup.first_call_tool_choice;
    state.context_enabled = startup.context_enabled;

    if (comptime !host_target.is_wasm) {
        const loaded_skills = try app_runtime_setup.loadSkills(alloc, state.workspace_root, builtin_skills.root_policy);
        skill_runtime.traceDiagnostics("acp_startup", loaded_skills.diagnostics);
        state.skills.replaceLoaded(alloc, loaded_skills.dir, loaded_skills.skills, loaded_skills.diagnostics);
    }

    var catalog_cancel_flag = std.atomic.Value(bool).init(false);
    const startup_catalog = catalogProviderFor(state, state.provider) orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Selected provider is unavailable in this host",
        });
    _ = try state.capability_resolver.resolve(
        state.alloc,
        startup_catalog,
        .{
            .access = credentials.catalogAccessForCredentialAndAccount(
                state.credential_source,
                state.api_key,
                state.gateway_team,
                state.account_id,
            ),
            .endpoint = state.cfg.gateway_models_path,
            .cancel_flag = &catalog_cancel_flag,
        },
        state.selected_model,
    );

    state.client_fs_read = request.client_fs_read;
    state.client_fs_write = request.client_fs_write;
    state.client_terminal = request.client_terminal;
    state.client_elicitation = request.client_elicitation;
    state.initialized = true;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try acp_types.writeInitializeResponse(&out.writer);
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

fn handleCancel(state: *ServerState) void {
    if (state.active_session) |*session| {
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "source=acp active_tool_known=false", .{});
        session.cancel_flag.store(true, .seq_cst);
    }
    cancelPendingOutbound(state);
    clearPendingLegacyUrls(state);
}

pub fn cancelAndReapActivePrompt(state: *ServerState) void {
    handleCancel(state);
    reapActivePrompt(state, true);
}

fn handleCloseSession(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    const requested_id = if (parsed.value == .object)
        if (parsed.value.object.get("sessionId")) |value|
            if (value == .string and value.string.len > 0) value.string else null
        else
            null
    else
        null;
    const session_id = requested_id orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing sessionId",
        });
    const active = if (state.active_session) |*session| session else return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Session is not active",
    });
    if (!std.mem.eql(u8, active.session_id, session_id)) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Session is not active",
        });
    }

    cancelAndReapActivePrompt(state);
    closeActiveSession(state) catch |err| {
        debug_trace.logf(
            "session",
            "failed to flush ACP session usage during close session_id={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to close session cleanly",
        });
    };
    try state.writer.writeResponse(alloc, msg.id, "{}");
}

fn handleSetConfigOption(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Params must be object" });

    const config_id = blk: {
        if (root.object.get("configId")) |v| {
            if (v == .string) break :blk v.string;
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing configId" });
    };

    const value = blk: {
        if (root.object.get("value")) |v| {
            if (v == .string) break :blk v.string;
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing value" });
    };

    if (std.mem.eql(u8, config_id, "model")) {
        const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "No active session",
        });
        session_codec.validateModelPreference(value) catch
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid session model",
            });
        if (comptime !host_target.is_wasm) {
            if (session.provider != .gateway) {
                var model_available = false;
                if (state.capability_resolver.catalogEntries()) |entries| {
                    for (entries) |entry| {
                        if (std.mem.eql(u8, entry.id, value)) {
                            model_available = true;
                            break;
                        }
                    }
                }
                if (!model_available) {
                    return state.writer.writeError(alloc, msg.id, .{
                        .code = ErrorCode.invalid_params,
                        .message = "Model is not available for the active provider",
                    });
                }
                if (!try selectCredentialForProvider(state, session.provider)) {
                    return state.writer.writeError(alloc, msg.id, .{
                        .code = ErrorCode.invalid_request,
                        .message = if (session.provider == .codex)
                            credentials.missing_chatgpt_credential_message
                        else
                            credentials.missing_grok_credential_message,
                    });
                }
            }
        }
        if (host_target.is_wasm and session.writable == null) {
            const next_model = alloc.dupe(u8, value) catch
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Failed to update session model",
                });
            const previous_model = session.model;
            session.model = next_model;
            sessions.commitWasmSession(alloc, session) catch {
                session.model = previous_model;
                alloc.free(next_model);
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Failed to persist session model",
                });
            };
            alloc.free(previous_model);
        } else commitActiveSessionModel(
            alloc,
            session,
            value,
            session_test_controls.logOptions(),
        ) catch |err| {
            if (modelCommitFailureTerminatesConnection(err)) {
                try state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Failed to persist session model",
                });
                state.terminate_connection = true;
                return;
            }
            return state.writer.writeError(alloc, msg.id, .{
                .code = if (err == error.InvalidDurableField)
                    ErrorCode.invalid_params
                else
                    ErrorCode.internal_error,
                .message = if (err == error.InvalidDurableField)
                    "Invalid session model"
                else
                    "Failed to persist session model",
            });
        };
    } else if (std.mem.eql(u8, config_id, "provider")) {
        const target = model_provider.parse(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid provider",
            });
        const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "No active session",
        });
        if (target != session.provider) {
            if (host_target.is_wasm) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Subscription provider switching is unavailable in this WASM runtime",
                });
            }
            var staged_credential = if (target == .gateway and state.cfg.credential_override != null)
                credentials.Credential{
                    .token = try alloc.dupe(u8, state.cfg.credential_override.?),
                    .source = .ai_gateway_api_key,
                }
            else credential: {
                const resolution = try credentials.resolveForProvider(
                    alloc,
                    state.cfg.gateway_provider.oauth_transport,
                    state.cfg.secret_store,
                    .refresh_if_needed,
                    target,
                    null,
                );
                break :credential resolution.credential orelse
                    return state.writer.writeError(alloc, msg.id, .{
                        .code = ErrorCode.invalid_request,
                        .message = if (target == .codex)
                            credentials.missing_chatgpt_credential_message
                        else if (target == .grok)
                            credentials.missing_grok_credential_message
                        else
                            credentials.missing_credential_message,
                    });
            };
            defer staged_credential.deinit(alloc);
            if (!model_provider.authorizesCredential(target, staged_credential.source)) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Credential cannot authorize the selected provider",
                });
            }
            const catalog_provider = catalogProviderFor(state, target) orelse
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Selected provider is unavailable in this host",
                });
            const access = credentials.catalogAccessForCredentialAndAccount(
                staged_credential.source,
                staged_credential.token,
                staged_credential.gatewayTeam(),
                staged_credential.accountId(),
            );
            const fetched = try catalog_provider.fetch(alloc, .{
                .access = access,
                .endpoint = state.cfg.gateway_models_path,
                .cancel_flag = &session.cancel_flag,
                .view = .picker,
            });
            var catalog = switch (fetched) {
                .catalog => |catalog| catalog,
                .failure => return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Failed to load provider model catalog",
                }),
            };
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            if (catalog.items.len == 0) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Provider returned no supported models",
                });
            }
            var settings = if (state.cfg.home_override) |home|
                try config_runtime.loadMergedSettingsFromHome(alloc, home, state.workspace_root)
            else
                try config_runtime.loadMergedSettings(alloc, state.workspace_root);
            defer settings.deinit(alloc);
            const saved_model = switch (target) {
                .gateway => settings.model,
                .codex => settings.codex_model,
                .grok => settings.grok_model,
                .claude => settings.claude_model,
            };
            var selected_model = catalog.items[0].id;
            if (saved_model) |saved| {
                for (catalog.items) |entry| {
                    if (std.mem.eql(u8, entry.id, saved)) {
                        selected_model = entry.id;
                        break;
                    }
                }
            }
            commitActiveSessionProvider(
                alloc,
                session,
                target,
                selected_model,
                session_test_controls.logOptions(),
            ) catch |err| {
                if (modelCommitFailureTerminatesConnection(err)) {
                    state.terminate_connection = true;
                }
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.internal_error,
                    .message = "Failed to persist session provider",
                });
            };
            state.capability_resolver.adoptOwnedCatalog(alloc, &catalog);
            adoptServerCredential(state, &staged_credential);
        }
    } else if (std.mem.eql(u8, config_id, "mode")) {
        if (state.active_session) |*session| {
            state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
            defer state.subagent_authority_mutex.unlock(io_mod.getIo());
            applySessionMode(state.cfg.mode_registry, session, value);
        }
    }

    const current_model = if (state.active_session) |s| s.model else state.selected_model;
    const current_mode: []const u8 = if (state.active_session) |s| s.mode else state.cfg.mode_registry.default_mode_id;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try sessions.writeProviderConfigOption(
            &out.writer,
            if (state.active_session) |session| session.provider else state.provider,
        );
        try out.writer.writeAll(",");
    }
    try sessions.writeModelConfigOption(
        &out.writer,
        current_model,
        state.capability_resolver.catalogEntries(),
    );
    try out.writer.writeAll(",");
    try sessions.writeModeConfigOption(&out.writer, state.cfg.mode_registry, current_mode);
    try out.writer.writeAll("]}");
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

fn commitActiveSessionProvider(
    alloc: Allocator,
    session: *ActiveSessionState,
    provider: model_provider.ProviderId,
    model: []const u8,
    options: session_log.Options,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*active|
        active
    else
        return error.SessionPersistenceUnavailable;
    const staged_model = try alloc.dupe(u8, model);
    errdefer alloc.free(staged_model);
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{
            .provider = provider,
            .model = @constCast(model),
        } },
        io_mod.milliTimestamp(),
        .rollback_before_adapter_continue,
        options,
    );
    alloc.free(session.model);
    session.model = staged_model;
    session.provider = provider;
}

fn commitActiveSessionModel(
    alloc: Allocator,
    session: *ActiveSessionState,
    value: []const u8,
    options: session_log.Options,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*active|
        active
    else
        return error.SessionPersistenceUnavailable;
    try commitSessionModel(
        alloc,
        writable,
        &session.model,
        value,
        options,
    );
}

fn commitSessionModel(
    alloc: Allocator,
    writable: *session_store.LoadedWritableSession,
    active_model: *[]u8,
    value: []const u8,
    options: session_log.Options,
) !void {
    const staged_model = try alloc.dupe(u8, value);
    errdefer alloc.free(staged_model);
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .model = @constCast(value) } },
        io_mod.milliTimestamp(),
        .rollback_before_adapter_continue,
        options,
    );
    alloc.free(active_model.*);
    active_model.* = staged_model;
}

fn modelCommitFailureTerminatesConnection(err: anyerror) bool {
    return err == error.SessionCommitIndeterminate or
        err == error.SessionLogCompactionIndeterminate;
}

fn handleSetMode(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("modeId")) |v| {
            if (v == .string) {
                if (state.active_session) |*session| {
                    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
                    defer state.subagent_authority_mutex.unlock(io_mod.getIo());
                    applySessionMode(state.cfg.mode_registry, session, v.string);
                }
            }
        }
    }

    try state.writer.writeResponse(alloc, msg.id, "null");
}

pub fn applySessionMode(registry: mode_registry.Registry, session: *ActiveSessionState, id: []const u8) void {
    const mode = registry.lookup(id) orelse return;
    session.mode = mode.id;
    session.permission_mode = mode.permission_mode;
}

test "applySessionMode uses registered mode policy and ignores unknown modes" {
    const mode_specs = [_]mode_registry.ModeSpec{
        .{ .id = "inspect", .name = "Inspect", .permission_mode = .ask },
        .{ .id = "apply", .name = "Apply", .permission_mode = .auto },
    };
    const registry = mode_registry.Registry{
        .default_mode_id = "inspect",
        .modes = mode_specs[0..],
    };
    var session = ActiveSessionState{
        .session_id = @constCast("session"),
        .model = @constCast("model"),
        .mode = registry.default_mode_id,
        .workspace_root = "/tmp/workspace",
        .api_key = "",
        .agent_step_limit = 0,
        .max_tool_result_bytes = 0,
        .fast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .ask,
        .permission_rules = .{},
        .session_rt = .{ .max_history_turns = 0 },
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };

    applySessionMode(registry, &session, "apply");
    try std.testing.expectEqualStrings("apply", session.mode);
    try std.testing.expectEqual(types.PermissionMode.auto, session.permission_mode);

    applySessionMode(registry, &session, "inspect");
    try std.testing.expectEqualStrings("inspect", session.mode);
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);

    applySessionMode(registry, &session, "unknown");
    try std.testing.expectEqualStrings("inspect", session.mode);
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);

    applySessionMode(registry, &session, "apply");
    try std.testing.expectEqual(types.PermissionMode.auto, session.permission_mode);
    applySessionMode(registry, &session, "inspect");
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);
}

test "ACP notifications with absent id are not response targets" {
    const alloc = std.testing.allocator;
    var notification = try jsonrpc.parseMessage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"unknown/notification\",\"params\":{}}",
    );
    defer jsonrpc.freeMessage(alloc, &notification);
    try std.testing.expect(!shouldRespondToMessage(&notification));

    var null_id_request = try jsonrpc.parseMessage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"unknown/request\",\"params\":{}}",
    );
    defer jsonrpc.freeMessage(alloc, &null_id_request);
    try std.testing.expect(shouldRespondToMessage(&null_id_request));
}

test "ACP method parser classifies request dispatch methods" {
    try std.testing.expectEqual(AcpMethod.initialize, AcpMethod.parse("initialize"));
    try std.testing.expectEqual(AcpMethod.session_cancel, AcpMethod.parse("session/cancel"));
    try std.testing.expectEqual(AcpMethod.session_new, AcpMethod.parse("session/new"));
    try std.testing.expectEqual(AcpMethod.session_load, AcpMethod.parse("session/load"));
    try std.testing.expectEqual(AcpMethod.session_resume, AcpMethod.parse("session/resume"));
    try std.testing.expectEqual(AcpMethod.session_close, AcpMethod.parse("session/close"));
    try std.testing.expectEqual(AcpMethod.session_list, AcpMethod.parse("session/list"));
    try std.testing.expectEqual(AcpMethod.session_prompt, AcpMethod.parse("session/prompt"));
    try std.testing.expectEqual(AcpMethod.session_set_config_option, AcpMethod.parse("session/set_config_option"));
    try std.testing.expectEqual(AcpMethod.session_set_mode, AcpMethod.parse("session/set_mode"));
    try std.testing.expectEqual(AcpMethod.unknown, AcpMethod.parse("workspace/unknown"));
}

test "ACP prompt gate policy keeps lifecycle interruption responsive" {
    try std.testing.expect(!AcpMethod.initialize.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_cancel.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_new.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_load.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_resume.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_close.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.session_list.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.session_prompt.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.session_set_config_option.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_set_mode.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.unknown.waitsForActivePrompt());
}

test "ACP initialize request validation requires a uint16 protocol version" {
    const alloc = std.testing.allocator;
    const valid = try parseInitializeRequest(
        alloc,
        "{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":true},\"terminal\":true}}",
    );
    try std.testing.expect(valid.client_fs_read);
    try std.testing.expect(!valid.client_fs_write);
    try std.testing.expect(valid.client_terminal);

    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":0}");
    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":2}");
    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":65535}");

    const cases = [_]struct {
        params: ?[]const u8,
        expected: anyerror,
    }{
        .{ .params = null, .expected = error.InvalidInitializeParams },
        .{ .params = "{}", .expected = error.InvalidInitializeParams },
        .{ .params = "[]", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":\"one\"}", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":-1}", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":70000}", .expected = error.InvalidInitializeParams },
    };
    for (cases) |case| {
        try std.testing.expectError(
            case.expected,
            parseInitializeRequest(alloc, case.params),
        );
    }
}

test "ACP permission responses map canonical option ids" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, expected: types.ToolPermissionDecision }{
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_once\"}}", .expected = .once },
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_always\"}}", .expected = .always },
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"reject_once\"}}", .expected = .deny },
        .{ .json = "{\"outcome\":{\"outcome\":\"cancelled\"}}", .expected = .deny },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, parsePermissionDecision(parsed.value).?);
    }
    const malformed_cases = [_][]const u8{
        "{\"outcome\":{\"outcome\":\"selected\"}}",
        "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_forever\"}}",
        "{\"outcome\":{\"outcome\":\"granted\"}}",
        "{\"outcome\":\"selected\"}",
        "{}",
        "[]",
    };
    for (malformed_cases) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsePermissionDecision(parsed.value) == null);
    }
}

test "ACP outbound waiters resolve to deny on cancellation" {
    var state = ServerState{
        .alloc = std.testing.allocator,
        .cfg = undefined,
        .writer = jsonrpc.Writer.init(),
    };
    defer state.pending_outbound.deinit(state.alloc);

    const id = beginPermissionRequest(&state) orelse return error.TestExpectedEqual;
    const concurrent = beginPermissionRequest(&state) orelse return error.TestExpectedEqual;

    cancelPendingOutbound(&state);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&state, id));
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&state, concurrent));
    try std.testing.expectEqual(@as(usize, 0), state.pending_outbound.count());

    const second = beginPermissionRequest(&state) orelse return error.TestExpectedEqual;
    try std.testing.expect(second != id);
    cancelPermissionRequest(&state, second);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&state, second));
}

test "ACP outbound responses correlate out of order and ignore unknown ids" {
    const alloc = std.testing.allocator;
    var state = ServerState{
        .alloc = alloc,
        .cfg = undefined,
        .writer = jsonrpc.Writer.init(),
    };
    defer state.pending_outbound.deinit(alloc);

    const first = (try beginOutboundRequest(&state, .elicitation)).?;
    const second = (try beginOutboundRequest(&state, .elicitation)).?;
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = @intCast(second) },
        .result_raw = "{\"action\":\"decline\"}",
    });
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = 9999 },
        .result_raw = "{\"action\":\"accept\"}",
    });
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = @intCast(first) },
        .result_raw = "{\"action\":\"cancel\"}",
    });

    var second_response = awaitOutboundResponse(&state, second, .elicitation).?;
    defer second_response.deinit(alloc);
    try std.testing.expectEqualStrings("{\"action\":\"decline\"}", second_response.result_json.?);
    var first_response = awaitOutboundResponse(&state, first, .elicitation).?;
    defer first_response.deinit(alloc);
    try std.testing.expectEqualStrings("{\"action\":\"cancel\"}", first_response.result_json.?);
    try std.testing.expectEqual(@as(usize, 0), state.pending_outbound.count());
}

test "ACP legacy URL publication owns partial allocations" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var state = ServerState{
                .alloc = alloc,
                .cfg = undefined,
                .writer = jsonrpc.Writer.init(),
            };
            defer {
                clearPendingLegacyUrls(&state);
                state.pending_legacy_urls.deinit(alloc);
            }
            const reserved = try reserveLegacyUrl(
                &state,
                .{
                    .wire = .legacy_mcp_2025_11,
                    .server_name = "fixture",
                    .operation = .{ .tools_call = "echo" },
                    .connection_generation = 1,
                    .client_generation = 1,
                    .catalog_generation = 1,
                    .request_generation = 1,
                    .auth_generation = 1,
                    .deadline_ms = 1,
                },
                "legacy-id",
                "acp-id",
                "session-id",
                "tool-call-id",
            );
            try std.testing.expect(reserved);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "ACP legacy URL state requires consent and completion" {
    const alloc = std.testing.allocator;
    var state = ServerState{
        .alloc = alloc,
        .cfg = undefined,
        .writer = jsonrpc.Writer.init(),
    };
    defer {
        clearPendingLegacyUrls(&state);
        state.pending_legacy_urls.deinit(alloc);
    }
    const origin = tool_mcp_runtime.InputOrigin{
        .wire = .legacy_mcp_2025_11,
        .server_name = "fixture",
        .operation = .{ .tools_call = "echo" },
        .runtime_generation = 1,
        .connection_generation = 1,
        .client_generation = 2,
        .catalog_generation = 3,
        .request_generation = 4,
        .auth_generation = 5,
        .deadline_ms = std.math.maxInt(i64),
    };
    try std.testing.expect(try reserveLegacyUrl(
        &state,
        origin,
        "early",
        "acp-early",
        "session",
        "call",
    ));
    const sink = legacyUrlCompletionSink(&state);
    _ = sink.consume(sink.context, .{
        .server_name = "fixture",
        .elicitation_id = "early",
        .runtime_generation = 1,
        .connection_generation = 0,
        .client_generation = 1,
        .auth_generation = 4,
    });
    try std.testing.expectEqual(@as(usize, 1), state.pending_legacy_urls.items.len);
    try std.testing.expect(!state.pending_legacy_urls.items[0].completed);
    _ = sink.consume(sink.context, .{
        .server_name = "fixture",
        .elicitation_id = "early",
        .runtime_generation = 2,
        .connection_generation = 1,
        .client_generation = 2,
        .auth_generation = 5,
    });
    try std.testing.expectEqual(@as(usize, 1), state.pending_legacy_urls.items.len);
    try std.testing.expect(!state.pending_legacy_urls.items[0].completed);
    _ = sink.consume(sink.context, .{
        .server_name = "fixture",
        .elicitation_id = "early",
        .runtime_generation = 1,
        .connection_generation = 1,
        .client_generation = 2,
        .auth_generation = 5,
    });
    try std.testing.expectEqual(@as(usize, 1), state.pending_legacy_urls.items.len);
    try std.testing.expect(state.pending_legacy_urls.items[0].completed);
    try std.testing.expect(!state.pending_legacy_urls.items[0].accepted);
    removeLegacyUrl(&state, "acp-early");
    try std.testing.expectEqual(@as(usize, 0), state.pending_legacy_urls.items.len);

    try std.testing.expect(try reserveLegacyUrl(
        &state,
        origin,
        "late",
        "acp-late",
        "session",
        "call",
    ));
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlAcceptTransition.awaiting_completion,
        acceptLegacyUrl(&state, origin, "acp-late"),
    );
    try std.testing.expect(state.pending_legacy_urls.items[0].accepted);
    try std.testing.expect(!state.pending_legacy_urls.items[0].completed);
    removeLegacyUrl(&state, "acp-late");

    try std.testing.expect(try reserveLegacyUrl(
        &state,
        origin,
        "publish",
        "acp-publish",
        "session",
        "call",
    ));
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlAcceptTransition.awaiting_completion,
        acceptLegacyUrl(&state, origin, "acp-publish"),
    );
    const publication = sink.consume(sink.context, .{
        .server_name = "fixture",
        .elicitation_id = "publish",
        .runtime_generation = 1,
        .connection_generation = 1,
        .client_generation = 2,
        .auth_generation = 5,
    }).consumed.?;
    defer alloc.free(publication);
    try std.testing.expectEqualStrings("acp-publish", publication);
    try std.testing.expectEqual(@as(usize, 0), state.pending_legacy_urls.items.len);

    try std.testing.expect(try reserveLegacyUrl(
        &state,
        origin,
        "old-a",
        "acp-old-a",
        "session",
        "call",
    ));
    try std.testing.expect(try reserveLegacyUrl(
        &state,
        origin,
        "old-b",
        "acp-old-b",
        "session",
        "call",
    ));
    var refreshed_catalog = origin;
    refreshed_catalog.catalog_generation = 4;
    try std.testing.expect(!try reserveLegacyUrl(
        &state,
        refreshed_catalog,
        "old-a",
        "acp-old-a-refresh",
        "session",
        "call",
    ));
    try std.testing.expectEqual(@as(usize, 2), state.pending_legacy_urls.items.len);
    var recovered = origin;
    recovered.runtime_generation = 2;
    recovered.catalog_generation = 4;
    try std.testing.expect(try reserveLegacyUrl(
        &state,
        recovered,
        "old-a",
        "acp-new",
        "session",
        "call",
    ));
    try std.testing.expectEqual(@as(usize, 1), state.pending_legacy_urls.items.len);
    try std.testing.expectEqual(@as(u64, 2), state.pending_legacy_urls.items[0].binding.runtime_generation);
    try std.testing.expectEqual(@as(u64, 1), state.pending_legacy_urls.items[0].binding.connection_generation);
    removeLegacyUrl(&state, "acp-old-a");
    try std.testing.expectEqual(@as(usize, 1), state.pending_legacy_urls.items.len);
    try std.testing.expectEqualStrings("acp-new", state.pending_legacy_urls.items[0].acp_id);
    removeLegacyUrl(&state, "acp-new");
}

const AcpModelBoundaryFailure = struct {
    target: session_log.Boundary,

    fn hit(raw: ?*anyopaque, point: session_log.Boundary) !void {
        const self: *AcpModelBoundaryFailure = @ptrCast(@alignCast(raw.?));
        if (point == self.target) return error.InjectedBoundaryFailure;
    }

    fn options(self: *AcpModelBoundaryFailure) session_log.Options {
        return .{ .test_controls = .{
            .context = self,
            .boundary_fn = hit,
        } };
    }
};

fn acpModelTestState(
    alloc: Allocator,
    id: []const u8,
    workspace_root: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin_workspace_root = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin_workspace_root);
    const current_workspace_root = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(current_workspace_root);
    const model = try alloc.dupe(u8, "old-model");
    errdefer alloc.free(model);
    const history = try alloc.alloc(session_runtime.HistoryTurn, 0);
    return .{
        .id = owned_id,
        .origin_workspace_root = origin_workspace_root,
        .workspace_root = current_workspace_root,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = model,
            .effort = .auto,
            .fast_mode = false,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

test "ACP model commit rolls back before later request can succeed" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var state = try acpModelTestState(alloc, "acp-model-rollback", workspace);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    var active_model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active_model);
    var failure = AcpModelBoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        commitSessionModel(
            alloc,
            &writable,
            &active_model,
            "rejected-model",
            failure.options(),
        ),
    );
    try std.testing.expectEqualStrings("old-model", active_model);
    try std.testing.expectEqualStrings(
        "old-model",
        writable.state.preferences.model,
    );
    try std.testing.expect(writable.degradedTail() == null);

    try commitSessionModel(
        alloc,
        &writable,
        &active_model,
        "accepted-model",
        .{},
    );
    try std.testing.expectEqualStrings("accepted-model", active_model);
    try std.testing.expectEqualStrings(
        "accepted-model",
        writable.state.preferences.model,
    );
}

test "ACP indeterminate model commit leaves staged runtime value unapplied" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var state = try acpModelTestState(
        alloc,
        "acp-model-indeterminate",
        workspace,
    );
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    var active_model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active_model);
    var failure = AcpModelBoundaryFailure{
        .target = .after_target_namespace_sync,
    };

    const result = commitSessionModel(
        alloc,
        &writable,
        &active_model,
        "uncertain-model",
        failure.options(),
    );
    try std.testing.expectError(error.SessionCommitIndeterminate, result);
    try std.testing.expectEqualStrings("old-model", active_model);
    try std.testing.expect(
        modelCommitFailureTerminatesConnection(
            error.SessionCommitIndeterminate,
        ),
    );
    try std.testing.expect(
        modelCommitFailureTerminatesConnection(
            error.SessionLogCompactionIndeterminate,
        ),
    );
}

test "ACP model commits honor the active session write boundary" {
    const alloc = std.testing.allocator;
    var active: ActiveSessionState = undefined;
    active.writable = null;
    active.session_write_mutex = .init;
    active.model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active.model);

    const Worker = struct {
        alloc: Allocator,
        active: *ActiveSessionState,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .seq_cst);
            commitActiveSessionModel(
                self.alloc,
                self.active,
                "new-model",
                .{},
            ) catch |err| {
                self.failure = err;
            };
            self.done.store(true, .seq_cst);
        }
    };
    var worker = Worker{
        .alloc = alloc,
        .active = &active,
    };
    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!worker.started.load(.seq_cst)) std.Thread.yield() catch {};
    for (0..100) |_| std.Thread.yield() catch {};
    const blocked_at_boundary = !worker.done.load(.seq_cst);
    active.session_write_mutex.unlock(io_mod.getIo());
    thread.join();

    try std.testing.expect(blocked_at_boundary);
    try std.testing.expect(worker.done.load(.seq_cst));
    try std.testing.expectEqual(
        error.SessionPersistenceUnavailable,
        worker.failure.?,
    );
}

test "ACP publishes an account-bound refreshed Codex token for later prompts" {
    const alloc = std.testing.allocator;
    var state: ServerState = undefined;
    state.alloc = alloc;
    state.api_key = try alloc.dupe(u8, "stale-token");
    state.account_id = try alloc.dupe(u8, "acct-1");
    state.credential_source = .chatgpt_subscription;
    var active: ActiveSessionState = undefined;
    active.api_key = state.api_key;
    active.account_id = state.account_id;
    active.credential_source = .chatgpt_subscription;
    state.active_session = active;
    defer {
        secret.zeroAndFree(alloc, state.api_key);
        alloc.free(state.account_id.?);
    }

    try publishRefreshedSubscriptionToken(&state, "fresh-token", .chatgpt_subscription, "acct-1");

    try std.testing.expectEqualStrings("fresh-token", state.api_key);
    try std.testing.expectEqualStrings("fresh-token", state.active_session.?.api_key);
    try std.testing.expectEqualStrings("acct-1", state.account_id.?);
    try std.testing.expectEqualStrings("acct-1", state.active_session.?.account_id.?);
}

test "ACP rejects refreshed Codex tokens for another account" {
    const alloc = std.testing.allocator;
    var state: ServerState = undefined;
    state.alloc = alloc;
    state.api_key = try alloc.dupe(u8, "stale-token");
    state.account_id = try alloc.dupe(u8, "acct-1");
    state.credential_source = .chatgpt_subscription;
    state.active_session = null;
    defer {
        secret.zeroAndFree(alloc, state.api_key);
        alloc.free(state.account_id.?);
    }

    try std.testing.expectError(
        error.ChatGptAccountChanged,
        publishRefreshedSubscriptionToken(&state, "wrong-token", .chatgpt_subscription, "acct-2"),
    );
    try std.testing.expectEqualStrings("stale-token", state.api_key);
}

test "ACP usage flush preserves snapshot ownership on allocation failure" {
    const alloc = std.testing.allocator;
    var runtime: session_runtime.SessionRuntime = .{ .max_history_turns = 8 };
    var runtime_owned = true;
    defer if (runtime_owned) runtime.deinit(alloc);
    try runtime.appendAssistantHistoryTurn(alloc, "question", "answer");
    const sequence = try runtime.usage.reserveInvocation();
    try runtime.usage.finishObservedInvocation(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );

    var durable = try acpModelTestState(
        alloc,
        "acp-usage-flush",
        "/tmp/workspace",
    );
    var durable_owned = true;
    defer if (durable_owned) durable.deinit(alloc);
    durable.usage = try runtime.usage.snapshot(alloc);

    var writable: session_store.LoadedWritableSession = undefined;
    writable.state = durable;
    durable_owned = false;
    var active: ActiveSessionState = undefined;
    active.writable = writable;
    active.session_rt = runtime;
    runtime_owned = false;
    var state: ServerState = undefined;
    state.active_session = active;
    defer {
        state.active_session.?.session_rt.deinit(alloc);
        state.active_session.?.writable.?.state.deinit(alloc);
    }

    var counting = std.testing.FailingAllocator.init(alloc, .{});
    {
        var current = try state.active_session.?.writable.?.state.dupe(
            counting.allocator(),
        );
        defer current.deinit(counting.allocator());
        const history = try state.active_session.?.session_rt.snapshotHistory(
            counting.allocator(),
        );
        defer types.freeHistoryTurnSlice(counting.allocator(), history);
    }

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = counting.alloc_index },
    );
    state.alloc = failing.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        flushActiveSessionUsage(&state),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(
        failing.allocated_bytes,
        failing.freed_bytes,
    );
}
