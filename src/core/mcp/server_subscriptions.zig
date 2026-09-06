const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp_contract = @import("mcp_contract.zig");
const server_auth = @import("server_auth.zig");
const streamable_http = @import("streamable_http.zig");
const tool_subscription = @import("tool_subscription.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const connection_control = @import("connection_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const Allocator = std.mem.Allocator;
const McpServer = @import("server_connection.zig").Server;
const ConnectionControl = connection_control.Control;
const modern_protocol_version = @import("protocol_negotiation.zig").modern_protocol_version;
const mcp_subscription_event_cap_bytes: usize = 64 * 1024;
const startupDeadline = connection_control.startupDeadline;
const lockMutexUntil = controlled_lock.mutexUntil;
const lockRwUntil = controlled_lock.rwUntil;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const lockRwSharedWithControl = controlled_lock.rwSharedWithControl;

pub fn startToolSubscription(
    alloc: Allocator,
    server: *McpServer,
    control: ConnectionControl,
) !void {
    return startToolSubscriptionWithResources(alloc, server, &.{}, control);
}

fn startToolSubscriptionWithResources(
    alloc: Allocator,
    server: *McpServer,
    resource_subscriptions: []const []const u8,
    control: ConnectionControl,
) !void {
    if (server.tool_subscription != null) return;
    const subscription = try createToolSubscriptionWithResources(
        alloc,
        server,
        resource_subscriptions,
        control,
    ) orelse return;
    publishToolSubscription(server, subscription);
}

pub fn createToolSubscriptionWithResources(
    alloc: Allocator,
    server: *McpServer,
    resource_subscriptions: []const []const u8,
    control: ConnectionControl,
) !?*tool_subscription.State {
    const base_filters = tool_subscription.Filters{
        .tools_list_changed = server.tools_list_changed,
        .resources_list_changed = server.capabilities.resources_list_changed,
        .prompts_list_changed = server.capabilities.prompts_list_changed,
        .resource_subscriptions = if (server.capabilities.resources_subscribe)
            resource_subscriptions
        else
            &.{},
        .elicitation_complete = server.legacyWire() == .legacy_mcp_2025_11 and
            server.elicitation_capabilities.url,
    };
    if (!base_filters.any()) return null;
    const subscription_generation = server.next_subscription_generation;
    server.next_subscription_generation = std.math.add(
        u64,
        subscription_generation,
        1,
    ) catch return error.McpGenerationExhausted;

    const subscription = switch (server.config.transport) {
        .stdio => subscription: {
            const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
            const protocol: catalog_freshness.Protocol = switch (server.stdio_protocol) {
                .modern => .modern,
                .legacy => .legacy,
                .unselected => return error.McpConnectionClosed,
            };
            const request_id = if (protocol == .modern)
                try dispatcher.reserveRequestId()
            else
                0;
            if (protocol == .legacy and base_filters.elicitation_complete) {
                break :subscription try tool_subscription.State.createLegacyStdioWithNotifications(
                    alloc,
                    dispatcher,
                    server.connection_generation,
                    subscription_generation,
                    base_filters,
                    try legacyCompletionPassthrough(server, dispatcher.connectionGeneration()),
                );
            }
            break :subscription try tool_subscription.State.createStdio(
                alloc,
                dispatcher,
                protocol,
                server.connection_generation,
                request_id,
                subscription_generation,
                base_filters,
                if (protocol == .modern)
                    subscriptionStartupDeadline(server, control.deadline)
                else
                    null,
                if (protocol == .modern) control.cancel_flag else null,
            );
        },
        .http => subscription: {
            if (std.mem.eql(
                u8,
                server.negotiated_protocol_version,
                modern_protocol_version,
            )) {
                if (server.session_generation == null) return null;
                break :subscription try tool_subscription.State.createHttp(
                    alloc,
                    server.config.name,
                    .{
                        .context = server.subscription_server orelse server,
                        .callback = listenModernHttpToolSubscription,
                    },
                    server.connection_generation,
                    try server.reserveRequestId(),
                    subscription_generation,
                    base_filters,
                );
            }
            const client = server.legacy_http orelse return error.McpConnectionClosed;
            break :subscription try tool_subscription.State.createLegacyHttp(
                alloc,
                client,
                server.connection_generation,
                subscription_generation,
                base_filters,
                try legacyCompletionPassthrough(server, server.connection_generation),
            );
        },
        .sse => subscription: {
            const client = server.legacy_sse orelse return error.McpConnectionClosed;
            break :subscription try tool_subscription.State.createLegacySse(
                alloc,
                client,
                server.connection_generation,
                subscription_generation,
                base_filters,
            );
        },
    };
    return subscription;
}

pub fn publishToolSubscription(
    server: *McpServer,
    subscription: *tool_subscription.State,
) void {
    server.tool_subscription = subscription;
    if (server.tool_catalog.metadata) |*metadata| {
        metadata.subscription = subscription.identity();
    }
    if (server.resource_catalog.metadata) |*metadata| {
        metadata.subscription = subscription.identity();
    }
    if (server.resource_template_catalog.metadata) |*metadata| {
        metadata.subscription = subscription.identity();
    }
    if (server.prompt_catalog.metadata) |*metadata| {
        metadata.subscription = subscription.identity();
    }
    debug_trace.logf(
        "mcp",
        "MCP subscription started server={s} connection_generation={d} subscription_generation={d}",
        .{ server.config.name, server.connection_generation, subscription.identity().generation },
    );
}

pub fn legacyCompletionPassthrough(
    server: *McpServer,
    client_generation: u64,
) error{McpRuntimeUnavailable}!tool_subscription.NotificationPassthrough {
    const handler = server.legacy_notifications orelse return error.McpRuntimeUnavailable;
    return .{
        .context = handler.context,
        .source = .{
            .server_name = server.config.name,
            .connection_generation = server.connection_generation,
            .client_generation = client_generation,
            .auth_generation = server.auth_generation.load(.acquire),
        },
        .callback = handler.callback,
    };
}

fn subscriptionStartupDeadline(
    server: *const McpServer,
    operation_deadline: ?std.Io.Clock.Timestamp,
) std.Io.Clock.Timestamp {
    const startup_deadline = startupDeadline(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        server.config.startup_timeout_ms,
        null,
    );
    const operation = operation_deadline orelse return startup_deadline;
    return if (std.Io.Clock.Timestamp.compare(operation, .lt, startup_deadline))
        operation
    else
        startup_deadline;
}

pub fn takeFinishedToolSubscription(
    catalog_mutex: *std.Io.RwLock,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !?tool_subscription.State.FinishReason {
    try lockMutexUntil(&server.subscription_lifecycle_lock, deadline, cancel_flag);
    defer server.subscription_lifecycle_lock.unlock(io_mod.getIo());
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    var commit_locked = true;
    defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
    const previous = server.tool_subscription orelse return null;
    if (!previous.isFinished()) return null;
    const observed_reason = previous.finishReason();
    debug_trace.logf(
        "mcp",
        "recovering finished tool subscription server={s} reason={s}",
        .{ server.config.name, @tagName(observed_reason) },
    );
    if (observed_reason == .authentication_required and
        server.legacy_http == null and
        server.legacy_sse == null)
    {
        return observed_reason;
    }
    previous.requestStop();

    try lockRwUntil(catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) catalog_mutex.unlock(io_mod.getIo());
    if (server.tool_subscription != previous or !previous.isFinished()) return null;
    const reason = previous.finishReason();
    debug_trace.logf(
        "mcp",
        "detaching finished tool subscription server={s}",
        .{server.config.name},
    );
    const detached = server.detachToolSubscription() orelse return null;
    catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    server.catalog_commit_lock.unlock(io_mod.getIo());
    commit_locked = false;
    detached.stopAndDestroy();
    return reason;
}

pub fn startToolSubscriptionGuarded(
    catalog_mutex: *std.Io.RwLock,
    alloc: Allocator,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    try lockMutexUntil(&server.subscription_lifecycle_lock, deadline, cancel_flag);
    defer server.subscription_lifecycle_lock.unlock(io_mod.getIo());
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    var candidate: ?*tool_subscription.State = null;
    defer if (candidate) |subscription| subscription.stopAndDestroy();

    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    var commit_locked = true;
    defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
    try lockRwUntil(catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) catalog_mutex.unlock(io_mod.getIo());
    if (server.tool_subscription != null) return;
    catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    server.catalog_commit_lock.unlock(io_mod.getIo());
    commit_locked = false;

    candidate = try createToolSubscriptionWithResources(
        alloc,
        server,
        &.{},
        .{
            .deadline = deadline,
            .cancel_flag = cancel_flag,
            .lifecycle_cancel_flag = server.cancellation(),
        },
    );
    if (candidate == null) return;

    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    commit_locked = true;
    try lockRwUntil(catalog_mutex, deadline, cancel_flag);
    catalog_locked = true;
    if (server.tool_subscription != null) return;
    publishToolSubscription(server, candidate.?);
    candidate = null;
}

fn listenModernHttpToolSubscription(
    raw: *anyopaque,
    alloc: Allocator,
    server_name: []const u8,
    connection_generation: u64,
    request_body: []const u8,
    notifications: mcp_contract.NotificationSink,
    control: streamable_http.Control,
) ![]u8 {
    const server: *McpServer = @ptrCast(@alignCast(raw));
    if (!std.mem.eql(u8, server.config.name, server_name) or !server.lifetime.acquire(io_mod.getIo())) return error.McpConnectionClosed;
    defer server.lifetime.release(io_mod.getIo());
    const owner_alloc = server.owner_alloc orelse return error.McpConnectionClosed;
    const generation = server.session_generation orelse return error.McpConnectionClosed;
    try lockRwSharedWithControl(&server.connection_lock, control);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    if (server.connection_generation != connection_generation or
        server.config.transport != .http or
        !std.mem.eql(u8, server.negotiated_protocol_version, modern_protocol_version))
    {
        return error.McpConnectionClosed;
    }
    const response = try server_auth.authenticatedPost(alloc, owner_alloc, server, .{
        .url = try server.config.remoteUrl(),
        .request_body = request_body,
        .max_response_bytes = mcp_subscription_event_cap_bytes,
        .max_event_bytes = mcp_subscription_event_cap_bytes,
        .notifications = notifications,
        .long_lived = true,
        .control = control,
    }, .{
        .alloc = owner_alloc,
        .runtime_generation = generation,
        .access = .unrestricted,
        .target = .{ .tool_server = server.config.name },
    }, .safe, null);
    if (response.www_authenticate) |value| alloc.free(value);
    return response.body;
}
