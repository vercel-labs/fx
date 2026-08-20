const std = @import("std");
const builtin = @import("builtin");

const api_key_validator_contract = @import("../gateway/auth/api_key_validator.zig");
const adapter_auth = @import("../core/gateway/adapter_auth.zig");
const adapter_registry = @import("../core/gateway/adapter_registry.zig");
const agent_stream_provider_contract = @import("../core/agent/stream_provider.zig");
const agent_runtime_telemetry = @import("../core/agent/runtime/telemetry.zig");
const credentials = @import("../gateway/auth/credentials.zig");
const login_flow = @import("../gateway/auth/login_flow.zig");
const oauth_session = @import("../gateway/auth/oauth_session.zig");
const oauth_transport = @import("../gateway/auth/oauth_transport.zig");
const secret = @import("../core/auth/secret.zig");
const collections = @import("../core/shared/collections.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_error_format = @import("../gateway/gateway_error_format.zig");
const gateway_client = @import("../gateway/client.zig");
const gateway_failure_diagnostics = @import("../gateway/gateway_failure_diagnostics.zig");
const gateway_json = @import("../gateway/gateway_json.zig");
const io_mod = @import("../core/shared/io.zig");
const host = @import("../core/hosts/host.zig");
const gateway_generation_usage = @import("../gateway/generation_usage.zig");
const connection_registry = @import("../core/gateway/connection_registry.zig");
const route_snapshot_contract = @import("../core/gateway/route_snapshot.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const account_usage_provider = @import("../core/gateway/account_usage_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_descriptors = @import("gateway/model_descriptors.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const shared_types = @import("../core/shared/types.zig");
const session_usage = @import("../core/session/session_usage.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");
const gateway_schema = @import("../core/tooling/gateway_schema.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const sort_utils = @import("../core/shared/sort_utils.zig");

const Allocator = std.mem.Allocator;
const FetchGatewayGetResultFn = *const fn (Allocator, ?[]const u8, []const u8) anyerror!gateway_client.GetResult;

const Request = web_search_contract.ProviderRequest;
const Response = web_search_contract.ProviderResponse;
const ProgressFn = web_search_contract.ProgressFn;

pub const default_model = "zai/glm-5.2";
pub const default_fast_mode = true;
pub const default_chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model";
pub const models_path = "/coding-agent/v1/models";
const credits_path = "/coding-agent/v1/credits";
pub const retry_count: usize = 3;
pub const chat_url_env = "FX_GATEWAY_CHAT_URL";
pub const default_model_catalog_base_url = "https://ai-gateway.vercel.sh";
const base_url_env = "FX_GATEWAY_BASE_URL";
const e2e_gateway_models_url_env = "FX_E2E_GATEWAY_MODELS_URL";
const oauth_request_timeout_ms: i64 = 15_000;
const oauth_response_max_bytes: usize = 64 * 1024;

pub const connection_seed = connection_registry.Seed{
    .id = "vercel",
    .display_name = "Vercel AI Gateway",
    .adapter_id = "vercel_ai_gateway",
    .endpoint = default_chat_url,
    .protocol = "vercel_ai_gateway",
    .credential_ref = "automatic",
    .internal_models = .{
        .permission_review = "zai/glm-5.2",
        .vision = "google/gemini-2.5-flash",
    },
};

const web_search_system_prompt = "Research the user's query with the web_search tool and preserve sources for citation.";
const perplexity_search_backend_id = web_search_contract.SearchBackendId{ .value = "ai_gateway_perplexity_search" };
const parallel_search_backend_id = web_search_contract.SearchBackendId{ .value = "ai_gateway_parallel_search" };
const default_web_search_backend_order = [_]web_search_contract.SearchBackendId{
    perplexity_search_backend_id,
    parallel_search_backend_id,
};
const perplexity_search_backend = [_]web_search_contract.SearchBackendId{perplexity_search_backend_id};
const parallel_search_backend = [_]web_search_contract.SearchBackendId{parallel_search_backend_id};
const default_web_search_backend_policies = [_]web_search_policy.BackendPolicy{
    .{
        .id = perplexity_search_backend_id,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .post_filter,
        },
    },
    .{
        .id = parallel_search_backend_id,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .pass_through,
        },
    },
};

pub const default_web_search_policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = &default_web_search_backend_order,
    .backend_policies = &default_web_search_backend_policies,
};

pub const default_web_search_provider = web_search_provider.Provider{
    .policy = default_web_search_policy,
    .input_overhead_bytes = web_search_system_prompt.len,
    .preferred_backends_fn = resolvePreferredWebSearchBackends,
    .execute_fn = executeWebSearchProvider,
};

pub const chat_url_provider = gateway_provider.ChatUrlProvider{
    .resolve_fn = resolveChatUrlForProvider,
};

pub const account_usage = account_usage_provider.Provider{
    .fetch_fn = fetchCredits,
};

pub const api_key_validator = api_key_validator_contract.Provider{
    .validate_fn = validateApiKey,
};

pub const oauth_transport_provider = oauth_transport.Provider{
    .execute_fn = executeOAuthRequest,
};

pub const generation_usage_provider = gateway_generation_usage.provider;
pub const model_descriptor_provider = model_descriptors.provider;

pub const agent_stream_provider = agent_stream_provider_contract.Provider{
    .build_fn = buildAgentRequest,
    .stream_fn = streamAgentCompletion,
};

/// The transport must outlive every operation through the returned provider.
pub fn auth_provider_for_transport(transport: *const oauth_transport.Provider) adapter_auth.Provider {
    return .{
        .kind = connection_seed.adapter_id,
        .context = transport,
        .acquire_fn = acquireVercelCredential,
        .logout_fn = logoutVercel,
        .start_sign_in_fn = startVercelSignIn,
        .load_teams_fn = loadVercelTeams,
        .invalidate_fn = invalidateVercelCredential,
        .status_fn = loadVercelStatus,
    };
}

fn native_auth_provider() adapter_auth.Provider {
    var value = auth_provider_for_transport(&oauth_transport_provider);
    value.login_fn = runVercelLogin;
    value.teams_fn = runVercelTeams;
    return value;
}

pub const auth_provider = native_auth_provider();

pub const provider_adapter = agent_stream_provider_contract.ProviderAdapter{
    .kind = connection_seed.adapter_id,
    .auth = auth_provider,
    .account_usage = account_usage,
    .generation_usage = generation_usage_provider,
    .model_catalog = model_catalog_provider,
    .model_descriptors = model_descriptors.provider,
    .provider_tools = &.{.web_search},
    .web_search = default_web_search_provider,
    .stream_fn = streamVercelAdapter,
};

const production_adapters = [_]agent_stream_provider_contract.ProviderAdapter{provider_adapter};

pub const production_adapter_registry = adapter_registry.AdapterRegistry{
    .adapters = &production_adapters,
};

pub const provider = gateway_provider.Provider{
    .connection_seed = connection_seed,
    .agent_stream = agent_stream_provider,
    .provider_adapter = provider_adapter,
    .adapter_registry = production_adapter_registry,
    .oauth_transport = oauth_transport_provider,
    .chat_url = chat_url_provider,
};

fn vercelTransport(raw: *const anyopaque) oauth_transport.Provider {
    return @as(*const oauth_transport.Provider, @ptrCast(@alignCast(raw))).*;
}

fn credentialSourceFromReference(reference: []const u8) !?credentials.Source {
    if (std.mem.eql(u8, reference, "automatic")) return null;
    return shared_types.parseCredentialSource(reference) orelse error.InvalidCredentialReference;
}

fn normalizeAuthFailure(err: anyerror) adapter_auth.Failure {
    std.debug.assert(err != error.Cancelled);
    return .{ .category = switch (err) {
        error.ClientIdMissing, error.InvalidCredentialReference => .configuration,
        error.AccessDenied => .denied,
        error.ExpiredToken, error.LoginTimedOut => .expired,
        error.NoSession => .missing_session,
        error.NoTeams => .no_teams,
        error.SessionChanged => .session_changed,
        error.InvalidTeamSelection => .invalid_selection,
        error.SessionDeleteFailed => .persistence,
        else => .unavailable,
    } };
}

fn normalizedSource(source: credentials.Source) adapter_auth.Source {
    return .{
        .id = @tagName(source),
        .label = credentials.sourceLabel(source),
        .refreshable = credentials.sourceRefreshable(source),
    };
}

pub fn credentialOverrideSource(reference: []const u8) !adapter_auth.Source {
    return normalizedSource((try credentialSourceFromReference(reference)) orelse .ai_gateway_api_key);
}

fn normalizedCatalogAccess(access: credentials.CatalogAccess) adapter_auth.CatalogAccess {
    return switch (access) {
        .authenticated => .authenticated,
        .public_only => |value| .{ .public_only = switch (value) {
            .no_credential => .no_credential,
            .fx_login_team_required => .tenant_required,
            .fx_login_refresh_required => .refresh_required,
            .credential_refresh_failed => .refresh_failed,
            .authenticated_credential_rejected => .credential_rejected,
        } },
    };
}

fn takeNormalizedCredential(credential: *credentials.Credential) adapter_auth.Credential {
    const source = credential.source;
    const catalog_access = normalizedCatalogAccess(credentials.catalogAccessAt(credential.*, io_mod.milliTimestamp()));
    const result = adapter_auth.Credential{
        .secret_bytes = credential.token,
        .source = normalizedSource(source),
        .tenant_id = credential.team_id,
        .tenant_slug = credential.team_slug,
        .refresh_after_ms = credential.refresh_after_ms,
        .catalog_access = catalog_access,
    };
    credential.token = &.{};
    credential.team_id = null;
    credential.team_slug = null;
    return result;
}

fn normalizedStoreStatus(status: credentials.StoredKeyReadStatus) adapter_auth.StoreStatus {
    return switch (status) {
        .not_attempted => .not_attempted,
        .not_found => .not_found,
        .unavailable => .unavailable,
    };
}

fn normalizedAcquisitionFailure(err: anyerror) adapter_auth.Acquisition {
    if (err == error.Cancelled) return .cancelled;
    return .{ .failed = normalizeAuthFailure(err) };
}

fn acquireVercelCredential(
    raw: *const anyopaque,
    alloc: Allocator,
    request: adapter_auth.Request,
) Allocator.Error!adapter_auth.Acquisition {
    const transport = vercelTransport(raw);

    const resolution = switch (request.mode) {
        .stored, .if_needed => acquisition: {
            const source = credentialSourceFromReference(
                request.current_source_id orelse request.profile.credential_ref,
            ) catch return .{ .failed = .{ .category = .configuration } };
            const resolved = switch (request.source_resolution) {
                .allow_fallback => credentials.resolvePreferring(
                    alloc,
                    transport,
                    request.host.secret_store,
                    if (request.mode == .stored) .stored else .refresh_if_needed,
                    source,
                ),
                .exact => if (source) |selected|
                    credentials.resolveExact(
                        alloc,
                        transport,
                        request.host.secret_store,
                        if (request.mode == .stored) .stored else .refresh_if_needed,
                        selected,
                    )
                else
                    return .{ .missing = .not_attempted },
            } catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return normalizedAcquisitionFailure(err);
            };
            break :acquisition resolved;
        },
        .force => force: {
            const source_id = request.current_source_id orelse
                return .{ .failed = .{ .category = .configuration } };
            if (!std.mem.eql(u8, source_id, @tagName(credentials.Source.fx_login))) {
                return .{ .failed = .{ .category = .unavailable } };
            }
            const credential = credentials.refreshFxLoginCredential(alloc, transport) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return normalizedAcquisitionFailure(err);
            };
            if (credential == null) return .{ .missing = .not_attempted };
            break :force credentials.Resolution{ .credential = credential };
        },
    };
    if (resolution.credential) |value| {
        var credential = value;
        defer credential.deinit(alloc);
        return .{ .acquired = takeNormalizedCredential(&credential) };
    }
    return .{ .missing = normalizedStoreStatus(resolution.stored_key_status) };
}

fn runVercelLogin(
    raw: *const anyopaque,
    alloc: Allocator,
    _: connection_registry.Profile,
    auth_host: adapter_auth.AuthHost,
) Allocator.Error!adapter_auth.OperationOutcome {
    login_flow.runLogin(alloc, vercelTransport(raw), auth_host.url_opener) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .cancelled;
        return .{ .failed = normalizeAuthFailure(err) };
    };
    return .succeeded;
}

fn logoutVercel(
    raw: *const anyopaque,
    alloc: Allocator,
    _: connection_registry.Profile,
    _: adapter_auth.AuthHost,
) Allocator.Error!adapter_auth.LogoutOutcome {
    const result = login_flow.logout(alloc, vercelTransport(raw)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .cancelled;
        return .{ .failed = normalizeAuthFailure(err) };
    };
    return .{ .completed = .{
        .session_deleted = result.session_deleted,
        .local_durability_failed = result.local_durability_failed,
        .remote_revocation_failed = result.remote_revocation_failed,
    } };
}

fn runVercelTeams(
    raw: *const anyopaque,
    alloc: Allocator,
    _: connection_registry.Profile,
    _: adapter_auth.AuthHost,
) Allocator.Error!adapter_auth.OperationOutcome {
    login_flow.runTeams(alloc, vercelTransport(raw)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .cancelled;
        return .{ .failed = normalizeAuthFailure(err) };
    };
    return .succeeded;
}

const VercelTeamSelection = struct {
    selection: login_flow.TeamSelection,
    teams: []adapter_auth.Team,
};

fn takeVercelTeamSelection(
    alloc: Allocator,
    selection: *login_flow.TeamSelection,
) Allocator.Error!adapter_auth.TeamSelection {
    const team_count = selection.teams.items.len;
    const state = try alloc.create(VercelTeamSelection);
    errdefer alloc.destroy(state);
    state.* = .{
        .selection = selection.take(),
        .teams = &.{},
    };
    errdefer state.selection.deinit(alloc);
    state.teams = try alloc.alloc(adapter_auth.Team, team_count);
    for (state.selection.teams.items, 0..) |team, index| {
        state.teams[index] = .{ .id = team.id, .slug = team.slug, .name = team.name };
    }
    return .{
        .context = state,
        .teams = state.teams,
        .current_team = state.selection.currentTeam(),
        .select_fn = selectVercelTeam,
        .deinit_fn = deinitVercelTeamSelection,
    };
}

fn selectVercelTeam(raw: ?*anyopaque, alloc: Allocator, index: usize) Allocator.Error!adapter_auth.SelectOutcome {
    const state: *VercelTeamSelection = @ptrCast(@alignCast(raw.?));
    const selected = state.selection.select(alloc, index) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = normalizeAuthFailure(err) };
    };
    return .{ .selected = .{ .id = selected.id, .slug = selected.slug } };
}

fn deinitVercelTeamSelection(raw: ?*anyopaque, alloc: Allocator) void {
    const state: *VercelTeamSelection = @ptrCast(@alignCast(raw.?));
    state.selection.deinit(alloc);
    alloc.free(state.teams);
    alloc.destroy(state);
}

const VercelSignIn = struct {
    runtime: login_flow.SignInRuntime = .{},
};

fn startVercelSignIn(
    raw: *const anyopaque,
    alloc: Allocator,
    _: connection_registry.Profile,
    _: adapter_auth.AuthHost,
) Allocator.Error!adapter_auth.StartSignInOutcome {
    const state = try alloc.create(VercelSignIn);
    state.* = .{};
    const started = state.runtime.start(alloc, vercelTransport(raw)) catch |err| {
        state.runtime.deinit(alloc);
        alloc.destroy(state);
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .cancelled;
        return .{ .failed = normalizeAuthFailure(err) };
    };
    if (!started) {
        state.runtime.deinit(alloc);
        alloc.destroy(state);
        return .busy;
    }
    return .{ .started = .{
        .context = state,
        .snapshot_fn = snapshotVercelSignIn,
        .browser_url_fn = vercelSignInBrowserUrl,
        .poll_fn = pollVercelSignIn,
        .cancel_fn = cancelVercelSignIn,
        .deinit_fn = deinitVercelSignIn,
    } };
}

fn snapshotVercelSignIn(raw: ?*anyopaque) adapter_auth.SignInSnapshot {
    const state: *VercelSignIn = @ptrCast(@alignCast(raw.?));
    const snapshot = state.runtime.snapshot();
    return .{
        .state = switch (snapshot.state) {
            .idle => .idle,
            .polling => .polling,
            .succeeded => .succeeded,
            .failed => .failed,
            .cancelled => .cancelled,
        },
        .verification_uri = snapshot.verification_uri,
        .verification_uri_complete = snapshot.verification_uri_complete,
        .user_code = snapshot.user_code,
    };
}

fn vercelSignInBrowserUrl(raw: ?*anyopaque, alloc: Allocator) Allocator.Error!?[]u8 {
    const state: *VercelSignIn = @ptrCast(@alignCast(raw.?));
    return state.runtime.browserUrlAlloc(alloc);
}

fn pollVercelSignIn(raw: ?*anyopaque, alloc: Allocator) Allocator.Error!adapter_auth.SignInTransition {
    const state: *VercelSignIn = @ptrCast(@alignCast(raw.?));
    state.runtime.pulse(alloc);
    return switch (state.runtime.pollTransition(alloc)) {
        .none => .none,
        .cancelled => .cancelled,
        .failed => |err| if (err == error.Cancelled)
            .cancelled
        else
            .{ .failed = normalizeAuthFailure(err) },
        .succeeded => |value| blk: {
            var selection = value;
            defer selection.deinit(alloc);
            break :blk .{ .succeeded = try takeVercelTeamSelection(alloc, &selection) };
        },
    };
}

fn cancelVercelSignIn(raw: ?*anyopaque, alloc: Allocator) bool {
    const state: *VercelSignIn = @ptrCast(@alignCast(raw.?));
    return state.runtime.cancel(alloc);
}

fn deinitVercelSignIn(raw: ?*anyopaque, alloc: Allocator) void {
    const state: *VercelSignIn = @ptrCast(@alignCast(raw.?));
    state.runtime.deinit(alloc);
    alloc.destroy(state);
}

fn loadVercelTeams(
    raw: *const anyopaque,
    alloc: Allocator,
    _: connection_registry.Profile,
    _: adapter_auth.AuthHost,
) Allocator.Error!adapter_auth.TeamsOutcome {
    var selection = login_flow.loadTeamSelection(alloc, vercelTransport(raw)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .cancelled;
        return .{ .failed = normalizeAuthFailure(err) };
    };
    defer selection.deinit(alloc);
    return .{ .loaded = try takeVercelTeamSelection(alloc, &selection) };
}

fn invalidateVercelCredential(
    _: *const anyopaque,
    _: connection_registry.Profile,
    failure: adapter_auth.Failure,
) adapter_auth.Invalidation {
    return .{ .drop_credential = failure.category == .denied };
}

fn loadVercelStatus(
    raw: *const anyopaque,
    alloc: Allocator,
    profile: connection_registry.Profile,
    auth_host: adapter_auth.AuthHost,
) Allocator.Error!adapter_auth.StatusOutcome {
    const acquisition = try acquireVercelCredential(raw, alloc, .{
        .profile = profile,
        .host = auth_host,
        .mode = .stored,
        .source_resolution = .allow_fallback,
    });
    var credential = switch (acquisition) {
        .acquired => |value| value,
        .missing => |store_status| return .{ .loaded = .{
            .store_status = store_status,
        } },
        .failed => |failure| return .{ .failed = failure },
        .cancelled => return .cancelled,
    };
    defer credential.deinit(alloc);
    const owned_team = if (credential.tenant_slug) |value| blk: {
        credential.tenant_slug = null;
        break :blk value;
    } else if (credential.tenant_id) |value| blk: {
        credential.tenant_id = null;
        break :blk value;
    } else null;
    return .{ .loaded = .{
        .source = credential.source,
        .team = owned_team,
        .expired = if (credential.refresh_after_ms) |deadline| deadline <= io_mod.milliTimestamp() else false,
    } };
}

const AdapterEventBridge = struct {
    events: agent_stream_provider_contract.EventSink,
    failure: ?anyerror = null,
    saw_text: bool = false,

    fn emit(self: *AdapterEventBridge, event: agent_stream_provider_contract.StreamEvent) void {
        if (self.failure != null) return;
        self.events.emit(event) catch |err| {
            self.failure = err;
        };
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        const self: *AdapterEventBridge = @ptrCast(@alignCast(raw));
        self.saw_text = true;
        self.emit(.{ .text_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        const self: *AdapterEventBridge = @ptrCast(@alignCast(raw));
        self.emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        const self: *AdapterEventBridge = @ptrCast(@alignCast(raw));
        self.emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(
        raw: *anyopaque,
        id: []const u8,
        name: []const u8,
        label: ?[]const u8,
    ) void {
        const self: *AdapterEventBridge = @ptrCast(@alignCast(raw));
        self.emit(.{ .tool_input_started = .{ .id = id, .name = name, .label = label } });
    }
};

const VercelTransportOutcome = union(enum) {
    cancelled,
    normalized: agent_stream_provider_contract.StreamFailure,
    propagate: anyerror,
};

fn classifyVercelTransportError(
    err: anyerror,
    cancel_requested: bool,
    delivery_ambiguous: bool,
) VercelTransportOutcome {
    if (err == error.Cancelled or cancel_requested) return .cancelled;
    const cause: agent_stream_provider_contract.StreamFailure.TransportCause = switch (err) {
        error.ReadFailed => .read_failed,
        error.ConnectionResetByPeer => .connection_reset,
        error.ConnectionTimedOut => .connection_timed_out,
        error.HttpConnectionClosing => .connection_closing,
        error.SystemResumed => .system_resumed,
        else => return .{ .propagate = err },
    };
    return .{ .normalized = .{
        .category = .transport,
        .retryable = true,
        .delivery_ambiguous = delivery_ambiguous,
        .detail = @errorName(err),
        .transport_cause = cause,
    } };
}

const VercelHttpFailureFacts = struct {
    category: agent_stream_provider_contract.StreamFailure.Category,
    retryable: bool,
};

fn classifyVercelHttpFailure(status: std.http.Status) VercelHttpFailureFacts {
    const code: u16 = @intFromEnum(status);
    return .{
        .category = switch (status) {
            .unauthorized => .authentication,
            .forbidden => .authorization,
            .request_timeout, .gateway_timeout => .timeout,
            .too_many_requests => .rate_limited,
            .bad_request => .configuration,
            .unprocessable_entity => .invalid_content,
            .payload_too_large => .request_too_large,
            .internal_server_error => .provider_internal,
            .bad_gateway => .upstream_failure,
            .service_unavailable => .unavailable,
            else => .protocol,
        },
        .retryable = code == 408 or code == 425 or code == 429 or code >= 500,
    };
}

test "Vercel transport classification preserves every recovery transition" {
    const cases = [_]struct {
        err: anyerror,
        cause: agent_stream_provider_contract.StreamFailure.TransportCause,
    }{
        .{ .err = error.ReadFailed, .cause = .read_failed },
        .{ .err = error.ConnectionResetByPeer, .cause = .connection_reset },
        .{ .err = error.ConnectionTimedOut, .cause = .connection_timed_out },
        .{ .err = error.HttpConnectionClosing, .cause = .connection_closing },
        .{ .err = error.SystemResumed, .cause = .system_resumed },
    };
    for (cases) |case| {
        const outcome = classifyVercelTransportError(case.err, false, true);
        try std.testing.expect(outcome == .normalized);
        try std.testing.expectEqual(case.cause, outcome.normalized.transport_cause.?);
        try std.testing.expect(outcome.normalized.retryable);
        try std.testing.expect(outcome.normalized.delivery_ambiguous);
    }

    try std.testing.expect(classifyVercelTransportError(error.Cancelled, false, false) == .cancelled);
    try std.testing.expect(classifyVercelTransportError(error.ReadFailed, true, false) == .cancelled);
    const oom = classifyVercelTransportError(error.OutOfMemory, false, false);
    try std.testing.expect(oom == .propagate);
    try std.testing.expectEqual(error.OutOfMemory, oom.propagate);
    const terminal = classifyVercelTransportError(error.UnknownHostName, false, false);
    try std.testing.expect(terminal == .propagate);
    try std.testing.expectEqual(error.UnknownHostName, terminal.propagate);
}

test "Vercel HTTP classification preserves exact neutral codes and retry policy" {
    const cases = [_]struct {
        status: std.http.Status,
        category: agent_stream_provider_contract.StreamFailure.Category,
        adapter_retryable: bool,
    }{
        .{ .status = .payment_required, .category = .protocol, .adapter_retryable = false },
        .{ .status = .not_found, .category = .protocol, .adapter_retryable = false },
        .{ .status = .request_timeout, .category = .timeout, .adapter_retryable = true },
        .{ .status = .too_many_requests, .category = .rate_limited, .adapter_retryable = true },
        .{ .status = .bad_gateway, .category = .upstream_failure, .adapter_retryable = true },
        .{ .status = .gateway_timeout, .category = .timeout, .adapter_retryable = true },
    };
    for (cases) |case| {
        const facts = classifyVercelHttpFailure(case.status);
        try std.testing.expectEqual(case.category, facts.category);
        try std.testing.expectEqual(case.adapter_retryable, facts.retryable);
    }
}

pub fn streamVercelAdapter(
    adapter: *const agent_stream_provider_contract.ProviderAdapter,
    alloc: Allocator,
    request: agent_stream_provider_contract.AdapterRequest,
    events: agent_stream_provider_contract.EventSink,
) anyerror!void {
    const stream_provider = adapter.legacy_provider orelse agent_stream_provider;
    const built_payload = try stream_provider.build(alloc, request.model_request);
    const payload = try finalizeAgentRequestBody(alloc, request.model_id, built_payload);
    defer alloc.free(payload);
    debug_trace.eventf("gateway", "after_payload_build", request.trace_ctx, "payload_bytes={d} model={s} gateway_messages={d}", .{
        payload.len,
        request.model_id,
        request.model_request.messages.len,
    });
    agent_runtime_telemetry.traceGatewayRequestBuilt(
        request.trace_ctx,
        request.model_id,
        payload.len,
        request.model_request.messages.len,
        .{
            .local_count = request.model_request.tools.len,
            .provider_count = request.model_request.provider_tools.len,
        },
    );
    if (request.serialized_request_limit_bytes) |limit| {
        if (payload.len > limit) {
            try events.emit(.{ .failure = .{
                .category = .request_too_large,
                .detail = "serialized provider request exceeds the configured limit",
            } });
            return;
        }
    }
    try events.emit(.provider_admitted);

    var bridge = AdapterEventBridge{ .events = events };
    var result = stream_provider.stream(alloc, .{
        .api_key = request.credential,
        .team = request.tenant,
        .session_id = request.session_id,
        .model = request.model_id,
        .retry_count = request.retry_count,
        .chat_url = request.route.endpoint,
        .payload = payload,
        .trace_ctx = request.trace_ctx,
        .content_capture_limit = request.content_capture_limit,
        .cooperative_pulse = request.cooperative_pulse,
        .delivery = request.delivery,
        .attempt_evidence = request.attempt_evidence,
        .callback_ctx = &bridge,
        .on_content_chunk = AdapterEventBridge.content,
        .on_tool_start = AdapterEventBridge.toolStart,
        .on_reasoning_chunk = AdapterEventBridge.reasoning,
        .on_tool_input_chunk = AdapterEventBridge.toolInput,
        .cancel_flag = request.cancel_flag,
        .provider_attempt_owner = request.provider_attempt_owner,
    }) catch |err| {
        if (bridge.failure) |failure| return failure;
        switch (classifyVercelTransportError(
            err,
            request.cancel_flag.load(.seq_cst),
            request.delivery.load() == .possibly_sent,
        )) {
            .cancelled => try events.emit(.cancelled),
            .normalized => |failure| {
                try events.emit(.{ .failure = failure });
                return err;
            },
            .propagate => |failure| return failure,
        }
        return;
    };
    defer result.deinit(alloc);
    if (bridge.failure) |failure| return failure;

    if (result.status == .ok) {
        if (!bridge.saw_text) {
            if (result.completion.content) |content| try events.emit(.{ .text_delta = content });
        }
        tool_calls: for (result.completion.tool_calls) |call| switch (call.provenance) {
            .fx_local => try events.emit(.{ .fx_tool_call = call }),
            .provider_executed => {
                var started = call;
                started.provider_result = null;
                events.emit(.{ .provider_tool_started = started }) catch |err| {
                    if (err == error.DuplicateProviderToolStart and result.completion.provider_result_identity_failure != null) break :tool_calls;
                    if (err == error.DuplicateProviderToolStart) return error.MalformedAuthoritativeToolIdentity;
                    return err;
                };
                if (call.provider_result) |provider_result| {
                    try events.emit(.{ .provider_tool_result = .{
                        .call_id = call.id,
                        .result = provider_result,
                    } });
                }
            },
        };
        try events.emit(.{ .usage = .{
            .tokens = result.completion.usage,
            .billing = if (result.completion.billing) |billing| .{
                .created_at_ms = billing.created_at_ms,
                .model_id = billing.model,
                .total_cost = billing.total_cost,
                .input_tokens = billing.input_tokens,
                .output_tokens = billing.output_tokens,
                .cache_read_tokens = billing.cache_read_tokens,
                .cache_write_tokens = billing.cache_write_tokens,
                .reasoning_tokens = billing.reasoning_tokens,
                .billable_web_search_calls = billing.billable_web_search_calls,
            } else null,
        } });
        try events.emit(.{ .finish = .{
            .reason = result.completion.finish_reason,
            .generation_reference = if (result.completion.generation_id) |id| .{
                .id = id,
                .lookup_scope = result.generation_origin,
            } else null,
            .generation_metadata_invalid = result.completion.generation_metadata_invalid,
            .delivery_ambiguous = result.completion.delivery_ambiguous,
            .provider_result_identity_failure = result.completion.provider_result_identity_failure,
            .provider_failure_detail = result.completion.provider_failure_detail,
        } });
    } else {
        const failure_facts = classifyVercelHttpFailure(result.status);
        const raw_detail = result.err_body orelse "";
        const detail = try gateway_error_format.formatHttpErrorMessage(
            alloc,
            result.status,
            raw_detail,
        );
        defer alloc.free(detail);
        const recovery_diagnostic = try gateway_error_format.formatHttpRecoveryDiagnostic(
            alloc,
            result.status,
            raw_detail,
        );
        defer alloc.free(recovery_diagnostic);
        try events.emit(.{ .failure = .{
            .category = failure_facts.category,
            .retryable = failure_facts.retryable,
            .response_code = @intFromEnum(result.status),
            .delivery_ambiguous = result.completion.delivery_ambiguous,
            .detail = detail,
            .retry_after_seconds = result.retry_after_seconds,
            .diagnostic = .{
                .summary = result.failure_schema orelse recovery_diagnostic,
                .request_shape = result.failure_request_shape,
            },
        } });
    }
}

test "Vercel adapter sink failure does not mutate user cancellation" {
    const FakeLegacy = struct {
        fn build(_: ?*anyopaque, alloc: Allocator, _: agent_stream_provider_contract.BuildRequest) anyerror![]u8 {
            return alloc.dupe(u8, "{}");
        }

        fn stream(_: ?*anyopaque, _: Allocator, request: agent_stream_provider_contract.Request) anyerror!agent_stream_provider_contract.Result {
            request.on_content_chunk(request.callback_ctx, "chunk");
            return .{ .status = .ok, .completion = .{ .finish_reason = .stop } };
        }
    };
    const RejectingSink = struct {
        fn emit(_: *anyopaque, _: agent_stream_provider_contract.StreamEvent) anyerror!void {
            return error.TestSinkFailure;
        }
    };

    var adapter = provider_adapter;
    adapter.legacy_provider = .{
        .build_fn = FakeLegacy.build,
        .stream_fn = FakeLegacy.stream,
    };
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = agent_stream_provider_contract.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider_contract.AttemptEvidence = .{};
    var state = agent_stream_provider_contract.EventState.init(std.testing.allocator);
    defer state.deinit();
    var sink_error: ?anyerror = null;
    var sink_context: u8 = 0;
    var route = route_snapshot_contract.RouteSnapshot{
        .connection_id = @constCast("vercel"),
        .adapter_kind = @constCast(connection_seed.adapter_id),
        .endpoint = @constCast("provider:endpoint"),
        .protocol = @constCast("vercel_ai_gateway"),
        .credential_ref = @constCast("automatic"),
        .primary_model_id = @constCast("test/model"),
        .permission_review_model_id = null,
        .vision_model_id = null,
        .subagent_model_id = @constCast("test/model"),
        .capabilities = .{},
        .capability_source = .configured,
        .selected_fast_mode = false,
        .fast_model_suffix = null,
    };
    try std.testing.expectError(error.TestSinkFailure, adapter.stream(std.testing.allocator, .{
        .model_request = .{
            .tools = &.{},
            .messages = &.{},
            .tool_choice = .none,
            .capabilities = .{},
        },
        .route = &route,
        .credential = "credential",
        .tenant = null,
        .model_id = "test/model",
        .retry_count = 1,
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .cancel_flag = &cancelled,
    }, .{
        .context = &sink_context,
        .state = &state,
        .sink_error = &sink_error,
        .emit_fn = RejectingSink.emit,
    }));
    try std.testing.expectEqual(error.TestSinkFailure, sink_error.?);
    try std.testing.expect(!cancelled.load(.seq_cst));
}

test "Vercel adapter enforces serialized request limit before admission" {
    const FakeLegacy = struct {
        payload: []const u8,
        calls: usize = 0,

        fn build(raw: ?*anyopaque, alloc: Allocator, _: agent_stream_provider_contract.BuildRequest) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return alloc.dupe(u8, self.payload);
        }

        fn stream(raw: ?*anyopaque, _: Allocator, _: agent_stream_provider_contract.Request) anyerror!agent_stream_provider_contract.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return .{ .status = .ok, .completion = .{ .finish_reason = .stop } };
        }
    };
    const Capture = struct {
        admitted: usize = 0,
        failures: usize = 0,
        finishes: usize = 0,

        fn emit(raw: *anyopaque, event: agent_stream_provider_contract.StreamEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .provider_admitted => self.admitted += 1,
                .failure => |failure| {
                    try std.testing.expectEqual(agent_stream_provider_contract.StreamFailure.Category.request_too_large, failure.category);
                    self.failures += 1;
                },
                .finish => self.finishes += 1,
                else => {},
            }
        }
    };

    const accepted_payload = "x" ** (16 * 1024);
    const rejected_payload = accepted_payload ++ "x";
    var fake = FakeLegacy{ .payload = rejected_payload };
    var adapter = provider_adapter;
    adapter.legacy_provider = .{
        .context = &fake,
        .build_fn = FakeLegacy.build,
        .stream_fn = FakeLegacy.stream,
    };
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = agent_stream_provider_contract.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider_contract.AttemptEvidence = .{};
    var route = route_snapshot_contract.RouteSnapshot{
        .connection_id = @constCast("vercel"),
        .adapter_kind = @constCast(connection_seed.adapter_id),
        .endpoint = @constCast("provider:endpoint"),
        .protocol = @constCast("vercel_ai_gateway"),
        .credential_ref = @constCast("automatic"),
        .primary_model_id = @constCast("test/model"),
        .permission_review_model_id = null,
        .vision_model_id = null,
        .subagent_model_id = @constCast("test/model"),
        .capabilities = .{},
        .capability_source = .configured,
        .selected_fast_mode = false,
        .fast_model_suffix = null,
    };
    const request = agent_stream_provider_contract.AdapterRequest{
        .model_request = .{
            .tools = &.{},
            .messages = &.{},
            .tool_choice = .none,
            .capabilities = .{},
        },
        .serialized_request_limit_bytes = 16 * 1024,
        .route = &route,
        .credential = "credential",
        .tenant = null,
        .model_id = "test/model",
        .retry_count = 1,
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .cancel_flag = &cancelled,
    };

    var state = agent_stream_provider_contract.EventState.init(std.testing.allocator);
    defer state.deinit();
    var sink_error: ?anyerror = null;
    var capture: Capture = .{};
    try adapter.stream(std.testing.allocator, request, .{
        .context = &capture,
        .state = &state,
        .sink_error = &sink_error,
        .emit_fn = Capture.emit,
    });
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), capture.admitted);
    try std.testing.expectEqual(@as(usize, 1), capture.failures);
    try std.testing.expect(!state.provider_admitted);

    state.deinit();
    state = agent_stream_provider_contract.EventState.init(std.testing.allocator);
    fake.payload = accepted_payload;
    capture = .{};
    sink_error = null;
    try adapter.stream(std.testing.allocator, request, .{
        .context = &capture,
        .state = &state,
        .sink_error = &sink_error,
        .emit_fn = Capture.emit,
    });
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.admitted);
    try std.testing.expectEqual(@as(usize, 1), capture.finishes);
    try std.testing.expect(state.provider_admitted);
}

test "Vercel and peer adapters receive equivalent neutral requests with isolated wire formats" {
    const Probe = struct {
        vercel_calls: usize = 0,
        peer_calls: usize = 0,
        peer_received_neutral_tools: bool = false,
        vercel_payload: ?[]u8 = null,

        fn deinit(self: *@This(), alloc: Allocator) void {
            if (self.vercel_payload) |payload| alloc.free(payload);
            self.* = undefined;
        }

        fn vercelStream(
            raw: ?*anyopaque,
            alloc: Allocator,
            request: agent_stream_provider_contract.Request,
        ) anyerror!agent_stream_provider_contract.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.vercel_calls += 1;
            self.vercel_payload = try alloc.dupe(u8, request.payload);
            return .{
                .status = .bad_gateway,
                .err_body = @constCast("peer unavailable"),
            };
        }

        fn peerStream(
            adapter: *const agent_stream_provider_contract.ProviderAdapter,
            _: Allocator,
            request: agent_stream_provider_contract.AdapterRequest,
            events: agent_stream_provider_contract.EventSink,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(adapter.context.?));
            self.peer_calls += 1;
            self.peer_received_neutral_tools = request.model_request.tools.len == 2 and
                std.mem.eql(u8, request.model_request.tools[0].name, "read_file") and
                std.mem.eql(u8, request.model_request.tools[1].name, "mcp_read") and
                request.model_request.provider_tools.len == 1;
            try events.emit(.{ .failure = .{
                .category = .upstream_failure,
                .detail = "peer unavailable",
            } });
        }
    };
    const Capture = struct {
        category: ?agent_stream_provider_contract.StreamFailure.Category = null,
        response_code: ?u16 = null,
        retryable: bool = false,
        saw_http_detail: bool = false,

        fn emit(raw: *anyopaque, event: agent_stream_provider_contract.StreamEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (event == .failure) {
                self.category = event.failure.category;
                self.response_code = event.failure.response_code;
                self.retryable = event.failure.retryable;
                if (event.failure.detail) |detail| {
                    self.saw_http_detail = std.mem.find(u8, detail, "HTTP 502") != null;
                }
            }
        }
    };
    const makeRoute = struct {
        fn call(kind: []const u8) route_snapshot_contract.RouteSnapshot {
            return .{
                .connection_id = @constCast(kind),
                .adapter_kind = @constCast(kind),
                .endpoint = @constCast("provider:endpoint"),
                .protocol = @constCast(kind),
                .credential_ref = @constCast("automatic"),
                .primary_model_id = @constCast("test/model"),
                .permission_review_model_id = null,
                .vision_model_id = null,
                .subagent_model_id = @constCast("test/model"),
                .capabilities = .{},
                .capability_source = .configured,
                .selected_fast_mode = false,
                .fast_model_suffix = null,
            };
        }
    }.call;

    const alloc = std.testing.allocator;
    var probe: Probe = .{};
    defer probe.deinit(alloc);
    var vercel = provider_adapter;
    vercel.legacy_provider = .{
        .context = &probe,
        .build_fn = buildAgentRequest,
        .stream_fn = Probe.vercelStream,
    };
    const peer = agent_stream_provider_contract.ProviderAdapter{
        .kind = "test_peer",
        .context = &probe,
        .stream_fn = Probe.peerStream,
    };
    const adapters = [_]agent_stream_provider_contract.ProviderAdapter{ vercel, peer };
    const registry = try adapter_registry.AdapterRegistry.init(&adapters);
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const tools = [_]gateway_schema.FunctionSchema{
        .{ .name = "read_file", .description = "Read" },
        .{ .name = "mcp_read", .description = "MCP read" },
    };
    const neutral_request = agent_stream_provider_contract.ModelRequest{
        .tools = &tools,
        .provider_tools = &.{.{ .tool = .web_search, .local_schema_position = 1 }},
        .messages = &messages,
        .tool_choice = .auto,
        .capabilities = .{},
    };
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = agent_stream_provider_contract.DeliveryCertainty.init();
    var vercel_attempt: agent_stream_provider_contract.AttemptEvidence = .{};
    var peer_attempt: agent_stream_provider_contract.AttemptEvidence = .{};
    var sink_error: ?anyerror = null;
    var vercel_capture: Capture = .{};
    var vercel_state = agent_stream_provider_contract.EventState.init(alloc);
    defer vercel_state.deinit();
    var vercel_route = makeRoute(connection_seed.adapter_id);
    try (try registry.resolve(connection_seed.adapter_id)).stream(alloc, .{
        .model_request = neutral_request,
        .route = &vercel_route,
        .credential = "wire-secret",
        .tenant = null,
        .model_id = "test/model",
        .retry_count = 1,
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &vercel_attempt,
        .cancel_flag = &cancelled,
    }, .{
        .context = &vercel_capture,
        .state = &vercel_state,
        .sink_error = &sink_error,
        .emit_fn = Capture.emit,
    });

    var peer_capture: Capture = .{};
    var peer_state = agent_stream_provider_contract.EventState.init(alloc);
    defer peer_state.deinit();
    var peer_route = makeRoute("test_peer");
    try (try registry.resolve("test_peer")).stream(alloc, .{
        .model_request = neutral_request,
        .route = &peer_route,
        .credential = "peer-secret",
        .tenant = null,
        .model_id = "test/model",
        .retry_count = 1,
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &peer_attempt,
        .cancel_flag = &cancelled,
    }, .{
        .context = &peer_capture,
        .state = &peer_state,
        .sink_error = &sink_error,
        .emit_fn = Capture.emit,
    });

    try std.testing.expectEqual(@as(usize, 1), probe.vercel_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.peer_calls);
    try std.testing.expect(probe.peer_received_neutral_tools);
    try std.testing.expectEqual(agent_stream_provider_contract.StreamFailure.Category.upstream_failure, vercel_capture.category.?);
    try std.testing.expectEqual(agent_stream_provider_contract.StreamFailure.Category.upstream_failure, peer_capture.category.?);
    try std.testing.expectEqual(@as(?u16, 502), vercel_capture.response_code);
    try std.testing.expect(vercel_capture.retryable);
    try std.testing.expect(peer_capture.response_code == null);
    try std.testing.expect(!peer_capture.retryable);
    try std.testing.expect(vercel_capture.saw_http_detail);
    try std.testing.expect(!peer_capture.saw_http_detail);
    try std.testing.expect(std.mem.find(u8, probe.vercel_payload.?, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.find(u8, probe.vercel_payload.?, "gateway.perplexity_search") != null);
    try std.testing.expect(std.mem.find(u8, probe.vercel_payload.?, "wire-secret") == null);
    try std.testing.expect(std.mem.find(u8, probe.vercel_payload.?, "peer-secret") == null);
}

pub fn buildAgentRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.BuildRequest,
) anyerror![]u8 {
    const provider_options = model_capabilities.resolveProviderOptionsForCapabilities(
        request.capabilities,
        request.reasoning_effort,
        request.fast_mode,
    );
    const budget: ?gateway_json.BuildBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        null;
    if (budget) |active| try active.check();

    const adapter_tools_json = try buildVercelToolsJson(alloc, request);
    defer alloc.free(adapter_tools_json);

    if (request.verified_images) |images| {
        const response_format = request.response_format orelse
            return error.MissingStructuredResponseFormat;
        return gateway_json.buildGatewayRequestBodyWithVerifiedImagesAndBudget(
            alloc,
            adapter_tools_json,
            request.messages,
            images,
            provider_options,
            request.tool_choice,
            .{
                .name = response_format.name,
                .description = response_format.description,
                .schema_json = response_format.schema_json,
            },
            budget orelse .{},
        );
    }
    if (request.response_format != null) return error.StructuredResponseRequiresVerifiedImages;

    if (request.required_tool_call_id) |target_call_id| {
        const active = budget orelse return error.PendingToolReviewRequiresBudget;
        return gateway_json.buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
            alloc,
            adapter_tools_json,
            request.messages,
            target_call_id,
            provider_options,
            request.max_output_tokens orelse 2048,
            active.deadline orelse return error.PendingToolReviewRequiresDeadline,
            active.cancel_flag orelse return error.PendingToolReviewRequiresCancellation,
        );
    }
    if (request.require_tool_call) {
        return if (budget) |active|
            gateway_json.buildGatewayRequiredToolRequestBodyWithOptionsAndBudget(
                alloc,
                adapter_tools_json,
                request.messages,
                provider_options,
                request.max_output_tokens,
                active,
            )
        else
            gateway_json.buildGatewayRequiredToolRequestBodyWithOptionsAndOutputLimit(
                alloc,
                adapter_tools_json,
                request.messages,
                provider_options,
                request.max_output_tokens,
            );
    }

    return if (budget) |active|
        gateway_json.buildGatewayRequestBodyWithOptionsAndBudget(
            alloc,
            adapter_tools_json,
            request.messages,
            provider_options,
            request.tool_choice,
            request.max_output_tokens,
            active,
        )
    else
        gateway_json.buildGatewayRequestBodyWithOptionsAndOutputLimit(
            alloc,
            adapter_tools_json,
            request.messages,
            provider_options,
            request.tool_choice,
            request.max_output_tokens,
        );
}

fn finalizeAgentRequestBody(
    alloc: Allocator,
    model: []const u8,
    body: []u8,
) ![]u8 {
    if (!std.mem.eql(u8, model, "zai/glm-5.2")) return body;

    errdefer alloc.free(body);
    const identified = try gateway_json.withRequestUserAgent(
        alloc,
        body,
        gateway_client.user_agent,
    );
    alloc.free(body);
    return identified;
}

fn buildVercelToolsJson(
    alloc: Allocator,
    request: agent_stream_provider_contract.ModelRequest,
) ![]u8 {
    const PositionedSchema = struct {
        position: usize,
        json: []const u8,
    };
    var provider_schemas: std.ArrayList(PositionedSchema) = .empty;
    defer provider_schemas.deinit(alloc);
    var owned_schemas: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_schemas.items) |schema| alloc.free(schema);
        owned_schemas.deinit(alloc);
    }

    for (request.provider_tools) |advertisement| {
        const schema = switch (advertisement.tool) {
            .web_search => try vercelWebSearchToolJson(alloc),
        };
        owned_schemas.append(alloc, schema) catch |err| {
            alloc.free(schema);
            return err;
        };
        try provider_schemas.append(alloc, .{
            .position = advertisement.local_schema_position,
            .json = schema,
        });
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var provider_index: usize = 0;
    var first = true;
    try out.writer.writeByte('[');
    for (0..request.tools.len + 1) |position| {
        while (provider_index < provider_schemas.items.len and
            provider_schemas.items[provider_index].position == position)
        {
            if (!first) try out.writer.writeByte(',');
            first = false;
            try out.writer.writeAll(provider_schemas.items[provider_index].json);
            provider_index += 1;
        }
        if (position < request.tools.len) {
            if (!first) try out.writer.writeByte(',');
            first = false;
            try writeVercelFunctionSchema(
                alloc,
                &out.writer,
                request.tools[position],
            );
        }
    }
    if (provider_index != provider_schemas.items.len) return error.InvalidGatewayAdvertisement;
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn writeVercelFunctionSchema(
    alloc: Allocator,
    writer: *std.Io.Writer,
    schema: gateway_schema.FunctionSchema,
) !void {
    try schema.validate();
    var capped_description: ?[]u8 = null;
    defer if (capped_description) |description| alloc.free(description);
    if (schema.description.len > gateway_schema.description_max_bytes) {
        const prefix_len = gateway_schema.description_max_bytes - gateway_schema.truncation_marker.len;
        const description = try alloc.alloc(u8, gateway_schema.description_max_bytes);
        @memcpy(description[0..prefix_len], schema.description[0..prefix_len]);
        @memcpy(description[prefix_len..], gateway_schema.truncation_marker);
        capped_description = description;
    }

    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(schema.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(capped_description orelse schema.description, .{}, writer);
    try writer.writeAll(",\"inputSchema\":");
    try gateway_schema.writeInputSchema(alloc, writer, schema);
    try writer.writeByte('}');
}

fn vercelWebSearchToolJson(alloc: Allocator) ![]u8 {
    const policy = default_web_search_policy;
    const tools_json = try providerToolsJson(alloc, .{
        .backend = try selectedWebSearchBackend(),
        .max_results = policy.max_results,
        .max_output_tokens = policy.max_output_tokens,
        .max_output_chars = policy.max_output_chars,
    });
    defer alloc.free(tools_json);
    if (tools_json.len < 2 or tools_json[0] != '[' or tools_json[tools_json.len - 1] != ']') {
        return error.InvalidGatewayAdvertisement;
    }
    return alloc.dupe(u8, tools_json[1 .. tools_json.len - 1]);
}

test "agent request builder keeps default reasoning silent and emits output limit" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .tools = &.{},
        .messages = &messages,
        .tool_choice = .auto,
        .capabilities = model_capabilities.capabilitiesForModel("anthropic/claude-opus-4.8"),
        .max_output_tokens = 32_000,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":32000") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"providerOptions\"") == null);
}

test "agent request builder serializes neutral provider search beside local tools" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .tools = &.{.{ .name = "read_file", .description = "Read" }},
        .provider_tools = &.{.{ .tool = .web_search, .local_schema_position = 1 }},
        .messages = &messages,
        .tool_choice = .auto,
        .capabilities = model_descriptor_provider.fallback("anthropic/claude").capabilities,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"id\":\"gateway.perplexity_search\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"web_search\"") == null);
    try std.testing.expect(
        std.mem.find(u8, body, "\"name\":\"read_file\"").? <
            std.mem.find(u8, body, "\"name\":\"perplexity_search\"").?,
    );
}

test "agent request builder overlays selected dynamic schemas" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "question" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .tools = &.{.{ .name = "mcp_fs_read", .description = "Read" }},
        .messages = &messages,
        .tool_choice = .auto,
        .capabilities = model_descriptor_provider.fallback("anthropic/claude").capabilities,
        .max_output_tokens = 64_000,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"mcp_fs_read\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":64000") != null);
}

test "required vision request contains only the registered vision schema" {
    const messages = [_]shared_types.ChatMessage{.{ .role = .user, .content = "inspect image 7" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .tools = &.{.{
            .name = "vision",
            .description = "registry-owned vision schema sentinel",
        }},
        .messages = &messages,
        .tool_choice = .none,
        .require_tool_call = true,
        .capabilities = model_descriptor_provider.fallback("zai/glm-5.2").capabilities,
        .max_output_tokens = 128_000,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"toolChoice\":{\"type\":\"required\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"vision\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "registry-owned vision schema sentinel") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"read_file\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"mcp_fs_read\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":128000") != null);
}

fn streamAgentCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.Request,
) anyerror!agent_stream_provider_contract.Result {
    const result = gateway_client.streamGatewayCompletion(
        alloc,
        .{
            .api_key = request.api_key,
            .team = request.team,
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .chat_url = request.chat_url,
            .payload = request.payload,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.content_capture_limit,
            .delivery = request.delivery,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
            .provider_attempt_owner = switch (request.provider_attempt_owner) {
                .transport => .transport,
                .agent => .agent,
            },
        },
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.cancel_flag,
    ) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
        return err;
    };
    const diagnostics = if (result.status == .ok)
        gateway_failure_diagnostics.FailureDiagnostics{}
    else
        gateway_failure_diagnostics.collect(alloc, request.payload, result.err_body);
    return .{
        .status = result.status,
        .completion = result.completion,
        .err_body = result.err_body,
        .generation_origin = gateway_client.generationBaseUrl(),
        .reconcile_generation_usage = true,
        .failure_schema = diagnostics.schema,
        .failure_request_shape = diagnostics.request_shape,
        .retry_after_seconds = result.retry_after_seconds,
        .ownership = .owned,
    };
}

fn fetchCredits(
    _: ?*anyopaque,
    alloc: Allocator,
    input: account_usage_provider.Input,
) output_contracts.CreditsSnapshot {
    return fetchCreditsWithFetch(
        alloc,
        input.credential,
        input.tenant,
        gateway_client.fetchGatewayGetResult,
    );
}

/// An fx login can reach several teams, so `/v1/credits` rejects it outright
/// unless the request names one. The endpoint reads the team from a `teamId`
/// query value and ignores `x-vercel-ai-gateway-team`, which is the reverse of
/// the inference endpoint. An API key carries its own team and resolves to no
/// team here, so the query value is added for logins only.
fn fetchCreditsWithFetch(
    alloc: Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    fetch_fn: FetchGatewayGetResultFn,
) output_contracts.CreditsSnapshot {
    var team_path: ?[]u8 = null;
    defer if (team_path) |path| alloc.free(path);
    if (gateway_team) |team| {
        if (shared_types.validGatewayTeam(team)) {
            team_path = std.fmt.allocPrint(alloc, "{s}?teamId={s}", .{ credits_path, team }) catch {
                return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
            };
        } else {
            debug_trace.logf("credits", "team omitted from query; not url safe len={d}", .{team.len});
        }
    }

    var result = fetch_fn(alloc, api_key, team_path orelse credits_path) catch {
        return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
    };
    defer result.deinit(alloc);

    if (result.status != .ok) {
        const message = gateway_error_format.formatHttpErrorMessage(alloc, result.status, result.body) catch {
            return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
        };
        return .{ .err_message = message };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, result.body, .{}) catch {
        return creditsErrorSnapshot(alloc, "invalid JSON response from gateway");
    };
    defer parsed.deinit();

    return creditsSnapshotFromJsonValue(alloc, parsed.value) catch {
        return creditsErrorSnapshot(alloc, "invalid JSON response from gateway");
    };
}

fn creditsSnapshotFromJsonValue(
    alloc: Allocator,
    value: std.json.Value,
) !output_contracts.CreditsSnapshot {
    if (value != .object) {
        return creditsErrorSnapshot(alloc, "unexpected response format from gateway");
    }

    const obj = value.object;
    var snapshot = output_contracts.CreditsSnapshot{};
    errdefer snapshot.deinit(alloc);

    if (obj.get("balance")) |field| {
        if (field == .string) snapshot.balance = try alloc.dupe(u8, field.string);
    }
    if (obj.get("used")) |field| {
        if (field == .string) snapshot.used = try alloc.dupe(u8, field.string);
    }
    if (obj.get("plan")) |field| {
        if (field == .string) snapshot.plan = try alloc.dupe(u8, field.string);
    }

    return snapshot;
}

fn creditsErrorSnapshot(
    alloc: Allocator,
    message: []const u8,
) output_contracts.CreditsSnapshot {
    return .{
        .raw_json = null,
        .err_message = alloc.dupe(u8, message) catch null,
    };
}

fn executeOAuthRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: oauth_transport.Request,
) !oauth_transport.Response {
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = request.cancel_flag orelse &local_cancel;
    const deadline = request.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(oauth_request_timeout_ms),
    });
    var operation = OAuthHttpOperation{
        .alloc = alloc,
        .request = request,
    };
    return gateway_client.runBoundedHttpOperation(
        oauth_transport.Response,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

const OAuthHttpOperation = struct {
    alloc: Allocator,
    request: oauth_transport.Request,

    pub fn run(self: *@This()) !oauth_transport.Response {
        var client: std.http.Client = .{
            .allocator = self.alloc,
            .io = io_mod.getIo(),
        };
        defer client.deinit();

        const response_buffer = try self.alloc.alloc(u8, oauth_response_max_bytes + 1);
        defer secret.zeroAndFree(self.alloc, response_buffer);
        var response_writer = std.Io.Writer.fixed(response_buffer);

        const result = client.fetch(.{
            .location = .{ .url = self.request.url },
            .method = switch (self.request.method) {
                .get => .GET,
                .post_form => .POST,
            },
            .payload = self.request.payload,
            .headers = .{
                .content_type = if (self.request.method == .post_form)
                    .{ .override = "application/x-www-form-urlencoded" }
                else
                    .default,
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .response_writer = &response_writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OAuthResponseTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > oauth_response_max_bytes) return error.OAuthResponseTooLarge;

        return .{
            .disposition = if (result.status == .ok) .accepted else .rejected,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

test "oauth transport user agent uses the product version" {
    try std.testing.expect(std.mem.startsWith(u8, gateway_client.user_agent, "fx/"));
    try std.testing.expect(gateway_client.user_agent.len > "fx/".len);
    try std.testing.expect(std.mem.find(u8, gateway_client.user_agent, "zig") == null);
    try std.testing.expect(std.mem.find(u8, gateway_client.user_agent, "std.http") == null);
}

fn validateApiKey(
    _: ?*anyopaque,
    alloc: Allocator,
    api_key: []const u8,
) api_key_validator_contract.Result {
    var result = gateway_client.fetchGatewayGetResult(alloc, api_key, models_path) catch |err| {
        debug_trace.logf("auth", "api key validation failed err={s}", .{@errorName(err)});
        return .unavailable;
    };
    defer result.deinit(alloc);
    return apiKeyValidationForStatus(result.status);
}

fn apiKeyValidationForStatus(status: std.http.Status) api_key_validator_contract.Result {
    return switch (status) {
        .ok => .accepted,
        .unauthorized, .forbidden => .refused,
        else => .unavailable,
    };
}

test "API key validator preserves Gateway status mapping" {
    try std.testing.expectEqual(api_key_validator_contract.Result.accepted, apiKeyValidationForStatus(.ok));
    try std.testing.expectEqual(api_key_validator_contract.Result.refused, apiKeyValidationForStatus(.unauthorized));
    try std.testing.expectEqual(api_key_validator_contract.Result.refused, apiKeyValidationForStatus(.forbidden));
    try std.testing.expectEqual(api_key_validator_contract.Result.unavailable, apiKeyValidationForStatus(.internal_server_error));
}

pub fn preferredWebSearchBackendsOverride(raw: ?[]const u8) !?[]const web_search_contract.SearchBackendId {
    const value = raw orelse return null;
    if (value.len == 0) return null;
    if (std.mem.eql(u8, value, "ai_gateway_perplexity_search")) return &perplexity_search_backend;
    if (std.mem.eql(u8, value, "ai_gateway_parallel_search")) return &parallel_search_backend;
    return error.InvalidWebSearchBackend;
}

pub fn selectedWebSearchBackend() !web_search_contract.SearchBackendId {
    if (try preferredWebSearchBackendsOverride(io_mod.getenv("FX_WEB_SEARCH_BACKEND"))) |backends| {
        return backends[0];
    }
    return default_web_search_backend_order[0];
}

fn resolvePreferredWebSearchBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
    return preferredWebSearchBackendsOverride(io_mod.getenv("FX_WEB_SEARCH_BACKEND"));
}

fn executeWebSearchProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: Request,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    return executeGatewayWorker(alloc, .{
        .connection_id = inputs.connection_id,
        .api_key = inputs.credential,
        .team = inputs.tenant,
        .model = inputs.model,
        .retry_count = inputs.retry_count,
        .chat_url = inputs.endpoint,
        .usage = inputs.usage,
        .usage_allocator = inputs.usage_allocator,
    }, request, on_progress, progress_ctx);
}

pub fn chatUrl(fallback: []const u8) []const u8 {
    return resolveChatUrl(fallback, io_mod.getenv(chat_url_env));
}

pub fn defaultChatUrl() []const u8 {
    return chatUrl(default_chat_url);
}

fn resolveChatUrlForProvider(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return chatUrl(fallback);
}

pub fn resolveChatUrl(fallback: []const u8, override: ?[]const u8) []const u8 {
    const candidate = override orelse return fallback;
    // The chat URL carries the bearer token and full request payload; only a
    // loopback HTTP override is trusted for local testing.
    if (!gateway_client.isLoopbackHttpUrl(candidate)) return fallback;
    return candidate;
}

pub const StreamFn = *const fn (
    *anyopaque,
    Allocator,
    []const u8,
    ?[]const u8,
    []const u8,
    usize,
    []const u8,
    []const u8,
    []const u8,
    std.Io.Clock.Timestamp,
    *gateway_client.DeliveryCertainty,
    *std.atomic.Value(bool),
) anyerror!gateway_client.StreamResult;

var default_stream_ctx: u8 = 0;

pub const GatewayWorkerConfig = struct {
    connection_id: []const u8,
    api_key: []const u8,
    team: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    stream_ctx: *anyopaque = @ptrCast(&default_stream_ctx),
    stream_fn: StreamFn = streamGatewayWorker,
};

pub const ProviderToolInput = struct {
    backend: web_search_contract.SearchBackendId,
    allowed_domains: ?[]const []const u8 = null,
    blocked_domains: ?[]const []const u8 = null,
    max_results: u8,
    max_output_tokens: u32 = 4096,
    max_output_chars: usize,
};

pub fn executeGatewayWorker(
    alloc: Allocator,
    config: GatewayWorkerConfig,
    request: Request,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    if (config.api_key.len == 0 or config.model.len == 0 or config.chat_url.len == 0) {
        return error.MissingGatewaySearchConfiguration;
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const deadline = deadlineAfterMs(request.timeout_ms);
    if (on_progress) |progress| progress(progress_ctx orelse return error.MissingProgressContext, .{ .query_update = request.query });

    const tools_json = try providerToolsJson(alloc, .{
        .backend = request.backend,
        .allowed_domains = request.allowed_domains,
        .blocked_domains = request.blocked_domains,
        .max_results = request.max_results,
        .max_output_tokens = request.max_output_tokens,
        .max_output_chars = request.max_output_chars,
    });
    defer alloc.free(tools_json);

    const messages = [_]shared_types.ChatMessage{
        .{ .role = .system, .content = web_search_system_prompt },
        .{ .role = .user, .content = request.query },
    };
    const payload = try gateway_json.buildGatewayRequiredToolRequestBodyWithMaxOutputTokens(alloc, tools_json, &messages, request.max_output_tokens);
    defer alloc.free(payload);

    const usage_observation = try session_usage.GatewayObservation.begin(config.usage);
    var delivery = gateway_client.DeliveryCertainty.init();
    const provider_tool_name = try selectedToolName(request.backend);
    var stream = config.stream_fn(
        config.stream_ctx,
        alloc,
        config.api_key,
        config.team,
        config.model,
        @max(config.retry_count, 1),
        config.chat_url,
        payload,
        provider_tool_name,
        deadline,
        &delivery,
        @constCast(request.cancel_flag),
    ) catch |err| {
        try usage_observation.fail(if (delivery.load() == .possibly_sent)
            .ambiguous_delivery
        else
            .unbilled);
        return err;
    };
    defer stream.deinit(alloc);
    try usage_observation.complete(
        config.usage_allocator,
        stream.status,
        stream.completion,
        config.connection_id,
        gateway_client.generationBaseUrl(),
    );
    if (!builtin.is_test) {
        if (config.usage) |ledger| {
            ledger.startReconciliation(config.usage_allocator);
        }
    }
    if (stream.status != .ok) return error.GatewayRequestFailed;
    return normalizeGatewayCompletion(alloc, request, stream.completion, on_progress, progress_ctx);
}

fn deadlineAfterMs(timeout_ms: u32) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
}

pub fn providerToolsJson(alloc: Allocator, input: ProviderToolInput) ![]u8 {
    if (hasValues(input.allowed_domains) and hasValues(input.blocked_domains)) {
        return error.ConflictingDomainFilters;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (input.backend.eql(perplexity_search_backend_id)) {
        try out.writer.print(
            "[{{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"args\":{{\"maxResults\":{d},\"maxTokens\":{d}",
            .{ input.max_results, input.max_output_tokens },
        );
        if (hasValues(input.allowed_domains)) {
            try writePerplexityDomains(alloc, &out.writer, input.allowed_domains.?, false);
        } else if (hasValues(input.blocked_domains)) {
            try writePerplexityDomains(alloc, &out.writer, input.blocked_domains.?, true);
        }
        try out.writer.writeAll("}}]");
    } else if (input.backend.eql(parallel_search_backend_id)) {
        try out.writer.print(
            "[{{\"type\":\"provider\",\"id\":\"gateway.parallel_search\",\"name\":\"parallel_search\",\"args\":{{\"mode\":\"one-shot\",\"maxResults\":{d}",
            .{input.max_results},
        );
        if (hasValues(input.allowed_domains)) {
            try writeParallelDomains(&out.writer, "includeDomains", input.allowed_domains.?);
        } else if (hasValues(input.blocked_domains)) {
            try writeParallelDomains(&out.writer, "excludeDomains", input.blocked_domains.?);
        }
        try out.writer.print(",\"excerpts\":{{\"maxCharsTotal\":{d}}}}}}}]", .{input.max_output_chars});
    } else {
        return error.InvalidWebSearchBackend;
    }
    return try out.toOwnedSlice();
}

fn streamGatewayWorker(
    _: *anyopaque,
    alloc: Allocator,
    api_key: []const u8,
    team: ?[]const u8,
    model: []const u8,
    request_retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    expected_provider_tool_name: []const u8,
    deadline: std.Io.Clock.Timestamp,
    delivery: *gateway_client.DeliveryCertainty,
    cancel_flag: *std.atomic.Value(bool),
) !gateway_client.StreamResult {
    return gateway_client.streamGatewayProviderToolCompletionBounded(
        alloc,
        .{
            .api_key = api_key,
            .team = team,
            .model = model,
            .retry_count = request_retry_count,
            .chat_url = chat_url,
            .payload = payload,
            .delivery = delivery,
        },
        expected_provider_tool_name,
        deadline,
        cancel_flag,
    );
}

fn normalizeGatewayCompletion(
    alloc: Allocator,
    request: Request,
    completion: shared_types.GatewayCompletion,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    var content: std.ArrayList(web_search_contract.ResultItem) = .empty;
    errdefer deinitItems(alloc, &content);

    var search_requests: u32 = 0;
    const admission = shared_types.authoritativeToolAdmission(completion);
    const admitted = switch (admission) {
        .admitted => true,
        .reject_duplicate_identity => blk: {
            try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "provider search tool identity is duplicated") });
            break :blk false;
        },
        .reject_malformed_identity => |failure| blk: {
            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(
                alloc,
                "provider search tool identity is malformed ({s})",
                .{@tagName(failure)},
            ) });
            break :blk false;
        },
        .reject_malformed_provider_result => |failure| blk: {
            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(
                alloc,
                "provider search result identity is malformed ({s})",
                .{@tagName(failure)},
            ) });
            break :blk false;
        },
        .reject_malformed_provider_arguments => blk: {
            try content.append(alloc, .{
                .error_text = try alloc.dupe(
                    u8,
                    "provider search tool arguments are malformed",
                ),
            });
            break :blk false;
        },
    };
    if (admitted) {
        const expected_tool_name = try selectedToolName(request.backend);
        var provider_call: ?shared_types.ToolCall = null;
        for (completion.tool_calls) |call| {
            if (call.provenance != .provider_executed or !std.mem.eql(u8, call.name, expected_tool_name)) {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned an unexpected tool call") });
                break;
            }
            if (provider_call != null) {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned multiple provider search calls") });
                break;
            }
            provider_call = call;
        }

        if (content.items.len == 0) {
            if (provider_call) |call| {
                if (call.provider_result) |provider_result| {
                    search_requests += 1;
                    map_result: {
                        const hits = parseSearchHits(alloc, provider_result, request.max_results) catch |err| {
                            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(alloc, "provider search result decode failed: {s}", .{@errorName(err)}) });
                            break :map_result;
                        };
                        errdefer deinitHits(alloc, hits);
                        try content.append(alloc, .{ .search = .{
                            .tool_use_id = try alloc.dupe(u8, call.id),
                            .content = hits,
                        } });
                        if (on_progress) |progress| progress(progress_ctx orelse return error.MissingProgressContext, .{
                            .results_received = .{
                                .query = request.query,
                                .result_count = hits.len,
                            },
                        });
                    }
                } else {
                    try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "provider search returned no result") });
                }
            } else {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned no provider search call") });
            }
        }
    }

    if (completion.finish_reason == null) {
        try content.append(alloc, .{ .terminal_incomplete = .{
            .stop_reason = try alloc.dupe(u8, "missing_provider_finish"),
            .message = try alloc.dupe(u8, "private web search worker stopped before completion"),
        } });
    } else if (completion.finish_reason == .provider_error or completion.finish_reason == .content_filter) {
        const reason = completion.finish_reason.?;
        try content.append(alloc, .{ .terminal_incomplete = .{
            .stop_reason = try alloc.dupe(u8, reason.label()),
            .message = try alloc.dupe(u8, "private web search worker reported an unsuccessful completion"),
        } });
    }

    return .{
        .content = try content.toOwnedSlice(alloc),
        .stop_reason = if (completion.finish_reason) |reason| try alloc.dupe(u8, reason.label()) else null,
        .usage = .{
            .input_tokens = completion.usage.input_tokens orelse 0,
            .output_tokens = completion.usage.output_tokens orelse 0,
            .web_search_requests = search_requests,
        },
    };
}

fn parseSearchHits(alloc: Allocator, json_text: []const u8, max_results: u8) ![]web_search_contract.Source {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    const values = searchResultValues(parsed.value) orelse return &.{};
    var hits: std.ArrayList(web_search_contract.Source) = .empty;
    errdefer deinitHitsList(alloc, &hits);
    for (values) |value| {
        if (hits.items.len >= max_results) break;
        const hit = try decodeSearchHit(alloc, value) orelse continue;
        try hits.append(alloc, hit);
    }
    return try hits.toOwnedSlice(alloc);
}

fn searchResultValues(value: std.json.Value) ?[]const std.json.Value {
    if (value == .array) return value.array.items;
    if (value != .object) return null;
    inline for (&.{ "results", "sources", "data", "response" }) |name| {
        if (value.object.get(name)) |nested| {
            if (searchResultValues(nested)) |values| return values;
        }
    }
    return null;
}

fn decodeSearchHit(alloc: Allocator, value: std.json.Value) !?web_search_contract.Source {
    if (value != .object) return null;
    const url = stringField(value.object, &.{ "url", "link" }) orelse return null;
    if (!isSafeCitationUrl(url)) return null;
    const title = stringField(value.object, &.{ "title", "name" }) orelse url;
    const owned_title = try alloc.dupe(u8, title);
    errdefer alloc.free(owned_title);
    return .{
        .title = owned_title,
        .url = try alloc.dupe(u8, url),
    };
}

fn isSafeCitationUrl(url: []const u8) bool {
    const authority_start = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        return false;
    var authority_end = authority_start;
    while (authority_end < url.len) : (authority_end += 1) {
        const char = url[authority_end];
        if (char < 0x20 or char == 0x7f or std.ascii.isWhitespace(char)) return false;
        if (char == '/' or char == '?' or char == '#') break;
    }
    if (authority_end == authority_start) return false;
    if (std.mem.findScalar(u8, url[authority_start..authority_end], '@') != null) return false;
    for (url[authority_end..]) |char| {
        if (char < 0x20 or char == 0x7f or std.ascii.isWhitespace(char)) return false;
    }
    return true;
}

fn stringField(object: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = object.get(name) orelse continue;
        if (value == .string) return value.string;
    }
    return null;
}

fn selectedToolName(backend: web_search_contract.SearchBackendId) ![]const u8 {
    if (backend.eql(perplexity_search_backend_id)) return "perplexity_search";
    if (backend.eql(parallel_search_backend_id)) return "parallel_search";
    return error.InvalidWebSearchBackend;
}

fn writePerplexityDomains(alloc: Allocator, writer: *std.Io.Writer, domains: []const []const u8, blocked: bool) !void {
    try writer.writeAll(",\"searchDomainFilter\":[");
    for (domains, 0..) |domain, index| {
        if (index > 0) try writer.writeByte(',');
        if (blocked) {
            const prefixed = try std.fmt.allocPrint(alloc, "-{s}", .{domain});
            defer alloc.free(prefixed);
            try std.json.Stringify.value(prefixed, .{}, writer);
        } else {
            try std.json.Stringify.value(domain, .{}, writer);
        }
    }
    try writer.writeByte(']');
}

fn writeParallelDomains(writer: *std.Io.Writer, name: []const u8, domains: []const []const u8) !void {
    try writer.print(",\"sourcePolicy\":{{\"{s}\":[", .{name});
    for (domains, 0..) |domain, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(domain, .{}, writer);
    }
    try writer.writeAll("]}");
}

fn boundedDupe(alloc: Allocator, text: []const u8, max_len: usize) ![]u8 {
    return try alloc.dupe(u8, text[0..@min(text.len, max_len)]);
}

fn hasValues(values: ?[]const []const u8) bool {
    return if (values) |actual| actual.len > 0 else false;
}

fn deinitItems(alloc: Allocator, items: *std.ArrayList(web_search_contract.ResultItem)) void {
    for (items.items) |item| item.deinit(alloc);
    items.deinit(alloc);
}

fn deinitHitsList(alloc: Allocator, hits: *std.ArrayList(web_search_contract.Source)) void {
    for (hits.items) |hit| hit.deinit(alloc);
    hits.deinit(alloc);
}

fn deinitHits(alloc: Allocator, hits: []web_search_contract.Source) void {
    for (hits) |hit| hit.deinit(alloc);
    if (hits.len > 0) alloc.free(hits);
}

test "built-in search rejects an unknown provider-owned backend identity" {
    try std.testing.expectError(error.InvalidWebSearchBackend, providerToolsJson(std.testing.allocator, .{
        .backend = .{ .value = "other.search" },
        .max_results = 1,
        .max_output_chars = 1024,
    }));
}

test "private perplexity worker advertises only selected gateway provider search tool" {
    const alloc = std.testing.allocator;
    const allowed_domains = [_][]const u8{"ziglang.org"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = perplexity_search_backend_id,
        .allowed_domains = &allowed_domains,
        .max_results = 7,
        .max_output_chars = 4096,
    });
    defer alloc.free(tools_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.find(u8, tools_json, "gateway.perplexity_search") != null);
    try std.testing.expect(std.mem.find(u8, tools_json, "gateway.parallel_search") == null);
    try std.testing.expect(std.mem.find(u8, tools_json, "\"maxResults\":7") != null);
    try std.testing.expect(std.mem.find(u8, tools_json, "\"searchDomainFilter\":[\"ziglang.org\"]") != null);
}

test "private perplexity worker serializes blocked domains as exclusions" {
    const alloc = std.testing.allocator;
    const blocked_domains = [_][]const u8{"example.com"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = perplexity_search_backend_id,
        .blocked_domains = &blocked_domains,
        .max_results = 7,
        .max_output_chars = 4096,
    });
    defer alloc.free(tools_json);

    try std.testing.expect(std.mem.find(u8, tools_json, "\"searchDomainFilter\":[\"-example.com\"]") != null);
}

test "private perplexity worker ignores empty allowed domains before blocked domains" {
    const alloc = std.testing.allocator;
    const allowed_domains = [_][]const u8{};
    const blocked_domains = [_][]const u8{"example.com"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = perplexity_search_backend_id,
        .allowed_domains = &allowed_domains,
        .blocked_domains = &blocked_domains,
        .max_results = 7,
        .max_output_chars = 4096,
    });
    defer alloc.free(tools_json);

    try std.testing.expect(std.mem.find(u8, tools_json, "\"searchDomainFilter\":[\"-example.com\"]") != null);
}

test "private parallel worker advertises only selected gateway provider search tool" {
    const alloc = std.testing.allocator;
    const blocked_domains = [_][]const u8{"example.com"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = parallel_search_backend_id,
        .blocked_domains = &blocked_domains,
        .max_results = 5,
        .max_output_chars = 6000,
    });
    defer alloc.free(tools_json);

    try std.testing.expect(std.mem.find(u8, tools_json, "gateway.parallel_search") != null);
    try std.testing.expect(std.mem.find(u8, tools_json, "gateway.perplexity_search") == null);
    try std.testing.expect(std.mem.find(u8, tools_json, "\"excludeDomains\":[\"example.com\"]") != null);
    try std.testing.expect(std.mem.find(u8, tools_json, "\"maxCharsTotal\":6000") != null);
}

test "private parallel worker ignores empty allowed domains before blocked domains" {
    const alloc = std.testing.allocator;
    const allowed_domains = [_][]const u8{};
    const blocked_domains = [_][]const u8{"example.com"};
    const tools_json = try providerToolsJson(alloc, .{
        .backend = parallel_search_backend_id,
        .allowed_domains = &allowed_domains,
        .blocked_domains = &blocked_domains,
        .max_results = 5,
        .max_output_chars = 6000,
    });
    defer alloc.free(tools_json);

    try std.testing.expect(std.mem.find(u8, tools_json, "\"excludeDomains\":[\"example.com\"]") != null);
}

test "provider search result drops unsafe citation urls" {
    const alloc = std.testing.allocator;
    const hits = try parseSearchHits(
        alloc,
        \\{"results":[
        \\  {"title":"safe","url":"https://example.com/docs"},
        \\  {"title":"script","url":"javascript:alert(1)"},
        \\  {"title":"credentials","url":"https://user:pass@example.com/docs"},
        \\  {"title":"space","url":"https://example.com/a b"}
        \\]}
    ,
        10,
    );
    defer deinitHits(alloc, hits);

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("https://example.com/docs", hits[0].url);
}

fn expectGatewayWorkerAdapterExecutes(backend: web_search_contract.SearchBackendId) !void {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var fake = FakeStream{};
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var response = try executeGatewayWorker(alloc, .{
        .connection_id = "vercel",
        .api_key = "key",
        .team = "team_123",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = backend,
        .query = "latest Zig release",
        .max_results = 1,
        .cancel_flag = &cancel_flag,
    }, null, null);
    defer response.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("team_123", fake.team.?);
    const deadline = fake.deadline orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(std.Io.Clock.awake, deadline.clock);
    try std.testing.expect(std.Io.Clock.Timestamp.compare(
        std.Io.Clock.Timestamp.now(std.testing.io, .awake),
        .lt,
        deadline,
    ));
    try std.testing.expect(fake.saw_inner_prompt);
    try std.testing.expect(fake.saw_output_bound);
    try std.testing.expect(fake.saw_required_tool_choice);
    try std.testing.expect(fake.saw_expected_provider_tool);
    var usage_snapshot = try usage.snapshot(alloc);
    defer usage_snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), usage_snapshot.pending.len);
    if (backend.eql(perplexity_search_backend_id)) {
        try std.testing.expect(fake.saw_perplexity);
        try std.testing.expect(!fake.saw_parallel);
    } else {
        try std.testing.expect(backend.eql(parallel_search_backend_id));
        try std.testing.expect(!fake.saw_perplexity);
        try std.testing.expect(fake.saw_parallel);
    }
    try std.testing.expectEqual(@as(usize, 1), response.content[0].search.content.len);
    try std.testing.expectEqual(@as(u32, 1), response.usage.?.web_search_requests);
}

test "gateway worker adapter executes private perplexity backend with bounded payload" {
    try expectGatewayWorkerAdapterExecutes(perplexity_search_backend_id);
}

test "gateway worker adapter executes private parallel backend with bounded payload" {
    try expectGatewayWorkerAdapterExecutes(parallel_search_backend_id);
}

test "gateway worker returns one bounded error for malformed provider result identity" {
    const failures = [_]shared_types.ProviderResultIdentityFailure{
        .absent,
        .empty,
        .wrong_type,
    };
    for (failures) |failure| {
        var cancel_flag = std.atomic.Value(bool).init(false);
        var response = try normalizeGatewayCompletion(std.testing.allocator, .{
            .backend = perplexity_search_backend_id,
            .query = "latest Zig release",
            .cancel_flag = &cancel_flag,
        }, .{
            .content = "must not escape malformed admission",
            .provider_result_identity_failure = failure,
            .finish_reason = .stop,
        }, null, null);
        defer response.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), response.content.len);
        try std.testing.expect(response.content[0] == .error_text);
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "provider search result identity is malformed ({s})",
            .{@tagName(failure)},
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, response.content[0].error_text);
        try std.testing.expectEqual(@as(u32, 0), response.usage.?.web_search_requests);
    }
}

test "gateway worker rejects malformed provider arguments before accepting search results" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(std.testing.allocator, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .tool_calls = &.{.{
            .id = "search_1",
            .name = "perplexity_search",
            .arguments_json = "{}",
            .argument_integrity = .malformed_json,
            .provider_result = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}",
            .provenance = .provider_executed,
        }},
        .finish_reason = .stop,
    }, null, null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expect(response.content[0] == .error_text);
    try std.testing.expectEqual(@as(u32, 0), response.usage.?.web_search_requests);
}

test "gateway worker rejects duplicate selected provider calls" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(std.testing.allocator, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .tool_calls = &.{
            .{
                .id = "search_1",
                .name = "perplexity_search",
                .arguments_json = "{}",
                .provider_result = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}",
                .provenance = .provider_executed,
            },
            .{
                .id = "search_2",
                .name = "perplexity_search",
                .arguments_json = "{}",
                .provider_result = "{\"results\":[{\"title\":\"Zig downloads\",\"url\":\"https://ziglang.org/download\"}]}",
                .provenance = .provider_executed,
            },
        },
        .finish_reason = .stop,
    }, null, null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expect(response.content[0] == .error_text);
    try std.testing.expectEqual(@as(u32, 0), response.usage.?.web_search_requests);
}

test "gateway worker accepts refined provider input without worker commentary" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(std.testing.allocator, .{
        .backend = perplexity_search_backend_id,
        .query = "current latest stable Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .content = "private worker commentary",
        .tool_calls = &.{.{
            .id = "search_1",
            .name = "perplexity_search",
            .arguments_json = "{\"query\":\"current latest stable Zig release version\"}",
            .provider_result = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}",
            .provenance = .provider_executed,
        }},
        .finish_reason = .stop,
    }, null, null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expect(response.content[0] == .search);
    try std.testing.expectEqual(@as(usize, 1), response.content[0].search.content.len);
    try std.testing.expectEqual(@as(u32, 1), response.usage.?.web_search_requests);
}

test "gateway worker rejects an unselected provider call" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(std.testing.allocator, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .tool_calls = &.{.{
            .id = "search_1",
            .name = "parallel_search",
            .arguments_json = "{}",
            .provider_result = "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}",
            .provenance = .provider_executed,
        }},
        .finish_reason = .stop,
    }, null, null);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.content.len);
    try std.testing.expect(response.content[0] == .error_text);
    try std.testing.expectEqual(@as(u32, 0), response.usage.?.web_search_requests);
}

test "cancelled gateway worker performs zero stream requests" {
    var cancel_flag = std.atomic.Value(bool).init(true);
    var fake = FakeStream{};

    try std.testing.expectError(error.Cancelled, executeGatewayWorker(std.testing.allocator, .{
        .connection_id = "vercel",
        .api_key = "key",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, null, null));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "web search drops worker text when no provider result arrives" {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = try normalizeGatewayCompletion(alloc, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, .{
        .content = "partial research",
        .finish_reason = null,
    }, null, null);
    defer response.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), response.content.len);
    try std.testing.expect(response.content[0] == .error_text);
    try std.testing.expectEqualStrings("private worker returned no provider search call", response.content[0].error_text);
    try std.testing.expect(response.content[1] == .terminal_incomplete);
    try std.testing.expectEqualStrings("missing_provider_finish", response.content[1].terminal_incomplete.stop_reason);
    try std.testing.expect(response.stop_reason == null);
}

const FakeStream = struct {
    calls: usize = 0,
    fail_before_send: bool = false,
    fail_after_send: bool = false,
    team: ?[]const u8 = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    saw_perplexity: bool = false,
    saw_parallel: bool = false,
    saw_inner_prompt: bool = false,
    saw_output_bound: bool = false,
    saw_required_tool_choice: bool = false,
    saw_expected_provider_tool: bool = false,

    fn execute(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        _: []const u8,
        team: ?[]const u8,
        _: []const u8,
        _: usize,
        _: []const u8,
        payload: []const u8,
        expected_provider_tool_name: []const u8,
        deadline: std.Io.Clock.Timestamp,
        delivery: *gateway_client.DeliveryCertainty,
        _: *std.atomic.Value(bool),
    ) anyerror!gateway_client.StreamResult {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        if (self.fail_before_send) return error.AccessDenied;
        if (self.fail_after_send) {
            delivery.markPossiblySent();
            return error.ConnectionResetByPeer;
        }
        self.team = team;
        self.deadline = deadline;
        self.saw_perplexity = std.mem.find(u8, payload, "gateway.perplexity_search") != null;
        self.saw_parallel = std.mem.find(u8, payload, "gateway.parallel_search") != null;
        self.saw_inner_prompt = std.mem.find(u8, payload, "Research the user's query with the web_search tool and preserve sources for citation.") != null;
        self.saw_output_bound = std.mem.find(u8, payload, "\"maxOutputTokens\":4096") != null;
        self.saw_required_tool_choice = std.mem.find(u8, payload, "\"toolChoice\":{\"type\":\"required\"}") != null;
        const tool_name = if (self.saw_parallel) "parallel_search" else "perplexity_search";
        self.saw_expected_provider_tool = std.mem.eql(u8, expected_provider_tool_name, tool_name);
        return .{
            .status = .ok,
            .completion = .{
                .generation_id = try alloc.dupe(
                    u8,
                    "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
                ),
                .finish_reason = .stop,
                .tool_calls = try alloc.dupe(shared_types.ToolCall, &.{
                    .{
                        .id = try alloc.dupe(u8, "search_1"),
                        .name = try alloc.dupe(u8, tool_name),
                        .arguments_json = try alloc.dupe(u8, "{}"),
                        .provider_result = try alloc.dupe(u8, "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"},{\"title\":\"Zig downloads\",\"url\":\"https://ziglang.org/download\"}]}"),
                        .provenance = .provider_executed,
                    },
                }),
                .usage = .{ .input_tokens = 2, .output_tokens = 3 },
            },
        };
    }
};

test "pre-send web search failure stays unbilled" {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var fake = FakeStream{ .fail_before_send = true };
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);

    try std.testing.expectError(error.AccessDenied, executeGatewayWorker(alloc, .{
        .connection_id = "vercel",
        .api_key = "key",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, null, null));

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "possibly sent web search failure marks billing incomplete" {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var fake = FakeStream{ .fail_after_send = true };
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);

    try std.testing.expectError(error.ConnectionResetByPeer, executeGatewayWorker(alloc, .{
        .connection_id = "vercel",
        .api_key = "key",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = perplexity_search_backend_id,
        .query = "latest Zig release",
        .cancel_flag = &cancel_flag,
    }, null, null));

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.incomplete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "built-in gateway defaults preserve active provider policy" {
    try std.testing.expectEqualStrings("zai/glm-5.2", default_model);
    try std.testing.expect(default_fast_mode);
    try std.testing.expectEqualStrings("https://ai-gateway.vercel.sh/v3/ai/language-model", default_chat_url);
    try std.testing.expectEqualStrings("/coding-agent/v1/models", models_path);
    try std.testing.expectEqual(@as(usize, 3), retry_count);
    try std.testing.expectEqualStrings("FX_GATEWAY_CHAT_URL", chat_url_env);
}

fn stubFetchCreditsError(
    _: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return error.StubFetchFailed;
}

fn stubFetchInvalidCreditsJson(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{"),
    };
}

fn stubFetchCreditsObject(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{\"balance\":\"10\",\"used\":\"2\",\"plan\":\"pro\"}"),
    };
}

var captured_credits_path: [256]u8 = undefined;
var captured_credits_path_len: usize = 0;

fn stubCaptureCreditsPath(
    alloc: Allocator,
    _: ?[]const u8,
    path: []const u8,
) anyerror!gateway_client.GetResult {
    captured_credits_path_len = @min(path.len, captured_credits_path.len);
    @memcpy(
        captured_credits_path[0..captured_credits_path_len],
        path[0..captured_credits_path_len],
    );
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{\"balance\":\"10\",\"total_used\":\"2\"}"),
    };
}

fn stubFetchForbiddenCredits(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .forbidden,
        .body = try alloc.dupe(u8, "{\"error\":{\"code\":\"credit_card_required\",\"message\":\"Buy credits to use AI Gateway.\"}}"),
    };
}

test "built-in credits provider names the team query only when valid" {
    const cases = [_]struct { team: ?[]const u8, want: []const u8 }{
        .{ .team = null, .want = "/coding-agent/v1/credits" },
        .{ .team = "team_000000000000000000000000", .want = "/coding-agent/v1/credits?teamId=team_000000000000000000000000" },
        .{ .team = "example-projects", .want = "/coding-agent/v1/credits?teamId=example-projects" },
        .{ .team = "team a/../b", .want = "/coding-agent/v1/credits" },
        .{ .team = "", .want = "/coding-agent/v1/credits" },
    };
    for (cases) |case| {
        captured_credits_path_len = 0;
        var snapshot = fetchCreditsWithFetch(
            std.testing.allocator,
            null,
            case.team,
            stubCaptureCreditsPath,
        );
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(
            case.want,
            captured_credits_path[0..captured_credits_path_len],
        );
    }
}

test "built-in credits provider maps fetch failure" {
    var snapshot = fetchCreditsWithFetch(
        std.testing.allocator,
        null,
        null,
        stubFetchCreditsError,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.balance == null);
    try std.testing.expect(snapshot.used == null);
    try std.testing.expect(snapshot.plan == null);
    try std.testing.expectEqualStrings(
        "failed to fetch credits from gateway",
        snapshot.err_message.?,
    );
}

test "built-in credits provider maps Gateway HTTP denial" {
    var snapshot = fetchCreditsWithFetch(
        std.testing.allocator,
        null,
        null,
        stubFetchForbiddenCredits,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.balance == null);
    try std.testing.expect(snapshot.used == null);
    try std.testing.expect(snapshot.plan == null);
    try std.testing.expectEqualStrings(
        "API access denied · HTTP 403 · credit_card_required: Buy credits to use AI Gateway.",
        snapshot.err_message.?,
    );
}

test "built-in credits provider rejects malformed JSON" {
    var snapshot = fetchCreditsWithFetch(
        std.testing.allocator,
        null,
        null,
        stubFetchInvalidCreditsJson,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.raw_json == null);
    try std.testing.expectEqualStrings(
        "invalid JSON response from gateway",
        snapshot.err_message.?,
    );
}

test "built-in credits provider rejects non-object JSON" {
    var snapshot = try creditsSnapshotFromJsonValue(
        std.testing.allocator,
        .{ .string = "nope" },
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.raw_json == null);
    try std.testing.expectEqualStrings(
        "unexpected response format from gateway",
        snapshot.err_message.?,
    );
}

test "built-in credits provider returns owned string fields" {
    var snapshot = fetchCreditsWithFetch(
        std.testing.allocator,
        null,
        null,
        stubFetchCreditsObject,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("10", snapshot.balance.?);
    try std.testing.expectEqualStrings("2", snapshot.used.?);
    try std.testing.expectEqualStrings("pro", snapshot.plan.?);

    const text = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[credits] balance=10\n[credits] used=2\n[credits] plan=pro\n",
        text,
    );
}

test "built-in credits provider ignores non-string fields" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"balance\":10,\"used\":false,\"plan\":null}",
        .{},
    );
    defer parsed.deinit();

    var snapshot = try creditsSnapshotFromJsonValue(
        std.testing.allocator,
        parsed.value,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.balance == null);
    try std.testing.expect(snapshot.used == null);
    try std.testing.expect(snapshot.plan == null);
}

test "built-in model catalog owns default and loopback target resolution" {
    const default_url = try modelCatalogUrl(std.testing.allocator, models_path, null);
    defer std.testing.allocator.free(default_url);
    try std.testing.expectEqualStrings("https://ai-gateway.vercel.sh/coding-agent/v1/models", default_url);

    const loopback_url = try modelCatalogUrl(std.testing.allocator, models_path, "http://127.0.0.1:43123");
    defer std.testing.allocator.free(loopback_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/coding-agent/v1/models", loopback_url);

    const rejected_url = try modelCatalogUrl(std.testing.allocator, models_path, "https://gateway.example");
    defer std.testing.allocator.free(rejected_url);
    try std.testing.expectEqualStrings("https://ai-gateway.vercel.sh/coding-agent/v1/models", rejected_url);
}

test "built-in gateway owns the admitted web search provider policy" {
    try std.testing.expect(web_search_policy.hasAdmittedBackendPolicy(default_web_search_policy.backend_policies));
    try std.testing.expectEqual(@as(usize, 2), default_web_search_policy.backend_policies.len);
    try std.testing.expect(perplexity_search_backend_id.eql(default_web_search_policy.preferred_backends[0]));
    try std.testing.expect(parallel_search_backend_id.eql(default_web_search_policy.preferred_backends[1]));

    for (default_web_search_policy.backend_policies) |backend| {
        try std.testing.expectEqual(web_search_contract.BackendFeatureMode.best_effort, backend.features.max_uses);
        try std.testing.expectEqual(web_search_contract.BackendFeatureMode.pass_through, backend.features.allowed_domains);
        try std.testing.expectEqual(web_search_contract.BackendFeatureMode.pass_through, backend.features.blocked_domains);
        try std.testing.expect(backend.features.ordered_sources);
        try std.testing.expect(backend.features.usage);
        try std.testing.expect(backend.features.terminal_incomplete);
        try std.testing.expect(backend.features.timeout);
        try std.testing.expect(backend.features.cancellation);
        try std.testing.expect(backend.features.result_bounds == .pass_through or backend.features.result_bounds == .post_filter);
    }
}

test "built-in web search provider preserves missing worker configuration error" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.MissingGatewaySearchConfiguration, default_web_search_provider.execute(
        std.testing.allocator,
        .{
            .connection_id = "vercel",
            .credential = "",
            .model = "",
            .retry_count = retry_count,
            .endpoint = default_chat_url,
        },
        .{
            .backend = perplexity_search_backend_id,
            .query = "latest Zig release",
            .cancel_flag = &cancel_flag,
        },
        null,
        null,
    ));
}

test "built-in gateway web search override selects one backend and rejects unknown values" {
    try std.testing.expect((try preferredWebSearchBackendsOverride(null)) == null);
    try std.testing.expect((try preferredWebSearchBackendsOverride("")) == null);
    try std.testing.expect(perplexity_search_backend_id.eql((try preferredWebSearchBackendsOverride("ai_gateway_perplexity_search")).?[0]));
    try std.testing.expect(parallel_search_backend_id.eql((try preferredWebSearchBackendsOverride("ai_gateway_parallel_search")).?[0]));
    try std.testing.expectError(error.InvalidWebSearchBackend, preferredWebSearchBackendsOverride("parallel_search"));
}

test "built-in gateway chat url honors loopback override before fallback" {
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123/chat",
        resolveChatUrl("https://fallback.test/chat", "http://127.0.0.1:43123/chat"),
    );
    try std.testing.expectEqualStrings(
        "https://fallback.test/chat",
        resolveChatUrl("https://fallback.test/chat", null),
    );
}

test "built-in gateway chat url ignores untrusted overrides and falls back" {
    const fallback = "https://ai-gateway.vercel.sh/v3/ai/language-model";
    for ([_][]const u8{
        "https://evil.example/chat",
        "http://evil.example/chat",
        "http://127.0.0.1:8080@evil.example/chat",
        "ftp://evil.example/chat",
        "not a url",
        "",
    }) |bad| {
        try std.testing.expectEqualStrings(fallback, resolveChatUrl(fallback, bad));
    }
}

pub fn fetchModelIds(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, null, .full);
}

pub fn fetchModelIdsCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, cancel_flag, .full);
}

pub fn fetchPickerModelIdsCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, cancel_flag, .picker);
}

pub fn fetchModelCatalog(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, null, .full);
}

pub fn fetchModelCatalogCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, cancel_flag, .full);
}

pub fn fetchPickerModelCatalog(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, null, .picker);
}

pub fn fetchPickerModelCatalogCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, cancel_flag, .picker);
}

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

pub const ModelCatalogEntry = model_catalog.ModelCatalogEntry;
pub const freeModelCatalog = model_catalog.freeModelCatalog;

fn parseSortedModelIds(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList([]u8) {
    return parseModelIdsForView(alloc, json_text, .full);
}

const ModelCatalogView = model_catalog.View;

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const response = fetchModelCatalogResponse(
        alloc,
        input.access,
        input.endpoint,
        input.cancel_flag,
    ) catch |err| return .{ .failure = catalogRequestFailure(err) };
    const json_text = switch (response) {
        .success => |body| body,
        .http_status => |status| return .{ .failure = model_catalog.failureForHttpStatus(status) },
    };
    defer alloc.free(json_text);

    const catalog = parseModelCatalogForView(alloc, json_text, input.view) catch |err| return .{
        .failure = .{
            .category = if (err == error.OutOfMemory) .resource_exhausted else .malformed_response,
            .http_status = .ok,
        },
    };
    return .{ .catalog = catalog };
}

fn fetchModelIdsForView(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    view: ModelCatalogView,
) !std.ArrayList([]u8) {
    var catalog = try fetchModelCatalogForView(alloc, access, path, cancel_flag, view);
    defer freeModelCatalog(alloc, &catalog);

    return model_catalog.projectModelIds(alloc, catalog.items);
}

fn fetchModelCatalogForView(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    view: ModelCatalogView,
) !std.ArrayList(ModelCatalogEntry) {
    const response = try fetchModelCatalogResponse(alloc, access, path, cancel_flag);
    const json_text = switch (response) {
        .success => |body| body,
        .http_status => |status| return model_catalog.failureForHttpStatus(status).asError(),
    };
    defer alloc.free(json_text);

    return parseModelCatalogForView(alloc, json_text, view);
}

fn fetchModelCatalogResponse(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) !gateway_client.GatewayJsonResult {
    if (cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }

    const team_path = try modelCatalogTeamPath(alloc, path, access);
    defer if (team_path) |owned| alloc.free(owned);

    const model_catalog_url = try modelCatalogUrl(
        alloc,
        team_path orelse path,
        io_mod.getenv(base_url_env),
    );
    defer alloc.free(model_catalog_url);

    const api_key = access.authorizationCredential();
    const gateway_team = modelCatalogHeaderTeam(access);
    return if (cancel_flag) |flag|
        gateway_client.fetchGatewayJsonCancellable(alloc, api_key, gateway_team, model_catalog_url, flag)
    else
        gateway_client.fetchGatewayJson(alloc, api_key, gateway_team, model_catalog_url);
}

fn modelCatalogTeamPath(
    alloc: Allocator,
    path: []const u8,
    access: credentials.CatalogAccess,
) Allocator.Error!?[]u8 {
    if (access.credentialSource() != .fx_login) return null;
    const team = access.teamContext() orelse return null;
    if (!shared_types.validGatewayTeam(team)) return null;
    return try std.fmt.allocPrint(alloc, "{s}?teamId={s}", .{ path, team });
}

fn modelCatalogHeaderTeam(access: credentials.CatalogAccess) ?[]const u8 {
    if (access.credentialSource() == .fx_login) return null;
    return access.teamContext();
}

fn catalogRequestFailure(err: anyerror) model_catalog.Failure {
    if (err == error.OutOfMemory) return .{ .category = .resource_exhausted };
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (isInvalidGatewayResponse(err)) return .{ .category = .malformed_response };
    return .{
        .category = .transport,
        .retryable = gateway_client.isRetryableGatewayError(err),
    };
}

fn isInvalidGatewayResponse(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionHeaderUnsupported,
        error.HttpContentEncodingUnsupported,
        error.HttpHeaderContinuationsUnsupported,
        error.HttpHeadersInvalid,
        error.HttpTransferEncodingUnsupported,
        error.InvalidContentLength,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpHeadersOversize,
        error.UnsupportedCompressionMethod,
        => true,
        else => false,
    };
}

test "catalog request failures preserve transport and cancellation facts" {
    const network = catalogRequestFailure(error.ConnectionResetByPeer);
    try std.testing.expectEqual(model_catalog.FailureCategory.transport, network.category);
    try std.testing.expect(network.http_status == null);
    try std.testing.expect(network.retryable);

    const cancelled = catalogRequestFailure(error.Cancelled);
    try std.testing.expectEqual(model_catalog.FailureCategory.cancellation, cancelled.category);
    try std.testing.expect(!cancelled.retryable);

    const malformed = catalogRequestFailure(error.HttpHeadersInvalid);
    try std.testing.expectEqual(model_catalog.FailureCategory.malformed_response, malformed.category);
}

fn modelCatalogUrl(alloc: Allocator, path: []const u8, base_url_override: ?[]const u8) ![]u8 {
    const base_url = if (base_url_override) |candidate| blk: {
        if (gateway_client.isLoopbackHttpUrl(candidate)) break :blk candidate;
        debug_trace.logf("gateway", "ignoring {s}: not loopback http", .{base_url_env});
        break :blk default_model_catalog_base_url;
    } else default_model_catalog_base_url;

    return std.fmt.allocPrint(alloc, "{s}{s}", .{ base_url, path });
}

var stable_models_test_environ: ?*std.process.Environ.Map = null;

fn stableModelsTestEnviron() !*const std.process.Environ.Map {
    if (stable_models_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_models_test_environ = map;
    return map;
}

const ModelsUrlTestEnv = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: std.mem.Allocator, models_url: []const u8) !*ModelsUrlTestEnv {
        _ = try stableModelsTestEnviron();

        const self = try alloc.create(ModelsUrlTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put(e2e_gateway_models_url_env, models_url);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *ModelsUrlTestEnv) void {
        if (stable_models_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn installLoopbackModelsEnv(alloc: std.mem.Allocator, port: u16) !*ModelsUrlTestEnv {
    const models_url = try std.fmt.allocPrint(
        alloc,
        "http://127.0.0.1:{d}/v1/models",
        .{port},
    );
    defer alloc.free(models_url);
    return ModelsUrlTestEnv.install(alloc, models_url);
}

test "model catalog GET includes selected team header" {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var ids = try fetchModelIds(std.testing.allocator, credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"), models_path);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("Bearer test-key", fixture.capturedHeaderValue("authorization").?);
    try std.testing.expectEqualStrings("team_123", fixture.capturedHeaderValue(gateway_client.vercel_ai_gateway_team_header).?);
    if (fixture.failure()) |err| return err;
}

test "cancellable model catalog GET includes selected team header" {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var ids = try fetchModelIdsCancellable(
        std.testing.allocator,
        credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"),
        models_path,
        &cancel_flag,
    );
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("Bearer test-key", fixture.capturedHeaderValue("authorization").?);
    try std.testing.expectEqualStrings("team_123", fixture.capturedHeaderValue(gateway_client.vercel_ai_gateway_team_header).?);
    if (fixture.failure()) |err| return err;
}

fn expectModelCatalogTeamHeaderOmitted(gateway_team: ?[]const u8) !void {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var ids = try fetchModelIds(std.testing.allocator, credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", gateway_team), models_path);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("Bearer test-key", fixture.capturedHeaderValue("authorization").?);
    try std.testing.expect(fixture.capturedHeaderValue(gateway_client.vercel_ai_gateway_team_header) == null);
    if (fixture.failure()) |err| return err;
}

test "model catalog GET omits team header for null and empty team" {
    try expectModelCatalogTeamHeaderOmitted(null);
    try expectModelCatalogTeamHeaderOmitted("");
}

test "model catalog GET sends fx user agent without attribution headers" {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var ids = try fetchModelIds(std.testing.allocator, credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", null), models_path);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings(gateway_client.user_agent, fixture.capturedHeaderValue("user-agent").?);
    try std.testing.expect(std.mem.find(u8, fixture.capturedHeaderValue("user-agent").?, "zig") == null);
    // Attribution headers stay on model generation requests only.
    try std.testing.expect(fixture.capturedHeaderValue("http-referer") == null);
    try std.testing.expect(fixture.capturedHeaderValue("x-title") == null);
    if (fixture.failure()) |err| return err;
}

fn parseModelIdsForView(
    alloc: std.mem.Allocator,
    json_text: []const u8,
    view: ModelCatalogView,
) !std.ArrayList([]u8) {
    var catalog = try parseModelCatalogForView(alloc, json_text, view);
    defer freeModelCatalog(alloc, &catalog);

    return model_catalog.projectModelIds(alloc, catalog.items);
}

pub fn parseModelCatalogForView(
    alloc: std.mem.Allocator,
    json_text: []const u8,
    view: ModelCatalogView,
) !std.ArrayList(ModelCatalogEntry) {
    var catalog = try parseSortedModelCatalog(alloc, json_text);
    switch (view) {
        .full => return catalog,
        .picker => {
            defer freeModelCatalog(alloc, &catalog);
            return model_catalog.projectPickerModelCatalog(alloc, catalog.items);
        },
    }
}

fn parseSortedModelCatalog(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList(ModelCatalogEntry) {
    var candidates: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer freeModelCatalog(alloc, &candidates);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedResponse;
    const data_value = parsed.value.object.get("data") orelse return error.MalformedResponse;
    if (data_value != .array) return error.MalformedResponse;

    for (data_value.array.items) |entry| {
        const candidate = (try parseModelCatalogEntry(alloc, entry)) orelse continue;
        candidates.append(alloc, candidate) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, candidate);
            return err;
        };
    }

    sort_utils.sort(ModelCatalogEntry, candidates.items, {}, model_catalog.compareModelCatalogEntries);

    return candidates;
}

fn parsePickerModelIds(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList([]u8) {
    return parseModelIdsForView(alloc, json_text, .picker);
}

fn parsePickerModelCatalog(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return parseModelCatalogForView(alloc, json_text, .picker);
}

test "gateway catalog rejects malformed envelope shapes" {
    const malformed_envelopes = [_][]const u8{
        "[]",
        "{}",
        "{\"data\":{}}",
    };

    for (malformed_envelopes) |json_text| {
        try std.testing.expectError(
            error.MalformedResponse,
            parseSortedModelCatalog(std.testing.allocator, json_text),
        );
    }
}

test "gateway catalog accepts an explicit empty data array" {
    var catalog = try parseSortedModelCatalog(std.testing.allocator, "{\"data\":[]}");
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 0), catalog.items.len);
}

fn parseModelCatalogEntry(alloc: std.mem.Allocator, entry: std.json.Value) !?ModelCatalogEntry {
    if (entry != .object) return null;

    const model_type = if (entry.object.get("type")) |type_value| blk: {
        if (type_value == .string and !std.ascii.eqlIgnoreCase(type_value.string, "language")) {
            return null;
        }
        break :blk if (type_value == .string) type_value.string else "";
    } else "";

    const id_value = entry.object.get("id") orelse return null;
    if (id_value != .string) return null;

    const released = if (entry.object.get("released")) |value|
        switch (value) {
            .integer => value.integer,
            else => 0,
        }
    else
        0;

    const tags_value = entry.object.get("tags");
    const has_tool_use = optionalTagListContains(tags_value, "tool-use");
    var reasoning_efforts = try parseReasoningEfforts(alloc, entry.object.get("reasoning_options"));
    errdefer reasoning_efforts.deinit(alloc);
    const has_reasoning = optionalTagListContains(tags_value, "reasoning") or reasoning_efforts.items.len > 0;
    const supports_fast_mode = supportsFastMode(entry.object);
    const has_vision = optionalTagListContains(tags_value, "vision");
    const has_file_input = optionalTagListContains(tags_value, "file-input");
    const has_web_search = optionalTagListContains(tags_value, "web-search");
    const has_explicit_caching = optionalTagListContains(tags_value, "explicit-caching");
    const has_implicit_caching = optionalTagListContains(tags_value, "implicit-caching");

    const context_window = optionalUnsignedU32(entry.object.get("context_window"));
    const max_tokens = optionalUnsignedU32(entry.object.get("max_tokens"));
    const web_search_price = try parseWebSearchPrice(alloc, entry.object.get("pricing"));
    errdefer if (web_search_price) |value| alloc.free(value);

    const id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(id);
    const owned_model_type = try alloc.dupe(u8, model_type);
    errdefer alloc.free(owned_model_type);

    return .{
        .id = id,
        .model_type = owned_model_type,
        .released = released,
        .has_tool_use = has_tool_use,
        .has_reasoning = has_reasoning,
        .reasoning_efforts = reasoning_efforts,
        .supports_fast_mode = supports_fast_mode,
        .has_vision = has_vision,
        .has_file_input = has_file_input,
        .has_web_search = has_web_search,
        .has_explicit_caching = has_explicit_caching,
        .has_implicit_caching = has_implicit_caching,
        .context_window = context_window,
        .max_tokens = max_tokens,
        .web_search_price = web_search_price,
    };
}

fn parseReasoningEfforts(alloc: std.mem.Allocator, options: ?std.json.Value) !std.ArrayList(shared_types.ReasoningEffort) {
    var efforts: std.ArrayList(shared_types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);

    const value = options orelse return efforts;
    if (value != .array) return efforts;
    for (value.array.items) |option| {
        if (option != .object) continue;
        const option_type = option.object.get("type") orelse continue;
        if (option_type != .string or !std.mem.eql(u8, option_type.string, "effort")) continue;
        const values = option.object.get("values") orelse continue;
        if (values != .array) continue;
        for (values.array.items) |raw| {
            if (efforts.items.len >= shared_types.ReasoningEffort.max_options) break;
            if (raw != .string) continue;
            const effort = shared_types.ReasoningEffort.parse(raw.string) orelse continue;
            if (effort.isDefault()) continue;
            try efforts.append(alloc, effort);
        }
        break;
    }
    return efforts;
}

fn hasToggleOption(options: ?std.json.Value) bool {
    const value = options orelse return false;
    if (value != .array) return false;
    for (value.array.items) |option| {
        if (option != .object) continue;
        const option_type = option.object.get("type") orelse continue;
        if (option_type == .string and std.mem.eql(u8, option_type.string, "toggle")) return true;
    }
    return false;
}

fn supportsFastMode(entry: std.json.ObjectMap) bool {
    if (hasToggleOption(entry.get("fast_options"))) return true;

    const pricing = entry.get("pricing");
    if (hasObjectField(pricing, "fast")) return true;

    const owned_by = entry.get("owned_by") orelse return false;
    if (owned_by != .string or !std.ascii.eqlIgnoreCase(owned_by.string, "openai")) return false;
    return hasObjectField(objectField(pricing, "service_tiers"), "priority");
}

fn objectField(value: ?std.json.Value, key: []const u8) ?std.json.Value {
    const actual = value orelse return null;
    if (actual != .object) return null;
    return actual.object.get(key);
}

fn hasObjectField(value: ?std.json.Value, key: []const u8) bool {
    const field = objectField(value, key) orelse return false;
    return field == .object;
}

fn optionalUnsignedU32(value: ?std.json.Value) u32 {
    const actual = value orelse return 0;
    if (actual != .integer or actual.integer <= 0) return 0;
    return std.math.cast(u32, actual.integer) orelse 0;
}

fn parseWebSearchPrice(alloc: std.mem.Allocator, pricing: ?std.json.Value) !?[]u8 {
    const pricing_value = pricing orelse return null;
    if (pricing_value != .object) return null;
    const price = pricing_value.object.get("web_search") orelse return null;
    return switch (price) {
        .string => |value| try alloc.dupe(u8, value),
        .integer, .float => blk: {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try std.json.Stringify.value(price, .{}, &out.writer);
            break :blk try out.toOwnedSlice();
        },
        else => null,
    };
}

fn optionalTagListContains(value: ?std.json.Value, needle: []const u8) bool {
    return if (value) |actual| tagListContains(actual, needle) else false;
}

fn tagListContains(value: std.json.Value, needle: []const u8) bool {
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item == .string and std.ascii.eqlIgnoreCase(item.string, needle)) return true;
    }
    return false;
}

test "parseSortedModelIds filters non-language entries and surfaces popular models first" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"google/gemini-2.5-flash-image","type":"image-generation","released":30,"tags":["image-generation"]},
        \\  {"id":"anthropic/claude-haiku-4.5","type":"language","released":20,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5","type":"language","released":40,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-opus-4.6","type":"language","released":50,"tags":["tool-use"]}
        \\]}
    ;

    var ids = try parseSortedModelIds(std.testing.allocator, json_text);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.6", ids.items[0]);
    try std.testing.expectEqualStrings("openai/gpt-5", ids.items[1]);
    try std.testing.expectEqualStrings("anthropic/claude-haiku-4.5", ids.items[2]);
}

test "parseSortedModelIds prefers tool-use models over unsupported ones" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"openai/gpt-5","type":"language","released":10,"tags":[]},
        \\  {"id":"openai/gpt-5-mini","type":"language","released":9,"tags":["tool-use"]}
        \\]}
    ;

    var ids = try parseSortedModelIds(std.testing.allocator, json_text);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("openai/gpt-5-mini", ids.items[0]);
    try std.testing.expectEqualStrings("openai/gpt-5", ids.items[1]);
}

fn idsContain(ids: []const []const u8, needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}

test "parsePickerModelIds keeps highlights on top and exposes the full catalog" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"anthropic/claude-opus-4.8","type":"language","released":50,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-opus-4.7","type":"language","released":40,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-opus-4.6","type":"language","released":30,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-opus-4.5","type":"language","released":20,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-sonnet-4.6","type":"language","released":60,"tags":["tool-use"]},
        \\  {"id":"alibaba/qwen-3.7-max","type":"language","released":130,"tags":["tool-use"]},
        \\  {"id":"alibaba/qwen-3.7-plus","type":"language","released":120,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.5","type":"language","released":90,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.5-pro","type":"language","released":90,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.4","type":"language","released":85,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.4-mini","type":"language","released":85,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.3-codex","type":"language","released":80,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.2-codex","type":"language","released":70,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-5.2","type":"language","released":70,"tags":["tool-use"]},
        \\  {"id":"openai/o3","type":"language","released":110,"tags":["tool-use"]},
        \\  {"id":"openai/gpt-oss-120b","type":"language","released":100,"tags":["tool-use"]},
        \\  {"id":"xai/grok-build-0.1","type":"language","released":95,"tags":["tool-use"]},
        \\  {"id":"google/gemini-3.1-pro","type":"language","released":120,"tags":["tool-use"]},
        \\  {"id":"zai/glm-5.2","type":"language","released":100,"tags":["tool-use"]},
        \\  {"id":"zai/glm-5.2-fast","type":"language","released":100,"tags":["tool-use"]},
        \\  {"id":"zai/glm-5.1","type":"language","released":90,"tags":["tool-use"]},
        \\  {"id":"zai/glm-5","type":"language","released":80,"tags":["tool-use"]},
        \\  {"id":"deepseek/deepseek-v4","type":"language","released":110,"tags":["tool-use"]},
        \\  {"id":"deepseek/deepseek-v4-flash","type":"language","released":110,"tags":["tool-use"]},
        \\  {"id":"deepseek/deepseek-v4-pro","type":"language","released":110,"tags":["tool-use"]},
        \\  {"id":"minimax/minimax-m3","type":"language","released":140,"tags":["tool-use"]},
        \\  {"id":"minimax/minimax-m2.7","type":"language","released":130,"tags":["tool-use"]}
        \\]}
    ;

    var ids = try parsePickerModelIds(std.testing.allocator, json_text);
    defer collections.freeStringList(std.testing.allocator, &ids);

    const expected_featured = [_][]const u8{
        "openai/gpt-5.5",
        "xai/grok-build-0.1",
        "anthropic/claude-opus-4.8",
        "zai/glm-5.2",
        "deepseek/deepseek-v4-pro",
        "minimax/minimax-m3",
    };
    for (expected_featured, 0..) |model, index| {
        try std.testing.expectEqualStrings(model, ids.items[index]);
    }
    try std.testing.expectEqualStrings("alibaba/qwen-3.7-max", ids.items[expected_featured.len]);
    try std.testing.expectEqualStrings("alibaba/qwen-3.7-plus", ids.items[expected_featured.len + 1]);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", ids.items[expected_featured.len + 2]);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.6", ids.items[expected_featured.len + 3]);

    const all_models = [_][]const u8{
        "anthropic/claude-opus-4.8",
        "anthropic/claude-opus-4.7",
        "anthropic/claude-opus-4.6",
        "anthropic/claude-opus-4.5",
        "anthropic/claude-sonnet-4.6",
        "alibaba/qwen-3.7-max",
        "alibaba/qwen-3.7-plus",
        "openai/gpt-5.5",
        "openai/gpt-5.5-pro",
        "openai/gpt-5.4",
        "openai/gpt-5.4-mini",
        "openai/gpt-5.3-codex",
        "openai/gpt-5.2-codex",
        "openai/gpt-5.2",
        "openai/o3",
        "openai/gpt-oss-120b",
        "xai/grok-build-0.1",
        "google/gemini-3.1-pro",
        "zai/glm-5.2",
        "zai/glm-5.2-fast",
        "zai/glm-5.1",
        "zai/glm-5",
        "deepseek/deepseek-v4",
        "deepseek/deepseek-v4-flash",
        "deepseek/deepseek-v4-pro",
        "minimax/minimax-m3",
        "minimax/minimax-m2.7",
    };
    for (all_models) |model| {
        try std.testing.expect(idsContain(ids.items, model));
    }
    try std.testing.expectEqual(all_models.len, ids.items.len);
}

test "parsePickerModelIds features Fable as the top highlight" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"anthropic/claude-opus-4.8","type":"language","released":50,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-fable-5","type":"language","released":55,"tags":["tool-use"]},
        \\  {"id":"anthropic/claude-sonnet-4.6","type":"language","released":60,"tags":["tool-use"]}
        \\]}
    ;

    var ids = try parsePickerModelIds(std.testing.allocator, json_text);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("anthropic/claude-fable-5", ids.items[0]);
    try std.testing.expect(idsContain(ids.items, "anthropic/claude-opus-4.8"));
    try std.testing.expect(idsContain(ids.items, "anthropic/claude-sonnet-4.6"));
    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
}

test "gateway catalog retains broad capability metadata" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"provider/search-priced-worker","type":"language","released":20,"tags":["reasoning","tool-use","vision","file-input","web-search","explicit-caching","implicit-caching"],"context_window":200000,"max_tokens":64000,"pricing":{"web_search":"0.01"}}
        \\]}
    ;

    var catalog = try parseSortedModelCatalog(std.testing.allocator, json_text);
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("provider/search-priced-worker", catalog.items[0].id);
    try std.testing.expectEqualStrings("language", catalog.items[0].model_type);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(catalog.items[0].has_reasoning);
    try std.testing.expectEqual(@as(usize, 0), catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expect(catalog.items[0].has_vision);
    try std.testing.expect(catalog.items[0].has_file_input);
    try std.testing.expect(catalog.items[0].has_web_search);
    try std.testing.expect(catalog.items[0].has_explicit_caching);
    try std.testing.expect(catalog.items[0].has_implicit_caching);
    try std.testing.expectEqual(@as(u32, 200_000), catalog.items[0].context_window);
    try std.testing.expectEqual(@as(u32, 64_000), catalog.items[0].max_tokens);
    try std.testing.expectEqualStrings("0.01", catalog.items[0].web_search_price.?);
}

test "gateway catalog recognizes structured reasoning without a reasoning tag" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"provider/future","type":"language","tags":["tool-use","fast"],"reasoning_options":[{"type":"effort","values":["future-tier","high"]},{"type":"budget_tokens","min":1,"max":2048}],"fast_options":[{"type":"toggle"}]}
        \\]}
    ;

    var catalog = try parseSortedModelCatalog(std.testing.allocator, json_text);
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expect(catalog.items[0].has_reasoning);
    try std.testing.expectEqual(@as(usize, 2), catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("future-tier", catalog.items[0].reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("high", catalog.items[0].reasoning_efforts.items[1].label());
    try std.testing.expect(catalog.items[0].supports_fast_mode);
}

test "gateway catalog derives Fast support from explicit provider metadata" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"provider/tagged-fast","type":"language","owned_by":"provider","tags":["fast"]},
        \\  {"id":"provider/priced-fast","type":"language","owned_by":"provider","pricing":{"fast":{"input":"0.1","output":"0.2"}}},
        \\  {"id":"openai/priority","type":"language","owned_by":"openai","pricing":{"service_tiers":{"priority":{"input":"0.1","output":"0.2"}}}},
        \\  {"id":"google/priority","type":"language","owned_by":"google","pricing":{"service_tiers":{"priority":{"input":"0.1","output":"0.2"}}}},
        \\  {"id":"provider/malformed-fast","type":"language","owned_by":"provider","pricing":{"fast":"0.1","service_tiers":{"priority":"0.2"}}}
        \\ ]}
    ;

    var catalog = try parseSortedModelCatalog(std.testing.allocator, json_text);
    defer freeModelCatalog(std.testing.allocator, &catalog);

    const expected = [_]struct { id: []const u8, supports_fast_mode: bool }{
        .{ .id = "google/priority", .supports_fast_mode = false },
        .{ .id = "openai/priority", .supports_fast_mode = true },
        .{ .id = "provider/malformed-fast", .supports_fast_mode = false },
        .{ .id = "provider/priced-fast", .supports_fast_mode = true },
        .{ .id = "provider/tagged-fast", .supports_fast_mode = false },
    };
    try std.testing.expectEqual(expected.len, catalog.items.len);
    for (expected) |wanted| {
        const supports_fast_mode = for (catalog.items) |actual| {
            if (std.mem.eql(u8, wanted.id, actual.id)) break actual.supports_fast_mode;
        } else return error.TestExpectedEqual;
        try std.testing.expectEqual(wanted.supports_fast_mode, supports_fast_mode);
    }
}

test "gateway catalog controls are explicit ordered and bounded" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"provider/adversarial","type":"language","tags":["reasoning","fast"],"pricing":{"fast":"1"},"reasoning_options":[42,{"type":"toggle","values":["invented"]},{"type":"effort","values":["default","first",7,"bad value","second","third","fourth","fifth","sixth","seventh","eighth","ninth","tenth","eleventh","twelfth","thirteenth","fourteenth","fifteenth","sixteenth","seventeenth"]}],"fast_options":[null,{"type":"budget_tokens"}]},
        \\  {"id":"provider/explicit-fast","type":"language","fast_options":[{"type":"toggle"}]},
        \\  {"id":"provider/malformed","type":"language","reasoning_options":{"type":"effort","values":["high"]},"fast_options":{"type":"toggle"}}
        \\ ]}
    ;

    var catalog = try parseSortedModelCatalog(std.testing.allocator, json_text);
    defer freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 3), catalog.items.len);
    const adversarial = catalog.items[0];
    try std.testing.expectEqualStrings("provider/adversarial", adversarial.id);
    try std.testing.expectEqual(shared_types.ReasoningEffort.max_options, adversarial.reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("first", adversarial.reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("sixteenth", adversarial.reasoning_efforts.items[15].label());
    try std.testing.expect(!adversarial.supports_fast_mode);

    try std.testing.expectEqualStrings("provider/explicit-fast", catalog.items[1].id);
    try std.testing.expect(catalog.items[1].supports_fast_mode);
    try std.testing.expectEqualStrings("provider/malformed", catalog.items[2].id);
    try std.testing.expectEqual(@as(usize, 0), catalog.items[2].reasoning_efforts.items.len);
    try std.testing.expect(!catalog.items[2].supports_fast_mode);
}

const AdapterAuthStoreProbe = struct {
    loads: usize = 0,
    value: []const u8,

    fn store(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "adapter test store",
            .is_disabled_fn = isDisabled,
            .load_fn = load,
            .store_fn = write,
            .store_interactive_fn = writeInteractive,
        };
    }

    fn isDisabled(_: ?*anyopaque) bool {
        return false;
    }

    fn load(raw: ?*anyopaque, alloc: Allocator) host.SecretStoreLoadError!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.loads += 1;
        return try alloc.dupe(u8, self.value);
    }

    fn write(_: ?*anyopaque, _: Allocator, _: []const u8) host.SecretStoreWriteError!void {}

    fn writeInteractive(_: ?*anyopaque) host.SecretStoreWriteError!bool {
        return false;
    }
};

const PeerAuthProbe = struct {
    acquire_calls: usize = 0,
    cancel_during_acquire: ?*std.atomic.Value(bool) = null,

    fn acquire(raw: *const anyopaque, alloc: Allocator, request: adapter_auth.Request) Allocator.Error!adapter_auth.Acquisition {
        const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
        self.acquire_calls += 1;
        const value = request.host.secret_store.load(alloc) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .missing = .unavailable };
        } orelse return .{ .missing = .not_found };
        if (self.cancel_during_acquire) |flag| flag.store(true, .seq_cst);
        return .{ .acquired = .{
            .secret_bytes = value,
            .source = .{ .id = "peer_key", .label = "peer key", .refreshable = false },
            .catalog_access = .authenticated,
        } };
    }
};

const AdapterAuthTestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const [2][]const u8) !*AdapterAuthTestEnv {
        _ = try stableModelsTestEnviron();
        const self = try alloc.create(AdapterAuthTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .map = std.process.Environ.Map.init(alloc) };
        errdefer self.map.deinit();
        for (entries) |entry| try self.map.put(entry[0], entry[1]);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *AdapterAuthTestEnv) void {
        if (stable_models_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn adapterAuthTestProfile(kind: []const u8, credential_ref: []const u8) connection_registry.Profile {
    return .{
        .id = @constCast("test"),
        .display_name = @constCast("Test"),
        .adapter_id = @constCast(kind),
        .endpoint = null,
        .protocol = null,
        .credential_ref = @constCast(credential_ref),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    };
}

test "production registry contains only Vercel" {
    const validated = try adapter_registry.AdapterRegistry.init(production_adapter_registry.adapters);
    try std.testing.expectEqual(@as(usize, 1), validated.adapters.len);
    try std.testing.expectEqualStrings(connection_seed.adapter_id, validated.adapters[0].kind);
}

test "top-level status and interactive acquire resolve one adapter with zero cross traffic" {
    var peer_probe: PeerAuthProbe = .{};
    const peer_auth = adapter_auth.Provider{
        .kind = "test_peer",
        .context = &peer_probe,
        .acquire_fn = PeerAuthProbe.acquire,
    };
    const peer_adapter = agent_stream_provider_contract.ProviderAdapter{
        .kind = "test_peer",
        .auth = peer_auth,
        .stream_fn = agent_stream_provider_contract.unavailable_adapter.stream_fn,
    };
    const adapters = [_]agent_stream_provider_contract.ProviderAdapter{ provider_adapter, peer_adapter };
    const registry = try adapter_registry.AdapterRegistry.init(&adapters);
    var vercel_store = AdapterAuthStoreProbe{ .value = "vercel-secret" };
    var peer_store = AdapterAuthStoreProbe{ .value = "peer-secret" };

    const vercel_profile = adapterAuthTestProfile(connection_seed.adapter_id, "stored_key");
    const vercel_auth = try registry.resolveAuthForProfile(vercel_profile);
    var status = switch (try vercel_auth.status(std.testing.allocator, vercel_profile, .{
        .secret_store = vercel_store.store(),
    })) {
        .loaded => |value| value,
        .failed, .cancelled => return error.UnexpectedAdapterStatus,
    };
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), vercel_store.loads);
    try std.testing.expectEqual(@as(usize, 0), peer_store.loads);
    try std.testing.expectEqual(@as(usize, 0), peer_probe.acquire_calls);
    try std.testing.expectEqualStrings(credentials.sourceLabel(.stored_key), status.source.?.label);

    const peer_profile = adapterAuthTestProfile("test_peer", "automatic");
    const selected_peer = try registry.resolveAuthForProfile(peer_profile);
    var credential = switch (try selected_peer.acquire(std.testing.allocator, .{
        .profile = peer_profile,
        .host = .{ .secret_store = peer_store.store() },
        .mode = .if_needed,
        .source_resolution = .allow_fallback,
    })) {
        .acquired => |value| value,
        .missing, .failed, .cancelled => return error.UnexpectedAdapterAcquisition,
    };
    defer credential.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), vercel_store.loads);
    try std.testing.expectEqual(@as(usize, 1), peer_store.loads);
    try std.testing.expectEqual(@as(usize, 1), peer_probe.acquire_calls);

    try std.testing.expectError(
        error.MissingAdapter,
        registry.resolveAuthForProfile(adapterAuthTestProfile("missing", "automatic")),
    );
    try std.testing.expectEqual(@as(usize, 1), vercel_store.loads);
    try std.testing.expectEqual(@as(usize, 1), peer_store.loads);
}

test "adapter auth preserves invalid references refresh failures and late cancellation" {
    const env_secret = "invalid-reference-must-not-fallback";
    const env = try AdapterAuthTestEnv.install(std.testing.allocator, &.{.{ "AI_GATEWAY_API_KEY", env_secret }});
    defer env.deinit();
    var vercel_store = AdapterAuthStoreProbe{ .value = "stored-secret" };

    const invalid_profile = adapterAuthTestProfile(connection_seed.adapter_id, "not_a_credential_source");
    const invalid = try auth_provider.acquire(std.testing.allocator, .{
        .profile = invalid_profile,
        .host = .{ .secret_store = vercel_store.store() },
        .mode = .if_needed,
        .source_resolution = .exact,
    });
    switch (invalid) {
        .failed => |failure| try std.testing.expectEqual(adapter_auth.FailureCategory.configuration, failure.category),
        .acquired, .missing, .cancelled => return error.UnexpectedInvalidReferenceOutcome,
    }
    var failure_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer failure_json.deinit();
    try std.json.Stringify.value(invalid, .{}, &failure_json.writer);
    try std.testing.expect(std.mem.find(u8, failure_json.written(), env_secret) == null);
    const invalid_status = try auth_provider.status(std.testing.allocator, invalid_profile, .{
        .secret_store = vercel_store.store(),
    });
    switch (invalid_status) {
        .failed => |failure| try std.testing.expectEqual(adapter_auth.FailureCategory.configuration, failure.category),
        .loaded, .cancelled => return error.UnexpectedInvalidReferenceStatus,
    }
    try std.testing.expectEqual(@as(usize, 0), vercel_store.loads);

    const refresh = try auth_provider.acquire(std.testing.allocator, .{
        .profile = adapterAuthTestProfile(connection_seed.adapter_id, "fx_login"),
        .host = .{ .secret_store = vercel_store.store() },
        .mode = .force,
        .source_resolution = .exact,
        .current_source_id = "fx_login",
    });
    switch (refresh) {
        .failed => |failure| try std.testing.expectEqual(adapter_auth.FailureCategory.unavailable, failure.category),
        .acquired, .missing, .cancelled => return error.UnexpectedRefreshFailureOutcome,
    }
    try std.testing.expectEqual(@as(usize, 0), vercel_store.loads);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var peer_probe = PeerAuthProbe{ .cancel_during_acquire = &cancel_flag };
    const peer_auth = adapter_auth.Provider{
        .kind = "test_peer",
        .context = &peer_probe,
        .acquire_fn = PeerAuthProbe.acquire,
    };
    const adapters = [_]agent_stream_provider_contract.ProviderAdapter{
        provider_adapter,
        .{
            .kind = "test_peer",
            .auth = peer_auth,
            .stream_fn = agent_stream_provider_contract.unavailable_adapter.stream_fn,
        },
    };
    const registry = try adapter_registry.AdapterRegistry.init(&adapters);
    const peer_profile = adapterAuthTestProfile("test_peer", "automatic");
    var backing: [128]u8 = [_]u8{0xa5} ** 128;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var peer_store = AdapterAuthStoreProbe{ .value = "late-cancel-secret" };
    const cancelled = try (try registry.resolveAuthForProfile(peer_profile)).acquire(fixed.allocator(), .{
        .profile = peer_profile,
        .host = .{ .secret_store = peer_store.store() },
        .mode = .if_needed,
        .source_resolution = .exact,
        .cancel_flag = &cancel_flag,
    });
    try std.testing.expect(cancelled == .cancelled);
    try std.testing.expectEqual(@as(usize, 1), peer_store.loads);
    try std.testing.expectEqual(@as(usize, 1), peer_probe.acquire_calls);
    try std.testing.expect(std.mem.find(u8, &backing, "late-cancel-secret") == null);
}

const ConditionalRefreshProbe = struct {
    discovery_calls: usize = 0,
    refresh_calls: usize = 0,
    saw_refresh_secret: bool = false,

    fn provider(self: *@This()) oauth_transport.Provider {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return switch (request.method) {
            .get => blk: {
                self.discovery_calls += 1;
                break :blk .{
                    .disposition = .accepted,
                    .body = try alloc.dupe(u8,
                        \\{"issuer":"https://vercel.com","device_authorization_endpoint":"https://vercel.com/oauth/device","token_endpoint":"https://vercel.com/oauth/token"}
                    ),
                };
            },
            .post_form => {
                self.refresh_calls += 1;
                self.saw_refresh_secret = if (request.payload) |payload|
                    std.mem.find(u8, payload, "conditional-refresh-secret") != null
                else
                    false;
                return error.InjectedRefreshFailure;
            },
        };
    }
};

test "exact conditional fx login refresh failure is normalized without fallback" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const fallback_secret = "conditional-fallback-secret";
    const env = try AdapterAuthTestEnv.install(alloc, &.{
        .{ "HOME", home },
        .{ "AI_GATEWAY_API_KEY", fallback_secret },
    });
    defer env.deinit();

    var session = oauth_session.Session{
        .issuer = try alloc.dupe(u8, "https://vercel.com"),
        .client_id = try alloc.dupe(u8, "test-client"),
        .access_token = try alloc.dupe(u8, "expired-access-secret"),
        .refresh_token = try alloc.dupe(u8, "conditional-refresh-secret"),
        .expires_at_ms = 0,
        .scope = try alloc.dupe(u8, "openid offline_access"),
        .token_type = try alloc.dupe(u8, "Bearer"),
    };
    defer session.deinit(alloc);
    try oauth_session.saveNewSession(alloc, session);

    var refresh_probe: ConditionalRefreshProbe = .{};
    const transport = refresh_probe.provider();
    const test_provider = auth_provider_for_transport(&transport);
    var store = AdapterAuthStoreProbe{ .value = "stored-fallback-secret" };
    const outcome = try test_provider.acquire(alloc, .{
        .profile = adapterAuthTestProfile(connection_seed.adapter_id, "fx_login"),
        .host = .{ .secret_store = store.store() },
        .mode = .if_needed,
        .source_resolution = .exact,
        .current_source_id = "fx_login",
    });
    switch (outcome) {
        .failed => |failure| try std.testing.expectEqual(adapter_auth.FailureCategory.unavailable, failure.category),
        .acquired, .missing, .cancelled => return error.UnexpectedConditionalRefreshOutcome,
    }
    try std.testing.expectEqual(@as(usize, 1), refresh_probe.discovery_calls);
    try std.testing.expectEqual(@as(usize, 1), refresh_probe.refresh_calls);
    try std.testing.expect(refresh_probe.saw_refresh_secret);
    try std.testing.expectEqual(@as(usize, 0), store.loads);

    var rendered: std.Io.Writer.Allocating = .init(alloc);
    defer rendered.deinit();
    try std.json.Stringify.value(outcome, .{}, &rendered.writer);
    for ([_][]const u8{ "expired-access-secret", "conditional-refresh-secret", fallback_secret, store.value }) |value| {
        try std.testing.expect(std.mem.find(u8, rendered.written(), value) == null);
    }
}
