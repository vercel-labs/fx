const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const oauth = @import("oauth.zig");
const oauth_session = @import("oauth_session.zig");
const oauth_transport = @import("oauth_transport.zig");
const provider_oauth = @import("provider_oauth.zig");
const secret = @import("secret.zig");
const types = @import("../shared/types.zig");
const inference_provider = @import("../gateway/inference_provider.zig");

pub const Source = types.CredentialSource;

pub const CatalogPublicOnly = union(enum) {
    no_credential,
    fx_login_team_required,
    fx_login_refresh_required,
    credential_refresh_failed: Source,
    authenticated_credential_rejected: Source,

    fn credentialSource(self: CatalogPublicOnly) ?Source {
        return switch (self) {
            .no_credential => null,
            .fx_login_team_required, .fx_login_refresh_required => .fx_login,
            .credential_refresh_failed => |source| source,
            .authenticated_credential_rejected => |source| source,
        };
    }
};

pub const CatalogPublicOnlyReason = std.meta.Tag(CatalogPublicOnly);

pub const CatalogAuthenticatedSource = enum {
    vercel_oidc_token,
    ai_gateway_api_key,
    fx_login,
    stored_key,

    fn credentialSource(self: CatalogAuthenticatedSource) Source {
        return switch (self) {
            .vercel_oidc_token => .vercel_oidc_token,
            .ai_gateway_api_key => .ai_gateway_api_key,
            .fx_login => .fx_login,
            .stored_key => .stored_key,
        };
    }
};

/// A borrowed authorization decision for one model-catalog request. Public-only
/// states cannot carry credential or team bytes; authenticated states carry the
/// only values the request is allowed to send.
pub const CatalogAccess = union(enum) {
    public_only: CatalogPublicOnly,
    authenticated: struct {
        source: CatalogAuthenticatedSource,
        credential: []const u8,
        team_context: ?[]const u8,
    },

    pub fn credentialSource(self: CatalogAccess) ?Source {
        return switch (self) {
            .public_only => |access| access.credentialSource(),
            .authenticated => |access| access.source.credentialSource(),
        };
    }

    pub fn publicOnlyReason(self: CatalogAccess) ?CatalogPublicOnlyReason {
        const access = self.publicOnly() orelse return null;
        return std.meta.activeTag(access);
    }

    pub fn publicOnly(self: CatalogAccess) ?CatalogPublicOnly {
        return switch (self) {
            .public_only => |access| access,
            .authenticated => null,
        };
    }

    pub fn publicFallbackAfterRejection(self: CatalogAccess) ?CatalogAccess {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| .{
                .public_only = .{
                    .authenticated_credential_rejected = access.source.credentialSource(),
                },
            },
        };
    }

    pub fn authorizationCredential(self: CatalogAccess) ?[]const u8 {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| access.credential,
        };
    }

    pub fn teamContext(self: CatalogAccess) ?[]const u8 {
        const team = switch (self) {
            .public_only => return null,
            .authenticated => |access| access.team_context orelse return null,
        };
        return if (team.len > 0) team else null;
    }
};

pub fn catalogAccessAt(credential: ?Credential, now_ms: i64) CatalogAccess {
    const selected = credential orelse return .{ .public_only = .no_credential };
    if (selected.source == .fx_login and selected.needsRefreshAt(now_ms)) {
        return .{ .public_only = .fx_login_refresh_required };
    }
    return catalogAccessForCredential(
        selected.source,
        selected.token,
        selected.gatewayTeam(),
    );
}

pub fn catalogAccessAfterRefreshFailure(source: Source) CatalogAccess {
    return .{
        .public_only = .{
            .credential_refresh_failed = source,
        },
    };
}

pub fn catalogAccessForCredential(
    source: ?Source,
    credential: []const u8,
    team_context: ?[]const u8,
) CatalogAccess {
    const selected_source = source orelse return .{ .public_only = .no_credential };
    const authenticated_source: CatalogAuthenticatedSource = switch (selected_source) {
        .vercel_oidc_token => .vercel_oidc_token,
        .ai_gateway_api_key => .ai_gateway_api_key,
        .stored_key => .stored_key,
        .anthropic_fx_login,
        .anthropic_oauth_token,
        .anthropic_api_key,
        .codex_fx_login,
        .codex_login,
        .xai_oauth_token,
        .xai_api_key,
        => return .{ .public_only = .no_credential },
        .fx_login => blk: {
            const team = team_context orelse
                return .{ .public_only = .fx_login_team_required };
            if (!types.validGatewayTeam(team))
                return .{ .public_only = .fx_login_team_required };
            break :blk .fx_login;
        },
    };
    return .{
        .authenticated = .{
            .source = authenticated_source,
            .credential = credential,
            .team_context = team_context,
        },
    };
}

/// Current native product copy. Store mechanics and availability come from the
/// injected host port; Core retains the stable user-facing source name.
pub const stored_key_backend_label = if (builtin.os.tag == .macos) "macOS Keychain" else "profile file";

/// Both modes resolve the same source set; the mode selects only whether an expired
/// fx login session is refreshed first.
pub const LoadMode = enum { stored, refresh_if_needed };

const FxLoginRefreshMode = enum { if_needed, force };

pub const missing_credential_message = "Fx needs access to Vercel AI Gateway. Run fx login to sign in, fx setup to use an API key, or set AI_GATEWAY_API_KEY.";
pub const missing_interactive_credential_message = "Fx needs access to Vercel AI Gateway. Run /login to sign in, /setup to use an API key, or set AI_GATEWAY_API_KEY.";
pub const unreadable_store_message = "Fx could not read the stored API key from " ++ stored_key_backend_label ++ ". A key may be saved but unreadable. Set FX_TRACE_LOG for the failing step, or set AI_GATEWAY_API_KEY.";

pub const Credential = struct {
    token: []u8,
    source: Source,
    team_id: ?[]u8 = null,
    team_slug: ?[]u8 = null,
    refresh_after_ms: ?i64 = null,

    pub fn deinit(self: *Credential, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        if (self.team_id) |team| alloc.free(team);
        if (self.team_slug) |team| alloc.free(team);
        self.* = undefined;
    }

    pub fn gatewayTeam(self: Credential) ?[]const u8 {
        if (self.team_id) |team| return team;
        return self.team_slug;
    }

    pub fn needsRefreshAt(self: Credential, now_ms: i64) bool {
        const refresh_after_ms = self.refresh_after_ms orelse return false;
        return refresh_after_ms <= now_ms;
    }
};

pub const StoredKeyReadStatus = enum {
    not_attempted,
    not_found,
    unavailable,
};

pub const Resolution = struct {
    credential: ?Credential = null,
    stored_key_status: StoredKeyReadStatus = .not_attempted,
};

/// The single credential resolution method. Walks source precedence, then falls back to
/// the stored key, reporting why that store was silent when it produced nothing.
pub fn resolve(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
) !Resolution {
    return resolvePreferring(alloc, transport, secret_store, mode, null);
}

/// Resolves credentials for the route encoded by `model`. Existing model IDs
/// remain Vercel AI Gateway routes; direct routes use provider-owned sources.
pub fn resolveForModel(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    model: []const u8,
    preferred: ?Source,
) !Resolution {
    const route = inference_provider.routeForModel(model);
    return switch (route.provider) {
        .vercel_ai_gateway => resolvePreferring(
            alloc,
            transport,
            secret_store,
            mode,
            if (preferred) |source| if (sourceSupportsProvider(source, route.provider)) source else null else null,
        ),
        .anthropic_max => .{ .credential = try loadAnthropicCredential(alloc, transport, mode) },
        .openai_codex => .{ .credential = try loadCodexCredential(alloc, transport, mode) },
        .xai_direct => .{ .credential = try loadXaiCredential(alloc, transport, mode) },
    };
}

pub fn sourceSupportsModel(source: Source, model: []const u8) bool {
    return sourceSupportsProvider(source, inference_provider.routeForModel(model).provider);
}

fn sourceSupportsProvider(source: Source, provider: inference_provider.ProviderId) bool {
    return switch (provider) {
        .vercel_ai_gateway => switch (source) {
            .vercel_oidc_token, .ai_gateway_api_key, .fx_login, .stored_key => true,
            else => false,
        },
        .anthropic_max => source == .anthropic_fx_login or source == .anthropic_oauth_token or source == .anthropic_api_key,
        .openai_codex => source == .codex_fx_login or source == .codex_login,
        .xai_direct => source == .xai_oauth_token or source == .xai_api_key,
    };
}

/// `preferred` is the source the user last chose in the hub. It wins over the
/// precedence order below, including over the environment, because it is an
/// explicit choice rather than a default. A preferred source that no longer
/// resolves falls through to precedence instead of failing.
pub fn resolvePreferring(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    preferred: ?Source,
) !Resolution {
    if (preferred) |source| {
        if (source != .stored_key or !secret_store.isDisabled()) {
            const chosen = loadPreferredSource(alloc, transport, secret_store, mode, source) catch |err| blk: {
                if (err == error.OutOfMemory) return err;
                debug_trace.logf("auth", "preferred source load failed source={t} err={s}", .{ source, @errorName(err) });
                break :blk null;
            };
            if (chosen) |credential| return .{ .credential = credential };
            debug_trace.logf("auth", "preferred source unavailable source={t}; using precedence", .{source});
        }
    }

    if (try loadSource(alloc, transport, secret_store, .vercel_oidc_token)) |credential| return .{ .credential = credential };
    if (try loadSource(alloc, transport, secret_store, .ai_gateway_api_key)) |credential| return .{ .credential = credential };

    const fx_login = switch (mode) {
        .stored => try loadStoredFxLoginCredential(alloc),
        .refresh_if_needed => try loadFxLoginCredential(alloc, transport),
    };
    if (fx_login) |credential| return .{ .credential = credential };

    if (secret_store.isDisabled()) return .{};

    var status: StoredKeyReadStatus = .not_found;
    const stored = loadSource(alloc, transport, secret_store, .stored_key) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        status = .unavailable;
        debug_trace.logf("auth", "stored key load failed err={s} status={t}", .{ @errorName(err), status });
        break :blk null;
    };
    if (stored) |credential| return .{ .credential = credential };
    return .{ .stored_key_status = status };
}

/// `loadSource` always refreshes an expired fx login, which `.stored` mode
/// forbids: a diagnostic must not rewrite the session file or make an OAuth
/// request. Honour the mode for the preferred source too.
fn loadPreferredSource(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    source: Source,
) !?Credential {
    if (source != .fx_login) return loadSource(alloc, transport, secret_store, source);
    return switch (mode) {
        .stored => loadStoredFxLoginCredential(alloc),
        .refresh_if_needed => loadFxLoginCredential(alloc, transport),
    };
}

pub fn loadSource(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    source: Source,
) !?Credential {
    return switch (source) {
        .vercel_oidc_token => loadEnvCredential(alloc, "VERCEL_OIDC_TOKEN", source),
        .ai_gateway_api_key => loadEnvCredential(alloc, "AI_GATEWAY_API_KEY", source),
        .fx_login => loadFxLoginCredential(alloc, transport),
        .stored_key => loadStoredKeyCredential(alloc, secret_store),
        .anthropic_fx_login => loadManagedProviderCredential(alloc, transport, .anthropic, .refresh_if_needed),
        .anthropic_oauth_token => loadAnthropicOAuthCredential(alloc),
        .anthropic_api_key => loadEnvCredential(alloc, "ANTHROPIC_API_KEY", source),
        .codex_fx_login => loadManagedProviderCredential(alloc, transport, .openai_codex, .refresh_if_needed),
        .codex_login => loadCodexCredential(alloc, transport, .refresh_if_needed),
        .xai_oauth_token => loadManagedProviderCredential(alloc, transport, .xai, .refresh_if_needed),
        .xai_api_key => loadEnvCredential(alloc, "XAI_API_KEY", source),
    };
}

pub fn sourceExists(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
    source: Source,
) !bool {
    return switch (source) {
        .vercel_oidc_token => nonEmptyEnvValue("VERCEL_OIDC_TOKEN") != null,
        .ai_gateway_api_key => nonEmptyEnvValue("AI_GATEWAY_API_KEY") != null,
        .fx_login => blk: {
            const loaded = oauth_session.load(alloc) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    debug_trace.logf("auth", "source probe failed source=fx_login err={s}", .{@errorName(err)});
                    break :blk false;
                },
            };
            var session = loaded orelse break :blk false;
            defer session.deinit(alloc);
            break :blk true;
        },
        .stored_key => blk: {
            if (secret_store.isDisabled()) break :blk false;
            const stored = secret_store.load(alloc) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    debug_trace.logf("auth", "source probe failed source=stored_key err={s}", .{@errorName(err)});
                    break :blk false;
                },
            };
            const value = stored orelse break :blk false;
            secret.zeroAndFree(alloc, value);
            break :blk true;
        },
        .anthropic_fx_login => managedProviderExists(alloc, .anthropic),
        .anthropic_oauth_token => probeCredential(alloc, try loadAnthropicOAuthCredential(alloc)),
        .anthropic_api_key => nonEmptyEnvValue("ANTHROPIC_API_KEY") != null,
        .codex_fx_login => managedProviderExists(alloc, .openai_codex),
        .codex_login => blk: {
            if (nonEmptyEnvValue("CODEX_ACCESS_TOKEN") != null) break :blk true;
            break :blk try managedOrExternalSourceExists(alloc, .openai_codex, ".codex/auth.json", &.{ "tokens", "access_token" });
        },
        .xai_oauth_token => managedProviderExists(alloc, .xai),
        .xai_api_key => nonEmptyEnvValue("XAI_API_KEY") != null,
    };
}

fn probeCredential(alloc: std.mem.Allocator, loaded: ?Credential) bool {
    var credential = loaded orelse return false;
    credential.deinit(alloc);
    return true;
}

fn loadAnthropicCredential(alloc: std.mem.Allocator, transport: oauth_transport.Provider, mode: LoadMode) !?Credential {
    if (try loadManagedProviderCredential(alloc, transport, .anthropic, mode)) |credential| return credential;
    if (try loadAnthropicOAuthCredential(alloc)) |credential| return credential;
    return loadEnvCredential(alloc, "ANTHROPIC_API_KEY", .anthropic_api_key);
}

fn loadAnthropicOAuthCredential(alloc: std.mem.Allocator) !?Credential {
    inline for (&.{ "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN" }) |name| {
        if (try loadEnvCredential(alloc, name, .anthropic_oauth_token)) |credential| {
            if (std.mem.startsWith(u8, credential.token, "sk-ant-oat")) return credential;
            var rejected = credential;
            rejected.deinit(alloc);
        }
    }
    if (try loadJsonCredential(alloc, ".claude/.credentials.json", &.{ "claudeAiOauth", "accessToken" }, .anthropic_oauth_token)) |credential| {
        if (std.mem.startsWith(u8, credential.token, "sk-ant-oat")) return credential;
        var rejected = credential;
        rejected.deinit(alloc);
    }
    return null;
}

fn loadCodexCredential(alloc: std.mem.Allocator, transport: oauth_transport.Provider, mode: LoadMode) !?Credential {
    if (try loadManagedProviderCredential(alloc, transport, .openai_codex, mode)) |credential| return credential;
    if (try loadEnvCredential(alloc, "CODEX_ACCESS_TOKEN", .codex_login)) |credential| return credential;
    return loadJsonCredential(alloc, ".codex/auth.json", &.{ "tokens", "access_token" }, .codex_login);
}

fn loadXaiCredential(alloc: std.mem.Allocator, transport: oauth_transport.Provider, mode: LoadMode) !?Credential {
    if (try loadManagedProviderCredential(alloc, transport, .xai, mode)) |credential| return credential;
    return loadEnvCredential(alloc, "XAI_API_KEY", .xai_api_key);
}

fn loadManagedProviderCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    provider: provider_oauth.Provider,
    mode: LoadMode,
) !?Credential {
    var session = (try provider_oauth.loadManagedSession(alloc, transport, provider, mode == .refresh_if_needed)) orelse return null;
    defer session.deinit(alloc);
    const token = session.access_token;
    session.access_token = &.{};
    return .{
        .token = token,
        .source = provider.credentialSource(),
        .refresh_after_ms = oauth_session.refresh_deadline_ms(session.expires_at_ms),
    };
}

fn managedProviderExists(alloc: std.mem.Allocator, provider: provider_oauth.Provider) !bool {
    var session = (try oauth_session.loadNamed(alloc, provider.fileName(), @tagName(provider))) orelse return false;
    session.deinit(alloc);
    return true;
}

fn managedOrExternalSourceExists(
    alloc: std.mem.Allocator,
    provider: provider_oauth.Provider,
    relative_path: []const u8,
    keys: []const []const u8,
) !bool {
    if (try managedProviderExists(alloc, provider)) return true;
    return probeCredential(alloc, try loadJsonCredential(alloc, relative_path, keys, provider.credentialSource()));
}

fn loadJsonCredential(
    alloc: std.mem.Allocator,
    relative_path: []const u8,
    keys: []const []const u8,
    source: Source,
) !?Credential {
    const home = io_mod.getenv("HOME") orelse return null;
    const path = try std.fs.path.join(alloc, &.{ home, relative_path });
    defer alloc.free(path);
    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), path, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.size > 1024 * 1024) return null;
    const bytes = try io_mod.readFileToEnd(alloc, &file, 1024 * 1024 + 1);
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    var value = parsed.value;
    for (keys) |key| {
        if (value != .object) return null;
        value = value.object.get(key) orelse return null;
    }
    if (value != .string) return null;
    const token = nonEmptyValue(value.string) orelse return null;
    return .{ .token = try alloc.dupe(u8, token), .source = source };
}

fn loadEnvCredential(
    alloc: std.mem.Allocator,
    name: []const u8,
    source: Source,
) !?Credential {
    const value = nonEmptyEnvValue(name) orelse return null;
    return .{
        .token = try alloc.dupe(u8, value),
        .source = source,
    };
}

fn loadStoredKeyCredential(
    alloc: std.mem.Allocator,
    secret_store: host.SecretStore,
) !?Credential {
    if (secret_store.isDisabled()) return null;
    const value = (try secret_store.load(alloc)) orelse return null;
    return .{ .token = value, .source = .stored_key };
}

fn nonEmptyEnvValue(name: []const u8) ?[]const u8 {
    return nonEmptyValue(io_mod.getenv(name));
}

fn nonEmptyValue(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

pub fn loadFxLoginCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    var session = (try oauth_session.load(alloc)) orelse return null;
    defer session.deinit(alloc);

    if (session.expired(io_mod.milliTimestamp())) {
        return refreshFxLoginCredentialLocked(alloc, transport, .if_needed);
    }

    return takeCredentialFromSession(&session, null);
}

fn loadStoredFxLoginCredential(alloc: std.mem.Allocator) !?Credential {
    var session = (try oauth_session.load(alloc)) orelse return null;
    defer session.deinit(alloc);
    return takeCredentialFromSession(&session, null);
}

pub fn refreshFxLoginCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    return refreshFxLoginCredentialLocked(alloc, transport, .force);
}

fn refreshFxLoginCredentialLocked(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: FxLoginRefreshMode,
) !?Credential {
    var mutation = (try oauth_session.beginExistingMutation()) orelse return null;
    defer mutation.deinit();

    var session = (try mutation.load(alloc)) orelse return null;
    defer session.deinit(alloc);

    var refreshed_at_ms: ?i64 = null;
    if (mode == .force or session.expired(io_mod.milliTimestamp())) {
        try refreshFxSession(alloc, transport, &mutation, &session);
        refreshed_at_ms = io_mod.milliTimestamp();
    }
    return takeCredentialFromSession(&session, refreshed_at_ms);
}

pub fn refreshFxSession(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mutation: *oauth_session.Mutation,
    session: *oauth_session.Session,
) !void {
    const issuer_url = session.issuer;
    var metadata = try oauth.discover(alloc, transport, issuer_url);
    defer metadata.deinit(alloc);
    try oauth_session.validateE2EEndpoint(issuer_url, metadata.token_endpoint);

    var refreshed = try oauth.refreshToken(
        alloc,
        transport,
        metadata,
        session.client_id,
        session.refresh_token,
    );
    defer refreshed.deinit(alloc);

    secret.zeroAndFree(alloc, session.access_token);
    session.access_token = refreshed.access_token;
    refreshed.access_token = &.{};

    if (refreshed.refresh_token) |value| {
        secret.zeroAndFree(alloc, session.refresh_token);
        session.refresh_token = value;
        refreshed.refresh_token = null;
    }

    alloc.free(session.scope);
    session.scope = refreshed.scope;
    refreshed.scope = &.{};

    alloc.free(session.token_type);
    session.token_type = refreshed.token_type;
    refreshed.token_type = &.{};

    session.expires_at_ms = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), refreshed.expires_in);
    try mutation.save(alloc, session.*);
}

fn takeCredentialFromSession(session: *oauth_session.Session, refreshed_at_ms: ?i64) Credential {
    const token = session.access_token;
    session.access_token = &.{};
    const team_id = session.team_id;
    session.team_id = null;
    const team_slug = session.team_slug;
    session.team_slug = null;
    return .{
        .token = token,
        .source = .fx_login,
        .team_id = team_id,
        .team_slug = team_slug,
        .refresh_after_ms = credentialRefreshAfterMs(session.expires_at_ms, refreshed_at_ms),
    };
}

fn credentialRefreshAfterMs(expires_at_ms: i64, refreshed_at_ms: ?i64) i64 {
    const refresh_after_ms = oauth_session.refresh_deadline_ms(expires_at_ms);
    const refreshed_at = refreshed_at_ms orelse return refresh_after_ms;
    if (refresh_after_ms > refreshed_at) return refresh_after_ms;
    return expires_at_ms;
}

pub fn sourceLabel(source: Source) []const u8 {
    return switch (source) {
        .vercel_oidc_token => "VERCEL_OIDC_TOKEN",
        .ai_gateway_api_key => "AI_GATEWAY_API_KEY",
        .fx_login => "fx login",
        .stored_key => "stored API key (" ++ stored_key_backend_label ++ ")",
        .anthropic_fx_login => "fx Anthropic login",
        .anthropic_oauth_token => "Anthropic Max login",
        .anthropic_api_key => "ANTHROPIC_API_KEY",
        .codex_fx_login => "fx Codex login",
        .codex_login => "ChatGPT/Codex login",
        .xai_oauth_token => "xAI Grok/X login",
        .xai_api_key => "XAI_API_KEY",
    };
}

pub fn sourceRefreshable(source: Source) bool {
    return source == .fx_login or provider_oauth.Provider.fromCredentialSource(source) != null;
}

test "stored key label discloses the backend that answered" {
    try std.testing.expect(std.mem.find(u8, sourceLabel(.stored_key), stored_key_backend_label) != null);
    try std.testing.expect(std.mem.find(u8, unreadable_store_message, stored_key_backend_label) != null);
    for ([_]Source{ .vercel_oidc_token, .ai_gateway_api_key, .fx_login }) |source| {
        try std.testing.expect(!std.mem.eql(u8, sourceLabel(source), sourceLabel(.stored_key)));
    }
}

test "missing credential messages use surface commands in preferred order" {
    const cli_login = std.mem.find(u8, missing_credential_message, "fx login").?;
    const cli_setup = std.mem.find(u8, missing_credential_message, "fx setup").?;
    const cli_env = std.mem.find(u8, missing_credential_message, "AI_GATEWAY_API_KEY").?;

    try std.testing.expect(cli_login < cli_setup);
    try std.testing.expect(cli_setup < cli_env);

    const tui_login = std.mem.find(u8, missing_interactive_credential_message, "/login").?;
    const tui_setup = std.mem.find(u8, missing_interactive_credential_message, "/setup").?;
    const tui_env = std.mem.find(u8, missing_interactive_credential_message, "AI_GATEWAY_API_KEY").?;

    try std.testing.expect(tui_login < tui_setup);
    try std.testing.expect(tui_setup < tui_env);
}

test "credential gateway team prefers team id" {
    var credential = Credential{
        .token = try std.testing.allocator.dupe(u8, "token"),
        .source = .fx_login,
        .team_id = try std.testing.allocator.dupe(u8, "team_123"),
        .team_slug = try std.testing.allocator.dupe(u8, "vercel-labs"),
    };
    defer credential.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("team_123", credential.gatewayTeam().?);
}

test "public-only catalog access never permits authorization or team context" {
    const missing = catalogAccessAt(null, 0);
    try std.testing.expectEqual(CatalogPublicOnlyReason.no_credential, missing.publicOnlyReason().?);
    try std.testing.expect(missing.credentialSource() == null);
    try std.testing.expect(missing.authorizationCredential() == null);
    try std.testing.expect(missing.teamContext() == null);

    const refresh_failed = catalogAccessAfterRefreshFailure(.fx_login);
    try std.testing.expectEqual(CatalogPublicOnlyReason.credential_refresh_failed, refresh_failed.publicOnlyReason().?);
    try std.testing.expectEqual(Source.fx_login, refresh_failed.credentialSource().?);

    const rejected: CatalogAccess = .{ .public_only = .{ .authenticated_credential_rejected = .stored_key } };
    try std.testing.expectEqual(CatalogPublicOnlyReason.authenticated_credential_rejected, rejected.publicOnlyReason().?);
    try std.testing.expectEqual(Source.stored_key, rejected.credentialSource().?);
    try std.testing.expect(rejected.authorizationCredential() == null);
    try std.testing.expect(rejected.teamContext() == null);
}

test "selected fx login authorizes its team model catalog" {
    var login = Credential{
        .token = try std.testing.allocator.dupe(u8, "login-token"),
        .source = .fx_login,
        .team_id = try std.testing.allocator.dupe(u8, "team_123"),
    };
    defer login.deinit(std.testing.allocator);

    const access = catalogAccessAt(login, 0);
    try std.testing.expectEqual(Source.fx_login, access.credentialSource().?);
    try std.testing.expect(access.authorizationCredential() != null);
    try std.testing.expectEqualStrings("login-token", access.authorizationCredential().?);
    try std.testing.expectEqualStrings("team_123", access.teamContext().?);
}

test "fx login catalog access requires a fresh credential and selected team" {
    var login = Credential{
        .token = try std.testing.allocator.dupe(u8, "login-token"),
        .source = .fx_login,
        .refresh_after_ms = 10,
    };
    defer login.deinit(std.testing.allocator);

    const expired = catalogAccessAt(login, 10);
    try std.testing.expectEqual(CatalogPublicOnlyReason.fx_login_refresh_required, expired.publicOnlyReason().?);
    try std.testing.expect(expired.authorizationCredential() == null);
    try std.testing.expect(expired.teamContext() == null);

    login.refresh_after_ms = null;
    const missing_team = catalogAccessAt(login, 10);
    try std.testing.expectEqual(CatalogPublicOnlyReason.fx_login_team_required, missing_team.publicOnlyReason().?);
    try std.testing.expect(missing_team.authorizationCredential() == null);
    try std.testing.expect(missing_team.teamContext() == null);
}

test "authenticated catalog access carries source and permitted request context" {
    for ([_]Source{ .vercel_oidc_token, .ai_gateway_api_key, .stored_key }) |source| {
        var credential = Credential{
            .token = try std.testing.allocator.dupe(u8, "token"),
            .source = source,
            .team_slug = try std.testing.allocator.dupe(u8, "vercel-labs"),
        };
        defer credential.deinit(std.testing.allocator);

        const authenticated = catalogAccessAt(credential, 0);
        try std.testing.expect(authenticated.publicOnlyReason() == null);
        try std.testing.expectEqual(source, authenticated.credentialSource().?);
        try std.testing.expectEqualStrings("token", authenticated.authorizationCredential().?);
        try std.testing.expectEqualStrings("vercel-labs", authenticated.teamContext().?);

        const fallback = authenticated.publicFallbackAfterRejection().?;
        try std.testing.expectEqual(CatalogPublicOnlyReason.authenticated_credential_rejected, fallback.publicOnlyReason().?);
        try std.testing.expectEqual(source, fallback.credentialSource().?);
        try std.testing.expect(fallback.authorizationCredential() == null);
        try std.testing.expect(fallback.teamContext() == null);
        try std.testing.expect(fallback.publicFallbackAfterRejection() == null);
    }
}

test "fresh short-lived credential remains ready for its admitted action" {
    try std.testing.expectEqual(@as(i64, 70_000), credentialRefreshAfterMs(130_000, null));
    try std.testing.expectEqual(@as(i64, 130_000), credentialRefreshAfterMs(130_000, 100_000));
    try std.testing.expectEqual(@as(i64, 140_000), credentialRefreshAfterMs(200_000, 100_000));
}

var stable_credential_test_environ: ?*std.process.Environ.Map = null;

fn stableCredentialTestEnviron() !*const std.process.Environ.Map {
    if (stable_credential_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_credential_test_environ = map;
    return map;
}

const CredentialTestEnv = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    /// Installs exactly `entries`, so anything the resolver reads from the real
    /// environment, `HOME` included, is absent for the duration of the test.
    fn install(alloc: std.mem.Allocator, entries: []const [2][]const u8) !*CredentialTestEnv {
        _ = try stableCredentialTestEnviron();

        const self = try alloc.create(CredentialTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        for (entries) |entry| try self.map.put(entry[0], entry[1]);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *CredentialTestEnv) void {
        if (stable_credential_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const SecretStoreFixture = struct {
    value: ?[]const u8 = null,
    disabled: bool = false,
    unreadable: bool = false,
    load_calls: usize = 0,

    fn provider(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = isDisabled,
            .load_fn = load,
            .store_fn = store,
            .store_interactive_fn = storeInteractive,
        };
    }

    fn isDisabled(raw_context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        return self.disabled;
    }

    fn load(
        raw_context: ?*anyopaque,
        alloc: std.mem.Allocator,
    ) host.SecretStoreLoadError!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        self.load_calls += 1;
        if (self.unreadable) return error.StoredKeyUnreadable;
        const value = self.value orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn store(
        _: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
    ) host.SecretStoreWriteError!void {
        return error.StoredKeyWriteFailed;
    }

    fn storeInteractive(
        _: ?*anyopaque,
    ) host.SecretStoreWriteError!bool {
        return false;
    }
};

test "source-specific credential loading bypasses generic precedence" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "VERCEL_OIDC_TOKEN", "oidc-token" },
        .{ "AI_GATEWAY_API_KEY", "api-key" },
    });
    defer env.deinit();

    const resolution = try resolve(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .refresh_if_needed);
    var startup = resolution.credential orelse return error.TestExpectedCredential;
    defer startup.deinit(alloc);
    try std.testing.expectEqualStrings("oidc-token", startup.token);
    try std.testing.expectEqual(Source.vercel_oidc_token, startup.source);

    var api_key = (try loadSource(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .ai_gateway_api_key)).?;
    defer api_key.deinit(alloc);
    try std.testing.expectEqualStrings("api-key", api_key.token);
    try std.testing.expectEqual(Source.ai_gateway_api_key, api_key.source);

    var oidc = (try loadSource(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .vercel_oidc_token)).?;
    defer oidc.deinit(alloc);
    try std.testing.expectEqualStrings("oidc-token", oidc.token);
    try std.testing.expectEqual(Source.vercel_oidc_token, oidc.source);

    try std.testing.expect(try sourceExists(alloc, host.unavailable_secret_store, .ai_gateway_api_key));
    try std.testing.expect(try sourceExists(alloc, host.unavailable_secret_store, .vercel_oidc_token));
    try std.testing.expect(!(try sourceExists(alloc, host.unavailable_secret_store, .stored_key)));
}

test "provider-qualified models resolve only their provider credential" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "AI_GATEWAY_API_KEY", "gateway-key" },
        .{ "ANTHROPIC_OAUTH_TOKEN", "sk-ant-oat-test" },
        .{ "CODEX_ACCESS_TOKEN", "codex-token" },
        .{ "XAI_API_KEY", "xai-key" },
    });
    defer env.deinit();

    const cases = [_]struct {
        model: []const u8,
        source: Source,
        token: []const u8,
    }{
        .{ .model = "anthropic-max/claude-opus", .source = .anthropic_oauth_token, .token = "sk-ant-oat-test" },
        .{ .model = "openai-codex/gpt-5", .source = .codex_login, .token = "codex-token" },
        .{ .model = "xai-direct/grok-4", .source = .xai_api_key, .token = "xai-key" },
        .{ .model = "anthropic/claude-opus", .source = .ai_gateway_api_key, .token = "gateway-key" },
    };
    for (cases) |case| {
        var resolution = try resolveForModel(
            alloc,
            oauth_transport.unavailable_provider,
            host.unavailable_secret_store,
            .stored,
            case.model,
            null,
        );
        defer if (resolution.credential) |*credential| credential.deinit(alloc);
        try std.testing.expectEqual(case.source, resolution.credential.?.source);
        try std.testing.expectEqualStrings(case.token, resolution.credential.?.token);
    }
}

test "direct provider credentials never authorize the Gateway catalog" {
    const direct_sources = [_]Source{
        .anthropic_fx_login,
        .anthropic_oauth_token,
        .anthropic_api_key,
        .codex_fx_login,
        .codex_login,
        .xai_oauth_token,
        .xai_api_key,
    };
    for (direct_sources) |source| {
        const access = catalogAccessForCredential(source, "provider-secret", null);
        try std.testing.expect(access.authorizationCredential() == null);
        try std.testing.expect(access.teamContext() == null);
    }
}

test "credential sources are scoped to their model route" {
    try std.testing.expect(sourceSupportsModel(.fx_login, "anthropic/claude-opus"));
    try std.testing.expect(!sourceSupportsModel(.anthropic_oauth_token, "anthropic/claude-opus"));
    try std.testing.expect(sourceSupportsModel(.anthropic_fx_login, "anthropic-max/claude-opus"));
    try std.testing.expect(sourceSupportsModel(.anthropic_oauth_token, "anthropic-max/claude-opus"));
    try std.testing.expect(!sourceSupportsModel(.ai_gateway_api_key, "anthropic-max/claude-opus"));
    try std.testing.expect(sourceSupportsModel(.codex_fx_login, "openai-codex/gpt-5"));
    try std.testing.expect(sourceSupportsModel(.codex_login, "openai-codex/gpt-5"));
    try std.testing.expect(sourceSupportsModel(.xai_oauth_token, "xai-direct/grok-4"));
    try std.testing.expect(sourceSupportsModel(.xai_api_key, "xai-direct/grok-4"));
}

test "a remembered choice outranks the environment" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "VERCEL_OIDC_TOKEN", "oidc-token" },
        .{ "AI_GATEWAY_API_KEY", "api-key" },
    });
    defer env.deinit();

    const resolution = try resolvePreferring(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .refresh_if_needed, .ai_gateway_api_key);
    var credential = resolution.credential orelse return error.TestExpectedCredential;
    defer credential.deinit(alloc);
    try std.testing.expectEqual(Source.ai_gateway_api_key, credential.source);
    try std.testing.expectEqualStrings("api-key", credential.token);
}

test "a remembered fx login never refreshes in stored mode" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{});
    defer env.deinit();

    // No session exists, so both modes resolve to nothing. What matters is the
    // route taken: `.stored` must reach loadStoredFxLoginCredential, which never
    // performs the network refresh that a diagnostic is forbidden from making.
    for ([_]LoadMode{ .stored, .refresh_if_needed }) |mode| {
        var resolution = try resolvePreferring(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, mode, .fx_login);
        defer if (resolution.credential) |*credential| credential.deinit(alloc);
        try std.testing.expect(resolution.credential == null);
    }

    try std.testing.expect((try loadPreferredSource(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .stored, .vercel_oidc_token)) == null);
}

test "a remembered choice that no longer resolves falls back to precedence" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "AI_GATEWAY_API_KEY", "api-key" },
    });
    defer env.deinit();

    // fx_login is remembered but no session exists, so precedence must still answer.
    const resolution = try resolvePreferring(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .refresh_if_needed, .fx_login);
    var credential = resolution.credential orelse return error.TestExpectedCredential;
    defer credential.deinit(alloc);
    try std.testing.expectEqual(Source.ai_gateway_api_key, credential.source);
}

test "no remembered choice resolves exactly as plain precedence" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "VERCEL_OIDC_TOKEN", "oidc-token" },
        .{ "AI_GATEWAY_API_KEY", "api-key" },
    });
    defer env.deinit();

    var preferred = try resolvePreferring(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .refresh_if_needed, null);
    defer if (preferred.credential) |*credential| credential.deinit(alloc);
    var plain = try resolve(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .refresh_if_needed);
    defer if (plain.credential) |*credential| credential.deinit(alloc);

    try std.testing.expectEqual(plain.credential.?.source, preferred.credential.?.source);
    try std.testing.expectEqualStrings(plain.credential.?.token, preferred.credential.?.token);
}

test "a disabled stored key is reported as never attempted, not as absent" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{});
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .disabled = true };

    for ([_]LoadMode{ .stored, .refresh_if_needed }) |mode| {
        var resolution = try resolve(alloc, oauth_transport.unavailable_provider, store_fixture.provider(), mode);
        defer if (resolution.credential) |*credential| credential.deinit(alloc);
        try std.testing.expect(resolution.credential == null);
        try std.testing.expectEqual(StoredKeyReadStatus.not_attempted, resolution.stored_key_status);
    }
    try std.testing.expectEqual(@as(usize, 0), store_fixture.load_calls);
}

test "credential resolution loads a stored key only through the injected host port" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{});
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .value = "injected-test-value" };

    var resolution = try resolve(
        alloc,
        oauth_transport.unavailable_provider,
        store_fixture.provider(),
        .stored,
    );
    defer if (resolution.credential) |*credential| credential.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), store_fixture.load_calls);
    try std.testing.expectEqual(StoredKeyReadStatus.not_attempted, resolution.stored_key_status);
    try std.testing.expectEqual(Source.stored_key, resolution.credential.?.source);
    try std.testing.expectEqualStrings("injected-test-value", resolution.credential.?.token);
}

test "credential resolution preserves unreadable store classification" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{});
    defer env.deinit();
    var store_fixture = SecretStoreFixture{ .unreadable = true };

    const resolution = try resolve(
        alloc,
        oauth_transport.unavailable_provider,
        store_fixture.provider(),
        .stored,
    );

    try std.testing.expectEqual(@as(usize, 1), store_fixture.load_calls);
    try std.testing.expect(resolution.credential == null);
    try std.testing.expectEqual(StoredKeyReadStatus.unavailable, resolution.stored_key_status);
}
