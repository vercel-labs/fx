const feature_transport = @import("feature_transport.zig");
const std = @import("std");
const server_connection = @import("server_connection.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp_auth = @import("mcp_auth.zig");
const server_auth = @import("server_auth.zig");
const server_lifecycle = @import("server_lifecycle.zig");
const feature_catalog = @import("feature_catalog.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const operation_control = @import("operation_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const protocol_messages = @import("protocol_messages.zig");
const writeModernRequestMetadata = protocol_messages.writeModernRequestMetadata;
const featureProtocol = protocol_messages.featureProtocol;
const catalog_freshness = @import("catalog_freshness.zig");
const access_policy = @import("access_policy.zig");
const tool_subscription = @import("tool_subscription.zig");
const prompts_feature = @import("features/prompts.zig");
const resources_feature = @import("features/resources.zig");
const Allocator = std.mem.Allocator;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const lockRwUntil = controlled_lock.rwUntil;
const lockMutexUntil = controlled_lock.mutexUntil;
const operation_authority = @import("operation_authority.zig");
const FeatureResponse = feature_transport.Response;
const nextFeatureRequestId = server_connection.featureRequestId;
const serverFeatureProtocol = server_connection.featureProtocol;
const catalog_state = @import("catalog_state.zig");
const ResourceCatalogSnapshot = catalog_state.ResourceCatalogSnapshot;
const ResourceTemplateCatalogSnapshot = catalog_state.ResourceTemplateCatalogSnapshot;
const PromptCatalogSnapshot = catalog_state.PromptCatalogSnapshot;
const ServerAccessPrecommit = operation_authority.SendGuard;
const OperationAccessGuard = operation_authority.Guard;
const authorizeLiveAccess = operation_authority.authorizeLiveAccess;
const McpServer = server_connection.Server;
const currentAuthPartition = server_auth.currentAuthPartition;

pub const Operations = struct {
    transport: feature_transport.Operations,
    lifecycle: server_lifecycle.Operations,

    const FetchedFeatureCatalog = union(feature_catalog.FeatureCatalogKind) {
        resources: FetchedResources,
        resource_templates: FetchedResourceTemplates,
        prompts: FetchedPrompts,

        fn deinit(self: *FetchedFeatureCatalog, alloc: Allocator) void {
            switch (self.*) {
                .resources => |*value| value.catalog.deinit(alloc),
                .resource_templates => |*value| value.catalog.deinit(alloc),
                .prompts => |*value| value.catalog.deinit(alloc),
            }
            self.* = undefined;
        }

        fn scope(self: FetchedFeatureCatalog) catalog_freshness.CacheScope {
            return switch (self) {
                .resources => |value| switch (value.catalog.cache_scope) {
                    .private => .private,
                    .public => .public,
                },
                .resource_templates => |value| switch (value.catalog.cache_scope) {
                    .private => .private,
                    .public => .public,
                },
                .prompts => |value| switch (value.catalog.cache_scope) {
                    .private => .private,
                    .public => .public,
                },
            };
        }

        fn authIdentity(self: FetchedFeatureCatalog) ?catalog_freshness.Digest {
            return switch (self) {
                .resources => |value| value.auth_identity,
                .resource_templates => |value| value.auth_identity,
                .prompts => |value| value.auth_identity,
            };
        }

        fn fetchedAt(self: FetchedFeatureCatalog) u64 {
            return switch (self) {
                .resources => |value| value.catalog.fetched_at_ms,
                .resource_templates => |value| value.catalog.fetched_at_ms,
                .prompts => |value| value.catalog.fetched_at_ms,
            };
        }

        fn expiresAt(self: FetchedFeatureCatalog) u64 {
            return switch (self) {
                .resources => |value| value.catalog.expires_at_ms,
                .resource_templates => |value| value.catalog.expires_at_ms,
                .prompts => |value| value.catalog.expires_at_ms,
            };
        }

        fn digest(self: FetchedFeatureCatalog) catalog_freshness.Digest {
            return switch (self) {
                .resources => |value| digestResources(value.catalog.items),
                .resource_templates => |value| digestResourceTemplates(value.catalog.items),
                .prompts => |value| digestPrompts(value.catalog.prompts),
            };
        }
    };

    pub fn ensureResourceCatalog(
        self: Operations,
        server: *McpServer,
        templates: bool,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !bool {
        return ensureFeatureCatalog(
            self,
            server,
            if (templates) .resource_templates else .resources,
            deadline,
            cancel_flag,
            access,
        );
    }

    pub fn ensurePromptCatalog(
        self: Operations,
        server: *McpServer,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !bool {
        return ensureFeatureCatalog(self, server, .prompts, deadline, cancel_flag, access);
    }

    fn ensureFeatureCatalog(
        self: Operations,
        server: *McpServer,
        kind: feature_catalog.FeatureCatalogKind,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !bool {
        var operation_access = try OperationAccessGuard.init(
            self.transport.alloc,
            access,
            self.transport.generation,
        );
        defer operation_access.deinit();
        const access_target = access_policy.Target{ .feature_server = server.config.name };
        const may_mutate_before_transport = switch (access) {
            .unrestricted => true,
            .disabled, .scoped => false,
        };
        try operation_access.authorize(access_target);
        try lockMutexUntil(&server.feature_refresh_lock, deadline, cancel_flag);
        var refresh_locked = true;
        defer if (refresh_locked) server.feature_refresh_lock.unlock(io_mod.getIo());
        const initial = initial: {
            try lockRwSharedUntil(self.transport.catalog_mutex, deadline, cancel_flag);
            defer self.transport.catalog_mutex.unlockShared(io_mod.getIo());
            const state = feature_catalog.featureCatalogState(server, kind);
            break :initial .{
                .metadata = state.metadata,
                .available = state.available,
                .invalidated = if (server.tool_subscription) |subscription|
                    subscription.hasInvalidationFor(kind.invalidation())
                else
                    false,
            };
        };
        const initial_scope = if (initial.metadata) |metadata| metadata.scope else .private;
        try operation_access.refreshAndAuthorize(access_target);
        const requested_key = try currentAuthPartition(self.transport.alloc, server, initial_scope, deadline, cancel_flag, .{ .alloc = self.transport.alloc, .runtime_generation = self.transport.generation, .access = access, .target = access_target });
        var may_serve_snapshot = false;
        if (initial.metadata) |metadata| {
            const decision = catalog_freshness.decideRefresh(
                metadata,
                requested_key,
                operation_control.monotonicMillis(io_mod.getIo()),
                initial.invalidated,
            );
            may_serve_snapshot = decision.may_serve_snapshot and initial.available;
            if (decision.action != .refresh) {
                try operation_access.refreshAndAuthorize(access_target);
                return may_serve_snapshot;
            }
            if (!may_serve_snapshot and may_mutate_before_transport) {
                try lockRwUntil(self.transport.catalog_mutex, deadline, cancel_flag);
                defer self.transport.catalog_mutex.unlock(io_mod.getIo());
                const current = feature_catalog.featureCatalogState(server, kind);
                if (current.metadata) |current_metadata| {
                    if (current_metadata.connection_generation == metadata.connection_generation and
                        current_metadata.catalog_generation == metadata.catalog_generation and
                        current_metadata.key.eql(metadata.key))
                    {
                        feature_catalog.setFeatureCatalogAvailable(server, kind, false);
                    }
                }
            }
        }

        const recovered = self.lifecycle.ensureFeatureServerRunning(
            server,
            self.transport.generation,
            deadline,
            cancel_flag,
            access,
        ) catch |err| {
            if (err == error.McpAccessDenied) return error.McpAccessDenied;
            if (err == error.McpAuthorityChanged) return error.McpAuthorityChanged;
            recordFeatureRefreshFailure(
                self,
                server,
                kind,
                initial.metadata,
                may_serve_snapshot,
                err,
            );
            if (may_serve_snapshot) return true;
            return err;
        };
        if (recovered) {
            server.feature_refresh_lock.unlock(io_mod.getIo());
            refresh_locked = false;
            return ensureFeatureCatalog(
                self,
                server,
                kind,
                deadline,
                cancel_flag,
                access,
            );
        }

        const invalidation_generation = if (server.tool_subscription) |subscription|
            subscription.invalidationGenerationFor(kind.invalidation())
        else
            0;

        const source_connection_generation = server.connection_generation;
        var fetched = fetchFeatureCatalogWithAuthRetry(self, server, kind, deadline, cancel_flag, access) catch |err| {
            if (err == error.McpAccessDenied) return error.McpAccessDenied;
            if (err == error.McpAuthorityChanged) return error.McpAuthorityChanged;
            recordFeatureRefreshFailure(
                self,
                server,
                kind,
                initial.metadata,
                may_serve_snapshot,
                err,
            );
            if (may_serve_snapshot) return true;
            return err;
        };
        defer fetched.deinit(self.transport.alloc);
        try operation_access.refreshAndAuthorize(access_target);
        const scope = fetched.scope();
        const replacement_key = if (fetched.authIdentity()) |identity|
            catalog_freshness.authPartition(scope, identity)
        else
            try currentAuthPartition(self.transport.alloc, server, scope, deadline, cancel_flag, .{ .alloc = self.transport.alloc, .runtime_generation = self.transport.generation, .access = access, .target = access_target });
        const digest = fetched.digest();

        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        defer server.connection_lock.unlockShared(io_mod.getIo());
        if (server.connection_generation != source_connection_generation) return feature_catalog.featureCatalogState(server, kind).available;
        try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
        defer server.catalog_commit_lock.unlock(io_mod.getIo());
        var auth_locked = false;
        defer if (auth_locked) server.auth_lock.unlock(io_mod.getIo());
        const active_key = if (scope == .private and server.config.transport != .stdio) active: {
            try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
            auth_locked = true;
            break :active catalog_freshness.authPartition(scope, try server_auth.currentAuthIdentity(self.transport.alloc, server));
        } else replacement_key;
        if (!active_key.eql(replacement_key)) return error.McpAuthIdentityChangedDuringPagination;

        try lockRwUntil(self.transport.catalog_mutex, deadline, cancel_flag);
        var catalog_locked = true;
        defer if (catalog_locked) self.transport.catalog_mutex.unlock(io_mod.getIo());
        const latest = feature_catalog.featureCatalogState(server, kind);
        if (server.connection_generation != source_connection_generation) return latest.available;
        const generation = if (latest.metadata) |metadata| generation: {
            const source = initial.metadata orelse {
                debug_trace.logf(
                    "mcp",
                    "rejected stale feature refresh server={s} feature={s} reason=source_missing",
                    .{ server.config.name, @tagName(kind) },
                );
                return latest.available;
            };
            const transition = catalog_freshness.authorizeReplacement(
                metadata,
                source.connection_generation,
                source.catalog_generation,
                active_key,
                replacement_key,
                digest,
            );
            break :generation switch (transition) {
                .reject_stale_generation => {
                    debug_trace.logf(
                        "mcp",
                        "rejected stale feature refresh server={s} feature={s} source_connection_generation={d} source_catalog_generation={d}",
                        .{
                            server.config.name,
                            @tagName(kind),
                            source.connection_generation,
                            source.catalog_generation,
                        },
                    );
                    return latest.available;
                },
                .reject_auth_partition => {
                    recordFeatureRefreshFailureLocked(
                        server,
                        kind,
                        source,
                        false,
                        error.McpAuthIdentityChangedDuringPagination,
                    );
                    return latest.available;
                },
                .metadata_only => metadata.catalog_generation,
                .replace_snapshot => std.math.add(
                    u64,
                    metadata.catalog_generation,
                    1,
                ) catch return error.McpGenerationExhausted,
            };
        } else generation: {
            if (initial.metadata != null or !active_key.eql(replacement_key)) {
                return latest.available;
            }
            break :generation 1;
        };
        const metadata = catalog_freshness.SnapshotMetadata{
            .key = replacement_key,
            .connection_generation = source_connection_generation,
            .catalog_generation = generation,
            .fetched_at_ms = fetched.fetchedAt(),
            .expires_at_ms = fetched.expiresAt(),
            .scope = scope,
            .content_digest = digest,
            .subscription = if (server.tool_subscription) |subscription| subscription.identity() else null,
        };
        const auth_generation = server.auth_generation.load(.acquire);
        var retired = publishFeatureCatalog(server, kind, &fetched, metadata, auth_generation);
        if (server.tool_subscription) |subscription| {
            subscription.clearInvalidationThroughFor(kind.invalidation(), invalidation_generation);
        }
        self.transport.catalog_mutex.unlock(io_mod.getIo());
        catalog_locked = false;
        retired.deinit(self.transport.alloc);
        debug_trace.logf(
            "mcp",
            "feature cache snapshot replaced server={s} feature={s} generation={d}",
            .{ server.config.name, @tagName(kind), generation },
        );
        return true;
    }

    const RetiredFeatureCatalog = union(feature_catalog.FeatureCatalogKind) {
        resources: ResourceCatalogSnapshot,
        resource_templates: ResourceTemplateCatalogSnapshot,
        prompts: PromptCatalogSnapshot,

        fn deinit(self: *RetiredFeatureCatalog, alloc: Allocator) void {
            switch (self.*) {
                .resources => |*value| value.deinit(alloc),
                .resource_templates => |*value| value.deinit(alloc),
                .prompts => |*value| value.deinit(alloc),
            }
            self.* = undefined;
        }
    };

    fn publishFeatureCatalog(
        server: *McpServer,
        kind: feature_catalog.FeatureCatalogKind,
        fetched: *FetchedFeatureCatalog,
        metadata: catalog_freshness.SnapshotMetadata,
        auth_generation: u64,
    ) RetiredFeatureCatalog {
        return switch (kind) {
            .resources => blk: {
                const retired = RetiredFeatureCatalog{ .resources = server.resource_catalog };
                server.resource_catalog = .{
                    .catalog = fetched.resources.catalog,
                    .metadata = metadata,
                    .auth_generation = auth_generation,
                    .available = true,
                };
                fetched.resources.catalog.items = &.{};
                break :blk retired;
            },
            .resource_templates => blk: {
                const retired = RetiredFeatureCatalog{ .resource_templates = server.resource_template_catalog };
                server.resource_template_catalog = .{
                    .catalog = fetched.resource_templates.catalog,
                    .metadata = metadata,
                    .auth_generation = auth_generation,
                    .available = true,
                };
                fetched.resource_templates.catalog.items = &.{};
                break :blk retired;
            },
            .prompts => blk: {
                const retired = RetiredFeatureCatalog{ .prompts = server.prompt_catalog };
                server.prompt_catalog = .{
                    .catalog = fetched.prompts.catalog,
                    .metadata = metadata,
                    .auth_generation = auth_generation,
                    .available = true,
                };
                fetched.prompts.catalog.prompts = &.{};
                break :blk retired;
            },
        };
    }

    fn recordFeatureRefreshFailure(
        self: Operations,
        server: *McpServer,
        kind: feature_catalog.FeatureCatalogKind,
        source: ?catalog_freshness.SnapshotMetadata,
        may_serve_snapshot: bool,
        err: anyerror,
    ) void {
        self.transport.catalog_mutex.lockUncancelable(io_mod.getIo());
        defer self.transport.catalog_mutex.unlock(io_mod.getIo());
        recordFeatureRefreshFailureLocked(server, kind, source, may_serve_snapshot, err);
    }

    fn recordFeatureRefreshFailureLocked(
        server: *McpServer,
        kind: feature_catalog.FeatureCatalogKind,
        source: ?catalog_freshness.SnapshotMetadata,
        may_serve_snapshot: bool,
        err: anyerror,
    ) void {
        const source_metadata = source orelse return;
        const current = feature_catalog.featureCatalogState(server, kind).metadata orelse return;
        if (current.connection_generation != source_metadata.connection_generation or
            current.catalog_generation != source_metadata.catalog_generation or
            !current.key.eql(source_metadata.key))
        {
            return;
        }
        const failed = catalog_freshness.failedRefresh(current, operation_control.monotonicMillis(io_mod.getIo()));
        switch (kind) {
            .resources => server.resource_catalog.metadata = failed,
            .resource_templates => server.resource_template_catalog.metadata = failed,
            .prompts => server.prompt_catalog.metadata = failed,
        }
        feature_catalog.setFeatureCatalogAvailable(server, kind, may_serve_snapshot);
        debug_trace.logf(
            "mcp",
            "feature cache refresh failed server={s} feature={s} preserved_snapshot={any} err={s}",
            .{ server.config.name, @tagName(kind), may_serve_snapshot, @errorName(err) },
        );
    }

    fn fetchFeatureCatalog(
        self: Operations,
        server: *McpServer,
        kind: feature_catalog.FeatureCatalogKind,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !FetchedFeatureCatalog {
        return switch (kind) {
            .resources => .{ .resources = try fetchResources(self, server, deadline, cancel_flag, access) },
            .resource_templates => .{ .resource_templates = try fetchResourceTemplates(self, server, deadline, cancel_flag, access) },
            .prompts => .{ .prompts = try fetchPrompts(self, server, deadline, cancel_flag, access) },
        };
    }

    fn fetchFeatureCatalogWithAuthRetry(
        self: Operations,
        server: *McpServer,
        kind: feature_catalog.FeatureCatalogKind,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !FetchedFeatureCatalog {
        var identity_restarts: u8 = 0;
        while (true) {
            return fetchFeatureCatalog(self, server, kind, deadline, cancel_flag, access) catch |err| switch (err) {
                error.McpAuthIdentityChangedDuringPagination => {
                    if (identity_restarts >= mcp_auth.max_scope_reauthorizations) {
                        return error.McpAuthenticationRetryLimit;
                    }
                    identity_restarts += 1;
                    debug_trace.logf(
                        "mcp",
                        "restarting paginated feature fetch after auth identity change server={s} feature={s} attempt={d}",
                        .{ server.config.name, @tagName(kind), identity_restarts },
                    );
                    continue;
                },
                else => |other| return other,
            };
        }
    }

    const FetchedResources = struct { catalog: resources_feature.ResourceCatalog, auth_identity: ?catalog_freshness.Digest = null };
    const FetchedResourceTemplates = struct { catalog: resources_feature.TemplateCatalog, auth_identity: ?catalog_freshness.Digest = null };
    const FetchedPrompts = struct { catalog: prompts_feature.Catalog, auth_identity: ?catalog_freshness.Digest = null };

    fn fetchResources(self: Operations, server: *McpServer, deadline: std.Io.Clock.Timestamp, cancel_flag: ?*std.atomic.Value(bool), access: tool_mcp_runtime.Access) !FetchedResources {
        var builder = resources_feature.ResourceCatalogBuilder.init(self.transport.alloc, serverFeatureProtocol(server));
        defer builder.deinit(self.transport.alloc);
        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.transport.alloc.free(value);
        var producing_identity: ?catalog_freshness.Digest = null;
        while (true) {
            var exchange = try request_feature_catalog_page(
                self,
                server,
                .resources,
                cursor,
                deadline,
                cancel_flag,
                access,
            );
            defer exchange.response.deinit(self.transport.alloc);
            try acceptPageIdentity(&producing_identity, exchange.response.auth_identity);
            var page = try resources_feature.parseResourcePage(self.transport.alloc, exchange.response.body, serverFeatureProtocol(server), .{});
            defer page.deinit(self.transport.alloc);
            try replaceOwnedCursor(self.transport.alloc, &cursor, page.next_cursor);
            try builder.appendPage(self.transport.alloc, &page, exchange.received_at_ms, .{});
            if (cursor == null) return .{ .catalog = try builder.finish(self.transport.alloc), .auth_identity = producing_identity };
        }
    }

    fn fetchResourceTemplates(self: Operations, server: *McpServer, deadline: std.Io.Clock.Timestamp, cancel_flag: ?*std.atomic.Value(bool), access: tool_mcp_runtime.Access) !FetchedResourceTemplates {
        var builder = resources_feature.TemplateCatalogBuilder.init(self.transport.alloc, serverFeatureProtocol(server));
        defer builder.deinit(self.transport.alloc);
        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.transport.alloc.free(value);
        var producing_identity: ?catalog_freshness.Digest = null;
        while (true) {
            var exchange = try request_feature_catalog_page(
                self,
                server,
                .resource_templates,
                cursor,
                deadline,
                cancel_flag,
                access,
            );
            defer exchange.response.deinit(self.transport.alloc);
            try acceptPageIdentity(&producing_identity, exchange.response.auth_identity);
            var page = try resources_feature.parseTemplatePage(self.transport.alloc, exchange.response.body, serverFeatureProtocol(server), .{});
            defer page.deinit(self.transport.alloc);
            try replaceOwnedCursor(self.transport.alloc, &cursor, page.next_cursor);
            try builder.appendPage(self.transport.alloc, &page, exchange.received_at_ms, .{});
            if (cursor == null) return .{ .catalog = try builder.finish(self.transport.alloc), .auth_identity = producing_identity };
        }
    }

    fn fetchPrompts(self: Operations, server: *McpServer, deadline: std.Io.Clock.Timestamp, cancel_flag: ?*std.atomic.Value(bool), access: tool_mcp_runtime.Access) !FetchedPrompts {
        var builder = prompts_feature.CatalogBuilder.init(self.transport.alloc, serverFeatureProtocol(server));
        defer builder.deinit(self.transport.alloc);
        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.transport.alloc.free(value);
        var producing_identity: ?catalog_freshness.Digest = null;
        while (true) {
            var exchange = try request_feature_catalog_page(
                self,
                server,
                .prompts,
                cursor,
                deadline,
                cancel_flag,
                access,
            );
            defer exchange.response.deinit(self.transport.alloc);
            try acceptPageIdentity(&producing_identity, exchange.response.auth_identity);
            var page = try prompts_feature.parseListPage(self.transport.alloc, exchange.response.body, serverFeatureProtocol(server), .{});
            defer page.deinit(self.transport.alloc);
            try replaceOwnedCursor(self.transport.alloc, &cursor, page.next_cursor);
            try builder.appendPage(self.transport.alloc, &page, exchange.received_at_ms, .{});
            if (cursor == null) return .{ .catalog = try builder.finish(self.transport.alloc), .auth_identity = producing_identity };
        }
    }

    fn acceptPageIdentity(producing: *?catalog_freshness.Digest, incoming: ?catalog_freshness.Digest) !void {
        const page = incoming orelse return;
        if (producing.*) |identity| {
            if (!std.mem.eql(u8, &identity, &page)) return error.McpAuthIdentityChangedDuringPagination;
        } else producing.* = page;
    }

    const FeatureCatalogPageResponse = struct {
        response: FeatureResponse,
        received_at_ms: u64,
    };

    fn request_feature_catalog_page(
        self: Operations,
        server: *McpServer,
        kind: feature_catalog.FeatureCatalogKind,
        cursor: ?[]const u8,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !FeatureCatalogPageResponse {
        try (operation_authority.EffectAccess{
            .alloc = self.transport.alloc,
            .runtime_generation = self.transport.generation,
            .access = access,
            .target = .{ .feature_server = server.config.name },
        }).authorize();
        const request_id = try nextFeatureRequestId(server);
        const protocol = serverFeatureProtocol(server);
        const request = switch (kind) {
            .resources => try resources_feature.buildListRequest(
                self.transport.alloc,
                request_id,
                protocol,
                cursor,
                writeModernRequestMetadata,
            ),
            .resource_templates => try resources_feature.buildTemplatesListRequest(
                self.transport.alloc,
                request_id,
                protocol,
                cursor,
                writeModernRequestMetadata,
            ),
            .prompts => try prompts_feature.buildListRequest(
                self.transport.alloc,
                request_id,
                protocol,
                cursor,
                writeModernRequestMetadata,
            ),
        };
        defer self.transport.alloc.free(request);
        var guard = ServerAccessPrecommit{
            .authority = .{ .alloc = self.transport.alloc, .runtime_generation = self.transport.generation, .access = access, .target = .{ .feature_server = server.config.name } },
            .cancel_flag = server.cancellation(),
        };
        var precommit = guard.transport();
        return .{
            .response = try self.transport.send(
                server,
                request_id,
                request,
                deadline,
                cancel_flag,
                access,
                &precommit,
                null,
            ),
            .received_at_ms = operation_control.monotonicMillis(io_mod.getIo()),
        };
    }
};

pub fn digestResources(items: []const resources_feature.Descriptor) catalog_freshness.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (items) |item| {
        catalog_state.hashField(&hasher, item.uri);
        catalog_state.hashField(&hasher, item.name);
        catalog_state.hashOptionalField(&hasher, item.title);
        catalog_state.hashOptionalField(&hasher, item.description);
        catalog_state.hashOptionalField(&hasher, item.mime_type);
        catalog_state.hashOptionalU64(&hasher, item.size);
        catalog_state.hashOptionalField(&hasher, item.icons_json);
        catalog_state.hashOptionalField(&hasher, item.annotations_json);
        catalog_state.hashOptionalField(&hasher, item.metadata_json);
    }
    var digest: catalog_freshness.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn digestResourceTemplates(items: []const resources_feature.Template) catalog_freshness.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (items) |item| {
        catalog_state.hashField(&hasher, item.uri_template);
        catalog_state.hashField(&hasher, item.name);
        catalog_state.hashOptionalField(&hasher, item.title);
        catalog_state.hashOptionalField(&hasher, item.description);
        catalog_state.hashOptionalField(&hasher, item.mime_type);
        catalog_state.hashOptionalField(&hasher, item.icons_json);
        catalog_state.hashOptionalField(&hasher, item.annotations_json);
        catalog_state.hashOptionalField(&hasher, item.metadata_json);
    }
    var digest: catalog_freshness.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn digestPrompts(items: []const prompts_feature.Prompt) catalog_freshness.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (items) |item| {
        catalog_state.hashField(&hasher, item.name);
        catalog_state.hashOptionalField(&hasher, item.title);
        catalog_state.hashOptionalField(&hasher, item.description);
        catalog_state.hashOptionalField(&hasher, item.icons_json);
        for (item.arguments) |argument| {
            catalog_state.hashField(&hasher, argument.name);
            catalog_state.hashOptionalField(&hasher, argument.description);
            hasher.update(&.{@intFromBool(argument.required)});
        }
        catalog_state.hashOptionalField(&hasher, item.metadata_json);
    }
    var digest: catalog_freshness.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn replaceOwnedCursor(
    alloc: Allocator,
    cursor: *?[]u8,
    next_cursor: ?[]const u8,
) !void {
    const replacement = if (next_cursor) |value|
        try alloc.dupe(u8, value)
    else
        null;
    if (cursor.*) |value| alloc.free(value);
    cursor.* = replacement;
}
