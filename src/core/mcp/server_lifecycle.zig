const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const ServerAccessPrecommit = @import("operation_authority.zig").SendGuard;
const std = @import("std");
const server_connection = @import("server_connection.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp_contract = @import("mcp_contract.zig");
const server_auth = @import("server_auth.zig");
const server_transport = @import("server_transport.zig");
const tool_names = @import("tool_names.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const controlled_lock = @import("controlled_lock.zig");
const Allocator = std.mem.Allocator;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const lockRwUntil = controlled_lock.rwUntil;
const lockMutexUntil = controlled_lock.mutexUntil;
const checkOperationControl = controlled_lock.checkOperation;
const McpServer = server_connection.Server;

const RemoteReconnectTransport = union(enum) {
    negotiate,
    http: legacy_streamable_http.Version,
    sse,
};

pub const Operations = struct {
    alloc: Allocator,
    catalog_mutex: *std.Io.RwLock,
    tool_aliases: *tool_names.Registry,
    tool_registry: tool_dispatch.Registry,

    pub fn ensureFeatureServerRunning(
        self: Operations,
        server: *McpServer,
        runtime_generation: u64,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !bool {
        if (server.config.transport != .stdio) return false;

        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        const dispatcher = server.dispatcher orelse {
            server.connection_lock.unlockShared(io_mod.getIo());
            return error.McpConnectionClosed;
        };
        const generation = dispatcher.connectionGeneration();
        const running = dispatcher.isRunning();
        server.connection_lock.unlockShared(io_mod.getIo());
        if (running) return false;

        var guard = ServerAccessPrecommit{
            .authority = .{ .alloc = self.alloc, .runtime_generation = runtime_generation, .access = access, .target = .{ .feature_server = server.config.name } },
            .cancel_flag = server.cancellation(),
        };
        var precommit = guard.transport();
        try self.recoverServer(
            server,
            generation,
            deadline,
            cancel_flag,
            &precommit,
        );
        return true;
    }

    pub fn recoverServer(
        self: Operations,
        server: *McpServer,
        failed_generation: u64,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        precommit: ?*mcp_contract.TransportPrecommit,
    ) !void {
        try lockMutexUntil(&server.recovery_lock, deadline, cancel_flag);
        defer server.recovery_lock.unlock(io_mod.getIo());

        if (precommit) |guard| {
            try guard.acquire();
            defer guard.release();
        }

        if (failed_generation <= server.last_recovery_generation) return;

        try lockRwUntil(&server.connection_lock, deadline, cancel_flag);
        defer server.connection_lock.unlock(io_mod.getIo());

        try lockRwUntil(self.catalog_mutex, deadline, cancel_flag);

        if (server.dispatcher) |dispatcher| {
            if (dispatcher.connectionGeneration() != failed_generation and
                dispatcher.isRunning())
            {
                server.last_recovery_generation = failed_generation;
                self.catalog_mutex.unlock(io_mod.getIo());
                return;
            }
        }
        if (server.restart_attempts >= server.config.restart_limit) {
            self.catalog_mutex.unlock(io_mod.getIo());
            try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
            var failure_commit_locked = true;
            defer if (failure_commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
            try lockRwUntil(self.catalog_mutex, deadline, cancel_flag);
            server.last_recovery_generation = failed_generation;
            var retired = server_connection.detachFailedConnectionPreservingFeatureCaches(server);
            server.setFailed(self.alloc, "MCP restart limit reached");
            self.catalog_mutex.unlock(io_mod.getIo());
            server.catalog_commit_lock.unlock(io_mod.getIo());
            failure_commit_locked = false;
            retired.deinit(self.alloc);
            return error.McpRestartLimitReached;
        }

        const used_tool_names = self.tool_aliases;

        server.restart_attempts += 1;
        const next_request_id = server.next_request_id;
        self.catalog_mutex.unlock(io_mod.getIo());

        try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
        debug_trace.logf(
            "mcp",
            "restarting stdio server server={s} generation={d} attempt={d}",
            .{ server.config.name, failed_generation, server.restart_attempts },
        );

        var connected = McpServer{
            .config = server.config,
            .session_generation = server.session_generation,
            .elicitation_capabilities = server.elicitation_capabilities,
            .legacy_notifications = server.legacy_notifications,
            .connection_cancel = server.cancellation(),
            .subscription_server = server,
            .auth_generation = .init(server.auth_generation.load(.acquire)),
            .authority_id = .init(server.authority_id.load(.acquire)),
            .next_request_id = next_request_id,
            .connection_generation = server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .next_subscription_generation = server.next_subscription_generation,
        };
        var connected_published = false;
        defer if (!connected_published) {
            var detached = server_connection.detachConnection(&connected);
            detached.deinit(self.alloc);
        };
        server_transport.connectServer(
            self.alloc,
            &connected,
            self.tool_registry,
            used_tool_names,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = server.cancellation(),
            },
        ) catch |err| {
            try lockRwUntil(self.catalog_mutex, deadline, cancel_flag);
            server.setFailed(self.alloc, @errorName(err));
            self.catalog_mutex.unlock(io_mod.getIo());
            return err;
        };

        try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
        try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
        var commit_locked = true;
        defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
        try lockRwUntil(self.catalog_mutex, deadline, cancel_flag);
        var retired = server_connection.detachPublishedConnection(server);
        server_connection.publishConnection(server, &connected);
        server.last_recovery_generation = failed_generation;
        connected_published = true;
        self.catalog_mutex.unlock(io_mod.getIo());
        server.catalog_commit_lock.unlock(io_mod.getIo());
        commit_locked = false;
        retired.deinit(self.alloc);
    }

    pub fn reconnectRemote(
        self: Operations,
        server: *McpServer,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        mode: enum { credentials, legacy, negotiate },
    ) !void {
        try lockMutexUntil(&server.recovery_lock, deadline, cancel_flag);
        defer server.recovery_lock.unlock(io_mod.getIo());
        // Keep a resource watch from replacing the listener while it is being stopped.
        try lockMutexUntil(&server.subscription_lifecycle_lock, deadline, cancel_flag);
        defer server.subscription_lifecycle_lock.unlock(io_mod.getIo());

        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        const has_legacy_transport = server.legacy_http != null or server.legacy_sse != null;
        server.connection_lock.unlockShared(io_mod.getIo());
        if (!has_legacy_transport and mode != .negotiate) return;

        _ = try server_auth.refreshSharedCredentials(self.alloc, server, .{
            .deadline = deadline,
            .cancel_flag = cancel_flag,
            .lifecycle_cancel_flag = server.cancellation(),
        });

        if (mode == .negotiate) {
            try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
            defer server.connection_lock.unlockShared(io_mod.getIo());
            try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
            defer server.catalog_commit_lock.unlock(io_mod.getIo());
            server.signalToolSubscriptionStop();
        }
        try lockRwUntil(&server.connection_lock, deadline, cancel_flag);
        defer server.connection_lock.unlock(io_mod.getIo());
        server.startup_state.store(.loading, .release);
        defer server.startup_state.store(.complete, .release);
        const transport: RemoteReconnectTransport = if (mode == .negotiate)
            .negotiate
        else if (server.legacy_http) |client|
            .{ .http = client.version }
        else if (server.legacy_sse != null)
            .sse
        else
            return;

        const connection_credentials = credentials: {
            try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
            defer server.auth_lock.unlock(io_mod.getIo());
            const current_identity = try server_auth.currentAuthIdentity(self.alloc, server);
            const connected_identity = try server_auth.authIdentityForHeaders(
                self.alloc,
                server.resolved_headers,
            );
            if (mode == .credentials and std.mem.eql(u8, &current_identity, &connected_identity)) return;
            break :credentials if (server.auth_credentials) |credentials|
                try credentials.clone(self.alloc)
            else
                null;
        };

        const used_tool_names = self.tool_aliases;
        try lockRwUntil(self.catalog_mutex, deadline, cancel_flag);
        var catalog_locked = true;
        errdefer if (catalog_locked) self.catalog_mutex.unlock(io_mod.getIo());

        self.catalog_mutex.unlock(io_mod.getIo());
        catalog_locked = false;

        var next_request_id = server.http_next_request_id.load(.seq_cst);
        var connected = McpServer{
            .config = server.config,
            .session_generation = server.session_generation,
            .elicitation_capabilities = server.elicitation_capabilities,
            .legacy_notifications = server.legacy_notifications,
            .connection_cancel = server.cancellation(),
            .subscription_server = server,
            .auth_credentials = connection_credentials,
            .auth_generation = .init(server.auth_generation.load(.acquire)),
            .authority_id = .init(server.authority_id.load(.acquire)),
            .http_next_request_id = .init(next_request_id),
            .connection_generation = server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .next_subscription_generation = server.next_subscription_generation,
        };
        defer if (connected.auth_credentials) |*credentials| {
            credentials.deinit(self.alloc);
        };
        defer if (connected.pending_auth_challenge) |*challenge| {
            challenge.deinit(self.alloc);
        };
        var connected_published = false;
        defer if (!connected_published) {
            var detached = server_connection.detachConnection(&connected);
            detached.deinit(self.alloc);
        };
        switch (transport) {
            .negotiate => try server_transport.connectServer(self.alloc, &connected, self.tool_registry, used_tool_names, .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = server.cancellation(),
            }),
            .http => |version| try server_transport.connectServerLegacyHttp(
                self.alloc,
                &connected,
                self.tool_registry,
                used_tool_names,
                .{
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = server.cancellation(),
                },
                &next_request_id,
                version,
            ),
            .sse => try server_transport.connectServerSse(
                self.alloc,
                &connected,
                self.tool_registry,
                used_tool_names,
                .{
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = server.cancellation(),
                },
            ),
        }

        try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
        try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
        var commit_locked = true;
        defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
        try lockRwUntil(self.catalog_mutex, deadline, cancel_flag);
        var retired = server_connection.detachPublishedConnection(server);
        server_connection.publishConnection(server, &connected);
        connected_published = true;
        self.catalog_mutex.unlock(io_mod.getIo());
        server.catalog_commit_lock.unlock(io_mod.getIo());
        commit_locked = false;
        retired.deinit(self.alloc);
        debug_trace.logf(
            "mcp",
            "reconnected server with refreshed credentials server={s} transport={s}",
            .{
                server.config.name,
                switch (transport) {
                    .negotiate => "negotiated",
                    .http => "http",
                    .sse => "sse",
                },
            },
        );
    }

    pub fn recoverLegacyHttpSession(
        self: Operations,
        server: *McpServer,
        expired_client: *legacy_streamable_http.Client,
        version: legacy_streamable_http.Version,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !void {
        try lockMutexUntil(&server.recovery_lock, deadline, cancel_flag);
        defer server.recovery_lock.unlock(io_mod.getIo());

        try lockRwUntil(&server.connection_lock, deadline, cancel_flag);
        defer server.connection_lock.unlock(io_mod.getIo());
        if (server.legacy_http != expired_client) return;

        const used_tool_names = self.tool_aliases;
        try lockRwUntil(self.catalog_mutex, deadline, cancel_flag);
        var catalog_locked = true;
        errdefer if (catalog_locked) self.catalog_mutex.unlock(io_mod.getIo());

        self.catalog_mutex.unlock(io_mod.getIo());
        catalog_locked = false;

        var next_request_id = server.http_next_request_id.load(.seq_cst);
        const recovery_credentials = credentials: {
            try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
            defer server.auth_lock.unlock(io_mod.getIo());
            break :credentials if (server.auth_credentials) |credentials|
                try credentials.clone(self.alloc)
            else
                null;
        };
        var connected = McpServer{
            .config = server.config,
            .session_generation = server.session_generation,
            .elicitation_capabilities = server.elicitation_capabilities,
            .legacy_notifications = server.legacy_notifications,
            .connection_cancel = server.cancellation(),
            .subscription_server = server,
            .auth_credentials = recovery_credentials,
            .auth_generation = .init(server.auth_generation.load(.acquire)),
            .authority_id = .init(server.authority_id.load(.acquire)),
            .http_next_request_id = .init(next_request_id),
            .connection_generation = server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .next_subscription_generation = server.next_subscription_generation,
        };
        defer if (connected.auth_credentials) |*credentials| {
            credentials.deinit(self.alloc);
        };
        var connected_published = false;
        defer if (!connected_published) {
            var detached = server_connection.detachConnection(&connected);
            detached.deinit(self.alloc);
        };
        try server_transport.connectServerLegacyHttp(
            self.alloc,
            &connected,
            self.tool_registry,
            used_tool_names,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = server.cancellation(),
            },
            &next_request_id,
            version,
        );

        try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
        try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
        var commit_locked = true;
        defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
        try lockRwUntil(self.catalog_mutex, deadline, cancel_flag);
        if (server.legacy_http != expired_client) {
            self.catalog_mutex.unlock(io_mod.getIo());
            return;
        }
        expired_client.retireExpiredSession();
        var retired = server_connection.detachPublishedConnection(server);
        server_connection.publishConnection(server, &connected);
        connected_published = true;
        self.catalog_mutex.unlock(io_mod.getIo());
        server.catalog_commit_lock.unlock(io_mod.getIo());
        commit_locked = false;
        retired.deinit(self.alloc);
        debug_trace.logf(
            "mcp",
            "reinitialized expired legacy HTTP session server={s} version={s}",
            .{ server.config.name, version.string() },
        );
    }
};
