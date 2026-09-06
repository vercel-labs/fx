const std = @import("std");
const io_mod = @import("../shared/io.zig");
const mcp_contract = @import("mcp_contract.zig");
const server_auth = @import("server_auth.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const feature_catalog = @import("feature_catalog.zig");
const tool_subscription = @import("tool_subscription.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const resources_feature = @import("features/resources.zig");
const prompts_feature = @import("features/prompts.zig");
const controlled_lock = @import("controlled_lock.zig");
const Allocator = std.mem.Allocator;
const McpServer = @import("server_connection.zig").Server;
const authorizeLiveAccess = @import("operation_authority.zig").authorizeLiveAccess;
const lockMutexUntil = controlled_lock.mutexUntil;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const checkOperationControl = controlled_lock.checkOperation;

pub const Kind = enum {
    resource,
    prompt,
    resource_template,
};

pub const Snapshot = struct {
    server_name: []u8,
    identity: []u8,
    requested_uri: ?[]u8 = null,
    kind: Kind,
    auth_partition: catalog_freshness.AuthPartition,
    connection_generation: u64,
    catalog_generation: u64,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.identity);
        if (self.requested_uri) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const CommitGuard = struct {
    alloc: Allocator,
    runtime_generation: u64,
    catalog_mutex: *std.Io.RwLock,
    server: *McpServer,
    snapshot: *const Snapshot,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access = .unrestricted,
    live_view: ?tool_mcp_runtime.ResolvedLiveView = null,
    subscription: ?*tool_subscription.State = null,
    subscription_locked: bool = false,
    catalog_commit_locked: bool = false,
    auth_locked: bool = false,

    pub fn transport(self: *CommitGuard) mcp_contract.TransportPrecommit {
        return .{ .context = self, .acquire_callback = acquireCallback, .release_callback = releaseCallback };
    }

    fn acquireCallback(raw: *anyopaque) !void {
        const self: *CommitGuard = @ptrCast(@alignCast(raw));
        errdefer self.release();
        try checkOperationControl(io_mod.getIo(), self.deadline, self.cancel_flag);
        if (self.server.lifetime.retiring.load(.acquire)) return error.Cancelled;
        self.live_view = try authorizeLiveAccess(
            self.alloc,
            self.access,
            self.runtime_generation,
            .{ .feature_server = self.snapshot.server_name },
        );
        try lockMutexUntil(&self.server.catalog_commit_lock, self.deadline, self.cancel_flag);
        self.catalog_commit_locked = true;
        if (self.server.tool_subscription) |subscription| {
            const feature: tool_subscription.FeatureInvalidation = switch (self.snapshot.kind) {
                .resource => .resource_read,
                .resource_template => .resource_templates,
                .prompt => .prompts,
            };
            if (!subscription.lockFeatureCommitIfCurrent(feature)) {
                return error.McpFeatureCatalogChanged;
            }
            self.subscription = subscription;
            self.subscription_locked = true;
        }
        const private_remote = self.snapshot.auth_partition.private_auth_identity != null and
            self.server.config.transport != .stdio;
        if (private_remote) {
            try lockMutexUntil(&self.server.auth_lock, self.deadline, self.cancel_flag);
            self.auth_locked = true;
        }
        try lockRwSharedUntil(self.catalog_mutex, self.deadline, self.cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        if (!featureSnapshotCurrent(self.server, self.snapshot)) return error.McpFeatureCatalogChanged;
        if (private_remote) {
            const active_key = catalog_freshness.authPartition(.private, try server_auth.currentAuthIdentity(self.alloc, self.server));
            if (!self.snapshot.auth_partition.eql(active_key)) return error.McpFeatureCatalogChanged;
        }
    }

    fn releaseCallback(raw: *anyopaque) void {
        const self: *CommitGuard = @ptrCast(@alignCast(raw));
        self.release();
    }

    fn release(self: *CommitGuard) void {
        if (self.live_view) |*view| {
            view.deinit(self.alloc);
            self.live_view = null;
        }
        if (self.auth_locked) {
            self.server.auth_lock.unlock(io_mod.getIo());
            self.auth_locked = false;
        }
        if (self.subscription_locked) {
            self.subscription.?.unlockCommit();
            self.subscription_locked = false;
            self.subscription = null;
        }
        if (self.catalog_commit_locked) {
            self.server.catalog_commit_lock.unlock(io_mod.getIo());
            self.catalog_commit_locked = false;
        }
    }
};

pub fn featureSnapshotCurrent(server: *const McpServer, snapshot: *const Snapshot) bool {
    if (!std.mem.eql(u8, server.config.name, snapshot.server_name) or
        server.connection_generation != snapshot.connection_generation)
    {
        return false;
    }
    return switch (snapshot.kind) {
        .resource => current: {
            if (!feature_catalog.featureCatalogAvailable(server, .resources)) break :current false;
            const metadata = server.resource_catalog.metadata orelse break :current false;
            if (metadata.catalog_generation != snapshot.catalog_generation or !metadata.key.eql(snapshot.auth_partition)) break :current false;
            const catalog = server.resource_catalog.catalog orelse break :current false;
            break :current catalog.containsUri(snapshot.identity);
        },
        .resource_template => current: {
            if (!feature_catalog.featureCatalogAvailable(server, .resource_templates)) break :current false;
            const metadata = server.resource_template_catalog.metadata orelse break :current false;
            if (metadata.catalog_generation != snapshot.catalog_generation or !metadata.key.eql(snapshot.auth_partition)) break :current false;
            const catalog = server.resource_template_catalog.catalog orelse break :current false;
            for (catalog.items) |template| {
                if (!std.mem.eql(u8, template.uri_template, snapshot.identity)) continue;
                if (snapshot.requested_uri) |uri| {
                    break :current resources_feature.templateMayResolve(template.uri_template, uri);
                }
                break :current true;
            }
            break :current false;
        },
        .prompt => current: {
            if (!feature_catalog.featureCatalogAvailable(server, .prompts)) break :current false;
            const metadata = server.prompt_catalog.metadata orelse break :current false;
            if (metadata.catalog_generation != snapshot.catalog_generation or !metadata.key.eql(snapshot.auth_partition)) break :current false;
            const catalog = server.prompt_catalog.catalog orelse break :current false;
            break :current catalog.find(snapshot.identity) != null;
        },
    };
}

pub fn snapshotConcreteResourceIdentity(
    catalog_mutex: *std.Io.RwLock,
    alloc: Allocator,
    server: *McpServer,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !?Snapshot {
    try lockRwSharedUntil(catalog_mutex, deadline, cancel_flag);
    defer catalog_mutex.unlockShared(io_mod.getIo());
    if (!feature_catalog.featureCatalogAvailable(server, .resources)) return error.McpResourceCatalogUnavailable;
    if (server.resource_catalog.catalog) |catalog| {
        if (catalog.containsUri(uri)) {
            const metadata = server.resource_catalog.metadata orelse return error.McpResourceCatalogUnavailable;
            return try cloneFeatureSnapshot(alloc, server, .resource, uri, null, metadata);
        }
    }
    return null;
}

pub fn snapshotResourceIdentityWithTemplates(
    catalog_mutex: *std.Io.RwLock,
    alloc: Allocator,
    server: *McpServer,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !Snapshot {
    try lockRwSharedUntil(catalog_mutex, deadline, cancel_flag);
    defer catalog_mutex.unlockShared(io_mod.getIo());
    if (!feature_catalog.featureCatalogAvailable(server, .resources)) return error.McpResourceCatalogUnavailable;
    if (server.resource_catalog.catalog) |catalog| {
        if (catalog.containsUri(uri)) {
            const metadata = server.resource_catalog.metadata orelse return error.McpResourceCatalogUnavailable;
            return cloneFeatureSnapshot(alloc, server, .resource, uri, null, metadata);
        }
    }
    if (!feature_catalog.featureCatalogAvailable(server, .resource_templates)) return error.McpResourceCatalogUnavailable;
    var match_budget = resources_feature.TemplateMatchBudget.init(
        resources_feature.default_template_match_steps,
    );
    if (server.resource_template_catalog.catalog) |catalog| {
        for (catalog.items) |template| {
            try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
            switch (resources_feature.matchTemplateWithBudget(
                template.uri_template,
                uri,
                &match_budget,
            )) {
                .matches => {
                    const metadata = server.resource_template_catalog.metadata orelse return error.McpResourceCatalogUnavailable;
                    return cloneFeatureSnapshot(alloc, server, .resource_template, template.uri_template, uri, metadata);
                },
                .no_match => continue,
                .work_limit_exceeded => return error.McpResourceTemplateMatchLimitExceeded,
            }
        }
    }
    try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
    return error.McpResourceNotFound;
}

pub fn snapshotPromptIdentity(
    catalog_mutex: *std.Io.RwLock,
    alloc: Allocator,
    server: *McpServer,
    name: []const u8,
    arguments_json: ?[]const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !Snapshot {
    try lockRwSharedUntil(catalog_mutex, deadline, cancel_flag);
    defer catalog_mutex.unlockShared(io_mod.getIo());
    if (!feature_catalog.featureCatalogAvailable(server, .prompts)) return error.McpPromptCatalogUnavailable;
    const catalog = server.prompt_catalog.catalog orelse return error.McpPromptCatalogUnavailable;
    const prompt = catalog.find(name) orelse return error.McpPromptNotFound;
    if (arguments_json) |arguments| try prompts_feature.validateArgumentsJson(alloc, prompt.*, arguments, .{});
    const metadata = server.prompt_catalog.metadata orelse return error.McpPromptCatalogUnavailable;
    return cloneFeatureSnapshot(alloc, server, .prompt, name, null, metadata);
}

pub fn snapshotResourceTemplateIdentity(
    catalog_mutex: *std.Io.RwLock,
    alloc: Allocator,
    server: *McpServer,
    uri_template: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !Snapshot {
    try lockRwSharedUntil(catalog_mutex, deadline, cancel_flag);
    defer catalog_mutex.unlockShared(io_mod.getIo());
    if (!feature_catalog.featureCatalogAvailable(server, .resource_templates)) return error.McpResourceCatalogUnavailable;
    const catalog = server.resource_template_catalog.catalog orelse return error.McpResourceCatalogUnavailable;
    for (catalog.items) |template| {
        if (!std.mem.eql(u8, template.uri_template, uri_template)) continue;
        const metadata = server.resource_template_catalog.metadata orelse return error.McpResourceCatalogUnavailable;
        return cloneFeatureSnapshot(alloc, server, .resource_template, uri_template, null, metadata);
    }
    return error.McpResourceTemplateNotFound;
}

pub fn cloneFeatureSnapshot(
    alloc: Allocator,
    server: *const McpServer,
    kind: Kind,
    identity: []const u8,
    requested_uri: ?[]const u8,
    metadata: catalog_freshness.SnapshotMetadata,
) !Snapshot {
    const server_name = try alloc.dupe(u8, server.config.name);
    errdefer alloc.free(server_name);
    const owned_identity = try alloc.dupe(u8, identity);
    errdefer alloc.free(owned_identity);
    const owned_uri = if (requested_uri) |value| try alloc.dupe(u8, value) else null;
    return .{
        .server_name = server_name,
        .identity = owned_identity,
        .requested_uri = owned_uri,
        .kind = kind,
        .auth_partition = metadata.key,
        .connection_generation = metadata.connection_generation,
        .catalog_generation = metadata.catalog_generation,
    };
}
