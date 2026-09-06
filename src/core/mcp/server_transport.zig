const std = @import("std");
const server_connection = @import("server_connection.zig");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const server_auth = @import("server_auth.zig");
const server_subscriptions = @import("server_subscriptions.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_names = @import("tool_names.zig");
const tool_catalog = @import("tool_catalog.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const legacy_http_sse = @import("legacy_http_sse.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const operation_control = @import("operation_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
const protocol_messages = @import("protocol_messages.zig");
const buildDiscoverRequest = protocol_messages.buildDiscoverRequest;
const buildToolsListRequest = protocol_messages.buildToolsListRequest;
const buildLegacyInitializeRequest = protocol_messages.buildLegacyInitializeRequest;
const parseServerCapabilitiesFromResponse = protocol_messages.parseServerCapabilitiesFromResponse;
const parseServerIdentity = protocol_messages.parseServerIdentity;
const parseServerCapabilities = protocol_messages.parseServerCapabilities;
const featureProtocol = protocol_messages.featureProtocol;
const docker_run = @import("docker_run.zig");
const stdio_dispatcher = @import("stdio_dispatcher.zig");
const streamable_http = @import("streamable_http.zig");
const tools_feature = @import("features/tools.zig");
const tool_result = @import("tool_result.zig");
const Allocator = std.mem.Allocator;
const mcp_discovery_response_frame_cap_bytes: usize = 1024 * 1024;
const modern_protocol_version = protocol_negotiation.modern_protocol_version;
const allocateGeneration = @import("server_lifetime.zig").allocateIdentity;
const lockMutexUntil = controlled_lock.mutexUntil;
const StdioProtocol = protocol_negotiation.Protocol;
const LegacyStdioVersion = protocol_negotiation.LegacyStdioVersion;
const decideLegacyInitializeTransition = protocol_negotiation.decideLegacyInitializeTransition;
const classifyResponsePayload = protocol_negotiation.classifyResponsePayload;
const classifyDiscoveryResponse = protocol_negotiation.classifyDiscoveryResponse;
const classifyHttpDiscoveryResponse = protocol_negotiation.classifyHttpDiscoveryResponse;
const classifyLegacyInitializeResponse = protocol_negotiation.classifyLegacyInitializeResponse;
const connection_control = @import("connection_control.zig");
const ConnectionControl = connection_control.Control;
const McpServer = server_connection.Server;

pub fn connectServer(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *tool_names.Registry,
    control: ConnectionControl,
) !void {
    server.owner_alloc = alloc;
    try connection_control.check(io_mod.getIo(), control);
    if (server.last_error) |old| {
        alloc.free(old);
        server.last_error = null;
    }
    if (server.instructions) |old| {
        alloc.free(old);
        server.instructions = null;
    }
    switch (server.config.transport) {
        .sse => {
            const attempt_control = connectionAttemptControl(
                control,
                server.config.startup_timeout_ms,
            );
            try connection_control.check(io_mod.getIo(), attempt_control);
            _ = server_auth.refreshSharedCredentials(alloc, server, .{
                .deadline = attempt_control.deadline.?,
                .cancel_flag = attempt_control.cancel_flag,
                .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
            }) catch |err| {
                server.tool_catalog.deinit(alloc);
                return err;
            };
            return connectServerSse(
                alloc,
                server,
                tool_registry,
                used_tool_names,
                attempt_control,
            );
        },
        .http => return connectServerHttp(alloc, server, tool_registry, used_tool_names, control),
        .stdio => {},
    }
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    try connection_control.check(io_mod.getIo(), attempt_control);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, try server.config.stdioCommand());
    for (server.config.args) |arg| try argv.append(alloc, arg);

    if (server.env_map) |*existing| {
        existing.deinit();
        server.env_map = null;
    }
    defer {
        if (server.env_map) |*environment| environment.deinit();
        server.env_map = null;
    }
    const has_child_environment = for (server.config.env) |entry| {
        if (!std.mem.eql(u8, entry.key, protocol_negotiation.protocol_version_environment)) break true;
    } else false;
    if (has_child_environment) {
        server.env_map = try io_mod.cloneEnvironMap(alloc);
        for (server.config.env) |entry| {
            if (std.mem.eql(u8, entry.key, protocol_negotiation.protocol_version_environment)) continue;
            try server.env_map.?.put(entry.key, entry.value);
        }
    }

    if (try protocol_negotiation.startupMode(server.config.env, io_mod.getenv(protocol_negotiation.protocol_version_environment)) == .legacy) {
        return connectServerLegacy(alloc, server, argv.items, tool_registry, used_tool_names, attempt_control, .v2025_11_25);
    }

    try spawnStdioServer(alloc, server, argv.items);
    errdefer server.disconnectForced();

    const dispatcher = server.dispatcher.?;
    const discover_id = try dispatcher.reserveRequestId();
    const discover_request = try buildDiscoverRequest(alloc, discover_id);
    defer alloc.free(discover_request);

    const discover_response = dispatcher.request(
        alloc,
        discover_id,
        discover_request,
        mcp_discovery_response_frame_cap_bytes,
        .{
            .timeout_ms = server.config.startup_timeout_ms,
            .deadline = attempt_control.discoveryProbeAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
            .send_cancellation = false,
        },
    ) catch |err| switch (err) {
        error.McpRequestTimedOut,
        error.McpConnectionClosed,
        => {
            try connection_control.check(io_mod.getIo(), control);
            return connectServerLegacy(
                alloc,
                server,
                argv.items,
                tool_registry,
                used_tool_names,
                control,
                .v2024_11_05,
            );
        },
        else => return err,
    };
    defer alloc.free(discover_response);

    var parsed_discover = std.json.parseFromSlice(std.json.Value, alloc, discover_response, .{}) catch
        return error.McpInvalidJson;
    defer parsed_discover.deinit();

    switch (try classifyDiscoveryResponse(parsed_discover.value)) {
        .legacy_fallback => |version| return connectServerLegacy(
            alloc,
            server,
            argv.items,
            tool_registry,
            used_tool_names,
            control,
            version,
        ),
        .unsupported => {
            server.setFailed(alloc, "MCP server does not support protocol version " ++ modern_protocol_version);
            return error.McpUnsupportedProtocolVersion;
        },
        .modern_protocol_error => |protocol_error| {
            const diagnostic = try tool_result.format_protocol_error(alloc, protocol_error);
            defer alloc.free(diagnostic);
            server.setFailed(alloc, diagnostic);
            return error.McpProtocolError;
        },
        .modern => {},
    }

    server.stdio_protocol = .modern;
    server.negotiated_protocol_version = modern_protocol_version;
    const discovered_capabilities = try parseServerCapabilities(parsed_discover.value);
    server.tools_list_changed = discovered_capabilities.tools_list_changed;
    server.capabilities = discovered_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, discover_response);
    try parseAndStoreServerInstructionsForProtocol(alloc, server, discover_response, .modern);
    try discoverServerTools(
        alloc,
        server,
        tool_registry,
        used_tool_names,
        .modern,
        attempt_control,
    );
}

fn connectServerHttp(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *tool_names.Registry,
    control: ConnectionControl,
) !void {
    errdefer {
        server.tool_catalog.deinit(alloc);
    }
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    try connection_control.check(io_mod.getIo(), attempt_control);
    const deadline = attempt_control.deadline.?;
    const post_control = streamable_http.Control{
        .deadline = deadline,
        .cancel_flag = attempt_control.cancel_flag,
        .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
    };

    var next_request_id: u64 = 1;
    if (try protocol_negotiation.startupMode(server.config.env, io_mod.getenv(protocol_negotiation.protocol_version_environment)) == .legacy) {
        _ = try server_auth.refreshSharedCredentials(alloc, server, post_control);
        return connectServerLegacyHttp(alloc, server, tool_registry, used_tool_names, attempt_control, &next_request_id, legacy_streamable_http.preferred_version);
    }
    var discover_request = try buildDiscoverRequest(alloc, next_request_id);
    defer alloc.free(discover_request);
    next_request_id += 1;

    var discover_response = try server_auth.authenticatedPost(alloc, alloc, server, .{
        .url = try server.config.remoteUrl(),
        .static_headers = server.resolved_headers,
        .request_body = discover_request,
        .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
        .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
        .allow_version_error = true,
        .allow_discovery_mismatch_status = true,
        .control = post_control,
    }, .{
        .alloc = alloc,
        .runtime_generation = server.session_generation orelse return error.McpRuntimeUnavailable,
        .access = .unrestricted,
        .target = .{ .tool_server = server.config.name },
    }, .safe, null);
    defer discover_response.deinit(alloc);

    if (discover_response.discovery_mismatch_status) {
        return connectServerLegacyHttp(
            alloc,
            server,
            tool_registry,
            used_tool_names,
            control,
            &next_request_id,
            legacy_streamable_http.preferred_version,
        );
    }

    if (discover_response.version_error) {
        const selection = selection: {
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                alloc,
                discover_response.body,
                .{},
            ) catch return error.McpInvalidJson;
            defer parsed.deinit();
            break :selection try classifyHttpDiscoveryResponse(parsed.value);
        };
        switch (selection) {
            .legacy_fallback => return connectServerLegacyHttp(
                alloc,
                server,
                tool_registry,
                used_tool_names,
                control,
                &next_request_id,
                legacy_streamable_http.preferred_version,
            ),
            .retry_modern => {
                const replacement = replacement: {
                    const request = try buildDiscoverRequest(alloc, next_request_id);
                    errdefer alloc.free(request);
                    const response = try server_auth.authenticatedPost(alloc, alloc, server, .{
                        .url = try server.config.remoteUrl(),
                        .static_headers = server.resolved_headers,
                        .request_body = request,
                        .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
                        .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
                        .control = post_control,
                    }, .{
                        .alloc = alloc,
                        .runtime_generation = server.session_generation orelse return error.McpRuntimeUnavailable,
                        .access = .unrestricted,
                        .target = .{ .tool_server = server.config.name },
                    }, .safe, null);
                    break :replacement .{
                        .request = request,
                        .response = response,
                    };
                };
                next_request_id += 1;
                discover_response.deinit(alloc);
                alloc.free(discover_request);
                discover_request = replacement.request;
                discover_response = replacement.response;
            },
            .modern, .unsupported => return error.UnexpectedHttpStatus,
        }
    }

    var parsed_discover = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        discover_response.body,
        .{},
    ) catch return error.McpInvalidJson;
    defer parsed_discover.deinit();
    switch (try classifyHttpDiscoveryResponse(parsed_discover.value)) {
        .modern => {},
        .legacy_fallback => return connectServerLegacyHttp(
            alloc,
            server,
            tool_registry,
            used_tool_names,
            control,
            &next_request_id,
            legacy_streamable_http.preferred_version,
        ),
        .retry_modern, .unsupported => {
            server.setFailed(
                alloc,
                "MCP server does not support protocol version " ++ modern_protocol_version,
            );
            return error.McpUnsupportedProtocolVersion;
        },
    }

    server.negotiated_protocol_version = modern_protocol_version;
    const discovered_capabilities = try parseServerCapabilities(parsed_discover.value);
    server.tools_list_changed = discovered_capabilities.tools_list_changed;
    server.capabilities = discovered_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, discover_response.body);

    try parseAndStoreServerInstructionsForProtocol(
        alloc,
        server,
        discover_response.body,
        .modern,
    );

    var request_ids = tool_catalog.RequestIds{ .local = &next_request_id };
    var fetched = try tool_catalog.fetch(alloc, .{
        .alloc = alloc,
        .runtime_generation = server.session_generation orelse return error.McpRuntimeUnavailable,
        .access = .unrestricted,
        .target = .{ .tool_server = server.config.name },
    }, server, .{ .modern_http = &request_ids }, deadline, attempt_control.cancel_flag);
    defer fetched.deinit(alloc);
    try tool_catalog.install(
        alloc,
        server,
        tool_registry,
        fetched.catalog,
        used_tool_names,
        .modern,
        fetched.auth_identity,
    );
    server.http_next_request_id.store(next_request_id, .seq_cst);
    try server_subscriptions.startToolSubscription(alloc, server, attempt_control);
    server.setReady(alloc, operation_control.monotonicMillis(io_mod.getIo()));
}

pub fn connectServerLegacyHttp(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *tool_names.Registry,
    control: ConnectionControl,
    next_request_id: *u64,
    requested_version: legacy_streamable_http.Version,
) !void {
    try server_auth.refreshResolvedHeaders(alloc, server);
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    try connection_control.check(io_mod.getIo(), attempt_control);
    const deadline = attempt_control.deadline.?;
    const init_id = next_request_id.*;
    next_request_id.* = std.math.add(u64, init_id, 1) catch
        return error.McpRequestIdExhausted;
    const init_request = try buildLegacyInitializeRequest(
        alloc,
        init_id,
        requested_version.string(),
        server_connection.legacyWireForHttpVersion(requested_version),
        server.elicitation_capabilities,
    );
    defer alloc.free(init_request);

    var startup_auth_challenge: ?[]u8 = null;
    defer if (startup_auth_challenge) |value| alloc.free(value);
    var initialized = legacy_streamable_http.initialize(alloc, .{
        .url = try server.config.remoteUrl(),
        .static_headers = server.resolved_headers,
        .request_body = init_request,
        .request_id = init_id,
        .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
        .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
        .control = .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
        .auth_challenge = &startup_auth_challenge,
    }) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try server_auth.captureAuthHeader(
                alloc,
                server,
                startup_auth_challenge,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };
    var client_owned = true;
    defer if (client_owned) initialized.client.deinit();
    defer initialized.deinitResponse(alloc);

    server.negotiated_protocol_version = initialized.client.version.string();
    const initialized_capabilities = try parseServerCapabilitiesFromResponse(
        alloc,
        initialized.response_body,
    );
    server.tools_list_changed = initialized_capabilities.tools_list_changed;
    server.capabilities = initialized_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, initialized.response_body);

    try parseAndStoreServerInstructionsForProtocol(
        alloc,
        server,
        initialized.response_body,
        .legacy,
    );
    initialized.client.sendNotification(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}",
        .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
    ) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try server_auth.captureLegacyStreamableAuth(
                alloc,
                server,
                initialized.client,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };

    var pages = tools_feature.CatalogBuilder.init(alloc, .legacy);
    defer pages.deinit(alloc);
    while (true) {
        const tools_id = next_request_id.*;
        next_request_id.* = std.math.add(u64, tools_id, 1) catch
            return error.McpRequestIdExhausted;
        const tools_request = try buildToolsListRequest(alloc, tools_id, .legacy, pages.next_cursor);
        defer alloc.free(tools_request);
        const tools_response = initialized.client.request(alloc, .{
            .request_id = tools_id,
            .request_body = tools_request,
            .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
            .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
            .control = .{
                .deadline = deadline,
                .cancel_flag = attempt_control.cancel_flag,
                .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
            },
        }) catch |err| {
            if (err == error.McpAuthenticationRequired) {
                try server_auth.captureLegacyStreamableAuth(
                    alloc,
                    server,
                    initialized.client,
                    .{
                        .deadline = deadline,
                        .cancel_flag = attempt_control.cancel_flag,
                        .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                    },
                );
            }
            return err;
        };
        const received_at_ms = operation_control.monotonicMillis(io_mod.getIo());
        defer alloc.free(tools_response);
        if (try pages.appendResponse(
            alloc,
            tools_response,
            received_at_ms,
            .{},
        )) break;
    }
    var catalog = try pages.finish(alloc);
    defer catalog.deinit(alloc);
    try tool_catalog.install(alloc, server, tool_registry, catalog, used_tool_names, .legacy, null);

    server.legacy_http = initialized.client;
    client_owned = false;
    server.http_next_request_id.store(next_request_id.*, .seq_cst);
    try server_subscriptions.startToolSubscription(alloc, server, attempt_control);
    server.setReady(alloc, operation_control.monotonicMillis(io_mod.getIo()));
}

pub fn connectServerSse(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *tool_names.Registry,
    control: ConnectionControl,
) !void {
    errdefer {
        server.tool_catalog.deinit(alloc);
    }
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    try connection_control.check(io_mod.getIo(), attempt_control);
    const deadline = attempt_control.deadline.?;
    {
        try lockMutexUntil(&server.auth_lock, deadline, attempt_control.cancel_flag);
        defer server.auth_lock.unlock(io_mod.getIo());
        try server_auth.refreshResolvedHeaders(alloc, server);
    }
    var startup_auth_challenge: ?[]u8 = null;
    defer if (startup_auth_challenge) |value| alloc.free(value);
    const client = legacy_http_sse.Client.create(
        alloc,
        std.heap.c_allocator,
        try server.config.remoteUrl(),
        server.resolved_headers,
        mcp_discovery_response_frame_cap_bytes,
        .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
        &startup_auth_challenge,
    ) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try server_auth.captureAuthHeader(
                alloc,
                server,
                startup_auth_challenge,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };
    var client_owned = true;
    defer if (client_owned) client.deinit();

    var next_request_id: u64 = 1;
    const init_id = next_request_id;
    next_request_id += 1;
    const init_request = try buildLegacyInitializeRequest(
        alloc,
        init_id,
        legacy_http_sse.protocol_version,
        null,
        .{},
    );
    defer alloc.free(init_request);
    const init_response = client.request(
        alloc,
        init_id,
        init_request,
        mcp_discovery_response_frame_cap_bytes,
        .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
    ) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try server_auth.captureLegacySseAuth(
                alloc,
                server,
                client,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };
    defer alloc.free(init_response);
    try legacy_http_sse.validateInitializeResponse(alloc, init_response);
    server.negotiated_protocol_version = legacy_http_sse.protocol_version;
    const initialized_capabilities = try parseServerCapabilitiesFromResponse(
        alloc,
        init_response,
    );
    server.tools_list_changed = initialized_capabilities.tools_list_changed;
    server.capabilities = initialized_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, init_response);
    try parseAndStoreServerInstructionsForProtocol(
        alloc,
        server,
        init_response,
        .legacy,
    );
    client.sendNotification(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}",
        .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
    ) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try server_auth.captureLegacySseAuth(
                alloc,
                server,
                client,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };

    var pages = tools_feature.CatalogBuilder.init(alloc, .legacy);
    defer pages.deinit(alloc);
    while (true) {
        const tools_id = next_request_id;
        next_request_id = std.math.add(u64, tools_id, 1) catch
            return error.McpRequestIdExhausted;
        const tools_request = try buildToolsListRequest(alloc, tools_id, .legacy, pages.next_cursor);
        defer alloc.free(tools_request);
        const tools_response = client.request(
            alloc,
            tools_id,
            tools_request,
            mcp_discovery_response_frame_cap_bytes,
            .{
                .deadline = deadline,
                .cancel_flag = attempt_control.cancel_flag,
                .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
            },
        ) catch |err| {
            if (err == error.McpAuthenticationRequired) {
                try server_auth.captureLegacySseAuth(
                    alloc,
                    server,
                    client,
                    .{
                        .deadline = deadline,
                        .cancel_flag = attempt_control.cancel_flag,
                        .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                    },
                );
            }
            return err;
        };
        const received_at_ms = operation_control.monotonicMillis(io_mod.getIo());
        defer alloc.free(tools_response);
        if (try pages.appendResponse(
            alloc,
            tools_response,
            received_at_ms,
            .{},
        )) break;
    }
    var catalog = try pages.finish(alloc);
    defer catalog.deinit(alloc);
    try tool_catalog.install(alloc, server, tool_registry, catalog, used_tool_names, .legacy, null);

    server.legacy_sse = client;
    client_owned = false;
    server.http_next_request_id.store(next_request_id, .seq_cst);
    try server_subscriptions.startToolSubscription(alloc, server, attempt_control);
    server.setReady(alloc, operation_control.monotonicMillis(io_mod.getIo()));
}

fn connectServerLegacy(
    alloc: Allocator,
    server: *McpServer,
    argv: []const []const u8,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *tool_names.Registry,
    control: ConnectionControl,
    initial_version: LegacyStdioVersion,
) !void {
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    var offered_version = initial_version;
    const initialized: LegacyInitializeSuccess = while (true) {
        server.disconnectForced();
        try connection_control.check(io_mod.getIo(), attempt_control);
        try spawnStdioServer(alloc, server, argv);
        server.stdio_protocol = .legacy;

        const dispatcher = server.dispatcher.?;
        const init_id = try dispatcher.reserveRequestId();
        const init_request = try buildLegacyInitializeRequest(
            alloc,
            init_id,
            offered_version.string(),
            offered_version.wire(),
            server.elicitation_capabilities,
        );
        defer alloc.free(init_request);

        const init_response = dispatcher.request(
            alloc,
            init_id,
            init_request,
            mcp_discovery_response_frame_cap_bytes,
            .{
                .timeout_ms = server.config.startup_timeout_ms,
                .deadline = attempt_control.deadline,
                .cancel_flag = attempt_control.cancel_flag,
                .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                .send_cancellation = false,
            },
        ) catch |err| switch (err) {
            error.McpConnectionClosed => switch (decideLegacyInitializeTransition(
                offered_version,
                .connection_closed,
            )) {
                .retry => |next_version| {
                    offered_version = next_version;
                    continue;
                },
                .accept => unreachable,
                .fail => {
                    server.state.store(.failed, .release);
                    return error.McpInitFailed;
                },
            },
            error.Cancelled, error.McpRequestTimedOut => {
                server.state.store(.failed, .release);
                return err;
            },
            else => {
                server.state.store(.failed, .release);
                return error.McpInitFailed;
            },
        };

        const observation = observation: {
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, init_response, .{}) catch {
                alloc.free(init_response);
                return error.McpInvalidJson;
            };
            defer parsed.deinit();
            break :observation classifyLegacyInitializeResponse(
                parsed.value,
                offered_version,
            ) catch |err| {
                alloc.free(init_response);
                return err;
            };
        };
        switch (decideLegacyInitializeTransition(offered_version, observation)) {
            .accept => |negotiated_version| break .{
                .owned_response = init_response,
                .version = negotiated_version,
            },
            .retry => |next_version| {
                alloc.free(init_response);
                offered_version = next_version;
                continue;
            },
            .fail => {
                alloc.free(init_response);
                server.state.store(.failed, .release);
                return error.McpUnsupportedProtocolVersion;
            },
        }
    };
    defer alloc.free(initialized.owned_response);
    server.negotiated_protocol_version = initialized.version.string();
    const initialized_capabilities = try parseServerCapabilitiesFromResponse(
        alloc,
        initialized.owned_response,
    );
    server.tools_list_changed = initialized_capabilities.tools_list_changed;
    server.capabilities = initialized_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, initialized.owned_response);
    try parseAndStoreServerInstructions(alloc, server, initialized.owned_response);

    const dispatcher = server.dispatcher.?;
    const initialized_notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
    try dispatcher.sendNotificationWithLifecycleControl(
        initialized_notification,
        server.config.startup_timeout_ms,
        attempt_control.deadline,
        attempt_control.cancel_flag,
        attempt_control.lifecycle_cancel_flag,
    );

    try discoverServerTools(
        alloc,
        server,
        tool_registry,
        used_tool_names,
        .legacy,
        attempt_control,
    );
}

fn connectionAttemptControl(control: ConnectionControl, configured_timeout_ms: u32) ConnectionControl {
    return control.startAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), configured_timeout_ms);
}

fn spawnStdioServer(alloc: Allocator, server: *McpServer, argv: []const []const u8) !void {
    const generation = allocateGeneration();
    var prepared = try docker_run.prepare(alloc, argv);
    defer prepared.deinit(alloc);
    var docker_cleanup = prepared.takeCleanup();
    defer if (docker_cleanup) |*cleanup| cleanup.deinit(alloc);
    if (docker_cleanup) |*cleanup| {
        if (server.env_map) |*environment| {
            try cleanup.cloneEnvironment(alloc, environment);
        }
    }
    const child = try std.process.spawn(io_mod.getIo(), .{
        .argv = prepared.argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = if (server.env_map != null) &server.env_map.? else null,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });

    server.dispatcher = stdio_dispatcher.StdioDispatcher.create(
        alloc,
        std.heap.c_allocator,
        child,
        generation,
        mcp_discovery_response_frame_cap_bytes,
    ) catch |err| {
        if (docker_cleanup) |*cleanup| cleanup.run(alloc);
        return err;
    };
    if (docker_cleanup) |cleanup| {
        server.dispatcher.?.installDockerCleanup(cleanup);
        docker_cleanup = null;
    }
}

fn discoverServerTools(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *tool_names.Registry,
    protocol: StdioProtocol,
    control: ConnectionControl,
) !void {
    const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
    var pages = tools_feature.CatalogBuilder.init(alloc, featureProtocol(protocol));
    defer pages.deinit(alloc);
    while (true) {
        const request_id = try dispatcher.reserveRequestId();
        const tools_request = try buildToolsListRequest(alloc, request_id, protocol, pages.next_cursor);
        defer alloc.free(tools_request);
        const tools_response = dispatcher.request(
            alloc,
            request_id,
            tools_request,
            mcp_discovery_response_frame_cap_bytes,
            .{
                .timeout_ms = server.config.startup_timeout_ms,
                .deadline = control.deadline,
                .cancel_flag = control.cancel_flag,
                .lifecycle_cancel_flag = control.lifecycle_cancel_flag,
                .send_cancellation = false,
            },
        ) catch |err| {
            server.state.store(.failed, .release);
            return switch (err) {
                error.Cancelled, error.McpRequestTimedOut => err,
                else => error.McpToolDiscoveryFailed,
            };
        };
        const received_at_ms = operation_control.monotonicMillis(io_mod.getIo());
        defer alloc.free(tools_response);
        if (try pages.appendResponse(
            alloc,
            tools_response,
            received_at_ms,
            .{},
        )) break;
    }
    var catalog = try pages.finish(alloc);
    defer catalog.deinit(alloc);
    try tool_catalog.install(alloc, server, tool_registry, catalog, used_tool_names, protocol, null);
    try server_subscriptions.startToolSubscription(alloc, server, control);
    server.setReady(alloc, operation_control.monotonicMillis(io_mod.getIo()));
}

fn parseAndStoreServerIdentity(
    alloc: Allocator,
    server: *McpServer,
    response: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch
        return error.McpInvalidJson;
    defer parsed.deinit();
    const identity = try parseServerIdentity(parsed.value);
    const name = if (identity.name) |value| try alloc.dupe(u8, value) else null;
    errdefer if (name) |value| alloc.free(value);
    const version = if (identity.version) |value| try alloc.dupe(u8, value) else null;
    if (server.negotiated_server_name) |old| alloc.free(old);
    if (server.negotiated_server_version) |old| alloc.free(old);
    server.negotiated_server_name = name;
    server.negotiated_server_version = version;
}

pub fn parseAndStoreServerInstructions(alloc: Allocator, server: *McpServer, response: []const u8) !void {
    return parseAndStoreServerInstructionsForProtocol(alloc, server, response, .legacy);
}

fn parseAndStoreServerInstructionsForProtocol(
    alloc: Allocator,
    server: *McpServer,
    response: []const u8,
    protocol: StdioProtocol,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch return error.McpInvalidJson;
    defer parsed.deinit();

    const payload = try classifyResponsePayload(parsed.value, protocol);
    const result = switch (payload) {
        .complete => |value| value,
        .protocol_error => |protocol_error| {
            const diagnostic = try tool_result.format_protocol_error(alloc, protocol_error);
            defer alloc.free(diagnostic);
            server.setFailed(alloc, diagnostic);
            return error.McpProtocolError;
        },
    };
    const instructions_value = result.object.get("instructions") orelse return;
    if (instructions_value != .string) return;

    const owned = try sanitizeServerInstructionsAlloc(alloc, instructions_value.string);
    errdefer alloc.free(owned);
    if (owned.len == 0) {
        alloc.free(owned);
        return;
    }

    if (server.instructions) |old| alloc.free(old);
    server.instructions = owned;
}

fn sanitizeServerInstructionsAlloc(alloc: Allocator, text: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const safe = try text_utils.sanitizeModelText(arena, text);
    const masked = try text_utils.maskSecrets(arena, safe);
    const trimmed = std.mem.trim(u8, masked, " \t\r\n");
    return try alloc.dupe(u8, trimmed);
}

const LegacyInitializeSuccess = struct {
    owned_response: []u8,
    version: LegacyStdioVersion,
};

fn connectServerBounded(
    alloc: Allocator,
    tool_registry: tool_dispatch.Registry,
    server: *McpServer,
    used_tool_names: *tool_names.Registry,
    control: ConnectionControl,
) !void {
    while (true) {
        connectServer(
            alloc,
            server,
            tool_registry,
            used_tool_names,
            control,
        ) catch |err| {
            server.tool_catalog.deinit(alloc);
            server.disconnect();
            if (server.restart_attempts >= server.config.restart_limit) return err;
            server.restart_attempts += 1;
            debug_trace.logf(
                "mcp",
                "restarting stdio server after startup failure server={s} attempt={d} err={s}",
                .{ server.config.name, server.restart_attempts, @errorName(err) },
            );
            continue;
        };
        return;
    }
}

pub fn start(
    alloc: Allocator,
    tool_registry: tool_dispatch.Registry,
    server: *McpServer,
    used_tool_names: *tool_names.Registry,
    control: ConnectionControl,
) !void {
    server_auth.loadStoredCredentials(alloc, server, control) catch |err| {
        if (err == error.Cancelled) return err;
        debug_trace.logf(
            "mcp",
            "credential load failed server={s} err={s}",
            .{ server.config.name, @errorName(err) },
        );
        server.setFailed(
            alloc,
            "Stored MCP credentials could not be read securely.",
        );
        return err;
    };
    return if (server.config.transport == .stdio)
        connectServerBounded(alloc, tool_registry, server, used_tool_names, control)
    else
        connectServer(
            alloc,
            server,
            tool_registry,
            used_tool_names,
            control,
        );
}
