const tool_operations = @import("tool_operations.zig");
const feature_operations = @import("feature_operations.zig");
const feature_catalog_runtime = @import("feature_catalog_runtime.zig");
const legacy_elicitation_runtime = @import("legacy_elicitation_runtime.zig");
const feature_transport = @import("feature_transport.zig");
const catalog_refresh = @import("catalog_refresh.zig");
const tool_search = @import("tool_search.zig");
const server_views = @import("server_views.zig");
const std = @import("std");
const atomic_value = @import("atomic_value.zig");
const server_connection = @import("server_connection.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const collections = @import("../shared/collections.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp_contract = @import("mcp_contract.zig");
const mcp_auth = @import("mcp_auth.zig");
const server_auth = @import("server_auth.zig");
const server_subscriptions = @import("server_subscriptions.zig");
const server_transport = @import("server_transport.zig");
const server_lifecycle = @import("server_lifecycle.zig");
const mcp_auth_store = @import("mcp_auth_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const selected_schema = @import("selected_schema.zig");
const tool_names = @import("tool_names.zig");
const tool_catalog = @import("tool_catalog.zig");
const tool_snapshot = @import("tool_snapshot.zig");
const feature_catalog = @import("feature_catalog.zig");
const feature_snapshot = @import("feature_snapshot.zig");
const FeatureIdentitySnapshot = feature_snapshot.Snapshot;
const ToolCallSnapshot = tool_snapshot.Snapshot;
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");
const context_limits = @import("../config/context_limits.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const capability_retrieval = @import("../tooling/capability_retrieval.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const legacy_http_sse = @import("legacy_http_sse.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const elicitation = @import("elicitation.zig");
const legacy_url_completion = @import("legacy_url_completion.zig");
const mrtr = @import("mrtr.zig");
const operation_control = @import("operation_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const mcp_json = @import("mcp_json.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
const protocol_messages = @import("protocol_messages.zig");
const buildDiscoverRequest = protocol_messages.buildDiscoverRequest;
const buildToolsListRequest = protocol_messages.buildToolsListRequest;
const writeModernRequestMetadata = protocol_messages.writeModernRequestMetadata;
const buildToolCallRequest = protocol_messages.buildToolCallRequest;
const buildToolCallRequestForProtocol = protocol_messages.buildToolCallRequestForProtocol;
const writeModernRequestMetadataWithProgress = protocol_messages.writeModernRequestMetadataWithProgress;
const writeModernRequestMetadataForm = protocol_messages.writeModernRequestMetadataForm;
const writeModernRequestMetadataUrl = protocol_messages.writeModernRequestMetadataUrl;
const writeModernRequestMetadataFormAndUrl = protocol_messages.writeModernRequestMetadataFormAndUrl;
const buildLegacyInitializeRequest = protocol_messages.buildLegacyInitializeRequest;
const buildCancellationNotification = protocol_messages.buildCancellationNotification;
const parseToolsListChangedCapabilityFromResponse = protocol_messages.parseToolsListChangedCapabilityFromResponse;
const parseServerCapabilitiesFromResponse = protocol_messages.parseServerCapabilitiesFromResponse;
const parseServerIdentity = protocol_messages.parseServerIdentity;
const parseToolsListChangedCapability = protocol_messages.parseToolsListChangedCapability;
const parseServerCapabilities = protocol_messages.parseServerCapabilities;
const optionalCapabilityBool = protocol_messages.optionalCapabilityBool;
const featureProtocol = protocol_messages.featureProtocol;
const docker_run = @import("docker_run.zig");
const stdio_dispatcher = @import("stdio_dispatcher.zig");
const streamable_http = @import("streamable_http.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const access_policy = @import("access_policy.zig");
const health = @import("health.zig");
const model_catalog = @import("model_catalog.zig");
const startup_admission = @import("startup_admission.zig");
const project_config = @import("project_config.zig");
const tool_subscription = @import("tool_subscription.zig");
const completion_feature = @import("features/completion.zig");
const prompts_feature = @import("features/prompts.zig");
const resources_feature = @import("features/resources.zig");
const tools_feature = @import("features/tools.zig");
const tool_result = @import("tool_result.zig");

const Allocator = std.mem.Allocator;
const legacy_protocol_version = protocol_negotiation.legacy_protocol_version;
const legacy_2025_06_protocol_version = protocol_negotiation.legacy_2025_06_protocol_version;
const legacy_2025_11_protocol_version = protocol_negotiation.legacy_2025_11_protocol_version;
const modern_protocol_version = protocol_negotiation.modern_protocol_version;
const missing_required_client_capability_code: i64 = -32021;
const unsupported_protocol_version_code = protocol_negotiation.unsupported_protocol_version_code;
const default_mcp_search_limit: usize = 8;
const max_mcp_search_limit: usize = 20;
const mcp_tool_description_search_bytes: usize = 2 * 1024;
const mcp_tool_schema_search_bytes: usize = 4 * 1024;
const max_pending_legacy_url_waiters = legacy_url_completion.max_pending_legacy_url_waiters;
const max_early_legacy_url_completions_per_window = legacy_url_completion.max_early_legacy_url_completions_per_window;
const max_legacy_url_completion_candidates = legacy_url_completion.max_legacy_url_completion_candidates;
const max_legacy_url_completion_windows = legacy_url_completion.max_legacy_url_completion_windows;
const early_legacy_url_completion_ttl_ms = legacy_url_completion.early_legacy_url_completion_ttl_ms;
const allocateGeneration = @import("server_lifetime.zig").allocateIdentity;

const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const lockRwUntil = controlled_lock.rwUntil;
const lockMutexUntil = controlled_lock.mutexUntil;
const checkOperationControl = controlled_lock.checkOperation;
const StdioProtocol = protocol_negotiation.Protocol;
const ResponsePayload = protocol_negotiation.ResponsePayload;
const DiscoveryOutcome = protocol_negotiation.DiscoveryOutcome;
const LegacyStdioVersion = protocol_negotiation.LegacyStdioVersion;
const LegacyInitializeObservation = protocol_negotiation.LegacyInitializeObservation;
const LegacyInitializeTransition = protocol_negotiation.LegacyInitializeTransition;
const decideLegacyInitializeTransition = protocol_negotiation.decideLegacyInitializeTransition;
const classifyResponsePayload = protocol_negotiation.classifyResponsePayload;
const classifyDiscoveryResponse = protocol_negotiation.classifyDiscoveryResponse;
const classifyHttpDiscoveryResponse = protocol_negotiation.classifyHttpDiscoveryResponse;
const classifyLegacyInitializeResponse = protocol_negotiation.classifyLegacyInitializeResponse;

pub const LoadRuntimeFn = *const fn (
    Allocator,
    []const u8,
    elicitation.Capabilities,
) anyerror!?*McpRuntime;

pub const PreviewNativeWorkspaceAuthorityFn = *const fn (
    Allocator,
    []const u8,
) anyerror![][]u8;

const connection_control = @import("connection_control.zig");
const operation_authority = @import("operation_authority.zig");
const startupDeadline = connection_control.startupDeadline;

const LegacyUrlWaiter = legacy_url_completion.Waiter;
const LegacyUrlWireCompletionIdentity = legacy_url_completion.WireCompletionIdentity;
const LegacyUrlCompletionCandidate = legacy_url_completion.Candidate;
const LegacyUrlCompletionReplayStep = legacy_url_completion.ReplayStep;

fn applyLegacyUrlCompletion(
    waiter: *LegacyUrlWaiter,
    completion: elicitation.LegacyUrlCompletionIdentity,
) bool {
    return legacy_url_completion.apply(waiter, completion, operation_control.awakeMillis(io_mod.getIo()));
}

fn awaitFeatureServer(
    runtime: *McpRuntime,
    server: *const McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    if (server.config.source == .workspace and server.config.workspace_admission != .approved) return error.McpWorkspaceApprovalRequired;
    while (server.startup_state.load(.acquire) == .loading or
        (runtime.isDiscovering() and server.startup_state.load(.acquire) == .idle))
    {
        if (server.cancellation().load(.acquire)) return error.Cancelled;
        try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
    if (server.cancellation().load(.acquire)) return error.Cancelled;
    try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
}

test "feature startup waits honor the caller deadline and cancellation" {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var server = McpServer{ .config = .{ .name = "starting" }, .startup_state = .init(.loading) };
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.McpRequestTimedOut, awaitFeatureServer(&runtime, &server, std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(10) }), &cancel));
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, awaitFeatureServer(&runtime, &server, std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromSeconds(1) }), &cancel));
    cancel.store(false, .release);
    server.startup_state.store(.complete, .release);
    try awaitFeatureServer(&runtime, &server, std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromSeconds(1) }), &cancel);
}

fn completeFeatureArgument(
    self: *McpRuntime,
    alloc: Allocator,
    server_name: []const u8,
    reference: completion_feature.Reference,
    argument: completion_feature.Argument,
    context_arguments: []const completion_feature.Argument,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !CompletionResult {
    var operation_access = try OperationAccessGuard.init(
        self.alloc,
        access,
        self.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server_name });
    const server = self.acquireServer(server_name) orelse return error.McpServerNotFound;
    defer server.lifetime.release(io_mod.getIo());
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(server.config.operation_timeout_ms),
    });
    try awaitFeatureServer(self, server, deadline, cancel_flag);
    return feature_operations.completeFeatureArgument(self.featureCatalogs(), alloc, server, deadline, reference, argument, context_arguments, cancel_flag, access);
}

pub const ServerState = server_connection.ServerState;

pub const ToolFreshness = catalog_freshness.Freshness;
const DiscoveryState = server_connection.DiscoveryState;

pub const McpServerConfig = mcp_contract.McpServerConfig;
const freeOwnedStrings = mcp_contract.freeOwnedStrings;

const catalog_state = @import("catalog_state.zig");
pub const McpTool = catalog_state.McpTool;
pub const ToolCatalogSnapshot = catalog_state.ToolCatalogSnapshot;
pub const ResourceCatalogSnapshot = catalog_state.ResourceCatalogSnapshot;
pub const ResourceTemplateCatalogSnapshot = catalog_state.ResourceTemplateCatalogSnapshot;
pub const PromptCatalogSnapshot = catalog_state.PromptCatalogSnapshot;
pub const ResourceReadCacheEntry = catalog_state.ResourceReadCacheEntry;
pub const ServerCapabilities = catalog_state.ServerCapabilities;

const feature_result = @import("feature_result.zig");
pub const ResourceSummary = feature_result.ResourceSummary;
pub const ResourceCatalogResult = feature_result.ResourceCatalogResult;
pub const PromptSummary = feature_result.PromptSummary;
pub const PromptCatalogResult = feature_result.PromptCatalogResult;
pub const FeatureCallOptions = feature_result.FeatureCallOptions;
pub const ResourceReadResult = feature_result.ResourceReadResult;
pub const PromptGetResult = feature_result.PromptGetResult;
pub const CompletionResult = feature_result.CompletionResult;

const ServerAccessPrecommit = operation_authority.SendGuard;

const OperationAccessGuard = operation_authority.Guard;

const authorizeLiveAccess = operation_authority.authorizeLiveAccess;
const resolveLiveAuthority = operation_authority.resolveLiveAuthority;

const bindingForSnapshot = tool_snapshot.binding;

const snapshotServerHealthBeforeDiscoveryPublication = server_views.snapshotServerHealthBeforeDiscoveryPublication;
const snapshotServerHealth = server_views.snapshotServerHealth;
const configuredAuthenticationState = server_views.configuredAuthenticationState;
const serverAuthenticationState = server_views.serverAuthenticationState;
const snapshotServerModelSummary = server_views.snapshotServerModelSummary;
const terminalSafeOwned = server_views.terminalSafeOwned;
const healthFailureForState = server_views.healthFailureForState;

const DetachedTransport = server_connection.DetachedTransport;
pub const McpServer = server_connection.Server;

const freeTools = catalog_state.freeTools;

pub const McpRuntime = struct {
    alloc: Allocator,
    completions: legacy_url_completion.State,
    tool_aliases: tool_names.Registry,
    generation: u64,
    servers: std.ArrayList(*McpServer) = .empty,
    pending_servers: []const *McpServer = &.{},
    reload_mutex: std.Io.Mutex = .init,
    workspace_diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty,
    server_mutex: std.Io.RwLock = .init,
    catalog_mutex: std.Io.RwLock = .init,
    lifecycle_mutex: std.Io.Mutex = .init,
    lifecycle_cond: std.Io.Condition = .init,
    active_users: usize = 0,
    retiring: std.atomic.Value(bool) = .init(false),
    tool_registry: tool_dispatch.Registry = .{},
    legacy_elicitation_capabilities: elicitation.Capabilities = .{},
    discovery_state: std.atomic.Value(DiscoveryState) = .init(.idle),
    discovery_cancel_requested: std.atomic.Value(bool) = .init(false),
    discovery_thread: ?std.Thread = null,

    fn legacyInputs(self: *McpRuntime) legacy_elicitation_runtime.Coordination {
        return .{ .catalog_mutex = &self.catalog_mutex, .completions = &self.completions };
    }

    fn toolOperations(self: *McpRuntime) tool_operations.Operations {
        return .{ .lifecycle = self.lifecycle(), .generation = self.generation, .completions = &self.completions };
    }

    fn featureCatalogs(self: *McpRuntime) feature_catalog_runtime.Operations {
        return .{ .transport = self.featureTransport(), .lifecycle = self.lifecycle() };
    }

    fn featureTransport(self: *McpRuntime) feature_transport.Operations {
        return .{ .alloc = self.alloc, .generation = self.generation, .catalog_mutex = &self.catalog_mutex, .completions = &self.completions };
    }

    fn catalogRefresh(self: *McpRuntime) catalog_refresh.Context {
        return .{ .lifecycle = self.lifecycle(), .generation = self.generation };
    }

    fn lifecycle(self: *McpRuntime) server_lifecycle.Operations {
        return .{
            .alloc = self.alloc,
            .catalog_mutex = &self.catalog_mutex,
            .tool_aliases = &self.tool_aliases,
            .tool_registry = self.tool_registry,
        };
    }

    pub fn init(alloc: Allocator) McpRuntime {
        return .{ .alloc = alloc, .completions = .init(alloc), .tool_aliases = .init(alloc), .generation = allocateGeneration() };
    }

    pub fn initWithElicitation(
        alloc: Allocator,
        capabilities: elicitation.Capabilities,
    ) McpRuntime {
        return .{
            .alloc = alloc,
            .generation = allocateGeneration(),
            .completions = .init(alloc),
            .tool_aliases = .init(alloc),
            .legacy_elicitation_capabilities = capabilities,
        };
    }

    pub fn deinit(self: *McpRuntime) void {
        self.discovery_cancel_requested.store(true, .seq_cst);
        if (self.discovery_thread) |thread| {
            self.discovery_thread = null;
            thread.join();
        }
        for (self.servers.items) |server| self.destroyServer(server);
        self.servers.deinit(self.alloc);
        for (self.workspace_diagnostics.items) |*diagnostic| {
            diagnostic.deinit(self.alloc);
        }
        self.workspace_diagnostics.deinit(self.alloc);
        self.completions.deinit();
        self.tool_aliases.deinit();
    }

    fn destroyServer(self: *McpRuntime, server: *McpServer) void {
        server.lifetime.retire();
        server.connection_lock.lockSharedUncancelable(io_mod.getIo());
        server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
        server.signalToolSubscriptionStop();
        server.catalog_commit_lock.unlock(io_mod.getIo());
        server.connection_lock.unlockShared(io_mod.getIo());
        server.lifetime.wait(io_mod.getIo());
        server.subscription_lifecycle_lock.lockUncancelable(io_mod.getIo());
        server.connection_lock.lockUncancelable(io_mod.getIo());
        server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
        self.catalog_mutex.lockUncancelable(io_mod.getIo());
        var detached = server_connection.detachPublishedConnection(server);
        self.catalog_mutex.unlock(io_mod.getIo());
        server.catalog_commit_lock.unlock(io_mod.getIo());
        detached.deinitGracefully(self.alloc);
        server.deinit(self.alloc);
        server.connection_lock.unlock(io_mod.getIo());
        server.subscription_lifecycle_lock.unlock(io_mod.getIo());
        self.alloc.destroy(server);
    }

    pub fn legacyUrlCompletionRecorded(self: *McpRuntime, origin: tool_mcp_runtime.InputOrigin, id: []const u8) bool {
        return self.completions.legacyUrlCompletionRecorded(origin, id);
    }

    pub fn setLegacyUrlCompletionSink(
        self: *McpRuntime,
        sink: ?tool_mcp_runtime.LegacyUrlCompletionSink,
    ) void {
        if (sink != null and self.completions.runtime_generation == 0) {
            self.completions.runtime_generation = allocateGeneration();
            std.debug.assert(self.completions.runtime_generation != 0);
        }
        self.completions.sink = sink;
    }

    pub fn acquireUse(self: *McpRuntime) bool {
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        if (self.retiring.load(.acquire)) {
            self.lifecycle_mutex.unlock(io_mod.getIo());
            return false;
        }
        self.active_users += 1;
        const active_users = self.active_users;
        self.lifecycle_mutex.unlock(io_mod.getIo());
        debug_trace.logf("mcp", "runtime lease acquired active_users={d}", .{active_users});
        return true;
    }

    pub fn releaseUse(self: *McpRuntime) void {
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        std.debug.assert(self.active_users > 0);
        self.active_users -= 1;
        if (self.active_users == 0) self.lifecycle_cond.broadcast(io_mod.getIo());
        const active_users = self.active_users;
        self.lifecycle_mutex.unlock(io_mod.getIo());
        debug_trace.logf("mcp", "runtime lease released active_users={d}", .{active_users});
    }

    /// Prevents new users, publishes cancellation to active interactions, and
    /// waits without holding an app/catalog lock. The owner may deinit/destroy
    /// the runtime after this returns.
    pub fn retireAndWait(self: *McpRuntime) void {
        self.retiring.store(true, .release);
        self.server_mutex.lockSharedUncancelable(io_mod.getIo());
        for (self.servers.items) |server| server.lifetime.retire();
        for (self.pending_servers) |server| server.lifetime.retire();
        self.server_mutex.unlockShared(io_mod.getIo());
        self.discovery_cancel_requested.store(true, .release);
        self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        self.completions.cancelAllLegacyUrlWaitersLocked();
        self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        for (self.servers.items) |server| {
            server.connection_lock.lockSharedUncancelable(io_mod.getIo());
            server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
            server.signalToolSubscriptionStop();
            server.catalog_commit_lock.unlock(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());
        }
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        const active_users = self.active_users;
        self.lifecycle_mutex.unlock(io_mod.getIo());
        debug_trace.logf("mcp", "runtime retirement signalled active_users={d}", .{active_users});
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        defer self.lifecycle_mutex.unlock(io_mod.getIo());
        while (self.active_users > 0) {
            self.lifecycle_cond.waitUncancelable(io_mod.getIo(), &self.lifecycle_mutex);
        }
    }

    fn registerCurrentLegacyUrlWaiter(self: *McpRuntime, waiter: *LegacyUrlWaiter) !void {
        if (self.retiring.load(.acquire)) return error.Cancelled;
        const server = self.acquireServer(waiter.binding.server_name) orelse return error.Cancelled;
        defer server.lifetime.release(io_mod.getIo());
        return self.legacyInputs().registerWaiter(server, waiter);
    }

    fn beginLegacyUrlCompletionWindow(
        self: *McpRuntime,
        source: tool_subscription.NotificationSource,
        runtime_generation: u64,
    ) !u64 {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        if (!self.legacyCompletionSourceCurrentLocked(
            source.server_name,
            runtime_generation,
            source.connection_generation,
            source.client_generation,
            source.auth_generation,
        )) return error.Cancelled;
        return self.completions.beginWindowLocked(source, runtime_generation);
    }
    fn registerLegacyUrlCompletionCandidates(
        self: *McpRuntime,
        source: tool_subscription.NotificationSource,
        runtime_generation: u64,
        window_generation: ?u64,
        ids: []const []const u8,
    ) !void {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        const source_state = self.legacyCompletionSourceStateLocked(
            source.server_name,
            runtime_generation,
            source.connection_generation,
            source.client_generation,
            source.auth_generation,
        );
        return self.completions.registerCandidatesLocked(source, runtime_generation, window_generation, ids, source_state, operation_control.awakeMillis(io_mod.getIo()));
    }
    fn legacyCompletionSourceCurrentLocked(
        self: *McpRuntime,
        server_name: []const u8,
        runtime_generation: u64,
        connection_generation: u64,
        client_generation: u64,
        auth_generation: u64,
    ) bool {
        return self.legacyCompletionSourceStateLocked(
            server_name,
            runtime_generation,
            connection_generation,
            client_generation,
            auth_generation,
        ) == .current;
    }

    const LegacyCompletionSourceState = legacy_url_completion.SourceState;

    fn legacyCompletionSourceStateLocked(
        self: *McpRuntime,
        server_name: []const u8,
        runtime_generation: u64,
        connection_generation: u64,
        client_generation: u64,
        auth_generation: u64,
    ) LegacyCompletionSourceState {
        if (self.retiring.load(.acquire) or self.completions.runtime_generation != runtime_generation) return .stale;
        const server = self.findServer(server_name) orelse return .stale;
        return server.legacySourceState(connection_generation, client_generation, auth_generation);
    }

    fn replayLogoutFencedLegacyUrlCompletions(
        self: *McpRuntime,
        server_name: []const u8,
    ) void {
        while (true) switch (self.replayLogoutFencedLegacyUrlCompletionStep(server_name)) {
            .done => return,
            .progressed => {},
            .publication => |publication| {
                publication.sink.publish(publication.sink.context, publication.id);
            },
        };
    }

    fn replayLogoutFencedLegacyUrlCompletionStep(
        self: *McpRuntime,
        server_name: []const u8,
    ) LegacyUrlCompletionReplayStep {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        for (self.completions.legacy_url_completion_candidates.items) |*candidate| {
            if (candidate.status != .logout_fenced or
                !std.mem.eql(u8, candidate.server_name, server_name) or
                !self.legacyCompletionSourceCurrentLocked(
                    candidate.server_name,
                    candidate.runtime_generation,
                    candidate.connection_generation,
                    candidate.client_generation,
                    candidate.auth_generation,
                ))
            {
                continue;
            }
            const completion = LegacyUrlWireCompletionIdentity{
                .server_name = candidate.server_name,
                .elicitation_id = candidate.elicitation_id,
                .runtime_generation = candidate.runtime_generation,
                .connection_generation = candidate.connection_generation,
                .client_generation = candidate.client_generation,
                .auth_generation = candidate.auth_generation,
            };
            const recorded = self.completions.recordLegacyUrlCompletionFromWireLocked(completion);
            if (recorded) candidate.status = .handled;
            const sink = self.completions.sink orelse {
                if (recorded) return .progressed;
                continue;
            };
            switch (sink.consume(sink.context, .{
                .server_name = completion.server_name,
                .elicitation_id = completion.elicitation_id,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                .auth_generation = completion.auth_generation,
            })) {
                .missing => if (recorded) return .progressed,
                .consumed => |maybe_id| {
                    if (!recorded) candidate.status = .handled;
                    if (maybe_id) |id| {
                        return .{ .publication = .{ .sink = sink, .id = id } };
                    }
                    return .progressed;
                },
            }
        }
        return .done;
    }

    pub fn reconcileLegacyUrlCompletion(
        self: *McpRuntime,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
        sink: tool_mcp_runtime.LegacyUrlCompletionSink,
    ) void {
        const publication = publication: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
            defer self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
            if (!self.legacyCompletionSourceCurrentLocked(
                origin.server_name,
                origin.runtime_generation,
                origin.connection_generation,
                origin.client_generation,
                origin.auth_generation,
            )) break :publication null;
            if (!self.completions.legacyUrlCompletionRecordedLocked(origin, elicitation_id) and
                !self.completions.earlyLegacyUrlCompletionRecordedLocked(origin, elicitation_id))
            {
                break :publication null;
            }
            const consumed = sink.consume(sink.context, .{
                .server_name = origin.server_name,
                .elicitation_id = elicitation_id,
                .runtime_generation = origin.runtime_generation,
                .connection_generation = origin.connection_generation,
                .client_generation = origin.client_generation,
                .auth_generation = origin.auth_generation,
            });
            break :publication switch (consumed) {
                .missing => null,
                .consumed => |id| consumed: {
                    self.completions.markLegacyUrlCompletionHandledLocked(origin, elicitation_id);
                    break :consumed id;
                },
            };
        };
        if (publication) |id| sink.publish(sink.context, id);
    }

    pub fn acceptLegacyUrlCompletion(
        self: *McpRuntime,
        origin: tool_mcp_runtime.InputOrigin,
        acp_id: []const u8,
        sink: tool_mcp_runtime.LegacyUrlCompletionSink,
    ) ?tool_mcp_runtime.LegacyUrlAcceptStatus {
        const accepted = accepted: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
            defer self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
            if (!self.legacyCompletionSourceCurrentLocked(
                origin.server_name,
                origin.runtime_generation,
                origin.connection_generation,
                origin.client_generation,
                origin.auth_generation,
            )) break :accepted tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
            const server = self.findServer(origin.server_name) orelse
                break :accepted tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
            if (server.catalog_generation != origin.catalog_generation) {
                break :accepted tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
            }
            break :accepted sink.accept(sink.context, origin, acp_id);
        };
        return switch (accepted) {
            .missing => null,
            .awaiting_completion => .awaiting_completion,
            .completed => |id| completed: {
                sink.publish(sink.context, id);
                break :completed .completed;
            },
        };
    }

    pub fn addServer(
        self: *McpRuntime,
        config: McpServerConfig,
    ) (Allocator.Error || error{ McpConfigScopeMismatch, McpConfigAdmissionMismatch, McpRuntimeAlreadyStarted })!void {
        if (self.discovery_state.load(.acquire) != .idle) return error.McpRuntimeAlreadyStarted;
        if (!mcp_contract.sourceAllowsScope(config.source, config.scope)) {
            return error.McpConfigScopeMismatch;
        }
        if (!mcp_contract.sourceAllowsWorkspaceAdmission(
            config.source,
            config.workspace_admission,
        )) {
            return error.McpConfigAdmissionMismatch;
        }
        try self.appendOwnedServer(.{ .config = config });
    }

    fn appendOwnedServer(self: *McpRuntime, value: McpServer) Allocator.Error!void {
        const server = try self.alloc.create(McpServer);
        errdefer self.alloc.destroy(server);
        server.* = value;
        self.bindServer(server);
        if (server.authority_id.load(.acquire) == 0) server.authority_id.store(allocateGeneration(), .release);
        try self.servers.append(self.alloc, server);
    }

    fn bindServer(self: *McpRuntime, server: *McpServer) void {
        server.owner_alloc = self.alloc;
        server.session_generation = self.generation;
        server.elicitation_capabilities = self.legacy_elicitation_capabilities;
        server.completion_state = &self.completions;
        server.legacy_notifications = .{ .context = self, .callback = handleLegacyCompletionNotification };
    }

    /// Applies admitted configuration without replacing healthy equal servers.
    /// The caller owns candidate; published nodes are removed from it. A returned
    /// message is owned by the caller and means a required candidate was rejected.
    pub fn reconcile(
        self: *McpRuntime,
        candidate: ?*McpRuntime,
        cancel: *std.atomic.Value(bool),
        retain_on_required_failure: bool,
    ) !?[]u8 {
        self.reload_mutex.lockUncancelable(io_mod.getIo());
        defer self.reload_mutex.unlock(io_mod.getIo());
        if (cancel.load(.acquire) or self.retiring.load(.acquire)) return error.Cancelled;
        const current = try self.acquireServers();
        var current_retained = true;
        defer if (current_retained) self.releaseServers(current);
        const configured = if (candidate) |next| next.servers.items else &.{};
        var authority_reduced = false;
        for (current) |server| {
            if (server.config.source != .workspace or server.config.workspace_admission != .approved) continue;
            const retained = for (configured) |next| {
                if (next.config.source == .workspace and next.config.enabled and
                    next.config.workspace_admission == .approved and
                    std.mem.eql(u8, next.config.name, server.config.name)) break true;
            } else false;
            if (!retained) {
                server.lifetime.retire();
                authority_reduced = true;
            }
        }
        var desired: std.ArrayList(*McpServer) = .empty;
        defer desired.deinit(self.alloc);
        var work: std.ArrayList(*McpServer) = .empty;
        defer work.deinit(self.alloc);
        try desired.ensureTotalCapacity(self.alloc, configured.len);
        try work.ensureTotalCapacity(self.alloc, configured.len);
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        for (configured) |next| {
            const reused = for (current) |existing| {
                if (!project_config.sameServerConfig(existing.config, next.config)) continue;
                if (!existing.isPublished() or existing.state.load(.acquire) != .ready) continue;
                if (existing.dispatcher) |dispatcher| if (!dispatcher.isRunning()) continue;
                break existing;
            } else null;
            if (reused) |server| {
                desired.appendAssumeCapacity(server);
            } else {
                self.bindServer(next);
                desired.appendAssumeCapacity(next);
                switch (startup_admission.decide(next.config.enabled, next.config.required, next.config.workspace_admission, .all)) {
                    .connect => {
                        next.startup_state.store(.loading, .release);
                        work.appendAssumeCapacity(next);
                    },
                    .disabled => next.state.store(.disabled, .release),
                    .deferred => {},
                }
            }
        }
        self.catalog_mutex.unlockShared(io_mod.getIo());
        for (current) |server| {
            if (std.mem.findScalar(*McpServer, desired.items, server) == null) server.reload_pending.store(true, .release);
        }
        var reload_marks_active = true;
        defer if (reload_marks_active) {
            for (current) |server| server.reload_pending.store(false, .release);
        };
        self.server_mutex.lockUncancelable(io_mod.getIo());
        self.pending_servers = work.items;
        if (self.retiring.load(.acquire)) for (work.items) |server| server.lifetime.retire();
        self.server_mutex.unlock(io_mod.getIo());
        defer {
            self.server_mutex.lockUncancelable(io_mod.getIo());
            self.pending_servers = &.{};
            self.server_mutex.unlock(io_mod.getIo());
        }
        var batch = DiscoveryBatch{
            .runtime = self,
            .servers = work.items,
            .used_tool_names = &self.tool_aliases,
            .cancel_requested = cancel,
            .server_timeout = null,
            .phase = .all,
        };
        batch.runAndJoin();
        if (cancel.load(.acquire) or self.retiring.load(.acquire)) return error.Cancelled;
        if (retain_on_required_failure and !authority_reduced) {
            for (desired.items) |server| {
                if (!server.config.required) continue;
                server.status_lock.lockUncancelable(io_mod.getIo());
                defer server.status_lock.unlock(io_mod.getIo());
                if (server.state.load(.acquire) != .ready) {
                    const safe_name = try terminalSafeOwned(self.alloc, server.config.name, 256);
                    defer self.alloc.free(safe_name);
                    const failure = try healthFailureForState(self.alloc, true, switch (server.state.load(.acquire)) {
                        .disconnected => .disconnected,
                        .disabled => .disabled,
                        .ready => .ready,
                        .failed => .failed,
                    }, serverAuthenticationState(server), server.last_error);
                    defer if (failure) |message| self.alloc.free(message);
                    return try std.fmt.allocPrint(self.alloc, "Required MCP server '{s}' failed to start: {s}", .{ safe_name, failure orelse "Check the trusted profile configuration and retry." });
                }
            }
        }
        self.catalog_mutex.lockUncancelable(io_mod.getIo());
        self.server_mutex.lockUncancelable(io_mod.getIo());
        if (cancel.load(.acquire) or self.retiring.load(.acquire)) {
            self.server_mutex.unlock(io_mod.getIo());
            self.catalog_mutex.unlock(io_mod.getIo());
            return error.Cancelled;
        }
        var previous = self.servers;
        self.servers = desired;
        desired = .empty;
        for (previous.items) |server| {
            if (std.mem.findScalar(*McpServer, self.servers.items, server) == null) server.lifetime.retire();
        }
        if (candidate) |next| {
            var index: usize = 0;
            while (index < next.servers.items.len) {
                if (std.mem.findScalar(*McpServer, self.servers.items, next.servers.items[index]) != null) {
                    _ = next.servers.swapRemove(index);
                } else index += 1;
            }
            std.mem.swap(std.ArrayList(project_config.WorkspaceDiagnostic), &self.workspace_diagnostics, &next.workspace_diagnostics);
        } else {
            for (self.workspace_diagnostics.items) |*diagnostic| diagnostic.deinit(self.alloc);
            self.workspace_diagnostics.clearRetainingCapacity();
        }
        self.pending_servers = &.{};
        self.discovery_state.store(.complete, .release);
        self.server_mutex.unlock(io_mod.getIo());
        self.catalog_mutex.unlock(io_mod.getIo());
        for (current) |server| server.reload_pending.store(false, .release);
        reload_marks_active = false;
        self.releaseServers(current);
        current_retained = false;
        for (previous.items) |server| {
            if (std.mem.findScalar(*McpServer, self.servers.items, server) == null) self.destroyServer(server);
        }
        previous.deinit(self.alloc);
        return null;
    }

    /// Stops revoked workspace authority immediately without disrupting profile
    /// servers. Reconciliation or shutdown drains the retired owners.
    pub fn revokeWorkspaceExceptNames(self: *McpRuntime, names: []const []const u8) bool {
        self.server_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.server_mutex.unlockShared(io_mod.getIo());
        var reduced = false;
        for (self.servers.items) |server| {
            if (server.config.source != .workspace or server.config.workspace_admission != .approved or
                server.lifetime.retiring.load(.acquire)) continue;
            const retained = for (names) |name| {
                if (std.mem.eql(u8, name, server.config.name)) break true;
            } else false;
            if (!retained) {
                server.lifetime.retire();
                reduced = true;
            }
        }
        return reduced;
    }

    pub fn drainRetiredServers(self: *McpRuntime) Allocator.Error!void {
        self.reload_mutex.lockUncancelable(io_mod.getIo());
        defer self.reload_mutex.unlock(io_mod.getIo());
        var retired: std.ArrayList(*McpServer) = .empty;
        defer retired.deinit(self.alloc);
        self.catalog_mutex.lockUncancelable(io_mod.getIo());
        self.server_mutex.lockUncancelable(io_mod.getIo());
        retired.ensureTotalCapacity(self.alloc, self.servers.items.len) catch |err| {
            self.server_mutex.unlock(io_mod.getIo());
            self.catalog_mutex.unlock(io_mod.getIo());
            return err;
        };
        var index: usize = 0;
        while (index < self.servers.items.len) {
            if (self.servers.items[index].lifetime.retiring.load(.acquire)) {
                retired.appendAssumeCapacity(self.servers.orderedRemove(index));
            } else index += 1;
        }
        self.server_mutex.unlock(io_mod.getIo());
        self.catalog_mutex.unlock(io_mod.getIo());
        for (retired.items) |server| self.destroyServer(server);
    }

    pub fn workspaceAuthorityReducedAgainstConfigs(
        self: *const McpRuntime,
        next: []const McpServerConfig,
        phase: startup_admission.Phase,
    ) bool {
        const table_lock = &@constCast(self).server_mutex;
        table_lock.lockSharedUncancelable(io_mod.getIo());
        defer table_lock.unlockShared(io_mod.getIo());
        for (self.servers.items) |current| {
            if (!project_config.configRetainsWorkspaceAuthority(
                current.config,
                next,
                phase,
            )) return true;
        }
        return false;
    }

    pub fn pendingWorkspaceNames(
        self: *const McpRuntime,
        alloc: Allocator,
    ) ![][]u8 {
        const table_lock = &@constCast(self).server_mutex;
        table_lock.lockSharedUncancelable(io_mod.getIo());
        defer table_lock.unlockShared(io_mod.getIo());
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        for (self.servers.items) |server| {
            if (!server.config.enabled or
                server.config.source != .workspace or
                server.config.workspace_admission != .pending) continue;
            const owned_name = try terminalSafeOwned(alloc, server.config.name, 256);
            errdefer alloc.free(owned_name);
            try names.append(alloc, owned_name);
        }
        return names.toOwnedSlice(alloc);
    }

    pub fn firstPendingWorkspaceName(
        self: *const McpRuntime,
        alloc: Allocator,
    ) !?[]u8 {
        const table_lock = &@constCast(self).server_mutex;
        table_lock.lockSharedUncancelable(io_mod.getIo());
        defer table_lock.unlockShared(io_mod.getIo());
        for (self.servers.items) |server| {
            if (!server.config.enabled or
                server.config.source != .workspace or
                server.config.workspace_admission != .pending) continue;
            return @as(?[]u8, try alloc.dupe(u8, server.config.name));
        }
        return null;
    }

    pub fn hasPendingWorkspace(self: *const McpRuntime) bool {
        const table_lock = &@constCast(self).server_mutex;
        table_lock.lockSharedUncancelable(io_mod.getIo());
        defer table_lock.unlockShared(io_mod.getIo());
        for (self.servers.items) |server| {
            if (server.config.enabled and
                server.config.source == .workspace and
                server.config.workspace_admission == .pending) return true;
        }
        return false;
    }

    pub fn takeWorkspaceDiagnostics(
        self: *McpRuntime,
        diagnostics: *std.ArrayList(project_config.WorkspaceDiagnostic),
    ) !void {
        try self.workspace_diagnostics.ensureUnusedCapacity(
            self.alloc,
            diagnostics.items.len,
        );
        self.workspace_diagnostics.appendSliceAssumeCapacity(diagnostics.items);
        diagnostics.clearRetainingCapacity();
    }

    pub fn waitForDiscovery(
        self: *McpRuntime,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !void {
        while (self.isDiscovering()) {
            if (cancel_flag) |flag| {
                if (flag.load(.acquire)) return error.Cancelled;
            }
            if (self.retiring.load(.acquire)) return error.McpRuntimeUnavailable;
            try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
        }
    }

    pub fn waitForRequiredDiscovery(self: *McpRuntime, cancel_flag: ?*std.atomic.Value(bool)) !void {
        while (self.isDiscovering()) {
            if (cancel_flag) |flag| if (flag.load(.acquire)) return error.Cancelled;
            if (self.retiring.load(.acquire)) return error.McpRuntimeUnavailable;
            self.server_mutex.lockSharedUncancelable(io_mod.getIo());
            const pending = for (self.servers.items) |server| {
                if (!server.config.required) continue;
                if (startup_admission.decide(server.config.enabled, true, server.config.workspace_admission, .all) != .connect) continue;
                if (server.startup_state.load(.acquire) != .complete) break true;
            } else false;
            self.server_mutex.unlockShared(io_mod.getIo());
            if (!pending) return;
            try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
        }
    }

    pub fn snapshotHealth(
        self: *McpRuntime,
        alloc: Allocator,
        captured_at_ms: u64,
    ) !health.Snapshot {
        const server_handles = try self.acquireServers();
        defer self.releaseServers(server_handles);
        const items = try alloc.alloc(health.ServerSnapshot, server_handles.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |*item| item.deinit(alloc);
            alloc.free(items);
        }
        const discovery_state = self.discovery_state.load(.seq_cst);
        for (server_handles, 0..) |server, index| {
            if (!server.isPublished() or discovery_state == .idle or
                (discovery_state == .loading and server.startup_state.load(.acquire) == .idle))
            {
                items[index] = try snapshotServerHealthBeforeDiscoveryPublication(
                    alloc,
                    self.generation,
                    server,
                    discovery_state == .loading,
                );
                initialized += 1;
                continue;
            }
            if (!server.connection_lock.tryLockShared(io_mod.getIo())) {
                items[index] = try snapshotServerHealthBeforeDiscoveryPublication(alloc, self.generation, server, true);
                initialized += 1;
                continue;
            }
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            if (!server.isPublished()) {
                self.catalog_mutex.unlockShared(io_mod.getIo());
                server.connection_lock.unlockShared(io_mod.getIo());
                items[index] = try snapshotServerHealthBeforeDiscoveryPublication(alloc, self.generation, server, true);
                initialized += 1;
                continue;
            }
            server.status_lock.lockUncancelable(io_mod.getIo());
            items[index] = snapshotServerHealth(
                alloc,
                self.generation,
                server,
                operation_control.monotonicMillis(io_mod.getIo()),
            ) catch |err| {
                server.status_lock.unlock(io_mod.getIo());
                self.catalog_mutex.unlockShared(io_mod.getIo());
                server.connection_lock.unlockShared(io_mod.getIo());
                return err;
            };
            server.status_lock.unlock(io_mod.getIo());
            self.catalog_mutex.unlockShared(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());
            initialized += 1;
        }
        self.server_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.server_mutex.unlockShared(io_mod.getIo());
        const configuration_issues = try alloc.alloc(
            health.ConfigurationIssue,
            self.workspace_diagnostics.items.len,
        );
        var issues_initialized: usize = 0;
        errdefer {
            for (configuration_issues[0..issues_initialized]) |*issue| issue.deinit(alloc);
            alloc.free(configuration_issues);
        }
        for (self.workspace_diagnostics.items, 0..) |diagnostic, index| {
            configuration_issues[index] = .{
                .message = try project_config.renderWorkspaceDiagnostic(
                    alloc,
                    diagnostic,
                ),
            };
            issues_initialized += 1;
        }
        return .{
            .captured_at_ms = captured_at_ms,
            .servers = items,
            .configuration_issues = configuration_issues,
        };
    }

    /// Returns an owned model-safe catalog snapshot. The caller releases it with `deinit`.
    pub fn snapshotModelCatalog(
        self: *McpRuntime,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
        include_ask_deferred: bool,
    ) !model_catalog.Snapshot {
        const server_handles = try self.acquireServers();
        defer self.releaseServers(server_handles);
        const servers = try alloc.alloc(model_catalog.ServerSummary, server_handles.len);
        var initialized: usize = 0;
        errdefer {
            for (servers[0..initialized]) |server| alloc.free(server.name);
            alloc.free(servers);
        }

        const discovery_state = self.discovery_state.load(.acquire);
        for (server_handles, 0..) |server, index| {
            if (!server.isPublished() or discovery_state == .idle or
                (discovery_state == .loading and server.startup_state.load(.acquire) == .idle))
            {
                const connection: health.ConnectionState = if (!server.config.enabled)
                    .disabled
                else if (discovery_state == .loading)
                    .connecting
                else
                    .disconnected;
                servers[index] = .{
                    .name = try alloc.dupe(u8, server.config.name),
                    .availability = model_catalog.classifyAvailability(
                        connection,
                        configuredAuthenticationState(server),
                        false,
                    ),
                };
                initialized += 1;
                continue;
            }

            if (!server.connection_lock.tryLockShared(io_mod.getIo())) {
                servers[index] = .{ .name = try alloc.dupe(u8, server.config.name), .availability = .discovering };
                initialized += 1;
                continue;
            }
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            if (!server.isPublished()) {
                self.catalog_mutex.unlockShared(io_mod.getIo());
                server.connection_lock.unlockShared(io_mod.getIo());
                servers[index] = .{ .name = try alloc.dupe(u8, server.config.name), .availability = .discovering };
                initialized += 1;
                continue;
            }
            server.status_lock.lockUncancelable(io_mod.getIo());
            servers[index] = snapshotServerModelSummary(
                alloc,
                server,
                permission_rules,
                include_ask_deferred and server.startup_state.load(.acquire) == .idle,
            ) catch |err| {
                server.status_lock.unlock(io_mod.getIo());
                self.catalog_mutex.unlockShared(io_mod.getIo());
                server.connection_lock.unlockShared(io_mod.getIo());
                return err;
            };
            server.status_lock.unlock(io_mod.getIo());
            self.catalog_mutex.unlockShared(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());
            initialized += 1;
        }
        return .{ .servers = servers };
    }

    pub fn requiredStartupFailure(
        self: *McpRuntime,
        alloc: Allocator,
        captured_at_ms: u64,
    ) !?[]u8 {
        var snapshot = try self.snapshotHealth(alloc, captured_at_ms);
        defer snapshot.deinit(alloc);
        if (health.startupDecision(snapshot.servers) != .blocked) return null;
        for (snapshot.servers) |server| {
            if (!server.required or server.connection == .ready) continue;
            const message = try std.fmt.allocPrint(
                alloc,
                "Required MCP server '{s}' failed to start: {s}",
                .{
                    server.configured_name,
                    server.failure orelse "Check the trusted profile configuration and retry.",
                },
            );
            return message;
        }
        const fallback = try alloc.dupe(u8, "A required MCP server is unavailable.");
        return fallback;
    }

    pub fn startupDecision(
        self: *McpRuntime,
        alloc: Allocator,
        captured_at_ms: u64,
    ) !health.StartupDecision {
        var snapshot = try self.snapshotHealth(alloc, captured_at_ms);
        defer snapshot.deinit(alloc);
        return health.startupDecision(snapshot.servers);
    }

    pub const ServerDiagnostic = struct {
        name: []u8,
        command: []u8,
        state: health.ConnectionState,
        tool_count: usize,
        last_error: ?[]u8,

        fn deinit(self: *ServerDiagnostic, alloc: Allocator) void {
            alloc.free(self.name);
            alloc.free(self.command);
            if (self.last_error) |value| alloc.free(value);
            self.* = undefined;
        }
    };

    pub const ServerDiagnostics = struct {
        items: []ServerDiagnostic,

        pub fn deinit(self: *ServerDiagnostics, alloc: Allocator) void {
            for (self.items) |*item| item.deinit(alloc);
            alloc.free(self.items);
            self.* = undefined;
        }
    };

    pub fn snapshotServerDiagnostics(self: *McpRuntime, alloc: Allocator) !ServerDiagnostics {
        var snapshot = try self.snapshotHealth(alloc, operation_control.monotonicMillis(io_mod.getIo()));
        defer snapshot.deinit(alloc);
        const items = try alloc.alloc(ServerDiagnostic, snapshot.servers.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |*item| item.deinit(alloc);
            alloc.free(items);
        }
        for (snapshot.servers, 0..) |observed, index| {
            const name = try alloc.dupe(u8, observed.identity());
            errdefer alloc.free(name);
            const server = self.acquireServer(observed.identity());
            defer if (server) |value| value.lifetime.release(io_mod.getIo());
            const command = try alloc.dupe(u8, if (server) |value| value.config.command orelse "" else "");
            errdefer alloc.free(command);
            items[index] = .{
                .name = name,
                .command = command,
                .state = observed.connection,
                .tool_count = observed.counts.tools orelse 0,
                .last_error = if (observed.failure) |failure| try alloc.dupe(u8, failure) else null,
            };
            initialized += 1;
        }
        return .{ .items = items };
    }

    pub fn connectAll(self: *McpRuntime, tool_registry: tool_dispatch.Registry) void {
        self.tool_registry = tool_registry;
        self.discovery_cancel_requested.store(false, .seq_cst);
        self.connectAllCancellable(tool_registry, &self.discovery_cancel_requested);
    }

    pub fn connectAllForAcp(self: *McpRuntime, tool_registry: tool_dispatch.Registry) void {
        self.tool_registry = tool_registry;
        if (self.discovery_state.cmpxchgStrong(.idle, .loading, .seq_cst, .seq_cst) != null) return;
        self.discovery_cancel_requested.store(false, .seq_cst);
        self.connectAllControlled(
            tool_registry,
            &self.discovery_cancel_requested,
            null,
            .acp_startup,
        );
        self.discovery_state.store(.complete, .seq_cst);
    }

    pub fn connectAllCancellable(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        cancel_requested: *std.atomic.Value(bool),
    ) void {
        self.tool_registry = tool_registry;
        if (self.discovery_state.cmpxchgStrong(.idle, .loading, .seq_cst, .seq_cst) != null) return;
        self.connectAllControlled(tool_registry, cancel_requested, null, .all);
        self.discovery_state.store(.complete, .seq_cst);
    }

    /// Connects only required profile servers before a one-shot Ask reaches the
    /// Gateway. Optional servers remain dormant until Ask uses MCP directly or
    /// captures MCP authority for a child.
    pub fn connectRequiredForAsk(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        cancel: *std.atomic.Value(bool),
    ) void {
        self.tool_registry = tool_registry;
        if (self.discovery_state.cmpxchgStrong(.idle, .loading, .seq_cst, .seq_cst) != null) return;
        self.discovery_cancel_requested.store(false, .seq_cst);
        self.connectAllControlled(
            tool_registry,
            cancel,
            null,
            .ask_startup,
        );
        self.discovery_state.store(.complete, .seq_cst);
    }

    /// Activates optional one-shot Ask servers exactly once. Concurrent MCP
    /// operations wait for the active loader instead of launching duplicates.
    pub fn connectDeferredForAsk(self: *McpRuntime, tool_registry: tool_dispatch.Registry, cancel: *std.atomic.Value(bool)) !void {
        const server_handles = try self.acquireServers();
        defer self.releaseServers(server_handles);
        if (self.retiring.load(.acquire)) return error.McpRuntimeRetired;
        self.connectAllControlled(tool_registry, cancel, null, .ask_deferred);
        for (server_handles) |server| try self.waitForServerStartup(server, cancel);
    }

    fn waitForServerStartup(self: *McpRuntime, server: *const McpServer, cancel: *std.atomic.Value(bool)) !void {
        while (server.startup_state.load(.acquire) == .loading) {
            if (self.retiring.load(.acquire) or self.discovery_cancel_requested.load(.acquire) or cancel.load(.acquire)) return error.Cancelled;
            try io_mod.getIo().sleep(.fromMilliseconds(1), .awake);
        }
    }

    /// Activates one dormant server without starting unrelated optional servers.
    pub fn connectDeferredServerForAsk(self: *McpRuntime, tool_registry: tool_dispatch.Registry, name: []const u8, access: tool_mcp_runtime.Access, kind: enum { tools, features }, cancel: *std.atomic.Value(bool)) !void {
        var authority = try OperationAccessGuard.init(self.alloc, access, self.generation);
        defer authority.deinit();
        const target: access_policy.Target = if (kind == .tools) .{ .tool_server = name } else .{ .feature_server = name };
        try authority.authorize(target);
        const server = self.acquireServer(name) orelse return error.McpServerNotFound;
        defer server.lifetime.release(io_mod.getIo());
        if (startup_admission.decide(server.config.enabled, server.config.required, server.config.workspace_admission, .ask_deferred) != .connect) return;
        if (server.startup_state.load(.acquire) == .complete) return;
        try authority.refreshAndAuthorize(target);
        if (self.retiring.load(.acquire) or self.discovery_cancel_requested.load(.acquire) or cancel.load(.acquire)) return error.Cancelled;
        _ = tool_registry;
        if (server.startup_state.cmpxchgStrong(.idle, .loading, .acq_rel, .acquire) != null) return self.waitForServerStartup(server, cancel);
        defer server.startup_state.store(.complete, .release);
        server.connection_lock.lockUncancelable(io_mod.getIo());
        defer server.connection_lock.unlock(io_mod.getIo());
        const names = &self.tool_aliases;
        connectServerCancellable(self, server, names, cancel, null) catch |err| {
            server.setFailed(self.alloc, @errorName(err));
            return err;
        };
    }

    pub fn connectDeferredToolForAsk(self: *McpRuntime, tool_registry: tool_dispatch.Registry, name: []const u8, access: tool_mcp_runtime.Access, cancel: *std.atomic.Value(bool)) !void {
        const server_handles = try self.acquireServers();
        defer self.releaseServers(server_handles);
        if (!access.allowsTool(self.generation, name)) return error.McpAuthorityChanged;
        for (server_handles) |server| {
            if (tool_names.matchesServer(name, server.config.name)) {
                try self.connectDeferredServerForAsk(tool_registry, server.config.name, access, .tools, cancel);
            }
        }
    }

    pub fn startDiscovery(self: *McpRuntime, tool_registry: tool_dispatch.Registry) void {
        self.startDiscoveryControlled(tool_registry, null);
    }

    fn startDiscoveryWithServerTimeout(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        server_timeout: std.Io.Duration,
    ) void {
        self.startDiscoveryControlled(tool_registry, server_timeout);
    }

    fn startDiscoveryControlled(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        server_timeout: ?std.Io.Duration,
    ) void {
        self.tool_registry = tool_registry;
        if (self.discovery_state.cmpxchgStrong(.idle, .loading, .seq_cst, .seq_cst) != null) return;
        self.discovery_cancel_requested.store(false, .seq_cst);
        self.discovery_thread = std.Thread.spawn(.{}, discoveryThreadMain, .{ self, tool_registry, server_timeout }) catch |err| {
            debug_trace.logf("mcp", "discovery thread failed to start: {s}", .{@errorName(err)});
            self.discovery_state.store(.complete, .seq_cst);
            return;
        };
    }

    pub fn isDiscovering(self: *const McpRuntime) bool {
        return self.discovery_state.load(.seq_cst) == .loading;
    }

    fn discoveryThreadMain(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        server_timeout: ?std.Io.Duration,
    ) void {
        self.connectAllControlled(
            tool_registry,
            &self.discovery_cancel_requested,
            server_timeout,
            .all,
        );
        self.discovery_state.store(.complete, .seq_cst);
    }

    fn connectAllControlled(
        self: *McpRuntime,
        _: tool_dispatch.Registry,
        cancel_requested: *std.atomic.Value(bool),
        server_timeout: ?std.Io.Duration,
        phase: startup_admission.Phase,
    ) void {
        const used_tool_names = &self.tool_aliases;

        const server_handles = self.acquireServers() catch {
            debug_trace.logf("mcp", "startup batch could not retain servers", .{});
            return;
        };
        defer self.releaseServers(server_handles);
        const jobs = self.alloc.alloc(*McpServer, server_handles.len) catch {
            debug_trace.logf("mcp", "startup batch could not allocate server slots", .{});
            return;
        };
        defer self.alloc.free(jobs);
        var index_count: usize = 0;
        self.catalog_mutex.lockUncancelable(io_mod.getIo());
        for (server_handles) |server| {
            switch (startup_admission.decide(server.config.enabled, server.config.required, server.config.workspace_admission, phase)) {
                .connect => if (server.startup_state.cmpxchgStrong(.idle, .loading, .acq_rel, .acquire) == null) {
                    jobs[index_count] = server;
                    index_count += 1;
                },
                .disabled => server.state.store(.disabled, .release),
                .deferred => {},
            }
        }
        self.catalog_mutex.unlock(io_mod.getIo());
        defer {
            // Workers have joined before the batch releases its publication barrier.
            for (jobs[0..index_count]) |server| server.startup_state.store(.complete, .release);
        }

        var batch = DiscoveryBatch{
            .runtime = self,
            .servers = jobs[0..index_count],
            .used_tool_names = used_tool_names,
            .cancel_requested = cancel_requested,
            .server_timeout = server_timeout,
            .phase = phase,
        };
        batch.runAndJoin();
    }

    pub fn reloadCatalogs(self: *McpRuntime, cancel: *std.atomic.Value(bool)) !void {
        const servers = try self.acquireServers();
        defer self.releaseServers(servers);
        for (servers) |server| {
            if (server.isPublished() and server.state.load(.acquire) == .ready) server.reload_pending.store(true, .release);
        }
        defer for (servers) |server| server.reload_pending.store(false, .release);
        var batch = DiscoveryBatch{
            .runtime = self,
            .servers = servers,
            .used_tool_names = &self.tool_aliases,
            .cancel_requested = cancel,
            .server_timeout = null,
            .phase = .all,
            .refresh_catalogs = true,
        };
        batch.runAndJoin();
        if (cancel.load(.acquire)) return error.Cancelled;
    }

    const DiscoveryBatch = struct {
        runtime: *McpRuntime,
        servers: []const *McpServer,
        used_tool_names: *tool_names.Registry,
        cancel_requested: *std.atomic.Value(bool),
        server_timeout: ?std.Io.Duration,
        phase: startup_admission.Phase,
        refresh_catalogs: bool = false,
        next_index: std.atomic.Value(usize) = .init(0),

        fn runAndJoin(batch: *@This()) void {
            if (comptime builtin.single_threaded) {
                batch.run();
                return;
            }
            var workers: [7]std.Thread = undefined;
            var worker_count: usize = 0;
            defer for (workers[0..worker_count]) |worker| worker.join();
            for (0..@min(workers.len, batch.servers.len -| 1)) |_| {
                workers[worker_count] = std.Thread.spawn(.{}, run, .{batch}) catch break;
                worker_count += 1;
            }
            batch.run();
        }

        fn run(batch: *@This()) void {
            const self = batch.runtime;
            while (true) {
                const index = batch.next_index.fetchAdd(1, .monotonic);
                if (index >= batch.servers.len) return;
                const server = batch.servers[index];
                if (batch.cancel_requested.load(.acquire)) return;
                if (batch.refresh_catalogs) {
                    defer server.reload_pending.store(false, .release);
                    self.catalogRefresh().reload(server, batch.cancel_requested) catch |err| {
                        debug_trace.logf("mcp", "catalog reload failed server={s} err={s}", .{ server.config.name, @errorName(err) });
                    };
                    continue;
                }
                if (server.startup_state.load(.acquire) == .complete) continue;
                switch (startup_admission.decide(
                    server.config.enabled,
                    server.config.required,
                    server.config.workspace_admission,
                    batch.phase,
                )) {
                    .disabled => {
                        var name_buf: [256]u8 = undefined;
                        debug_trace.logf(
                            "mcp",
                            "skipped disabled server {s}",
                            .{debug_trace.terminalPreview(name_buf[0..], server.config.name)},
                        );
                        continue;
                    },
                    .deferred => continue,
                    .connect => {},
                }
                server.connection_lock.lockUncancelable(io_mod.getIo());
                defer server.connection_lock.unlock(io_mod.getIo());
                defer server.startup_state.store(.complete, .release);
                connectServerCancellable(
                    self,
                    server,
                    batch.used_tool_names,
                    batch.cancel_requested,
                    batch.server_timeout,
                ) catch |err| {
                    if (batch.cancel_requested.load(.acquire)) return;
                    var name_buf: [256]u8 = undefined;
                    debug_trace.logf(
                        "mcp",
                        "connection failed for server {s}: {s}",
                        .{
                            debug_trace.terminalPreview(name_buf[0..], server.config.name),
                            @errorName(err),
                        },
                    );
                    if (server.last_error == null) {
                        server.setFailed(self.alloc, @errorName(err));
                    } else {
                        server.state.store(.failed, .release);
                    }
                };
            }
        }
    };

    pub fn authenticateServer(
        self: *McpRuntime,
        name: []const u8,
        open_ctx: ?*anyopaque,
        open_url: mcp_auth.OpenUrlFn,
    ) !mcp_auth.AuthenticationResult {
        return self.authenticateServerControlled(
            name,
            open_ctx,
            open_url,
            null,
        );
    }

    pub fn authenticateServerControlled(
        self: *McpRuntime,
        name: []const u8,
        open_ctx: ?*anyopaque,
        open_url: mcp_auth.OpenUrlFn,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !mcp_auth.AuthenticationResult {
        const server = try self.authenticationServer(name);
        defer server.lifetime.release(io_mod.getIo());
        return server_auth.authenticate(self.alloc, server, open_ctx, open_url, cancel_flag);
    }

    pub fn reconnectAuthenticatedServer(self: *McpRuntime, name: []const u8, cancel: ?*std.atomic.Value(bool)) !void {
        const server = try self.authenticationServer(name);
        defer server.lifetime.release(io_mod.getIo());
        const deadline = startupDeadline(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), server.config.startup_timeout_ms, null);
        return self.lifecycle().reconnectRemote(server, deadline, cancel, .negotiate);
    }

    pub fn validateAuthenticationServer(self: *McpRuntime, name: []const u8) !void {
        const server = try self.authenticationServer(name);
        server.lifetime.release(io_mod.getIo());
    }

    fn authenticationServer(self: *McpRuntime, name: []const u8) !*McpServer {
        const server = self.acquireServer(name) orelse return error.McpServerNotFound;
        errdefer server.lifetime.release(io_mod.getIo());
        if (!server.isPublished()) return error.McpDiscoveryInProgress;
        if (server.config.transport == .stdio) return error.McpAuthenticationNotRemote;
        if (server.config.source == .workspace and
            server.config.workspace_admission != .approved)
        {
            return error.McpWorkspaceApprovalRequired;
        }
        return server;
    }

    pub const LogoutResult = server_auth.LogoutResult;
    const detachAuthForLogout = server_auth.detachAuthForLogout;

    pub fn logoutServer(self: *McpRuntime, name: []const u8) !LogoutResult {
        const server = self.acquireServer(name) orelse return error.McpServerNotFound;
        defer server.lifetime.release(io_mod.getIo());
        defer self.replayLogoutFencedLegacyUrlCompletions(server.config.name);
        return server_auth.logout(self.alloc, &self.catalog_mutex, &self.completions, server);
    }

    fn bindingForTool(self: *const McpRuntime, server: *const McpServer, tool: McpTool) tool_mcp_runtime.Binding {
        return bindingForSnapshot(self.generation, server, tool);
    }

    /// Returns a retained server; the caller releases its lifetime after all I/O.
    fn acquireServer(self: *McpRuntime, name: []const u8) ?*McpServer {
        self.server_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.server_mutex.unlockShared(io_mod.getIo());
        const server = self.findServer(name) orelse return null;
        return if (server.lifetime.acquire(io_mod.getIo())) server else null;
    }

    fn acquireServers(self: *McpRuntime) Allocator.Error![]*McpServer {
        self.server_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.server_mutex.unlockShared(io_mod.getIo());
        var servers: std.ArrayList(*McpServer) = .empty;
        errdefer servers.deinit(self.alloc);
        try servers.ensureTotalCapacity(self.alloc, self.servers.items.len);
        for (self.servers.items) |server| {
            if (server.lifetime.acquire(io_mod.getIo())) servers.appendAssumeCapacity(server);
        }
        return servers.toOwnedSlice(self.alloc) catch |err| {
            for (servers.items) |server| server.lifetime.release(io_mod.getIo());
            return err;
        };
    }

    fn releaseServers(self: *McpRuntime, servers: []const *McpServer) void {
        for (servers) |server| server.lifetime.release(io_mod.getIo());
        self.alloc.free(servers);
    }

    fn findServer(self: *McpRuntime, name: []const u8) ?*McpServer {
        for (self.servers.items) |server| {
            if (std.mem.eql(u8, server.config.name, name)) return server;
        }
        return null;
    }

    fn lookupTool(self: *McpRuntime, name: []const u8) ?struct { server: *McpServer, tool: McpTool } {
        for (self.servers.items) |server| {
            if (!server.isPublished() or server.state.load(.acquire) != .ready) continue;
            if (!tool_catalog.serverCatalogAvailable(server)) continue;
            for (server.tool_catalog.tools.items) |tool| {
                if (std.mem.eql(u8, tool.prefixed_name, name)) {
                    return .{ .server = server, .tool = tool };
                }
            }
        }
        return null;
    }

    fn lookupCallableTool(self: *McpRuntime, name: []const u8) ?struct { server: *McpServer, tool: McpTool } {
        for (self.servers.items) |server| {
            if (!server.isPublished() or (server.state.load(.acquire) != .ready and server.state.load(.acquire) != .failed)) continue;
            if (!tool_catalog.serverCatalogAvailable(server)) continue;
            for (server.tool_catalog.tools.items) |tool| {
                if (std.mem.eql(u8, tool.prefixed_name, name)) {
                    return .{ .server = server, .tool = tool };
                }
            }
        }
        return null;
    }

    fn refreshAllToolCatalogs(
        self: *McpRuntime,
        cancel_flag: ?*std.atomic.Value(bool),
        access: *const OperationAccessGuard,
        server_filter: ?[]const u8,
    ) void {
        const server_handles = self.acquireServers() catch |err| {
            debug_trace.logf("mcp", "tool refresh could not retain servers err={s}", .{@errorName(err)});
            return;
        };
        defer self.releaseServers(server_handles);
        for (server_handles) |server| {
            if (server_filter) |name| {
                if (!std.mem.eql(u8, server.config.name, name)) continue;
            }
            if (!access.allows(.{ .tool_server = server.config.name })) {
                continue;
            }
            _ = self.catalogRefresh().refresh(
                server,
                null,
                cancel_flag,
                access.access,
            ) catch |err| {
                debug_trace.logf(
                    "mcp",
                    "tool cache refresh check failed server={s} err={s}",
                    .{ server.config.name, @errorName(err) },
                );
            };
        }
    }

    fn refreshToolCatalogForName(
        self: *McpRuntime,
        name: []const u8,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !void {
        try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
        var matched_server: ?*McpServer = null;
        for (self.servers.items) |server| {
            if (!server.isPublished()) continue;
            for (server.tool_catalog.tools.items) |tool| {
                if (std.mem.eql(u8, tool.prefixed_name, name)) {
                    if (server.lifetime.acquire(io_mod.getIo())) matched_server = server;
                    break;
                }
            }
            if (matched_server != null) break;
        }
        self.catalog_mutex.unlockShared(io_mod.getIo());
        const server = matched_server orelse return;
        defer server.lifetime.release(io_mod.getIo());
        _ = try self.catalogRefresh().refresh(server, deadline, cancel_flag, access);
    }

    pub fn hasTool(self: *McpRuntime, name: []const u8) bool {
        return self.hasToolWithAccess(name, .unrestricted);
    }

    pub fn hasToolWithAccess(
        self: *McpRuntime,
        name: []const u8,
        access: tool_mcp_runtime.Access,
    ) bool {
        var operation_access = OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        ) catch return false;
        defer operation_access.deinit();
        operation_access.authorize(.{ .tool = name }) catch return false;
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        const available = self.lookupCallableTool(name) != null;
        self.catalog_mutex.unlockShared(io_mod.getIo());
        if (!available) return false;
        operation_access.refresh() catch return false;
        operation_access.authorize(.{ .tool = name }) catch return false;
        return true;
    }

    pub fn serverToolFreshness(self: *McpRuntime, name: []const u8) ?ToolFreshness {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        const server = self.findServer(name) orelse return null;
        const metadata = server.tool_catalog.metadata orelse return null;
        if (!tool_catalog.catalogAuthPartitionMatches(server, metadata)) return .stale;
        return catalog_freshness.effectiveFreshness(
            metadata,
            operation_control.monotonicMillis(io_mod.getIo()),
            if (server.tool_subscription) |subscription|
                subscription.hasInvalidation()
            else
                false,
        );
    }

    /// Returns owned names for every currently ready tool not revoked by policy.
    pub fn snapshotToolNames(
        self: *McpRuntime,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
    ) ![][]u8 {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        for (self.servers.items) |server| {
            if (!server.isPublished() or server.state.load(.acquire) != .ready) continue;
            if (!tool_catalog.serverCatalogAvailable(server)) continue;
            for (server.tool_catalog.tools.items) |tool| {
                if (permissions.rulesDenyAllTargetsForPermission(
                    permission_rules,
                    tool.prefixed_name,
                )) continue;
                try names.append(alloc, try alloc.dupe(u8, tool.prefixed_name));
            }
        }
        return names.toOwnedSlice(alloc);
    }

    pub fn snapshotAccessView(
        self: *McpRuntime,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
        features_visible: bool,
    ) !access_policy.View {
        const owned_owner = try alloc.dupe(u8, owner_id);
        errdefer alloc.free(owned_owner);
        const owned_parent = try alloc.dupe(u8, parent_id);
        errdefer alloc.free(owned_parent);
        var servers: std.ArrayList(access_policy.ServerIdentity) = .empty;
        errdefer {
            for (servers.items) |*server| server.deinit(alloc);
            servers.deinit(alloc);
        }
        var tools: std.ArrayList(access_policy.ToolIdentity) = .empty;
        errdefer {
            for (tools.items) |*tool| tool.deinit(alloc);
            tools.deinit(alloc);
        }
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        for (self.servers.items) |server| {
            if (!server.isPublished() or server.state.load(.acquire) != .ready) continue;
            const first_tool = tools.items.len;
            if (tool_catalog.serverCatalogAvailable(server)) {
                for (server.tool_catalog.tools.items) |tool| {
                    if (permissions.rulesDenyAllTargetsForPermission(
                        permission_rules,
                        tool.prefixed_name,
                    )) continue;
                    const name = try alloc.dupe(u8, tool.prefixed_name);
                    const tool_server_name = alloc.dupe(u8, server.config.name) catch |err| {
                        alloc.free(name);
                        return err;
                    };
                    tools.append(alloc, .{
                        .name = name,
                        .server_name = tool_server_name,
                    }) catch |err| {
                        alloc.free(name);
                        alloc.free(tool_server_name);
                        return err;
                    };
                }
            }
            const admits_tools = tools.items.len != first_tool;
            const admits_features = features_visible and server.capabilities.exposesFeatures();
            if (!admits_tools and !admits_features) continue;
            const server_name = try alloc.dupe(u8, server.config.name);
            servers.append(alloc, .{
                .name = server_name,
                .source = server.config.source,
                .scope = server.config.scope,
                .connection_generation = server.connection_generation,
                .catalog_generation = server.catalog_generation,
                .auth_generation = server.auth_generation.load(.acquire),
            }) catch |err| {
                alloc.free(server_name);
                return err;
            };
        }
        const owned_servers = try servers.toOwnedSlice(alloc);
        errdefer {
            for (owned_servers) |*server| server.deinit(alloc);
            alloc.free(owned_servers);
        }
        const owned_tools = try tools.toOwnedSlice(alloc);
        return .{
            .runtime_generation = self.generation,
            .owner_id = owned_owner,
            .parent_id = owned_parent,
            .features_visible = features_visible,
            .servers = owned_servers,
            .tools = owned_tools,
        };
    }

    /// Copies only published definitions. Does not connect or refresh a server.
    pub fn snapshotToolDefinition(self: *McpRuntime, alloc: Allocator, name: []const u8, known: tool_mcp_runtime.Binding, permission_rules: types.PermissionRuleSet, limits: context_limits.Values, access: tool_mcp_runtime.Access) !tool_mcp_runtime.DefinitionSnapshot {
        if (self.retiring.load(.acquire)) return .unavailable;
        var guard = OperationAccessGuard.init(self.alloc, access, self.generation) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .unavailable,
        };
        defer guard.deinit();
        guard.authorize(.{ .tool = name }) catch return .unavailable;
        const result: tool_mcp_runtime.DefinitionSnapshot = result: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            const match = self.lookupTool(name) orelse break :result .unavailable;
            if (permissions.rulesDenyAllTargetsForPermission(permission_rules, name)) break :result .unavailable;
            if (match.server.tool_subscription) |subscription| if (subscription.hasInvalidation()) break :result .unavailable;
            const current = self.bindingForTool(match.server, match.tool);
            if (std.meta.eql(known, current)) break :result .current;
            var projection = try selected_schema.project(alloc, match.tool, match.server.instructions, limits);
            errdefer projection.deinit(alloc);
            if (projection == .rejected) {
                projection.deinit(alloc);
                debug_trace.logf("mcp", "selected tool schema unavailable because of its context limit tool={s}", .{name});
                break :result .unavailable;
            }
            const owned_name = try alloc.dupe(u8, name);
            if (projection.selected.notice) |notice| alloc.free(notice);
            break :result .{ .updated = .{ .name = owned_name, .schema_json = projection.selected.model_output, .mcp_binding = current } };
        };
        guard.refreshAndAuthorize(.{ .tool = name }) catch |err| {
            if (result == .updated) result.updated.deinit(alloc);
            if (err == error.OutOfMemory) return err;
            return .unavailable;
        };
        return result;
    }

    pub fn toolSchemaJsonByName(
        self: *McpRuntime,
        alloc: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
    ) !?tool_mcp_runtime.ToolSchemaResult {
        return self.toolSchemaJsonByNameWithAccess(
            alloc,
            name,
            permission_rules,
            limits,
            .unrestricted,
            null,
        );
    }

    pub fn toolSchemaJsonByNameWithAccess(
        self: *McpRuntime,
        alloc: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !?tool_mcp_runtime.ToolSchemaResult {
        if (cancel_flag) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .tool = name });
        const deadline = self.catalogOperationDeadline(
            name,
            std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        );
        try self.refreshToolCatalogForName(name, deadline, cancel_flag, access);
        try operation_access.refresh();
        try operation_access.authorize(.{ .tool = name });
        var result = result: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            if (self.lookupTool(name)) |match| {
                const auth_witness = catalogAuthWitness(match.server);
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, match.tool.prefixed_name)) break :result null;
                var projection = try selected_schema.project(alloc, match.tool, match.server.instructions, limits);
                errdefer projection.deinit(alloc);
                if (projection == .selected) projection.selected.mcp_binding = self.bindingForTool(match.server, match.tool);
                try validateCatalogAuthWitness(match.server, auth_witness);
                break :result projection;
            }
            break :result null;
        };
        errdefer if (result) |*owned| owned.deinit(alloc);
        try operation_access.refreshAndAuthorize(.{ .tool = name });
        if (cancel_flag) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
        return result;
    }

    pub fn searchTools(
        self: *McpRuntime,
        alloc: Allocator,
        query: []const u8,
        limit: usize,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.SearchResult {
        const prepared_query = try lexical_relevance.prepare(query);
        return self.searchToolsPrepared(
            alloc,
            .{
                .query = &prepared_query,
                .kind = .mcp,
                .limit = @min(
                    if (limit == 0) default_mcp_search_limit else limit,
                    max_mcp_search_limit,
                ),
            },
            permission_rules,
            limits,
            access,
            null,
        );
    }

    pub fn searchToolsPrepared(
        self: *McpRuntime,
        alloc: Allocator,
        request: capability_retrieval.Request,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !tool_mcp_runtime.SearchResult {
        const server_handles = try self.acquireServers();
        defer self.releaseServers(server_handles);
        if (cancel_flag) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
        if (self.isDiscovering()) {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            const available = for (server_handles) |server| {
                if (server.isPublished() and server.state.load(.acquire) == .ready and tool_catalog.serverCatalogAvailable(server)) break true;
            } else false;
            self.catalog_mutex.unlockShared(io_mod.getIo());
            if (!available) return .{ .model_output = try alloc.dupe(u8, "{\"tools\":[],\"count\":0,\"state\":\"discovering\",\"retryable\":true}") };
        }
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        self.refreshAllToolCatalogs(cancel_flag, &operation_access, request.server);
        try operation_access.refresh();
        var result = result: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            break :result try tool_search.search(alloc, self.generation, server_handles, request, permission_rules, limits, &operation_access);
        };
        errdefer result.deinit(alloc);
        try operation_access.refresh();
        if (cancel_flag) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
        return result;
    }

    pub fn callToolByName(self: *McpRuntime, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize) !?tool_mcp_runtime.CallResult {
        return self.callToolByNameWithOptions(
            arena,
            name,
            arguments_json,
            max_tool_result_bytes,
            .{},
        );
    }

    /// Captures only continuation identity while holding the catalog lock.
    /// Callers perform all transport writes and user waiting after this
    /// returns; no runtime-owned pointer escapes the lock.
    pub fn inputIdentityWitness(
        self: *McpRuntime,
        server_name: []const u8,
    ) ?tool_mcp_runtime.InputIdentityWitness {
        if (self.retiring.load(.acquire)) return null;
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        const server = self.findServer(server_name) orelse return null;
        if (!server.isPublished() or server.state.load(.acquire) != .ready) return null;
        return .{
            .runtime_generation = self.completions.runtime_generation,
            .connection_generation = server.connection_generation,
            .client_generation = if (server.dispatcher) |dispatcher|
                dispatcher.connectionGeneration()
            else
                server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .auth_generation = server.auth_generation.load(.acquire),
        };
    }

    pub fn validateToolArgumentsByName(
        self: *McpRuntime,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) !tool_mcp_runtime.ValidationResult {
        return self.validateToolArgumentsByNameWithAccess(
            arena,
            name,
            arguments_json,
            .unrestricted,
        );
    }

    pub fn validateToolArgumentsByNameWithAccess(
        self: *McpRuntime,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.ValidationResult {
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .tool = name });
        const result = result: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            if (self.lookupCallableTool(name) == null) break :result @as(tool_mcp_runtime.ValidationResult, .not_available);
            tools_feature.validateArguments(arena, arguments_json, .{}) catch |err| {
                break :result @as(tool_mcp_runtime.ValidationResult, .{
                    .invalid = try std.fmt.allocPrint(arena, "Invalid arguments for MCP tool {s}: {s}", .{ name, @errorName(err) }),
                });
            };
            break :result @as(tool_mcp_runtime.ValidationResult, .{ .valid = self.generation });
        };
        try operation_access.refreshAndAuthorize(.{ .tool = name });
        return result;
    }

    pub fn callToolByNameWithOptions(
        self: *McpRuntime,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        if (options.expected_binding) |binding| {
            if (binding.runtime_generation != self.generation) return error.McpAdvertisedToolChanged;
        }
        if (options.expected_runtime_generation) |expected| {
            if (expected != self.generation) return error.McpAuthorityChanged;
        }
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            options.access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .tool = name });
        const deadline = self.catalogOperationDeadline(
            name,
            std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        );
        try self.refreshToolCatalogForName(
            name,
            deadline,
            options.cancel_flag,
            options.access,
        );
        try operation_access.refresh();
        try operation_access.authorize(.{ .tool = name });
        try lockRwSharedUntil(&self.catalog_mutex, deadline, options.cancel_flag);
        var catalog_locked = true;
        defer if (catalog_locked) self.catalog_mutex.unlockShared(io_mod.getIo());
        const match = self.lookupCallableTool(name) orelse {
            self.catalog_mutex.unlockShared(io_mod.getIo());
            catalog_locked = false;
            if (options.expected_binding != null) return error.McpAdvertisedToolChanged;
            return null;
        };
        if (options.expected_binding) |binding| {
            if (!binding.sameDefinition(self.bindingForTool(match.server, match.tool))) return error.McpAdvertisedToolChanged;
        }
        if (!match.server.lifetime.acquire(io_mod.getIo())) return error.McpToolCatalogChanged;
        defer match.server.lifetime.release(io_mod.getIo());
        var snapshot = try ToolCallSnapshot.init(arena, match.server, &match.tool);
        self.catalog_mutex.unlockShared(io_mod.getIo());
        catalog_locked = false;
        defer snapshot.deinit(arena);

        try tools_feature.validateArguments(arena, arguments_json, .{});

        return try self.toolOperations().callToolFromSnapshot(
            arena,
            match.server,
            &snapshot,
            arguments_json,
            max_tool_result_bytes,
            options,
            0,
            null,
        );
    }

    fn serverForSnapshotLocked(
        self: *McpRuntime,
        snapshot: *const ToolCallSnapshot,
    ) ?*McpServer {
        const server = self.findServer(snapshot.server_name) orelse return null;
        return if (tool_snapshot.current(server, snapshot)) server else null;
    }

    fn catalogOperationDeadline(
        self: *McpRuntime,
        name: []const u8,
        operation_started: std.Io.Clock.Timestamp,
    ) std.Io.Clock.Timestamp {
        const server_name = self.tool_aliases.serverName(name);
        self.server_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.server_mutex.unlockShared(io_mod.getIo());
        const timeout_ms = if (server_name) |owner| timeout: {
            for (self.servers.items) |server| {
                if (std.mem.eql(u8, server.config.name, owner)) break :timeout server.config.operation_timeout_ms;
            }
            break :timeout mcp_contract.default_operation_timeout_ms;
        } else mcp_contract.default_operation_timeout_ms;
        return operation_started.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(timeout_ms) });
    }

    pub fn loadStoredCredentialsForHealthSnapshot(self: *McpRuntime) !void {
        const server_handles = try self.acquireServers();
        defer self.releaseServers(server_handles);
        if (self.discovery_state.load(.acquire) != .idle) {
            return error.McpDiscoveryInProgress;
        }
        for (server_handles) |server| {
            try server_auth.loadStoredCredentials(self.alloc, server, .{
                .lifecycle_cancel_flag = server.cancellation(),
            });
        }
    }

    pub fn listServersAndTools(self: *McpRuntime, alloc: Allocator) ![]u8 {
        var snapshot = try self.snapshotHealth(alloc, operation_control.monotonicMillis(io_mod.getIo()));
        defer snapshot.deinit(alloc);
        return health.render(alloc, snapshot);
    }

    pub fn listResources(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        include_templates: bool,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !ResourceCatalogResult {
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = server_name });
        const server = self.acquireServer(server_name) orelse return error.McpServerNotFound;
        defer server.lifetime.release(io_mod.getIo());
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        try awaitFeatureServer(self, server, deadline, cancel_flag);
        return feature_operations.listResources(self.featureCatalogs(), alloc, server, deadline, include_templates, cancel_flag, access);
    }

    pub fn listPrompts(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !PromptCatalogResult {
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = server_name });
        const server = self.acquireServer(server_name) orelse return error.McpServerNotFound;
        defer server.lifetime.release(io_mod.getIo());
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        try awaitFeatureServer(self, server, deadline, cancel_flag);
        return feature_operations.listPrompts(self.featureCatalogs(), alloc, server, deadline, cancel_flag, access);
    }

    pub fn readResource(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        uri: []const u8,
        options: FeatureCallOptions,
    ) !ResourceReadResult {
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            options.access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = server_name });
        const server = self.acquireServer(server_name) orelse return error.McpServerNotFound;
        defer server.lifetime.release(io_mod.getIo());
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        try awaitFeatureServer(self, server, deadline, options.cancel_flag);
        return feature_operations.readResource(self.featureCatalogs(), alloc, server, deadline, uri, options);
    }

    pub fn getPrompt(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        name: []const u8,
        arguments_json: []const u8,
        options: FeatureCallOptions,
    ) !PromptGetResult {
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            options.access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = server_name });
        const server = self.acquireServer(server_name) orelse return error.McpServerNotFound;
        defer server.lifetime.release(io_mod.getIo());
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        try awaitFeatureServer(self, server, deadline, options.cancel_flag);
        return feature_operations.getPrompt(self.featureCatalogs(), alloc, server, deadline, name, arguments_json, options);
    }

    pub fn completePromptArgument(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        prompt_name: []const u8,
        argument: completion_feature.Argument,
        context_arguments: []const completion_feature.Argument,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !CompletionResult {
        return completeFeatureArgument(
            self,
            alloc,
            server_name,
            .{ .prompt = prompt_name },
            argument,
            context_arguments,
            cancel_flag,
            access,
        );
    }

    pub fn completeResourceTemplateArgument(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        uri_template: []const u8,
        argument: completion_feature.Argument,
        context_arguments: []const completion_feature.Argument,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !CompletionResult {
        return completeFeatureArgument(
            self,
            alloc,
            server_name,
            .{ .resource_template = uri_template },
            argument,
            context_arguments,
            cancel_flag,
            access,
        );
    }

    pub fn callFeatureForModel(
        self: *McpRuntime,
        alloc: Allocator,
        request: tool_mcp_runtime.FeatureRequest,
        options: tool_mcp_runtime.FeatureCallOptions,
    ) !tool_mcp_runtime.FeatureResult {
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            options.access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = request.server_name });
        var images: []types.ToolImage = &.{};
        errdefer types.freeToolImages(alloc, images);
        const model_output = switch (request.action) {
            .resource_list, .resource_templates => output: {
                var result = try self.listResources(
                    alloc,
                    request.server_name,
                    request.action == .resource_templates,
                    options.cancel_flag,
                    options.access,
                );
                defer result.deinit(alloc);
                break :output try renderResourceCatalogForModel(
                    alloc,
                    request.action,
                    request.server_name,
                    result,
                );
            },
            .resource_read => output: {
                var protocol_diagnostic: ?[]u8 = null;
                defer if (protocol_diagnostic) |diagnostic| alloc.free(diagnostic);
                var result = self.readResource(
                    alloc,
                    request.server_name,
                    request.identity,
                    .{
                        .cancel_flag = options.cancel_flag,
                        .input_responder = options.input_responder,
                        .access = options.access,
                        .protocol_diagnostic = &protocol_diagnostic,
                    },
                ) catch |err| {
                    if (err == error.McpProtocolError) {
                        if (protocol_diagnostic) |diagnostic| {
                            protocol_diagnostic = null;
                            break :output diagnostic;
                        }
                    }
                    return err;
                };
                defer result.deinit(alloc);
                images = try feature_result.resourceImages(alloc, result);
                break :output try renderResourceReadForModel(alloc, result);
            },
            .prompt_list => output: {
                var result = try self.listPrompts(
                    alloc,
                    request.server_name,
                    options.cancel_flag,
                    options.access,
                );
                defer result.deinit(alloc);
                break :output try renderPromptCatalogForModel(
                    alloc,
                    request.server_name,
                    result,
                );
            },
            .prompt_get => output: {
                var protocol_diagnostic: ?[]u8 = null;
                defer if (protocol_diagnostic) |diagnostic| alloc.free(diagnostic);
                var result = self.getPrompt(
                    alloc,
                    request.server_name,
                    request.identity,
                    request.arguments_json,
                    .{
                        .cancel_flag = options.cancel_flag,
                        .input_responder = options.input_responder,
                        .access = options.access,
                        .protocol_diagnostic = &protocol_diagnostic,
                    },
                ) catch |err| {
                    if (err == error.McpProtocolError) {
                        if (protocol_diagnostic) |diagnostic| {
                            protocol_diagnostic = null;
                            break :output diagnostic;
                        }
                    }
                    return err;
                };
                defer result.deinit(alloc);
                images = try feature_result.promptImages(alloc, result);
                break :output try renderPromptGetForModel(alloc, result);
            },
            .prompt_complete, .resource_complete => output: {
                const context_arguments = try alloc.alloc(
                    completion_feature.Argument,
                    request.context_arguments.len,
                );
                defer alloc.free(context_arguments);
                for (request.context_arguments, 0..) |argument, index| {
                    context_arguments[index] = .{ .name = argument.name, .value = argument.value };
                }
                const argument = completion_feature.Argument{
                    .name = request.argument_name,
                    .value = request.value,
                };
                var result = if (request.action == .prompt_complete)
                    try self.completePromptArgument(
                        alloc,
                        request.server_name,
                        request.identity,
                        argument,
                        context_arguments,
                        options.cancel_flag,
                        options.access,
                    )
                else
                    try self.completeResourceTemplateArgument(
                        alloc,
                        request.server_name,
                        request.identity,
                        argument,
                        context_arguments,
                        options.cancel_flag,
                        options.access,
                    );
                defer result.deinit(alloc);
                break :output try renderCompletionForModel(
                    alloc,
                    request.action,
                    request,
                    result,
                );
            },
        };
        errdefer alloc.free(model_output);
        if (model_output.len > options.output_limit_bytes) {
            return error.McpFeatureOutputLimitExceeded;
        }
        try operation_access.refresh();
        try operation_access.authorize(.{ .feature_server = request.server_name });
        return .{ .model_output = model_output, .images = images };
    }
};

const renderResourceCatalogForModel = feature_result.renderResourceCatalogForModel;
const renderResourceReadForModel = feature_result.renderResourceReadForModel;
const renderPromptCatalogForModel = feature_result.renderPromptCatalogForModel;
const renderPromptGetForModel = feature_result.renderPromptGetForModel;
const renderCompletionForModel = feature_result.renderCompletionForModel;

const currentAuthPartition = server_auth.currentAuthPartition;

test "operation deadline includes waiting for the connection lease" {
    const io = std.testing.io;
    var connection_lock: std.Io.RwLock = .init;
    connection_lock.lockUncancelable(io);
    defer connection_lock.unlock(io);

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(10),
    });
    try std.testing.expectError(
        error.McpRequestTimedOut,
        lockRwSharedUntil(&connection_lock, deadline, null),
    );
}

test "MRTR tool snapshots bind server schemas and both generations" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.servers.deinit(alloc);

    var server = McpServer{
        .config = .{ .name = "fixture" },
        .state = .init(.ready),
        .connection_generation = 7,
        .catalog_generation = 11,
    };
    const auth_partition = catalog_freshness.authPartition(.public, catalog_freshness.authIdentity(&.{}));
    server.tool_catalog.metadata = .{
        .key = auth_partition,
        .connection_generation = 7,
        .catalog_generation = 11,
        .fetched_at_ms = 1,
        .expires_at_ms = 2,
        .scope = .public,
        .content_digest = catalog_freshness.authIdentity(&.{}),
    };
    try server.tool_catalog.tools.append(alloc, .{
        .original_name = @constCast("echo"),
        .prefixed_name = @constCast("mcp_fixture_echo"),
        .description = @constCast("Echo"),
        .input_schema_json = @constCast("{\"type\":\"object\"}"),
        .tags = &.{},
    });
    try runtime.servers.append(alloc, &server);
    defer runtime.servers.items[0].tool_catalog.tools.deinit(alloc);

    var snapshot = ToolCallSnapshot{
        .server_name = @constCast("fixture"),
        .original_name = @constCast("echo"),
        .prefixed_name = @constCast("mcp_fixture_echo"),
        .input_schema_json = @constCast("{\"type\":\"object\"}"),
        .output_schema_json = null,
        .auth_partition = auth_partition,
        .connection_generation = 7,
        .catalog_generation = 11,
        .stdio_generation = null,
    };
    try std.testing.expect(runtime.serverForSnapshotLocked(&snapshot) != null);

    runtime.servers.items[0].catalog_generation += 1;
    try std.testing.expect(runtime.serverForSnapshotLocked(&snapshot) == null);
    runtime.servers.items[0].catalog_generation = 11;
    runtime.servers.items[0].connection_generation += 1;
    try std.testing.expect(runtime.serverForSnapshotLocked(&snapshot) == null);
    runtime.servers.items[0].connection_generation = 8;
    runtime.servers.items[0].catalog_generation = 12;
    try std.testing.expect(tool_snapshot.refreshGenerations(
        runtime.servers.items[0],
        &snapshot,
        13,
    ));
    try std.testing.expectEqual(@as(u64, 8), snapshot.connection_generation);
    try std.testing.expectEqual(@as(u64, 12), snapshot.catalog_generation);
    try std.testing.expectEqual(@as(?u64, 13), snapshot.stdio_generation);
    runtime.servers.items[0].config.name = "other-fixture";
    try std.testing.expect(runtime.serverForSnapshotLocked(&snapshot) == null);
    try std.testing.expect(!tool_snapshot.refreshGenerations(
        runtime.servers.items[0],
        &snapshot,
        14,
    ));
    runtime.servers.items[0].config.name = "fixture";
    runtime.servers.items[0].tool_catalog.tools.items[0].input_schema_json = @constCast(
        "{\"type\":\"object\",\"additionalProperties\":false}",
    );
    try std.testing.expect(!tool_snapshot.refreshGenerations(
        runtime.servers.items[0],
        &snapshot,
        14,
    ));
    try std.testing.expect(runtime.serverForSnapshotLocked(&snapshot) == null);
}

test "private catalog visibility is bound to the producing auth generation" {
    var server = McpServer{ .config = .{ .name = "fixture" } };
    server.tool_catalog.metadata = .{
        .key = catalog_freshness.authPartition(.private, catalog_freshness.authIdentity(&.{})),
        .connection_generation = 1,
        .catalog_generation = 1,
        .fetched_at_ms = 1,
        .expires_at_ms = 2,
        .scope = .private,
        .content_digest = catalog_freshness.authIdentity(&.{}),
    };
    server.tool_catalog.auth_generation = 3;
    server.auth_generation.store(3, .release);
    try std.testing.expect(tool_catalog.serverCatalogAvailable(&server));
    server.auth_generation.store(4, .release);
    try std.testing.expect(!tool_catalog.serverCatalogAvailable(&server));

    server.tool_catalog.metadata.?.scope = .public;
    try std.testing.expect(tool_catalog.serverCatalogAvailable(&server));
}

test "interactive authentication publishes only to its live auth generation" {
    var runtime = McpRuntime.init(std.testing.allocator);
    var caller_cancelled = std.atomic.Value(bool).init(false);
    var server = McpServer{
        .config = .{ .name = "fixture" },
        .auth_generation = .init(7),
    };
    const cancellation = operation_control.CancellationSources{
        .caller = &caller_cancelled,
        .runtime = &runtime.retiring,
    };

    try server_auth.validateInteractiveAuthPublication(&server, 7, cancellation);
    caller_cancelled.store(true, .release);
    try std.testing.expectError(
        error.Cancelled,
        server_auth.validateInteractiveAuthPublication(&server, 7, cancellation),
    );
    caller_cancelled.store(false, .release);
    server.auth_generation.store(8, .release);
    try std.testing.expectError(
        error.McpAuthorityChanged,
        server_auth.validateInteractiveAuthPublication(&server, 7, cancellation),
    );
    runtime.retiring.store(true, .release);
    try std.testing.expectError(
        error.Cancelled,
        server_auth.validateInteractiveAuthPublication(&server, 8, cancellation),
    );
}

test "a newer pending challenge invalidates interactive authentication publication" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    var server = McpServer{
        .config = .{ .name = "fixture" },
        .auth_generation = .init(7),
    };
    defer if (server.pending_auth_challenge) |*challenge| challenge.deinit(alloc);
    const interactive_generation = server.auth_generation.load(.acquire);
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });

    try server_auth.storePendingChallenge(
        alloc,
        &server,
        .{
            .scope = @constCast("files:write"),
            .insufficient_scope = true,
        },
        .{ .deadline = deadline },
    );

    try std.testing.expectEqual(@as(u64, 8), server.auth_generation.load(.acquire));
    try std.testing.expectError(
        error.McpAuthorityChanged,
        server_auth.validateInteractiveAuthPublication(
            &server,
            interactive_generation,
            .{ .runtime = &runtime.retiring },
        ),
    );
    try std.testing.expect(server.pending_auth_challenge != null);
    try std.testing.expectEqualStrings(
        "files:write",
        server.pending_auth_challenge.?.scope.?,
    );
}

test "pending authentication challenge overrides stored credential health" {
    const server = McpServer{
        .config = .{ .name = "fixture" },
        .auth_credentials_present = .init(true),
        .auth_challenge_present = .init(true),
    };
    try std.testing.expectEqual(
        health.AuthenticationState.required,
        serverAuthenticationState(&server),
    );
}

test "logout detachment fences auth publication until rollback" {
    var server = McpServer{
        .config = .{ .name = "fixture" },
        .auth_credentials = .{
            .endpoint = @constCast("https://mcp.example/rpc"),
            .resource = @constCast("https://mcp.example/rpc"),
            .issuer = @constCast("https://issuer.example"),
            .client_id = @constCast("client"),
            .access_token = @constCast("access"),
            .refresh_token = @constCast("refresh"),
            .scope = @constCast("tools.read"),
            .token_type = @constCast("Bearer"),
            .token_endpoint_auth_method = @constCast("none"),
            .expires_at_ms = 0,
            .authorization_endpoint = @constCast("https://issuer.example/authorize"),
            .token_endpoint = @constCast("https://issuer.example/token"),
        },
        .pending_auth_challenge = .{
            .scope = @constCast("tools.write"),
            .insufficient_scope = true,
        },
        .auth_generation = .init(7),
        .auth_credentials_present = .init(true),
        .auth_challenge_present = .init(true),
    };

    var detached = McpRuntime.detachAuthForLogout(&server);
    try std.testing.expectEqual(@as(u64, 7), server.auth_generation.load(.acquire));
    try std.testing.expect(server.auth_logout_in_progress.load(.acquire));
    try std.testing.expect(server.auth_credentials == null);
    try std.testing.expect(!server.auth_credentials_present.load(.acquire));
    try std.testing.expect(server.pending_auth_challenge == null);
    try std.testing.expect(!server.auth_challenge_present.load(.acquire));
    try std.testing.expectError(
        error.McpAuthorityChanged,
        server_auth.buildResolvedHeaders(std.testing.allocator, &server),
    );

    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    try std.testing.expect(!try server_auth.refreshSharedCredentials(
        std.testing.allocator,
        &server,
        .{ .deadline = deadline },
    ));
    try std.testing.expectError(
        error.McpAuthorityChanged,
        server_auth.storePendingChallenge(
            std.testing.allocator,
            &server,
            .{ .scope = @constCast("tools.admin") },
            .{ .deadline = deadline },
        ),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        server_auth.authorizeForChallenge(
            std.testing.allocator,
            &server,
            .{},
            .{ .deadline = deadline },
        ),
    );

    detached.restore(&server);
    try std.testing.expect(!server.auth_logout_in_progress.load(.acquire));
    try std.testing.expectEqual(@as(u64, 7), server.auth_generation.load(.acquire));
    try std.testing.expect(server.auth_credentials_present.load(.acquire));
    try std.testing.expect(server.auth_challenge_present.load(.acquire));
    server.auth_credentials = null;
    server.pending_auth_challenge = null;
}

test "private feature catalog visibility is bound to each producing auth generation" {
    var server = McpServer{ .config = .{ .name = "fixture" } };
    const metadata = catalog_freshness.SnapshotMetadata{
        .key = catalog_freshness.authPartition(.private, catalog_freshness.authIdentity(&.{})),
        .connection_generation = 1,
        .catalog_generation = 1,
        .fetched_at_ms = 1,
        .expires_at_ms = 2,
        .scope = .private,
        .content_digest = catalog_freshness.authIdentity(&.{}),
    };
    server.resource_catalog.metadata = metadata;
    server.resource_catalog.auth_generation = 3;
    server.resource_catalog.available = true;
    server.resource_template_catalog.metadata = metadata;
    server.resource_template_catalog.auth_generation = 3;
    server.resource_template_catalog.available = true;
    server.prompt_catalog.metadata = metadata;
    server.prompt_catalog.auth_generation = 3;
    server.prompt_catalog.available = true;
    server.auth_generation.store(3, .release);

    inline for ([_]feature_catalog.FeatureCatalogKind{ .resources, .resource_templates, .prompts }) |kind| {
        try std.testing.expect(feature_catalog.featureCatalogAvailable(&server, kind));
        try std.testing.expectEqual(@as(?u64, 3), feature_catalog.featureCatalogAuthWitness(&server, kind));
    }
    server.auth_generation.store(4, .release);
    inline for ([_]feature_catalog.FeatureCatalogKind{ .resources, .resource_templates, .prompts }) |kind| {
        try std.testing.expect(!feature_catalog.featureCatalogAvailable(&server, kind));
        try std.testing.expectError(
            error.McpFeatureCatalogChanged,
            feature_catalog.validateFeatureCatalogAuthWitness(&server, feature_catalog.featureCatalogAuthWitness(&server, kind)),
        );
    }

    server.resource_catalog.metadata.?.scope = .public;
    server.resource_template_catalog.metadata.?.scope = .public;
    server.prompt_catalog.metadata.?.scope = .public;
    inline for ([_]feature_catalog.FeatureCatalogKind{ .resources, .resource_templates, .prompts }) |kind| {
        try std.testing.expect(feature_catalog.featureCatalogAvailable(&server, kind));
        try std.testing.expectEqual(@as(?u64, null), feature_catalog.featureCatalogAuthWitness(&server, kind));
    }
}

test "feature catalog digests cover resource size and every feature icon field" {
    var resources_without = [_]resources_feature.Descriptor{.{
        .uri = @constCast("memory://one"),
        .name = @constCast("one"),
    }};
    var resources_with_size = resources_without;
    resources_with_size[0].size = 7;
    var resources_with_icons = resources_without;
    resources_with_icons[0].icons_json = @constCast("[{\"src\":\"memory://icon\"}]");
    try std.testing.expect(!std.mem.eql(
        u8,
        &digestResources(&resources_without),
        &digestResources(&resources_with_size),
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &digestResources(&resources_without),
        &digestResources(&resources_with_icons),
    ));

    var templates_without = [_]resources_feature.Template{.{
        .uri_template = @constCast("memory:///{id}"),
        .name = @constCast("one"),
    }};
    var templates_with_icons = templates_without;
    templates_with_icons[0].icons_json = @constCast("[{\"src\":\"memory://icon\"}]");
    try std.testing.expect(!std.mem.eql(
        u8,
        &digestResourceTemplates(&templates_without),
        &digestResourceTemplates(&templates_with_icons),
    ));

    var no_arguments: [0]prompts_feature.Argument = .{};
    var prompts_without = [_]prompts_feature.Prompt{.{
        .name = @constCast("review"),
        .arguments = &no_arguments,
    }};
    var prompts_with_icons = prompts_without;
    prompts_with_icons[0].icons_json = @constCast("[{\"src\":\"memory://icon\"}]");
    try std.testing.expect(!std.mem.eql(
        u8,
        &digestPrompts(&prompts_without),
        &digestPrompts(&prompts_with_icons),
    ));

    const first = digestResources(&resources_with_icons);
    const equivalent = digestResources(&resources_with_icons);
    try std.testing.expectEqualSlices(u8, &first, &equivalent);
}

test "operation deadline includes waiting for the shared catalog" {
    const io = std.testing.io;
    var catalog_lock: std.Io.RwLock = .init;
    catalog_lock.lockUncancelable(io);
    defer catalog_lock.unlock(io);

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(10),
    });
    try std.testing.expectError(
        error.McpRequestTimedOut,
        lockRwSharedUntil(&catalog_lock, deadline, null),
    );
}

test "per-server recovery serialization observes the operation deadline" {
    var server = McpServer{ .config = .{ .name = @constCast("fixture") } };
    server.recovery_lock.lockUncancelable(std.testing.io);
    defer server.recovery_lock.unlock(std.testing.io);

    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(10),
    });
    try std.testing.expectError(
        error.McpRequestTimedOut,
        lockMutexUntil(&server.recovery_lock, deadline, null),
    );
}

test "guarded stdio subscription startup releases catalog locks before transport commit" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", "while IFS= read -r request; do :; done" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    const dispatcher = try stdio_dispatcher.StdioDispatcher.create(
        std.testing.allocator,
        std.heap.c_allocator,
        child,
        1,
        4096,
    );
    defer dispatcher.deinit();

    var runtime = McpRuntime.init(std.testing.allocator);
    var server = McpServer{
        .config = .{
            .name = "fixture",
            .startup_timeout_ms = 2_000,
        },
        .dispatcher = dispatcher,
        .connection_generation = 1,
        .stdio_protocol = .modern,
        .tools_list_changed = true,
    };
    defer if (server.tool_subscription) |subscription| subscription.stopAndDestroy();

    const Attempt = struct {
        catalog_mutex: *std.Io.RwLock,
        server: *McpServer,
        cancel: *std.atomic.Value(bool),
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            server_subscriptions.startToolSubscriptionGuarded(
                self.catalog_mutex,
                std.testing.allocator,
                self.server,
                std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                    .clock = .awake,
                    .raw = .fromSeconds(2),
                }),
                self.cancel,
            ) catch |err| {
                self.err = err;
            };
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var attempt = Attempt{ .catalog_mutex = &runtime.catalog_mutex, .server = &server, .cancel = &cancel };
    dispatcher.write_mutex.lockUncancelable(std.testing.io);
    var write_locked = true;
    defer if (write_locked) dispatcher.write_mutex.unlock(std.testing.io);
    const thread = try std.Thread.spawn(.{}, Attempt.run, .{&attempt});
    var joined = false;
    defer if (!joined) thread.join();

    const registered_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    while (dispatcher.pendingRequestCount() == 0) {
        if (!std.Io.Clock.Timestamp.compare(
            std.Io.Clock.Timestamp.now(std.testing.io, .awake),
            .lt,
            registered_deadline,
        )) return error.McpSubscriptionNotRegistered;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }

    const lock_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(250),
    });
    try lockRwUntil(&runtime.catalog_mutex, lock_deadline, null);
    runtime.catalog_mutex.unlock(std.testing.io);
    try lockMutexUntil(&server.catalog_commit_lock, lock_deadline, null);
    server.catalog_commit_lock.unlock(std.testing.io);

    cancel.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expectEqual(error.Cancelled, attempt.err.?);
    try std.testing.expect(server.tool_subscription == null);
    try std.testing.expectEqual(@as(usize, 0), dispatcher.pendingRequestCount());
    try std.testing.expect(!dispatcher.hasNotificationSink());

    dispatcher.write_mutex.unlock(std.testing.io);
    write_locked = false;
}

test "runtime shutdown releases catalog locks before subscription cancellation write" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();
    {
        const name = try alloc.dupe(u8, "fixture");
        errdefer alloc.free(name);
        const command = try alloc.dupe(u8, "fixture");
        errdefer alloc.free(command);
        try runtime.addServer(.{
            .name = name,
            .command = command,
            .startup_timeout_ms = 2_000,
        });
    }

    const child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", "while IFS= read -r request; do :; done" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    const child_pid = child.id orelse return error.McpProcessNotStarted;
    const dispatcher = try stdio_dispatcher.StdioDispatcher.create(
        alloc,
        std.heap.c_allocator,
        child,
        1,
        4096,
    );
    const server = runtime.servers.items[0];
    server.dispatcher = dispatcher;
    server.connection_generation = 1;
    server.stdio_protocol = .modern;
    server.tools_list_changed = true;
    try server_subscriptions.startToolSubscriptionGuarded(
        &runtime.catalog_mutex,
        alloc,
        server,
        std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
            .clock = .awake,
            .raw = .fromSeconds(2),
        }),
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), dispatcher.pendingRequestCount());
    try std.testing.expect(dispatcher.hasNotificationSink());

    const Attempt = struct {
        runtime: *McpRuntime,
        finished: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            self.runtime.deinit();
            self.finished.store(true, .release);
        }
    };

    dispatcher.write_mutex.lockUncancelable(std.testing.io);
    var write_locked = true;
    var finished = std.atomic.Value(bool).init(false);
    var thread: std.Thread = undefined;
    var spawned = false;
    var joined = false;
    defer {
        if (write_locked) dispatcher.write_mutex.unlock(std.testing.io);
        if (spawned) {
            if (!joined) thread.join();
            runtime_live = false;
        }
    }
    thread = try std.Thread.spawn(.{}, Attempt.run, .{Attempt{
        .runtime = &runtime,
        .finished = &finished,
    }});
    spawned = true;

    const cancellation_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    while (dispatcher.pendingRequestCount() != 0) {
        if (!std.Io.Clock.Timestamp.compare(
            std.Io.Clock.Timestamp.now(std.testing.io, .awake),
            .lt,
            cancellation_deadline,
        )) return error.McpSubscriptionCancellationNotObserved;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(dispatcher.hasNotificationSink());
    try std.testing.expect(!finished.load(.acquire));

    const lock_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(250),
    });
    try lockRwUntil(&runtime.catalog_mutex, lock_deadline, null);
    runtime.catalog_mutex.unlock(std.testing.io);
    try lockMutexUntil(&server.catalog_commit_lock, lock_deadline, null);
    server.catalog_commit_lock.unlock(std.testing.io);

    dispatcher.write_mutex.unlock(std.testing.io);
    write_locked = false;
    thread.join();
    joined = true;
    try std.testing.expect(finished.load(.acquire));
    try expectTestProcessExited(child_pid);
}

test "recovery cancellation interrupts the catalog wait before state changes" {
    const RecoveryWait = struct {
        runtime: *McpRuntime,
        server: *McpServer,
        cancel: *std.atomic.Value(bool),
        started: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                .clock = .awake,
                .raw = .fromSeconds(2),
            });
            self.runtime.lifecycle().recoverServer(self.server, 1, deadline, self.cancel, null) catch |err| {
                self.err = err;
            };
        }
    };

    var runtime = McpRuntime.init(std.testing.allocator);
    var server = McpServer{ .config = .{ .name = "fixture" } };
    var cancel = std.atomic.Value(bool).init(false);
    runtime.catalog_mutex.lockUncancelable(std.testing.io);
    defer runtime.catalog_mutex.unlock(std.testing.io);

    var wait = RecoveryWait{
        .runtime = &runtime,
        .server = &server,
        .cancel = &cancel,
    };
    const thread = try std.Thread.spawn(.{}, RecoveryWait.run, .{&wait});
    while (!wait.started.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    io_mod.sleep(10 * std.time.ns_per_ms);
    cancel.store(true, .release);
    thread.join();

    try std.testing.expectEqual(error.Cancelled, wait.err.?);
    try std.testing.expectEqual(@as(u8, 0), server.restart_attempts);
    try std.testing.expectEqual(@as(u64, 0), server.last_recovery_generation);
    try std.testing.expect(server.dispatcher == null);
}

test "scoped stdio recovery rejects revoked authority before state changes" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .command = try alloc.dupe(u8, "/definitely/not/an/fx-mcp-fixture"),
    });
    const server = runtime.servers.items[0];
    server.state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    try parseAndStoreTools(
        alloc,
        server,
        .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}
    ,
        &used,
    );
    var captured = try runtime.snapshotAccessView(alloc, "child", "parent", .{}, true);
    defer captured.deinit(alloc);
    var revoked = try captured.clone(alloc);
    defer revoked.deinit(alloc);
    revoked.servers[0].auth_generation += 1;

    const LiveProvider = struct {
        view: *const access_policy.View,

        fn resolve(raw: *anyopaque, provider_alloc: Allocator) !tool_mcp_runtime.ResolvedLiveView {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const view = try self.view.clone(provider_alloc);
            return .{
                .authority_generation = access_policy.authorityGeneration(view),
                .view = view,
            };
        }
    };
    var provider = LiveProvider{ .view = &revoked };
    const access = tool_mcp_runtime.Access{ .scoped = .{
        .captured = &captured,
        .admission_authority_generation = access_policy.authorityGeneration(captured),
        .live = .{
            .context = @ptrCast(&provider),
            .resolve_fn = LiveProvider.resolve,
        },
    } };
    var guard = ServerAccessPrecommit{
        .authority = .{ .alloc = runtime.alloc, .runtime_generation = runtime.generation, .access = access, .target = .{ .tool = "mcp_fixture_echo" } },
        .cancel_flag = runtime.servers.items[0].cancellation(),
    };
    var precommit = guard.transport();
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });

    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.lifecycle().recoverServer(server, 1, deadline, null, &precommit),
    );
    try std.testing.expectEqual(@as(u8, 0), server.restart_attempts);
    try std.testing.expectEqual(@as(u64, 0), server.last_recovery_generation);
    try std.testing.expect(server.dispatcher == null);
}

test "failed recovery leaves its remaining generation budget reachable" {
    var runtime = McpRuntime.init(std.testing.allocator);
    var server = McpServer{ .config = .{
        .name = "fixture",
        .command = "/definitely/not/an/fx-mcp-fixture",
        .restart_limit = 2,
    } };
    defer if (server.last_error) |message| std.testing.allocator.free(message);

    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    runtime.lifecycle().recoverServer(&server, 1, deadline, null, null) catch {};

    try std.testing.expectEqual(@as(u8, 1), server.restart_attempts);
    try std.testing.expectEqual(@as(u64, 0), server.last_recovery_generation);
    try std.testing.expect(server.dispatcher == null);

    runtime.lifecycle().recoverServer(&server, 1, deadline, null, null) catch {};
    try std.testing.expectEqual(@as(u8, 2), server.restart_attempts);
    try std.testing.expectEqual(@as(u64, 0), server.last_recovery_generation);

    try std.testing.expectError(
        error.McpRestartLimitReached,
        runtime.lifecycle().recoverServer(&server, 1, deadline, null, null),
    );
    try std.testing.expectEqual(@as(u64, 1), server.last_recovery_generation);
}

fn connectServerCancellable(
    runtime: *McpRuntime,
    server: *McpServer,
    used_tool_names: *tool_names.Registry,
    cancel_requested: *std.atomic.Value(bool),
    timeout_override: ?std.Io.Duration,
) !void {
    const deadline = startupDeadline(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        server.config.startup_timeout_ms,
        timeout_override,
    );
    return server_transport.start(
        runtime.alloc,
        runtime.tool_registry,
        server,
        used_tool_names,
        .{
            .deadline = deadline,
            .cancel_flag = cancel_requested,
            .lifecycle_cancel_flag = server.cancellation(),
        },
    ) catch |err| switch (err) {
        error.McpRequestTimedOut => error.McpConnectionTimedOut,
        else => err,
    };
}

fn parseAndStoreTools(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    response: []const u8,
    used_tool_names: *tool_names.Registry,
) !void {
    return parseAndStoreToolsForProtocol(alloc, server, tool_registry, response, used_tool_names, .legacy);
}

fn parseAndStoreToolsForProtocol(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    response: []const u8,
    used_tool_names: *tool_names.Registry,
    protocol: StdioProtocol,
) !void {
    const received_at_ms = operation_control.monotonicMillis(io_mod.getIo());
    var page = tools_feature.parseListPage(
        alloc,
        response,
        featureProtocol(protocol),
        .{},
    ) catch |err| {
        server.setFailed(alloc, @errorName(err));
        return err;
    };
    defer page.deinit(alloc);
    var builder = tools_feature.CatalogBuilder.init(alloc, featureProtocol(protocol));
    defer builder.deinit(alloc);
    try builder.appendPage(alloc, &page, received_at_ms, .{});
    var catalog = try builder.finish(alloc);
    defer catalog.deinit(alloc);
    try tool_catalog.install(
        alloc,
        server,
        tool_registry,
        catalog,
        used_tool_names,
        protocol,
        null,
    );
}

const operationDeadline = server_connection.operationDeadline;

fn handleLegacyCompletionNotification(
    raw_context: *anyopaque,
    source: tool_subscription.NotificationSource,
    value: std.json.Value,
) void {
    const runtime: *McpRuntime = @ptrCast(@alignCast(raw_context));
    routeLegacyCompletionNotification(runtime, source, value);
}

fn routeLegacyCompletionNotification(
    runtime: *McpRuntime,
    source: tool_subscription.NotificationSource,
    value: std.json.Value,
) void {
    const notification = elicitation.classifyLegacyUrlCompletionNotification(value, .{}) orelse return;
    const sink = runtime.completions.sink;
    const publication = publication: {
        runtime.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer runtime.catalog_mutex.unlockShared(io_mod.getIo());
        runtime.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer runtime.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        const completion = LegacyUrlWireCompletionIdentity{
            .server_name = source.server_name,
            .elicitation_id = notification.elicitation_id,
            .runtime_generation = runtime.completions.runtime_generation,
            .connection_generation = source.connection_generation,
            .client_generation = source.client_generation,
            .auth_generation = source.auth_generation,
        };
        switch (runtime.legacyCompletionSourceStateLocked(
            source.server_name,
            runtime.completions.runtime_generation,
            source.connection_generation,
            source.client_generation,
            source.auth_generation,
        )) {
            .stale => break :publication null,
            .logout_fenced => {
                runtime.completions.journalEarlyLegacyUrlCompletionLocked(completion, true);
                break :publication null;
            },
            .current => {},
        }
        const recorded = runtime.completions.recordLegacyUrlCompletionFromWireLocked(completion);
        if (recorded) runtime.completions.markWireLegacyUrlCompletionHandledLocked(completion);
        const consumer = sink orelse {
            if (!recorded) runtime.completions.journalEarlyLegacyUrlCompletionLocked(completion, false);
            break :publication null;
        };
        break :publication switch (consumer.consume(consumer.context, .{
            .server_name = completion.server_name,
            .elicitation_id = completion.elicitation_id,
            .runtime_generation = completion.runtime_generation,
            .connection_generation = completion.connection_generation,
            .client_generation = completion.client_generation,
            .auth_generation = completion.auth_generation,
        })) {
            .missing => missing: {
                if (!recorded) runtime.completions.journalEarlyLegacyUrlCompletionLocked(completion, false);
                break :missing null;
            },
            .consumed => |id| consumed: {
                if (!recorded) runtime.completions.markWireLegacyUrlCompletionHandledLocked(completion);
                break :consumed id;
            },
        };
    };
    if (publication) |id| sink.?.publish(sink.?.context, id);
}

const authorizePendingChallengeIfAutomated = server_auth.authorizePendingChallengeIfAutomated;

const CatalogAuthWitness = tool_catalog.CatalogAuthWitness;
const catalogAuthWitness = tool_catalog.catalogAuthWitness;
const validateCatalogAuthWitness = tool_catalog.validateCatalogAuthWitness;
const validateCatalogAuthWitnesses = tool_catalog.validateCatalogAuthWitnesses;

fn checkAllocateToolNameCollisionAllocFailures(alloc: Allocator) !void {
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    const existing = try used.name(alloc, .{}, "a/b", "c");
    defer alloc.free(existing);

    const name = try used.name(alloc, .{}, "a b", "c");
    defer alloc.free(name);

    try std.testing.expectEqualStrings("mcp_a_b_c_2", name);
}

test "legacy URL waiter records every matching completion and ignores stale identities" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    const ids = [_][]const u8{ "one", "two" };
    var completed = [_]bool{ false, false };
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .connection_generation = 1,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 4,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try runtime.completions.registerLegacyUrlWaiter(&waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&waiter);

    runtime.completions.recordLegacyUrlCompletion(.{
        .server_name = "server",
        .elicitation_id = "one",
        .connection_generation = 9,
        .client_generation = 2,
        .catalog_generation = 3,
        .auth_generation = 5,
    });
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &completed);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.pending,
        waiter.signal.status.load(.acquire),
    );

    runtime.completions.recordLegacyUrlCompletion(.{
        .server_name = "server",
        .elicitation_id = "one",
        .connection_generation = 1,
        .client_generation = 2,
        .catalog_generation = 3,
        .auth_generation = 5,
    });
    runtime.completions.recordLegacyUrlCompletion(.{
        .server_name = "server",
        .elicitation_id = "one",
        .connection_generation = 1,
        .client_generation = 2,
        .catalog_generation = 3,
        .auth_generation = 5,
    });
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &completed);
    try std.testing.expect(!waiter.signal.wake.load(.acquire));

    runtime.completions.recordLegacyUrlCompletionFromWire(.{
        .server_name = "server",
        .elicitation_id = "two",
        .connection_generation = 1,
        .client_generation = 2,
        .auth_generation = 5,
    });
    try std.testing.expectEqualSlices(bool, &.{ true, true }, &completed);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.completed,
        waiter.signal.status.load(.acquire),
    );
    try std.testing.expect(waiter.signal.wake.load(.acquire));
}

test "legacy completion routing keeps recovered connection identities distinct" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.appendOwnedServer(.{
        .config = .{ .name = try alloc.dupe(u8, "server") },
        .state = .init(.ready),
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = .init(5),
    });
    const ids = [_][]const u8{"same-id"};
    var completed = [_]bool{false};
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 4,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try runtime.completions.registerLegacyUrlWaiter(&waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&waiter);
    const Capture = struct {
        accepted: usize = 0,
        consumed: usize = 0,
        published: usize = 0,

        fn accept(
            raw: *anyopaque,
            _: tool_mcp_runtime.InputOrigin,
            _: []const u8,
        ) tool_mcp_runtime.LegacyUrlAcceptTransition {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.accepted += 1;
            return .awaiting_completion;
        }

        fn consume(
            raw: *anyopaque,
            _: tool_mcp_runtime.LegacyUrlCompletion,
        ) tool_mcp_runtime.LegacyUrlConsumeTransition {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.consumed += 1;
            return .{ .consumed = @constCast("publication") };
        }

        fn publish(raw: *anyopaque, id: []u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(std.mem.eql(u8, id, "publication"));
            self.published += 1;
        }
    };
    var capture = Capture{};
    runtime.setLegacyUrlCompletionSink(.{
        .context = @ptrCast(&capture),
        .accept = Capture.accept,
        .consume = Capture.consume,
        .publish = Capture.publish,
    });
    waiter.binding.runtime_generation = runtime.completions.runtime_generation;
    const stale_origin = tool_mcp_runtime.InputOrigin{
        .wire = .legacy_mcp_2025_11,
        .server_name = "server",
        .operation = .{ .tools_call = "authorize" },
        .runtime_generation = runtime.completions.runtime_generation,
        .connection_generation = 1,
        .client_generation = 1,
        .catalog_generation = 3,
        .request_generation = 4,
        .auth_generation = 5,
        .deadline_ms = std.math.maxInt(i64),
    };
    try std.testing.expect(runtime.acceptLegacyUrlCompletion(
        stale_origin,
        "same-id",
        runtime.completions.sink.?,
    ) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.accepted);
    var current_origin = stale_origin;
    current_origin.connection_generation = 2;
    current_origin.client_generation = 2;
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlAcceptStatus.awaiting_completion,
        runtime.acceptLegacyUrlCompletion(
            current_origin,
            "same-id",
            runtime.completions.sink.?,
        ).?,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.accepted);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"same-id\"}}",
        .{},
    );
    defer parsed.deinit();
    routeLegacyCompletionNotification(&runtime, .{
        .server_name = "server",
        .connection_generation = 1,
        .client_generation = 1,
        .auth_generation = 5,
    }, parsed.value);
    try std.testing.expect(!completed[0]);
    try std.testing.expectEqual(@as(usize, 0), capture.consumed);
    try std.testing.expectEqual(@as(usize, 0), capture.published);

    routeLegacyCompletionNotification(&runtime, .{
        .server_name = "server",
        .connection_generation = 2,
        .client_generation = 2,
        .auth_generation = 5,
    }, parsed.value);
    try std.testing.expect(completed[0]);
    try std.testing.expectEqual(@as(usize, 1), capture.consumed);
    try std.testing.expectEqual(@as(usize, 1), capture.published);
}

test "legacy URL completions require an established unique candidate before replay" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.appendOwnedServer(.{
        .config = .{ .name = try alloc.dupe(u8, "server") },
        .state = .init(.ready),
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = .init(5),
    });
    const Capture = struct {
        alloc: Allocator,
        available: bool = false,
        consumed: usize = 0,
        published: usize = 0,

        fn accept(
            _: *anyopaque,
            _: tool_mcp_runtime.InputOrigin,
            _: []const u8,
        ) tool_mcp_runtime.LegacyUrlAcceptTransition {
            return .missing;
        }

        fn consume(
            raw: *anyopaque,
            _: tool_mcp_runtime.LegacyUrlCompletion,
        ) tool_mcp_runtime.LegacyUrlConsumeTransition {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!self.available) return .missing;
            self.consumed += 1;
            return .{ .consumed = self.alloc.dupe(u8, "acp-early") catch null };
        }

        fn publish(raw: *anyopaque, id: []u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.alloc.free(id);
            self.published += 1;
        }
    };
    var capture = Capture{ .alloc = alloc };
    runtime.setLegacyUrlCompletionSink(.{
        .context = @ptrCast(&capture),
        .accept = Capture.accept,
        .consume = Capture.consume,
        .publish = Capture.publish,
    });
    const source = tool_subscription.NotificationSource{
        .server_name = "server",
        .connection_generation = 2,
        .client_generation = 2,
        .auth_generation = 5,
    };
    var direct = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"direct\"}}",
        .{},
    );
    defer direct.deinit();

    // A valid-looking completion is still unknown until the corresponding
    // request or URL-required response establishes its id.
    routeLegacyCompletionNotification(&runtime, source, direct.value);
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.early_legacy_url_completions.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.legacy_url_completion_candidates.items.len);

    // HTTP response and notification streams can race. A bounded operation
    // window retains the frame only until the exact response candidate arrives.
    const window_generation = try runtime.beginLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
    );
    defer runtime.completions.endLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
        window_generation,
    );
    routeLegacyCompletionNotification(&runtime, source, direct.value);
    try std.testing.expectEqual(@as(usize, 1), runtime.completions.early_legacy_url_completions.items.len);
    const direct_ids = [_][]const u8{"direct"};
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        runtime.completions.runtime_generation,
        window_generation,
        &direct_ids,
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.early_legacy_url_completions.items.len);
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.early,
        runtime.completions.legacy_url_completion_candidates.items[0].status,
    );

    capture.available = true;
    runtime.reconcileLegacyUrlCompletion(.{
        .wire = .legacy_mcp_2025_11,
        .server_name = "server",
        .operation = .{ .tools_call = "authorize" },
        .runtime_generation = runtime.completions.runtime_generation,
        .connection_generation = 2,
        .client_generation = 2,
        .catalog_generation = 3,
        .request_generation = 1,
        .auth_generation = 5,
        .deadline_ms = std.math.maxInt(i64),
    }, "direct", runtime.completions.sink.?);
    try std.testing.expectEqual(@as(usize, 1), capture.consumed);
    try std.testing.expectEqual(@as(usize, 1), capture.published);
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.handled,
        runtime.completions.legacy_url_completion_candidates.items[0].status,
    );

    // Late duplicates cannot create replayable state, and the server-context
    // uniqueness rule prevents the id from being issued again.
    routeLegacyCompletionNotification(&runtime, source, direct.value);
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.early_legacy_url_completions.items.len);
    try std.testing.expectError(
        error.McpDuplicateElicitationId,
        runtime.registerLegacyUrlCompletionCandidates(
            source,
            runtime.completions.runtime_generation,
            window_generation,
            &direct_ids,
        ),
    );

    capture.available = false;
    var expired = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"expired\"}}",
        .{},
    );
    defer expired.deinit();
    routeLegacyCompletionNotification(&runtime, source, expired.value);
    try std.testing.expectEqual(@as(usize, 1), runtime.completions.early_legacy_url_completions.items.len);
    runtime.completions.early_legacy_url_completions.items[0].deadline_ms = operation_control.awakeMillis(io_mod.getIo()) - 1;
    const expired_ids = [_][]const u8{"expired"};
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        runtime.completions.runtime_generation,
        window_generation,
        &expired_ids,
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.early_legacy_url_completions.items.len);
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.issued,
        runtime.completions.legacy_url_completion_candidates.items[1].status,
    );

    var url_required = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"url-required\"}}",
        .{},
    );
    defer url_required.deinit();
    routeLegacyCompletionNotification(&runtime, source, url_required.value);
    try std.testing.expectEqual(@as(usize, 1), runtime.completions.early_legacy_url_completions.items.len);

    const ids = [_][]const u8{"url-required"};
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        runtime.completions.runtime_generation,
        window_generation,
        &ids,
    );
    var completed = [_]bool{false};
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .runtime_generation = runtime.completions.runtime_generation,
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 1,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try runtime.registerCurrentLegacyUrlWaiter(&waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&waiter);
    try std.testing.expect(completed[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.completed,
        waiter.signal.status.load(.acquire),
    );
    try std.testing.expect(!runtime.completions.earlyLegacyUrlCompletionRecordedLocked(.{
        .wire = .legacy_mcp_2025_11,
        .server_name = "server",
        .operation = .{ .tools_call = "authorize" },
        .runtime_generation = runtime.completions.runtime_generation,
        .connection_generation = 2,
        .client_generation = 2,
        .catalog_generation = 3,
        .request_generation = 1,
        .auth_generation = 5,
        .deadline_ms = std.math.maxInt(i64),
    }, "url-required"));

    // Candidate tombstones are never evicted by transient early-frame pressure.
    var id_buffer: [64]u8 = undefined;
    var candidate_index: usize = runtime.completions.legacy_url_completion_candidates.items.len;
    while (candidate_index < max_legacy_url_completion_candidates) : (candidate_index += 1) {
        const id = try std.fmt.bufPrint(&id_buffer, "candidate-{d}", .{candidate_index});
        const candidate_ids = [_][]const u8{id};
        try runtime.registerLegacyUrlCompletionCandidates(
            source,
            runtime.completions.runtime_generation,
            window_generation,
            &candidate_ids,
        );
    }
    var unknown_index: usize = 0;
    while (unknown_index <= max_early_legacy_url_completions_per_window) : (unknown_index += 1) {
        const id = try std.fmt.bufPrint(&id_buffer, "unknown-{d}", .{unknown_index});
        var frame = std.Io.Writer.Allocating.init(alloc);
        defer frame.deinit();
        try frame.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":");
        try std.json.Stringify.value(id, .{}, &frame.writer);
        try frame.writer.writeAll("}}");
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.writer.buffered(), .{});
        defer parsed.deinit();
        routeLegacyCompletionNotification(&runtime, source, parsed.value);
    }
    try std.testing.expectEqual(
        max_early_legacy_url_completions_per_window,
        runtime.completions.early_legacy_url_completions.items.len,
    );
    try std.testing.expectEqual(
        max_legacy_url_completion_candidates,
        runtime.completions.legacy_url_completion_candidates.items.len,
    );
    try std.testing.expectError(
        error.McpDuplicateElicitationId,
        runtime.registerLegacyUrlCompletionCandidates(
            source,
            runtime.completions.runtime_generation,
            window_generation,
            &direct_ids,
        ),
    );
}

test "legacy URL provisional completions cannot cross concurrent operation windows" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.appendOwnedServer(.{
        .config = .{ .name = try alloc.dupe(u8, "server") },
        .state = .init(.ready),
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = .init(5),
    });
    const source = tool_subscription.NotificationSource{
        .server_name = "server",
        .connection_generation = 2,
        .client_generation = 2,
        .auth_generation = 5,
    };
    const first_window = try runtime.beginLegacyUrlCompletionWindow(source, 0);
    var first_active = true;
    defer if (first_active) runtime.completions.endLegacyUrlCompletionWindow(source, 0, first_window);

    var completion = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"cross-window\"}}",
        .{},
    );
    defer completion.deinit();
    routeLegacyCompletionNotification(&runtime, source, completion.value);
    try std.testing.expectEqual(@as(usize, 1), runtime.completions.early_legacy_url_completions.items.len);
    var provisional_buffer: [64]u8 = undefined;
    var provisional_index: usize = 1;
    while (provisional_index < max_early_legacy_url_completions_per_window) : (provisional_index += 1) {
        const id = try std.fmt.bufPrint(&provisional_buffer, "first-window-{d}", .{provisional_index});
        var frame = std.Io.Writer.Allocating.init(alloc);
        defer frame.deinit();
        try frame.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":");
        try std.json.Stringify.value(id, .{}, &frame.writer);
        try frame.writer.writeAll("}}");
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame.writer.buffered(), .{});
        defer parsed.deinit();
        routeLegacyCompletionNotification(&runtime, source, parsed.value);
    }
    try std.testing.expectEqual(
        max_early_legacy_url_completions_per_window,
        runtime.completions.early_legacy_url_completions.items.len,
    );

    const second_window = try runtime.beginLegacyUrlCompletionWindow(source, 0);
    var second_active = true;
    defer if (second_active) runtime.completions.endLegacyUrlCompletionWindow(source, 0, second_window);
    const ids = [_][]const u8{"cross-window"};
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        0,
        second_window,
        &ids,
    );
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.issued,
        runtime.completions.legacy_url_completion_candidates.items[0].status,
    );
    try std.testing.expectEqual(
        max_early_legacy_url_completions_per_window,
        runtime.completions.early_legacy_url_completions.items.len,
    );

    var second_completion = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"second-window\"}}",
        .{},
    );
    defer second_completion.deinit();
    routeLegacyCompletionNotification(&runtime, source, second_completion.value);
    try std.testing.expectEqual(
        max_early_legacy_url_completions_per_window + 1,
        runtime.completions.early_legacy_url_completions.items.len,
    );
    const second_ids = [_][]const u8{"second-window"};
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        0,
        second_window,
        &second_ids,
    );
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.early,
        runtime.completions.legacy_url_completion_candidates.items[1].status,
    );
    try std.testing.expectEqual(
        max_early_legacy_url_completions_per_window,
        runtime.completions.early_legacy_url_completions.items.len,
    );

    runtime.completions.endLegacyUrlCompletionWindow(source, 0, second_window);
    second_active = false;
    try std.testing.expectEqual(
        max_early_legacy_url_completions_per_window,
        runtime.completions.early_legacy_url_completions.items.len,
    );
    runtime.completions.endLegacyUrlCompletionWindow(source, 0, first_window);
    first_active = false;
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.early_legacy_url_completions.items.len);
    runtime.completions.cancelLegacyUrlWaitersForServer("server", 2);
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.legacy_url_completion_candidates.items.len);
}

test "cancelled legacy URL waiter cannot be revived by a matching wire completion" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    const ids = [_][]const u8{"same-id"};
    var completed = [_]bool{false};
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .connection_generation = 2,
            .client_generation = 20,
            .catalog_generation = 3,
            .request_generation = 4,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try runtime.completions.registerLegacyUrlWaiter(&waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&waiter);
    waiter.signal.status.store(.cancelled, .release);

    runtime.completions.recordLegacyUrlCompletionFromWire(.{
        .server_name = "server",
        .elicitation_id = "same-id",
        .connection_generation = 2,
        .client_generation = 20,
        .auth_generation = 5,
    });

    try std.testing.expect(!completed[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.cancelled,
        waiter.signal.status.load(.acquire),
    );
    try std.testing.expect(!runtime.completions.legacyUrlCompletionRecorded(.{
        .wire = .legacy_mcp_2025_11,
        .server_name = "server",
        .operation = .{ .tools_call = "authorize" },
        .connection_generation = 2,
        .client_generation = 20,
        .catalog_generation = 3,
        .request_generation = 4,
        .auth_generation = 5,
        .deadline_ms = std.math.maxInt(i64),
    }, "same-id"));
}

test "late completion after cancellation cannot satisfy same-id reuse" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.appendOwnedServer(.{
        .config = .{ .name = try alloc.dupe(u8, "server") },
        .state = .init(.ready),
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = .init(5),
    });
    const source = tool_subscription.NotificationSource{
        .server_name = "server",
        .connection_generation = 2,
        .client_generation = 2,
        .auth_generation = 5,
    };
    const window = try runtime.beginLegacyUrlCompletionWindow(source, 0);
    var window_active = true;
    defer if (window_active) runtime.completions.endLegacyUrlCompletionWindow(source, 0, window);
    const ids = [_][]const u8{"cancelled-id"};
    try runtime.registerLegacyUrlCompletionCandidates(source, 0, window, &ids);
    var completed = [_]bool{false};
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 1,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try runtime.registerCurrentLegacyUrlWaiter(&waiter);
    waiter.signal.status.store(.cancelled, .release);
    runtime.completions.unregisterLegacyUrlWaiter(&waiter);

    var late = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"cancelled-id\"}}",
        .{},
    );
    defer late.deinit();
    routeLegacyCompletionNotification(&runtime, source, late.value);
    try std.testing.expect(!completed[0]);
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.early,
        runtime.completions.legacy_url_completion_candidates.items[0].status,
    );

    runtime.completions.endLegacyUrlCompletionWindow(source, 0, window);
    window_active = false;
    const next_window = try runtime.beginLegacyUrlCompletionWindow(source, 0);
    defer runtime.completions.endLegacyUrlCompletionWindow(source, 0, next_window);
    try std.testing.expectError(
        error.McpDuplicateElicitationId,
        runtime.registerLegacyUrlCompletionCandidates(source, 0, next_window, &ids),
    );
}

test "legacy URL waiter registration is serialized with auth invalidation" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.appendOwnedServer(.{
        .config = .{ .name = try alloc.dupe(u8, "server") },
        .state = .init(.ready),
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = .init(5),
    });
    const ids = [_][]const u8{"same-id"};
    var completed = [_]bool{false};
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 4,
            .auth_generation = 4,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try std.testing.expectError(
        error.Cancelled,
        runtime.registerCurrentLegacyUrlWaiter(&waiter),
    );

    waiter.binding.auth_generation = 5;
    try runtime.registerCurrentLegacyUrlWaiter(&waiter);
    server_auth.advanceAuthGeneration(runtime.servers.items[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.cancelled,
        waiter.signal.status.load(.acquire),
    );
    try std.testing.expect(waiter.signal.wake.load(.acquire));
    runtime.completions.unregisterLegacyUrlWaiter(&waiter);
}

test "logout rollback preserves active legacy completion authority" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.appendOwnedServer(.{
        .config = .{ .name = try alloc.dupe(u8, "server") },
        .state = .init(.ready),
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = .init(5),
    });
    const ids = [_][]const u8{"rollback-id"};
    const source = tool_subscription.NotificationSource{
        .server_name = "server",
        .connection_generation = 2,
        .client_generation = 2,
        .auth_generation = 5,
    };
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        runtime.completions.runtime_generation,
        null,
        &ids,
    );
    var completed = [_]bool{false};
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .runtime_generation = runtime.completions.runtime_generation,
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 4,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try runtime.registerCurrentLegacyUrlWaiter(&waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&waiter);

    var detached = McpRuntime.detachAuthForLogout(runtime.servers.items[0]);
    defer detached.deinit(alloc);
    try std.testing.expectEqual(
        @as(u64, 5),
        runtime.servers.items[0].auth_generation.load(.acquire),
    );
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.pending,
        waiter.signal.status.load(.acquire),
    );
    var notification = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"rollback-id\"}}",
        .{},
    );
    defer notification.deinit();
    routeLegacyCompletionNotification(&runtime, source, notification.value);
    try std.testing.expect(!completed[0]);
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.logout_fenced,
        runtime.completions.legacy_url_completion_candidates.items[0].status,
    );

    server_auth.restoreAuthAfterLogout(runtime.servers.items[0], &detached);
    runtime.replayLogoutFencedLegacyUrlCompletions(runtime.servers.items[0].config.name);
    try std.testing.expect(completed[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.completed,
        waiter.signal.status.load(.acquire),
    );

    const committed_ids = [_][]const u8{"committed-id"};
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        runtime.completions.runtime_generation,
        null,
        &committed_ids,
    );
    var committed = [_]bool{false};
    var committed_waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .runtime_generation = runtime.completions.runtime_generation,
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 6,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &committed_ids,
        .completed = &committed,
    };
    try runtime.registerCurrentLegacyUrlWaiter(&committed_waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&committed_waiter);
    var committed_detached = McpRuntime.detachAuthForLogout(runtime.servers.items[0]);
    defer committed_detached.deinit(alloc);
    var committed_notification = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"committed-id\"}}",
        .{},
    );
    defer committed_notification.deinit();
    routeLegacyCompletionNotification(&runtime, source, committed_notification.value);
    try std.testing.expect(!committed[0]);
    server_auth.advanceAuthGeneration(runtime.servers.items[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.cancelled,
        committed_waiter.signal.status.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        runtime.completions.legacy_url_completion_candidates.items.len,
    );
    runtime.servers.items[0].auth_logout_in_progress.store(false, .release);
}

test "logout rollback preserves early legacy completion authority" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.appendOwnedServer(.{
        .config = .{ .name = try alloc.dupe(u8, "server") },
        .state = .init(.ready),
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = .init(5),
    });
    const source = tool_subscription.NotificationSource{
        .server_name = "server",
        .connection_generation = 2,
        .client_generation = 2,
        .auth_generation = 5,
    };
    const ids = [_][]const u8{"early-rollback-id"};
    const window = try runtime.beginLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
    );
    var window_active = true;
    defer if (window_active) runtime.completions.endLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
        window,
    );

    var detached = McpRuntime.detachAuthForLogout(runtime.servers.items[0]);
    defer detached.deinit(alloc);
    var notification = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"early-rollback-id\"}}",
        .{},
    );
    defer notification.deinit();
    routeLegacyCompletionNotification(&runtime, source, notification.value);
    try std.testing.expectEqual(
        @as(usize, 1),
        runtime.completions.early_legacy_url_completions.items.len,
    );
    try std.testing.expect(runtime.completions.early_legacy_url_completions.items[0].logout_fenced);
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        runtime.completions.runtime_generation,
        window,
        &ids,
    );
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.logout_fenced,
        runtime.completions.legacy_url_completion_candidates.items[0].status,
    );

    var completed = [_]bool{false};
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .runtime_generation = runtime.completions.runtime_generation,
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 4,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try runtime.registerCurrentLegacyUrlWaiter(&waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&waiter);
    try std.testing.expect(!completed[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.pending,
        waiter.signal.status.load(.acquire),
    );

    server_auth.restoreAuthAfterLogout(runtime.servers.items[0], &detached);
    runtime.replayLogoutFencedLegacyUrlCompletions(runtime.servers.items[0].config.name);
    try std.testing.expect(completed[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.completed,
        waiter.signal.status.load(.acquire),
    );
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.handled,
        runtime.completions.legacy_url_completion_candidates.items[0].status,
    );
    runtime.completions.endLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
        window,
    );
    window_active = false;

    const pre_fence_ids = [_][]const u8{"pre-fence-rollback-id"};
    const pre_fence_window = try runtime.beginLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
    );
    var pre_fence_window_active = true;
    defer if (pre_fence_window_active) runtime.completions.endLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
        pre_fence_window,
    );
    var pre_fence_notification = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"pre-fence-rollback-id\"}}",
        .{},
    );
    defer pre_fence_notification.deinit();
    routeLegacyCompletionNotification(&runtime, source, pre_fence_notification.value);
    try std.testing.expectEqual(
        @as(usize, 1),
        runtime.completions.early_legacy_url_completions.items.len,
    );
    try std.testing.expect(!runtime.completions.early_legacy_url_completions.items[0].logout_fenced);

    var pre_fence_detached = McpRuntime.detachAuthForLogout(runtime.servers.items[0]);
    defer pre_fence_detached.deinit(alloc);
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        runtime.completions.runtime_generation,
        pre_fence_window,
        &pre_fence_ids,
    );
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.early,
        runtime.completions.legacy_url_completion_candidates.items[1].status,
    );
    var pre_fence_completed = [_]bool{false};
    var pre_fence_waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .runtime_generation = runtime.completions.runtime_generation,
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 5,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &pre_fence_ids,
        .completed = &pre_fence_completed,
    };
    try runtime.registerCurrentLegacyUrlWaiter(&pre_fence_waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&pre_fence_waiter);
    try std.testing.expectEqual(
        LegacyUrlCompletionCandidate.Status.logout_fenced,
        runtime.completions.legacy_url_completion_candidates.items[1].status,
    );
    try std.testing.expect(!pre_fence_completed[0]);
    server_auth.restoreAuthAfterLogout(runtime.servers.items[0], &pre_fence_detached);
    runtime.replayLogoutFencedLegacyUrlCompletions(runtime.servers.items[0].config.name);
    try std.testing.expect(pre_fence_completed[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.completed,
        pre_fence_waiter.signal.status.load(.acquire),
    );
    runtime.completions.endLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
        pre_fence_window,
    );
    pre_fence_window_active = false;

    const committed_ids = [_][]const u8{"early-committed-id"};
    const committed_window = try runtime.beginLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
    );
    defer runtime.completions.endLegacyUrlCompletionWindow(
        source,
        runtime.completions.runtime_generation,
        committed_window,
    );
    var committed_detached = McpRuntime.detachAuthForLogout(runtime.servers.items[0]);
    defer committed_detached.deinit(alloc);
    var committed_notification = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"early-committed-id\"}}",
        .{},
    );
    defer committed_notification.deinit();
    routeLegacyCompletionNotification(&runtime, source, committed_notification.value);
    try runtime.registerLegacyUrlCompletionCandidates(
        source,
        runtime.completions.runtime_generation,
        committed_window,
        &committed_ids,
    );
    var committed = [_]bool{false};
    var committed_waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .runtime_generation = runtime.completions.runtime_generation,
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 6,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &committed_ids,
        .completed = &committed,
    };
    try runtime.registerCurrentLegacyUrlWaiter(&committed_waiter);
    defer runtime.completions.unregisterLegacyUrlWaiter(&committed_waiter);
    try std.testing.expect(!committed[0]);
    server_auth.advanceAuthGeneration(runtime.servers.items[0]);
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.cancelled,
        committed_waiter.signal.status.load(.acquire),
    );
    try std.testing.expect(!committed[0]);
    try std.testing.expectEqual(
        @as(usize, 0),
        runtime.completions.legacy_url_completion_candidates.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        runtime.completions.early_legacy_url_completions.items.len,
    );
    runtime.servers.items[0].auth_logout_in_progress.store(false, .release);
}

test "logout releases completion arbitration before draining active legacy HTTP" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    const client = try alloc.create(legacy_streamable_http.Client);
    client.* = .{
        .owner_allocator = alloc,
        .url = "",
        .static_headers = &.{},
        .version = .v2025_11_25,
        .session_id = null,
    };
    try runtime.appendOwnedServer(.{
        .config = .{ .name = try alloc.dupe(u8, "server") },
        .legacy_http = client,
        .state = .init(.ready),
        .connection_generation = 2,
        .catalog_generation = 3,
        .auth_generation = .init(5),
    });
    try std.testing.expect(client.acquireUse());
    var lease_active = true;

    const ids = [_][]const u8{"same-id"};
    var completed = [_]bool{false};
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .connection_generation = 2,
            .client_generation = 2,
            .catalog_generation = 3,
            .request_generation = 4,
            .auth_generation = 5,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try runtime.registerCurrentLegacyUrlWaiter(&waiter);
    var waiter_registered = true;

    const Logout = struct {
        runtime: *McpRuntime,
        server: *McpServer,
        detached: *std.atomic.Value(bool),
        finished: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            var transport = server_auth.detachTransportForLogout(&self.runtime.completions, self.server);
            self.detached.store(true, .release);
            transport.deinit(false);
            self.finished.store(true, .release);
        }
    };
    var detached = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Logout.run, .{Logout{
        .runtime = &runtime,
        .server = runtime.servers.items[0],
        .detached = &detached,
        .finished = &finished,
    }});
    var joined = false;
    defer {
        if (waiter_registered) runtime.completions.unregisterLegacyUrlWaiter(&waiter);
        if (lease_active) client.releaseUse();
        if (!joined) thread.join();
    }

    const detach_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    while (!detached.load(.acquire)) {
        if (!std.Io.Clock.Timestamp.compare(
            std.Io.Clock.Timestamp.now(std.testing.io, .awake),
            .lt,
            detach_deadline,
        )) return error.McpLogoutTransportDetachTimedOut;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(!finished.load(.acquire));
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.cancelled,
        waiter.signal.status.load(.acquire),
    );

    const Capture = struct {
        accepted: usize = 0,

        fn accept(
            raw: *anyopaque,
            _: tool_mcp_runtime.InputOrigin,
            _: []const u8,
        ) tool_mcp_runtime.LegacyUrlAcceptTransition {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.accepted += 1;
            return .awaiting_completion;
        }

        fn consume(
            _: *anyopaque,
            _: tool_mcp_runtime.LegacyUrlCompletion,
        ) tool_mcp_runtime.LegacyUrlConsumeTransition {
            return .missing;
        }

        fn publish(_: *anyopaque, _: []u8) void {}
    };
    var capture = Capture{};
    try std.testing.expect(runtime.acceptLegacyUrlCompletion(.{
        .wire = .legacy_mcp_2025_11,
        .server_name = "server",
        .operation = .{ .tools_call = "authorize" },
        .connection_generation = 2,
        .client_generation = 2,
        .catalog_generation = 3,
        .request_generation = 4,
        .auth_generation = 5,
        .deadline_ms = std.math.maxInt(i64),
    }, "acp-id", .{
        .context = @ptrCast(&capture),
        .accept = Capture.accept,
        .consume = Capture.consume,
        .publish = Capture.publish,
    }) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.accepted);

    runtime.completions.unregisterLegacyUrlWaiter(&waiter);
    waiter_registered = false;
    client.releaseUse();
    lease_active = false;
    thread.join();
    joined = true;
    try std.testing.expect(finished.load(.acquire));
}

test "legacy completion passthrough snapshots a recovery candidate" {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var server = McpServer{
        .config = .{ .name = "server" },
        .connection_generation = 7,
        .catalog_generation = 8,
        .auth_generation = .init(9),
    };
    runtime.bindServer(&server);
    const passthrough = try server_subscriptions.legacyCompletionPassthrough(&server, 70);
    server.connection_generation = 17;
    server.catalog_generation = 18;
    server.auth_generation.store(19, .release);

    try std.testing.expect(passthrough.context == @as(*anyopaque, @ptrCast(&runtime)));
    try std.testing.expectEqual(@as(u64, 7), passthrough.source.connection_generation);
    try std.testing.expectEqual(@as(u64, 70), passthrough.source.client_generation);
    try std.testing.expectEqual(@as(u64, 9), passthrough.source.auth_generation);
}

test "legacy direct elicitation origin preserves its client generation" {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var server = McpServer{
        .config = .{ .name = "server" },
    };
    const context = LegacyElicitationContext{
        .catalog_mutex = &runtime.catalog_mutex,
        .completions = &runtime.completions,
        .server = &server,
        .transport = undefined,
        .wire = .legacy_mcp_2025_11,
        .responder = null,
        .capabilities = .{},
        .operation = .{ .tools_call = "authorize" },
        .deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
            .clock = .awake,
            .raw = .fromSeconds(1),
        }),
        .cancel_flag = null,
        .connection_generation = 7,
        .client_generation = 70,
        .catalog_generation = 8,
        .auth_generation = 9,
    };
    const origin = context.inputOrigin();
    try std.testing.expectEqual(@as(u64, 7), origin.connection_generation);
    try std.testing.expectEqual(@as(u64, 70), origin.client_generation);
}

test "direct legacy terminal retains only completed tool outcomes" {
    try std.testing.expectEqual(
        tool_mcp_runtime.ContinuationTerminal.completed,
        terminalOutcomeForCallStatus(.success),
    );
    try std.testing.expectEqual(
        tool_mcp_runtime.ContinuationTerminal.completed,
        terminalOutcomeForCallStatus(.tool_failure),
    );
    try std.testing.expectEqual(
        tool_mcp_runtime.ContinuationTerminal.abandoned,
        terminalOutcomeForCallStatus(.protocol_failure),
    );
    try std.testing.expectEqual(
        tool_mcp_runtime.ContinuationTerminal.abandoned,
        terminalOutcomeForCallStatus(.input_required),
    );
}

test "legacy URL waiter publication is allocator-safe and retirement wakes it" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failed_runtime = McpRuntime.init(failing.allocator());
    defer failed_runtime.deinit();
    const ids = [_][]const u8{"one"};
    var completed = [_]bool{false};
    var failed_waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = "server",
            .scope = .{ .operation = .{ .tools_call = "authorize" } },
            .connection_generation = 1,
            .client_generation = 1,
            .catalog_generation = 1,
            .request_generation = 1,
            .auth_generation = 1,
            .deadline_ms = std.math.maxInt(i64),
        },
        .ids = &ids,
        .completed = &completed,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        failed_runtime.completions.registerLegacyUrlWaiter(&failed_waiter),
    );
    try std.testing.expectEqual(@as(usize, 0), failed_runtime.completions.legacy_url_waiters.items.len);

    var runtime = McpRuntime.init(std.testing.allocator);
    var waiter = failed_waiter;
    try runtime.completions.registerLegacyUrlWaiter(&waiter);
    runtime.retireAndWait();
    try std.testing.expectEqual(
        tool_mcp_runtime.LegacyUrlCompletionStatus.cancelled,
        waiter.signal.status.load(.acquire),
    );
    try std.testing.expect(waiter.signal.wake.load(.acquire));
    runtime.completions.unregisterLegacyUrlWaiter(&waiter);
    runtime.deinit();
}

test "runtime retirement cancels a committed stdio tool call before waiting for its lease" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const shell_server =
        \\while IFS= read -r line; do
        \\  id=${line#*'"id":'}
        \\  id=${id%%,*}
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}'
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"tools":[{"name":"echo","description":"Echo","inputSchema":{"type":"object"}}]}}\n' "$id"
        \\      ;;
        \\    *'"method":"tools/call"'*)
        \\      ;;
        \\    *'"method":"notifications/cancelled"'*)
        \\      exit 0
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    var config = try shellMcpConfigForTest(alloc, "retire", shell_server);
    config.operation_timeout_ms = 60_000;
    try runtime.addServer(config);
    runtime.connectAll(.{});
    try std.testing.expect(runtime.hasTool("mcp_retire_echo"));

    const Call = struct {
        runtime: *McpRuntime,
        caller_cancel: *std.atomic.Value(bool),
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            if (!self.runtime.acquireUse()) {
                self.err = error.McpRuntimeUnavailable;
                return;
            }
            defer self.runtime.releaseUse();
            const result = self.runtime.callToolByNameWithOptions(
                std.testing.allocator,
                "mcp_retire_echo",
                "{}",
                tool_result_limits.default_max_tool_result_bytes,
                .{ .cancel_flag = self.caller_cancel },
            ) catch |err| {
                self.err = err;
                return;
            };
            if (result) |value| {
                var owned = value;
                owned.deinit(std.testing.allocator);
            }
        }
    };

    var caller_cancel = std.atomic.Value(bool).init(false);
    var call = Call{ .runtime = &runtime, .caller_cancel = &caller_cancel };
    const call_thread = try std.Thread.spawn(.{}, Call.run, .{&call});
    var joined = false;
    defer if (!joined) {
        caller_cancel.store(true, .release);
        call_thread.join();
    };

    const dispatcher = runtime.servers.items[0].dispatcher.?;
    const committed_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    while (dispatcher.pendingRequestCount() == 0) {
        if (!std.Io.Clock.Timestamp.compare(
            std.Io.Clock.Timestamp.now(std.testing.io, .awake),
            .lt,
            committed_deadline,
        )) return error.McpToolCallNotCommitted;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }

    const started_ms = io_mod.milliTimestamp();
    runtime.retireAndWait();
    const elapsed_ms = io_mod.milliTimestamp() - started_ms;
    call_thread.join();
    joined = true;

    try std.testing.expectEqual(error.Cancelled, call.err.?);
    try std.testing.expect(!caller_cancel.load(.acquire));
    try std.testing.expect(elapsed_ms < 1_000);
    try std.testing.expectEqual(@as(usize, 0), dispatcher.pendingRequestCount());
}

test "McpRuntime listServersAndTools with no servers" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    const listing = try runtime.listServersAndTools(alloc);
    defer alloc.free(listing);
    try std.testing.expectEqualStrings("No MCP servers configured.\n", listing);
}

test "MCP oversized frame result is structured and bounded" {
    const alloc = std.testing.allocator;
    const cap_bytes = mcpResponseFrameCap(1024);

    const result = try tool_result.frame_too_large_result(
        alloc,
        "filesystem",
        "mcp_filesystem_dump",
        cap_bytes,
    );
    defer alloc.free(result);

    try std.testing.expect(result.len <= 1024);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("filesystem", parsed.value.object.get("server").?.string);
    try std.testing.expectEqualStrings("mcp_filesystem_dump", parsed.value.object.get("tool").?.string);
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("response_frame_too_large", err.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(cap_bytes)), err.get("cap_bytes").?.integer);
}

test "oversized MCP frame handling preserves a structured bounded result" {
    const alloc = std.testing.allocator;
    const cap_bytes = mcpResponseFrameCap(1024);

    var server = McpServer{ .config = .{ .name = try alloc.dupe(u8, "filesystem"), .command = try alloc.dupe(u8, "cmd") } };
    defer server.deinit(alloc);
    server.setReady(alloc, operation_control.monotonicMillis(io_mod.getIo()));

    const result = try handleMcpResponseFrameTooLarge(alloc, &server, "mcp_filesystem_dump", cap_bytes);
    defer alloc.free(result.model_output);

    try std.testing.expect(std.mem.find(u8, result.model_output, "\"kind\":\"response_frame_too_large\"") != null);
    try std.testing.expect(std.mem.find(u8, result.model_output, "\"server\":\"filesystem\"") != null);
    try std.testing.expect(std.mem.find(u8, result.model_output, "\"tool\":\"mcp_filesystem_dump\"") != null);
}

test "modern response classification requires complete resultType and preserves protocol errors" {
    const alloc = std.testing.allocator;

    var complete = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"tools\":[]}}",
        .{},
    );
    defer complete.deinit();
    switch (try classifyResponsePayload(complete.value, .modern)) {
        .complete => |result| try std.testing.expect(result.object.get("tools") != null),
        .protocol_error => return error.TestUnexpectedResult,
    }

    var legacy = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}",
        .{},
    );
    defer legacy.deinit();
    switch (try classifyResponsePayload(legacy.value, .legacy)) {
        .complete => {},
        .protocol_error => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.McpMissingResultType, classifyResponsePayload(legacy.value, .modern));

    var input_required = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\"}}",
        .{},
    );
    defer input_required.deinit();
    try std.testing.expectError(error.McpUnsupportedResultType, classifyResponsePayload(input_required.value, .modern));

    var unsupported = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"1900-01-01\"}}}",
        .{},
    );
    defer unsupported.deinit();
    switch (try classifyResponsePayload(unsupported.value, .modern)) {
        .complete => return error.TestUnexpectedResult,
        .protocol_error => |protocol_error| {
            try std.testing.expectEqual(unsupported_protocol_version_code, protocol_error.code);
            try std.testing.expectEqualStrings("Unsupported protocol version", protocol_error.message);
            const data = protocol_error.data orelse return error.TestExpectedEqual;
            try std.testing.expectEqualStrings("1900-01-01", data.object.get("requested").?.string);
            try std.testing.expectEqualStrings(modern_protocol_version, data.object.get("supported").?.array.items[0].string);
        },
    }
}

test "response payload classification rejects malformed envelopes" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "{\"id\":1,\"result\":{\"resultType\":\"complete\"}}",
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"},\"error\":{\"code\":-1,\"message\":\"ambiguous\"}}",
    }) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            error.McpInvalidJson,
            classifyResponsePayload(parsed.value, .modern),
        );
    }
}

test "legacy stdio initialization transitions are bounded and monotonic" {
    const cases = [_]struct {
        offered: LegacyStdioVersion,
        observation: LegacyInitializeObservation,
        expected: LegacyInitializeTransition,
    }{
        .{ .offered = .v2025_11_25, .observation = .{ .accepted = .v2025_11_25 }, .expected = .{ .accept = .v2025_11_25 } },
        .{ .offered = .v2025_11_25, .observation = .{ .accepted = .v2024_11_05 }, .expected = .{ .accept = .v2024_11_05 } },
        .{ .offered = .v2025_06_18, .observation = .{ .accepted = .v2025_11_25 }, .expected = .{ .accept = .v2025_11_25 } },
        .{ .offered = .v2025_03_26, .observation = .{ .accepted = .v2025_03_26 }, .expected = .{ .accept = .v2025_03_26 } },
        .{ .offered = .v2025_11_25, .observation = .connection_closed, .expected = .{ .retry = .v2025_06_18 } },
        .{ .offered = .v2025_06_18, .observation = .connection_closed, .expected = .{ .retry = .v2025_03_26 } },
        .{ .offered = .v2025_03_26, .observation = .connection_closed, .expected = .{ .retry = .v2024_11_05 } },
        .{ .offered = .v2024_11_05, .observation = .connection_closed, .expected = .fail },
        .{ .offered = .v2025_11_25, .observation = .{ .unsupported = null }, .expected = .{ .retry = .v2025_06_18 } },
        .{ .offered = .v2025_06_18, .observation = .{ .unsupported = null }, .expected = .{ .retry = .v2025_03_26 } },
        .{ .offered = .v2025_03_26, .observation = .{ .unsupported = null }, .expected = .{ .retry = .v2024_11_05 } },
        .{ .offered = .v2024_11_05, .observation = .{ .unsupported = null }, .expected = .fail },
        .{ .offered = .v2025_11_25, .observation = .{ .unsupported = .v2024_11_05 }, .expected = .{ .retry = .v2024_11_05 } },
        .{ .offered = .v2025_11_25, .observation = .{ .unsupported = .v2025_11_25 }, .expected = .fail },
        .{ .offered = .v2025_06_18, .observation = .{ .unsupported = .v2025_11_25 }, .expected = .fail },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            decideLegacyInitializeTransition(case.offered, case.observation),
        );
    }
}

test "legacy stdio initialization accepts supported counters and rejects unknown versions" {
    const alloc = std.testing.allocator;

    var countered = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"serverInfo\":{\"name\":\"legacy\",\"version\":\"1\"}}}",
        .{},
    );
    defer countered.deinit();
    try std.testing.expectEqual(
        LegacyInitializeObservation{ .accepted = .v2024_11_05 },
        try classifyLegacyInitializeResponse(countered.value, .v2025_11_25),
    );

    var unsupported = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32602,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2024-11-05\"],\"requested\":\"2025-11-25\"}}}",
        .{},
    );
    defer unsupported.deinit();
    try std.testing.expectEqual(
        LegacyInitializeObservation{ .unsupported = .v2024_11_05 },
        try classifyLegacyInitializeResponse(unsupported.value, .v2025_11_25),
    );

    var unrelated_invalid_params = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32602,\"message\":\"Invalid client capabilities\"}}",
        .{},
    );
    defer unrelated_invalid_params.deinit();
    try std.testing.expectError(
        error.McpInitFailed,
        classifyLegacyInitializeResponse(unrelated_invalid_params.value, .v2025_11_25),
    );

    var unknown = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2030-01-01\",\"capabilities\":{},\"serverInfo\":{\"name\":\"future\",\"version\":\"1\"}}}",
        .{},
    );
    defer unknown.deinit();
    try std.testing.expectError(
        error.McpUnsupportedProtocolVersion,
        classifyLegacyInitializeResponse(unknown.value, .v2025_11_25),
    );
}

test "discovery classification separates modern negotiation from legacy fallback" {
    const alloc = std.testing.allocator;

    var modern = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"tools\":{}}}}",
        .{},
    );
    defer modern.deinit();
    try std.testing.expectEqual(DiscoveryOutcome.modern, try classifyDiscoveryResponse(modern.value));

    var legacy_error = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
        .{},
    );
    defer legacy_error.deinit();
    switch (try classifyDiscoveryResponse(legacy_error.value)) {
        .legacy_fallback => |version| try std.testing.expectEqual(LegacyStdioVersion.v2025_11_25, version),
        else => return error.TestUnexpectedResult,
    }

    var invalid_params = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32602,\"message\":\"Missing modern request metadata\"}}",
        .{},
    );
    defer invalid_params.deinit();
    switch (try classifyDiscoveryResponse(invalid_params.value)) {
        .legacy_fallback => |version| try std.testing.expectEqual(
            LegacyStdioVersion.v2025_11_25,
            version,
        ),
        else => return error.TestUnexpectedResult,
    }

    var legacy_supported = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2024-11-05\"],\"requested\":\"2026-07-28\"}}}",
        .{},
    );
    defer legacy_supported.deinit();
    switch (try classifyDiscoveryResponse(legacy_supported.value)) {
        .legacy_fallback => |version| try std.testing.expectEqual(LegacyStdioVersion.v2024_11_05, version),
        else => return error.TestUnexpectedResult,
    }

    var unsupported = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2025-11-25\"],\"requested\":\"2026-07-28\"}}}",
        .{},
    );
    defer unsupported.deinit();
    switch (try classifyDiscoveryResponse(unsupported.value)) {
        .legacy_fallback => |version| try std.testing.expectEqual(LegacyStdioVersion.v2025_11_25, version),
        else => return error.TestUnexpectedResult,
    }

    var malformed_unsupported = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2024-11-05\",1],\"requested\":\"2026-07-28\"}}}",
        .{},
    );
    defer malformed_unsupported.deinit();
    switch (try classifyDiscoveryResponse(malformed_unsupported.value)) {
        .modern_protocol_error => |protocol_error| {
            try std.testing.expectEqual(unsupported_protocol_version_code, protocol_error.code);
        },
        else => return error.TestUnexpectedResult,
    }

    var mismatched_request = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2024-11-05\"],\"requested\":\"2025-11-25\"}}}",
        .{},
    );
    defer mismatched_request.deinit();
    switch (try classifyDiscoveryResponse(mismatched_request.value)) {
        .modern_protocol_error => |protocol_error| {
            try std.testing.expectEqual(unsupported_protocol_version_code, protocol_error.code);
        },
        else => return error.TestUnexpectedResult,
    }

    var missing_capability = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32021,\"message\":\"Missing required client capability\",\"data\":{\"capability\":\"roots\"}}}",
        .{},
    );
    defer missing_capability.deinit();
    switch (try classifyDiscoveryResponse(missing_capability.value)) {
        .modern_protocol_error => |protocol_error| {
            try std.testing.expectEqual(missing_required_client_capability_code, protocol_error.code);
        },
        else => return error.TestUnexpectedResult,
    }

    var no_mutual_version = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2025-11-25\"],\"capabilities\":{}}}",
        .{},
    );
    defer no_mutual_version.deinit();
    switch (try classifyDiscoveryResponse(no_mutual_version.value)) {
        .legacy_fallback => |version| try std.testing.expectEqual(LegacyStdioVersion.v2025_11_25, version),
        else => return error.TestUnexpectedResult,
    }

    var missing_result_type = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{}}}",
        .{},
    );
    defer missing_result_type.deinit();
    try std.testing.expectError(error.McpMissingResultType, classifyDiscoveryResponse(missing_result_type.value));

    var unmarked_result = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}",
        .{},
    );
    defer unmarked_result.deinit();
    try std.testing.expectError(error.McpMissingResultType, classifyDiscoveryResponse(unmarked_result.value));
}

test "legacy initialize advertises elicitation only for negotiated supported modes" {
    const alloc = std.testing.allocator;
    const current = try buildLegacyInitializeRequest(
        alloc,
        1,
        "2025-11-25",
        .legacy_mcp_2025_11,
        .{ .form = true, .url = true },
    );
    defer alloc.free(current);
    try std.testing.expect(std.mem.find(u8, current, "\"elicitation\":{\"form\":{},\"url\":{}}") != null);

    const form_only = try buildLegacyInitializeRequest(
        alloc,
        2,
        "2025-06-18",
        .legacy_mcp_2025_06,
        .{ .form = true, .url = true },
    );
    defer alloc.free(form_only);
    try std.testing.expect(std.mem.find(u8, form_only, "\"elicitation\":{}") != null);
    try std.testing.expect(std.mem.find(u8, form_only, "\"url\"") == null);

    const old = try buildLegacyInitializeRequest(
        alloc,
        3,
        "2024-11-05",
        null,
        .{ .form = true, .url = true },
    );
    defer alloc.free(old);
    try std.testing.expect(std.mem.find(u8, old, "\"elicitation\"") == null);
}

test "modern request builders share required request metadata" {
    const alloc = std.testing.allocator;
    const metadata = try std.fmt.allocPrint(
        alloc,
        "\"_meta\":{{\"io.modelcontextprotocol/protocolVersion\":\"{s}\",\"io.modelcontextprotocol/clientInfo\":{{\"name\":\"fx\",\"version\":\"{s}\"}},\"io.modelcontextprotocol/clientCapabilities\":{{}}}}",
        .{ modern_protocol_version, build_options.app_version },
    );
    defer alloc.free(metadata);

    const discover = try buildDiscoverRequest(alloc, 0);
    defer alloc.free(discover);
    const expected_discover = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"server/discover\",\"params\":{{{s}}}}}",
        .{metadata},
    );
    defer alloc.free(expected_discover);
    try std.testing.expectEqualStrings(expected_discover, discover);

    const list = try buildToolsListRequest(alloc, 1, .modern, null);
    defer alloc.free(list);
    const expected_list = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{{{s}}}}}",
        .{metadata},
    );
    defer alloc.free(expected_list);
    try std.testing.expectEqualStrings(expected_list, list);

    const call = try buildToolCallRequestForProtocol(alloc, 2, "echo", "{\"text\":\"hi\"}", .modern, null, null, .{});
    defer alloc.free(call);
    const expected_call = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{{s},\"name\":\"echo\",\"arguments\":{{\"text\":\"hi\"}}}}}}",
        .{metadata},
    );
    defer alloc.free(expected_call);
    try std.testing.expectEqualStrings(expected_call, call);

    const modern_progress = try buildToolCallRequestForProtocol(
        alloc,
        3,
        "echo",
        "{}",
        .modern,
        3,
        null,
        .{},
    );
    defer alloc.free(modern_progress);
    try std.testing.expect(
        std.mem.find(u8, modern_progress, "\"progressToken\":3") != null,
    );

    const legacy_call = try buildToolCallRequestForProtocol(
        alloc,
        4,
        "echo",
        "{}",
        .legacy,
        null,
        null,
        .{},
    );
    defer alloc.free(legacy_call);
    try std.testing.expect(
        std.mem.find(u8, legacy_call, "\"_meta\"") == null,
    );
}

fn shellMcpConfigForTest(alloc: Allocator, name: []const u8, script: []const u8) !McpServerConfig {
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const command = try alloc.dupe(u8, "sh");
    errdefer alloc.free(command);
    const args = try alloc.alloc([]const u8, 2);
    errdefer alloc.free(args);
    args[0] = try alloc.dupe(u8, "-c");
    errdefer alloc.free(args[0]);
    args[1] = try alloc.dupe(u8, script);
    errdefer alloc.free(args[1]);
    const env = try alloc.alloc(mcp_contract.McpEnvVar, 1);
    errdefer alloc.free(env);
    const key = try alloc.dupe(u8, protocol_negotiation.protocol_version_environment);
    errdefer alloc.free(key);
    const value = try alloc.dupe(u8, modern_protocol_version);
    env[0] = .{ .key = key, .value = value };
    return .{
        .env = env,
        .name = owned_name,
        .command = command,
        .args = args,
    };
}

fn shellMcpConfigWithModeForTest(
    alloc: Allocator,
    name: []const u8,
    script: []const u8,
    mode: []const u8,
) !McpServerConfig {
    var config = try shellMcpConfigForTest(alloc, name, script);
    errdefer config.deinit(alloc);
    const args = try alloc.alloc([]const u8, 3);
    errdefer alloc.free(args);
    args[0] = config.args[0];
    args[1] = config.args[1];
    args[2] = try alloc.dupe(u8, mode);
    errdefer alloc.free(args[2]);
    alloc.free(config.args);
    config.args = args;
    return config;
}

const resource_resolution_shell_server =
    \\mode=$0
    \\while IFS= read -r line; do
    \\  id=${line#*'"id":'}
    \\  id=${id%%,*}
    \\  case "$line" in
    \\    *'"method":"server/discover"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{}}}}'
    \\      ;;
    \\    *'"method":"tools/list"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"tools":[]}}\n' "$id"
    \\      ;;
    \\    *'"method":"resources/list"'*)
    \\      if [ "$mode" = exact ]; then
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resources":[{"uri":"memory://exact","name":"exact"}]}}\n' "$id"
    \\      else
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resources":[]}}\n' "$id"
    \\      fi
    \\      ;;
    \\    *'"method":"resources/templates/list"'*)
    \\      case "$mode" in
    \\        exact) exit 7 ;;
    \\        invalid) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","nextCursor":"","resourceTemplates":[]}}\n' "$id" ;;
    \\        cancel) sleep 1; printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","resourceTemplates":[]}}\n' "$id" ;;
    \\        missing) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resourceTemplates":[]}}\n' "$id" ;;
    \\        *) exit 9 ;;
    \\      esac
    \\      ;;
    \\    *'"method":"notifications/cancelled"'*)
    \\      ;;
    \\    *'"method":"resources/read"'*'memory://exact'*)
    \\      if [ "$mode" != exact ]; then exit 8; fi
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","contents":[{"uri":"memory://exact","text":"exact-resource"}]}}\n' "$id"
    \\      ;;
    \\    *'"method":"resources/read"'*)
    \\      exit 8
    \\      ;;
    \\    *)
    \\      exit 3
    \\      ;;
    \\  esac
    \\done
;

fn acceptResourceInputForTest(
    context: *anyopaque,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    required: tool_mcp_runtime.InputRequired,
) anyerror![]const u8 {
    const calls: *usize = @ptrCast(@alignCast(context));
    calls.* += 1;
    if (std.mem.find(u8, required.input_requests_json, "confirm") == null or
        required.request_state_json == null)
    {
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, origin.server_name, "mrtr-cache") or
        origin.operation != .resources_read)
    {
        return error.TestUnexpectedResult;
    }
    return alloc.dupe(u8, "{\"confirm\":{\"action\":\"accept\",\"content\":{\"confirmed\":true}}}");
}

fn expectResourceText(result: ResourceReadResult, expected: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), result.contents.len);
    switch (result.contents[0].data) {
        .text => |text| try std.testing.expectEqualStrings(expected, text),
        .blob => return error.TestUnexpectedResult,
    }
}

fn expectTestProcessExited(pid: std.posix.pid_t) !void {
    for (0..200) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => {},
        };
        if (builtin.os.tag == .linux and testProcessIsZombie(pid)) return;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return error.TestProcessStillRunning;
}

fn testProcessIsZombie(pid: std.posix.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return false;
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return false;
    defer file.close(io_mod.getIo());

    var reader_buf: [512]u8 = undefined;
    var status_buf: [512]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &reader_buf);
    const read_len = reader.interface.readSliceShort(&status_buf) catch return false;
    return std.mem.find(u8, status_buf[0..read_len], "\nState:\tZ") != null;
}

test "server_transport.connectServer completes NDJSON handshake against a real stdio server" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\trap '' TERM
        \\sleep 60 &
        \\grandchild=$!
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"error":{"code":-32601,"message":"Method not found"}}'
        \\      ;;
        \\    *'"method":"initialize"'*)
        \\      printf '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"shell","version":"0"},"instructions":"%s"}}\n' "$grandchild"
        \\      ;;
        \\    *'"method":"notifications/initialized"'*)
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","description":"Echo text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}}'
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var server = McpServer{ .config = try shellMcpConfigForTest(alloc, "ndjson", shell_server) };
    defer server.deinit(alloc);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    try server_transport.connectServer(alloc, &server, .{}, &used, .{});

    try std.testing.expectEqual(ServerState.ready, server.state.load(.acquire));
    try std.testing.expectEqual(StdioProtocol.legacy, server.stdio_protocol);
    try std.testing.expectEqual(@as(usize, 1), server.tool_catalog.tools.items.len);
    try std.testing.expectEqualStrings("echo", server.tool_catalog.tools.items[0].original_name);
    try std.testing.expectEqualStrings("mcp_ndjson_echo", server.tool_catalog.tools.items[0].prefixed_name);
    const grandchild_pid = try std.fmt.parseInt(std.posix.pid_t, server.instructions.?, 10);

    server.disconnect();
    try expectTestProcessExited(grandchild_pid);
}

test "server_transport.connectServer discovers and calls a modern NDJSON tool" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*)
        \\      exit 2
        \\      ;;
        \\    *'"method":"server/discover"'*'"io.modelcontextprotocol/protocolVersion":"2026-07-28"'*'"io.modelcontextprotocol/clientCapabilities":{}'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"instructions":"Use echo.","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"modern-identity"}}}}'
        \\      ;;
        \\    *'"method":"tools/list"'*'"io.modelcontextprotocol/protocolVersion":"2026-07-28"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","ttlMs":60000,"tools":[{"name":"echo","description":"Echo text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}}'
        \\      ;;
        \\    *'"method":"tools/call"'*'"io.modelcontextprotocol/protocolVersion":"2026-07-28"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"text","text":"modern echo"}]}}'
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "modern", shell_server));
    runtime.connectAll(.{});

    const server = runtime.servers.items[0];
    try std.testing.expectEqual(ServerState.ready, server.state.load(.acquire));
    try std.testing.expectEqual(StdioProtocol.modern, server.stdio_protocol);
    try std.testing.expectEqualStrings("Use echo.", server.instructions.?);
    try std.testing.expectEqualStrings("modern-identity", server.negotiated_server_name.?);
    try std.testing.expectEqual(@as(?[]u8, null), server.negotiated_server_version);
    const listing = try runtime.listServersAndTools(alloc);
    defer alloc.free(listing);
    try std.testing.expect(std.mem.find(
        u8,
        listing,
        "negotiated_name=modern-identity negotiated_version=unavailable protocol=2026-07-28",
    ) != null);

    const result = (try runtime.callToolByName(
        alloc,
        "mcp_modern_echo",
        "{\"text\":\"hi\"}",
        tool_result_limits.default_max_tool_result_bytes,
    )).?;
    defer alloc.free(result.model_output);
    try std.testing.expect(std.mem.find(u8, result.model_output, "modern echo") != null);

    server.disconnect();
}

test "server identity projection preserves independently optional modern fields" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        name: ?[]const u8,
        version: ?[]const u8,
    }{
        .{
            .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"modern-meta\",\"version\":\"2.0.0\"}}}}",
            .name = "modern-meta",
            .version = "2.0.0",
        },
        .{
            .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"AWSKnowledgeMCP\",\"version\":\"\"}}}}",
            .name = "AWSKnowledgeMCP",
            .version = null,
        },
        .{
            .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"name\":\"name-only\"}}}",
            .name = "name-only",
            .version = null,
        },
        .{
            .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"version\":\"1.2.3\"}}}",
            .name = null,
            .version = "1.2.3",
        },
        .{
            .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
            .name = null,
            .version = null,
        },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        const identity = try parseServerIdentity(parsed.value);
        if (case.name) |expected| {
            try std.testing.expectEqualStrings(expected, identity.name.?);
        } else {
            try std.testing.expect(identity.name == null);
        }
        if (case.version) |expected| {
            try std.testing.expectEqualStrings(expected, identity.version.?);
        } else {
            try std.testing.expect(identity.version == null);
        }
    }

    var invalid = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"name\":1}}}",
        .{},
    );
    defer invalid.deinit();
    try std.testing.expectError(
        error.McpInvalidResult,
        parseServerIdentity(invalid.value),
    );
}

test "modern MCP calls delegate unsupported schema assertions to the server" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}'
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","ttlMs":60000,"tools":[{"name":"local","inputSchema":{"type":"object","properties":{"email":{"type":"string"}},"required":["email"]}},{"name":"provider_pattern","inputSchema":{"type":"object","properties":{"email":{"type":"string","pattern":"^(?!\\.)(?!.*\\.\\.)[A-Za-z0-9_+.-]+@[A-Za-z0-9.-]+$"}},"required":["email"]},"outputSchema":{"type":"object","properties":{"email":{"type":"string","pattern":"^(?!\\.)(?!.*\\.\\.)[A-Za-z0-9_+.-]+@[A-Za-z0-9.-]+$"}},"required":["email"]}}]}}'
        \\      ;;
        \\    *'"method":"tools/call"'*'"email":"person@example.com"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","content":[{"type":"text","text":"accepted"}],"structuredContent":{"email":"person@example.com"}}}'
        \\      ;;
        \\    *'"method":"tools/call"'*'"name":"local"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"email required by server"}}'
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "provider", shell_server));
    runtime.connectAll(.{});

    const server = runtime.servers.items[0];
    try std.testing.expectEqual(ServerState.ready, server.state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), server.tool_catalog.tools.items.len);
    const valid = try runtime.validateToolArgumentsByName(
        alloc,
        "mcp_provider_provider_pattern",
        \\{"email":"person@example.com"}
        ,
    );
    switch (valid) {
        .valid => |generation| try std.testing.expectEqual(runtime.generation, generation),
        .invalid, .not_available => return error.TestUnexpectedResult,
    }
    var rejected = (try runtime.callToolByName(
        alloc,
        "mcp_provider_local",
        "{}",
        tool_result_limits.default_max_tool_result_bytes,
    )).?;
    defer rejected.deinit(alloc);
    try std.testing.expectEqual(tool_mcp_runtime.CallStatus.protocol_failure, rejected.status);
    try std.testing.expect(std.mem.find(u8, rejected.model_output, "email required by server") != null);

    const result = (try runtime.callToolByName(
        alloc,
        "mcp_provider_provider_pattern",
        \\{"email":"person@example.com"}
    ,
        tool_result_limits.default_max_tool_result_bytes,
    )).?;
    defer alloc.free(result.model_output);
    try std.testing.expect(std.mem.find(u8, result.model_output, "accepted") != null);

    server.disconnect();
}

test "concrete resource reads do not require the template catalog" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigWithModeForTest(
        alloc,
        "exact-resource",
        resource_resolution_shell_server,
        "exact",
    ));
    runtime.connectAll(.{});
    try std.testing.expectEqual(ServerState.ready, runtime.servers.items[0].state.load(.acquire));

    var result = try runtime.readResource(alloc, "exact-resource", "memory://exact", .{});
    defer result.deinit(alloc);
    try expectResourceText(result, "exact-resource");
}

test "invalid resource template pagination propagates before resource read" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigWithModeForTest(
        alloc,
        "invalid-template-pages",
        resource_resolution_shell_server,
        "invalid",
    ));
    runtime.connectAll(.{});
    try std.testing.expectEqual(ServerState.ready, runtime.servers.items[0].state.load(.acquire));
    try std.testing.expectError(
        error.DuplicateCursor,
        runtime.readResource(alloc, "invalid-template-pages", "memory://missing", .{}),
    );
}

test "resource template discovery cancellation is not converted to not found" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigWithModeForTest(
        alloc,
        "cancel-template-pages",
        resource_resolution_shell_server,
        "cancel",
    ));
    runtime.connectAll(.{});
    try std.testing.expectEqual(ServerState.ready, runtime.servers.items[0].state.load(.acquire));
    var resources = try runtime.listResources(alloc, "cancel-template-pages", false, null, .unrestricted);
    resources.deinit(alloc);

    var cancel_flag = std.atomic.Value(bool).init(false);
    const Flip = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const cancel_thread = try std.Thread.spawn(.{}, Flip.run, .{&cancel_flag});
    defer cancel_thread.join();
    try std.testing.expectError(
        error.Cancelled,
        runtime.readResource(
            alloc,
            "cancel-template-pages",
            "memory://missing",
            .{ .cancel_flag = &cancel_flag },
        ),
    );
}

test "missing resource returns not found without a resource read request" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigWithModeForTest(
        alloc,
        "missing-resource",
        resource_resolution_shell_server,
        "missing",
    ));
    runtime.connectAll(.{});
    try std.testing.expectEqual(ServerState.ready, runtime.servers.items[0].state.load(.acquire));
    try std.testing.expectError(
        error.McpResourceNotFound,
        runtime.readResource(alloc, "missing-resource", "memory://missing", .{}),
    );
}

fn resourceTemplateSnapshotServerForTest(
    templates: []resources_feature.Template,
) McpServer {
    const digest = catalog_freshness.authIdentity(&.{});
    const template_metadata = catalog_freshness.SnapshotMetadata{
        .key = catalog_freshness.authPartition(.public, digest),
        .connection_generation = 0,
        .catalog_generation = 1,
        .fetched_at_ms = 1,
        .expires_at_ms = std.math.maxInt(u64),
        .scope = .public,
        .content_digest = digest,
    };
    return .{
        .config = .{ .name = "allocation-fixture" },
        .resource_catalog = .{
            .catalog = .{
                .items = &.{},
                .fetched_at_ms = 1,
                .expires_at_ms = std.math.maxInt(u64),
                .cache_scope = .public,
            },
            .metadata = catalog_freshness.SnapshotMetadata{
                .key = catalog_freshness.authPartition(.public, digest),
                .connection_generation = 0,
                .catalog_generation = 1,
                .fetched_at_ms = 1,
                .expires_at_ms = std.math.maxInt(u64),
                .scope = .public,
                .content_digest = digest,
            },
            .available = true,
        },
        .resource_template_catalog = .{
            .catalog = .{
                .items = templates,
                .fetched_at_ms = 1,
                .expires_at_ms = std.math.maxInt(u64),
                .cache_scope = .public,
            },
            .metadata = template_metadata,
            .available = true,
        },
    };
}

fn resourceReadPublicationServerForTest(
    descriptors: []resources_feature.Descriptor,
) McpServer {
    const digest = catalog_freshness.authIdentity(&.{});
    const metadata = catalog_freshness.SnapshotMetadata{
        .key = catalog_freshness.authPartition(.public, digest),
        .connection_generation = 1,
        .catalog_generation = 1,
        .fetched_at_ms = 1,
        .expires_at_ms = std.math.maxInt(u64),
        .scope = .public,
        .content_digest = digest,
    };
    return .{
        .config = .{ .name = "resource-read-publication" },
        .connection_generation = 1,
        .stdio_protocol = .modern,
        .negotiated_protocol_version = modern_protocol_version,
        .resource_catalog = .{
            .catalog = .{
                .items = descriptors,
                .fetched_at_ms = 1,
                .expires_at_ms = std.math.maxInt(u64),
                .cache_scope = .public,
            },
            .metadata = metadata,
            .available = true,
        },
    };
}

fn resourceReadPublicationSnapshotForTest(
    server: *const McpServer,
) FeatureIdentitySnapshot {
    return .{
        .server_name = @constCast(server.config.name),
        .identity = @constCast("memory://owned"),
        .kind = .resource,
        .auth_partition = server.resource_catalog.metadata.?.key,
        .connection_generation = server.connection_generation,
        .catalog_generation = server.resource_catalog.metadata.?.catalog_generation,
    };
}

fn fetchedResourceReadForTest(
    alloc: Allocator,
    cache_eligible: bool,
) !FetchedResourceRead {
    const contents = try alloc.alloc(resources_feature.ResourceContent, 1);
    errdefer alloc.free(contents);
    const uri = try alloc.dupe(u8, "memory://owned");
    errdefer alloc.free(uri);
    const text = try alloc.dupe(u8, "owned contents");
    contents[0] = .{ .uri = uri, .data = .{ .text = text } };
    return .{
        .result = .{
            .contents = contents,
            .cache = .{ .ttl_ms = 60_000, .ttl_present = true, .scope = .public },
            .cache_eligible = cache_eligible,
        },
        .auth_identity = null,
        .received_at_ms = 1,
    };
}

fn deinitResourceReadCacheForTest(server: *McpServer, alloc: Allocator) void {
    for (server.resource_read_cache.items) |*entry| entry.deinit(alloc);
    server.resource_read_cache.deinit(alloc);
    server.resource_read_cache = .empty;
}

fn checkResourceReadFinishAllocationFailures(
    alloc: Allocator,
    cache_eligible: bool,
) !void {
    var descriptors = [_]resources_feature.Descriptor{.{
        .uri = @constCast("memory://owned"),
        .name = @constCast("owned"),
    }};
    var server = resourceReadPublicationServerForTest(&descriptors);
    defer deinitResourceReadCacheForTest(&server, alloc);
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    const snapshot = resourceReadPublicationSnapshotForTest(&server);
    const fetched = try fetchedResourceReadForTest(alloc, cache_eligible);
    var result = try feature_operations.finishFetchedResourceRead(
        runtime.featureCatalogs(),
        alloc,
        &server,
        &snapshot,
        "memory://owned",
        fetched,
        std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
            .clock = .awake,
            .raw = .fromSeconds(1),
        }),
        null,
        .unrestricted,
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, @intFromBool(cache_eligible)),
        server.resource_read_cache.items.len,
    );
    try expectResourceText(result, "owned contents");
}

test "resource read cache publication OOM releases fetched contents" {
    var descriptors = [_]resources_feature.Descriptor{.{
        .uri = @constCast("memory://owned"),
        .name = @constCast("owned"),
    }};
    var server = resourceReadPublicationServerForTest(&descriptors);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var runtime = McpRuntime.init(failing.allocator());
    defer runtime.deinit();
    const snapshot = resourceReadPublicationSnapshotForTest(&server);
    const fetched = try fetchedResourceReadForTest(std.testing.allocator, true);
    try std.testing.expectError(
        error.OutOfMemory,
        feature_operations.finishFetchedResourceRead(
            runtime.featureCatalogs(),
            std.testing.allocator,
            &server,
            &snapshot,
            "memory://owned",
            fetched,
            std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
                .clock = .awake,
                .raw = .fromSeconds(1),
            }),
            null,
            .unrestricted,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), server.resource_read_cache.items.len);
}

test "resource read publication cancellation and deadline release fetched contents" {
    var descriptors = [_]resources_feature.Descriptor{.{
        .uri = @constCast("memory://owned"),
        .name = @constCast("owned"),
    }};
    var server = resourceReadPublicationServerForTest(&descriptors);
    defer deinitResourceReadCacheForTest(&server, std.testing.allocator);
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const snapshot = resourceReadPublicationSnapshotForTest(&server);
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Cancelled,
        feature_operations.finishFetchedResourceRead(
            runtime.featureCatalogs(),
            std.testing.allocator,
            &server,
            &snapshot,
            "memory://owned",
            try fetchedResourceReadForTest(std.testing.allocator, true),
            std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
                .clock = .awake,
                .raw = .fromSeconds(1),
            }),
            &cancel,
            .unrestricted,
        ),
    );
    cancel.store(false, .release);
    try std.testing.expectError(
        error.McpRequestTimedOut,
        feature_operations.finishFetchedResourceRead(
            runtime.featureCatalogs(),
            std.testing.allocator,
            &server,
            &snapshot,
            "memory://owned",
            try fetchedResourceReadForTest(std.testing.allocator, true),
            std.Io.Clock.Timestamp.now(std.testing.io, .awake),
            null,
            .unrestricted,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), server.resource_read_cache.items.len);
}

test "cached resource read finalization releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResourceReadFinishAllocationFailures,
        .{true},
    );
}

test "uncached resource read finalization releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResourceReadFinishAllocationFailures,
        .{false},
    );
}

fn checkResourceSnapshotWithTemplatesAllocationFailures(alloc: Allocator) !void {
    var templates = [_]resources_feature.Template{.{
        .uri_template = @constCast("memory://{value}"),
        .name = @constCast("value"),
    }};
    var server = resourceTemplateSnapshotServerForTest(&templates);
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    var snapshot = try feature_snapshot.snapshotResourceIdentityWithTemplates(
        &runtime.catalog_mutex,
        alloc,
        &server,
        "memory://accepted",
        deadline,
        null,
    );
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings("memory://accepted", snapshot.requested_uri.?);
}

test "resource template matching bounds catalog work and releases the catalog lock" {
    const malicious_template = "memory://{value}" ++ ("a" ** 2047) ++ "b";
    const requested_uri = "memory://" ++ ("a" ** 4096);
    var templates = [_]resources_feature.Template{.{
        .uri_template = @constCast(malicious_template),
        .name = @constCast("bounded"),
    }};
    var server = resourceTemplateSnapshotServerForTest(&templates);
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    try std.testing.expectError(
        error.McpResourceTemplateMatchLimitExceeded,
        feature_snapshot.snapshotResourceIdentityWithTemplates(
            &runtime.catalog_mutex,
            std.testing.allocator,
            &server,
            requested_uri,
            deadline,
            null,
        ),
    );

    try lockRwUntil(&runtime.catalog_mutex, deadline, null);
    runtime.catalog_mutex.unlock(io_mod.getIo());
}

test "resource template matching propagates operation control and releases the catalog lock" {
    var templates = [_]resources_feature.Template{.{
        .uri_template = @constCast("memory://{value}"),
        .name = @constCast("value"),
    }};
    var server = resourceTemplateSnapshotServerForTest(&templates);
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const future_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    var cancel_flag = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Cancelled,
        feature_snapshot.snapshotResourceIdentityWithTemplates(
            &runtime.catalog_mutex,
            std.testing.allocator,
            &server,
            "memory://accepted",
            future_deadline,
            &cancel_flag,
        ),
    );
    try lockRwUntil(&runtime.catalog_mutex, future_deadline, null);
    runtime.catalog_mutex.unlock(io_mod.getIo());

    const expired_deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(
        error.McpRequestTimedOut,
        feature_snapshot.snapshotResourceIdentityWithTemplates(
            &runtime.catalog_mutex,
            std.testing.allocator,
            &server,
            "memory://accepted",
            expired_deadline,
            null,
        ),
    );
    try lockRwUntil(&runtime.catalog_mutex, future_deadline, null);
    runtime.catalog_mutex.unlock(io_mod.getIo());
}

test "resource template snapshot allocation failures propagate and clean up" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResourceSnapshotWithTemplatesAllocationFailures,
        .{},
    );
}

test "MRTR-derived resource reads are never reused from the URI cache" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\read_count=0
        \\while IFS= read -r line; do
        \\  id=${line#*'"id":'}
        \\  id=${id%%,*}
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{}}}}'
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"tools":[]}}\n' "$id"
        \\      ;;
        \\    *'"method":"resources/list"'*)
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resources":[{"uri":"memory://mrtr","name":"mrtr"}]}}\n' "$id"
        \\      ;;
        \\    *'"method":"resources/templates/list"'*)
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resourceTemplates":[]}}\n' "$id"
        \\      ;;
        \\    *'"method":"resources/read"'*)
        \\      read_count=$((read_count + 1))
        \\      case "$line" in
        \\        *'"inputResponses"'*)
        \\          printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"contents":[{"uri":"memory://mrtr","text":"completed-%s"}]}}\n' "$id" "$read_count"
        \\          ;;
        \\        *)
        \\          printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}}},"requestState":{"round":%s}}}\n' "$id" "$read_count"
        \\          ;;
        \\      esac
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "mrtr-cache", shell_server));
    runtime.connectAll(.{});
    try std.testing.expectEqual(ServerState.ready, runtime.servers.items[0].state.load(.acquire));

    var responder_calls: usize = 0;
    const responder = tool_mcp_runtime.InputResponder{
        .context = &responder_calls,
        .capabilities = .{ .form = true },
        .callback = acceptResourceInputForTest,
    };
    var first = try runtime.readResource(
        alloc,
        "mrtr-cache",
        "memory://mrtr",
        .{ .input_responder = responder },
    );
    defer first.deinit(alloc);
    try expectResourceText(first, "completed-2");

    var second = try runtime.readResource(
        alloc,
        "mrtr-cache",
        "memory://mrtr",
        .{ .input_responder = responder },
    );
    defer second.deinit(alloc);
    try expectResourceText(second, "completed-4");
    try std.testing.expectEqual(@as(usize, 2), responder_calls);
}

test "stale resource cache never masks input-required or cancellation" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\mrtr_reads=0
        \\cancel_reads=0
        \\while IFS= read -r line; do
        \\  id=${line#*'"id":'}
        \\  id=${id%%,*}
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{}}}}'
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"tools":[]}}\n' "$id"
        \\      ;;
        \\    *'"method":"resources/list"'*)
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resources":[{"uri":"memory://mrtr-stale","name":"mrtr"},{"uri":"memory://cancel-stale","name":"cancel"}]}}\n' "$id"
        \\      ;;
        \\    *'"method":"resources/templates/list"'*)
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resourceTemplates":[]}}\n' "$id"
        \\      ;;
        \\    *'"method":"resources/read"'*'memory://mrtr-stale'*)
        \\      mrtr_reads=$((mrtr_reads + 1))
        \\      if [ "$mrtr_reads" -eq 1 ]; then
        \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":0,"contents":[{"uri":"memory://mrtr-stale","text":"stale-mrtr"}]}}\n' "$id"
        \\      else
        \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}}},"requestState":"mrtr-stale"}}\n' "$id"
        \\      fi
        \\      ;;
        \\    *'"method":"resources/read"'*'memory://cancel-stale'*)
        \\      cancel_reads=$((cancel_reads + 1))
        \\      if [ "$cancel_reads" -eq 1 ]; then
        \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":0,"contents":[{"uri":"memory://cancel-stale","text":"stale-cancel"}]}}\n' "$id"
        \\      else
        \\        sleep 1
        \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"contents":[{"uri":"memory://cancel-stale","text":"late"}]}}\n' "$id"
        \\      fi
        \\      ;;
        \\    *'"method":"notifications/cancelled"'*)
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "stale-controls", shell_server));
    runtime.connectAll(.{});
    try std.testing.expectEqual(ServerState.ready, runtime.servers.items[0].state.load(.acquire));

    var initial_mrtr = try runtime.readResource(
        alloc,
        "stale-controls",
        "memory://mrtr-stale",
        .{},
    );
    defer initial_mrtr.deinit(alloc);
    try expectResourceText(initial_mrtr, "stale-mrtr");
    try std.testing.expectError(
        error.McpInputRequired,
        runtime.readResource(alloc, "stale-controls", "memory://mrtr-stale", .{}),
    );

    var initial_cancel = try runtime.readResource(
        alloc,
        "stale-controls",
        "memory://cancel-stale",
        .{},
    );
    defer initial_cancel.deinit(alloc);
    try expectResourceText(initial_cancel, "stale-cancel");

    var cancel_flag = std.atomic.Value(bool).init(false);
    const Flip = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const cancel_thread = try std.Thread.spawn(.{}, Flip.run, .{&cancel_flag});
    defer cancel_thread.join();
    try std.testing.expectError(
        error.Cancelled,
        runtime.readResource(
            alloc,
            "stale-controls",
            "memory://cancel-stale",
            .{ .cancel_flag = &cancel_flag },
        ),
    );
}

test "modern stdio tool discovery consumes every page and publishes deterministic order" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}'
        \\      ;;
        \\    *'"method":"tools/list"'*'"cursor":"page-2"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"alpha","title":"Alpha","inputSchema":{"type":"object"}}]}}'
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","nextCursor":"page-2","tools":[{"name":"zeta","title":"Zeta","inputSchema":{"type":"object"},"outputSchema":{"type":"object"},"annotations":{"readOnlyHint":true},"icons":[{"src":"data:image/png;base64,AA=="}],"_meta":{"vendor":"fixture"}}]}}'
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "pages", shell_server));
    runtime.connectAll(.{});

    const server = runtime.servers.items[0];
    try std.testing.expectEqual(ServerState.ready, server.state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), server.tool_catalog.tools.items.len);
    try std.testing.expectEqualStrings("alpha", server.tool_catalog.tools.items[0].original_name);
    try std.testing.expectEqualStrings("zeta", server.tool_catalog.tools.items[1].original_name);
    try std.testing.expectEqualStrings("Zeta", server.tool_catalog.tools.items[1].title.?);
    try std.testing.expect(server.tool_catalog.tools.items[1].output_schema_json != null);
    try std.testing.expect(server.tool_catalog.tools.items[1].annotations_json != null);
    try std.testing.expect(server.tool_catalog.tools.items[1].icons_json != null);
    try std.testing.expect(server.tool_catalog.tools.items[1].metadata_json != null);

    server.disconnect();
}

test "delayed modern discovery response does not fall back to legacy" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*)
        \\      exit 2
        \\      ;;
        \\    *'"method":"server/discover"'*)
        \\      sleep 2
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}'
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[]}}'
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "delayed-modern", shell_server));
    runtime.connectAll(.{});

    const server = runtime.servers.items[0];
    try std.testing.expectEqual(ServerState.ready, server.state.load(.acquire));
    try std.testing.expectEqual(StdioProtocol.modern, server.stdio_protocol);

    server.disconnect();
}

test "unsupported modern version falls back when legacy is mutually supported" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2024-11-05"],"requested":"2026-07-28"}}}'
        \\      ;;
        \\    *'"method":"initialize"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"legacy","version":"0"}}}'
        \\      ;;
        \\    *'"method":"notifications/initialized"'*)
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}'
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "mutual-version", shell_server));
    runtime.connectAll(.{});

    const server = runtime.servers.items[0];
    try std.testing.expectEqual(ServerState.ready, server.state.load(.acquire));
    try std.testing.expectEqual(StdioProtocol.legacy, server.stdio_protocol);

    server.disconnect();
}

test "stdio discovery negotiates declared 2025-11 legacy elicitation" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2025-11-25"],"requested":"2026-07-28"}}}'
        \\      ;;
        \\    *'"method":"initialize"'*'"protocolVersion":"2025-11-25"'*'"elicitation":{"form":{},"url":{}}'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}}}}'
        \\      ;;
        \\    *'"method":"notifications/initialized"'*)
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}'
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.initWithElicitation(alloc, .{ .form = true, .url = true });
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "no-mutual-version", shell_server));
    runtime.connectAll(.{});

    const server = runtime.servers.items[0];
    try std.testing.expectEqual(ServerState.ready, server.state.load(.acquire));
    try std.testing.expectEqualStrings(legacy_2025_11_protocol_version, server.negotiated_protocol_version);
    try std.testing.expectEqual(StdioProtocol.legacy, server.stdio_protocol);
}

test "malformed modern discovery response does not fall back to legacy" {
    const alloc = std.testing.allocator;
    const shell_server =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}'
        \\      ;;
        \\    *'"method":"initialize"'*)
        \\      exit 2
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "malformed-modern", shell_server));
    runtime.connectAll(.{});

    const server = runtime.servers.items[0];
    try std.testing.expectEqual(ServerState.failed, server.state.load(.acquire));
    try std.testing.expectEqualStrings("McpMissingResultType", server.last_error.?);
}

test "McpRuntime cancels blocked stdio discovery without exposing partial state" {
    const alloc = std.testing.allocator;

    const args = try alloc.alloc([]const u8, 1);
    args[0] = try alloc.dupe(u8, "{}");

    var runtime = McpRuntime.init(alloc);
    var runtime_deinitialized = false;
    defer if (!runtime_deinitialized) runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "pending"),
        .command = try alloc.dupe(u8, "awk"),
        .args = args,
    });

    runtime.startDiscovery(.{});
    try io_mod.getIo().sleep(.fromMilliseconds(25), .awake);
    try std.testing.expect(runtime.isDiscovering());
    try std.testing.expect(!runtime.hasTool("mcp_pending_echo"));

    const listing = try runtime.listServersAndTools(alloc);
    defer alloc.free(listing);
    try std.testing.expect(std.mem.find(u8, listing, "state=connecting") != null);
    try std.testing.expect(std.mem.find(u8, listing, "command") == null);

    var results = try runtime.searchTools(alloc, "echo", 5, .{}, .{}, .unrestricted);
    defer results.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"tools\":[],\"count\":0,\"state\":\"discovering\",\"retryable\":true}",
        results.model_output,
    );

    const started_ms = io_mod.milliTimestamp();
    runtime.deinit();
    runtime_deinitialized = true;
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1000);
}

test "caller cancellation interrupts blocked candidate connection" {
    const Connector = struct {
        runtime: *McpRuntime,
        cancel: *std.atomic.Value(bool),
        started: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.runtime.connectAllCancellable(.{}, self.cancel);
        }
    };

    const alloc = std.testing.allocator;
    const args = try alloc.alloc([]const u8, 1);
    args[0] = try alloc.dupe(u8, "{}");
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "candidate"),
        .command = try alloc.dupe(u8, "awk"),
        .args = args,
        .startup_timeout_ms = 60_000,
    });
    var cancel = std.atomic.Value(bool).init(false);
    var connector = Connector{ .runtime = &runtime, .cancel = &cancel };
    const thread = try std.Thread.spawn(.{}, Connector.run, .{&connector});
    while (!connector.started.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    io_mod.sleep(25 * std.time.ns_per_ms);
    const started_ms = io_mod.milliTimestamp();
    cancel.store(true, .release);
    thread.join();

    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
    try std.testing.expectEqual(ServerState.disconnected, runtime.servers.items[0].state.load(.acquire));
    try std.testing.expect(runtime.servers.items[0].last_error == null);
}

test "MCP health terminal-encodes external identity and omits secret-bearing configuration" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "unsafe\x1b[31m-name"),
        .transport = .http,
        .url = try alloc.dupe(u8, "https://user:secret@example.test/mcp?token=hidden"),
        .headers = try alloc.dupe(mcp_contract.McpHttpHeader, &.{.{
            .name = try alloc.dupe(u8, "Authorization"),
            .value = try alloc.dupe(u8, "Bearer hidden"),
        }}),
        .enabled = false,
    });
    const output = try runtime.listServersAndTools(alloc);
    defer alloc.free(output);
    try std.testing.expect(std.mem.find(u8, output, "\\x1b") != null);
    for ([_][]const u8{ "secret", "token", "Authorization", "Bearer", "example.test" }) |forbidden| {
        try std.testing.expect(std.mem.find(u8, output, forbidden) == null);
    }
}

test "MCP health snapshot cleans up every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkHealthSnapshotAllocationFailures,
        .{},
    );
}

test "MCP health cache age is independent of the presentation clock" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "cached"),
        .transport = .http,
        .url = try alloc.dupe(u8, "https://example.test/mcp"),
    });
    const server = runtime.servers.items[0];
    server.state.store(.ready, .release);
    runtime.discovery_state.store(.complete, .release);
    try parseAndStoreTools(alloc, server, .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
    , &runtime.tool_aliases);
    server.tool_catalog.metadata.?.expires_at_ms = operation_control.monotonicMillis(io_mod.getIo()) + 60_000;
    var fresh = try runtime.snapshotHealth(alloc, std.math.maxInt(u64));
    defer fresh.deinit(alloc);
    try std.testing.expectEqual(health.CacheFreshness.fresh, fresh.servers[0].cache_freshness);
    server.tool_catalog.metadata.?.expires_at_ms = 1;
    var stale = try runtime.snapshotHealth(alloc, 0);
    defer stale.deinit(alloc);
    try std.testing.expectEqual(health.CacheFreshness.stale, stale.servers[0].cache_freshness);
}

test "model catalog reports deferred ask servers without connecting and counts only visible tools" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "required"),
        .transport = .http,
        .url = try alloc.dupe(u8, "https://required.example/mcp"),
        .required = true,
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "optional"),
        .transport = .http,
        .url = try alloc.dupe(u8, "https://optional.example/mcp"),
    });
    runtime.discovery_state.store(.complete, .seq_cst);
    runtime.servers.items[0].state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"one","inputSchema":{"type":"object"}},{"name":"two","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);

    var denied_rules = [_]types.PermissionRule{.{
        .permission = @constCast("mcp_required_two"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    var before = try runtime.snapshotModelCatalog(
        alloc,
        .{ .rules = &denied_rules },
        true,
    );
    defer before.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), before.servers.len);
    try std.testing.expectEqual(model_catalog.Availability.ready, before.servers[0].availability);
    try std.testing.expectEqual(@as(?usize, 1), before.servers[0].tool_count);
    try std.testing.expectEqual(model_catalog.Availability.available_on_demand, before.servers[1].availability);
    try std.testing.expectEqual(@as(?usize, null), before.servers[1].tool_count);
    try std.testing.expectEqual(ServerState.disconnected, runtime.servers.items[1].state.load(.acquire));
    try std.testing.expectEqual(DiscoveryState.idle, runtime.servers.items[1].startup_state.load(.acquire));

    runtime.servers.items[1].state.store(.ready, .release);
    try parseAndStoreTools(alloc, runtime.servers.items[1], .{}, response, &used);
    runtime.servers.items[1].startup_state.store(.complete, .release);
    var after = try runtime.snapshotModelCatalog(alloc, .{}, true);
    defer after.deinit(alloc);

    try std.testing.expectEqual(model_catalog.Availability.ready, after.servers[1].availability);
    try std.testing.expectEqual(@as(?usize, 2), after.servers[1].tool_count);
}

fn checkModelCatalogSnapshotAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try std.testing.allocator.dupe(u8, "one"),
        .command = try std.testing.allocator.dupe(u8, "fixture"),
        .enabled = false,
    });
    try runtime.addServer(.{
        .name = try std.testing.allocator.dupe(u8, "two"),
        .command = try std.testing.allocator.dupe(u8, "fixture"),
        .enabled = false,
    });
    runtime.discovery_state.store(.complete, .release);
    for (runtime.servers.items) |server| server.state.store(.disabled, .release);

    var snapshot = try runtime.snapshotModelCatalog(alloc, .{}, false);
    snapshot.deinit(alloc);
}

test "model catalog snapshot cleans up every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkModelCatalogSnapshotAllocationFailures,
        .{},
    );
}

fn checkHealthSnapshotAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try std.testing.allocator.dupe(u8, "server"),
        .command = try std.testing.allocator.dupe(u8, "fixture"),
        .enabled = false,
    });
    var snapshot = try runtime.snapshotHealth(alloc, 42);
    defer snapshot.deinit(alloc);
}

test "MCP health reads only lock-free state during discovery" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "active"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "disabled"),
        .command = try alloc.dupe(u8, "fixture"),
        .enabled = false,
        .required = true,
    });

    const active = runtime.servers.items[0];
    active.state.store(.ready, .release);
    active.negotiated_server_name = try alloc.dupe(u8, "published-name");
    active.negotiated_server_version = try alloc.dupe(u8, "1.0.0");
    active.negotiated_protocol_version = "2025-06-18";
    active.catalog_generation = 7;
    active.restart_attempts = 3;
    active.last_successful_discovery_ms = 41;
    active.auth_credentials_present.store(true, .release);
    runtime.servers.items[1].state.store(.ready, .release);

    var idle = try runtime.snapshotHealth(alloc, 40);
    try std.testing.expectEqual(health.ConnectionState.disconnected, idle.servers[0].connection);
    try std.testing.expectEqual(@as(?[]u8, null), idle.servers[0].negotiated_name);
    idle.deinit(alloc);

    runtime.discovery_state.store(.loading, .seq_cst);

    var loading = try runtime.snapshotHealth(alloc, 42);
    defer loading.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loading.servers.len);
    const loading_active = loading.servers[0];
    try std.testing.expectEqual(health.ConnectionState.connecting, loading_active.connection);
    try std.testing.expectEqual(health.AuthenticationState.authenticated, loading_active.authentication);
    try std.testing.expectEqual(@as(?[]u8, null), loading_active.negotiated_name);
    try std.testing.expectEqual(@as(?[]u8, null), loading_active.negotiated_version);
    try std.testing.expectEqual(@as(?[]u8, null), loading_active.protocol_version);
    try std.testing.expectEqual(health.CapabilityCounts{}, loading_active.counts);
    try std.testing.expectEqual(health.CacheFreshness.unavailable, loading_active.cache_freshness);
    try std.testing.expectEqual(health.SubscriptionState.unavailable, loading_active.subscription);
    try std.testing.expectEqual(@as(u64, 0), loading_active.catalog_generation);
    try std.testing.expectEqual(@as(u8, 0), loading_active.retry_attempt);
    try std.testing.expectEqual(@as(?u64, null), loading_active.retry_in_ms);
    try std.testing.expectEqual(@as(?u64, null), loading_active.last_successful_discovery_ms);
    try std.testing.expectEqual(@as(?[]u8, null), loading_active.failure);
    try std.testing.expectEqual(health.ConnectionState.disabled, loading.servers[1].connection);
    try std.testing.expectEqualStrings(
        "Enable this required server or mark it optional.",
        loading.servers[1].failure.?,
    );

    const SnapshotAttempt = struct {
        runtime: *McpRuntime,
        entered: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.entered.store(true, .release);
            var snapshot = self.runtime.snapshotHealth(std.heap.page_allocator, 42) catch |err| {
                self.err = err;
                self.finished.store(true, .release);
                return;
            };
            snapshot.deinit(std.heap.page_allocator);
            self.finished.store(true, .release);
        }
    };
    runtime.catalog_mutex.lockUncancelable(std.testing.io);
    active.status_lock.lockUncancelable(std.testing.io);
    var locks_held = true;
    defer if (locks_held) {
        active.status_lock.unlock(std.testing.io);
        runtime.catalog_mutex.unlock(std.testing.io);
    };
    var attempt = SnapshotAttempt{ .runtime = &runtime };
    const thread = try std.Thread.spawn(.{}, SnapshotAttempt.run, .{&attempt});
    const entered_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(5),
    });
    while (!attempt.entered.load(.acquire) and std.Io.Clock.Timestamp.compare(
        std.Io.Clock.Timestamp.now(std.testing.io, .awake),
        .lt,
        entered_deadline,
    )) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    const entered = attempt.entered.load(.acquire);
    const completion_deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(5),
    });
    while (entered and !attempt.finished.load(.acquire) and std.Io.Clock.Timestamp.compare(
        std.Io.Clock.Timestamp.now(std.testing.io, .awake),
        .lt,
        completion_deadline,
    )) {
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    const finished_while_locked = attempt.finished.load(.acquire);
    active.status_lock.unlock(std.testing.io);
    runtime.catalog_mutex.unlock(std.testing.io);
    locks_held = false;
    thread.join();
    try std.testing.expect(entered);
    try std.testing.expect(attempt.err == null);
    try std.testing.expect(finished_while_locked);

    runtime.discovery_state.store(.complete, .seq_cst);
    var published = try runtime.snapshotHealth(alloc, 43);
    defer published.deinit(alloc);
    try std.testing.expectEqual(health.ConnectionState.failed, published.servers[0].connection);
    try std.testing.expectEqual(health.AuthenticationState.authenticated, published.servers[0].authentication);
    try std.testing.expectEqualStrings("published-name", published.servers[0].negotiated_name.?);
    try std.testing.expectEqualStrings("1.0.0", published.servers[0].negotiated_version.?);
    try std.testing.expectEqualStrings("2025-06-18", published.servers[0].protocol_version.?);
    try std.testing.expectEqual(@as(u64, 7), published.servers[0].catalog_generation);
    try std.testing.expectEqual(@as(?u64, 41), published.servers[0].last_successful_discovery_ms);
}

test "McpRuntime publishes and calls ready servers while another server is connecting" {
    const alloc = std.testing.allocator;

    const ready_server =
        \\/"method":"server\/discover"/ { print "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"; fflush(); next }
        \\/"method":"initialize"/ { print "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"awk\",\"version\":\"0\"}}}"; fflush(); next }
        \\/"method":"tools\/list"/ { print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo text\",\"inputSchema\":{\"type\":\"object\"}}]}}"; fflush() }
        \\/"method":"tools\/call"/ { print "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ready worked\"}]}}"; fflush() }
    ;
    const ready_args = try alloc.alloc([]const u8, 1);
    ready_args[0] = try alloc.dupe(u8, ready_server);
    const pending_args = try alloc.alloc([]const u8, 1);
    pending_args[0] = try alloc.dupe(u8, "{}");

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "ready"),
        .command = try alloc.dupe(u8, "awk"),
        .args = ready_args,
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "pending"),
        .command = try alloc.dupe(u8, "awk"),
        .args = pending_args,
    });

    runtime.startDiscoveryWithServerTimeout(.{}, .fromSeconds(2));
    const ready_deadline_ms = io_mod.milliTimestamp() + 5_000;
    var ready_published = false;
    while (runtime.isDiscovering() and
        io_mod.milliTimestamp() < ready_deadline_ms)
    {
        ready_published = runtime.hasTool("mcp_ready_echo");
        if (ready_published) break;
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }

    try std.testing.expect(ready_published);
    try std.testing.expect(runtime.isDiscovering());
    try std.testing.expect(runtime.hasTool("mcp_ready_echo"));
    var result = (try runtime.callToolByName(alloc, "mcp_ready_echo", "{}", 4096)).?;
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, result.model_output, "ready worked") != null);
    try std.testing.expect(runtime.isDiscovering());
    const pending_names = try runtime.snapshotToolNames(alloc, .{});
    defer {
        for (pending_names) |name| alloc.free(name);
        alloc.free(pending_names);
    }
    try std.testing.expectEqual(@as(usize, 1), pending_names.len);

    const completion_deadline_ms = io_mod.milliTimestamp() + 5_000;
    while (runtime.isDiscovering() and
        io_mod.milliTimestamp() < completion_deadline_ms)
    {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(!runtime.isDiscovering());
    try std.testing.expect(runtime.hasTool("mcp_ready_echo"));
    const names = try runtime.snapshotToolNames(alloc, .{});
    defer {
        for (names) |name| alloc.free(name);
        alloc.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("mcp_ready_echo", names[0]);
}

test "McpRuntime continues discovery after one server times out" {
    const alloc = std.testing.allocator;

    const pending_args = try alloc.alloc([]const u8, 1);
    pending_args[0] = try alloc.dupe(u8, "{}");

    const ready_server =
        \\/"method":"server\/discover"/ { print "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"; fflush(); next }
        \\/"method":"initialize"/ { print "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"awk\",\"version\":\"0\"}}}"; fflush(); next }
        \\/"method":"tools\/list"/ { print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo text\",\"inputSchema\":{\"type\":\"object\"}}]}}"; fflush() }
    ;
    const ready_args = try alloc.alloc([]const u8, 1);
    ready_args[0] = try alloc.dupe(u8, ready_server);

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "pending"),
        .command = try alloc.dupe(u8, "awk"),
        .args = pending_args,
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "ready"),
        .command = try alloc.dupe(u8, "awk"),
        .args = ready_args,
    });

    runtime.startDiscoveryWithServerTimeout(.{}, .fromSeconds(2));
    const deadline_ms = io_mod.milliTimestamp() + 5_000;
    while (runtime.isDiscovering() and io_mod.milliTimestamp() < deadline_ms) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }

    try std.testing.expect(!runtime.isDiscovering());
    try std.testing.expectEqual(ServerState.failed, runtime.servers.items[0].state.load(.acquire));
    try std.testing.expectEqualStrings("McpConnectionTimedOut", runtime.servers.items[0].last_error.?);
    try std.testing.expectEqual(ServerState.ready, runtime.servers.items[1].state.load(.acquire));
    try std.testing.expect(runtime.hasTool("mcp_ready_echo"));
}

test "tool name allocation sanitizes truncates and deconflicts" {
    const alloc = std.testing.allocator;
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    const first = try used.name(alloc, .{}, "fs", "read");
    defer alloc.free(first);
    try std.testing.expectEqualStrings("mcp_fs_read", first);

    const sanitized = try used.name(alloc, .{}, "git-hub", "read/file");
    defer alloc.free(sanitized);
    try std.testing.expectEqualStrings("mcp_git-hub_read_file", sanitized);

    const empty_segments = try used.name(alloc, .{}, "", "");
    defer alloc.free(empty_segments);
    try std.testing.expectEqualStrings("mcp_server_tool", empty_segments);

    const slash = try used.name(alloc, .{}, "a/b", "c");
    defer alloc.free(slash);
    try std.testing.expectEqualStrings("mcp_a_b_c", slash);

    const space_collision = try used.name(alloc, .{}, "a b", "c");
    defer alloc.free(space_collision);
    try std.testing.expectEqualStrings("mcp_a_b_c_2", space_collision);

    const long_server = [_]u8{'s'} ** 70;
    const long_first = try used.name(alloc, .{}, long_server[0..], "tool");
    defer alloc.free(long_first);
    try std.testing.expectEqual(@as(usize, 64), long_first.len);
    try std.testing.expectEqualStrings("mcp_" ++ ("s" ** 60), long_first);

    const long_second = try used.name(alloc, .{}, long_server[0..], "other");
    defer alloc.free(long_second);
    try std.testing.expectEqual(@as(usize, 64), long_second.len);
    try std.testing.expectEqualStrings("mcp_" ++ ("s" ** 58) ++ "_2", long_second);
}

test "MCP tool name allocation reserves registered tool names" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const alloc = std.testing.allocator;
    const registry = tool_dispatch.Registry{ .tools = &.{builtin_tools.mcp_select_tool} };
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    const select_name = try used.name(alloc, registry, "select", "tool");
    defer alloc.free(select_name);

    try std.testing.expectEqualStrings("mcp_select_tool_2", select_name);
}

test "MCP tool name allocation leaves non-conflicting dynamic names unchanged" {
    const alloc = std.testing.allocator;
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    const name = try used.name(alloc, .{}, "github", "create_issue");
    defer alloc.free(name);

    try std.testing.expectEqualStrings("mcp_github_create_issue", name);
}

test "tool name allocation collision path cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocateToolNameCollisionAllocFailures, .{});
}

fn checkToolSnapshotBuildAllocationFailures(alloc: Allocator) !void {
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const server = McpServer{
        .config = .{ .name = "snapshot", .transport = .http, .url = "https://example.test/mcp" },
    };
    const protocol_tools = [_]tools_feature.Tool{.{
        .name = @constCast("echo"),
        .title = @constCast("Echo"),
        .description = @constCast("Echo input"),
        .input_schema_json = @constCast("{\"type\":\"object\"}"),
        .output_schema_json = @constCast("{\"type\":\"object\"}"),
        .icons_json = @constCast("[]"),
        .annotations_json = @constCast("{}"),
        .metadata_json = @constCast("{}"),
    }};
    var snapshot = try tool_catalog.prepare(
        alloc,
        &server,
        .{},
        &protocol_tools,
        &used,
        .modern,
    );
    defer snapshot.deinit(alloc);
}

fn checkCursorReplacementAllocationFailures(alloc: Allocator) !void {
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    cursor = try alloc.dupe(u8, "first");
    try replaceOwnedCursor(alloc, &cursor, "second");
    try std.testing.expectEqualStrings("second", cursor.?);
}

test "cursor replacement preserves the previous owner on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCursorReplacementAllocationFailures,
        .{},
    );
}

fn checkServerDiagnosticSnapshotAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(alloc);
    defer runtime.servers.deinit(alloc);
    var server = McpServer{
        .config = .{ .name = "fixture", .command = "fixture-command" },
        .state = .init(.failed),
    };
    server.last_error = try alloc.dupe(u8, "fixture-error");
    defer alloc.free(server.last_error.?);
    try runtime.servers.append(alloc, &server);
    runtime.discovery_state.store(.complete, .release);

    var snapshot = try runtime.snapshotServerDiagnostics(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try std.testing.expectEqualStrings("fixture", snapshot.items[0].name);
    try std.testing.expectEqualStrings("fixture-error", snapshot.items[0].last_error.?);
}

test "server diagnostic snapshots release every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkServerDiagnosticSnapshotAllocationFailures,
        .{},
    );
}

test "whole tool snapshot construction releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkToolSnapshotBuildAllocationFailures,
        .{},
    );
}

test "tool name deconfliction is whole-runtime" {
    const alloc = std.testing.allocator;
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    var server_one = McpServer{ .config = .{ .name = try alloc.dupe(u8, "same/a"), .command = try alloc.dupe(u8, "cmd") } };
    defer server_one.deinit(alloc);
    var server_two = McpServer{ .config = .{ .name = try alloc.dupe(u8, "same_a"), .command = try alloc.dupe(u8, "cmd") } };
    defer server_two.deinit(alloc);

    const tools_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"read","description":"Read","inputSchema":{"type":"object","properties":{}}}]}}
    ;

    try parseAndStoreTools(alloc, &server_one, .{}, tools_response, &used);
    try parseAndStoreTools(alloc, &server_two, .{}, tools_response, &used);

    try std.testing.expectEqualStrings("mcp_same_a_read", server_one.tool_catalog.tools.items[0].prefixed_name);
    try std.testing.expectEqualStrings("mcp_same_a_read_2", server_two.tool_catalog.tools.items[0].prefixed_name);
    server_one.tool_catalog.deinit(alloc);
    try parseAndStoreTools(alloc, &server_one, .{}, tools_response, &used);
    try std.testing.expectEqualStrings("mcp_same_a_read", server_one.tool_catalog.tools.items[0].prefixed_name);
}

test "parseAndStoreTools duplicates original_name for owned cleanup" {
    const alloc = std.testing.allocator;
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    var server = McpServer{ .config = .{ .name = try alloc.dupe(u8, "fs"), .command = try alloc.dupe(u8, "cmd") } };
    defer server.deinit(alloc);

    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"read","inputSchema":{"type":"object","properties":{}}}]}}
    ;
    try parseAndStoreTools(alloc, &server, .{}, response, &used);

    try std.testing.expectEqual(@as(usize, 1), server.tool_catalog.tools.items.len);
    try std.testing.expectEqualStrings("read", server.tool_catalog.tools.items[0].original_name);
}

test "MCP tool catalog retains only tool-owned search data" {
    try std.testing.expect(!@hasField(McpTool, "server_name"));
    try std.testing.expect(!@hasField(McpTool, "server_instructions"));
    try std.testing.expect(!@hasField(McpTool, "search_text"));
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(McpTool));
}

test "MCP search matches each retained source field" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "git-hub"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    runtime.servers.items[0].state.store(.ready, .release);
    runtime.servers.items[0].instructions = try alloc.dupe(u8, "workflow guide");

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    try parseAndStoreTools(
        alloc,
        runtime.servers.items[0],
        .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"create_issue","description":"Create ticket","inputSchema":{"type":"object","properties":{"repository_slug":{"type":"string"}}}}]}}
    ,
        &used,
    );

    const cases = [_][]const u8{
        "mcp",
        "GIT-HUB",
        "create_issue",
        "ticket repository_slug",
        "workflow ticket",
        "git-hub repository_slug",
    };
    const expected_output =
        "{\"tools\":[{\"name\":\"mcp_git-hub_create_issue\",\"server\":\"git-hub\",\"description\":\"Create ticket\",\"purpose\":\"Create ticket\",\"usage\":[\"mcp\",\"git-hub\",\"create_issue\"]}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}";
    for (cases) |query| {
        var result = try runtime.searchTools(alloc, query, 5, .{}, .{}, .unrestricted);
        defer result.deinit(alloc);
        try std.testing.expectEqualStrings(expected_output, result.model_output);
        try std.testing.expect(result.notice == null);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.model_output, .{});
        defer parsed.deinit();
        const tools = parsed.value.object.get("tools").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), tools.len);
        const usage = tools[0].object.get("usage").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), usage.len);
        try std.testing.expectEqualStrings("mcp", usage[0].string);
        try std.testing.expectEqualStrings("git-hub", usage[1].string);
        try std.testing.expectEqualStrings("create_issue", usage[2].string);
    }

    var missing = try runtime.searchTools(
        alloc,
        "missing-token",
        5,
        .{},
        .{},
        .unrestricted,
    );
    defer missing.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}",
        missing.model_output,
    );
    try std.testing.expect(missing.notice == null);
}

test "MCP search bounds untrusted description and schema fields" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "bounded"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    runtime.servers.items[0].state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    try parseAndStoreTools(
        alloc,
        runtime.servers.items[0],
        .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"probe","description":"initial","inputSchema":{"type":"object"}}]}}
    ,
        &used,
    );

    const description = "zearly123 " ++ ("x" ** mcp_tool_description_search_bytes) ++ " zlate987";
    const schema =
        "{\"type\":\"object\",\"properties\":{\"zearly456\":{\"type\":\"string\"},\"padding\":{\"description\":\"" ++
        ("x" ** mcp_tool_schema_search_bytes) ++
        "zlate654\"}}}";
    const tool = &runtime.servers.items[0].tool_catalog.tools.items[0];
    alloc.free(tool.description);
    tool.description = try alloc.dupe(u8, description);
    alloc.free(tool.input_schema_json);
    tool.input_schema_json = try alloc.dupe(u8, schema);

    const cases = [_]struct {
        query: []const u8,
        expected_match: bool,
    }{
        .{ .query = "zearly123 zearly456", .expected_match = true },
        .{ .query = "zlate987 zearly456", .expected_match = false },
        .{ .query = "zearly123 zlate654", .expected_match = false },
        .{ .query = "zlate987 zlate654", .expected_match = false },
    };
    for (cases) |case| {
        var result = try runtime.searchTools(alloc, case.query, 5, .{}, .{}, .unrestricted);
        defer result.deinit(alloc);
        try std.testing.expectEqual(
            case.expected_match,
            std.mem.find(u8, result.model_output, "mcp_bounded_probe") != null,
        );
    }
}

test "MCP search releases request-scoped ranking allocations" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "github"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    runtime.servers.items[0].state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    try parseAndStoreTools(
        alloc,
        runtime.servers.items[0],
        .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"create_issue","description":"Create issue","inputSchema":{"type":"object"}}]}}
    ,
        &used,
    );

    var counting = std.testing.FailingAllocator.init(alloc, .{});
    const search_alloc = counting.allocator();
    var result = try runtime.searchTools(
        search_alloc,
        "github issue",
        max_mcp_search_limit,
        .{},
        .{},
        .unrestricted,
    );
    defer result.deinit(search_alloc);

    try std.testing.expectEqualStrings(
        "{\"tools\":[{\"name\":\"mcp_github_create_issue\",\"server\":\"github\",\"description\":\"Create issue\",\"purpose\":\"Create issue\",\"usage\":[\"mcp\",\"github\",\"create_issue\"]}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}",
        result.model_output,
    );
    try std.testing.expect(counting.allocations > 0);
}

test "MCP search keeps the globally strongest matches across servers" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "first"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "linear"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    for (runtime.servers.items) |server| server.state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    try parseAndStoreTools(
        alloc,
        runtime.servers.items[0],
        .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"launch","description":"Deploy Linear infrastructure","inputSchema":{"type":"object"}}]}}
    ,
        &used,
    );
    try parseAndStoreTools(
        alloc,
        runtime.servers.items[1],
        .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","description":"Deploy Linear data","inputSchema":{"type":"object"}}]}}
    ,
        &used,
    );

    var result = try runtime.searchTools(alloc, "linear deploy", 1, .{}, .{}, .unrestricted);
    defer result.deinit(alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.model_output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "mcp_linear_echo",
        parsed.value.object.get("tools").?.array.items[0].object.get("name").?.string,
    );
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("total_matches").?.integer);
    try std.testing.expect(parsed.value.object.get("more_available").?.bool);
    try std.testing.expect(parsed.value.object.get("next_cursor").? == .string);
}

test "MCP search applies exact server scope before ranking" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "datadog"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "grafana"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    for (runtime.servers.items) |server| server.state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"list_monitors","description":"List service monitors","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);
    try parseAndStoreTools(alloc, runtime.servers.items[1], .{}, response, &used);

    const inventory = try lexical_relevance.prepare("");
    var scoped = try runtime.searchToolsPrepared(
        alloc,
        .{
            .query = &inventory,
            .kind = .mcp,
            .server = "datadog",
            .limit = 20,
        },
        .{},
        .{},
        .unrestricted,
        null,
    );
    defer scoped.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, scoped.model_output, "mcp_datadog_list_monitors") != null);
    try std.testing.expect(std.mem.find(u8, scoped.model_output, "mcp_grafana_list_monitors") == null);

    var missing = try runtime.searchToolsPrepared(
        alloc,
        .{
            .query = &inventory,
            .kind = .mcp,
            .server = "missing",
            .limit = 20,
        },
        .{},
        .{},
        .unrestricted,
        null,
    );
    defer missing.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, missing.model_output, "\"state\":\"server_not_found\"") != null);
}

test "MCP authentication guidance requires an observed challenge" {
    const alloc = std.testing.allocator;
    var servers = [_]McpServer{.{
        .config = .{ .name = "plain", .transport = .http, .auth = .{} },
        .state = .init(.failed),
    }};
    var access = try OperationAccessGuard.init(alloc, .unrestricted, 1);
    defer access.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try renderAuthenticationRequired(alloc, &.{&servers[0]}, &access, "plain"));

    servers[0].auth_challenge_present.store(true, .release);
    const output = (try renderAuthenticationRequired(alloc, &.{&servers[0]}, &access, "plain")).?;
    defer alloc.free(output);
    try std.testing.expect(std.mem.find(u8, output, "/mcp auth plain --open") != null);
}

test "MCP connection diagnostics retain the cause and mask sensitive values" {
    const alloc = std.testing.allocator;
    const output = (try healthFailureForState(alloc, false, .failed, .configured, "HTTP 500 TOKEN=example-secret")).?;
    defer alloc.free(output);
    try std.testing.expect(std.mem.find(u8, output, "HTTP 500") != null);
    try std.testing.expect(std.mem.find(u8, output, "example-secret") == null);
    try std.testing.expect(std.mem.find(u8, output, "Authentication is required") == null);
}

test "MCP search preserves exact identities and scopes authentication guidance" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "linear"),
        .command = try alloc.dupe(u8, "cmd"),
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "slack"),
        .command = try alloc.dupe(u8, "cmd"),
        .bearer_token_env = try alloc.dupe(u8, "SLACK_TOKEN"),
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "a/b"),
        .command = try alloc.dupe(u8, "cmd"),
        .bearer_token_env = try alloc.dupe(u8, "PUNCTUATED_TOKEN"),
    });
    runtime.servers.items[0].state.store(.ready, .release);
    runtime.servers.items[1].state.store(.failed, .release);
    runtime.servers.items[2].state.store(.failed, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","description":"Echo Linear data","inputSchema":{"type":"object"}},{"name":"read/file","description":"Read a Linear file","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);

    const cases = [_]struct {
        query: []const u8,
        expected_tool: []const u8,
    }{
        .{ .query = "Please use MCP_LINEAR_ECHO for this request", .expected_tool = "mcp_linear_echo" },
        .{ .query = "Please use read/file for this request", .expected_tool = "mcp_linear_read_file" },
    };
    for (cases) |case| {
        var result = try runtime.searchTools(alloc, case.query, 5, .{}, .{}, .unrestricted);
        defer result.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, result.model_output, case.expected_tool) != null);
        try std.testing.expect(std.mem.find(u8, result.model_output, "authentication_required") == null);
    }

    var partial = try runtime.searchTools(alloc, "mcp_linear_echoes", 5, .{}, .{}, .unrestricted);
    defer partial.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, partial.model_output, "authentication_required") == null);

    var noisy = try runtime.searchTools(alloc, "linear issue", 5, .{}, .{}, .unrestricted);
    defer noisy.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, noisy.model_output, "mcp_linear_echo") != null);

    var auth_collision = try runtime.searchTools(alloc, "slack data", 5, .{}, .{}, .unrestricted);
    defer auth_collision.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, auth_collision.model_output, "\"server\":\"slack\"") != null);
    try std.testing.expect(std.mem.find(u8, auth_collision.model_output, "mcp_linear_echo") == null);

    var targeted = try runtime.searchTools(alloc, "authenticate slack now", 5, .{}, .{}, .unrestricted);
    defer targeted.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, targeted.model_output, "\"server\":\"slack\"") != null);
    try std.testing.expect(std.mem.find(u8, targeted.model_output, "SLACK_TOKEN") != null);

    var punctuated = try runtime.searchTools(alloc, "authenticate a/b now", 5, .{}, .{}, .unrestricted);
    defer punctuated.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, punctuated.model_output, "\"server\":\"a/b\"") != null);

    var adjacent = try runtime.searchTools(alloc, "authenticate xa/by now", 5, .{}, .{}, .unrestricted);
    defer adjacent.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, adjacent.model_output, "authentication_required") == null);
}

test "MCP search returns metadata without advertising every executable schema" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{ .name = try alloc.dupe(u8, "github"), .command = try alloc.dupe(u8, "cmd") });
    runtime.servers.items[0].state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"create_issue","description":"Create an issue in a GitHub repository","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"Repository name"},"title":{"type":"string"}},"required":["repo","title"]}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);

    var results = try runtime.searchTools(alloc, "github issue", 5, .{}, .{}, .unrestricted);
    defer results.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, results.model_output, "\"name\":\"mcp_github_create_issue\"") != null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "\"server\":\"github\"") != null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "\"description\"") != null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "\"purpose\"") != null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "\"usage\"") != null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "inputSchema") == null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "Repository name") == null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "server_instructions") == null);
}

test "MCP search reports an authorized match beyond the count cap" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "chrome"),
        .command = try alloc.dupe(u8, "fixture"),
    });
    runtime.discovery_state.store(.complete, .seq_cst);
    runtime.servers.items[0].state.store(.ready, .release);

    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[");
    for (0..21) |index| {
        if (index > 0) try response.writer.writeByte(',');
        try response.writer.print(
            "{{\"name\":\"item{d:0>2}\",\"description\":\"Chrome item {d}\",\"inputSchema\":{{\"type\":\"object\"}}}}",
            .{ index, index },
        );
    }
    try response.writer.writeAll("]}}");

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    try parseAndStoreTools(
        alloc,
        runtime.servers.items[0],
        .{},
        response.written(),
        &used,
    );

    var broad = try runtime.searchTools(alloc, "chrome", 20, .{}, .{}, .unrestricted);
    defer broad.deinit(alloc);
    var broad_json = try std.json.parseFromSlice(std.json.Value, alloc, broad.model_output, .{});
    defer broad_json.deinit();
    try std.testing.expectEqual(@as(i64, 20), broad_json.value.object.get("count").?.integer);
    try std.testing.expect(broad_json.value.object.get("more_available").?.bool);
    try std.testing.expect(broad_json.value.object.get("next_cursor").? == .string);

    var targeted = try runtime.searchTools(alloc, "item00", 20, .{}, .{}, .unrestricted);
    defer targeted.deinit(alloc);
    var targeted_json = try std.json.parseFromSlice(std.json.Value, alloc, targeted.model_output, .{});
    defer targeted_json.deinit();
    try std.testing.expect(!targeted_json.value.object.get("more_available").?.bool);
    try std.testing.expect(targeted_json.value.object.get("next_cursor").? == .null);
}

test "scoped MCP cached tool and feature operations reject authority revoked after admission" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .command = try alloc.dupe(u8, "cmd"),
    });
    runtime.servers.items[0].state.store(.ready, .release);
    runtime.servers.items[0].capabilities = .{
        .resources = true,
        .resources_subscribe = true,
        .prompts = true,
        .completion = true,
    };

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","description":"Echo","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(
        alloc,
        runtime.servers.items[0],
        .{},
        response,
        &used,
    );

    var captured = try runtime.snapshotAccessView(
        alloc,
        "child",
        "parent",
        .{},
        true,
    );
    defer captured.deinit(alloc);
    var live = try captured.clone(alloc);
    defer live.deinit(alloc);
    for (live.tools) |*tool| tool.deinit(alloc);
    alloc.free(live.tools);
    live.tools = try alloc.alloc(access_policy.ToolIdentity, 0);

    const LiveProvider = struct {
        view: *const access_policy.View,

        fn resolve(raw: *anyopaque, provider_alloc: Allocator) !tool_mcp_runtime.ResolvedLiveView {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const view = try self.view.clone(provider_alloc);
            return .{
                .authority_generation = access_policy.authorityGeneration(view),
                .view = view,
            };
        }
    };
    var provider = LiveProvider{ .view = &live };
    const access = tool_mcp_runtime.Access{ .scoped = .{
        .captured = &captured,
        .admission_authority_generation = access_policy.authorityGeneration(captured),
        .live = .{
            .context = @ptrCast(&provider),
            .resolve_fn = LiveProvider.resolve,
        },
    } };

    try std.testing.expect(!runtime.hasToolWithAccess("mcp_fixture_echo", access));
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.validateToolArgumentsByNameWithAccess(
            alloc,
            "mcp_fixture_echo",
            "{}",
            access,
        ),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.toolSchemaJsonByNameWithAccess(
            alloc,
            "mcp_fixture_echo",
            .{},
            .{},
            access,
            null,
        ),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.callToolByNameWithOptions(
            alloc,
            "mcp_fixture_echo",
            "{}",
            1024,
            .{ .access = access },
        ),
    );

    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.searchTools(alloc, "echo", 5, .{}, .{}, access),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.listResources(alloc, "fixture", false, null, access),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.listResources(alloc, "fixture", true, null, access),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.readResource(
            alloc,
            "fixture",
            "memory://cached",
            .{ .access = access },
        ),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.listPrompts(alloc, "fixture", null, access),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.getPrompt(
            alloc,
            "fixture",
            "cached",
            "{}",
            .{ .access = access },
        ),
    );
    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.completePromptArgument(
            alloc,
            "fixture",
            "cached",
            .{ .name = "argument", .value = "" },
            &.{},
            null,
            access,
        ),
    );
}

test "MCP tool call rejects mismatched expected runtime generation before lookup" {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    try std.testing.expectError(
        error.McpAuthorityChanged,
        runtime.callToolByNameWithOptions(
            std.testing.allocator,
            "mcp_fixture_echo",
            "{}",
            1024,
            .{ .expected_runtime_generation = runtime.generation + 1 },
        ),
    );
}

test "MCP access snapshot excludes servers whose tools are denied" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "allowed"),
        .command = try alloc.dupe(u8, "cmd"),
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "denied"),
        .command = try alloc.dupe(u8, "cmd"),
    });
    for (runtime.servers.items) |server| server.state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);
    try parseAndStoreTools(alloc, runtime.servers.items[1], .{}, response, &used);

    var denied_rules = [_]types.PermissionRule{.{
        .permission = @constCast("mcp_denied_echo"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    var view = try runtime.snapshotAccessView(
        alloc,
        "child",
        "parent",
        .{ .rules = &denied_rules },
        true,
    );
    defer view.deinit(alloc);

    try std.testing.expect(view.server("allowed") != null);
    try std.testing.expect(view.tool("mcp_allowed_echo") != null);
    try std.testing.expect(view.server("denied") == null);
    try std.testing.expect(view.tool("mcp_denied_echo") == null);
    try std.testing.expectEqual(
        access_policy.Decision.reject_server,
        access_policy.authorize(view, view, .{ .feature_server = "denied" }),
    );
}

test "MCP access snapshot admits feature-only servers independently of tools" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "features"),
        .command = try alloc.dupe(u8, "cmd"),
    });
    const server = runtime.servers.items[0];
    server.state.store(.ready, .release);
    server.capabilities = .{
        .resources = true,
        .prompts = true,
        .completion = true,
    };

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    try parseAndStoreTools(
        alloc,
        server,
        .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
    ,
        &used,
    );

    var admitted = try runtime.snapshotAccessView(
        alloc,
        "child",
        "parent",
        .{},
        true,
    );
    defer admitted.deinit(alloc);
    try std.testing.expect(admitted.server("features") != null);
    try std.testing.expectEqual(@as(usize, 0), admitted.tools.len);
    try std.testing.expectEqual(
        access_policy.Decision.allow,
        access_policy.authorize(admitted, admitted, .{ .feature_server = "features" }),
    );
    try std.testing.expectEqual(
        access_policy.Decision.reject_tool,
        access_policy.authorize(admitted, admitted, .{ .tool_server = "features" }),
    );

    server.tool_catalog.available = false;
    var independent = try runtime.snapshotAccessView(
        alloc,
        "child",
        "parent",
        .{},
        true,
    );
    defer independent.deinit(alloc);
    try std.testing.expect(independent.server("features") != null);
    try std.testing.expectEqual(@as(usize, 0), independent.tools.len);

    var hidden = try runtime.snapshotAccessView(
        alloc,
        "child",
        "parent",
        .{},
        false,
    );
    defer hidden.deinit(alloc);
    try std.testing.expect(hidden.server("features") == null);
    try std.testing.expectEqual(@as(usize, 0), hidden.tools.len);
}

test "MCP access snapshot releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAccessSnapshotAllocationFailures,
        .{},
    );
}

fn checkAccessSnapshotAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try std.testing.allocator.dupe(u8, "fixture"),
        .command = try std.testing.allocator.dupe(u8, "cmd"),
    });
    runtime.servers.items[0].state.store(.ready, .release);
    var used = tool_names.Registry.init(std.testing.allocator);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(
        std.testing.allocator,
        runtime.servers.items[0],
        .{},
        response,
        &used,
    );
    var view = try runtime.snapshotAccessView(alloc, "child", "parent", .{}, true);
    defer view.deinit(alloc);
}

test "MCP transport precommit rejects MCP view and full authority changes" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .command = try alloc.dupe(u8, "cmd"),
    });
    runtime.servers.items[0].state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);

    var captured = try runtime.snapshotAccessView(alloc, "child", "parent", .{}, true);
    defer captured.deinit(alloc);
    var live = try captured.clone(alloc);
    defer live.deinit(alloc);
    const LiveProvider = struct {
        view: *const access_policy.View,
        action_authority_generation: u64,

        fn resolve(raw: *anyopaque, provider_alloc: Allocator) !tool_mcp_runtime.ResolvedLiveView {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const view = try self.view.clone(provider_alloc);
            return .{
                .authority_generation = access_policy.authorityGeneration(view),
                .action_authority_generation = self.action_authority_generation,
                .view = view,
            };
        }
    };
    var provider = LiveProvider{
        .view = &live,
        .action_authority_generation = 41,
    };
    const access = tool_mcp_runtime.Access{ .scoped = .{
        .captured = &captured,
        .admission_authority_generation = access_policy.authorityGeneration(captured),
        .live = .{
            .context = @ptrCast(&provider),
            .resolve_fn = LiveProvider.resolve,
        },
        .action_authority_generation = 41,
    } };

    var operation = try OperationAccessGuard.init(alloc, access, runtime.generation);
    defer operation.deinit();
    try operation.authorize(.{ .tool = "mcp_fixture_echo" });

    live.servers[0].auth_generation += 1;
    var final_guard = ServerAccessPrecommit{
        .authority = .{ .alloc = runtime.alloc, .runtime_generation = runtime.generation, .access = access, .target = .{ .tool_server = "fixture" } },
        .cancel_flag = runtime.servers.items[0].cancellation(),
    };
    var precommit = final_guard.transport();
    try std.testing.expectError(error.McpAuthorityChanged, precommit.acquire());
    try std.testing.expect(!precommit.acquired);

    live.servers[0].auth_generation -= 1;
    provider.action_authority_generation = 42;
    var action_guard = ServerAccessPrecommit{
        .authority = .{ .alloc = runtime.alloc, .runtime_generation = runtime.generation, .access = access, .target = .{ .tool_server = "fixture" } },
        .cancel_flag = runtime.servers.items[0].cancellation(),
    };
    var action_precommit = action_guard.transport();
    try std.testing.expectError(error.McpAuthorityChanged, action_precommit.acquire());
    try std.testing.expect(!action_precommit.acquired);
}

test "scoped MCP authentication rendering excludes denied servers" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "allowed"),
        .command = try alloc.dupe(u8, "cmd"),
    });
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "denied"),
        .command = try alloc.dupe(u8, "cmd"),
        .bearer_token_env = try alloc.dupe(u8, "DENIED_SECRET_ENV"),
    });
    for (runtime.servers.items) |server| server.state.store(.ready, .release);

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);
    try parseAndStoreTools(alloc, runtime.servers.items[1], .{}, response, &used);
    var denied_rules = [_]types.PermissionRule{.{
        .permission = @constCast("mcp_denied_echo"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    var captured = try runtime.snapshotAccessView(
        alloc,
        "child",
        "parent",
        .{ .rules = &denied_rules },
        true,
    );
    defer captured.deinit(alloc);
    runtime.servers.items[1].state.store(.failed, .release);

    const LiveProvider = struct {
        view: *const access_policy.View,

        fn resolve(raw: *anyopaque, provider_alloc: Allocator) !tool_mcp_runtime.ResolvedLiveView {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const view = try self.view.clone(provider_alloc);
            return .{
                .authority_generation = access_policy.authorityGeneration(view),
                .view = view,
            };
        }
    };
    var provider = LiveProvider{ .view = &captured };
    const access = tool_mcp_runtime.Access{ .scoped = .{
        .captured = &captured,
        .admission_authority_generation = access_policy.authorityGeneration(captured),
        .live = .{
            .context = @ptrCast(&provider),
            .resolve_fn = LiveProvider.resolve,
        },
    } };
    var scoped = try OperationAccessGuard.init(alloc, access, runtime.generation);
    defer scoped.deinit();
    try std.testing.expect(try renderAuthenticationRequired(
        alloc,
        runtime.servers.items,
        &scoped,
        "denied",
    ) == null);

    var root = try OperationAccessGuard.init(alloc, .unrestricted, runtime.generation);
    defer root.deinit();
    const rendered = (try renderAuthenticationRequired(
        alloc,
        runtime.servers.items,
        &root,
        "denied",
    )).?;
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "denied") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "DENIED_SECRET_ENV") != null);
}

test "MCP server instructions are captured from initialize and exposed only when present" {
    const alloc = std.testing.allocator;
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    var server = McpServer{ .config = .{ .name = try alloc.dupe(u8, "github"), .command = try alloc.dupe(u8, "cmd") } };
    defer server.deinit(alloc);

    const init_response =
        \\{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2024-11-05","instructions":"Use this server only for GitHub issue workflows. TOKEN=github_pat_1234567890abcdef"}}
    ;
    try server_transport.parseAndStoreServerInstructions(alloc, &server, init_response);
    try std.testing.expect(server.instructions != null);
    try std.testing.expect(std.mem.find(u8, server.instructions.?, "GitHub issue workflows") != null);
    try std.testing.expect(std.mem.find(u8, server.instructions.?, "github_pat_1234567890abcdef") == null);

    const tools_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"create_issue","description":"Create issue","inputSchema":{"type":"object","properties":{}}},{"name":"close_issue","description":"Close issue","inputSchema":{"type":"object","properties":{}}}]}}
    ;
    try parseAndStoreTools(alloc, &server, .{}, tools_response, &used);
    try std.testing.expectEqual(@as(usize, 2), server.tool_catalog.tools.items.len);
    server.state.store(.ready, .release);

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.appendOwnedServer(server);
    server = .{ .config = .{ .name = try alloc.dupe(u8, "moved"), .command = try alloc.dupe(u8, "moved") } };

    var results = try runtime.searchTools(alloc, "github issue", 5, .{}, .{}, .unrestricted);
    defer results.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, results.model_output, "server_instructions") == null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "GitHub issue workflows") == null);

    var instruction_results = try runtime.searchTools(alloc, "issue workflows", 5, .{}, .{}, .unrestricted);
    defer instruction_results.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, instruction_results.model_output, "mcp_github_create_issue") != null);
    try std.testing.expect(std.mem.find(u8, instruction_results.model_output, "mcp_github_close_issue") != null);

    var schema_result = (try runtime.toolSchemaJsonByName(alloc, "mcp_github_create_issue", .{}, .{})) orelse return error.TestExpectedEqual;
    defer schema_result.deinit(alloc);
    const schema = switch (schema_result) {
        .selected => |payload| payload.model_output,
        .rejected => return error.TestExpectedEqual,
    };
    try std.testing.expect(std.mem.find(u8, schema, "Server instructions:") != null);
}

test "MCP exact selection returns one executable schema by prefixed name" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    try runtime.addServer(.{ .name = try alloc.dupe(u8, "fs"), .command = try alloc.dupe(u8, "cmd") });
    runtime.servers.items[0].state.store(.ready, .release);
    runtime.servers.items[0].instructions = try alloc.dupe(u8, ("i" ** 1500) ++ "instruction tail");

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"read","description":"Read a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);

    var schema_result = (try runtime.toolSchemaJsonByName(alloc, "mcp_fs_read", .{}, .{})) orelse return error.TestExpectedEqual;
    defer schema_result.deinit(alloc);
    const schema = switch (schema_result) {
        .selected => |payload| payload.model_output,
        .rejected => return error.TestExpectedEqual,
    };

    try std.testing.expect(std.mem.find(u8, schema, "\"name\":\"mcp_fs_read\"") != null);
    try std.testing.expect(std.mem.find(u8, schema, "\"inputSchema\"") != null);
    try std.testing.expect(std.mem.find(u8, schema, "instruction tail") != null);
    try std.testing.expect(std.mem.find(u8, schema, model_tool_schema.truncation_marker) == null);
    try std.testing.expect((try runtime.toolSchemaJsonByName(alloc, "mcp_missing", .{}, .{})) == null);
}

test "MCP selection truncates instructions and rejects an oversized schema atomically" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{ .name = try alloc.dupe(u8, "docs"), .command = try alloc.dupe(u8, "cmd") });
    runtime.servers.items[0].state.store(.ready, .release);
    runtime.servers.items[0].instructions = try alloc.dupe(u8, "first line\nsecond line\nthird line");

    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"lookup","description":"Lookup docs","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"An exact query that must stay intact"}},"required":["query"]}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response, &used);

    var limits = context_limits.Values{};
    limits.mcp_server_instructions_bytes = .{ .value = .{ .bytes = 11 }, .source = .user_workspace };
    var schema_result = (try runtime.toolSchemaJsonByName(alloc, "mcp_docs_lookup", .{}, limits)) orelse return error.TestExpectedEqual;
    defer schema_result.deinit(alloc);
    const schema = switch (schema_result) {
        .selected => |payload| payload.model_output,
        .rejected => return error.TestExpectedEqual,
    };
    try std.testing.expect(std.mem.find(u8, schema, "first line&#x0a;") != null);
    try std.testing.expect(std.mem.find(u8, schema, "second line") == null);
    try std.testing.expect(std.mem.find(u8, schema, "mcp_server_instructions_bytes") != null);
    try std.testing.expect(std.mem.find(u8, schema, "An exact query that must stay intact") != null);

    limits.mcp_selected_schema_bytes = .{ .value = .{ .bytes = schema.len - 1 }, .source = .command_line };
    var rejected_result = (try runtime.toolSchemaJsonByName(alloc, "mcp_docs_lookup", .{}, limits)) orelse return error.TestExpectedEqual;
    defer rejected_result.deinit(alloc);
    const rejected = switch (rejected_result) {
        .rejected => |payload| payload.model_output,
        .selected => return error.TestExpectedEqual,
    };
    try std.testing.expect(std.mem.find(u8, rejected, "context_limit_rejection") != null);
    try std.testing.expect(std.mem.find(u8, rejected, "inputSchema") == null);
    try std.testing.expect(std.mem.find(u8, rejected, "source\":\"command line") != null);
    try std.testing.expect(try std.json.validate(alloc, rejected));
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rejected, .{});
    defer parsed.deinit();
    const rejection = parsed.value.object.get("context_limit_rejection") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("rejected", rejection.object.get("action").?.string);
}

test "MCP metadata caps encoded descriptions and preserves ready-server tool order" {
    const alloc = std.testing.allocator;
    const bounded = try boundedEncodedScalar(alloc, "<x", 4);
    defer alloc.free(bounded.text);
    try std.testing.expectEqual(@as(usize, 5), bounded.observed_bytes);
    try std.testing.expectEqualStrings("&lt;", bounded.text);

    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{ .name = try alloc.dupe(u8, "alpha"), .command = try alloc.dupe(u8, "cmd") });
    try runtime.addServer(.{ .name = try alloc.dupe(u8, "beta"), .command = try alloc.dupe(u8, "cmd") });
    runtime.servers.items[0].state.store(.ready, .release);
    runtime.servers.items[1].state.store(.ready, .release);
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();
    const response_a =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"one","description":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","inputSchema":{"type":"object","properties":{"secret":{"type":"string"}}}},{"name":"two","description":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","inputSchema":{"type":"object"}}]}}
    ;
    const response_b =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"three","description":"cccccccccccccccccccccccccccccccccccccccc","inputSchema":{"type":"object"}},{"name":"four","description":"dddddddddddddddddddddddddddddddddddddddd","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(alloc, runtime.servers.items[0], .{}, response_a, &used);
    try parseAndStoreTools(alloc, runtime.servers.items[1], .{}, response_b, &used);

    var limits = context_limits.Values{};
    limits.mcp_description_bytes = .{ .value = .{ .bytes = 12 }, .source = .user_global };
    limits.mcp_search_result_bytes = .{ .value = .{ .bytes = 1024 }, .source = .command_line };
    var results = try runtime.searchTools(alloc, "", 10, .{}, limits, .unrestricted);
    defer results.deinit(alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, results.model_output, .{});
    defer parsed.deinit();

    const expected = [_][]const u8{ "mcp_alpha_one", "mcp_alpha_two", "mcp_beta_three", "mcp_beta_four" };
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expect(tools.len > 0 and tools.len < expected.len);
    for (tools, 0..) |tool, index| {
        try std.testing.expectEqualStrings(expected[index], tool.object.get("name").?.string);
        try std.testing.expect(tool.object.get("inputSchema") == null);
        try std.testing.expect(tool.object.get("context_limit") != null);
    }
    try std.testing.expectEqual(@as(i64, @intCast(expected.len - tools.len)), parsed.value.object.get("context_limit").?.object.get("omitted_count").?.integer);
    try std.testing.expect(results.notice != null);
    for (expected[tools.len..]) |name| try std.testing.expect(std.mem.find(u8, results.notice.?, name) != null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "omitted_names") == null);
    try std.testing.expect(std.mem.find(u8, results.model_output, "secret") == null);

    limits.mcp_search_result_bytes = .{ .value = .{ .bytes = 10 }, .source = .command_line };
    var tiny = try runtime.searchTools(alloc, "", 10, .{}, limits, .unrestricted);
    defer tiny.deinit(alloc);
    var tiny_parsed = try std.json.parseFromSlice(std.json.Value, alloc, tiny.model_output, .{});
    defer tiny_parsed.deinit();
    try std.testing.expect(tiny.model_output.len > limits.mcp_search_result_bytes.effectiveBytes());
    try std.testing.expectEqual(@as(i64, expected.len), tiny_parsed.value.object.get("context_limit").?.object.get("omitted_count").?.integer);
    try std.testing.expect(tiny.notice != null);
}

test "runtime rejects source and workspace admission mismatches before installation" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    var missing: McpServerConfig = .{
        .name = try alloc.dupe(u8, "missing"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "cmd"),
    };
    try std.testing.expectError(error.McpConfigAdmissionMismatch, runtime.addServer(missing));
    missing.deinit(alloc);

    var synthetic: McpServerConfig = .{
        .name = try alloc.dupe(u8, "synthetic"),
        .source = .profile,
        .scope = .profile,
        .command = try alloc.dupe(u8, "cmd"),
        .workspace_admission = .approved,
    };
    try std.testing.expectError(error.McpConfigAdmissionMismatch, runtime.addServer(synthetic));
    synthetic.deinit(alloc);
}

test "interactive authentication requires approved workspace admission" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();

    for ([_]mcp_contract.WorkspaceAdmission{ .pending, .rejected, .approved }) |admission| {
        const name = @tagName(admission);
        try runtime.addServer(.{
            .name = try alloc.dupe(u8, name),
            .source = .workspace,
            .scope = .workspace,
            .transport = .http,
            .url = try alloc.dupe(u8, "https://example.test/mcp"),
            .workspace_admission = admission,
        });
    }

    try std.testing.expectError(
        error.McpWorkspaceApprovalRequired,
        runtime.validateAuthenticationServer("pending"),
    );
    try std.testing.expectError(
        error.McpWorkspaceApprovalRequired,
        runtime.validateAuthenticationServer("rejected"),
    );
    try runtime.validateAuthenticationServer("approved");
    try std.testing.expectError(
        error.McpWorkspaceApprovalRequired,
        runtime.listResources(
            alloc,
            "pending",
            false,
            null,
            .unrestricted,
        ),
    );
    try std.testing.expectError(
        error.McpWorkspaceApprovalRequired,
        runtime.listPrompts(
            alloc,
            "rejected",
            null,
            .unrestricted,
        ),
    );
}

test "tool schema uses prefixed name and call request uses raw name" {
    const alloc = std.testing.allocator;
    var used = tool_names.Registry.init(alloc);
    defer used.deinit();

    var server = McpServer{ .config = .{ .name = try alloc.dupe(u8, "a/b"), .command = try alloc.dupe(u8, "cmd") } };
    defer server.deinit(alloc);

    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"read/file","description":"Read","inputSchema":{"type":"object","properties":{}}}]}}
    ;
    try parseAndStoreTools(alloc, &server, .{}, response, &used);

    const tool = server.tool_catalog.tools.items[0];
    try std.testing.expectEqualStrings("read/file", tool.original_name);
    try std.testing.expectEqualStrings("mcp_a_b_read_file", tool.prefixed_name);
    var projected = try selected_schema.project(alloc, tool, null, .{});
    defer projected.deinit(alloc);
    const schema = projected.selected.model_output;
    try std.testing.expect(std.mem.find(u8, schema, "\"name\":\"mcp_a_b_read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, schema, "read/file") == null);

    const request = try buildToolCallRequest(alloc, 9, tool.original_name, "{\"path\":\"/tmp/a\"}");
    defer alloc.free(request);
    try std.testing.expect(std.mem.find(u8, request, "\"name\":\"read/file\"") != null);
    try std.testing.expect(std.mem.find(u8, request, "\"arguments\":{\"path\":\"/tmp/a\"}") != null);
}

test "tool call request preserves raw name and already-compact arguments" {
    const alloc = std.testing.allocator;
    const request = try buildToolCallRequest(alloc, 42, "raw/tool", "{\"x\":1,\"nested\":{\"ok\":true}}");
    defer alloc.free(request);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"raw/tool\",\"arguments\":{\"x\":1,\"nested\":{\"ok\":true}}}}",
        request,
    );
}

test "tool call request compacts pretty-printed arguments into a single line" {
    const alloc = std.testing.allocator;
    const pretty =
        \\{
        \\  "path": "/tmp/a",
        \\  "note": "line one\nline two"
        \\}
    ;
    const request = try buildToolCallRequest(alloc, 7, "raw/tool", pretty);
    defer alloc.free(request);

    // The frame must not contain any raw newline; the escaped "\n" inside the
    // string value must be preserved.
    try std.testing.expect(std.mem.find(u8, request, "\n") == null);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"raw/tool\",\"arguments\":{\"path\":\"/tmp/a\",\"note\":\"line one\\nline two\"}}}",
        request,
    );
}

test "tool binding permits token renewal but fences reauthentication and changed definitions" {
    const alloc = std.testing.allocator;
    const template = mcp_auth.Credentials{
        .endpoint = @constCast("https://example.test/mcp"),
        .resource = @constCast("https://example.test/mcp"),
        .issuer = @constCast("https://auth.example.test"),
        .client_id = @constCast("client"),
        .access_token = @constCast("first-token"),
        .refresh_token = @constCast("refresh-token"),
        .scope = @constCast("tools.read"),
        .token_type = @constCast("Bearer"),
        .token_endpoint_auth_method = @constCast("none"),
        .expires_at_ms = 1,
        .authorization_endpoint = @constCast("https://auth.example.test/authorize"),
        .token_endpoint = @constCast("https://auth.example.test/token"),
    };
    var server = McpServer{ .config = .{ .name = "fixture" } };
    defer if (server.auth_credentials) |*credentials| credentials.deinit(alloc);
    var credentials = try template.clone(alloc);
    server_auth.installAuthCredentials(alloc, &server, &credentials);
    const tool = McpTool{ .original_name = @constCast("echo"), .prefixed_name = @constCast("mcp_fixture_echo"), .description = @constCast("Echo"), .input_schema_json = @constCast("{\"type\":\"object\"}"), .tags = &.{} };
    const advertised = bindingForSnapshot(1, &server, tool);
    var renewal_template = template;
    renewal_template.access_token = @constCast("renewed-token");
    var renewal = try renewal_template.clone(alloc);
    server_auth.installRefreshedCredentials(alloc, &server, &renewal);
    server.connection_generation += 1;
    server.catalog_generation += 1;
    const renewed = bindingForSnapshot(1, &server, tool);
    try std.testing.expect(renewed.auth_generation != advertised.auth_generation);
    try std.testing.expect(advertised.sameDefinition(renewed));
    var changed = tool;
    changed.input_schema_json = @constCast("{\"type\":\"object\",\"required\":[\"text\"]}");
    try std.testing.expect(!advertised.sameDefinition(bindingForSnapshot(1, &server, changed)));
    var reauthenticated = try template.clone(alloc);
    server_auth.installAuthCredentials(alloc, &server, &reauthenticated);
    try std.testing.expect(!advertised.sameDefinition(bindingForSnapshot(1, &server, tool)));
    const before_scope_change = bindingForSnapshot(1, &server, tool);
    renewal_template.scope = @constCast("tools.write");
    var different_scope = try renewal_template.clone(alloc);
    server_auth.installRefreshedCredentials(alloc, &server, &different_scope);
    try std.testing.expect(!before_scope_change.sameDefinition(bindingForSnapshot(1, &server, tool)));
}

test "configuration reload retains a healthy process while replacing failed optional servers" {
    const alloc = std.testing.allocator;
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"server/discover"'*) printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}' ;;
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"echo","inputSchema":{"type":"object"}}],"ttlMs":60000}}' ;;
        \\    *'"method":"tools/call"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"text","text":"same process"}]}}' ;;
        \\  esac
        \\done
    ;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "healthy", script));
    runtime.connectAll(.{});
    const healthy = runtime.servers.items[0];
    const generation = healthy.connection_generation;
    try std.testing.expectEqual(ServerState.ready, healthy.state.load(.acquire));
    var next = McpRuntime.init(alloc);
    defer next.deinit();
    try next.addServer(try shellMcpConfigForTest(alloc, "failed", "exit 1"));
    try next.addServer(try shellMcpConfigForTest(alloc, "healthy", script));
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectEqual(@as(?[]u8, null), try runtime.reconcile(&next, &cancel, true));
    try std.testing.expect(runtime.servers.items[1] == healthy);
    try std.testing.expectEqual(generation, healthy.connection_generation);
    try std.testing.expectEqual(ServerState.failed, runtime.servers.items[0].state.load(.acquire));
    const old_binding = runtime.bindingForTool(healthy, healthy.tool_catalog.tools.items[0]);
    var result = (try runtime.callToolByName(alloc, "mcp_healthy_echo", "{}", 4096)).?;
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, result.model_output, "same process") != null);
    try std.testing.expectEqual(@as(usize, 1), next.servers.items.len);
    var changed = McpRuntime.init(alloc);
    defer changed.deinit();
    try changed.addServer(try shellMcpConfigForTest(alloc, "healthy", script ++ "\n# changed configuration"));
    try std.testing.expectEqual(@as(?[]u8, null), try runtime.reconcile(&changed, &cancel, true));
    try std.testing.expect(runtime.servers.items[0].connection_generation != generation);
    try std.testing.expectEqualStrings("mcp_healthy_echo", runtime.servers.items[0].tool_catalog.tools.items[0].prefixed_name);
    try std.testing.expectError(error.McpAdvertisedToolChanged, runtime.callToolByNameWithOptions(
        alloc,
        "mcp_healthy_echo",
        "{}",
        4096,
        .{ .expected_binding = old_binding },
    ));
}

test "configuration reload rejects required failure and cancellation without retiring the current server" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(try shellMcpConfigForTest(alloc, "current", "exit 1"));
    const current = runtime.servers.items[0];
    var next = McpRuntime.init(alloc);
    defer next.deinit();
    var config = try shellMcpConfigForTest(alloc, "required", "exit 1");
    config.required = true;
    config.enabled = false;
    try next.addServer(config);
    var cancel = std.atomic.Value(bool).init(false);
    const failure = (try runtime.reconcile(&next, &cancel, true)).?;
    defer alloc.free(failure);
    try std.testing.expect(std.mem.find(u8, failure, "required") != null);
    try std.testing.expect(runtime.servers.items[0] == current);
    try std.testing.expect(!current.lifetime.retiring.load(.acquire));
    cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, runtime.reconcile(null, &cancel, false));
    try std.testing.expect(runtime.servers.items[0] == current);
    cancel.store(false, .release);
    try std.testing.expectEqual(@as(?[]u8, null), try runtime.reconcile(null, &cancel, false));
    try std.testing.expectEqual(@as(usize, 0), runtime.servers.items.len);
}

fn checkConfigurationReloadAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    {
        var config = try shellMcpConfigForTest(alloc, "previous", "exit 1");
        errdefer config.deinit(alloc);
        config.enabled = false;
        try runtime.addServer(config);
    }
    var candidate = McpRuntime.init(alloc);
    defer candidate.deinit();
    {
        var config = try shellMcpConfigForTest(alloc, "candidate", "exit 1");
        errdefer config.deinit(alloc);
        config.enabled = false;
        try candidate.addServer(config);
    }
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectEqual(@as(?[]u8, null), try runtime.reconcile(&candidate, &cancel, false));
}

test "configuration reload cleans up every allocation failure without opening a transport" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkConfigurationReloadAllocationFailures, .{});
}

const boundedEncodedScalar = tool_search.boundedEncodedScalar;
const renderAuthenticationRequired = tool_search.renderAuthenticationRequired;

const digestResources = feature_catalog_runtime.digestResources;

const digestResourceTemplates = feature_catalog_runtime.digestResourceTemplates;

const digestPrompts = feature_catalog_runtime.digestPrompts;

const replaceOwnedCursor = feature_catalog_runtime.replaceOwnedCursor;

const FetchedResourceRead = feature_operations.FetchedResourceRead;

const mcpResponseFrameCap = tool_operations.Operations.mcpResponseFrameCap;

const terminalOutcomeForCallStatus = tool_operations.Operations.terminalOutcomeForCallStatus;

const handleMcpResponseFrameTooLarge = tool_operations.Operations.handleMcpResponseFrameTooLarge;

const LegacyElicitationContext = legacy_elicitation_runtime.Context;

test "unrelated server timeouts do not shorten a named tool operation" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    var target = try shellMcpConfigForTest(alloc, "target", "exit 0");
    target.operation_timeout_ms = 5000;
    try runtime.addServer(target);
    const alias = try runtime.tool_aliases.name(alloc, .{}, "target", "echo");
    defer alloc.free(alias);
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const original = runtime.catalogOperationDeadline(alias, started);
    var unrelated = try shellMcpConfigForTest(alloc, "unrelated", "exit 0");
    unrelated.operation_timeout_ms = 1;
    try runtime.addServer(unrelated);
    try std.testing.expectEqual(original, runtime.catalogOperationDeadline(alias, started));
}

test "connection retirement waits for the admitted transport commit" {
    const alloc = std.testing.allocator;
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    var config = try shellMcpConfigForTest(alloc, "fixture", "exit 0");
    config.restart_limit = 0;
    try runtime.addServer(config);
    const server = runtime.servers.items[0];
    server.state.store(.ready, .release);
    try parseAndStoreTools(alloc, server, .{},
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}
    , &runtime.tool_aliases);
    var snapshot = try ToolCallSnapshot.init(alloc, server, &server.tool_catalog.tools.items[0]);
    defer snapshot.deinit(alloc);
    var guard = tool_snapshot.CommitGuard{
        .alloc = alloc,
        .runtime_generation = runtime.generation,
        .catalog_mutex = &runtime.catalog_mutex,
        .server = server,
        .snapshot = &snapshot,
        .deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromSeconds(1) }),
        .cancel_flag = null,
    };
    var precommit = guard.transport();
    try precommit.acquire();
    var held = true;
    defer if (held) precommit.release();
    const failed_generation: u64 = 1;
    try std.testing.expectError(error.McpRequestTimedOut, runtime.lifecycle().recoverServer(
        server,
        failed_generation,
        std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(10) }),
        null,
        null,
    ));
    try std.testing.expect(tool_snapshot.current(server, &snapshot));
    precommit.release();
    held = false;
    try std.testing.expectError(error.McpRestartLimitReached, runtime.lifecycle().recoverServer(
        server,
        failed_generation,
        std.Io.Clock.Timestamp.fromNow(std.testing.io, .{ .clock = .awake, .raw = .fromSeconds(1) }),
        null,
        null,
    ));
    try std.testing.expect(!tool_snapshot.current(server, &snapshot));
}
