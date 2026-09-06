const std = @import("std");
const server_connection = @import("server_connection.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_catalog = @import("tool_catalog.zig");
const permissions = @import("../permissions/permissions.zig");
const types = @import("../shared/types.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const health = @import("health.zig");
const model_catalog = @import("model_catalog.zig");
const startup_admission = @import("startup_admission.zig");
const tool_subscription = @import("tool_subscription.zig");
const Allocator = std.mem.Allocator;
const McpServer = server_connection.Server;

pub fn snapshotServerHealthBeforeDiscoveryPublication(
    alloc: Allocator,
    runtime_generation: u64,
    server: *const McpServer,
    discovering: bool,
) !health.ServerSnapshot {
    const configured_name = try terminalSafeOwned(alloc, server.config.name, 256);
    errdefer alloc.free(configured_name);
    const identity_name = try alloc.dupe(u8, server.config.name);
    errdefer alloc.free(identity_name);
    const connection: health.ConnectionState = if (!server.config.enabled)
        .disabled
    else if (discovering)
        .connecting
    else
        .disconnected;
    const authentication = serverAuthenticationState(server);
    const failure = try healthFailureForState(
        alloc,
        server.config.required,
        connection,
        authentication,
        null,
    );
    return .{
        .configured_name = configured_name,
        .identity_name = identity_name,
        .negotiated_name = null,
        .negotiated_version = null,
        .source = server.config.source,
        .scope = server.config.scope,
        .workspace_admission = server.config.workspace_admission,
        .required = server.config.required,
        .transport = server.config.transport,
        .protocol_version = null,
        .connection = connection,
        .reloading = server.reload_pending.load(.acquire),
        .authentication = authentication,
        .counts = .{},
        .cache_freshness = .unavailable,
        .subscription = .unavailable,
        .runtime_generation = runtime_generation,
        .catalog_generation = 0,
        .retry_attempt = 0,
        .retry_in_ms = null,
        .last_successful_discovery_ms = null,
        .failure = failure,
    };
}

pub fn snapshotServerHealth(
    alloc: Allocator,
    runtime_generation: u64,
    server: *const McpServer,
    cache_now_ms: u64,
) !health.ServerSnapshot {
    const configured_name = try terminalSafeOwned(alloc, server.config.name, 256);
    errdefer alloc.free(configured_name);
    const identity_name = try alloc.dupe(u8, server.config.name);
    errdefer alloc.free(identity_name);
    const negotiated_name = if (server.negotiated_server_name) |value|
        try terminalSafeOwned(alloc, value, 256)
    else
        null;
    errdefer if (negotiated_name) |value| alloc.free(value);
    const negotiated_version = if (server.negotiated_server_version) |value|
        try terminalSafeOwned(alloc, value, 128)
    else
        null;
    errdefer if (negotiated_version) |value| alloc.free(value);
    const protocol_version = if (server.negotiated_protocol_version.len > 0)
        try terminalSafeOwned(alloc, server.negotiated_protocol_version, 128)
    else
        null;
    errdefer if (protocol_version) |value| alloc.free(value);
    const published_connection: health.ConnectionState = switch (server.state.load(.acquire)) {
        .disconnected => .disconnected,
        .disabled => .disabled,
        .ready => .ready,
        .failed => .failed,
    };
    const transport_running: ?bool = if (server.config.transport == .stdio)
        if (server.dispatcher) |dispatcher| dispatcher.isRunning() else false
    else
        null;
    const connection = health.observedConnection(
        published_connection,
        transport_running,
    );
    const authentication = serverAuthenticationState(server);
    const failure = try healthFailureForState(
        alloc,
        server.config.required,
        connection,
        authentication,
        server.last_error,
    );
    errdefer if (failure) |value| alloc.free(value);
    return .{
        .configured_name = configured_name,
        .identity_name = identity_name,
        .negotiated_name = negotiated_name,
        .negotiated_version = negotiated_version,
        .source = server.config.source,
        .scope = server.config.scope,
        .workspace_admission = server.config.workspace_admission,
        .required = server.config.required,
        .transport = server.config.transport,
        .protocol_version = protocol_version,
        .connection = connection,
        .reloading = server.reload_pending.load(.acquire),
        .authentication = authentication,
        .counts = .{
            .tools = health.capabilityCount(
                true,
                tool_catalog.serverCatalogAvailable(server),
                server.tool_catalog.tools.items.len,
            ),
            .resources = health.capabilityCount(
                server.capabilities.resources,
                server.resource_catalog.available,
                if (server.resource_catalog.catalog) |catalog| catalog.items.len else 0,
            ),
            .resource_templates = health.capabilityCount(
                server.capabilities.resources,
                server.resource_template_catalog.available,
                if (server.resource_template_catalog.catalog) |catalog| catalog.items.len else 0,
            ),
            .prompts = health.capabilityCount(
                server.capabilities.prompts,
                server.prompt_catalog.available,
                if (server.prompt_catalog.catalog) |catalog| catalog.prompts.len else 0,
            ),
        },
        .cache_freshness = aggregateCacheFreshness(server, cache_now_ms),
        .subscription = subscriptionHealth(server),
        .runtime_generation = runtime_generation,
        .catalog_generation = server.catalog_generation,
        .retry_attempt = aggregateRetryAttempt(server),
        .retry_in_ms = health.retryDelay(
            aggregateNextRetry(server),
            cache_now_ms,
        ),
        .last_successful_discovery_ms = server.last_successful_discovery_ms,
        .failure = failure,
    };
}

pub fn configuredAuthenticationState(server: *const McpServer) health.AuthenticationState {
    return if (server.config.auth != null or
        server.config.bearer_token_env != null or
        server.config.header_env.len > 0)
        .configured
    else
        .none;
}

pub fn serverAuthenticationState(server: *const McpServer) health.AuthenticationState {
    if (server.auth_challenge_present.load(.acquire)) return .required;
    if (server.auth_credentials_present.load(.acquire)) return .authenticated;
    return configuredAuthenticationState(server);
}

pub fn snapshotServerModelSummary(
    alloc: Allocator,
    server: *const McpServer,
    permission_rules: types.PermissionRuleSet,
    deferred_pending: bool,
) !model_catalog.ServerSummary {
    const name = try alloc.dupe(u8, server.config.name);
    errdefer alloc.free(name);
    const published_connection: health.ConnectionState = switch (server.state.load(.acquire)) {
        .disconnected => .disconnected,
        .disabled => .disabled,
        .ready => .ready,
        .failed => .failed,
    };
    const transport_running: ?bool = if (server.config.transport == .stdio)
        if (server.dispatcher) |dispatcher| dispatcher.isRunning() else false
    else
        null;
    const connection = health.observedConnection(published_connection, transport_running);
    const deferred_for_ask = deferred_pending and
        startup_admission.decide(
            server.config.enabled,
            server.config.required,
            server.config.workspace_admission,
            .ask_startup,
        ) == .deferred;
    var tool_count: ?usize = null;
    if (connection == .ready and tool_catalog.serverCatalogAvailable(server)) {
        var visible_count: usize = 0;
        for (server.tool_catalog.tools.items) |tool| {
            if (permissions.rulesDenyAllTargetsForPermission(
                permission_rules,
                tool.prefixed_name,
            )) continue;
            visible_count += 1;
        }
        tool_count = visible_count;
    }
    return .{
        .name = name,
        .availability = model_catalog.classifyAvailability(
            connection,
            serverAuthenticationState(server),
            deferred_for_ask,
        ),
        .tool_count = tool_count,
    };
}

pub fn terminalSafeOwned(alloc: Allocator, value: []const u8, limit: usize) Allocator.Error![]u8 {
    const encoded = try text_utils.encodeTerminalSafe(alloc, value, limit);
    return encoded.bytes;
}

pub fn healthFailureForState(
    alloc: Allocator,
    required: bool,
    connection: health.ConnectionState,
    authentication: health.AuthenticationState,
    last_error: ?[]const u8,
) Allocator.Error!?[]u8 {
    if (required and connection == .disabled) {
        return @as(?[]u8, try alloc.dupe(u8, "Enable this required server or mark it optional."));
    }
    if (authentication == .required) {
        return @as(?[]u8, try alloc.dupe(
            u8,
            "Authentication is required or the saved credentials lack access; run /mcp auth <name> --open and check server permissions.",
        ));
    }
    if (connection == .failed) {
        if (last_error) |message| {
            const masked = text_utils.maskSecrets(alloc, message) catch return error.OutOfMemory;
            defer if (masked.ptr != message.ptr) alloc.free(masked);
            return try terminalSafeOwned(alloc, masked, 1024);
        }
        return @as(?[]u8, try alloc.dupe(u8, "Connection or discovery failed; check the trusted profile configuration and trace logs."));
    }
    return null;
}

fn aggregateCacheFreshness(server: *const McpServer, now_ms: u64) health.CacheFreshness {
    var result: health.CacheFreshness = .unavailable;
    const invalidated = if (server.tool_subscription) |subscription| subscription.hasInvalidation() else false;
    for ([_]?catalog_freshness.SnapshotMetadata{
        server.tool_catalog.metadata,
        server.resource_catalog.metadata,
        server.resource_template_catalog.metadata,
        server.prompt_catalog.metadata,
    }) |maybe_metadata| {
        const metadata = maybe_metadata orelse continue;
        const current: health.CacheFreshness = switch (catalog_freshness.effectiveFreshness(metadata, now_ms, invalidated)) {
            .fresh => .fresh,
            .stale => .stale,
            .refreshing => .refreshing,
            .failed_refresh => .failed_refresh,
        };
        if (cacheFreshnessRank(current) > cacheFreshnessRank(result)) result = current;
    }
    return result;
}

fn cacheFreshnessRank(value: health.CacheFreshness) u3 {
    return switch (value) {
        .unavailable => 0,
        .fresh => 1,
        .stale => 2,
        .refreshing => 3,
        .failed_refresh => 4,
    };
}

fn subscriptionHealth(server: *const McpServer) health.SubscriptionState {
    const subscription = server.tool_subscription orelse return health.subscriptionStateFor(.{
        .present = false,
    });
    return health.subscriptionStateFor(.{
        .present = true,
        .unsupported = subscription.isUnsupported(),
        .finished = subscription.isFinished(),
        .requires_acknowledgement = subscription.requiresAcknowledgement(),
        .acknowledged = subscription.isAcknowledged(),
    });
}

fn aggregateRetryAttempt(server: *const McpServer) u8 {
    var attempt = server.restart_attempts;
    for ([_]?catalog_freshness.SnapshotMetadata{
        server.tool_catalog.metadata,
        server.resource_catalog.metadata,
        server.resource_template_catalog.metadata,
        server.prompt_catalog.metadata,
    }) |metadata| {
        if (metadata) |value| attempt = @max(attempt, value.refresh_attempt);
    }
    return attempt;
}

fn aggregateNextRetry(server: *const McpServer) ?u64 {
    var retry: ?u64 = null;
    for ([_]?catalog_freshness.SnapshotMetadata{
        server.tool_catalog.metadata,
        server.resource_catalog.metadata,
        server.resource_template_catalog.metadata,
        server.prompt_catalog.metadata,
    }) |metadata| {
        const retry_at_ms = if (metadata) |value| value.retry_at_ms else 0;
        if (retry_at_ms == 0) continue;
        retry = if (retry) |current| @min(current, retry_at_ms) else retry_at_ms;
    }
    return retry;
}
