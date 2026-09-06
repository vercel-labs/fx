const feature_catalog_runtime = @import("feature_catalog_runtime.zig");
const legacy_elicitation_runtime = @import("legacy_elicitation_runtime.zig");
const std = @import("std");
const server_connection = @import("server_connection.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const server_auth = @import("server_auth.zig");
const server_subscriptions = @import("server_subscriptions.zig");
const tool_catalog = @import("tool_catalog.zig");
const feature_catalog = @import("feature_catalog.zig");
const feature_snapshot = @import("feature_snapshot.zig");
const FeatureIdentitySnapshot = feature_snapshot.Snapshot;
const FeaturePrecommit = feature_snapshot.CommitGuard;
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const elicitation = @import("elicitation.zig");
const mrtr = @import("mrtr.zig");
const operation_control = @import("operation_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const protocol_messages = @import("protocol_messages.zig");
const writeModernRequestMetadata = protocol_messages.writeModernRequestMetadata;
const featureProtocol = protocol_messages.featureProtocol;
const catalog_freshness = @import("catalog_freshness.zig");
const access_policy = @import("access_policy.zig");
const tool_subscription = @import("tool_subscription.zig");
const completion_feature = @import("features/completion.zig");
const prompts_feature = @import("features/prompts.zig");
const resources_feature = @import("features/resources.zig");
const tool_result = @import("tool_result.zig");
const Allocator = std.mem.Allocator;
const max_resource_read_cache_entries: usize = 64;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const lockRwUntil = controlled_lock.rwUntil;
const lockMutexUntil = controlled_lock.mutexUntil;
const operation_authority = @import("operation_authority.zig");
const nextFeatureRequestId = server_connection.featureRequestId;
const serverFeatureProtocol = server_connection.featureProtocol;
const catalog_state = @import("catalog_state.zig");
const ResourceReadCacheEntry = catalog_state.ResourceReadCacheEntry;
const feature_result = @import("feature_result.zig");
const ResourceSummary = feature_result.ResourceSummary;
const ResourceCatalogResult = feature_result.ResourceCatalogResult;
const PromptSummary = feature_result.PromptSummary;
const PromptCatalogResult = feature_result.PromptCatalogResult;
const FeatureCallOptions = feature_result.FeatureCallOptions;
const ResourceReadResult = feature_result.ResourceReadResult;
const PromptGetResult = feature_result.PromptGetResult;
const CompletionResult = feature_result.CompletionResult;
const OperationAccessGuard = operation_authority.Guard;
const McpServer = server_connection.Server;
const currentAuthPartition = server_auth.currentAuthPartition;
const operationDeadline = server_connection.operationDeadline;

const Context = feature_catalog_runtime.Operations;
fn cloneResourceSummary(alloc: Allocator, server_name: []const u8, resource: resources_feature.Descriptor) !ResourceSummary {
    const owned_server = try alloc.dupe(u8, server_name);
    errdefer alloc.free(owned_server);
    const uri = try alloc.dupe(u8, resource.uri);
    errdefer alloc.free(uri);
    const name = try alloc.dupe(u8, resource.name);
    errdefer alloc.free(name);
    const title = if (resource.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const description = if (resource.description) |value| try alloc.dupe(u8, value) else null;
    errdefer if (description) |value| alloc.free(value);
    const mime_type = if (resource.mime_type) |value| try alloc.dupe(u8, value) else null;
    return .{
        .server_name = owned_server,
        .uri = uri,
        .name = name,
        .title = title,
        .description = description,
        .mime_type = mime_type,
    };
}

fn cloneTemplateSummary(alloc: Allocator, server_name: []const u8, template: resources_feature.Template) !ResourceSummary {
    const owned_server = try alloc.dupe(u8, server_name);
    errdefer alloc.free(owned_server);
    const uri = try alloc.dupe(u8, template.uri_template);
    errdefer alloc.free(uri);
    const name = try alloc.dupe(u8, template.name);
    errdefer alloc.free(name);
    const title = if (template.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const description = if (template.description) |value| try alloc.dupe(u8, value) else null;
    errdefer if (description) |value| alloc.free(value);
    const mime_type = if (template.mime_type) |value| try alloc.dupe(u8, value) else null;
    return .{
        .server_name = owned_server,
        .uri = uri,
        .name = name,
        .title = title,
        .description = description,
        .mime_type = mime_type,
        .is_template = true,
    };
}

fn clonePromptSummary(alloc: Allocator, server_name: []const u8, prompt: prompts_feature.Prompt) !PromptSummary {
    const owned_server = try alloc.dupe(u8, server_name);
    errdefer alloc.free(owned_server);
    const name = try alloc.dupe(u8, prompt.name);
    errdefer alloc.free(name);
    const title = if (prompt.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const description = if (prompt.description) |value| try alloc.dupe(u8, value) else null;
    errdefer if (description) |value| alloc.free(value);
    const arguments = try alloc.alloc(prompts_feature.Argument, prompt.arguments.len);
    var count: usize = 0;
    errdefer {
        for (arguments[0..count]) |*argument| argument.deinit(alloc);
        alloc.free(arguments);
    }
    for (prompt.arguments, 0..) |argument, index| {
        const argument_name = try alloc.dupe(u8, argument.name);
        errdefer alloc.free(argument_name);
        const argument_description = if (argument.description) |value| try alloc.dupe(u8, value) else null;
        arguments[index] = .{
            .name = argument_name,
            .description = argument_description,
            .required = argument.required,
        };
        count += 1;
    }
    return .{
        .server_name = owned_server,
        .name = name,
        .title = title,
        .description = description,
        .arguments = arguments,
    };
}

pub const FetchedResourceRead = struct {
    result: resources_feature.ReadResult,
    auth_identity: ?catalog_freshness.Digest,
    received_at_ms: u64,
};

fn cachedResourceRead(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    allow_stale: bool,
    access: tool_mcp_runtime.Access,
) !?ResourceReadResult {
    const public_key = catalog_freshness.authPartition(.public, catalog_freshness.authIdentity(&.{}));
    try lockRwSharedUntil(self.transport.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) self.transport.catalog_mutex.unlockShared(io_mod.getIo());
    var has_private_candidate = false;
    for (server.resource_read_cache.items) |entry| {
        if (!std.mem.eql(u8, entry.uri, uri)) continue;
        if (entry.metadata.scope == .private) {
            has_private_candidate = true;
            continue;
        }
        if (!entry.metadata.key.eql(public_key)) continue;
        const freshness = catalog_freshness.effectiveFreshness(entry.metadata, operation_control.monotonicMillis(io_mod.getIo()), false);
        if (!allow_stale and freshness != .fresh) continue;
        if (allow_stale and freshness == .fresh) continue;
        return @as(?ResourceReadResult, try cloneCachedResourceRead(
            alloc,
            server.config.name,
            uri,
            entry.result,
        ));
    }
    self.transport.catalog_mutex.unlockShared(io_mod.getIo());
    catalog_locked = false;
    if (!has_private_candidate) return null;

    const private_key = try currentAuthPartition(self.transport.alloc, server, .private, deadline, cancel_flag, .{
        .alloc = self.transport.alloc,
        .runtime_generation = self.transport.generation,
        .access = access,
        .target = .{ .feature_server = server.config.name },
    });
    try lockRwSharedUntil(self.transport.catalog_mutex, deadline, cancel_flag);
    defer self.transport.catalog_mutex.unlockShared(io_mod.getIo());
    for (server.resource_read_cache.items) |entry| {
        if (!std.mem.eql(u8, entry.uri, uri) or entry.metadata.scope != .private) continue;
        if (!entry.metadata.key.eql(private_key) or
            entry.auth_generation != server.auth_generation.load(.acquire))
        {
            continue;
        }
        const freshness = catalog_freshness.effectiveFreshness(entry.metadata, operation_control.monotonicMillis(io_mod.getIo()), false);
        if (!allow_stale and freshness != .fresh) continue;
        if (allow_stale and freshness == .fresh) continue;
        return @as(?ResourceReadResult, try cloneCachedResourceRead(
            alloc,
            server.config.name,
            uri,
            entry.result,
        ));
    }
    return null;
}

fn invalidateResourceReadCacheIfNeeded(
    self: Context,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    const subscription = server.tool_subscription orelse return;
    const generation = subscription.resourceUpdateGeneration();
    if (!subscription.hasInvalidationFor(.resource_read)) return;
    try lockRwUntil(self.transport.catalog_mutex, deadline, cancel_flag);
    var lock_held = true;
    defer if (lock_held) self.transport.catalog_mutex.unlock(io_mod.getIo());
    for (server.resource_read_cache.items) |*entry| entry.deinit(self.transport.alloc);
    server.resource_read_cache.clearRetainingCapacity();
    self.transport.catalog_mutex.unlock(io_mod.getIo());
    lock_held = false;
    subscription.clearResourceUpdatesThrough(generation);
    debug_trace.logf(
        "mcp",
        "resource read cache invalidated server={s} notification_generation={d}",
        .{ server.config.name, generation },
    );
}

fn ensureResourceUpdateSubscription(
    self: Context,
    server: *McpServer,
    requested_uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !void {
    var operation_access = try OperationAccessGuard.init(
        self.transport.alloc,
        access,
        self.transport.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server.config.name });
    switch (access) {
        .unrestricted => {},
        .disabled, .scoped => return,
    }
    if (!server.capabilities.resources_subscribe or serverFeatureProtocol(server) != .modern) {
        return;
    }

    var resource_uris: std.ArrayList([]u8) = .empty;
    defer {
        for (resource_uris.items) |uri| self.transport.alloc.free(uri);
        resource_uris.deinit(self.transport.alloc);
    }
    {
        try lockRwSharedUntil(self.transport.catalog_mutex, deadline, cancel_flag);
        defer self.transport.catalog_mutex.unlockShared(io_mod.getIo());
        for (server.resource_read_cache.items) |entry| {
            try appendUniqueOwnedUri(self.transport.alloc, &resource_uris, entry.uri);
        }
    }
    try appendUniqueOwnedUri(self.transport.alloc, &resource_uris, requested_uri);

    try lockMutexUntil(&server.subscription_lifecycle_lock, deadline, cancel_flag);
    defer server.subscription_lifecycle_lock.unlock(io_mod.getIo());
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    var candidate: ?*tool_subscription.State = null;
    defer if (candidate) |subscription| subscription.stopAndDestroy();

    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    var commit_locked = true;
    defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
    try lockRwUntil(self.transport.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) self.transport.catalog_mutex.unlock(io_mod.getIo());
    if (server.tool_subscription) |subscription| {
        if (subscription.subscribesToResource(requested_uri)) return;
        for (subscription.resourceSubscriptions()) |uri| {
            try appendUniqueOwnedUri(self.transport.alloc, &resource_uris, uri);
        }
    }

    if (server.tool_subscription) |subscription| subscription.requestStop();
    const previous = server.detachToolSubscription();
    expireMcpSnapshotsForSubscriptionHandoff(self, server);
    self.transport.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    server.catalog_commit_lock.unlock(io_mod.getIo());
    commit_locked = false;

    if (previous) |subscription| subscription.stopAndDestroy();
    candidate = server_subscriptions.createToolSubscriptionWithResources(
        self.transport.alloc,
        server,
        resource_uris.items,
        .{
            .deadline = deadline,
            .cancel_flag = cancel_flag,
            .lifecycle_cancel_flag = server.cancellation(),
        },
    ) catch |err| {
        debug_trace.logf(
            "mcp",
            "resource update subscription unavailable server={s} uri={s} err={s}",
            .{ server.config.name, requested_uri, @errorName(err) },
        );
        return err;
    };
    if (candidate == null) return;

    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    commit_locked = true;
    try lockRwUntil(self.transport.catalog_mutex, deadline, cancel_flag);
    catalog_locked = true;
    if (server.tool_subscription != null) return;
    server_subscriptions.publishToolSubscription(server, candidate.?);
    candidate = null;
    self.transport.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    server.catalog_commit_lock.unlock(io_mod.getIo());
    commit_locked = false;
    debug_trace.logf(
        "mcp",
        "resource update subscription installed server={s} watched_resources={d}",
        .{ server.config.name, resource_uris.items.len },
    );
}

fn appendUniqueOwnedUri(
    alloc: Allocator,
    uris: *std.ArrayList([]u8),
    uri: []const u8,
) !void {
    for (uris.items) |candidate| {
        if (std.mem.eql(u8, candidate, uri)) return;
    }
    const owned = try alloc.dupe(u8, uri);
    errdefer alloc.free(owned);
    try uris.append(alloc, owned);
}

fn expireMcpSnapshotsForSubscriptionHandoff(self: Context, server: *McpServer) void {
    if (server.tool_catalog.metadata) |*metadata| metadata.expires_at_ms = 0;
    if (server.resource_catalog.metadata) |*metadata| metadata.expires_at_ms = 0;
    if (server.resource_template_catalog.metadata) |*metadata| metadata.expires_at_ms = 0;
    if (server.prompt_catalog.metadata) |*metadata| metadata.expires_at_ms = 0;
    for (server.resource_read_cache.items) |*entry| entry.deinit(self.transport.alloc);
    server.resource_read_cache.clearRetainingCapacity();
}

fn cloneCachedResourceRead(
    alloc: Allocator,
    server_name: []const u8,
    uri: []const u8,
    result: resources_feature.ReadResult,
) !ResourceReadResult {
    const owned_server = try alloc.dupe(u8, server_name);
    errdefer alloc.free(owned_server);
    const owned_uri = try alloc.dupe(u8, uri);
    errdefer alloc.free(owned_uri);
    const contents = try cloneResourceContents(alloc, result.contents);
    return .{ .server_name = owned_server, .uri = owned_uri, .contents = contents };
}

fn cloneResourceContents(
    alloc: Allocator,
    source: []const resources_feature.ResourceContent,
) ![]resources_feature.ResourceContent {
    const contents = try alloc.alloc(resources_feature.ResourceContent, source.len);
    var count: usize = 0;
    errdefer {
        for (contents[0..count]) |*content| content.deinit(alloc);
        alloc.free(contents);
    }
    for (source, 0..) |content, index| {
        const uri = try alloc.dupe(u8, content.uri);
        errdefer alloc.free(uri);
        const mime_type = if (content.mime_type) |value| try alloc.dupe(u8, value) else null;
        errdefer if (mime_type) |value| alloc.free(value);
        const annotations_json = if (content.annotations_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (annotations_json) |value| alloc.free(value);
        const metadata_json = if (content.metadata_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (metadata_json) |value| alloc.free(value);
        const data: resources_feature.ResourceData = switch (content.data) {
            .text => |value| .{ .text = try alloc.dupe(u8, value) },
            .blob => |value| .{ .blob = try alloc.dupe(u8, value) },
        };
        contents[index] = .{
            .uri = uri,
            .mime_type = mime_type,
            .annotations_json = annotations_json,
            .metadata_json = metadata_json,
            .data = data,
        };
        count += 1;
    }
    return contents;
}

fn publishResourceReadCache(
    self: Context,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    uri: []const u8,
    fetched: FetchedResourceRead,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !void {
    const scope: catalog_freshness.CacheScope = switch (fetched.result.cache.scope) {
        .private => .private,
        .public => .public,
    };
    const replacement_key = if (fetched.auth_identity) |identity|
        catalog_freshness.authPartition(scope, identity)
    else
        try currentAuthPartition(self.transport.alloc, server, scope, deadline, cancel_flag, .{
            .alloc = self.transport.alloc,
            .runtime_generation = self.transport.generation,
            .access = access,
            .target = .{ .feature_server = server.config.name },
        });
    const active_key = try currentAuthPartition(self.transport.alloc, server, scope, deadline, cancel_flag, .{
        .alloc = self.transport.alloc,
        .runtime_generation = self.transport.generation,
        .access = access,
        .target = .{ .feature_server = server.config.name },
    });
    if (!replacement_key.eql(active_key)) return;
    const contents = try cloneResourceContents(self.transport.alloc, fetched.result.contents);
    var candidate = resources_feature.ReadResult{ .contents = contents, .cache = fetched.result.cache };
    defer candidate.deinit(self.transport.alloc);
    var owned_uri: ?[]u8 = try self.transport.alloc.dupe(u8, uri);
    defer if (owned_uri) |value| self.transport.alloc.free(value);
    const expires_at_ms = catalog_freshness.pageExpiry(
        if (serverFeatureProtocol(server) == .modern) .modern else .legacy,
        fetched.received_at_ms,
        fetched.result.cache.ttl_present,
        fetched.result.cache.ttl_ms,
    );
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    if (server.connection_generation != snapshot.connection_generation) return;
    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    defer server.catalog_commit_lock.unlock(io_mod.getIo());
    var subscription: ?*tool_subscription.State = null;
    defer if (subscription) |state| state.unlockCommit();
    if (server.tool_subscription) |state| {
        if (!state.lockFeatureCommitIfCurrent(.resource_read)) return;
        subscription = state;
    }
    var auth_locked = false;
    defer if (auth_locked) server.auth_lock.unlock(io_mod.getIo());
    const committed_key = if (scope == .private and server.config.transport != .stdio) key: {
        try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
        auth_locked = true;
        break :key catalog_freshness.authPartition(scope, try server_auth.currentAuthIdentity(self.transport.alloc, server));
    } else active_key;
    if (!replacement_key.eql(committed_key)) return;
    try lockRwUntil(self.transport.catalog_mutex, deadline, cancel_flag);
    var lock_held = true;
    defer if (lock_held) self.transport.catalog_mutex.unlock(io_mod.getIo());
    if (!feature_snapshot.featureSnapshotCurrent(server, snapshot)) return;
    var generation: u64 = 1;
    var replacement_index: ?usize = null;
    for (server.resource_read_cache.items, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.uri, uri)) continue;
        generation = std.math.add(u64, entry.metadata.catalog_generation, 1) catch
            return error.McpGenerationExhausted;
        replacement_index = index;
        break;
    }
    if (replacement_index == null and
        server.resource_read_cache.items.len < max_resource_read_cache_entries)
    {
        try server.resource_read_cache.ensureUnusedCapacity(self.transport.alloc, 1);
    }
    var replaced: ?ResourceReadCacheEntry = null;
    defer if (replaced) |*entry| entry.deinit(self.transport.alloc);
    if (replacement_index) |index| {
        replaced = server.resource_read_cache.orderedRemove(index);
    } else if (server.resource_read_cache.items.len >= max_resource_read_cache_entries) {
        var evicted = server.resource_read_cache.orderedRemove(0);
        evicted.deinit(self.transport.alloc);
    }
    server.resource_read_cache.appendAssumeCapacity(.{
        .uri = owned_uri.?,
        .result = candidate,
        .metadata = .{
            .key = replacement_key,
            .connection_generation = server.connection_generation,
            .catalog_generation = generation,
            .fetched_at_ms = fetched.received_at_ms,
            .expires_at_ms = expires_at_ms,
            .scope = scope,
            .content_digest = digestResourceContents(fetched.result.contents),
        },
        .auth_generation = server.auth_generation.load(.acquire),
    });
    owned_uri = null;
    candidate.contents = &.{};
    self.transport.catalog_mutex.unlock(io_mod.getIo());
    lock_held = false;
}

fn digestResourceContents(items: []const resources_feature.ResourceContent) catalog_freshness.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (items) |item| {
        catalog_state.hashField(&hasher, item.uri);
        catalog_state.hashOptionalField(&hasher, item.mime_type);
        catalog_state.hashOptionalField(&hasher, item.annotations_json);
        catalog_state.hashOptionalField(&hasher, item.metadata_json);
        switch (item.data) {
            .text => |value| catalog_state.hashField(&hasher, value),
            .blob => |value| catalog_state.hashField(&hasher, value),
        }
    }
    var digest: catalog_freshness.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn requestResourceRead(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    options: FeatureCallOptions,
) !FetchedResourceRead {
    return requestResourceReadRound(self, alloc, server, snapshot, uri, deadline, options, null, null, 0);
}

fn requestResourceReadRound(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    options: FeatureCallOptions,
    input_responses_json: ?[]const u8,
    request_state_json: ?[]const u8,
    round: u8,
) !FetchedResourceRead {
    if (server.lifetime.retiring.load(.acquire)) return error.Cancelled;
    try (operation_authority.EffectAccess{ .alloc = self.transport.alloc, .runtime_generation = self.transport.generation, .access = options.access, .target = .{ .feature_server = server.config.name } }).authorize();
    const request_id = try nextFeatureRequestId(server);
    const request = try resources_feature.buildReadRequest(
        alloc,
        request_id,
        serverFeatureProtocol(server),
        uri,
        protocol_messages.metadataWriterForCapabilities(if (options.input_responder) |responder| responder.capabilities else .{}),
        input_responses_json,
        request_state_json,
    );
    defer alloc.free(request);
    var guard = FeaturePrecommit{ .alloc = self.transport.alloc, .runtime_generation = self.transport.generation, .catalog_mutex = self.transport.catalog_mutex, .server = server, .snapshot = snapshot, .deadline = deadline, .cancel_flag = options.cancel_flag, .access = options.access };
    var precommit = guard.transport();
    var response = try self.transport.send(
        server,
        request_id,
        request,
        deadline,
        options.cancel_flag,
        options.access,
        &precommit,
        .{ .responder = options.input_responder, .operation = .{ .resources_read = uri } },
    );
    const received_at_ms = operation_control.monotonicMillis(io_mod.getIo());
    defer response.deinit(self.transport.alloc);
    var outcome = try resources_feature.parseReadOutcomeForRequest(
        alloc,
        response.body,
        serverFeatureProtocol(server),
        .{},
        .{
            .input_responses_present = input_responses_json != null,
            .request_state_present = request_state_json != null,
        },
    );
    defer outcome.deinit(alloc);
    switch (outcome) {
        .complete => |*complete| {
            response.finishLegacy(self.transport.alloc, .completed);
            const result = complete.*;
            complete.contents = &.{};
            return .{
                .result = result,
                .auth_identity = response.auth_identity,
                .received_at_ms = received_at_ms,
            };
        },
        .protocol_failure => |failure| {
            if (round >= 8) return error.McpInputRequiredLimitExceeded;
            if (try respondToLegacyUrlRequired(
                self,
                alloc,
                server,
                snapshot,
                .{ .resources_read = uri },
                failure.code,
                failure.data_json,
                options,
                round,
            )) |handled| {
                if (handled.decision != .retry) {
                    handled.responder.finish(alloc, handled.origin, .abandoned);
                    return error.McpInputRequired;
                }
                const continued = requestResourceReadRound(
                    self,
                    alloc,
                    server,
                    snapshot,
                    uri,
                    operationDeadline(server),
                    options,
                    null,
                    null,
                    round + 1,
                ) catch |err| {
                    handled.responder.finish(alloc, handled.origin, .abandoned);
                    return err;
                };
                handled.responder.finish(alloc, handled.origin, .completed);
                return continued;
            }
            try retainFeatureProtocolDiagnostic(alloc, options, failure);
            return error.McpProtocolError;
        },
        .input_required => |*required| {
            if (round >= 8) return error.McpInputRequiredLimitExceeded;
            const responder = options.input_responder orelse return error.McpInputRequired;
            const requests_json = try mrtr.renderRequests(alloc, required.requests);
            defer alloc.free(requests_json);
            const compatibility = tool_mcp_runtime.InputRequired{
                .input_requests_json = requests_json,
                .request_state_json = required.request_state_json,
            };
            const interaction_deadline = operation_control.elicitationDeadline(io_mod.getIo());
            const origin = tool_mcp_runtime.InputOrigin{
                .wire = .modern_mcp,
                .server_name = snapshot.server_name,
                .operation = .{ .resources_read = uri },
                .runtime_generation = self.transport.completions.runtime_generation,
                .connection_generation = snapshot.connection_generation,
                .client_generation = snapshot.connection_generation,
                .catalog_generation = snapshot.catalog_generation,
                .request_generation = round + 1,
                .auth_generation = server.auth_generation.load(.acquire),
                .deadline_ms = operation_control.timestampMillis(interaction_deadline),
                .lifecycle_cancel_flag = server.cancellation(),
            };
            const responses = try responder.callback(
                responder.context,
                alloc,
                origin,
                compatibility,
            );
            defer alloc.free(responses);
            try mrtr.validateResponses(alloc, required.requests, responses, .{});
            const continued = requestResourceReadRound(
                self,
                alloc,
                server,
                snapshot,
                uri,
                operationDeadline(server),
                options,
                responses,
                required.request_state_json,
                round + 1,
            ) catch |err| {
                responder.finish(alloc, origin, .abandoned);
                return err;
            };
            responder.finish(alloc, origin, .completed);
            return continued;
        },
    }
}

fn requestPromptGet(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    name: []const u8,
    arguments_json: []const u8,
    deadline: std.Io.Clock.Timestamp,
    options: FeatureCallOptions,
) !prompts_feature.GetResult {
    return requestPromptGetRound(self, alloc, server, snapshot, name, arguments_json, deadline, options, null, null, 0);
}

fn requestPromptGetRound(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    name: []const u8,
    arguments_json: []const u8,
    deadline: std.Io.Clock.Timestamp,
    options: FeatureCallOptions,
    input_responses_json: ?[]const u8,
    request_state_json: ?[]const u8,
    round: u8,
) !prompts_feature.GetResult {
    if (server.lifetime.retiring.load(.acquire)) return error.Cancelled;
    try (operation_authority.EffectAccess{ .alloc = self.transport.alloc, .runtime_generation = self.transport.generation, .access = options.access, .target = .{ .feature_server = server.config.name } }).authorize();
    const request_id = try nextFeatureRequestId(server);
    const request = try prompts_feature.buildGetRequest(
        alloc,
        request_id,
        serverFeatureProtocol(server),
        name,
        arguments_json,
        protocol_messages.metadataWriterForCapabilities(if (options.input_responder) |responder| responder.capabilities else .{}),
        input_responses_json,
        request_state_json,
    );
    defer alloc.free(request);
    var guard = FeaturePrecommit{ .alloc = self.transport.alloc, .runtime_generation = self.transport.generation, .catalog_mutex = self.transport.catalog_mutex, .server = server, .snapshot = snapshot, .deadline = deadline, .cancel_flag = options.cancel_flag, .access = options.access };
    var precommit = guard.transport();
    var response = try self.transport.send(
        server,
        request_id,
        request,
        deadline,
        options.cancel_flag,
        options.access,
        &precommit,
        .{ .responder = options.input_responder, .operation = .{ .prompts_get = name } },
    );
    defer response.deinit(self.transport.alloc);
    var outcome = try prompts_feature.parseGetOutcome(alloc, response.body, serverFeatureProtocol(server), .{});
    defer outcome.deinit(alloc);
    switch (outcome) {
        .complete => |*complete| {
            response.finishLegacy(self.transport.alloc, .completed);
            const result = complete.*;
            complete.description = null;
            complete.messages = &.{};
            return result;
        },
        .protocol_failure => |failure| {
            if (round >= 8) return error.McpInputRequiredLimitExceeded;
            if (try respondToLegacyUrlRequired(
                self,
                alloc,
                server,
                snapshot,
                .{ .prompts_get = name },
                failure.code,
                failure.data_json,
                options,
                round,
            )) |handled| {
                if (handled.decision != .retry) {
                    handled.responder.finish(alloc, handled.origin, .abandoned);
                    return error.McpInputRequired;
                }
                const continued = requestPromptGetRound(
                    self,
                    alloc,
                    server,
                    snapshot,
                    name,
                    arguments_json,
                    operationDeadline(server),
                    options,
                    null,
                    null,
                    round + 1,
                ) catch |err| {
                    handled.responder.finish(alloc, handled.origin, .abandoned);
                    return err;
                };
                handled.responder.finish(alloc, handled.origin, .completed);
                return continued;
            }
            try retainFeatureProtocolDiagnostic(alloc, options, failure);
            return error.McpProtocolError;
        },
        .input_required => |*required| {
            if (round >= 8) return error.McpInputRequiredLimitExceeded;
            const responder = options.input_responder orelse return error.McpInputRequired;
            const requests_json = try mrtr.renderRequests(alloc, required.requests);
            defer alloc.free(requests_json);
            const compatibility = tool_mcp_runtime.InputRequired{
                .input_requests_json = requests_json,
                .request_state_json = required.request_state_json,
            };
            const interaction_deadline = operation_control.elicitationDeadline(io_mod.getIo());
            const origin = tool_mcp_runtime.InputOrigin{
                .wire = .modern_mcp,
                .server_name = snapshot.server_name,
                .operation = .{ .prompts_get = name },
                .runtime_generation = self.transport.completions.runtime_generation,
                .connection_generation = snapshot.connection_generation,
                .client_generation = snapshot.connection_generation,
                .catalog_generation = snapshot.catalog_generation,
                .request_generation = round + 1,
                .auth_generation = server.auth_generation.load(.acquire),
                .deadline_ms = operation_control.timestampMillis(interaction_deadline),
                .lifecycle_cancel_flag = server.cancellation(),
            };
            const responses = try responder.callback(
                responder.context,
                alloc,
                origin,
                compatibility,
            );
            defer alloc.free(responses);
            try mrtr.validateResponses(alloc, required.requests, responses, .{});
            const continued = requestPromptGetRound(
                self,
                alloc,
                server,
                snapshot,
                name,
                arguments_json,
                operationDeadline(server),
                options,
                responses,
                required.request_state_json,
                round + 1,
            ) catch |err| {
                responder.finish(alloc, origin, .abandoned);
                return err;
            };
            responder.finish(alloc, origin, .completed);
            return continued;
        },
    }
}

const HandledLegacyUrlRequired = struct {
    decision: elicitation.LegacyUrlRetryDecision,
    origin: tool_mcp_runtime.InputOrigin,
    responder: tool_mcp_runtime.InputResponder,
};

fn respondToLegacyUrlRequired(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    operation: elicitation.Operation,
    code: i64,
    data_json: ?[]const u8,
    options: FeatureCallOptions,
    round: u8,
) !?HandledLegacyUrlRequired {
    const wire = server.legacyWire() orelse return null;
    if (wire != .legacy_mcp_2025_11 or
        code != elicitation.legacy_url_required_error_code or
        data_json == null)
    {
        return null;
    }
    var required = elicitation.parseLegacyUrlRequired(
        alloc,
        wire,
        data_json.?,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.McpProtocolError,
    };
    defer required.deinit(alloc);
    const requests_json = try elicitation.renderLegacyUrlRequiredRequests(alloc, required, .{});
    defer alloc.free(requests_json);
    const requests = mrtr.parseRequestJsonForWire(alloc, requests_json, wire, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.McpProtocolError,
    };
    defer {
        for (requests) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    const responder = options.input_responder orelse return error.McpInputRequired;
    const interaction_deadline = operation_control.elicitationDeadline(io_mod.getIo());
    const origin = tool_mcp_runtime.InputOrigin{
        .wire = wire,
        .server_name = snapshot.server_name,
        .operation = operation,
        .runtime_generation = self.transport.completions.runtime_generation,
        .connection_generation = snapshot.connection_generation,
        .client_generation = if (server.dispatcher) |dispatcher|
            dispatcher.connectionGeneration()
        else
            snapshot.connection_generation,
        .catalog_generation = snapshot.catalog_generation,
        .request_generation = round + 1,
        .auth_generation = server.auth_generation.load(.acquire),
        .deadline_ms = operation_control.timestampMillis(interaction_deadline),
        .lifecycle_cancel_flag = server.cancellation(),
    };
    return .{
        .decision = try (legacy_elicitation_runtime.Coordination{ .catalog_mutex = self.transport.catalog_mutex, .completions = self.transport.completions }).interact(
            alloc,
            server,
            origin,
            requests,
            requests_json,
            responder,
            .{ .feature = snapshot },
            interaction_deadline,
            options.cancel_flag,
        ),
        .origin = origin,
        .responder = responder,
    };
}

pub fn listResources(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    include_templates: bool,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !ResourceCatalogResult {
    const server_name = server.config.name;
    var operation_access = try OperationAccessGuard.init(
        self.transport.alloc,
        access,
        self.transport.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server_name });
    if (!server.capabilities.resources) return error.McpResourcesUnsupported;

    if (!try self.ensureResourceCatalog(server, false, deadline, cancel_flag, access)) {
        return error.McpResourceCatalogUnavailable;
    }
    if (include_templates and
        !try self.ensureResourceCatalog(server, true, deadline, cancel_flag, access))
    {
        return error.McpResourceCatalogUnavailable;
    }

    var result = result: {
        try lockRwSharedUntil(self.transport.catalog_mutex, deadline, cancel_flag);
        defer self.transport.catalog_mutex.unlockShared(io_mod.getIo());
        if (!feature_catalog.featureCatalogAvailable(server, .resources) or
            (include_templates and !feature_catalog.featureCatalogAvailable(server, .resource_templates)))
        {
            return error.McpResourceCatalogUnavailable;
        }
        const auth_witness = feature_catalog.featureCatalogAuthWitness(
            server,
            if (include_templates) .resource_templates else .resources,
        );
        const resources = server.resource_catalog.catalog orelse return error.McpResourceCatalogUnavailable;
        const template_count = if (include_templates)
            if (server.resource_template_catalog.catalog) |catalog| catalog.items.len else 0
        else
            0;
        const resource_count = if (include_templates) 0 else resources.items.len;
        const total = std.math.add(usize, resource_count, template_count) catch
            return error.McpResourceLimitExceeded;
        const items = try alloc.alloc(ResourceSummary, total);
        var count: usize = 0;
        errdefer {
            for (items[0..count]) |*item| item.deinit(alloc);
            alloc.free(items);
        }
        if (!include_templates) for (resources.items) |resource| {
            items[count] = try cloneResourceSummary(alloc, server.config.name, resource);
            count += 1;
        };
        if (include_templates) if (server.resource_template_catalog.catalog) |templates| {
            for (templates.items) |template| {
                items[count] = try cloneTemplateSummary(alloc, server.config.name, template);
                count += 1;
            }
        };
        try feature_catalog.validateFeatureCatalogAuthWitness(server, auth_witness);
        break :result ResourceCatalogResult{ .items = items };
    };
    errdefer result.deinit(alloc);
    try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
    return result;
}

pub fn listPrompts(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !PromptCatalogResult {
    const server_name = server.config.name;
    var operation_access = try OperationAccessGuard.init(
        self.transport.alloc,
        access,
        self.transport.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server_name });
    if (!server.capabilities.prompts) return error.McpPromptsUnsupported;

    if (!try self.ensurePromptCatalog(server, deadline, cancel_flag, access)) {
        return error.McpPromptCatalogUnavailable;
    }
    var result = result: {
        try lockRwSharedUntil(self.transport.catalog_mutex, deadline, cancel_flag);
        defer self.transport.catalog_mutex.unlockShared(io_mod.getIo());
        if (!feature_catalog.featureCatalogAvailable(server, .prompts)) return error.McpPromptCatalogUnavailable;
        const auth_witness = feature_catalog.featureCatalogAuthWitness(server, .prompts);
        const catalog = server.prompt_catalog.catalog orelse return error.McpPromptCatalogUnavailable;
        const items = try alloc.alloc(PromptSummary, catalog.prompts.len);
        var count: usize = 0;
        errdefer {
            for (items[0..count]) |*item| item.deinit(alloc);
            alloc.free(items);
        }
        for (catalog.prompts, 0..) |prompt, index| {
            items[index] = try clonePromptSummary(alloc, server.config.name, prompt);
            count += 1;
        }
        try feature_catalog.validateFeatureCatalogAuthWitness(server, auth_witness);
        break :result PromptCatalogResult{ .items = items };
    };
    errdefer result.deinit(alloc);
    try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
    return result;
}

pub fn readResource(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    uri: []const u8,
    options: FeatureCallOptions,
) !ResourceReadResult {
    const server_name = server.config.name;
    var operation_access = try OperationAccessGuard.init(
        self.transport.alloc,
        options.access,
        self.transport.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server_name });
    if (!server.capabilities.resources) return error.McpResourcesUnsupported;

    while (true) {
        if (!try self.ensureResourceCatalog(server, false, deadline, options.cancel_flag, options.access)) {
            return error.McpResourceCatalogUnavailable;
        }
        var snapshot = if (try feature_snapshot.snapshotConcreteResourceIdentity(
            self.transport.catalog_mutex,
            alloc,
            server,
            uri,
            deadline,
            options.cancel_flag,
        )) |concrete|
            concrete
        else snapshot: {
            if (!try self.ensureResourceCatalog(server, true, deadline, options.cancel_flag, options.access)) {
                return error.McpResourceCatalogUnavailable;
            }
            break :snapshot try feature_snapshot.snapshotResourceIdentityWithTemplates(
                self.transport.catalog_mutex,
                alloc,
                server,
                uri,
                deadline,
                options.cancel_flag,
            );
        };
        defer snapshot.deinit(alloc);
        try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
        try invalidateResourceReadCacheIfNeeded(self, server, deadline, options.cancel_flag);
        ensureResourceUpdateSubscription(
            self,
            server,
            uri,
            deadline,
            options.cancel_flag,
            options.access,
        ) catch |err| {
            if (err == error.McpAccessDenied or err == error.McpAuthorityChanged) return err;
            debug_trace.logf(
                "mcp",
                "resource update subscription skipped server={s} uri={s} err={s}",
                .{ server.config.name, uri, @errorName(err) },
            );
        };
        if (try cachedResourceRead(self, alloc, server, uri, deadline, options.cancel_flag, false, options.access)) |cached_value| {
            var cached = cached_value;
            errdefer cached.deinit(alloc);
            try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
            return cached;
        }
        var stale = try cachedResourceRead(self, alloc, server, uri, deadline, options.cancel_flag, true, options.access);
        defer if (stale) |*cached| cached.deinit(alloc);
        const recovered = self.lifecycle.ensureFeatureServerRunning(
            server,
            self.transport.generation,
            deadline,
            options.cancel_flag,
            options.access,
        ) catch |err| {
            if (stale) |cached_value| if (resources_feature.staleFallbackEligible(err) or
                err == error.McpRestartLimitReached)
            {
                var cached = cached_value;
                stale = null;
                errdefer cached.deinit(alloc);
                try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
                return cached;
            };
            return err;
        };
        if (recovered) continue;
        const fetched = requestResourceRead(self, alloc, server, &snapshot, uri, deadline, options) catch |err| {
            if (stale) |cached_value| if (resources_feature.staleFallbackEligible(err)) {
                var cached = cached_value;
                stale = null;
                errdefer cached.deinit(alloc);
                try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
                return cached;
            };
            return err;
        };
        return finishFetchedResourceRead(
            self,
            alloc,
            server,
            &snapshot,
            uri,
            fetched,
            deadline,
            options.cancel_flag,
            options.access,
        );
    }
}

pub fn getPrompt(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    name: []const u8,
    arguments_json: []const u8,
    options: FeatureCallOptions,
) !PromptGetResult {
    const server_name = server.config.name;
    var operation_access = try OperationAccessGuard.init(
        self.transport.alloc,
        options.access,
        self.transport.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server_name });
    if (!server.capabilities.prompts) return error.McpPromptsUnsupported;

    while (true) {
        _ = try self.ensurePromptCatalog(server, deadline, options.cancel_flag, options.access);
        var snapshot = try feature_snapshot.snapshotPromptIdentity(
            self.transport.catalog_mutex,
            alloc,
            server,
            name,
            arguments_json,
            deadline,
            options.cancel_flag,
        );
        defer snapshot.deinit(alloc);
        if (try self.lifecycle.ensureFeatureServerRunning(server, self.transport.generation, deadline, options.cancel_flag, options.access)) continue;
        var result = try requestPromptGet(
            self,
            alloc,
            server,
            &snapshot,
            name,
            arguments_json,
            deadline,
            options,
        );
        errdefer result.deinit(alloc);
        const server_copy = try alloc.dupe(u8, server.config.name);
        errdefer alloc.free(server_copy);
        const name_copy = try alloc.dupe(u8, name);
        errdefer alloc.free(name_copy);
        try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
        const description = result.description;
        const messages = result.messages;
        result.description = null;
        result.messages = &.{};
        result.deinit(alloc);
        return .{
            .server_name = server_copy,
            .name = name_copy,
            .description = description,
            .messages = messages,
        };
    }
}

pub fn completeFeatureArgument(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    reference: completion_feature.Reference,
    argument: completion_feature.Argument,
    context_arguments: []const completion_feature.Argument,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !CompletionResult {
    const server_name = server.config.name;
    var operation_access = try OperationAccessGuard.init(
        self.transport.alloc,
        access,
        self.transport.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server_name });
    if (!server.capabilities.completion) return error.McpCompletionUnsupported;
    switch (reference) {
        .prompt => if (!server.capabilities.prompts) return error.McpPromptsUnsupported,
        .resource_template => if (!server.capabilities.resources) return error.McpResourcesUnsupported,
    }

    while (true) {
        var snapshot = switch (reference) {
            .prompt => |name| snapshot: {
                _ = try self.ensurePromptCatalog(server, deadline, cancel_flag, access);
                break :snapshot try feature_snapshot.snapshotPromptIdentity(self.transport.catalog_mutex, alloc, server, name, null, deadline, cancel_flag);
            },
            .resource_template => |uri| snapshot: {
                _ = try self.ensureResourceCatalog(server, true, deadline, cancel_flag, access);
                break :snapshot try feature_snapshot.snapshotResourceTemplateIdentity(self.transport.catalog_mutex, alloc, server, uri, deadline, cancel_flag);
            },
        };
        defer snapshot.deinit(alloc);
        try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
        if (try self.lifecycle.ensureFeatureServerRunning(server, self.transport.generation, deadline, cancel_flag, access)) continue;
        const request_id = try nextFeatureRequestId(server);
        const request = try completion_feature.buildRequest(
            alloc,
            request_id,
            serverFeatureProtocol(server),
            reference,
            argument,
            context_arguments,
            .{},
            writeModernRequestMetadata,
        );
        defer alloc.free(request);
        var guard = FeaturePrecommit{ .alloc = self.transport.alloc, .runtime_generation = self.transport.generation, .catalog_mutex = self.transport.catalog_mutex, .server = server, .snapshot = &snapshot, .deadline = deadline, .cancel_flag = cancel_flag, .access = access };
        var precommit = guard.transport();
        var response = try self.transport.send(server, request_id, request, deadline, cancel_flag, access, &precommit, null);
        defer response.deinit(self.transport.alloc);
        var result = try completion_feature.parseResult(alloc, response.body, serverFeatureProtocol(server), .{});
        errdefer result.deinit(alloc);
        const owned_server = try alloc.dupe(u8, server.config.name);
        errdefer alloc.free(owned_server);
        try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
        const values = result.values;
        const total = result.total;
        const has_more = result.has_more;
        result.values = &.{};
        result.deinit(alloc);
        return .{ .server_name = owned_server, .values = values, .total = total, .has_more = has_more };
    }
}

pub fn finishFetchedResourceRead(
    self: Context,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    uri: []const u8,
    fetched_value: FetchedResourceRead,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !ResourceReadResult {
    var fetched = fetched_value;
    var fetched_owned = true;
    errdefer if (fetched_owned) fetched.result.deinit(alloc);
    var operation_access = try OperationAccessGuard.init(
        self.transport.alloc,
        access,
        self.transport.generation,
    );
    defer operation_access.deinit();
    const access_target = access_policy.Target{ .feature_server = server.config.name };
    try operation_access.authorize(access_target);
    if (fetched.result.cache_eligible) {
        try publishResourceReadCache(
            self,
            server,
            snapshot,
            uri,
            fetched,
            deadline,
            cancel_flag,
            access,
        );
    }
    var result = fetched.result;
    fetched.result.contents = &.{};
    fetched.result.deinit(alloc);
    fetched_owned = false;
    errdefer result.deinit(alloc);
    const server_copy = try alloc.dupe(u8, server.config.name);
    errdefer alloc.free(server_copy);
    const uri_copy = try alloc.dupe(u8, uri);
    errdefer alloc.free(uri_copy);
    try operation_access.refreshAndAuthorize(access_target);
    const contents = result.contents;
    result.contents = &.{};
    result.deinit(alloc);
    return .{ .server_name = server_copy, .uri = uri_copy, .contents = contents };
}

fn retainFeatureProtocolDiagnostic(
    alloc: Allocator,
    options: FeatureCallOptions,
    failure: resources_feature.ProtocolError,
) !void {
    const destination = options.protocol_diagnostic orelse return;
    std.debug.assert(destination.* == null);
    destination.* = try tool_result.protocol_diagnostic_alloc(
        alloc,
        failure.code,
        failure.message,
        failure.data_json,
    );
}
