const std = @import("std");
const host_target = @import("../hosts/target.zig");
const atomic_value = @import("atomic_value.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const elicitation = @import("elicitation.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const legacy_http_sse = @import("legacy_http_sse.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const mcp_contract = @import("mcp_contract.zig");
const stdio_dispatcher = @import("stdio_dispatcher.zig");
const streamable_http = @import("streamable_http.zig");

const Allocator = std.mem.Allocator;
const notification_frame_limit: usize = 64 * 1024;
const listener_lifetime_ms: u32 = std.math.maxInt(u32);
const stop_poll_ms: u64 = 5;

pub const Transport = union(enum) {
    legacy_stdio: *stdio_dispatcher.StdioDispatcher,
    legacy_http: *legacy_streamable_http.Client,
    legacy_sse: *legacy_http_sse.Client,
    modern_stdio: *stdio_dispatcher.StdioDispatcher,
    modern_http: Http,
};

const Http = struct {
    server_name: []u8,
    listener: HttpListener,
};

pub const HttpListener = struct {
    context: *anyopaque,
    callback: *const fn (
        context: *anyopaque,
        alloc: Allocator,
        server_name: []const u8,
        connection_generation: u64,
        request_body: []const u8,
        notifications: mcp_contract.NotificationSink,
        control: streamable_http.Control,
    ) anyerror![]u8,
};

pub const Filters = struct {
    tools_list_changed: bool = false,
    resources_list_changed: bool = false,
    prompts_list_changed: bool = false,
    elicitation_complete: bool = false,
    resource_subscriptions: []const []const u8 = &.{},

    pub fn any(self: Filters) bool {
        return self.tools_list_changed or
            self.resources_list_changed or
            self.prompts_list_changed or
            self.elicitation_complete or
            self.resource_subscriptions.len > 0;
    }
};

pub const NotificationSource = struct {
    server_name: []const u8,
    connection_generation: u64,
    client_generation: u64,
    auth_generation: u64,
};

pub const NotificationPassthrough = struct {
    context: *anyopaque,
    source: NotificationSource,
    callback: *const fn (*anyopaque, NotificationSource, std.json.Value) void,
};

pub const FeatureInvalidation = enum {
    tools,
    resources,
    resource_read,
    resource_templates,
    prompts,
};

pub const State = struct {
    pub const FinishReason = enum(u8) {
        running,
        closed,
        cancelled,
        unsupported,
        authentication_required,
        session_expired,
    };

    owner_allocator: Allocator,
    transport: Transport,
    tools_list_changed: bool,
    resources_list_changed: bool,
    prompts_list_changed: bool,
    elicitation_complete: bool = false,
    notification_passthrough: ?NotificationPassthrough = null,
    resource_subscriptions: [][]u8 = &.{},
    connection_generation: u64,
    active_request_id: atomic_value.Value(u64),
    active_generation: atomic_value.Value(u64),
    acknowledged: std.atomic.Value(bool) = .init(false),
    unsupported_filter: std.atomic.Value(bool) = .init(false),
    invalidation_generation: atomic_value.Value(u64) = .init(0),
    handled_invalidation_generation: atomic_value.Value(u64) = .init(0),
    resources_invalidation_generation: atomic_value.Value(u64) = .init(0),
    handled_resources_invalidation_generation: atomic_value.Value(u64) = .init(0),
    resource_update_generation: atomic_value.Value(u64) = .init(0),
    handled_resource_update_generation: atomic_value.Value(u64) = .init(0),
    prompts_invalidation_generation: atomic_value.Value(u64) = .init(0),
    handled_prompts_invalidation_generation: atomic_value.Value(u64) = .init(0),
    commit_lock: std.Io.Mutex = .init,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    notifications_seen: atomic_value.Value(u64) = .init(0),
    notifications_coalesced: atomic_value.Value(u64) = .init(0),
    listener_finished: std.atomic.Value(bool) = .init(false),
    finish_reason: std.atomic.Value(FinishReason) = .init(.running),
    startup_readiness: stdio_dispatcher.RequestReadiness = .{},
    startup_deadline: ?std.Io.Clock.Timestamp = null,
    startup_cancel_flag: ?*std.atomic.Value(bool) = null,
    listener_thread: ?std.Thread = null,

    pub fn createStdio(
        owner_allocator: Allocator,
        dispatcher: *stdio_dispatcher.StdioDispatcher,
        protocol: catalog_freshness.Protocol,
        connection_generation: u64,
        request_id: u64,
        subscription_generation: u64,
        filters: Filters,
        startup_deadline: ?std.Io.Clock.Timestamp,
        startup_cancel_flag: ?*std.atomic.Value(bool),
    ) !*State {
        if (comptime host_target.is_wasm) return error.McpTransportUnavailable;
        return createStdioCommon(
            owner_allocator,
            dispatcher,
            protocol,
            connection_generation,
            request_id,
            subscription_generation,
            filters,
            startup_deadline,
            startup_cancel_flag,
            null,
        );
    }

    pub fn createLegacyStdioWithNotifications(
        owner_allocator: Allocator,
        dispatcher: *stdio_dispatcher.StdioDispatcher,
        connection_generation: u64,
        subscription_generation: u64,
        filters: Filters,
        notification_passthrough: NotificationPassthrough,
    ) !*State {
        if (comptime host_target.is_wasm) return error.McpTransportUnavailable;
        return createStdioCommon(
            owner_allocator,
            dispatcher,
            .legacy,
            connection_generation,
            0,
            subscription_generation,
            filters,
            null,
            null,
            notification_passthrough,
        );
    }

    fn createStdioCommon(
        owner_allocator: Allocator,
        dispatcher: *stdio_dispatcher.StdioDispatcher,
        protocol: catalog_freshness.Protocol,
        connection_generation: u64,
        request_id: u64,
        subscription_generation: u64,
        filters: Filters,
        startup_deadline: ?std.Io.Clock.Timestamp,
        startup_cancel_flag: ?*std.atomic.Value(bool),
        notification_passthrough: ?NotificationPassthrough,
    ) !*State {
        const self = try owner_allocator.create(State);
        errdefer owner_allocator.destroy(self);
        self.* = .{
            .owner_allocator = owner_allocator,
            .transport = if (protocol == .modern)
                .{ .modern_stdio = dispatcher }
            else
                .{ .legacy_stdio = dispatcher },
            .connection_generation = connection_generation,
            .active_request_id = .init(request_id),
            .active_generation = .init(subscription_generation),
            .tools_list_changed = filters.tools_list_changed,
            .resources_list_changed = filters.resources_list_changed,
            .prompts_list_changed = filters.prompts_list_changed,
            .elicitation_complete = filters.elicitation_complete,
            .startup_deadline = startup_deadline,
            .startup_cancel_flag = startup_cancel_flag,
        };
        try self.cloneResourceSubscriptions(filters.resource_subscriptions);
        errdefer self.deinitResourceSubscriptions();
        try self.cloneNotificationPassthrough(notification_passthrough);
        errdefer self.deinitNotificationPassthrough();
        try dispatcher.setNotificationSink(.{
            .context = self,
            .callback = notificationCallback,
        });
        errdefer dispatcher.clearNotificationSink();
        if (protocol == .modern) {
            const deadline = startup_deadline orelse
                return error.McpSubscriptionStartupDeadlineMissing;
            self.listener_thread = try std.Thread.spawn(.{}, listenerMain, .{self});
            self.startup_readiness.waitCommitted(deadline, startup_cancel_flag) catch |err| {
                self.requestStop();
                self.listener_thread.?.join();
                self.listener_thread = null;
                return err;
            };
            self.startup_cancel_flag = null;
        }
        return self;
    }

    pub fn createHttp(
        owner_allocator: Allocator,
        server_name: []const u8,
        listener: HttpListener,
        connection_generation: u64,
        request_id: u64,
        subscription_generation: u64,
        filters: Filters,
    ) !*State {
        if (comptime host_target.is_wasm) return error.McpTransportUnavailable;
        const self = try allocateHttpState(
            owner_allocator,
            server_name,
            listener,
            connection_generation,
            request_id,
            subscription_generation,
            filters,
        );
        errdefer self.stopAndDestroy();
        self.listener_thread = try std.Thread.spawn(.{}, listenerMain, .{self});
        return self;
    }

    fn allocateHttpState(
        owner_allocator: Allocator,
        server_name: []const u8,
        listener: HttpListener,
        connection_generation: u64,
        request_id: u64,
        subscription_generation: u64,
        filters: Filters,
    ) !*State {
        const owned_server_name = try owner_allocator.dupe(u8, server_name);
        errdefer owner_allocator.free(owned_server_name);
        const self = try owner_allocator.create(State);
        errdefer owner_allocator.destroy(self);
        self.* = .{
            .owner_allocator = owner_allocator,
            .transport = .{ .modern_http = .{
                .server_name = owned_server_name,
                .listener = listener,
            } },
            .connection_generation = connection_generation,
            .active_request_id = .init(request_id),
            .active_generation = .init(subscription_generation),
            .tools_list_changed = filters.tools_list_changed,
            .resources_list_changed = filters.resources_list_changed,
            .prompts_list_changed = filters.prompts_list_changed,
        };
        try self.cloneResourceSubscriptions(filters.resource_subscriptions);
        errdefer self.deinitResourceSubscriptions();
        return self;
    }

    pub fn createLegacyHttp(
        owner_allocator: Allocator,
        client: *legacy_streamable_http.Client,
        connection_generation: u64,
        subscription_generation: u64,
        filters: Filters,
        notification_passthrough: ?NotificationPassthrough,
    ) !*State {
        if (comptime host_target.is_wasm) return error.McpTransportUnavailable;
        const self = try owner_allocator.create(State);
        errdefer owner_allocator.destroy(self);
        self.* = .{
            .owner_allocator = owner_allocator,
            .transport = .{ .legacy_http = client },
            .connection_generation = connection_generation,
            .active_request_id = .init(0),
            .active_generation = .init(subscription_generation),
            .tools_list_changed = filters.tools_list_changed,
            .resources_list_changed = filters.resources_list_changed,
            .prompts_list_changed = filters.prompts_list_changed,
            .elicitation_complete = filters.elicitation_complete,
        };
        try self.cloneResourceSubscriptions(filters.resource_subscriptions);
        errdefer self.deinitResourceSubscriptions();
        try self.cloneNotificationPassthrough(notification_passthrough);
        errdefer self.deinitNotificationPassthrough();
        self.listener_thread = try std.Thread.spawn(.{}, listenerMain, .{self});
        return self;
    }

    pub fn createLegacySse(
        owner_allocator: Allocator,
        client: *legacy_http_sse.Client,
        connection_generation: u64,
        subscription_generation: u64,
        filters: Filters,
    ) !*State {
        if (comptime host_target.is_wasm) return error.McpTransportUnavailable;
        const self = try owner_allocator.create(State);
        errdefer owner_allocator.destroy(self);
        self.* = .{
            .owner_allocator = owner_allocator,
            .transport = .{ .legacy_sse = client },
            .connection_generation = connection_generation,
            .active_request_id = .init(0),
            .active_generation = .init(subscription_generation),
            .tools_list_changed = filters.tools_list_changed,
            .resources_list_changed = filters.resources_list_changed,
            .prompts_list_changed = filters.prompts_list_changed,
        };
        try self.cloneResourceSubscriptions(filters.resource_subscriptions);
        errdefer self.deinitResourceSubscriptions();
        try client.setNotificationSink(.{
            .context = self,
            .callback = notificationCallback,
        });
        return self;
    }

    pub fn stopAndDestroy(self: *State) void {
        self.requestStop();
        if (self.listener_thread) |thread| {
            thread.join();
            self.listener_thread = null;
        }
        switch (self.transport) {
            .legacy_stdio, .modern_stdio => |dispatcher| dispatcher.clearNotificationSink(),
            .legacy_sse => |client| client.clearNotificationSink(),
            .legacy_http => {},
            .modern_http => |http| {
                self.owner_allocator.free(http.server_name);
            },
        }
        self.deinitNotificationPassthrough();
        self.deinitResourceSubscriptions();
        const owner_allocator = self.owner_allocator;
        self.* = undefined;
        owner_allocator.destroy(self);
    }

    pub fn requestStop(self: *State) void {
        self.cancel_flag.store(true, .release);
    }

    pub fn invalidationGeneration(self: *const State) u64 {
        return self.invalidation_generation.load(.acquire);
    }

    pub fn hasInvalidation(self: *const State) bool {
        return self.invalidationGeneration() !=
            self.handled_invalidation_generation.load(.acquire);
    }

    pub fn clearInvalidationThrough(self: *State, generation: u64) void {
        if (self.invalidationGeneration() != generation) return;
        self.handled_invalidation_generation.store(generation, .release);
    }

    pub fn invalidationGenerationFor(self: *const State, feature: FeatureInvalidation) u64 {
        return switch (feature) {
            .tools => self.invalidationGeneration(),
            .resources, .resource_read, .resource_templates => self.resources_invalidation_generation.load(.acquire),
            .prompts => self.prompts_invalidation_generation.load(.acquire),
        };
    }

    pub fn hasInvalidationFor(self: *const State, feature: FeatureInvalidation) bool {
        return switch (feature) {
            .tools => self.hasInvalidation(),
            .resources => self.resources_invalidation_generation.load(.acquire) !=
                self.handled_resources_invalidation_generation.load(.acquire),
            .resource_read => self.resources_invalidation_generation.load(.acquire) !=
                self.handled_resources_invalidation_generation.load(.acquire) or
                self.resource_update_generation.load(.acquire) !=
                    self.handled_resource_update_generation.load(.acquire),
            .resource_templates => self.resources_invalidation_generation.load(.acquire) !=
                self.handled_resources_invalidation_generation.load(.acquire),
            .prompts => self.prompts_invalidation_generation.load(.acquire) !=
                self.handled_prompts_invalidation_generation.load(.acquire),
        };
    }

    pub fn clearInvalidationThroughFor(
        self: *State,
        feature: FeatureInvalidation,
        generation: u64,
    ) void {
        switch (feature) {
            .tools => self.clearInvalidationThrough(generation),
            .resources, .resource_read, .resource_templates => {
                if (self.resources_invalidation_generation.load(.acquire) == generation) {
                    self.handled_resources_invalidation_generation.store(generation, .release);
                }
            },
            .prompts => {
                if (self.prompts_invalidation_generation.load(.acquire) == generation) {
                    self.handled_prompts_invalidation_generation.store(generation, .release);
                }
            },
        }
    }

    pub fn resourceUpdateGeneration(self: *const State) u64 {
        return self.resource_update_generation.load(.acquire);
    }

    pub fn clearResourceUpdatesThrough(self: *State, generation: u64) void {
        if (self.resource_update_generation.load(.acquire) == generation) {
            self.handled_resource_update_generation.store(generation, .release);
        }
    }

    pub fn hasAnyInvalidation(self: *const State) bool {
        return self.hasInvalidation() or
            self.hasInvalidationFor(.resources) or
            self.hasInvalidationFor(.prompts) or
            self.resource_update_generation.load(.acquire) !=
                self.handled_resource_update_generation.load(.acquire);
    }

    pub fn subscribesToResource(self: *const State, uri: []const u8) bool {
        return containsResourceSubscription(self.resource_subscriptions, uri);
    }

    pub fn resourceSubscriptions(self: *const State) []const []const u8 {
        return self.resource_subscriptions;
    }

    pub fn lockCommitIfCurrent(self: *State) bool {
        self.commit_lock.lockUncancelable(io_mod.getIo());
        if (self.hasInvalidation()) {
            self.commit_lock.unlock(io_mod.getIo());
            return false;
        }
        return true;
    }

    pub fn lockFeatureCommitIfCurrent(
        self: *State,
        feature: FeatureInvalidation,
    ) bool {
        self.commit_lock.lockUncancelable(io_mod.getIo());
        if (self.hasInvalidationFor(feature)) {
            self.commit_lock.unlock(io_mod.getIo());
            return false;
        }
        return true;
    }

    pub fn unlockCommit(self: *State) void {
        self.commit_lock.unlock(io_mod.getIo());
    }

    pub fn identity(self: *const State) catalog_freshness.SubscriptionIdentity {
        return .{
            .request_id = self.active_request_id.load(.acquire),
            .generation = self.active_generation.load(.acquire),
        };
    }

    pub fn isAcknowledged(self: *const State) bool {
        return self.acknowledged.load(.acquire);
    }

    pub fn requiresAcknowledgement(self: *const State) bool {
        return switch (self.transport) {
            .modern_stdio, .modern_http => true,
            .legacy_stdio, .legacy_http, .legacy_sse => false,
        };
    }

    pub fn startupState(self: *const State) stdio_dispatcher.RequestReadiness.State {
        return self.startup_readiness.current();
    }

    pub fn isUnsupported(self: *const State) bool {
        return self.unsupported_filter.load(.acquire);
    }

    pub fn isFinished(self: *const State) bool {
        return switch (self.transport) {
            .legacy_sse => |client| client.readerFinishReason() != null,
            else => self.listener_finished.load(.acquire),
        };
    }

    pub fn finishReason(self: *const State) FinishReason {
        return switch (self.transport) {
            .legacy_sse => |client| switch (client.readerFinishReason() orelse
                return .running) {
                .closed => .closed,
                .authentication_required => .authentication_required,
            },
            else => self.finish_reason.load(.acquire),
        };
    }

    pub const NotificationStats = struct {
        seen: u64,
        coalesced: u64,
    };

    pub fn notificationStats(self: *const State) NotificationStats {
        return .{
            .seen = self.notifications_seen.load(.acquire),
            .coalesced = self.notifications_coalesced.load(.acquire),
        };
    }

    fn cloneResourceSubscriptions(self: *State, source: []const []const u8) !void {
        if (source.len == 0) return;
        const owned = try self.owner_allocator.alloc([]u8, source.len);
        var count: usize = 0;
        errdefer {
            for (owned[0..count]) |uri| self.owner_allocator.free(uri);
            self.owner_allocator.free(owned);
        }
        for (source, 0..) |uri, index| {
            owned[index] = try self.owner_allocator.dupe(u8, uri);
            count += 1;
        }
        self.resource_subscriptions = owned;
    }

    fn deinitResourceSubscriptions(self: *State) void {
        for (self.resource_subscriptions) |uri| self.owner_allocator.free(uri);
        if (self.resource_subscriptions.len > 0) {
            self.owner_allocator.free(self.resource_subscriptions);
        }
        self.resource_subscriptions = &.{};
    }

    fn listenerMain(self: *State) void {
        defer {
            self.startup_readiness.markStopped();
            self.listener_finished.store(true, .release);
        }
        var retry_attempt: u8 = 0;
        var first_attempt = true;
        while (!self.cancel_flag.load(.acquire)) {
            if (!first_attempt) {
                const delay_ms = catalog_freshness.retryDelayMs(retry_attempt);
                if (!waitForRetry(self, delay_ms)) return;
                retry_attempt +|= 1;
                saturatingIncrement(&self.active_generation);
                switch (self.transport) {
                    .modern_stdio => |dispatcher| {
                        const request_id = dispatcher.reserveRequestId() catch |err| {
                            debug_trace.logf(
                                "mcp",
                                "tool subscription request id unavailable connection_generation={d} err={s}",
                                .{ self.connection_generation, @errorName(err) },
                            );
                            continue;
                        };
                        self.active_request_id.store(request_id, .release);
                    },
                    .modern_http, .legacy_stdio, .legacy_http, .legacy_sse => {},
                }
            }
            first_attempt = false;
            self.acknowledged.store(false, .release);
            const result = switch (self.transport) {
                .modern_stdio => |dispatcher| listenStdio(self, dispatcher),
                .modern_http => |http| listenHttp(self, http),
                .legacy_http => |client| listenLegacyHttp(self, client),
                .legacy_stdio, .legacy_sse => return,
            };
            result catch |err| {
                self.startup_readiness.markFailed(err);
                if (self.cancel_flag.load(.acquire) or
                    err == error.Cancelled or
                    err == error.McpRequestCancelled)
                {
                    self.finish_reason.store(
                        if (self.unsupported_filter.load(.acquire))
                            .unsupported
                        else
                            .cancelled,
                        .release,
                    );
                    return;
                }
                debug_trace.logf(
                    "mcp",
                    "tool subscription ended connection_generation={d} subscription_generation={d} err={s}",
                    .{
                        self.connection_generation,
                        self.active_generation.load(.acquire),
                        @errorName(err),
                    },
                );
                if (err == error.McpNotificationListenerUnsupported or
                    err == error.McpAuthenticationRequired or
                    err == error.McpSessionExpired or
                    err == error.MissingFinalResponse)
                {
                    const reason: FinishReason = if (err == error.McpNotificationListenerUnsupported)
                        .unsupported
                    else if (err == error.McpAuthenticationRequired)
                        .authentication_required
                    else if (err == error.MissingFinalResponse)
                        .closed
                    else
                        .session_expired;
                    self.finish_reason.store(reason, .release);
                    return;
                }
                continue;
            };
            if (!self.cancel_flag.load(.acquire)) {
                debug_trace.logf(
                    "mcp",
                    "tool subscription closed connection_generation={d} subscription_generation={d}",
                    .{
                        self.connection_generation,
                        self.active_generation.load(.acquire),
                    },
                );
            }
            self.finish_reason.store(.closed, .release);
            return;
        }
    }

    fn listenStdio(
        self: *State,
        dispatcher: *stdio_dispatcher.StdioDispatcher,
    ) !void {
        const request_id = self.active_request_id.load(.acquire);
        const body = try buildListenRequest(std.heap.c_allocator, request_id, self.currentFilters());
        defer std.heap.c_allocator.free(body);
        const startup_pending = switch (self.startup_readiness.current()) {
            .spawned, .registered => true,
            .committed, .failed, .stopped => false,
        };
        const response = try dispatcher.request(
            std.heap.c_allocator,
            request_id,
            body,
            notification_frame_limit,
            .{
                .timeout_ms = listener_lifetime_ms,
                .cancel_flag = &self.cancel_flag,
                .commit_deadline = if (startup_pending) self.startup_deadline else null,
                .commit_cancel_flag = if (startup_pending) self.startup_cancel_flag else null,
                .purpose = .subscription,
                .readiness = if (startup_pending) &self.startup_readiness else null,
            },
        );
        defer std.heap.c_allocator.free(response);
        try validateListenResponse(std.heap.c_allocator, response, request_id);
    }

    fn listenHttp(self: *State, http: Http) !void {
        const request_id = self.active_request_id.load(.acquire);
        const body = try buildListenRequest(std.heap.c_allocator, request_id, self.currentFilters());
        defer std.heap.c_allocator.free(body);
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(listener_lifetime_ms),
        });
        const response = try http.listener.callback(
            http.listener.context,
            std.heap.c_allocator,
            http.server_name,
            self.connection_generation,
            body,
            .{
                .context = self,
                .callback = notificationCallback,
            },
            .{
                .deadline = deadline,
                .cancel_flag = &self.cancel_flag,
            },
        );
        defer std.heap.c_allocator.free(response);
        try validateListenResponse(std.heap.c_allocator, response, request_id);
    }

    fn listenLegacyHttp(
        self: *State,
        client: *legacy_streamable_http.Client,
    ) !void {
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(listener_lifetime_ms),
        });
        try client.listenNotifications(
            std.heap.c_allocator,
            notification_frame_limit,
            .{
                .context = self,
                .callback = notificationCallback,
            },
            .{
                .deadline = deadline,
                .cancel_flag = &self.cancel_flag,
            },
        );
    }

    fn currentFilters(self: *const State) Filters {
        return .{
            .tools_list_changed = self.tools_list_changed,
            .resources_list_changed = self.resources_list_changed,
            .prompts_list_changed = self.prompts_list_changed,
            .elicitation_complete = self.elicitation_complete,
            .resource_subscriptions = self.resource_subscriptions,
        };
    }

    fn cloneNotificationPassthrough(
        self: *State,
        passthrough: ?NotificationPassthrough,
    ) !void {
        const source = passthrough orelse return;
        const server_name = try self.owner_allocator.dupe(u8, source.source.server_name);
        self.notification_passthrough = source;
        self.notification_passthrough.?.source.server_name = server_name;
    }

    fn deinitNotificationPassthrough(self: *State) void {
        if (self.notification_passthrough) |passthrough| {
            self.owner_allocator.free(passthrough.source.server_name);
            self.notification_passthrough = null;
        }
    }
};

fn notificationCallback(raw: *anyopaque, value: std.json.Value) void {
    const self: *State = @ptrCast(@alignCast(raw));
    if (self.elicitation_complete and
        elicitation.classifyLegacyUrlCompletionNotification(value, .{}) != null)
    {
        if (self.notification_passthrough) |sink| {
            sink.callback(sink.context, sink.source, value);
        }
        return;
    }
    const notification = parseNotification(value, self.currentFilters()) orelse {
        debug_trace.logf(
            "mcp",
            "ignored malformed tool subscription notification connection_generation={d}",
            .{self.connection_generation},
        );
        return;
    };
    const protocol: catalog_freshness.Protocol = switch (self.transport) {
        .legacy_stdio, .legacy_http, .legacy_sse => .legacy,
        .modern_stdio, .modern_http => .modern,
    };
    const identity = self.identity();
    const decision = classifyNotification(.{
        .protocol = protocol,
        .capability_advertised = true,
        .connection_generation = self.connection_generation,
        .event_connection_generation = self.connection_generation,
        .subscription = if (protocol == .modern) identity else null,
        .acknowledged = self.acknowledged.load(.acquire),
    }, notification);
    switch (decision) {
        .acknowledge => {
            if (self.acknowledged.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                debug_trace.logf(
                    "mcp",
                    "tool subscription acknowledged connection_generation={d} subscription_generation={d}",
                    .{ self.connection_generation, identity.generation },
                );
            }
        },
        .invalidate => {
            self.commit_lock.lockUncancelable(io_mod.getIo());
            defer self.commit_lock.unlock(io_mod.getIo());
            saturatingIncrement(&self.notifications_seen);
            const coalesce = decideCoalesce(
                notificationInvalidationPending(self, notification.kind),
                decision,
            );
            switch (notification.kind) {
                .tools_list_changed => saturatingIncrement(&self.invalidation_generation),
                .resources_list_changed => saturatingIncrement(&self.resources_invalidation_generation),
                .resource_updated => saturatingIncrement(&self.resource_update_generation),
                .prompts_list_changed => saturatingIncrement(&self.prompts_invalidation_generation),
                else => unreachable,
            }
            switch (coalesce) {
                .enqueue => {},
                .already_pending => saturatingIncrement(&self.notifications_coalesced),
                .ignore => {},
            }
        },
        .close_subscription => {
            debug_trace.logf(
                "mcp",
                "tool subscription cancelled by server connection_generation={d} subscription_generation={d}",
                .{ self.connection_generation, identity.generation },
            );
            self.cancel_flag.store(true, .release);
        },
        .close_unsupported => {
            self.unsupported_filter.store(true, .release);
            debug_trace.logf(
                "mcp",
                "tool subscription filter unsupported connection_generation={d} subscription_generation={d}",
                .{ self.connection_generation, identity.generation },
            );
            self.cancel_flag.store(true, .release);
        },
        .ignore_unadvertised,
        .ignore_malformed,
        .ignore_duplicate,
        .ignore_late_generation,
        .ignore_unrelated,
        => debug_trace.logf(
            "mcp",
            "ignored tool subscription notification connection_generation={d} reason={s}",
            .{ self.connection_generation, @tagName(decision) },
        ),
    }
}

fn notificationInvalidationPending(
    self: *const State,
    kind: NotificationKind,
) bool {
    return switch (kind) {
        .tools_list_changed => self.hasInvalidation(),
        .resources_list_changed => self.resources_invalidation_generation.load(.acquire) !=
            self.handled_resources_invalidation_generation.load(.acquire),
        .resource_updated => self.resource_update_generation.load(.acquire) !=
            self.handled_resource_update_generation.load(.acquire),
        .prompts_list_changed => self.prompts_invalidation_generation.load(.acquire) !=
            self.handled_prompts_invalidation_generation.load(.acquire),
        else => false,
    };
}

fn parseNotification(
    value: std.json.Value,
    filters: Filters,
) ?Notification {
    if (value != .object) return null;
    const jsonrpc = value.object.get("jsonrpc") orelse return null;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) return null;
    const method = value.object.get("method") orelse return null;
    if (method != .string) return null;
    if (std.mem.eql(u8, method.string, "notifications/subscriptions/acknowledged")) {
        return .{
            .kind = if (acknowledgementAcceptsFilters(value, filters))
                .subscription_acknowledged
            else
                .subscription_filter_unsupported,
            .subscription_id = subscriptionId(value),
        };
    }
    if (std.mem.eql(u8, method.string, "notifications/tools/list_changed")) {
        return .{
            .kind = if (filters.tools_list_changed) .tools_list_changed else .other,
            .subscription_id = subscriptionId(value),
        };
    }
    if (std.mem.eql(u8, method.string, "notifications/resources/list_changed")) {
        return .{
            .kind = if (filters.resources_list_changed) .resources_list_changed else .other,
            .subscription_id = subscriptionId(value),
        };
    }
    if (std.mem.eql(u8, method.string, "notifications/prompts/list_changed")) {
        return .{
            .kind = if (filters.prompts_list_changed) .prompts_list_changed else .other,
            .subscription_id = subscriptionId(value),
        };
    }
    if (std.mem.eql(u8, method.string, "notifications/resources/updated")) {
        const uri = resourceUpdateUri(value) orelse return null;
        return .{
            .kind = if (containsResourceSubscription(filters.resource_subscriptions, uri))
                .resource_updated
            else
                .other,
            .subscription_id = subscriptionId(value),
            .resource_uri = uri,
        };
    }
    if (std.mem.eql(u8, method.string, "notifications/cancelled")) {
        return .{
            .kind = .subscription_cancelled,
            .cancelled_request_id = cancelledRequestId(value),
        };
    }
    return .{ .kind = .other };
}

fn acknowledgementAcceptsFilters(value: std.json.Value, filters: Filters) bool {
    const params = value.object.get("params") orelse return false;
    if (params != .object) return false;
    const notifications = params.object.get("notifications") orelse return false;
    if (notifications != .object) return false;
    var expected_fields: usize = 0;
    if (filters.tools_list_changed) expected_fields += 1;
    if (filters.resources_list_changed) expected_fields += 1;
    if (filters.prompts_list_changed) expected_fields += 1;
    if (filters.resource_subscriptions.len > 0) expected_fields += 1;
    if (notifications.object.count() != expected_fields) return false;
    if (!acknowledgementBoolean(
        notifications.object,
        "toolsListChanged",
        filters.tools_list_changed,
    )) return false;
    if (!acknowledgementBoolean(
        notifications.object,
        "resourcesListChanged",
        filters.resources_list_changed,
    )) return false;
    if (!acknowledgementBoolean(
        notifications.object,
        "promptsListChanged",
        filters.prompts_list_changed,
    )) return false;
    const resources = notifications.object.get("resourceSubscriptions");
    if (filters.resource_subscriptions.len == 0) return resources == null;
    const acknowledged = resources orelse return false;
    if (acknowledged != .array or acknowledged.array.items.len != filters.resource_subscriptions.len) {
        return false;
    }
    for (acknowledged.array.items, filters.resource_subscriptions) |item, expected| {
        if (item != .string or !std.mem.eql(u8, item.string, expected)) return false;
    }
    return true;
}

fn acknowledgementBoolean(
    object: std.json.ObjectMap,
    name: []const u8,
    expected: bool,
) bool {
    const value = object.get(name);
    if (!expected) return value == null;
    const present = value orelse return false;
    return present == .bool and present.bool;
}

fn resourceUpdateUri(value: std.json.Value) ?[]const u8 {
    const params = value.object.get("params") orelse return null;
    if (params != .object) return null;
    const uri = params.object.get("uri") orelse return null;
    if (uri != .string or uri.string.len == 0) return null;
    return uri.string;
}

fn containsResourceSubscription(subscriptions: []const []const u8, uri: []const u8) bool {
    for (subscriptions) |candidate| {
        if (std.mem.eql(u8, candidate, uri)) return true;
    }
    return false;
}

fn subscriptionId(value: std.json.Value) ?u64 {
    const params = value.object.get("params") orelse return null;
    if (params != .object) return null;
    const meta = params.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const id = meta.object.get("io.modelcontextprotocol/subscriptionId") orelse return null;
    if (id != .integer) return null;
    return std.math.cast(u64, id.integer);
}

fn cancelledRequestId(value: std.json.Value) ?u64 {
    const params = value.object.get("params") orelse return null;
    if (params != .object) return null;
    const id = params.object.get("requestId") orelse return null;
    if (id != .integer) return null;
    return std.math.cast(u64, id.integer);
}

fn buildListenRequest(
    alloc: Allocator,
    request_id: u64,
    filters: Filters,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"subscriptions/listen\",\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/protocolVersion\":\"{s}\",\"io.modelcontextprotocol/clientInfo\":{{\"name\":\"fx\",\"version\":",
        .{ request_id, streamable_http.protocol_version },
    );
    try std.json.Stringify.value(build_options.app_version, .{}, &out.writer);
    try out.writer.writeAll("},\"io.modelcontextprotocol/clientCapabilities\":{}},\"notifications\":{");
    var first = true;
    if (filters.tools_list_changed) {
        try out.writer.writeAll("\"toolsListChanged\":true");
        first = false;
    }
    if (filters.resources_list_changed) {
        if (!first) try out.writer.writeByte(',');
        try out.writer.writeAll("\"resourcesListChanged\":true");
        first = false;
    }
    if (filters.prompts_list_changed) {
        if (!first) try out.writer.writeByte(',');
        try out.writer.writeAll("\"promptsListChanged\":true");
        first = false;
    }
    if (filters.resource_subscriptions.len > 0) {
        if (!first) try out.writer.writeByte(',');
        try out.writer.writeAll("\"resourceSubscriptions\":");
        try std.json.Stringify.value(filters.resource_subscriptions, .{}, &out.writer);
    }
    try out.writer.writeAll("}}}");
    return out.toOwnedSlice();
}

fn validateListenResponse(
    alloc: Allocator,
    body: []const u8,
    request_id: u64,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return error.McpInvalidSubscriptionResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidSubscriptionResponse;
    const object = parsed.value.object;
    const jsonrpc = object.get("jsonrpc") orelse return error.McpInvalidSubscriptionResponse;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.McpInvalidSubscriptionResponse;
    }
    const id = object.get("id") orelse return error.McpInvalidSubscriptionResponse;
    if (id != .integer or std.math.cast(u64, id.integer) != request_id) {
        return error.McpInvalidSubscriptionResponse;
    }
    const result = object.get("result") orelse return error.McpInvalidSubscriptionResponse;
    if (result != .object) return error.McpInvalidSubscriptionResponse;
    const result_type = result.object.get("resultType") orelse
        return error.McpInvalidSubscriptionResponse;
    if (result_type != .string or !std.mem.eql(u8, result_type.string, "complete")) {
        return error.McpInvalidSubscriptionResponse;
    }
    const meta = result.object.get("_meta") orelse return error.McpInvalidSubscriptionResponse;
    if (meta != .object) return error.McpInvalidSubscriptionResponse;
    const subscription_id = meta.object.get("io.modelcontextprotocol/subscriptionId") orelse
        return error.McpInvalidSubscriptionResponse;
    if (subscription_id != .integer or
        std.math.cast(u64, subscription_id.integer) != request_id)
    {
        return error.McpInvalidSubscriptionResponse;
    }
}

fn waitForRetry(self: *State, delay_ms: u64) bool {
    var elapsed: u64 = 0;
    while (elapsed < delay_ms) {
        if (self.cancel_flag.load(.acquire)) return false;
        const step = @min(stop_poll_ms, delay_ms - elapsed);
        io_mod.sleep(@as(u64, step) * std.time.ns_per_ms);
        elapsed += step;
    }
    return !self.cancel_flag.load(.acquire);
}

fn saturatingIncrement(value: *atomic_value.Value(u64)) void {
    var current = value.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        const result = value.cmpxchgWeak(current, current + 1, .monotonic, .monotonic);
        if (result == null) return;
        current = result.?;
    }
}

test "subscription request opens only the Tools filter" {
    const request = try buildListenRequest(std.testing.allocator, 7, .{
        .tools_list_changed = true,
    });
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.find(u8, request, "\"method\":\"subscriptions/listen\"") != null);
    try std.testing.expect(std.mem.find(u8, request, "\"toolsListChanged\":true") != null);
    try std.testing.expect(std.mem.find(u8, request, "resources") == null);
    try std.testing.expect(std.mem.find(u8, request, "prompts") == null);
}

test "subscription parser retains official acknowledgement and change identities" {
    const alloc = std.testing.allocator;
    var acknowledged = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7},\"notifications\":{\"toolsListChanged\":true}}}",
        .{},
    );
    defer acknowledged.deinit();
    const filters = Filters{ .tools_list_changed = true };
    const ack = parseNotification(acknowledged.value, filters).?;
    try std.testing.expectEqual(NotificationKind.subscription_acknowledged, ack.kind);
    try std.testing.expectEqual(@as(?u64, 7), ack.subscription_id);

    var changed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7}}}",
        .{},
    );
    defer changed.deinit();
    const event = parseNotification(changed.value, filters).?;
    try std.testing.expectEqual(NotificationKind.tools_list_changed, event.kind);
    try std.testing.expectEqual(@as(?u64, 7), event.subscription_id);
}

test "subscription request and parser support the complete modern filter set" {
    const alloc = std.testing.allocator;
    const uris = [_][]const u8{ "custom://one", "file:///two" };
    const filters = Filters{
        .tools_list_changed = true,
        .resources_list_changed = true,
        .prompts_list_changed = true,
        .resource_subscriptions = &uris,
    };
    const request = try buildListenRequest(alloc, 9, filters);
    defer alloc.free(request);
    try std.testing.expect(std.mem.find(u8, request, "\"resourcesListChanged\":true") != null);
    try std.testing.expect(std.mem.find(u8, request, "\"promptsListChanged\":true") != null);
    try std.testing.expect(std.mem.find(u8, request, "\"resourceSubscriptions\":[\"custom://one\",\"file:///two\"]") != null);

    var acknowledged = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":9},\"notifications\":{\"toolsListChanged\":true,\"resourcesListChanged\":true,\"promptsListChanged\":true,\"resourceSubscriptions\":[\"custom://one\",\"file:///two\"]}}}",
        .{},
    );
    defer acknowledged.deinit();
    try std.testing.expectEqual(
        NotificationKind.subscription_acknowledged,
        parseNotification(acknowledged.value, filters).?.kind,
    );

    var updated = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":9},\"uri\":\"custom://one\"}}",
        .{},
    );
    defer updated.deinit();
    const event = parseNotification(updated.value, filters).?;
    try std.testing.expectEqual(NotificationKind.resource_updated, event.kind);
    try std.testing.expectEqualStrings("custom://one", event.resource_uri.?);
}

test "subscription acknowledgement fails closed without an exclusive Tools grant" {
    const alloc = std.testing.allocator;
    var unsupported = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7,\"extension\":true},\"notifications\":{}}}",
        .{},
    );
    defer unsupported.deinit();
    const filters = Filters{ .tools_list_changed = true };
    const parsed = parseNotification(unsupported.value, filters).?;
    try std.testing.expectEqual(
        NotificationKind.subscription_filter_unsupported,
        parsed.kind,
    );
    try std.testing.expectEqual(@as(?u64, 7), parsed.subscription_id);

    var unrequested = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7},\"notifications\":{\"resourcesListChanged\":true}}}",
        .{},
    );
    defer unrequested.deinit();
    const unexpected = parseNotification(unrequested.value, filters).?;
    try std.testing.expectEqual(
        NotificationKind.subscription_filter_unsupported,
        unexpected.kind,
    );
    try std.testing.expectEqual(@as(?u64, 7), unexpected.subscription_id);

    var false_tools = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7},\"notifications\":{\"toolsListChanged\":false}}}",
        .{},
    );
    defer false_tools.deinit();
    try std.testing.expectEqual(
        NotificationKind.subscription_filter_unsupported,
        parseNotification(false_tools.value, filters).?.kind,
    );
}

test "subscription graceful result validates exact request identity" {
    try validateListenResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7}}}",
        7,
    );
    try std.testing.expectError(
        error.McpInvalidSubscriptionResponse,
        validateListenResponse(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":8}}}",
            7,
        ),
    );
}

test "subscription server identity ownership releases every allocation failure" {
    const Case = struct {
        fn listen(
            _: *anyopaque,
            alloc: Allocator,
            _: []const u8,
            _: u64,
            _: []const u8,
            _: mcp_contract.NotificationSink,
            _: streamable_http.Control,
        ) anyerror![]u8 {
            return alloc.dupe(
                u8,
                "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":7}}}",
            );
        }

        fn run(alloc: Allocator) !void {
            var context: u8 = 0;
            const state = try State.allocateHttpState(
                alloc,
                "server",
                .{ .context = &context, .callback = listen },
                1,
                7,
                1,
                .{ .tools_list_changed = true },
            );
            state.stopAndDestroy();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

const StdioCreateAttempt = struct {
    dispatcher: *stdio_dispatcher.StdioDispatcher,
    cancel: *std.atomic.Value(bool),
    state: ?*State = null,
    err: ?anyerror = null,

    fn run(self: *StdioCreateAttempt) void {
        self.state = State.createStdio(
            std.testing.allocator,
            self.dispatcher,
            .modern,
            1,
            0,
            1,
            .{ .tools_list_changed = true },
            std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                .clock = .awake,
                .raw = .fromSeconds(1),
            }),
            self.cancel,
        ) catch |err| {
            self.err = err;
            return;
        };
    }
};

fn createIdleStdioDispatcherForTest() !*stdio_dispatcher.StdioDispatcher {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &.{ "sh", "-c", "while IFS= read -r request; do :; done" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    return stdio_dispatcher.StdioDispatcher.create(
        std.testing.allocator,
        std.heap.c_allocator,
        child,
        1,
        4096,
    );
}

fn waitForPendingSubscriptionForTest(
    dispatcher: *stdio_dispatcher.StdioDispatcher,
) !void {
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    while (dispatcher.pendingRequestCount() == 0) {
        if (!std.Io.Clock.Timestamp.compare(
            std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
            .lt,
            deadline,
        )) return error.McpSubscriptionNotRegistered;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
}

fn expectFailedStdioCreateCleanedUp(
    dispatcher: *stdio_dispatcher.StdioDispatcher,
    attempt: StdioCreateAttempt,
    expected: anyerror,
) !void {
    try std.testing.expectEqual(expected, attempt.err.?);
    try std.testing.expect(attempt.state == null);
    try std.testing.expectEqual(@as(usize, 0), dispatcher.pendingRequestCount());
    try std.testing.expect(!dispatcher.hasNotificationSink());
}

test "modern stdio readiness cancellation joins the listener and clears attachment" {
    const dispatcher = try createIdleStdioDispatcherForTest();
    defer dispatcher.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    var attempt = StdioCreateAttempt{ .dispatcher = dispatcher, .cancel = &cancel };
    defer if (attempt.state) |state| state.stopAndDestroy();
    dispatcher.write_mutex.lockUncancelable(io_mod.getIo());
    var write_locked = true;
    defer if (write_locked) dispatcher.write_mutex.unlock(io_mod.getIo());
    const thread = try std.Thread.spawn(.{}, StdioCreateAttempt.run, .{&attempt});
    var joined = false;
    defer if (!joined) thread.join();
    try waitForPendingSubscriptionForTest(dispatcher);
    cancel.store(true, .release);
    thread.join();
    joined = true;
    try expectFailedStdioCreateCleanedUp(dispatcher, attempt, error.Cancelled);
    dispatcher.write_mutex.unlock(io_mod.getIo());
    write_locked = false;
}

test "modern stdio readiness connection failure joins the listener and clears attachment" {
    const dispatcher = try createIdleStdioDispatcherForTest();
    defer dispatcher.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    var attempt = StdioCreateAttempt{ .dispatcher = dispatcher, .cancel = &cancel };
    defer if (attempt.state) |state| state.stopAndDestroy();
    dispatcher.write_mutex.lockUncancelable(io_mod.getIo());
    var write_locked = true;
    defer if (write_locked) dispatcher.write_mutex.unlock(io_mod.getIo());
    const create_thread = try std.Thread.spawn(.{}, StdioCreateAttempt.run, .{&attempt});
    var create_joined = false;
    defer if (!create_joined) create_thread.join();
    try waitForPendingSubscriptionForTest(dispatcher);

    const Shutdown = struct {
        fn run(value: *stdio_dispatcher.StdioDispatcher) void {
            value.shutdown();
        }
    };
    const shutdown_thread = try std.Thread.spawn(.{}, Shutdown.run, .{dispatcher});
    while (dispatcher.isRunning()) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    dispatcher.write_mutex.unlock(io_mod.getIo());
    write_locked = false;
    shutdown_thread.join();
    create_thread.join();
    create_joined = true;
    try expectFailedStdioCreateCleanedUp(dispatcher, attempt, error.McpConnectionClosed);
}

const NotificationKind = enum {
    subscription_acknowledged,
    subscription_filter_unsupported,
    tools_list_changed,
    resources_list_changed,
    resource_updated,
    prompts_list_changed,
    subscription_cancelled,
    other,
};

const Notification = struct {
    kind: NotificationKind,
    subscription_id: ?u64 = null,
    cancelled_request_id: ?u64 = null,
    resource_uri: ?[]const u8 = null,
};

const SubscriptionExpectation = struct {
    protocol: catalog_freshness.Protocol,
    capability_advertised: bool,
    connection_generation: u64,
    event_connection_generation: u64,
    subscription: ?catalog_freshness.SubscriptionIdentity,
    acknowledged: bool,
};

const NotificationDecision = enum {
    acknowledge,
    invalidate,
    close_subscription,
    close_unsupported,
    ignore_unadvertised,
    ignore_malformed,
    ignore_duplicate,
    ignore_late_generation,
    ignore_unrelated,
};

fn classifyNotification(
    expectation: SubscriptionExpectation,
    notification: Notification,
) NotificationDecision {
    if (!expectation.capability_advertised) return .ignore_unadvertised;
    if (expectation.connection_generation != expectation.event_connection_generation) {
        return .ignore_late_generation;
    }
    if (expectation.protocol == .legacy) {
        return switch (notification.kind) {
            .tools_list_changed,
            .resources_list_changed,
            .resource_updated,
            .prompts_list_changed,
            => .invalidate,
            else => .ignore_unrelated,
        };
    }

    const subscription = expectation.subscription orelse return .ignore_late_generation;
    return switch (notification.kind) {
        .subscription_acknowledged => {
            const subscription_id = notification.subscription_id orelse
                return .ignore_malformed;
            if (subscription_id != subscription.request_id) return .ignore_late_generation;
            if (expectation.acknowledged) return .ignore_duplicate;
            return .acknowledge;
        },
        .subscription_filter_unsupported => {
            const subscription_id = notification.subscription_id orelse
                return .ignore_malformed;
            if (subscription_id != subscription.request_id) return .ignore_late_generation;
            if (expectation.acknowledged) return .ignore_duplicate;
            return .close_unsupported;
        },
        .tools_list_changed,
        .resources_list_changed,
        .resource_updated,
        .prompts_list_changed,
        => {
            const subscription_id = notification.subscription_id orelse
                return .ignore_malformed;
            if (subscription_id != subscription.request_id) return .ignore_late_generation;
            if (!expectation.acknowledged) return .ignore_late_generation;
            return .invalidate;
        },
        .subscription_cancelled => {
            const request_id = notification.cancelled_request_id orelse
                return .ignore_malformed;
            return if (request_id == subscription.request_id)
                .close_subscription
            else
                .ignore_late_generation;
        },
        .other => .ignore_unrelated,
    };
}

const CoalesceDecision = enum {
    enqueue,
    already_pending,
    ignore,
};

fn decideCoalesce(pending: bool, notification: NotificationDecision) CoalesceDecision {
    if (notification != .invalidate) return .ignore;
    return if (pending) .already_pending else .enqueue;
}

test "duplicate notifications are idempotent" {
    const subscription = catalog_freshness.SubscriptionIdentity{ .request_id = 17, .generation = 3 };
    const notification = Notification{
        .kind = .tools_list_changed,
        .subscription_id = 17,
    };
    const expectation = SubscriptionExpectation{
        .protocol = .modern,
        .capability_advertised = true,
        .connection_generation = 4,
        .event_connection_generation = 4,
        .subscription = subscription,
        .acknowledged = true,
    };
    const classified = classifyNotification(expectation, notification);
    try std.testing.expectEqual(NotificationDecision.invalidate, classified);
    try std.testing.expectEqual(CoalesceDecision.enqueue, decideCoalesce(false, classified));
    try std.testing.expectEqual(CoalesceDecision.already_pending, decideCoalesce(true, classified));
}

test "modern notification classification rejects malformed late and duplicate events" {
    const subscription = catalog_freshness.SubscriptionIdentity{ .request_id = 8, .generation = 2 };
    const base = SubscriptionExpectation{
        .protocol = .modern,
        .capability_advertised = true,
        .connection_generation = 5,
        .event_connection_generation = 5,
        .subscription = subscription,
        .acknowledged = false,
    };
    try std.testing.expectEqual(
        NotificationDecision.ignore_malformed,
        classifyNotification(base, .{ .kind = .subscription_acknowledged }),
    );
    try std.testing.expectEqual(
        NotificationDecision.ignore_late_generation,
        classifyNotification(base, .{
            .kind = .subscription_acknowledged,
            .subscription_id = 9,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.acknowledge,
        classifyNotification(base, .{
            .kind = .subscription_acknowledged,
            .subscription_id = 8,
        }),
    );
    var acknowledged = base;
    acknowledged.acknowledged = true;
    try std.testing.expectEqual(
        NotificationDecision.ignore_duplicate,
        classifyNotification(acknowledged, .{
            .kind = .subscription_acknowledged,
            .subscription_id = 8,
        }),
    );
    var late = acknowledged;
    late.event_connection_generation = 4;
    try std.testing.expectEqual(
        NotificationDecision.ignore_late_generation,
        classifyNotification(late, .{
            .kind = .tools_list_changed,
            .subscription_id = 8,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.close_subscription,
        classifyNotification(acknowledged, .{
            .kind = .subscription_cancelled,
            .cancelled_request_id = 8,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.close_unsupported,
        classifyNotification(base, .{
            .kind = .subscription_filter_unsupported,
            .subscription_id = 8,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.ignore_malformed,
        classifyNotification(base, .{
            .kind = .subscription_filter_unsupported,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.ignore_late_generation,
        classifyNotification(acknowledged, .{
            .kind = .subscription_cancelled,
            .cancelled_request_id = 7,
        }),
    );
}
