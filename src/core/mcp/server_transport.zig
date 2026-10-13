const std = @import("std");
const server_connection = @import("server_connection.zig");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const server_auth = @import("server_auth.zig");
const server_subscriptions = @import("server_subscriptions.zig");
const text_utils = @import("../shared/text_utils.zig");
const display_width = @import("../shared/display_width.zig");
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
    // Fallbacks keep the caller's deadline and report this operation's span.
    const operation = control.withStartupSpan(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        server.config.startup_timeout_ms,
    );
    const attempt_control = connectionAttemptControl(
        operation,
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
    errdefer {
        publishRejectedOutput(alloc, server);
        server.disconnectForced();
    }

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
            try connection_control.check(io_mod.getIo(), operation);
            return connectServerLegacy(
                alloc,
                server,
                argv.items,
                tool_registry,
                used_tool_names,
                operation,
                .v2024_11_05,
            ) catch |legacy_err| {
                // The discovery launch stayed up, so not every launch ended
                // on its own and a restart could still help.
                if (err == error.McpRequestTimedOut and legacy_err == error.McpServerExitedDuringStartup) {
                    return error.McpInitFailed;
                }
                return legacy_err;
            };
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
            operation,
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
    // Host-channel servers support only the modern stateless protocol.
    const host_channel = server.config.acp_server_id != null;
    if (!host_channel and try protocol_negotiation.startupMode(server.config.env, io_mod.getenv(protocol_negotiation.protocol_version_environment)) == .legacy) {
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
    const discovery = try classifyHttpDiscoveryResponse(parsed_discover.value);
    if (host_channel and discovery != .modern) {
        server.setFailed(
            alloc,
            "MCP server does not support protocol version " ++ modern_protocol_version,
        );
        return error.McpUnsupportedProtocolVersion;
    }
    switch (discovery) {
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
    // A cancelled connection starts no further round trips, so it leaves the
    // session for the server to expire instead of sending a DELETE while the
    // connection lock is still held.
    errdefer if (client_owned) {
        if (attempt_control.cancellation().cancelled()) {
            initialized.client.deinitWithoutSessionTermination();
        } else {
            initialized.client.deinit();
        }
    };
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
    // startAt always fixes the span.
    const span_ms = attempt_control.startup_span_ms.?;
    // Runs before callers disconnect, while the latest launch is attached.
    errdefer publishRejectedOutput(alloc, server);
    var offered_version = initial_version;
    var last_exit: stdio_dispatcher.ChildDiagnostics = undefined;
    var last_exit_ptr: ?*const stdio_dispatcher.ChildDiagnostics = null;
    const initialized: LegacyInitializeSuccess = while (true) {
        last_exit_ptr = rememberChildExit(server, &last_exit) orelse last_exit_ptr;
        server.disconnectForced();
        connection_control.check(io_mod.getIo(), attempt_control) catch |err| {
            // The deadline passed between launches; keep the exit that used it up.
            if (err == error.McpRequestTimedOut) publishStartupTimeout(
                alloc,
                server,
                startupTimeoutLimit(span_ms, server.config.startup_timeout_ms, true),
                last_exit_ptr,
                null,
            );
            return err;
        };
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
                    last_exit_ptr = rememberChildExit(server, &last_exit) orelse last_exit_ptr;
                    server.state.store(.failed, .release);
                    publishStartupFailure(alloc, server, .{
                        .closed = last_exit_ptr,
                    });
                    return error.McpServerExitedDuringStartup;
                },
            },
            error.McpRequestTimedOut => {
                server.state.store(.failed, .release);
                publishStartupTimeout(
                    alloc,
                    server,
                    startupTimeoutLimit(
                        span_ms,
                        server.config.startup_timeout_ms,
                        startupDeadlineSpent(attempt_control),
                    ),
                    last_exit_ptr,
                    dispatcher,
                );
                return err;
            },
            error.Cancelled => {
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
    // Process exit waits for this launch to register its child, including any
    // docker cleanup, before it kills every child.
    try stdio_dispatcher.beginChildLaunch();
    defer stdio_dispatcher.endChildLaunch();
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
        .stderr = if (builtin.target.os.tag == .windows) .ignore else .pipe,
        .environ_map = if (server.env_map != null) &server.env_map.? else null,
        .cwd = if (server.config.cwd) |cwd| .{ .path = cwd } else .inherit,
        .pgid = if (builtin.target.os.tag == .windows) null else 0,
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
    const trimmed = std.mem.trim(u8, safe, " \t\r\n");
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
    const operation = control.withStartupSpan(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        server.config.startup_timeout_ms,
    );
    while (true) {
        connectServer(
            alloc,
            server,
            tool_registry,
            used_tool_names,
            operation,
        ) catch |err| {
            server.tool_catalog.deinit(alloc);
            // A cancelled startup has no session state to flush; kill the
            // child immediately so shutdown cannot stall in grace windows.
            // Cancellation is the owner stopping this connection, not a
            // startup failure, so it never earns a restart.
            if (err == error.Cancelled) {
                server.disconnectImmediate();
                return err;
            }
            if (err == error.McpRequestTimedOut) {
                publishStartupTimeout(
                    alloc,
                    server,
                    startupTimeoutLimit(
                        // withStartupSpan always fixes the span.
                        operation.startup_span_ms.?,
                        server.config.startup_timeout_ms,
                        startupDeadlineSpent(operation),
                    ),
                    null,
                    server.dispatcher,
                );
            }
            server.disconnect();
            const decision = decideStartupRestart(.{
                .attempts = server.restart_attempts,
                .limit = server.config.restart_limit,
                .deadline_spent = startupDeadlineSpent(operation),
                .child_exited = err == error.McpServerExitedDuringStartup,
            });
            switch (decision) {
                .restart => {},
                .stop_limit => return err,
                .stop_deadline_spent, .stop_child_exited => {
                    debug_trace.logf(
                        "mcp",
                        "skipping stdio startup restart server={s} reason={s} err={s}",
                        .{ server.config.name, @tagName(decision), @errorName(err) },
                    );
                    return err;
                },
            }
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

fn rememberChildExit(
    server: *McpServer,
    last_exit: *stdio_dispatcher.ChildDiagnostics,
) ?*const stdio_dispatcher.ChildDiagnostics {
    const dispatcher = server.dispatcher orelse return null;
    const diagnostics = dispatcher.childDiagnostics();
    if (diagnostics.term == null) return null;
    last_exit.* = diagnostics;
    return last_exit;
}

fn startupDeadlineSpent(control: ConnectionControl) bool {
    connection_control.check(io_mod.getIo(), control) catch |err| return err == error.McpRequestTimedOut;
    return false;
}

const StartupRestartInput = struct {
    attempts: u8,
    limit: u8,
    deadline_spent: bool,
    /// The server closed its connection at every protocol version the
    /// ladder offered, so each of those launches already ended.
    child_exited: bool,
};

const StartupRestartDecision = enum {
    restart,
    stop_limit,
    stop_deadline_spent,
    stop_child_exited,
};

/// Restart only when a new launch has budget and could behave differently:
/// the shared deadline cannot be extended, and a child that exited at every
/// offered protocol version has already been relaunched by the ladder.
fn decideStartupRestart(input: StartupRestartInput) StartupRestartDecision {
    if (input.attempts >= input.limit) return .stop_limit;
    if (input.deadline_spent) return .stop_deadline_spent;
    if (input.child_exited) return .stop_child_exited;
    return .restart;
}

const StartupFailure = union(enum) {
    /// The server closed its connection at every offered protocol version.
    closed: ?*const stdio_dispatcher.ChildDiagnostics,
    timed_out: struct {
        limit: TimeoutLimit,
        /// An earlier launch in this startup that exited.
        earlier_exit: ?*const stdio_dispatcher.ChildDiagnostics,
        /// The launch that was still running at the deadline.
        live: ?*const stdio_dispatcher.ChildDiagnostics,
    },
    /// fx ended the connection on stdout output that is not an MCP message.
    rejected_output: struct {
        line: *const stdio_dispatcher.RejectedOutput,
        stderr: *const stdio_dispatcher.StderrCapture,
    },
};

/// Publishes the stdout line fx rejected, if the current launch left one.
/// Other failures return without waiting for the child's diagnostics.
fn publishRejectedOutput(alloc: Allocator, server: *McpServer) void {
    const dispatcher = server.dispatcher orelse return;
    if (!dispatcher.hasRejectedOutput()) return;
    const diagnostics = dispatcher.childDiagnostics();
    if (diagnostics.rejected_output) |*line| {
        publishStartupFailure(alloc, server, .{ .rejected_output = .{ .line = line, .stderr = &diagnostics.stderr } });
    }
}

const TimeoutLimit = struct {
    ms: u32,
    /// True when `startup_timeout_ms` set this limit.
    names_setting: bool,
};

/// Names the limit a startup timeout ran into. Each startup request is capped
/// by `startup_timeout_ms`, and the whole operation ends at its deadline,
/// which a caller such as a tool call may set to a different span.
fn startupTimeoutLimit(span_ms: u32, configured_ms: u32, deadline_spent: bool) TimeoutLimit {
    if (!deadline_spent) return .{ .ms = configured_ms, .names_setting = true };
    return .{ .ms = span_ms, .names_setting = span_ms == configured_ms };
}

fn publishStartupTimeout(
    alloc: Allocator,
    server: *McpServer,
    limit: TimeoutLimit,
    earlier_exit: ?*const stdio_dispatcher.ChildDiagnostics,
    live_dispatcher: ?*stdio_dispatcher.StdioDispatcher,
) void {
    if (server.last_error != null) return;
    var live_diagnostics: stdio_dispatcher.ChildDiagnostics = undefined;
    var live: ?*const stdio_dispatcher.ChildDiagnostics = null;
    if (earlier_exit == null) {
        if (live_dispatcher) |dispatcher| {
            live_diagnostics = dispatcher.childDiagnostics();
            live = &live_diagnostics;
        }
    }
    publishStartupFailure(alloc, server, .{ .timed_out = .{
        .limit = limit,
        .earlier_exit = earlier_exit,
        .live = live,
    } });
}

/// Publishes a startup failure description unless a more specific one is set.
fn publishStartupFailure(alloc: Allocator, server: *McpServer, failure: StartupFailure) void {
    if (server.last_error != null) return;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const message = formatStartupFailure(arena_state.allocator(), failure) catch |err| {
        debug_trace.logf(
            "mcp",
            "startup failure message unavailable server={s} err={s}",
            .{ server.config.name, @errorName(err) },
        );
        return;
    };
    server.setFailed(alloc, message);
}

const stderr_display_bytes: usize = 400;

fn formatStartupFailure(arena: Allocator, failure: StartupFailure) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    switch (failure) {
        .closed => |diagnostics| {
            try writer.writeAll("MCP server ");
            try writeTermPhrase(writer, if (diagnostics) |value| value.term else null);
            try writer.writeAll(" before completing startup");
            if (diagnostics) |value| try writeStderrSuffix(arena, writer, &value.stderr);
        },
        .timed_out => |timeout| {
            try writer.print("MCP server did not complete startup within {d} ms", .{timeout.limit.ms});
            if (timeout.limit.names_setting) try writer.writeAll(" (startup_timeout_ms)");
            if (timeout.earlier_exit) |value| {
                try writer.writeAll("; an earlier launch ");
                try writeTermPhrase(writer, value.term);
                try writeStderrSuffix(arena, writer, &value.stderr);
            } else if (timeout.live) |value| {
                const text = try displayStderr(arena, &value.stderr);
                if (text.len > 0) try writer.print("; last stderr: {s}", .{text});
            }
        },
        .rejected_output => |rejected| {
            try writer.writeAll("MCP server wrote output that is not an MCP message before completing startup");
            var line = try withoutAnsi(arena, rejected.line.slice());
            // A secret cut at the capture limit is too short to be masked.
            if (rejected.line.truncated) line = withoutTrailingWord(line);
            const text = try displayPlain(arena, line);
            if (text.len > 0) try writer.print(": {s}", .{text});
            const stderr_text = try displayStderr(arena, rejected.stderr);
            if (stderr_text.len > 0) try writer.print("; stderr: {s}", .{stderr_text});
        },
    }
    return try out.toOwnedSlice();
}

fn writeTermPhrase(writer: *std.Io.Writer, term: ?std.process.Child.Term) !void {
    const value = term orelse return writer.writeAll("closed its connection");
    switch (value) {
        .exited => |code| try writer.print("exited with code {d}", .{code}),
        .signal => |signal| try writeSignalPhrase(writer, "was killed by", signal),
        .stopped => |signal| try writeSignalPhrase(writer, "was stopped by", signal),
        .unknown => |status| try writer.print("ended with status {d}", .{status}),
    }
}

/// Targets without POSIX signals, such as WASI, carry no signal number.
fn writeSignalPhrase(writer: *std.Io.Writer, verb: []const u8, signal: anytype) !void {
    if (@TypeOf(signal) == void) {
        try writer.print("{s} a signal", .{verb});
    } else {
        try writer.print("{s} signal {d}", .{ verb, @backingInt(signal) });
    }
}

fn writeStderrSuffix(
    arena: Allocator,
    writer: *std.Io.Writer,
    capture: *const stdio_dispatcher.StderrCapture,
) !void {
    const text = try displayStderr(arena, capture);
    if (text.len == 0) return;
    try writer.writeAll(": ");
    try writer.writeAll(text);
}

fn displayStderr(arena: Allocator, capture: *const stdio_dispatcher.StderrCapture) ![]const u8 {
    if (!capture.omitted) {
        return displayPlain(arena, try withoutAnsi(arena, try std.mem.concat(arena, u8, &.{ capture.headSlice(), capture.tailSlice() })));
    }
    // Strip each side on its own so an escape sequence cut at the gap cannot
    // swallow the start of the tail. Then drop the words cut by the gap: a
    // secret split there is too short to be masked. Cutting at ASCII
    // whitespace also starts the tail on a UTF-8 boundary.
    const joined = try std.mem.concat(arena, u8, &.{
        withoutTrailingWord(try withoutAnsi(arena, capture.headSlice())),
        " ... ",
        withoutLeadingWord(try withoutAnsi(arena, capture.tailSlice())),
    });
    return displayPlain(arena, joined);
}

/// Server output is untrusted. Turns text with ANSI sequences already
/// removed into one terminal-safe line: secrets masked, whitespace collapsed
/// and remaining control or non-printing characters escaped by the shared
/// encoder, and the result bounded head-and-tail.
fn displayPlain(arena: Allocator, plain: []const u8) ![]const u8 {
    const masked = try text_utils.maskSecrets(arena, plain);
    const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, std.math.maxInt(usize));
    var out: std.Io.Writer.Allocating = .init(arena);
    try text_utils.writeHeadTailBounded(&out.writer, encoded.bytes, stderr_display_bytes, " ... ", .down);
    return try out.toOwnedSlice();
}

const word_separators = " \t\r\n";

fn withoutTrailingWord(bytes: []const u8) []const u8 {
    const end = std.mem.findLastAny(u8, bytes, word_separators) orelse return "";
    return bytes[0 .. end + 1];
}

fn withoutLeadingWord(bytes: []const u8) []const u8 {
    const first_separator = std.mem.findAny(u8, bytes, word_separators) orelse return "";
    return bytes[first_separator..];
}

fn withoutAnsi(arena: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < raw.len) {
        const escape = std.mem.findScalarPos(u8, raw, index, 0x1b) orelse raw.len;
        try out.appendSlice(arena, raw[index..escape]);
        if (escape == raw.len) break;
        index = display_width.ansiSequenceEnd(raw, escape);
    }
    return out.items;
}

test "startup restart runs only with budget left and a failure a relaunch could change" {
    for ([_]bool{ false, true }) |deadline_spent| {
        for ([_]bool{ false, true }) |child_exited| {
            for ([_]u8{ 0, 1, 2 }) |attempts| {
                for ([_]u8{ 0, 1, 2 }) |limit| {
                    const decision = decideStartupRestart(.{
                        .attempts = attempts,
                        .limit = limit,
                        .deadline_spent = deadline_spent,
                        .child_exited = child_exited,
                    });
                    const expect_restart = attempts < limit and !deadline_spent and !child_exited;
                    try std.testing.expectEqual(expect_restart, decision == .restart);
                }
            }
        }
    }
}

/// A capture whose middle was dropped, with the given head and tail.
fn testOmittedCapture(head: []const u8, tail: []const u8) stdio_dispatcher.StderrCapture {
    var capture: stdio_dispatcher.StderrCapture = .{ .omitted = true };
    @memcpy(capture.head[0..head.len], head);
    capture.head_len = head.len;
    @memcpy(capture.tail[0..tail.len], tail);
    capture.tail_len = tail.len;
    return capture;
}

fn testDiagnostics(term: ?std.process.Child.Term, stderr: []const u8) stdio_dispatcher.ChildDiagnostics {
    var diagnostics: stdio_dispatcher.ChildDiagnostics = .{ .term = term };
    diagnostics.stderr.append(stderr);
    return diagnostics;
}

test "startup failure names how the server ended and its cleaned stderr" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exited = testDiagnostics(
        .{ .exited = 1 },
        "npm error code E401\n\x1b[31mnpm error\x1b[0m Incorrect or missing password.\n",
    );
    try std.testing.expectEqualStrings(
        "MCP server exited with code 1 before completing startup: npm error code E401 npm error Incorrect or missing password.",
        try formatStartupFailure(arena, .{ .closed = &exited }),
    );
    const killed = testDiagnostics(.{ .signal = .KILL }, "");
    try std.testing.expectEqualStrings(
        "MCP server was killed by signal 9 before completing startup",
        try formatStartupFailure(arena, .{ .closed = &killed }),
    );
    try std.testing.expectEqualStrings(
        "MCP server closed its connection before completing startup",
        try formatStartupFailure(arena, .{ .closed = null }),
    );
}

test "startup failure shows the stdout line fx rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stderr = testDiagnostics(null, "loading config\n").stderr;
    const banner = testRejectedOutput("\x1b[32mServer started\x1b[0m on stdio\x07");
    try std.testing.expectEqualStrings(
        "MCP server wrote output that is not an MCP message before completing startup: Server started on stdio\\x07; stderr: loading config",
        try formatStartupFailure(arena, .{ .rejected_output = .{ .line = &banner, .stderr = &stderr } }),
    );
    const silent: stdio_dispatcher.StderrCapture = .{};
    const blank = testRejectedOutput("");
    try std.testing.expectEqualStrings(
        "MCP server wrote output that is not an MCP message before completing startup",
        try formatStartupFailure(arena, .{ .rejected_output = .{ .line = &blank, .stderr = &silent } }),
    );
    // A secret cut at the capture limit is dropped rather than shown in part.
    var cut = testRejectedOutput("token=abcdefghijklmnop");
    cut.truncated = true;
    try std.testing.expectEqualStrings(
        "MCP server wrote output that is not an MCP message before completing startup",
        try formatStartupFailure(arena, .{ .rejected_output = .{ .line = &cut, .stderr = &silent } }),
    );
}

fn testRejectedOutput(line: []const u8) stdio_dispatcher.RejectedOutput {
    var rejected: stdio_dispatcher.RejectedOutput = .{ .len = line.len };
    @memcpy(rejected.bytes[0..line.len], line);
    return rejected;
}

test "startup timeout names its limit and the most useful stderr" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const live = testDiagnostics(null, "downloading chrome-devtools-mcp\n");
    try std.testing.expectEqualStrings(
        "MCP server did not complete startup within 10000 ms (startup_timeout_ms); last stderr: downloading chrome-devtools-mcp",
        try formatStartupFailure(arena, .{ .timed_out = .{ .limit = .{ .ms = 10_000, .names_setting = true }, .earlier_exit = null, .live = &live } }),
    );
    const earlier = testDiagnostics(.{ .exited = 2 }, "boom\n");
    try std.testing.expectEqualStrings(
        "MCP server did not complete startup within 30000 ms (startup_timeout_ms); an earlier launch exited with code 2: boom",
        try formatStartupFailure(arena, .{ .timed_out = .{ .limit = .{ .ms = 30_000, .names_setting = true }, .earlier_exit = &earlier, .live = &live } }),
    );
    const silent = testDiagnostics(null, "");
    try std.testing.expectEqualStrings(
        "MCP server did not complete startup within 50 ms (startup_timeout_ms)",
        try formatStartupFailure(arena, .{ .timed_out = .{ .limit = .{ .ms = 50, .names_setting = true }, .earlier_exit = null, .live = &silent } }),
    );
    const blank = testDiagnostics(null, "\n\r\x1b[2K\n");
    try std.testing.expectEqualStrings(
        "MCP server did not complete startup within 50 ms (startup_timeout_ms)",
        try formatStartupFailure(arena, .{ .timed_out = .{ .limit = .{ .ms = 50, .names_setting = true }, .earlier_exit = null, .live = &blank } }),
    );
    // A shorter caller deadline set the limit, so the setting is not named.
    try std.testing.expectEqualStrings(
        "MCP server did not complete startup within 12345 ms",
        try formatStartupFailure(arena, .{ .timed_out = .{ .limit = .{ .ms = 12_345, .names_setting = false }, .earlier_exit = null, .live = &silent } }),
    );
}

test "startup timeout names the limit that ran out" {
    // An ordinary startup: the deadline and the request cap are the same limit.
    try expectTimeoutLimit(.{ .ms = 30_000, .names_setting = true }, startupTimeoutLimit(30_000, 30_000, true));
    try expectTimeoutLimit(.{ .ms = 30_000, .names_setting = true }, startupTimeoutLimit(30_000, 30_000, false));
    // A crash-recovery relaunch keeps the tool call's longer deadline, so a
    // hung request is stopped by the configured cap first.
    try expectTimeoutLimit(.{ .ms = 30_000, .names_setting = true }, startupTimeoutLimit(60_000, 30_000, false));
    // Slow exits used up the tool call's deadline instead.
    try expectTimeoutLimit(.{ .ms = 60_000, .names_setting = false }, startupTimeoutLimit(60_000, 30_000, true));
    // A shorter caller deadline ran out before the configured cap.
    try expectTimeoutLimit(.{ .ms = 2_000, .names_setting = false }, startupTimeoutLimit(2_000, 30_000, true));
}

fn expectTimeoutLimit(expected: TimeoutLimit, actual: TimeoutLimit) !void {
    try std.testing.expectEqual(expected.ms, actual.ms);
    try std.testing.expectEqual(expected.names_setting, actual.names_setting);
}

test "server stderr display keeps the first line and the end, bounded and masked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var big: std.ArrayList(u8) = .empty;
    try big.appendSlice(arena, "FIRST-LINE TypeError: boom\n");
    for (0..400) |index| try big.print(arena, "    at frame {d} (loader.js:{d})\n", .{ index, index });
    try big.appendSlice(arena, "LAST-LINE exit\n");
    var capture: stdio_dispatcher.StderrCapture = .{};
    capture.append(big.items);
    try std.testing.expect(capture.omitted);
    const bounded = try displayStderr(arena, &capture);
    try std.testing.expect(bounded.len <= stderr_display_bytes);
    try std.testing.expect(std.mem.startsWith(u8, bounded, "FIRST-LINE TypeError: boom"));
    try std.testing.expect(std.mem.endsWith(u8, bounded, "LAST-LINE exit"));
    for (bounded) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);

    var secret: stdio_dispatcher.StderrCapture = .{};
    secret.append("auth failed: Bearer abcdefghijklmnopqrstuvwxyz\n");
    const masked = try displayStderr(arena, &secret);
    try std.testing.expect(std.mem.find(u8, masked, "abcdefghijklmnop") == null);
    try std.testing.expect(std.mem.find(u8, masked, "[redacted]") != null);

    var hostile: stdio_dispatcher.StderrCapture = .{};
    hostile.append("\x98\xa9ok \xff caf\xc3\xa9\x1b]0;title\x07\n\n\t done\x07");
    try std.testing.expectEqualStrings("\\x98\\xa9ok \\xff caf\xc3\xa9 done\\x07", try displayStderr(arena, &hostile));

    // The retained tail starts with the second byte of a cut character.
    var split = testOmittedCapture("head\n", "\xa9 tail");
    try std.testing.expectEqualStrings("head ... tail", try displayStderr(arena, &split));

    // Neither half of a secret cut by the omitted gap is shown.
    var cut_secret = testOmittedCapture("auth failed: Bearer abcdefgh", "ijklmnopqrstuvwxyz rejected\n");
    const cut_display = try displayStderr(arena, &cut_secret);
    try std.testing.expect(std.mem.startsWith(u8, cut_display, "auth failed: Bearer"));
    try std.testing.expect(std.mem.endsWith(u8, cut_display, "rejected"));
    try std.testing.expect(std.mem.find(u8, cut_display, "abcdefgh") == null);
    try std.testing.expect(std.mem.find(u8, cut_display, "ijklmnop") == null);

    // An escape sequence cut at the gap cannot swallow the start of a token.
    const token = "ghp_" ++ text_utils.repeat("a1b2c3d4e5", 4);
    var cut_escape = testOmittedCapture("log line \x1b[ ", "xx " ++ token ++ " rejected\n");
    const escape_display = try displayStderr(arena, &cut_escape);
    try std.testing.expect(std.mem.find(u8, escape_display, token[1..]) == null);
    try std.testing.expect(std.mem.endsWith(u8, escape_display, "rejected"));

    var invisible: stdio_dispatcher.StderrCapture = .{};
    invisible.append("rtl \u{202e}txt\u{200b} nel\u{85}");
    try std.testing.expectEqualStrings("rtl \\u{202e}txt\\u{200b} nel\\u{0085}", try displayStderr(arena, &invisible));

    var blank: stdio_dispatcher.StderrCapture = .{};
    blank.append("\n\r\t\x1b[2K");
    try std.testing.expectEqualStrings("", try displayStderr(arena, &blank));
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
