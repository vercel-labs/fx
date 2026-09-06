const std = @import("std");
const server_connection = @import("server_connection.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const server_auth = @import("server_auth.zig");
const server_subscriptions = @import("server_subscriptions.zig");
const server_lifecycle = @import("server_lifecycle.zig");
const tool_catalog = @import("tool_catalog.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const operation_control = @import("operation_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
const streamable_http = @import("streamable_http.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const access_policy = @import("access_policy.zig");
const tool_subscription = @import("tool_subscription.zig");
const modern_protocol_version = protocol_negotiation.modern_protocol_version;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const lockRwUntil = controlled_lock.rwUntil;
const lockMutexUntil = controlled_lock.mutexUntil;
const StdioProtocol = protocol_negotiation.Protocol;
const operation_authority = @import("operation_authority.zig");
const catalog_state = @import("catalog_state.zig");
const OperationAccessGuard = operation_authority.Guard;
const McpServer = server_connection.Server;
const currentAuthPartition = server_auth.currentAuthPartition;
const authorizePendingChallengeIfAutomated = server_auth.authorizePendingChallengeIfAutomated;

pub const Context = struct {
    lifecycle: server_lifecycle.Operations,
    generation: u64,

    pub fn reload(self: Context, server: *McpServer, cancel: *std.atomic.Value(bool)) !void {
        if (!server.isPublished() or server.state.load(.acquire) != .ready) return;
        self.lifecycle.catalog_mutex.lockUncancelable(io_mod.getIo());
        inline for (.{ "tool_catalog", "resource_catalog", "resource_template_catalog", "prompt_catalog" }) |field| {
            if (@field(server, field).metadata) |*metadata| metadata.* = catalog_freshness.requestRefresh(metadata.*);
        }
        for (server.resource_read_cache.items) |*entry| entry.metadata = catalog_freshness.requestRefresh(entry.metadata);
        self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
        _ = try self.refresh(server, null, cancel, .unrestricted);
    }

    pub fn refresh(
        self: Context,
        server: *McpServer,
        requested_deadline: ?std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !bool {
        if (!server.isPublished() or (server.state.load(.acquire) != .ready and server.state.load(.acquire) != .failed)) return true;
        var operation_access = try OperationAccessGuard.init(
            self.lifecycle.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        const access_target = access_policy.Target{ .tool_server = server.config.name };
        const may_mutate_before_transport = switch (access) {
            .unrestricted => true,
            .disabled, .scoped => false,
        };
        try operation_access.authorize(access_target);
        const deadline = requested_deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        switch (access) {
            .unrestricted => try self.recoverFinishedToolSubscription(
                server,
                deadline,
                cancel_flag,
            ),
            .disabled, .scoped => {},
        }

        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        var initial_connection_locked = true;
        defer if (initial_connection_locked) {
            server.connection_lock.unlockShared(io_mod.getIo());
        };
        const initial = state: {
            try lockRwSharedUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);
            defer self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());
            break :state .{
                .metadata = server.tool_catalog.metadata orelse return true,
                .invalidated = if (server.tool_subscription) |subscription|
                    subscription.hasInvalidation()
                else
                    false,
            };
        };
        server.connection_lock.unlockShared(io_mod.getIo());
        initial_connection_locked = false;
        try operation_access.refreshAndAuthorize(access_target);
        const initial_key = try currentAuthPartition(
            self.lifecycle.alloc,
            server,
            initial.metadata.scope,
            deadline,
            cancel_flag,
            .{ .alloc = self.lifecycle.alloc, .runtime_generation = self.generation, .access = access, .target = access_target },
        );
        const initial_decision = catalog_freshness.decideRefresh(
            initial.metadata,
            initial_key,
            operation_control.monotonicMillis(io_mod.getIo()),
            initial.invalidated,
        );
        if (initial_decision.action != .refresh) {
            debug_trace.logf(
                "mcp",
                "tool cache decision server={s} action={s} freshness={s} catalog_generation={d}",
                .{
                    server.config.name,
                    @tagName(initial_decision.action),
                    @tagName(catalog_freshness.effectiveFreshness(
                        initial.metadata,
                        operation_control.monotonicMillis(io_mod.getIo()),
                        initial.invalidated,
                    )),
                    initial.metadata.catalog_generation,
                },
            );
            try operation_access.refreshAndAuthorize(access_target);
            return initial_decision.may_serve_snapshot;
        }
        if (!initial.metadata.key.eql(initial_key)) {
            try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
            const legacy_remote = server.legacy_http != null or server.legacy_sse != null;
            server.connection_lock.unlockShared(io_mod.getIo());
            if (legacy_remote) {
                try operation_access.refreshAndAuthorize(access_target);
                if (!may_mutate_before_transport) return initial_decision.may_serve_snapshot;
                try self.lifecycle.reconnectRemote(server, deadline, cancel_flag, .credentials);
                return true;
            }
        }

        try lockMutexUntil(&server.tool_refresh_lock, deadline, cancel_flag);
        defer server.tool_refresh_lock.unlock(io_mod.getIo());

        try operation_access.refreshAndAuthorize(access_target);
        const requested_key = try currentAuthPartition(
            self.lifecycle.alloc,
            server,
            initial.metadata.scope,
            deadline,
            cancel_flag,
            .{ .alloc = self.lifecycle.alloc, .runtime_generation = self.generation, .access = access, .target = access_target },
        );
        try operation_access.refreshAndAuthorize(access_target);
        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        var connection_locked = true;
        defer if (connection_locked) server.connection_lock.unlockShared(io_mod.getIo());
        try lockRwUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);
        const current = server.tool_catalog.metadata orelse {
            self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            return true;
        };
        const invalidated = if (server.tool_subscription) |subscription|
            subscription.hasInvalidation()
        else
            false;
        const decision = catalog_freshness.decideRefresh(
            current,
            requested_key,
            operation_control.monotonicMillis(io_mod.getIo()),
            invalidated,
        );
        if (decision.action != .refresh) {
            self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            return decision.may_serve_snapshot;
        }
        if (may_mutate_before_transport) {
            server.tool_catalog.metadata = catalog_freshness.beginRefresh(current);
            if (!decision.may_serve_snapshot) server.tool_catalog.available = false;
        }
        const invalidation_generation = if (server.tool_subscription) |subscription|
            subscription.invalidationGeneration()
        else
            0;
        self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
        var refresh_finished = false;
        errdefer |err| if (!refresh_finished and
            err != error.McpAccessDenied and
            err != error.McpAuthorityChanged)
        {
            self.recordToolRefreshFailure(server, current, decision.may_serve_snapshot, err);
        };
        var fetched = tool_catalog.fetchCurrent(self.lifecycle.alloc, .{
            .alloc = self.lifecycle.alloc,
            .runtime_generation = self.generation,
            .access = access,
            .target = .{ .tool_server = server.config.name },
        }, server, deadline, cancel_flag) catch |err| {
            const legacy_http = server.legacy_http;
            const legacy_sse = server.legacy_sse;
            if (err == error.McpAuthenticationRequired and
                (legacy_http != null or legacy_sse != null))
            {
                if (!may_mutate_before_transport) {
                    server.connection_lock.unlockShared(io_mod.getIo());
                    connection_locked = false;
                    try operation_access.refreshAndAuthorize(access_target);
                    self.recordToolRefreshFailure(
                        server,
                        current,
                        decision.may_serve_snapshot,
                        err,
                    );
                    refresh_finished = true;
                    return decision.may_serve_snapshot;
                }
                const control = streamable_http.Control{
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = server.cancellation(),
                };
                const captured = if (legacy_http) |client|
                    server_auth.captureLegacyStreamableAuth(self.lifecycle.alloc, server, client, control)
                else
                    server_auth.captureLegacySseAuth(self.lifecycle.alloc, server, legacy_sse.?, control);
                captured catch |capture_err| {
                    server.connection_lock.unlockShared(io_mod.getIo());
                    connection_locked = false;
                    self.recordToolRefreshFailure(
                        server,
                        current,
                        decision.may_serve_snapshot,
                        capture_err,
                    );
                    refresh_finished = true;
                    return decision.may_serve_snapshot;
                };
                server.connection_lock.unlockShared(io_mod.getIo());
                connection_locked = false;
                try operation_access.refreshAndAuthorize(access_target);
                if (try authorizePendingChallengeIfAutomated(
                    self.lifecycle.alloc,
                    server,
                    control,
                )) {
                    try operation_access.refreshAndAuthorize(access_target);
                    try self.lifecycle.reconnectRemote(server, deadline, cancel_flag, .credentials);
                    refresh_finished = true;
                    return true;
                }
                self.recordToolRefreshFailure(
                    server,
                    current,
                    decision.may_serve_snapshot,
                    err,
                );
                refresh_finished = true;
                return decision.may_serve_snapshot;
            }
            if (err == error.McpSessionExpired and legacy_http != null) {
                const client = legacy_http.?;
                const version = client.version;
                server.connection_lock.unlockShared(io_mod.getIo());
                connection_locked = false;
                try operation_access.refreshAndAuthorize(access_target);
                if (!may_mutate_before_transport) {
                    self.recordToolRefreshFailure(
                        server,
                        current,
                        decision.may_serve_snapshot,
                        err,
                    );
                    refresh_finished = true;
                    return decision.may_serve_snapshot;
                }
                try self.lifecycle.recoverLegacyHttpSession(
                    server,
                    client,
                    version,
                    deadline,
                    cancel_flag,
                );
                refresh_finished = true;
                return true;
            }
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            if (err == error.McpAccessDenied) return error.McpAccessDenied;
            if (err == error.McpAuthorityChanged) return error.McpAuthorityChanged;
            self.recordToolRefreshFailure(server, current, decision.may_serve_snapshot, err);
            return decision.may_serve_snapshot;
        };
        defer fetched.deinit(self.lifecycle.alloc);
        const scope: catalog_freshness.CacheScope = switch (fetched.catalog.cache_scope) {
            .private => .private,
            .public => .public,
        };
        const replacement_key = if (fetched.auth_identity) |auth_identity|
            catalog_freshness.authPartition(scope, auth_identity)
        else
            currentAuthPartition(
                self.lifecycle.alloc,
                server,
                scope,
                deadline,
                cancel_flag,
                .{ .alloc = self.lifecycle.alloc, .runtime_generation = self.generation, .access = access, .target = access_target },
            ) catch |err| {
                server.connection_lock.unlockShared(io_mod.getIo());
                connection_locked = false;
                self.recordToolRefreshFailure(server, current, decision.may_serve_snapshot, err);
                return decision.may_serve_snapshot;
            };
        if (fetched.auth_identity == null and
            server.config.transport == .http and
            server.legacy_http == null)
        {
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            self.recordToolRefreshFailure(
                server,
                current,
                decision.may_serve_snapshot,
                error.McpMissingAuthIdentity,
            );
            return decision.may_serve_snapshot;
        }
        const subscription_identity = if (server.tool_subscription) |subscription|
            subscription.identity()
        else
            null;
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;

        try operation_access.refreshAndAuthorize(access_target);

        const used_tool_names = self.lifecycle.tool_aliases;
        try lockRwSharedUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);

        self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());

        const protocol: StdioProtocol = if (std.mem.eql(
            u8,
            server.negotiated_protocol_version,
            modern_protocol_version,
        ))
            .modern
        else
            .legacy;
        var replacement = try tool_catalog.prepare(
            self.lifecycle.alloc,
            server,
            self.lifecycle.tool_registry,
            fetched.catalog.tools,
            used_tool_names,
            protocol,
        );
        defer replacement.deinit(self.lifecycle.alloc);
        replacement.metadata = .{
            .key = replacement_key,
            .connection_generation = current.connection_generation,
            .catalog_generation = current.catalog_generation,
            .fetched_at_ms = fetched.catalog.fetched_at_ms,
            .expires_at_ms = fetched.catalog.expires_at_ms,
            .scope = scope,
            .content_digest = catalog_state.digestTools(replacement.tools.items),
            .subscription = subscription_identity,
        };

        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        defer server.connection_lock.unlockShared(io_mod.getIo());
        if (server.connection_generation != current.connection_generation) {
            try lockRwSharedUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);
            defer self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());
            refresh_finished = true;
            return tool_catalog.serverCatalogAvailable(server);
        }

        var catalog_commit_locked = false;
        defer if (catalog_commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
        try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
        catalog_commit_locked = true;

        var auth_locked = false;
        defer if (auth_locked) server.auth_lock.unlock(io_mod.getIo());
        const active_key = if (scope == .private and server.config.transport != .stdio) active: {
            try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
            auth_locked = true;
            break :active catalog_freshness.authPartition(scope, try server_auth.currentAuthIdentity(self.lifecycle.alloc, server));
        } else replacement_key;

        try lockRwUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);
        const latest = server.tool_catalog.metadata orelse {
            self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
            return false;
        };
        const transition = catalog_freshness.authorizeReplacement(
            latest,
            current.connection_generation,
            current.catalog_generation,
            active_key,
            replacement.metadata.?.key,
            replacement.metadata.?.content_digest,
        );
        switch (transition) {
            .reject_stale_generation => {
                const snapshot_available = tool_catalog.serverCatalogAvailable(server);
                self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
                if (auth_locked) {
                    server.auth_lock.unlock(io_mod.getIo());
                    auth_locked = false;
                }
                server.catalog_commit_lock.unlock(io_mod.getIo());
                catalog_commit_locked = false;
                refresh_finished = true;
                debug_trace.logf(
                    "mcp",
                    "rejected stale tool refresh server={s} source_connection_generation={d} source_catalog_generation={d}",
                    .{ server.config.name, current.connection_generation, current.catalog_generation },
                );
                return snapshot_available;
            },
            .reject_auth_partition => {
                self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
                if (auth_locked) {
                    server.auth_lock.unlock(io_mod.getIo());
                    auth_locked = false;
                }
                server.catalog_commit_lock.unlock(io_mod.getIo());
                catalog_commit_locked = false;
                refresh_finished = true;
                self.recordToolRefreshFailure(
                    server,
                    current,
                    decision.may_serve_snapshot,
                    error.McpAuthIdentityChangedDuringPagination,
                );
                return decision.may_serve_snapshot;
            },
            .metadata_only => {
                replacement.metadata.?.catalog_generation = latest.catalog_generation;
                replacement.metadata.?.connection_generation = latest.connection_generation;
                server.tool_catalog.metadata = replacement.metadata;
                server.tool_catalog.auth_generation = server.auth_generation.load(.acquire);
                server.tool_catalog.available = true;
                server.setReady(self.lifecycle.alloc, operation_control.monotonicMillis(io_mod.getIo()));
                if (server.tool_subscription) |subscription| {
                    subscription.clearInvalidationThrough(invalidation_generation);
                }
                const catalog_generation = replacement.metadata.?.catalog_generation;
                const fetched_at_ms = replacement.metadata.?.fetched_at_ms;
                const expires_at_ms = replacement.metadata.?.expires_at_ms;
                const notification_stats: tool_subscription.State.NotificationStats = if (server.tool_subscription) |subscription|
                    subscription.notificationStats()
                else
                    .{ .seen = 0, .coalesced = 0 };
                self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
                if (auth_locked) {
                    server.auth_lock.unlock(io_mod.getIo());
                    auth_locked = false;
                }
                server.catalog_commit_lock.unlock(io_mod.getIo());
                catalog_commit_locked = false;
                refresh_finished = true;
                debug_trace.logf(
                    "mcp",
                    "tool cache refreshed without schema change server={s} catalog_generation={d} fetched_at_ms={d} expiry_ms={d} notifications_seen={d} notifications_coalesced={d}",
                    .{
                        server.config.name,
                        catalog_generation,
                        fetched_at_ms,
                        expires_at_ms,
                        notification_stats.seen,
                        notification_stats.coalesced,
                    },
                );
                return true;
            },
            .replace_snapshot => {
                const next_catalog_generation = std.math.add(
                    u64,
                    latest.catalog_generation,
                    1,
                ) catch {
                    self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
                    return error.McpGenerationExhausted;
                };
                replacement.metadata.?.catalog_generation = next_catalog_generation;
                replacement.metadata.?.connection_generation = latest.connection_generation;
                replacement.auth_generation = server.auth_generation.load(.acquire);
                var retired = server.tool_catalog;
                server.tool_catalog = replacement;
                replacement = .{};
                server.catalog_generation = next_catalog_generation;
                server.setReady(self.lifecycle.alloc, operation_control.monotonicMillis(io_mod.getIo()));
                if (server.tool_subscription) |subscription| {
                    subscription.clearInvalidationThrough(invalidation_generation);
                }
                const tool_count = server.tool_catalog.tools.items.len;
                const notification_stats: tool_subscription.State.NotificationStats = if (server.tool_subscription) |subscription|
                    subscription.notificationStats()
                else
                    .{ .seen = 0, .coalesced = 0 };
                self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
                if (auth_locked) {
                    server.auth_lock.unlock(io_mod.getIo());
                    auth_locked = false;
                }
                server.catalog_commit_lock.unlock(io_mod.getIo());
                catalog_commit_locked = false;
                refresh_finished = true;
                retired.deinit(self.lifecycle.alloc);
                debug_trace.logf(
                    "mcp",
                    "tool cache snapshot replaced server={s} catalog_generation={d} tools={d} notifications_seen={d} notifications_coalesced={d}",
                    .{
                        server.config.name,
                        next_catalog_generation,
                        tool_count,
                        notification_stats.seen,
                        notification_stats.coalesced,
                    },
                );
                return true;
            },
        }
    }

    fn recordToolRefreshFailure(
        self: Context,
        server: *McpServer,
        source: catalog_freshness.SnapshotMetadata,
        may_serve_snapshot: bool,
        err: anyerror,
    ) void {
        self.lifecycle.catalog_mutex.lockUncancelable(io_mod.getIo());
        defer self.lifecycle.catalog_mutex.unlock(io_mod.getIo());
        const current = server.tool_catalog.metadata orelse return;
        if (current.connection_generation != source.connection_generation or
            current.catalog_generation != source.catalog_generation)
        {
            return;
        }
        server.tool_catalog.metadata = catalog_freshness.failedRefresh(current, operation_control.monotonicMillis(io_mod.getIo()));
        server.tool_catalog.available = may_serve_snapshot;
        debug_trace.logf(
            "mcp",
            "tool cache refresh failed server={s} freshness=failed_refresh retry_at_ms={d} preserved_tools={d} err={s}",
            .{
                server.config.name,
                server.tool_catalog.metadata.?.retry_at_ms,
                server.tool_catalog.tools.items.len,
                @errorName(err),
            },
        );
    }

    fn recoverFinishedToolSubscription(
        self: Context,
        server: *McpServer,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !void {
        const reason = try server_subscriptions.takeFinishedToolSubscription(
            self.lifecycle.catalog_mutex,
            server,
            deadline,
            cancel_flag,
        ) orelse return;
        switch (reason) {
            .unsupported, .cancelled => return,
            .authentication_required => {
                const control = streamable_http.Control{
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = server.cancellation(),
                };
                try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
                var has_legacy = false;
                var capture_error: ?anyerror = null;
                if (server.legacy_http) |client| {
                    has_legacy = true;
                    server_auth.captureLegacyStreamableAuth(
                        self.lifecycle.alloc,
                        server,
                        client,
                        control,
                    ) catch |err| {
                        capture_error = err;
                    };
                } else if (server.legacy_sse) |client| {
                    has_legacy = true;
                    server_auth.captureLegacySseAuth(
                        self.lifecycle.alloc,
                        server,
                        client,
                        control,
                    ) catch |err| {
                        capture_error = err;
                    };
                }
                server.connection_lock.unlockShared(io_mod.getIo());
                if (capture_error) |err| return err;
                if (!has_legacy) return;
                if (!try authorizePendingChallengeIfAutomated(
                    self.lifecycle.alloc,
                    server,
                    control,
                )) return;
                try self.lifecycle.reconnectRemote(server, deadline, cancel_flag, .credentials);
            },
            .session_expired => {
                try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
                const client = server.legacy_http orelse {
                    server.connection_lock.unlockShared(io_mod.getIo());
                    return;
                };
                const version = client.version;
                server.connection_lock.unlockShared(io_mod.getIo());
                try self.lifecycle.recoverLegacyHttpSession(
                    server,
                    client,
                    version,
                    deadline,
                    cancel_flag,
                );
            },
            .running, .closed => {
                var credentials_refreshed = false;
                if (server.config.transport != .stdio) {
                    credentials_refreshed = try server_auth.refreshSharedCredentials(
                        self.lifecycle.alloc,
                        server,
                        .{
                            .deadline = deadline,
                            .cancel_flag = cancel_flag,
                            .lifecycle_cancel_flag = server.cancellation(),
                        },
                    );
                }
                try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
                const has_legacy_sse = server.legacy_sse != null;
                const has_legacy_http = server.legacy_http != null;
                server.connection_lock.unlockShared(io_mod.getIo());
                if (has_legacy_sse) {
                    try self.lifecycle.reconnectRemote(server, deadline, cancel_flag, .legacy);
                } else if (credentials_refreshed and has_legacy_http) {
                    try self.lifecycle.reconnectRemote(server, deadline, cancel_flag, .credentials);
                } else {
                    try server_subscriptions.startToolSubscriptionGuarded(
                        self.lifecycle.catalog_mutex,
                        self.lifecycle.alloc,
                        server,
                        deadline,
                        cancel_flag,
                    );
                }
            },
        }
        debug_trace.logf(
            "mcp",
            "tool subscription restarted after listener completion server={s}",
            .{server.config.name},
        );
    }
};
