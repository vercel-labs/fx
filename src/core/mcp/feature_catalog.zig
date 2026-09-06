const std = @import("std");
const catalog_freshness = @import("catalog_freshness.zig");
const tool_subscription = @import("tool_subscription.zig");
const McpServer = @import("server_connection.zig").Server;

pub const FeatureCatalogKind = enum {
    resources,
    resource_templates,
    prompts,

    pub fn invalidation(self: FeatureCatalogKind) tool_subscription.FeatureInvalidation {
        return switch (self) {
            .resources => .resources,
            .resource_templates => .resource_templates,
            .prompts => .prompts,
        };
    }
};

pub const FeatureCatalogState = struct {
    metadata: ?catalog_freshness.SnapshotMetadata,
    available: bool,
};

const FeatureCatalogAvailability = struct {
    available: bool,
    metadata: ?catalog_freshness.SnapshotMetadata,
    auth_generation: u64,
};

pub fn featureCatalogState(server: *const McpServer, kind: FeatureCatalogKind) FeatureCatalogState {
    return switch (kind) {
        .resources => .{ .metadata = server.resource_catalog.metadata, .available = featureCatalogAvailable(server, kind) },
        .resource_templates => .{ .metadata = server.resource_template_catalog.metadata, .available = featureCatalogAvailable(server, kind) },
        .prompts => .{ .metadata = server.prompt_catalog.metadata, .available = featureCatalogAvailable(server, kind) },
    };
}

pub fn featureCatalogAvailable(server: *const McpServer, kind: FeatureCatalogKind) bool {
    if (!server.isPublished()) return false;
    const state = featureCatalogAvailability(server, kind);
    if (!state.available) return false;
    const metadata = state.metadata orelse return false;
    return metadata.scope == .public or
        state.auth_generation == server.auth_generation.load(.acquire);
}

pub fn featureCatalogAvailability(server: *const McpServer, kind: FeatureCatalogKind) FeatureCatalogAvailability {
    return switch (kind) {
        .resources => .{
            .available = server.resource_catalog.available,
            .metadata = server.resource_catalog.metadata,
            .auth_generation = server.resource_catalog.auth_generation,
        },
        .resource_templates => .{
            .available = server.resource_template_catalog.available,
            .metadata = server.resource_template_catalog.metadata,
            .auth_generation = server.resource_template_catalog.auth_generation,
        },
        .prompts => .{
            .available = server.prompt_catalog.available,
            .metadata = server.prompt_catalog.metadata,
            .auth_generation = server.prompt_catalog.auth_generation,
        },
    };
}

pub fn setFeatureCatalogAvailable(server: *McpServer, kind: FeatureCatalogKind, available: bool) void {
    switch (kind) {
        .resources => server.resource_catalog.available = available,
        .resource_templates => server.resource_template_catalog.available = available,
        .prompts => server.prompt_catalog.available = available,
    }
}

pub fn featureCatalogAuthWitness(server: *const McpServer, kind: FeatureCatalogKind) ?u64 {
    const state = featureCatalogAvailability(server, kind);
    const metadata = state.metadata orelse return null;
    if (metadata.scope == .public) return null;
    return state.auth_generation;
}

pub fn validateFeatureCatalogAuthWitness(server: *const McpServer, witness: ?u64) !void {
    const generation = witness orelse return;
    if (server.auth_generation.load(.acquire) != generation) {
        return error.McpFeatureCatalogChanged;
    }
}
