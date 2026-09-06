const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp_contract = @import("mcp_contract.zig");
const mcp_auth = @import("mcp_auth.zig");
const server_auth = @import("server_auth.zig");
const stdio_dispatcher = @import("stdio_dispatcher.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const legacy_http_sse = @import("legacy_http_sse.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const tools_feature = @import("features/tools.zig");
const operation_authority = @import("operation_authority.zig");
const operation_control = @import("operation_control.zig");
const protocol_messages = @import("protocol_messages.zig");
const Allocator = std.mem.Allocator;
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_names = @import("tool_names.zig");
const streamable_http = @import("streamable_http.zig");
const catalog_state = @import("catalog_state.zig");
const ToolCatalogSnapshot = catalog_state.ToolCatalogSnapshot;
const freeOwnedStrings = mcp_contract.freeOwnedStrings;
const allocateGeneration = @import("server_lifetime.zig").allocateIdentity;
const McpServer = @import("server_connection.zig").Server;
const StdioProtocol = @import("protocol_negotiation.zig").Protocol;
const AuthEffectAccess = operation_authority.EffectAccess;
const ServerAccessPrecommit = operation_authority.SendGuard;
const buildToolsListRequest = protocol_messages.buildToolsListRequest;
const featureProtocol = protocol_messages.featureProtocol;
const mcp_discovery_response_frame_cap_bytes = 1024 * 1024;

const PageResponse = struct {
    body: []u8,
    auth_identity: ?catalog_freshness.Digest = null,

    fn deinit(self: *PageResponse, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const FetchResult = struct {
    catalog: tools_feature.Catalog,
    auth_identity: ?catalog_freshness.Digest = null,

    pub fn deinit(self: *FetchResult, alloc: Allocator) void {
        self.catalog.deinit(alloc);
        self.* = undefined;
    }
};

pub const RequestIds = union(enum) {
    server: *McpServer,
    local: *u64,

    fn next(self: *RequestIds) !u64 {
        return switch (self.*) {
            .server => |server| server.reserveRequestId(),
            .local => |next_request_id| request_id: {
                const request_id = next_request_id.*;
                next_request_id.* = std.math.add(u64, request_id, 1) catch
                    return error.McpRequestIdExhausted;
                break :request_id request_id;
            },
        };
    }
};

pub const Transport = union(enum) {
    stdio: *stdio_dispatcher.StdioDispatcher,
    modern_http: *RequestIds,
    legacy_http: *legacy_streamable_http.Client,
    legacy_sse: *legacy_http_sse.Client,

    fn protocol(self: Transport, server: *const McpServer) StdioProtocol {
        return switch (self) {
            .stdio => server.stdio_protocol,
            .modern_http => .modern,
            .legacy_http, .legacy_sse => .legacy,
        };
    }

    fn next_request_id(self: *Transport, server: *McpServer) !u64 {
        return switch (self.*) {
            .stdio => |dispatcher| dispatcher.reserveRequestId(),
            .modern_http => |request_ids| request_ids.next(),
            .legacy_http, .legacy_sse => server.reserveRequestId(),
        };
    }

    fn request_page(
        self: Transport,
        alloc: Allocator,
        authority: AuthEffectAccess,
        server: *McpServer,
        request_id: u64,
        request: []const u8,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        precommit: *mcp_contract.TransportPrecommit,
    ) !PageResponse {
        return switch (self) {
            .stdio => |dispatcher| .{ .body = try dispatcher.request(
                alloc,
                request_id,
                request,
                mcp_discovery_response_frame_cap_bytes,
                .{
                    .timeout_ms = server.config.operation_timeout_ms,
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = server.cancellation(),
                    .precommit = precommit,
                },
            ) },
            .modern_http => {
                var auth_identity: catalog_freshness.Digest = undefined;
                const response = try server_auth.authenticatedPost(alloc, alloc, server, .{
                    .url = try server.config.remoteUrl(),
                    .request_body = request,
                    .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
                    .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
                    .precommit = precommit,
                    .control = .{
                        .deadline = deadline,
                        .cancel_flag = cancel_flag,
                        .lifecycle_cancel_flag = server.cancellation(),
                    },
                }, authority, .safe, &auth_identity);
                if (response.www_authenticate) |value| alloc.free(value);
                return .{
                    .body = response.body,
                    .auth_identity = auth_identity,
                };
            },
            .legacy_http => |client| .{ .body = try client.request(alloc, .{
                .request_id = request_id,
                .request_body = request,
                .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
                .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
                .precommit = precommit,
                .control = .{
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = server.cancellation(),
                },
            }) },
            .legacy_sse => |client| .{ .body = try client.request(
                alloc,
                request_id,
                request,
                mcp_discovery_response_frame_cap_bytes,
                .{
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = server.cancellation(),
                    .precommit = precommit,
                },
            ) },
        };
    }
};

pub fn fetchCurrent(
    alloc: Allocator,
    authority: AuthEffectAccess,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !FetchResult {
    var request_ids = RequestIds{ .server = server };
    const transport: Transport = switch (server.config.transport) {
        .stdio => .{ .stdio = server.dispatcher orelse return error.McpConnectionClosed },
        .http => if (server.legacy_http) |client| .{ .legacy_http = client } else .{ .modern_http = &request_ids },
        .sse => .{ .legacy_sse = server.legacy_sse orelse return error.McpConnectionClosed },
    };
    const legacy_identity: ?catalog_freshness.Digest = switch (transport) {
        .legacy_http => |client| try server_auth.authIdentityForHeaders(alloc, client.static_headers),
        .legacy_sse => |client| try server_auth.authIdentityForHeaders(alloc, client.static_headers),
        .stdio, .modern_http => null,
    };
    var fetched = try fetch(alloc, authority, server, transport, deadline, cancel_flag);
    if (legacy_identity) |identity| fetched.auth_identity = identity;
    return fetched;
}

fn fetchPages(
    alloc: Allocator,
    authority: AuthEffectAccess,
    server: *McpServer,
    initial_transport: Transport,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !FetchResult {
    var transport = initial_transport;
    const protocol = transport.protocol(server);
    var pages = tools_feature.CatalogBuilder.init(alloc, featureProtocol(protocol));
    defer pages.deinit(alloc);
    var producing_identity: ?catalog_freshness.Digest = null;
    while (true) {
        try authority.authorize();
        const request_id = try transport.next_request_id(server);
        const request = try buildToolsListRequest(alloc, request_id, protocol, pages.next_cursor);
        defer alloc.free(request);
        var guard = ServerAccessPrecommit{
            .authority = authority,
            .cancel_flag = server.cancellation(),
        };
        var precommit = guard.transport();
        var response = try transport.request_page(
            alloc,
            authority,
            server,
            request_id,
            request,
            deadline,
            cancel_flag,
            &precommit,
        );
        const received_at_ms = operation_control.monotonicMillis(io_mod.getIo());
        defer response.deinit(alloc);
        if (response.auth_identity) |page_identity| {
            if (producing_identity) |identity| {
                if (!std.mem.eql(u8, &identity, &page_identity)) {
                    return error.McpAuthIdentityChangedDuringPagination;
                }
            } else {
                producing_identity = page_identity;
            }
        }
        if (try pages.appendResponse(
            alloc,
            response.body,
            received_at_ms,
            .{},
        )) return .{
            .catalog = try pages.finish(alloc),
            .auth_identity = producing_identity,
        };
    }
}

pub fn fetch(
    alloc: Allocator,
    authority: AuthEffectAccess,
    server: *McpServer,
    transport: Transport,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !FetchResult {
    var identity_restarts: u8 = 0;
    while (true) {
        return fetchPages(alloc, authority, server, transport, deadline, cancel_flag) catch |err| switch (err) {
            error.McpAuthIdentityChangedDuringPagination => {
                if (identity_restarts >= mcp_auth.max_scope_reauthorizations) return error.McpAuthenticationRetryLimit;
                identity_restarts += 1;
                debug_trace.logf("mcp", "restarting paginated tool fetch after auth identity change server={s} attempt={d}", .{ server.config.name, identity_restarts });
                continue;
            },
            else => |other| return other,
        };
    }
}

pub fn install(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    protocol_catalog: tools_feature.Catalog,
    used_tool_names: *tool_names.Registry,
    protocol: StdioProtocol,
    source_auth_identity: ?catalog_freshness.Digest,
) !void {
    if (server.tool_catalog.tools.items.len != 0) return error.McpToolCatalogNotEmpty;
    const auth_identity = source_auth_identity orelse try server_auth.currentAuthIdentity(alloc, server);
    var candidate = try prepare(
        alloc,
        server,
        tool_registry,
        protocol_catalog.tools,
        used_tool_names,
        protocol,
    );
    errdefer candidate.deinit(alloc);
    const connection_generation = if (server.dispatcher) |dispatcher| dispatcher.connectionGeneration() else allocateGeneration();
    const catalog_generation = std.math.add(
        u64,
        server.catalog_generation,
        1,
    ) catch return error.McpGenerationExhausted;
    const scope: catalog_freshness.CacheScope = switch (protocol_catalog.cache_scope) {
        .private => .private,
        .public => .public,
    };
    candidate.metadata = .{
        .key = catalog_freshness.authPartition(scope, auth_identity),
        .connection_generation = connection_generation,
        .catalog_generation = catalog_generation,
        .fetched_at_ms = protocol_catalog.fetched_at_ms,
        .expires_at_ms = protocol_catalog.expires_at_ms,
        .scope = scope,
        .content_digest = catalog_state.digestTools(candidate.tools.items),
    };
    candidate.auth_generation = server.auth_generation.load(.acquire);
    server.connection_generation = connection_generation;
    server.catalog_generation = catalog_generation;
    server.tool_catalog = candidate;
    candidate = .{};
}

pub fn prepare(
    alloc: Allocator,
    server: *const McpServer,
    tool_registry: tool_dispatch.Registry,
    protocol_tools: []const tools_feature.Tool,
    used_tool_names: *tool_names.Registry,
    protocol: StdioProtocol,
) !ToolCatalogSnapshot {
    var result: ToolCatalogSnapshot = .{};
    errdefer result.deinit(alloc);
    for (protocol_tools) |protocol_tool| {
        const name = protocol_tool.name;
        const description = if (protocol_tool.description.len > 0)
            protocol_tool.description
        else
            "MCP tool";

        const original_name = try alloc.dupe(u8, name);
        errdefer alloc.free(original_name);

        const prefixed_name = try used_tool_names.name(alloc, tool_registry, server.config.name, name);
        errdefer alloc.free(prefixed_name);

        const owned_description = try alloc.dupe(u8, description);
        errdefer alloc.free(owned_description);

        const input_schema_json = try alloc.dupe(u8, protocol_tool.input_schema_json);
        errdefer alloc.free(input_schema_json);
        if (server.config.transport == .http and protocol == .modern) {
            streamable_http.validateToolInputSchemaHeaders(
                alloc,
                input_schema_json,
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                debug_trace.logf(
                    "mcp",
                    "excluded modern HTTP tool server={s} tool={s} reason={s}",
                    .{ server.config.name, name, @errorName(err) },
                );
                alloc.free(input_schema_json);
                alloc.free(owned_description);
                alloc.free(prefixed_name);
                alloc.free(original_name);
                continue;
            };
        }

        const tags = try tool_names.tagsFor(alloc, server.config.name, name);
        errdefer freeOwnedStrings(alloc, tags);

        const title = if (protocol_tool.title) |value| try alloc.dupe(u8, value) else null;
        errdefer if (title) |value| alloc.free(value);
        const output_schema_json = if (protocol_tool.output_schema_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (output_schema_json) |value| alloc.free(value);
        const icons_json = if (protocol_tool.icons_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (icons_json) |value| alloc.free(value);
        const annotations_json = if (protocol_tool.annotations_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (annotations_json) |value| alloc.free(value);
        const metadata_json = if (protocol_tool.metadata_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (metadata_json) |value| alloc.free(value);

        try result.tools.ensureUnusedCapacity(alloc, 1);
        result.tools.appendAssumeCapacity(.{
            .original_name = original_name,
            .prefixed_name = prefixed_name,
            .title = title,
            .description = owned_description,
            .input_schema_json = input_schema_json,
            .output_schema_json = output_schema_json,
            .icons_json = icons_json,
            .annotations_json = annotations_json,
            .metadata_json = metadata_json,
            .tags = tags,
        });
    }
    return result;
}

pub fn serverCatalogAvailable(server: *const McpServer) bool {
    if (!server.isPublished()) return false;
    if (!server.tool_catalog.available) return false;
    const metadata = server.tool_catalog.metadata orelse return true;
    return catalogAuthPartitionMatches(server, metadata);
}

pub fn catalogAuthPartitionMatches(
    server: *const McpServer,
    metadata: catalog_freshness.SnapshotMetadata,
) bool {
    return metadata.scope == .public or
        server.tool_catalog.auth_generation ==
            server.auth_generation.load(.acquire);
}

pub const CatalogAuthWitness = struct {
    server: *McpServer,
    generation: u64,
};

pub fn catalogAuthWitness(server: *McpServer) ?u64 {
    const metadata = server.tool_catalog.metadata orelse return null;
    if (metadata.scope == .public) return null;
    return server.tool_catalog.auth_generation;
}

pub fn validateCatalogAuthWitness(server: *McpServer, witness: ?u64) !void {
    const generation = witness orelse return;
    if (server.auth_generation.load(.acquire) != generation) {
        return error.McpToolCatalogChanged;
    }
}

pub fn validateCatalogAuthWitnesses(witnesses: []const CatalogAuthWitness) !void {
    for (witnesses) |witness| {
        try validateCatalogAuthWitness(witness.server, witness.generation);
    }
}
