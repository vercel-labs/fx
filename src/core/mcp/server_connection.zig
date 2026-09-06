const std = @import("std");
const io_mod = @import("../shared/io.zig");
const atomic_value = @import("atomic_value.zig");
const mcp_contract = @import("mcp_contract.zig");
const mcp_auth = @import("mcp_auth.zig");
const elicitation = @import("elicitation.zig");
const legacy_url_completion = @import("legacy_url_completion.zig");
const tool_subscription = @import("tool_subscription.zig");
const stdio_dispatcher = @import("stdio_dispatcher.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const legacy_http_sse = @import("legacy_http_sse.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
const catalog_state = @import("catalog_state.zig");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const McpServerConfig = mcp_contract.McpServerConfig;
const StdioProtocol = protocol_negotiation.Protocol;
const ToolCatalogSnapshot = catalog_state.ToolCatalogSnapshot;
const ResourceCatalogSnapshot = catalog_state.ResourceCatalogSnapshot;
const ResourceTemplateCatalogSnapshot = catalog_state.ResourceTemplateCatalogSnapshot;
const PromptCatalogSnapshot = catalog_state.PromptCatalogSnapshot;
const ResourceReadCacheEntry = catalog_state.ResourceReadCacheEntry;
const ServerCapabilities = catalog_state.ServerCapabilities;

pub const ServerState = enum(u8) {
    disconnected,
    disabled,
    ready,
    failed,
};

pub const DiscoveryState = enum(u8) {
    idle,
    loading,
    complete,
};

pub const DetachedTransport = struct {
    dispatcher: ?*stdio_dispatcher.StdioDispatcher,
    legacy_http: ?*legacy_streamable_http.Client,
    legacy_sse: ?*legacy_http_sse.Client,

    pub fn deinit(self: *DetachedTransport, force_dispatcher_shutdown: bool) void {
        if (self.dispatcher) |dispatcher| {
            if (force_dispatcher_shutdown) {
                dispatcher.deinitForced();
            } else {
                dispatcher.deinit();
            }
        }
        if (self.legacy_http) |client| client.deinit();
        if (self.legacy_sse) |client| client.deinit();
        self.* = undefined;
    }
};

pub const Server = struct {
    lifetime: @import("server_lifetime.zig").Lifetime = .{},
    connection_cancel: ?*const std.atomic.Value(bool) = null,
    subscription_server: ?*Server = null,
    config: McpServerConfig,
    session_generation: ?u64 = null,
    elicitation_capabilities: elicitation.Capabilities = .{},
    completion_state: ?*legacy_url_completion.State = null,
    legacy_notifications: ?struct {
        context: *anyopaque,
        callback: *const fn (*anyopaque, tool_subscription.NotificationSource, std.json.Value) void,
    } = null,
    owner_alloc: ?Allocator = null,
    dispatcher: ?*stdio_dispatcher.StdioDispatcher = null,
    legacy_http: ?*legacy_streamable_http.Client = null,
    legacy_sse: ?*legacy_http_sse.Client = null,
    resolved_headers: []mcp_contract.McpHttpHeader = &.{},
    resolved_authorization: ?[]u8 = null,
    auth_credentials: ?mcp_auth.Credentials = null,
    pending_auth_challenge: ?mcp_auth.Challenge = null,
    env_map: ?EnvMap = null,
    tool_catalog: ToolCatalogSnapshot = .{},
    resource_catalog: ResourceCatalogSnapshot = .{},
    resource_template_catalog: ResourceTemplateCatalogSnapshot = .{},
    prompt_catalog: PromptCatalogSnapshot = .{},
    resource_read_cache: std.ArrayList(ResourceReadCacheEntry) = .empty,
    next_request_id: u64 = 1,
    http_next_request_id: atomic_value.Value(u64) = .init(1),
    connection_generation: u64 = 0,
    catalog_generation: u64 = 0,
    restart_attempts: u8 = 0,
    last_recovery_generation: u64 = 0,
    connection_lock: std.Io.RwLock = .init,
    recovery_lock: std.Io.Mutex = .init,
    tool_refresh_lock: std.Io.Mutex = .init,
    feature_refresh_lock: std.Io.Mutex = .init,
    catalog_commit_lock: std.Io.Mutex = .init,
    subscription_lifecycle_lock: std.Io.Mutex = .init,
    auth_lock: std.Io.Mutex = .init,
    status_lock: std.Io.Mutex = .init,
    auth_generation: atomic_value.Value(u64) = .init(0),
    authority_id: atomic_value.Value(u64) = .init(0),
    auth_logout_in_progress: std.atomic.Value(bool) = .init(false),
    auth_credentials_present: std.atomic.Value(bool) = .init(false),
    auth_challenge_present: std.atomic.Value(bool) = .init(false),
    startup_state: std.atomic.Value(DiscoveryState) = .init(.idle),
    reload_pending: std.atomic.Value(bool) = .init(false),
    state: atomic_value.Value(ServerState) = .init(.disconnected),
    last_error: ?[]u8 = null,
    instructions: ?[]u8 = null,
    negotiated_server_name: ?[]u8 = null,
    negotiated_server_version: ?[]u8 = null,
    stdio_protocol: StdioProtocol = .unselected,
    negotiated_protocol_version: []const u8 = "",
    last_successful_discovery_ms: ?u64 = null,
    tools_list_changed: bool = false,
    capabilities: ServerCapabilities = .{},
    tool_subscription: ?*tool_subscription.State = null,
    next_subscription_generation: u64 = 1,

    pub fn reserveRequestId(self: *Server) error{McpRequestIdExhausted}!u64 {
        var current = self.http_next_request_id.load(.seq_cst);
        while (true) {
            if (current > std.math.maxInt(i64)) return error.McpRequestIdExhausted;
            const next = current + 1;
            const result = self.http_next_request_id.cmpxchgWeak(
                current,
                next,
                .seq_cst,
                .seq_cst,
            );
            if (result == null) return current;
            current = result.?;
        }
    }

    pub fn legacyWire(self: *const Server) ?elicitation.Wire {
        if (std.mem.eql(
            u8,
            self.negotiated_protocol_version,
            protocol_negotiation.legacy_2025_11_protocol_version,
        )) return .legacy_mcp_2025_11;
        if (std.mem.eql(
            u8,
            self.negotiated_protocol_version,
            protocol_negotiation.legacy_2025_06_protocol_version,
        )) return .legacy_mcp_2025_06;
        return null;
    }

    pub fn cancellation(self: *const Server) *const std.atomic.Value(bool) {
        return self.connection_cancel orelse &self.lifetime.retiring;
    }

    pub fn isPublished(self: *const Server) bool {
        return !self.lifetime.retiring.load(.acquire) and self.startup_state.load(.acquire) != .loading;
    }

    pub fn legacySourceState(self: *const Server, connection_generation: u64, client_generation: u64, auth_generation: u64) legacy_url_completion.SourceState {
        if (!self.isPublished() or self.state.load(.acquire) != .ready or
            self.connection_generation != connection_generation or
            self.auth_generation.load(.acquire) != auth_generation) return .stale;
        const current_client_generation = if (self.dispatcher) |dispatcher| dispatcher.connectionGeneration() else self.connection_generation;
        if (current_client_generation != client_generation) return .stale;
        return if (self.auth_logout_in_progress.load(.acquire)) .logout_fenced else .current;
    }

    pub fn deinit(self: *Server, alloc: Allocator) void {
        self.owner_alloc = alloc;
        self.lifetime.retire();
        self.lifetime.wait(io_mod.getIo());
        self.disconnect();
        self.clearResolvedHeaders(alloc);
        if (self.auth_credentials) |*credentials| credentials.deinit(alloc);
        if (self.pending_auth_challenge) |*challenge| challenge.deinit(alloc);
        self.config.deinit(alloc);
        self.tool_catalog.deinit(alloc);
        self.resource_catalog.deinit(alloc);
        self.resource_template_catalog.deinit(alloc);
        self.prompt_catalog.deinit(alloc);
        for (self.resource_read_cache.items) |*entry| entry.deinit(alloc);
        self.resource_read_cache.deinit(alloc);
        if (self.last_error) |value| alloc.free(value);
        if (self.instructions) |value| alloc.free(value);
        if (self.negotiated_server_name) |value| alloc.free(value);
        if (self.negotiated_server_version) |value| alloc.free(value);
        if (self.env_map) |*map| map.deinit();
    }

    pub fn clearResolvedHeaders(self: *Server, alloc: Allocator) void {
        if (self.resolved_headers.len > 0) alloc.free(self.resolved_headers);
        self.resolved_headers = &.{};
        if (self.resolved_authorization) |value| {
            @memset(value, 0);
            alloc.free(value);
        }
        self.resolved_authorization = null;
    }

    pub fn disconnect(self: *Server) void {
        self.stopToolSubscription();
        var detached = self.detachTransport();
        detached.deinit(false);
    }

    pub fn disconnectForced(self: *Server) void {
        self.stopToolSubscription();
        var detached = self.detachTransport();
        detached.deinit(true);
    }

    pub fn detachTransport(self: *Server) DetachedTransport {
        const detached = DetachedTransport{
            .dispatcher = self.dispatcher,
            .legacy_http = self.legacy_http,
            .legacy_sse = self.legacy_sse,
        };
        self.dispatcher = null;
        self.legacy_http = null;
        self.legacy_sse = null;
        self.stdio_protocol = .unselected;
        self.negotiated_protocol_version = "";
        const alloc = self.owner_alloc;
        if (self.negotiated_server_name) |value| alloc.?.free(value);
        self.negotiated_server_name = null;
        if (self.negotiated_server_version) |value| alloc.?.free(value);
        self.negotiated_server_version = null;
        self.tools_list_changed = false;
        self.capabilities = .{};
        self.state.store(.disconnected, .release);
        return detached;
    }

    pub fn setFailed(self: *Server, alloc: Allocator, msg: []const u8) void {
        self.status_lock.lockUncancelable(io_mod.getIo());
        defer self.status_lock.unlock(io_mod.getIo());
        if (self.last_error) |old| alloc.free(old);
        self.last_error = alloc.dupe(u8, msg) catch null;
        self.state.store(.failed, .release);
    }

    pub fn setReady(self: *Server, alloc: Allocator, observed_at_ms: u64) void {
        self.status_lock.lockUncancelable(io_mod.getIo());
        defer self.status_lock.unlock(io_mod.getIo());
        if (self.last_error) |value| alloc.free(value);
        self.last_error = null;
        self.state.store(.ready, .release);
        self.last_successful_discovery_ms = observed_at_ms;
    }

    fn stopToolSubscription(self: *Server) void {
        const subscription = self.detachToolSubscription();
        if (subscription) |state| state.stopAndDestroy();
    }

    pub fn detachToolSubscription(self: *Server) ?*tool_subscription.State {
        const subscription = self.tool_subscription;
        self.tool_subscription = null;
        if (self.tool_catalog.metadata) |*metadata| metadata.subscription = null;
        if (self.resource_catalog.metadata) |*metadata| metadata.subscription = null;
        if (self.resource_template_catalog.metadata) |*metadata| metadata.subscription = null;
        if (self.prompt_catalog.metadata) |*metadata| metadata.subscription = null;
        return subscription;
    }

    pub fn signalToolSubscriptionStop(self: *Server) void {
        if (self.tool_subscription) |subscription| subscription.requestStop();
    }
};

pub fn legacyWireForHttpVersion(version: legacy_streamable_http.Version) ?elicitation.Wire {
    return switch (version) {
        .v2025_11_25 => .legacy_mcp_2025_11,
        .v2025_06_18 => .legacy_mcp_2025_06,
        .v2025_03_26 => null,
    };
}

pub const DetachedConnection = struct {
    dispatcher: ?*stdio_dispatcher.StdioDispatcher,
    legacy_http: ?*legacy_streamable_http.Client,
    legacy_sse: ?*legacy_http_sse.Client,
    resolved_headers: []mcp_contract.McpHttpHeader,
    resolved_authorization: ?[]u8,
    env_map: ?EnvMap,
    tool_catalog: ToolCatalogSnapshot,
    resource_catalog: ResourceCatalogSnapshot,
    resource_template_catalog: ResourceTemplateCatalogSnapshot,
    prompt_catalog: PromptCatalogSnapshot,
    resource_read_cache: std.ArrayList(ResourceReadCacheEntry),
    last_error: ?[]u8,
    instructions: ?[]u8,
    negotiated_protocol_version: []const u8,
    negotiated_server_name: ?[]u8,
    negotiated_server_version: ?[]u8,
    last_successful_discovery_ms: ?u64,
    tools_list_changed: bool,
    capabilities: ServerCapabilities,
    tool_subscription: ?*tool_subscription.State,

    pub fn deinit(self: *DetachedConnection, alloc: Allocator) void {
        self.deinitWithDispatcherMode(alloc, true);
    }

    pub fn deinitGracefully(self: *DetachedConnection, alloc: Allocator) void {
        self.deinitWithDispatcherMode(alloc, false);
    }

    fn deinitWithDispatcherMode(
        self: *DetachedConnection,
        alloc: Allocator,
        force_dispatcher_shutdown: bool,
    ) void {
        if (self.tool_subscription) |subscription| subscription.stopAndDestroy();
        if (self.dispatcher) |dispatcher| {
            if (force_dispatcher_shutdown) {
                dispatcher.deinitForced();
            } else {
                dispatcher.deinit();
            }
        }
        if (self.legacy_http) |client| client.deinit();
        if (self.legacy_sse) |client| client.deinit();
        if (self.resolved_headers.len > 0) alloc.free(self.resolved_headers);
        if (self.resolved_authorization) |value| {
            @memset(value, 0);
            alloc.free(value);
        }
        self.tool_catalog.deinit(alloc);
        self.resource_catalog.deinit(alloc);
        self.resource_template_catalog.deinit(alloc);
        self.prompt_catalog.deinit(alloc);
        for (self.resource_read_cache.items) |*entry| entry.deinit(alloc);
        self.resource_read_cache.deinit(alloc);
        if (self.last_error) |value| alloc.free(value);
        if (self.instructions) |value| alloc.free(value);
        if (self.negotiated_server_name) |value| alloc.free(value);
        if (self.negotiated_server_version) |value| alloc.free(value);
        if (self.env_map) |*map| map.deinit();
        self.* = undefined;
    }
};

pub fn detachConnection(server: *Server) DetachedConnection {
    const detached = DetachedConnection{
        .dispatcher = server.dispatcher,
        .legacy_http = server.legacy_http,
        .legacy_sse = server.legacy_sse,
        .resolved_headers = server.resolved_headers,
        .resolved_authorization = server.resolved_authorization,
        .env_map = server.env_map,
        .tool_catalog = server.tool_catalog,
        .resource_catalog = server.resource_catalog,
        .resource_template_catalog = server.resource_template_catalog,
        .prompt_catalog = server.prompt_catalog,
        .resource_read_cache = server.resource_read_cache,
        .last_error = server.last_error,
        .instructions = server.instructions,
        .negotiated_protocol_version = server.negotiated_protocol_version,
        .negotiated_server_name = server.negotiated_server_name,
        .negotiated_server_version = server.negotiated_server_version,
        .last_successful_discovery_ms = server.last_successful_discovery_ms,
        .tools_list_changed = server.tools_list_changed,
        .capabilities = server.capabilities,
        .tool_subscription = server.tool_subscription,
    };
    server.dispatcher = null;
    server.legacy_http = null;
    server.legacy_sse = null;
    server.resolved_headers = &.{};
    server.resolved_authorization = null;
    server.env_map = null;
    server.tool_catalog = .{};
    server.resource_catalog = .{};
    server.resource_template_catalog = .{};
    server.prompt_catalog = .{};
    server.resource_read_cache = .empty;
    server.state.store(.disconnected, .release);
    server.last_error = null;
    server.instructions = null;
    server.stdio_protocol = .unselected;
    server.negotiated_protocol_version = "";
    server.negotiated_server_name = null;
    server.negotiated_server_version = null;
    server.last_successful_discovery_ms = null;
    server.tools_list_changed = false;
    server.capabilities = .{};
    server.tool_subscription = null;
    return detached;
}

pub fn detachPublishedConnection(server: *Server) DetachedConnection {
    if (server.completion_state) |completions| completions.cancelLegacyUrlWaitersForServer(server.config.name, server.connection_generation);
    return detachConnection(server);
}

pub fn detachFailedConnectionPreservingFeatureCaches(server: *Server) DetachedConnection {
    const stdio_protocol = server.stdio_protocol;
    var detached = detachPublishedConnection(server);
    server.resource_catalog = detached.resource_catalog;
    detached.resource_catalog = .{};
    server.resource_template_catalog = detached.resource_template_catalog;
    detached.resource_template_catalog = .{};
    server.prompt_catalog = detached.prompt_catalog;
    detached.prompt_catalog = .{};
    server.resource_read_cache = detached.resource_read_cache;
    detached.resource_read_cache = .empty;
    server.stdio_protocol = stdio_protocol;
    server.negotiated_protocol_version = detached.negotiated_protocol_version;
    detached.negotiated_protocol_version = "";
    server.negotiated_server_name = detached.negotiated_server_name;
    detached.negotiated_server_name = null;
    server.negotiated_server_version = detached.negotiated_server_version;
    detached.negotiated_server_version = null;
    server.last_successful_discovery_ms = detached.last_successful_discovery_ms;
    server.capabilities = detached.capabilities;
    return detached;
}

/// The caller holds the connection, catalog commit, and catalog publication locks.
pub fn publishConnection(server: *Server, connected: *Server) void {
    std.debug.assert(server.dispatcher == null);
    std.debug.assert(server.legacy_http == null);
    std.debug.assert(server.legacy_sse == null);
    std.debug.assert(server.resolved_headers.len == 0);
    std.debug.assert(server.resolved_authorization == null);
    std.debug.assert(server.last_error == null);
    std.debug.assert(server.instructions == null);
    std.debug.assert(server.env_map == null);

    server.dispatcher = connected.dispatcher;
    connected.dispatcher = null;
    server.legacy_http = connected.legacy_http;
    connected.legacy_http = null;
    server.legacy_sse = connected.legacy_sse;
    connected.legacy_sse = null;
    server.resolved_headers = connected.resolved_headers;
    connected.resolved_headers = &.{};
    server.resolved_authorization = connected.resolved_authorization;
    connected.resolved_authorization = null;
    server.env_map = connected.env_map;
    connected.env_map = null;
    server.tool_catalog = connected.tool_catalog;
    connected.tool_catalog = .{};
    server.resource_catalog = connected.resource_catalog;
    connected.resource_catalog = .{};
    server.resource_template_catalog = connected.resource_template_catalog;
    connected.resource_template_catalog = .{};
    server.prompt_catalog = connected.prompt_catalog;
    connected.prompt_catalog = .{};
    server.resource_read_cache = connected.resource_read_cache;
    connected.resource_read_cache = .empty;
    server.next_request_id = connected.next_request_id;
    server.http_next_request_id.store(
        connected.http_next_request_id.load(.seq_cst),
        .seq_cst,
    );
    server.connection_generation = connected.connection_generation;
    server.catalog_generation = connected.catalog_generation;
    server.state.store(connected.state.load(.acquire), .release);
    server.last_error = connected.last_error;
    connected.last_error = null;
    server.instructions = connected.instructions;
    connected.instructions = null;
    server.stdio_protocol = connected.stdio_protocol;
    connected.stdio_protocol = .unselected;
    server.negotiated_protocol_version = connected.negotiated_protocol_version;
    connected.negotiated_protocol_version = "";
    server.negotiated_server_name = connected.negotiated_server_name;
    connected.negotiated_server_name = null;
    server.negotiated_server_version = connected.negotiated_server_version;
    connected.negotiated_server_version = null;
    server.last_successful_discovery_ms = connected.last_successful_discovery_ms;
    server.tools_list_changed = connected.tools_list_changed;
    connected.tools_list_changed = false;
    server.capabilities = connected.capabilities;
    connected.capabilities = .{};
    server.tool_subscription = connected.tool_subscription;
    connected.tool_subscription = null;
    server.next_subscription_generation = connected.next_subscription_generation;
}

pub const StdioRequestWait = struct {
    server: *Server,
    released: bool = false,

    pub fn begin(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        std.debug.assert(!self.released);
        self.server.connection_lock.unlockShared(io_mod.getIo());
        self.released = true;
    }
};

pub fn featureRequestId(server: *Server) !u64 {
    return switch (server.config.transport) {
        .stdio => try (server.dispatcher orelse return error.McpConnectionClosed).reserveRequestId(),
        .http, .sse => try server.reserveRequestId(),
    };
}

pub fn featureProtocol(server: *const Server) @import("features/resources.zig").Protocol {
    if (std.mem.eql(u8, server.negotiated_protocol_version, protocol_negotiation.modern_protocol_version)) return .modern;
    return switch (server.stdio_protocol) {
        .modern => .modern,
        .legacy, .unselected => .legacy,
    };
}

pub fn operationDeadline(server: *const Server) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(server.config.operation_timeout_ms),
    });
}
