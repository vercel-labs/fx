const server_connection = @import("server_connection.zig");
const legacy_url_completion = @import("legacy_url_completion.zig");
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp_contract = @import("mcp_contract.zig");
const mcp_auth = @import("mcp_auth.zig");
const mcp_auth_store = @import("mcp_auth_store.zig");
const streamable_http = @import("streamable_http.zig");
const legacy_http_sse = @import("legacy_http_sse.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const operation_authority = @import("operation_authority.zig");
const operation_control = @import("operation_control.zig");
const connection_control = @import("connection_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const Allocator = std.mem.Allocator;
const McpServer = @import("server_connection.zig").Server;
const ConnectionControl = connection_control.Control;
const lockMutexWithControl = controlled_lock.mutexWithControl;
const lockMutexUntil = controlled_lock.mutexUntil;
const checkOperationControl = controlled_lock.checkOperation;
const allocateGeneration = @import("server_lifetime.zig").allocateIdentity;

pub fn loadStoredCredentials(
    alloc: Allocator,
    server: *McpServer,
    control: ConnectionControl,
) !void {
    try connection_control.check(io_mod.getIo(), control);
    if (server.config.transport == .stdio or
        !server.config.allow_stored_credentials or
        server.auth_credentials != null)
    {
        return;
    }
    const auth = server.config.auth orelse mcp_contract.McpAuthConfig{};
    var credentials = if (control.cancel_flag) |cancel_flag|
        try mcp_auth_store.loadCancellable(
            alloc,
            server.config.name,
            try server.config.remoteUrl(),
            auth.resource,
            auth.issuer,
            cancel_flag,
        )
    else
        try mcp_auth_store.load(
            alloc,
            server.config.name,
            try server.config.remoteUrl(),
            auth.resource,
            auth.issuer,
        );
    errdefer if (credentials) |*owned| owned.deinit(alloc);
    try connection_control.check(io_mod.getIo(), control);
    server.auth_credentials = credentials;
    credentials = null;
    server.auth_credentials_present.store(
        server.auth_credentials != null,
        .release,
    );
}

pub fn buildResolvedHeaders(alloc: Allocator, server: *McpServer) !ResolvedHeaderSet {
    if (server.auth_logout_in_progress.load(.acquire)) {
        return error.McpAuthorityChanged;
    }
    var headers: std.ArrayList(mcp_contract.McpHttpHeader) = .empty;
    defer headers.deinit(alloc);

    for (server.config.headers) |header| {
        try headers.append(alloc, .{
            .name = header.name,
            .value = header.value,
        });
    }
    for (server.config.header_env) |ref| {
        const value = io_mod.getenv(ref.env) orelse
            return error.McpHeaderEnvironmentMissing;
        try headers.append(alloc, .{
            .name = ref.name,
            .value = @constCast(value),
        });
    }

    const bearer = if (server.auth_credentials) |credentials|
        credentials.access_token
    else if (server.config.bearer_token_env) |env_name|
        io_mod.getenv(env_name) orelse return error.McpBearerEnvironmentMissing
    else
        null;
    const authorization = if (bearer) |token|
        try mcp_auth.bearerHeaderAlloc(alloc, token)
    else
        null;
    errdefer if (authorization) |value| {
        @memset(value, 0);
        alloc.free(value);
    };
    if (authorization) |value| {
        try headers.append(alloc, .{
            .name = @constCast("Authorization"),
            .value = value,
        });
    }
    try streamable_http.validateStaticHeaders(headers.items);

    return .{
        .headers = try headers.toOwnedSlice(alloc),
        .authorization = authorization,
    };
}

pub fn refreshResolvedHeaders(alloc: Allocator, server: *McpServer) !void {
    var resolved = try buildResolvedHeaders(alloc, server);
    errdefer resolved.deinit(alloc);
    server.clearResolvedHeaders(alloc);
    server.resolved_headers = resolved.headers;
    server.resolved_authorization = resolved.authorization;
    resolved = .{};
}

pub fn currentAuthIdentity(alloc: Allocator, server: *McpServer) !catalog_freshness.Digest {
    if (server.config.transport == .stdio) return catalog_freshness.authIdentity(&.{});
    var resolved = try buildResolvedHeaders(alloc, server);
    defer resolved.deinit(alloc);
    return authIdentityForHeaders(alloc, resolved.headers);
}

pub fn authIdentityForHeaders(
    alloc: Allocator,
    resolved: []const mcp_contract.McpHttpHeader,
) !catalog_freshness.Digest {
    const headers = try alloc.alloc(catalog_freshness.Header, resolved.len);
    defer alloc.free(headers);
    for (resolved, 0..) |header, index| {
        headers[index] = .{ .name = header.name, .value = header.value };
    }
    return catalog_freshness.authIdentity(headers);
}

fn authRejectionAction(
    automated: bool,
    retry_policy: AuthRetryPolicy,
    authorization_attempts: u8,
) AuthRejectionAction {
    if (!automated) return .require_interactive;
    if (retry_policy == .never) return .authorize_without_retry;
    if (authorization_attempts >= mcp_auth.max_scope_reauthorizations) {
        return .retry_limit;
    }
    return .authorize_and_retry;
}

pub fn authenticatedPost(
    request_alloc: Allocator,
    owner_alloc: Allocator,
    server: *McpServer,
    initial_options: streamable_http.PostOptions,
    auth_access: operation_authority.EffectAccess,
    retry_policy: AuthRetryPolicy,
    producing_identity: ?*catalog_freshness.Digest,
) !streamable_http.PostResponse {
    var options = initial_options;
    var authorization_attempts: u8 = 0;
    while (true) {
        var resolved = try resolvedHeadersForPost(
            request_alloc,
            owner_alloc,
            server,
            options.control,
            auth_access,
        );
        defer resolved.deinit(request_alloc);
        options.static_headers = resolved.headers;
        const attempt_identity = if (producing_identity != null)
            try authIdentityForHeaders(request_alloc, resolved.headers)
        else
            undefined;
        var response = try streamable_http.post(request_alloc, options);
        if (response.auth_rejection == .none) {
            if (producing_identity) |identity| identity.* = attempt_identity;
            return response;
        }

        var challenge = if (response.www_authenticate) |value|
            try mcp_auth.parseChallenge(request_alloc, value)
        else
            mcp_auth.Challenge{};
        defer challenge.deinit(request_alloc);
        if (!auth_access.permitsSharedEffects()) {
            response.deinit(request_alloc);
            try auth_access.authorize();
            return error.McpAuthenticationRequired;
        }
        try storePendingChallenge(
            owner_alloc,
            server,
            challenge,
            options.control,
        );
        response.deinit(request_alloc);
        switch (authRejectionAction(
            automatedAuthorizationEnabled(try server.config.remoteUrl()),
            retry_policy,
            authorization_attempts,
        )) {
            .require_interactive => {
                markAuthenticationRequired(owner_alloc, server);
                return error.McpAuthenticationRequired;
            },
            .retry_limit => return error.McpAuthenticationRetryLimit,
            .authorize_without_retry => {
                try authorizeForChallenge(
                    owner_alloc,
                    server,
                    challenge,
                    options.control,
                );
                return error.McpAuthenticationUpdated;
            },
            .authorize_and_retry => {
                authorization_attempts += 1;
                try authorizeForChallenge(
                    owner_alloc,
                    server,
                    challenge,
                    options.control,
                );
            },
        }
    }
}

fn resolvedHeadersForPost(
    request_alloc: Allocator,
    owner_alloc: Allocator,
    server: *McpServer,
    control: streamable_http.Control,
    auth_access: operation_authority.EffectAccess,
) !ResolvedHeaderSet {
    if (auth_access.permitsSharedEffects()) {
        _ = try refreshSharedCredentials(owner_alloc, server, control);
    } else {
        try auth_access.authorize();
    }

    try lockMutexWithControl(&server.auth_lock, control);
    var auth_locked = true;
    defer if (auth_locked) server.auth_lock.unlock(io_mod.getIo());
    if (!auth_access.permitsSharedEffects()) {
        if (server.auth_credentials) |credentials| {
            if (credentials.needsRefresh(io_mod.milliTimestamp())) {
                server.auth_lock.unlock(io_mod.getIo());
                auth_locked = false;
                try auth_access.authorize();
                return error.McpAuthenticationRequired;
            }
        }
    }
    return buildResolvedHeaders(request_alloc, server);
}

pub fn currentAuthIdentityForAccess(
    alloc: Allocator,
    server: *McpServer,
    control: streamable_http.Control,
    auth_access: operation_authority.EffectAccess,
) !catalog_freshness.Digest {
    var resolved = try resolvedHeadersForPost(
        alloc,
        alloc,
        server,
        control,
        auth_access,
    );
    defer resolved.deinit(alloc);
    return authIdentityForHeaders(alloc, resolved.headers);
}

pub fn refreshSharedCredentials(
    alloc: Allocator,
    server: *McpServer,
    control: streamable_http.Control,
) !bool {
    var source = source: {
        try lockMutexWithControl(&server.auth_lock, control);
        defer server.auth_lock.unlock(io_mod.getIo());
        if (server.auth_logout_in_progress.load(.acquire)) return false;
        const credentials = server.auth_credentials orelse return false;
        if (!credentials.needsRefresh(io_mod.milliTimestamp())) return false;
        break :source .{
            .generation = server.auth_generation.load(.acquire),
            .credentials = try credentials.clone(alloc),
        };
    };
    defer source.credentials.deinit(alloc);
    if (source.credentials.refresh_token == null) {
        var auth_message: [512]u8 = undefined;
        server.setFailed(alloc, authRecoveryMessage(&auth_message, "MCP credentials expired.", server.config.name));
        return error.McpAuthenticationRequired;
    }

    var refreshed = mcp_auth.refreshCredentials(alloc, source.credentials, .{
        .deadline = control.deadline,
        .cancel_flag = control.cancel_flag,
        .lifecycle_cancel_flag = control.lifecycle_cancel_flag,
    }) catch |err| {
        if (err == error.Cancelled or err == error.McpRequestTimedOut) return err;
        var auth_message: [512]u8 = undefined;
        server.setFailed(alloc, authRecoveryMessage(&auth_message, "MCP credential refresh failed.", server.config.name));
        return err;
    };
    var transferred = false;
    defer if (!transferred) refreshed.deinit(alloc);
    try checkOperationControl(io_mod.getIo(), control.deadline, control.cancel_flag);
    try lockMutexWithControl(&server.auth_lock, control);
    defer server.auth_lock.unlock(io_mod.getIo());
    if (server.auth_logout_in_progress.load(.acquire) or
        server.auth_generation.load(.acquire) != source.generation)
    {
        return false;
    }
    const save_result = try mcp_auth_store.save(
        alloc,
        server.config.name,
        refreshed,
    );
    traceCredentialStoreRepair(
        "refresh",
        server.config.name,
        save_result.repaired_entries,
    );
    installRefreshedCredentials(alloc, server, &refreshed);
    transferred = true;
    return true;
}

pub fn authRecoveryMessage(buffer: []u8, reason: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} Run /mcp auth {s} --open.", .{ reason, name }) catch reason;
}

pub fn markAuthenticationRequired(alloc: Allocator, server: *McpServer) void {
    const message = std.fmt.allocPrint(
        alloc,
        "Authentication required. Run /mcp auth {s} --open, or configure bearer_token_env.",
        .{server.config.name},
    ) catch {
        server.setFailed(alloc, "Authentication required.");
        return;
    };
    defer alloc.free(message);
    server.setFailed(alloc, message);
}

pub fn storePendingChallenge(
    alloc: Allocator,
    server: *McpServer,
    challenge: mcp_auth.Challenge,
    control: streamable_http.Control,
) !void {
    var owned = try challenge.clone(alloc);
    var transferred = false;
    errdefer if (!transferred) owned.deinit(alloc);
    try lockMutexWithControl(&server.auth_lock, control);
    defer server.auth_lock.unlock(io_mod.getIo());
    if (server.auth_logout_in_progress.load(.acquire)) return error.McpAuthorityChanged;
    advanceAuthGeneration(server);
    if (server.pending_auth_challenge) |*previous| previous.deinit(alloc);
    server.pending_auth_challenge = owned;
    server.auth_challenge_present.store(true, .release);
    transferred = true;
    owned = undefined;
}

pub fn authorizeForChallenge(
    alloc: Allocator,
    server: *McpServer,
    challenge: mcp_auth.Challenge,
    control: streamable_http.Control,
) !void {
    const auth_config = server.config.auth orelse mcp_contract.McpAuthConfig{};
    const client_secret = if (auth_config.client_secret_env) |env_name|
        io_mod.getenv(env_name) orelse return error.McpClientSecretEnvironmentMissing
    else
        null;
    const source = source: {
        try lockMutexWithControl(&server.auth_lock, control);
        defer server.auth_lock.unlock(io_mod.getIo());
        if (server.auth_logout_in_progress.load(.acquire)) return error.McpAuthorityChanged;
        break :source .{
            .generation = server.auth_generation.load(.acquire),
            .previous_scope = if (server.auth_credentials) |credentials|
                try alloc.dupe(u8, credentials.scope)
            else
                null,
        };
    };
    defer if (source.previous_scope) |value| alloc.free(value);
    var credentials = switch (try mcp_auth.authorizeAutomated(alloc, .{
        .endpoint = try server.config.remoteUrl(),
        .challenge = challenge,
        .config = .{
            .resource = auth_config.resource,
            .issuer = auth_config.issuer,
            .client_id = auth_config.client_id,
            .client_secret = client_secret,
            .client_metadata_url = auth_config.client_metadata_url,
            .scopes = auth_config.scopes,
        },
        .previous_scope = source.previous_scope,
    })) {
        .credentials => |credentials| credentials,
        .issuer_mismatch => |owned_mismatch| {
            var mismatch = owned_mismatch;
            const err = switch (mismatch.source) {
                .authorization_metadata => error.AuthorizationMetadataIssuerMismatch,
                .authorization_response => error.AuthorizationResponseIssuerMismatch,
            };
            mismatch.deinit();
            return err;
        },
    };
    var credentials_transferred = false;
    errdefer if (!credentials_transferred) credentials.deinit(alloc);
    try lockMutexWithControl(&server.auth_lock, control);
    defer server.auth_lock.unlock(io_mod.getIo());
    if (server.auth_logout_in_progress.load(.acquire) or
        server.auth_generation.load(.acquire) != source.generation)
    {
        credentials.deinit(alloc);
        return;
    }
    const save_result = try mcp_auth_store.save(
        alloc,
        server.config.name,
        credentials,
    );
    traceCredentialStoreRepair(
        "automated_auth",
        server.config.name,
        save_result.repaired_entries,
    );
    installAuthCredentials(alloc, server, &credentials);
    if (server.pending_auth_challenge) |*pending| pending.deinit(alloc);
    server.pending_auth_challenge = null;
    server.auth_challenge_present.store(false, .release);
    credentials_transferred = true;
}

fn traceCredentialStoreRepair(
    actor: []const u8,
    server_name: []const u8,
    repaired_entries: usize,
) void {
    if (repaired_entries == 0) return;
    debug_trace.logf(
        "mcp",
        "removed unreadable MCP credential entries actor={s} server={s} count={d}",
        .{ actor, server_name, repaired_entries },
    );
}

pub fn installAuthCredentials(
    alloc: Allocator,
    server: *McpServer,
    credentials: *mcp_auth.Credentials,
) void {
    advanceAuthGeneration(server);
    replaceAuthCredentials(alloc, server, credentials);
}

pub fn installRefreshedCredentials(alloc: Allocator, server: *McpServer, credentials: *mcp_auth.Credentials) void {
    const previous = server.auth_credentials orelse {
        installAuthCredentials(alloc, server, credentials);
        return;
    };
    if (sameCredentialAuthority(previous, credentials.*)) {
        advanceCredentialGeneration(server);
    } else {
        advanceAuthGeneration(server);
    }
    replaceAuthCredentials(alloc, server, credentials);
}

fn sameCredentialAuthority(previous: mcp_auth.Credentials, renewed: mcp_auth.Credentials) bool {
    return std.mem.eql(u8, previous.endpoint, renewed.endpoint) and
        std.mem.eql(u8, previous.resource, renewed.resource) and
        std.mem.eql(u8, previous.issuer, renewed.issuer) and
        std.mem.eql(u8, previous.client_id, renewed.client_id) and
        std.mem.eql(u8, previous.scope, renewed.scope);
}

fn replaceAuthCredentials(alloc: Allocator, server: *McpServer, credentials: *mcp_auth.Credentials) void {
    if (server.auth_credentials) |*old| old.deinit(alloc);
    server.auth_credentials = credentials.*;
    server.auth_credentials_present.store(true, .release);
    credentials.* = undefined;
}

pub fn advanceAuthGeneration(server: *McpServer) void {
    server.authority_id.store(allocateGeneration(), .release);
    advanceCredentialGeneration(server);
}

fn advanceCredentialGeneration(server: *McpServer) void {
    const completions = server.completion_state;
    if (completions) |state| state.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
    defer if (completions) |state| state.legacy_url_waiter_mutex.unlock(io_mod.getIo());
    advanceAuthGenerationLocked(server);
    if (completions) |state| state.cancelLegacyUrlWaitersForServerLocked(server.config.name, server.connection_generation);
}

fn advanceAuthGenerationLocked(server: *McpServer) void {
    var current = server.auth_generation.load(.acquire);
    while (current != std.math.maxInt(u64)) {
        const result = server.auth_generation.cmpxchgWeak(
            current,
            current + 1,
            .release,
            .acquire,
        );
        if (result == null) return;
        current = result.?;
    }
}

pub fn automatedAuthorizationEnabled(endpoint: []const u8) bool {
    if (!mcp_auth.isLoopbackEndpoint(endpoint)) return false;
    const value = io_mod.getenv("FX_E2E_MCP_AUTH_AUTOMATE") orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true");
}

pub fn legacyConnectionNeedsCredentialUpdate(
    alloc: Allocator,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !bool {
    try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
    defer server.auth_lock.unlock(io_mod.getIo());
    if (server.auth_credentials) |credentials| {
        if (credentials.needsRefresh(io_mod.milliTimestamp())) return true;
    }
    const current_identity = try currentAuthIdentity(alloc, server);
    const connected_identity = try authIdentityForHeaders(
        alloc,
        server.resolved_headers,
    );
    return authIdentitiesDiffer(current_identity, connected_identity);
}

fn authIdentitiesDiffer(
    current: catalog_freshness.Digest,
    connected: catalog_freshness.Digest,
) bool {
    return !std.mem.eql(u8, &current, &connected);
}

const ResolvedHeaderSet = struct {
    headers: []mcp_contract.McpHttpHeader = &.{},
    authorization: ?[]u8 = null,

    pub fn deinit(self: *ResolvedHeaderSet, alloc: Allocator) void {
        if (self.headers.len > 0) alloc.free(self.headers);
        if (self.authorization) |value| {
            @memset(value, 0);
            alloc.free(value);
        }
        self.* = .{};
    }
};

const AuthRetryPolicy = enum {
    safe,
    never,
};

const AuthRejectionAction = enum {
    require_interactive,
    authorize_and_retry,
    authorize_without_retry,
    retry_limit,
};

test "tool authentication can update credentials without replay authorization" {
    try std.testing.expectEqual(
        AuthRejectionAction.authorize_without_retry,
        authRejectionAction(true, .never, 0),
    );
    try std.testing.expectEqual(
        AuthRejectionAction.authorize_and_retry,
        authRejectionAction(true, .safe, 0),
    );
    try std.testing.expectEqual(
        AuthRejectionAction.require_interactive,
        authRejectionAction(false, .never, 0),
    );
}

test "legacy credential reconnect compares the complete auth identity" {
    const current = catalog_freshness.authIdentity(&.{
        .{ .name = "Authorization", .value = "Bearer current-token" },
    });
    const same = catalog_freshness.authIdentity(&.{
        .{ .name = "Authorization", .value = "Bearer current-token" },
    });
    const stale = catalog_freshness.authIdentity(&.{
        .{ .name = "Authorization", .value = "Bearer stale-token" },
    });
    try std.testing.expect(!authIdentitiesDiffer(current, same));
    try std.testing.expect(authIdentitiesDiffer(current, stale));
}

test "authentication waits observe operation cancellation before state changes" {
    const alloc = std.testing.allocator;
    var server = McpServer{ .config = .{ .name = "fixture" } };
    server.auth_lock.lockUncancelable(std.testing.io);
    defer server.auth_lock.unlock(std.testing.io);
    var cancel = std.atomic.Value(bool).init(true);
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });

    try std.testing.expectError(
        error.Cancelled,
        storePendingChallenge(
            alloc,
            &server,
            .{},
            .{
                .deadline = deadline,
                .cancel_flag = &cancel,
            },
        ),
    );
    try std.testing.expect(server.pending_auth_challenge == null);
}

pub fn authenticate(
    alloc: Allocator,
    server: *McpServer,
    open_ctx: ?*anyopaque,
    open_url: mcp_auth.OpenUrlFn,
    cancel_flag: ?*const std.atomic.Value(bool),
) !mcp_auth.AuthenticationResult {
    const cancellation = operation_control.CancellationSources{
        .caller = cancel_flag,
        .runtime = server.cancellation(),
    };
    if (cancellation.cancelled()) return error.Cancelled;
    try loadStoredCredentials(alloc, server, .{
        .lifecycle_cancel_flag = server.cancellation(),
    });
    server.connection_lock.lockSharedUncancelable(io_mod.getIo());
    defer server.connection_lock.unlockShared(io_mod.getIo());
    const auth_config = server.config.auth orelse mcp_contract.McpAuthConfig{};
    const client_secret = if (auth_config.client_secret_env) |env_name|
        io_mod.getenv(env_name) orelse return error.McpClientSecretEnvironmentMissing
    else
        null;
    var source = source: {
        server.auth_lock.lockUncancelable(io_mod.getIo());
        defer server.auth_lock.unlock(io_mod.getIo());
        if (server.auth_logout_in_progress.load(.acquire)) {
            return error.McpAuthorityChanged;
        }
        var challenge = if (server.pending_auth_challenge) |pending|
            try pending.clone(alloc)
        else
            mcp_auth.Challenge{};
        errdefer challenge.deinit(alloc);
        const previous_scope = if (server.auth_credentials) |credentials|
            try alloc.dupe(u8, credentials.scope)
        else
            null;
        break :source .{
            .generation = server.auth_generation.load(.acquire),
            .challenge = challenge,
            .previous_scope = previous_scope,
        };
    };
    defer source.challenge.deinit(alloc);
    defer if (source.previous_scope) |value| alloc.free(value);
    var credentials = switch (try mcp_auth.authorizeInteractive(alloc, .{
        .endpoint = try server.config.remoteUrl(),
        .challenge = source.challenge,
        .config = .{
            .resource = auth_config.resource,
            .issuer = auth_config.issuer,
            .client_id = auth_config.client_id,
            .client_secret = client_secret,
            .client_metadata_url = auth_config.client_metadata_url,
            .scopes = auth_config.scopes,
            .callback_port = auth_config.callback_port,
        },
        .previous_scope = source.previous_scope,
        .open_ctx = open_ctx,
        .open_url = open_url,
        .cancel_flag = cancel_flag,
        .lifecycle_cancel_flag = server.cancellation(),
    })) {
        .credentials => |credentials| credentials,
        .issuer_mismatch => |mismatch| return .{ .issuer_mismatch = mismatch },
    };
    var transferred = false;
    var repaired_entries: usize = 0;
    defer if (!transferred) credentials.deinit(alloc);
    {
        server.auth_lock.lockUncancelable(io_mod.getIo());
        defer server.auth_lock.unlock(io_mod.getIo());
        try validateInteractiveAuthPublication(
            server,
            source.generation,
            cancellation,
        );
        const save_result = try mcp_auth_store.save(
            alloc,
            server.config.name,
            credentials,
        );
        repaired_entries = save_result.repaired_entries;
        installAuthCredentials(alloc, server, &credentials);
        transferred = true;
        if (server.pending_auth_challenge) |*pending| pending.deinit(alloc);
        server.pending_auth_challenge = null;
        server.auth_challenge_present.store(false, .release);
    }
    return .{ .authenticated = .{ .repaired_entries = repaired_entries } };
}

pub fn validateInteractiveAuthPublication(
    server: *const McpServer,
    generation: u64,
    cancellation: operation_control.CancellationSources,
) !void {
    if (cancellation.cancelled()) return error.Cancelled;
    if (server.auth_logout_in_progress.load(.acquire) or
        server.auth_generation.load(.acquire) != generation)
    {
        return error.McpAuthorityChanged;
    }
}

pub fn captureAuthHeader(
    alloc: Allocator,
    server: *McpServer,
    header: ?[]const u8,
    control: streamable_http.Control,
) !void {
    var challenge = if (header) |value|
        mcp_auth.parseChallenge(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => mcp_auth.Challenge{},
        }
    else
        mcp_auth.Challenge{};
    defer challenge.deinit(alloc);
    try storePendingChallenge(alloc, server, challenge, control);
    markAuthenticationRequired(alloc, server);
}

pub fn captureLegacySseAuth(
    alloc: Allocator,
    server: *McpServer,
    client: *legacy_http_sse.Client,
    control: streamable_http.Control,
) !void {
    const header = try client.copyAuthChallenge(alloc);
    defer if (header) |value| alloc.free(value);
    try captureAuthHeader(alloc, server, header, control);
}

pub fn captureLegacyStreamableAuth(
    alloc: Allocator,
    server: *McpServer,
    client: *legacy_streamable_http.Client,
    control: streamable_http.Control,
) !void {
    const header = try client.copyAuthChallenge(alloc);
    defer if (header) |value| alloc.free(value);
    try captureAuthHeader(alloc, server, header, control);
}

pub fn currentAuthPartition(
    alloc: Allocator,
    server: *McpServer,
    scope: catalog_freshness.CacheScope,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    auth_access: operation_authority.EffectAccess,
) !catalog_freshness.AuthPartition {
    const auth_identity = if (scope == .private and server.config.transport != .stdio) identity: {
        break :identity try currentAuthIdentityForAccess(
            alloc,
            server,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = server.cancellation(),
            },
            auth_access,
        );
    } else catalog_freshness.authIdentity(&.{});
    return catalog_freshness.authPartition(scope, auth_identity);
}

pub fn authorizePendingChallengeIfAutomated(
    alloc: Allocator,
    server: *McpServer,
    control: streamable_http.Control,
) !bool {
    if (!automatedAuthorizationEnabled(try server.config.remoteUrl())) return false;
    var owned_challenge = challenge: {
        try lockMutexWithControl(&server.auth_lock, control);
        defer server.auth_lock.unlock(io_mod.getIo());
        if (server.auth_logout_in_progress.load(.acquire)) return error.McpAuthorityChanged;
        break :challenge if (server.pending_auth_challenge) |pending|
            try pending.clone(alloc)
        else
            mcp_auth.Challenge{};
    };
    defer owned_challenge.deinit(alloc);
    try authorizeForChallenge(alloc, server, owned_challenge, control);
    return true;
}

pub const LogoutResult = struct {
    removed: bool = false,
    revocation_failed: bool = false,
    repaired_entries: usize = 0,
    local_only: bool = false,
};

pub const DetachedLogoutAuth = struct {
    credentials: ?mcp_auth.Credentials,
    challenge: ?mcp_auth.Challenge,

    pub fn restore(self: *DetachedLogoutAuth, server: *McpServer) void {
        std.debug.assert(server.auth_logout_in_progress.load(.acquire));
        std.debug.assert(server.auth_credentials == null);
        std.debug.assert(server.pending_auth_challenge == null);
        server.auth_credentials = self.credentials;
        self.credentials = null;
        server.auth_credentials_present.store(
            server.auth_credentials != null,
            .release,
        );
        server.pending_auth_challenge = self.challenge;
        self.challenge = null;
        server.auth_challenge_present.store(
            server.pending_auth_challenge != null,
            .release,
        );
        server.auth_logout_in_progress.store(false, .release);
    }

    pub fn deinit(self: *DetachedLogoutAuth, alloc: Allocator) void {
        if (self.credentials) |*credentials| credentials.deinit(alloc);
        if (self.challenge) |*challenge| challenge.deinit(alloc);
        self.* = undefined;
    }
};

pub fn detachAuthForLogout(server: *McpServer) DetachedLogoutAuth {
    std.debug.assert(!server.auth_logout_in_progress.load(.acquire));
    server.auth_logout_in_progress.store(true, .release);
    const detached = DetachedLogoutAuth{
        .credentials = server.auth_credentials,
        .challenge = server.pending_auth_challenge,
    };
    server.auth_credentials = null;
    server.auth_credentials_present.store(false, .release);
    server.pending_auth_challenge = null;
    server.auth_challenge_present.store(false, .release);
    return detached;
}

pub fn restoreAuthAfterLogout(
    server: *McpServer,
    auth: *DetachedLogoutAuth,
) void {
    server.auth_lock.lockUncancelable(io_mod.getIo());
    auth.restore(server);
    server.auth_lock.unlock(io_mod.getIo());
}

pub fn detachTransportForLogout(
    completions: *legacy_url_completion.State,
    server: *McpServer,
) server_connection.DetachedTransport {
    completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
    defer completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
    const detached = server.detachTransport();
    completions.cancelLegacyUrlWaitersForServerLocked(
        server.config.name,
        server.connection_generation,
    );
    return detached;
}

pub fn logout(alloc: Allocator, catalog_mutex: *std.Io.RwLock, completions: *legacy_url_completion.State, server: *McpServer) !LogoutResult {
    if (!server.isPublished()) return error.McpDiscoveryInProgress;
    if (server.config.transport == .stdio) return error.McpAuthenticationNotRemote;
    if (server.config.source == .workspace and
        server.config.workspace_admission != .approved)
    {
        const deleted = try mcp_auth_store.delete(
            alloc,
            server.config.name,
            try server.config.remoteUrl(),
        );
        return .{
            .removed = deleted.removed > 0,
            .repaired_entries = deleted.repaired_entries,
            .local_only = true,
        };
    }
    loadStoredCredentials(alloc, server, .{
        .lifecycle_cancel_flag = server.cancellation(),
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf(
            "mcp",
            "stored credential load skipped during logout server={s} err={s}",
            .{ server.config.name, @errorName(err) },
        );
    };
    server.auth_lock.lockUncancelable(io_mod.getIo());
    if (server.auth_logout_in_progress.load(.acquire)) {
        server.auth_lock.unlock(io_mod.getIo());
        return error.McpAuthorityChanged;
    }
    var auth = detachAuthForLogout(server);
    server.auth_lock.unlock(io_mod.getIo());
    defer auth.deinit(alloc);
    const deleted = mcp_auth_store.delete(
        alloc,
        server.config.name,
        try server.config.remoteUrl(),
    ) catch |err| {
        restoreAuthAfterLogout(server, &auth);
        return err;
    };
    if (deleted.removed == 0 and
        deleted.repaired_entries == 0 and
        auth.credentials == null)
    {
        restoreAuthAfterLogout(server, &auth);
        return .{};
    }

    server.auth_lock.lockUncancelable(io_mod.getIo());
    advanceAuthGeneration(server);
    server.auth_lock.unlock(io_mod.getIo());
    server.connection_lock.lockSharedUncancelable(io_mod.getIo());
    server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
    server.signalToolSubscriptionStop();
    server.catalog_commit_lock.unlock(io_mod.getIo());
    server.connection_lock.unlockShared(io_mod.getIo());
    server.connection_lock.lockUncancelable(io_mod.getIo());
    defer server.connection_lock.unlock(io_mod.getIo());
    server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
    catalog_mutex.lockUncancelable(io_mod.getIo());
    const subscription = server.detachToolSubscription();
    catalog_mutex.unlock(io_mod.getIo());
    server.catalog_commit_lock.unlock(io_mod.getIo());
    if (subscription) |state| state.stopAndDestroy();
    var detached = detachTransportForLogout(completions, server);
    detached.deinit(false);
    server.auth_lock.lockUncancelable(io_mod.getIo());
    server.clearResolvedHeaders(alloc);
    server.auth_logout_in_progress.store(false, .release);
    server.auth_lock.unlock(io_mod.getIo());
    var revocation_failed = false;
    if (auth.credentials) |credentials| {
        mcp_auth.revokeCredentials(alloc, credentials) catch |err| {
            if (err != error.RevocationEndpointMissing) revocation_failed = true;
        };
    }
    return .{
        .removed = true,
        .revocation_failed = revocation_failed,
        .repaired_entries = deleted.repaired_entries,
    };
}
