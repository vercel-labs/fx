const std = @import("std");
const model_capabilities = @import("../config/model_capabilities.zig");
const connection_registry = @import("connection_registry.zig");

const Allocator = std.mem.Allocator;

pub const recovery_identity_version: u8 = 1;

pub const RecoveryRouteIdentity = struct {
    version: u8 = recovery_identity_version,
    connection_id: []u8,
    adapter_kind: []u8,
    endpoint: ?[]u8 = null,
    protocol: ?[]u8 = null,
    credential_ref: ?[]u8 = null,
    permission_review_model_id: ?[]u8,
    vision_model_id: ?[]u8,
    subagent_model_id: []u8,

    pub fn deinit(self: *RecoveryRouteIdentity, alloc: Allocator) void {
        alloc.free(self.connection_id);
        alloc.free(self.adapter_kind);
        if (self.endpoint) |value| alloc.free(value);
        if (self.protocol) |value| alloc.free(value);
        if (self.credential_ref) |value| alloc.free(value);
        if (self.permission_review_model_id) |model| alloc.free(model);
        if (self.vision_model_id) |model| alloc.free(model);
        alloc.free(self.subagent_model_id);
        self.* = undefined;
    }

    pub fn dupe(self: RecoveryRouteIdentity, alloc: Allocator) !RecoveryRouteIdentity {
        const connection_id = try alloc.dupe(u8, self.connection_id);
        errdefer alloc.free(connection_id);
        const adapter_kind = try alloc.dupe(u8, self.adapter_kind);
        errdefer alloc.free(adapter_kind);
        const endpoint = if (self.endpoint) |value| try alloc.dupe(u8, value) else null;
        errdefer if (endpoint) |value| alloc.free(value);
        const protocol = if (self.protocol) |value| try alloc.dupe(u8, value) else null;
        errdefer if (protocol) |value| alloc.free(value);
        const credential_ref = if (self.credential_ref) |value| try alloc.dupe(u8, value) else null;
        errdefer if (credential_ref) |value| alloc.free(value);
        const permission_review_model_id = if (self.permission_review_model_id) |model|
            try alloc.dupe(u8, model)
        else
            null;
        errdefer if (permission_review_model_id) |model| alloc.free(model);
        const vision_model_id = if (self.vision_model_id) |model|
            try alloc.dupe(u8, model)
        else
            null;
        errdefer if (vision_model_id) |model| alloc.free(model);
        return .{
            .version = self.version,
            .connection_id = connection_id,
            .adapter_kind = adapter_kind,
            .endpoint = endpoint,
            .protocol = protocol,
            .credential_ref = credential_ref,
            .permission_review_model_id = permission_review_model_id,
            .vision_model_id = vision_model_id,
            .subagent_model_id = try alloc.dupe(u8, self.subagent_model_id),
        };
    }
};

pub fn recoveryDescriptor(
    route_model: []const u8,
    resolved: model_capabilities.ModelDescriptor,
) model_capabilities.ModelDescriptor {
    return .{
        .id = route_model,
        .display_name = resolved.display_name,
        .capabilities = resolved.capabilities,
        .source = resolved.source,
        .selected_fast_mode = false,
        .fast_route = .same_model,
    };
}

pub fn validateRecoveryProfile(
    profile: connection_registry.Profile,
    seed: connection_registry.Seed,
    identity: RecoveryRouteIdentity,
) !void {
    if (identity.version != recovery_identity_version or
        identity.endpoint == null or
        identity.protocol == null or
        identity.credential_ref == null)
    {
        return error.RecoveryRouteAuthorityUnavailable;
    }
    const endpoint = profile.endpoint orelse
        (if (std.mem.eql(u8, profile.id, seed.id)) seed.endpoint else null) orelse
        return error.RecoveryRouteAuthorityChanged;
    const protocol = profile.protocol orelse return error.RecoveryRouteAuthorityChanged;
    if (!std.mem.eql(u8, profile.id, identity.connection_id) or
        !std.mem.eql(u8, profile.adapter_id, identity.adapter_kind) or
        !std.mem.eql(u8, endpoint, identity.endpoint.?) or
        !std.mem.eql(u8, protocol, identity.protocol.?) or
        (!std.mem.eql(u8, profile.credential_ref, "automatic") and
            !std.mem.eql(u8, profile.credential_ref, identity.credential_ref.?)))
    {
        return error.RecoveryRouteAuthorityChanged;
    }
}

/// Owned, secret-free routing authority for one admitted turn.
pub const RouteSnapshot = struct {
    connection_id: []const u8,
    adapter_kind: []const u8,
    endpoint: []const u8,
    protocol: []const u8,
    credential_ref: []const u8,
    primary_model_id: []const u8,
    permission_review_model_id: ?[]const u8,
    vision_model_id: ?[]const u8,
    subagent_model_id: []const u8,
    capabilities: model_capabilities.Capabilities,
    capability_source: model_capabilities.CapabilitySource,
    selected_fast_mode: bool,
    fast_model_suffix: ?[]const u8,

    pub fn admitSelected(
        alloc: Allocator,
        profile: connection_registry.Profile,
        seed: connection_registry.Seed,
        model_descriptor: model_capabilities.ModelDescriptor,
    ) !RouteSnapshot {
        const endpoint = profile.endpoint orelse
            (if (std.mem.eql(u8, profile.id, seed.id)) seed.endpoint else null) orelse
            return error.InvalidRouteEndpoint;
        return admit(alloc, profile, model_descriptor, endpoint);
    }

    pub fn admit(
        alloc: Allocator,
        profile: connection_registry.Profile,
        model_descriptor: model_capabilities.ModelDescriptor,
        effective_endpoint: []const u8,
    ) !RouteSnapshot {
        return admitWithInternalModels(
            alloc,
            profile,
            model_descriptor,
            effective_endpoint,
            profile.internal_models.input(),
        );
    }

    fn admitRecovery(
        alloc: Allocator,
        profile: connection_registry.Profile,
        identity: RecoveryRouteIdentity,
        model_descriptor: model_capabilities.ModelDescriptor,
        effective_endpoint: []const u8,
    ) !RouteSnapshot {
        const credential_ref = identity.credential_ref orelse
            return error.RecoveryRouteAuthorityUnavailable;
        var pinned_profile = profile;
        pinned_profile.id = identity.connection_id;
        pinned_profile.adapter_id = identity.adapter_kind;
        pinned_profile.protocol = identity.protocol;
        pinned_profile.credential_ref = credential_ref;
        return admitWithInternalModels(
            alloc,
            pinned_profile,
            model_descriptor,
            effective_endpoint,
            .{
                .permission_review = identity.permission_review_model_id,
                .vision = identity.vision_model_id,
                .subagent = identity.subagent_model_id,
            },
        );
    }

    pub fn admitSelectedRecovery(
        alloc: Allocator,
        profile: connection_registry.Profile,
        seed: connection_registry.Seed,
        identity: RecoveryRouteIdentity,
        model_descriptor: model_capabilities.ModelDescriptor,
    ) !RouteSnapshot {
        try validateRecoveryProfile(profile, seed, identity);
        return admitRecovery(
            alloc,
            profile,
            identity,
            model_descriptor,
            identity.endpoint.?,
        );
    }

    fn admitWithInternalModels(
        alloc: Allocator,
        profile: connection_registry.Profile,
        model_descriptor: model_capabilities.ModelDescriptor,
        effective_endpoint: []const u8,
        internal_models: connection_registry.InternalModelsInput,
    ) !RouteSnapshot {
        if (model_descriptor.id.len == 0) return error.InvalidRouteModel;
        const protocol_value = profile.protocol orelse return error.InvalidRouteProtocol;
        if (effective_endpoint.len == 0) return error.InvalidRouteEndpoint;

        const connection_id = try alloc.dupe(u8, profile.id);
        errdefer alloc.free(connection_id);
        const adapter_kind = try alloc.dupe(u8, profile.adapter_id);
        errdefer alloc.free(adapter_kind);
        const endpoint = try alloc.dupe(u8, effective_endpoint);
        errdefer alloc.free(endpoint);
        const protocol = try alloc.dupe(u8, protocol_value);
        errdefer alloc.free(protocol);
        const credential_ref = try alloc.dupe(u8, profile.credential_ref);
        errdefer alloc.free(credential_ref);
        const primary_model_id = try alloc.dupe(u8, model_descriptor.id);
        errdefer alloc.free(primary_model_id);
        const permission_review_model_id = if (internal_models.permission_review) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (permission_review_model_id) |value| alloc.free(value);
        const resolved_vision_model = internal_models.vision orelse
            if (model_descriptor.capabilities.supports_vision and
                model_descriptor.capabilities.supports_file_input)
                model_descriptor.id
            else
                null;
        const vision_model_id = if (resolved_vision_model) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (vision_model_id) |value| alloc.free(value);
        const subagent_model_id = try alloc.dupe(
            u8,
            internal_models.subagent orelse model_descriptor.id,
        );
        errdefer alloc.free(subagent_model_id);
        const fast_model_suffix = if (model_descriptor.capabilities.supports_fast_mode)
            switch (model_descriptor.fast_route) {
                .same_model => null,
                .suffix => |suffix| try alloc.dupe(u8, suffix),
            }
        else
            null;

        return .{
            .connection_id = connection_id,
            .adapter_kind = adapter_kind,
            .endpoint = endpoint,
            .protocol = protocol,
            .credential_ref = credential_ref,
            .primary_model_id = primary_model_id,
            .permission_review_model_id = permission_review_model_id,
            .vision_model_id = vision_model_id,
            .subagent_model_id = subagent_model_id,
            .capabilities = model_descriptor.capabilities,
            .capability_source = model_descriptor.source,
            .selected_fast_mode = model_descriptor.selected_fast_mode,
            .fast_model_suffix = fast_model_suffix,
        };
    }

    pub fn deinit(self: *RouteSnapshot, alloc: Allocator) void {
        alloc.free(self.connection_id);
        alloc.free(self.adapter_kind);
        alloc.free(self.endpoint);
        alloc.free(self.protocol);
        alloc.free(self.credential_ref);
        alloc.free(self.primary_model_id);
        if (self.permission_review_model_id) |value| alloc.free(value);
        if (self.vision_model_id) |value| alloc.free(value);
        alloc.free(self.subagent_model_id);
        if (self.fast_model_suffix) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn descriptor(self: *const RouteSnapshot) model_capabilities.ModelDescriptor {
        return .{
            .id = self.primary_model_id,
            .display_name = self.primary_model_id,
            .capabilities = self.capabilities,
            .source = self.capability_source,
            .selected_fast_mode = self.selected_fast_mode,
            .fast_route = if (self.fast_model_suffix) |suffix|
                .{ .suffix = suffix }
            else
                .same_model,
        };
    }

    /// Returns the Vision model resolved at admission. A distinct configured
    /// model is explicitly assigned to this workload by the connection owner;
    /// a primary-model fallback retains its normalized capabilities.
    pub fn visionDescriptor(
        self: *const RouteSnapshot,
    ) ?model_capabilities.ModelDescriptor {
        const model = self.vision_model_id orelse return null;
        if (std.mem.eql(u8, model, self.primary_model_id)) return self.descriptor();
        return model_capabilities.configuredDescriptor(model, .{
            .supports_vision = true,
            .supports_file_input = true,
        });
    }

    /// Copies the pinned connection authority while admitting one model for a
    /// child workload. This never consults connection selection or a registry.
    pub fn deriveForModel(
        self: *const RouteSnapshot,
        alloc: Allocator,
        descriptor_value: model_capabilities.ModelDescriptor,
    ) !RouteSnapshot {
        const connection_id = try alloc.dupe(u8, self.connection_id);
        errdefer alloc.free(connection_id);
        const adapter_kind = try alloc.dupe(u8, self.adapter_kind);
        errdefer alloc.free(adapter_kind);
        const endpoint = try alloc.dupe(u8, self.endpoint);
        errdefer alloc.free(endpoint);
        const protocol = try alloc.dupe(u8, self.protocol);
        errdefer alloc.free(protocol);
        const credential_ref = try alloc.dupe(u8, self.credential_ref);
        errdefer alloc.free(credential_ref);
        const primary_model_id = try alloc.dupe(u8, descriptor_value.id);
        errdefer alloc.free(primary_model_id);
        const permission_review_model_id = if (self.permission_review_model_id) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (permission_review_model_id) |value| alloc.free(value);
        const vision_model_id = if (self.vision_model_id) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (vision_model_id) |value| alloc.free(value);
        const subagent_model_id = try alloc.dupe(u8, self.subagent_model_id);
        errdefer alloc.free(subagent_model_id);
        const fast_model_suffix = if (descriptor_value.capabilities.supports_fast_mode)
            switch (descriptor_value.fast_route) {
                .same_model => null,
                .suffix => |suffix| try alloc.dupe(u8, suffix),
            }
        else
            null;

        return .{
            .connection_id = connection_id,
            .adapter_kind = adapter_kind,
            .endpoint = endpoint,
            .protocol = protocol,
            .credential_ref = credential_ref,
            .primary_model_id = primary_model_id,
            .permission_review_model_id = permission_review_model_id,
            .vision_model_id = vision_model_id,
            .subagent_model_id = subagent_model_id,
            .capabilities = descriptor_value.capabilities,
            .capability_source = descriptor_value.source,
            .selected_fast_mode = descriptor_value.selected_fast_mode,
            .fast_model_suffix = fast_model_suffix,
        };
    }

    pub fn clone(self: *const RouteSnapshot, alloc: Allocator) !RouteSnapshot {
        return self.deriveForModel(alloc, self.descriptor());
    }

    /// Returns borrowed primary storage unless the admitted fast suffix is used.
    /// A suffixed result is allocated by `alloc` and owned by the caller.
    pub fn modelFor(self: *const RouteSnapshot, alloc: Allocator, fast_mode: bool) ![]const u8 {
        return self.descriptor().routeModel(alloc, fast_mode);
    }

    pub fn containsModel(self: *const RouteSnapshot, model: []const u8) bool {
        if (std.mem.eql(u8, self.primary_model_id, model)) return true;
        if (self.permission_review_model_id) |reviewer| {
            if (std.mem.eql(u8, reviewer, model)) return true;
        }
        if (self.vision_model_id) |vision| {
            if (std.mem.eql(u8, vision, model)) return true;
        }
        if (std.mem.eql(u8, self.subagent_model_id, model)) return true;
        const suffix = self.fast_model_suffix orelse return false;
        if (model.len != self.primary_model_id.len + suffix.len) return false;
        return std.mem.eql(u8, model[0..self.primary_model_id.len], self.primary_model_id) and
            std.mem.eql(u8, model[self.primary_model_id.len..], suffix);
    }
};

test "route admission owns immutable secret-free routing facts" {
    var connection_id = [_]u8{ 'f', 'a', 'k', 'e' };
    var adapter_kind = [_]u8{ 'l', 'o', 'c', 'a', 'l' };
    var endpoint = [_]u8{ 'h', 't', 't', 'p', ':', '/', '/', 'a' };
    var protocol = [_]u8{ 'f', 'a', 'k', 'e' };
    var credential_ref = [_]u8{ 'r', 'e', 'f', '_', 'a' };
    var primary_model = [_]u8{ 'm', 'o', 'd', 'e', 'l', '-', 'a' };
    var reviewer_model = [_]u8{ 'r', 'e', 'v', 'i', 'e', 'w', '-', 'a' };
    var fast_suffix = [_]u8{ '-', 'f', 'a', 's', 't' };
    const profile = connection_registry.Profile{
        .id = &connection_id,
        .display_name = @constCast("Fake"),
        .adapter_id = &adapter_kind,
        .endpoint = &endpoint,
        .protocol = &protocol,
        .credential_ref = &credential_ref,
        .remembered_model = &primary_model,
        .internal_models = .{
            .permission_review = &reviewer_model,
            .vision = @constCast("vision-a"),
            .subagent = @constCast("child-a"),
        },
    };
    const descriptor = model_capabilities.ModelDescriptor{
        .id = &primary_model,
        .display_name = &primary_model,
        .capabilities = .{
            .supports_fast_mode = true,
            .supports_tool_use = true,
        },
        .source = .configured,
        .fast_route = .{ .suffix = &fast_suffix },
    };

    var route = try RouteSnapshot.admit(
        std.testing.allocator,
        profile,
        descriptor,
        &endpoint,
    );
    defer route.deinit(std.testing.allocator);

    @memset(&connection_id, 'x');
    @memset(&adapter_kind, 'x');
    @memset(&endpoint, 'x');
    @memset(&protocol, 'x');
    @memset(&credential_ref, 'x');
    @memset(&primary_model, 'x');
    @memset(&reviewer_model, 'x');
    @memset(&fast_suffix, 'x');

    try std.testing.expectEqualStrings("fake", route.connection_id);
    try std.testing.expectEqualStrings("local", route.adapter_kind);
    try std.testing.expectEqualStrings("http://a", route.endpoint);
    try std.testing.expectEqualStrings("fake", route.protocol);
    try std.testing.expectEqualStrings("ref_a", route.credential_ref);
    try std.testing.expectEqualStrings("model-a", route.primary_model_id);
    try std.testing.expectEqualStrings("review-a", route.permission_review_model_id.?);
    try std.testing.expectEqualStrings("vision-a", route.vision_model_id.?);
    try std.testing.expectEqualStrings("child-a", route.subagent_model_id);
    try std.testing.expect(route.capabilities.supports_tool_use);
    try std.testing.expect(route.containsModel("model-a"));
    try std.testing.expect(route.containsModel("model-a-fast"));
    try std.testing.expect(!route.containsModel("model-b"));
    try std.testing.expect(!@hasField(RouteSnapshot, "credential"));
    try std.testing.expect(!@hasField(RouteSnapshot, "api_key"));
    try std.testing.expect(!@hasField(RouteSnapshot, "token"));
}

test "internal model resolution is pinned per admission and null never consults defaults" {
    var profile = connection_registry.Profile{
        .id = @constCast("connection-a"),
        .display_name = @constCast("A"),
        .adapter_id = @constCast("loopback"),
        .endpoint = @constCast("http://127.0.0.1/a"),
        .protocol = @constCast("loopback"),
        .credential_ref = @constCast("key-a"),
        .remembered_model = @constCast("primary-a"),
        .internal_models = .{
            .permission_review = @constCast("reviewer-a"),
            .vision = @constCast("vision-a"),
            .subagent = @constCast("child-a"),
        },
    };
    const primary = model_capabilities.configuredDescriptor("primary-a", .{
        .supports_tool_use = true,
    });
    var first = try RouteSnapshot.admit(
        std.testing.allocator,
        profile,
        primary,
        profile.endpoint.?,
    );
    defer first.deinit(std.testing.allocator);

    profile.internal_models = .{};
    var second = try RouteSnapshot.admit(
        std.testing.allocator,
        profile,
        primary,
        profile.endpoint.?,
    );
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("reviewer-a", first.permission_review_model_id.?);
    try std.testing.expectEqualStrings("vision-a", first.vision_model_id.?);
    try std.testing.expectEqualStrings("child-a", first.subagent_model_id);
    try std.testing.expect(second.permission_review_model_id == null);
    try std.testing.expect(second.vision_model_id == null);
    try std.testing.expectEqualStrings("primary-a", second.subagent_model_id);

    const vision_primary = model_capabilities.configuredDescriptor("primary-a", .{
        .supports_vision = true,
        .supports_file_input = true,
    });
    var third = try RouteSnapshot.admit(
        std.testing.allocator,
        profile,
        vision_primary,
        profile.endpoint.?,
    );
    defer third.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("primary-a", third.vision_model_id.?);
}

test "route admission rejects invalid model protocol and endpoint" {
    var profile = connection_registry.Profile{
        .id = @constCast("fake"),
        .display_name = @constCast("Fake"),
        .adapter_id = @constCast("local"),
        .endpoint = null,
        .protocol = null,
        .credential_ref = @constCast("ref"),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    };
    const descriptor = model_capabilities.configuredDescriptor("model", .{});
    try std.testing.expectError(
        error.InvalidRouteModel,
        RouteSnapshot.admit(
            std.testing.allocator,
            profile,
            model_capabilities.configuredDescriptor("", .{}),
            "http://example.invalid",
        ),
    );
    try std.testing.expectError(
        error.InvalidRouteProtocol,
        RouteSnapshot.admit(
            std.testing.allocator,
            profile,
            descriptor,
            "http://example.invalid",
        ),
    );
    profile.protocol = @constCast("fake");
    try std.testing.expectError(
        error.InvalidRouteEndpoint,
        RouteSnapshot.admit(std.testing.allocator, profile, descriptor, ""),
    );
}

test "selected route uses profile endpoint before the seed endpoint" {
    const seed = connection_registry.Seed{
        .id = "seed",
        .display_name = "Seed",
        .adapter_id = "shared-adapter",
        .endpoint = "https://seed.invalid",
        .protocol = "shared-protocol",
        .credential_ref = "seed-ref",
    };
    var custom_profile = connection_registry.Profile{
        .id = @constCast("custom"),
        .display_name = @constCast("Custom"),
        .adapter_id = @constCast("shared-adapter"),
        .endpoint = @constCast("https://custom.invalid"),
        .protocol = @constCast("shared-protocol"),
        .credential_ref = @constCast("custom-ref"),
        .remembered_model = @constCast("custom-model"),
        .internal_models = .{},
    };
    const descriptor = model_capabilities.configuredDescriptor("custom-model", .{});

    var custom_route = try RouteSnapshot.admitSelected(
        std.testing.allocator,
        custom_profile,
        seed,
        descriptor,
    );
    defer custom_route.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://custom.invalid", custom_route.endpoint);

    custom_profile.id = @constCast("seed");
    var seed_route = try RouteSnapshot.admitSelected(
        std.testing.allocator,
        custom_profile,
        seed,
        descriptor,
    );
    defer seed_route.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://custom.invalid", seed_route.endpoint);
}

test "recovery route rejects changed authority before admission" {
    const seed = connection_registry.Seed{
        .id = "saved",
        .display_name = "Saved",
        .adapter_id = "changed-adapter",
        .endpoint = "https://saved.invalid",
        .protocol = "saved-protocol",
        .credential_ref = "saved-ref",
    };
    const profile = connection_registry.Profile{
        .id = @constCast("saved"),
        .display_name = @constCast("Saved"),
        .adapter_id = @constCast("changed-adapter"),
        .endpoint = @constCast("https://saved.invalid"),
        .protocol = @constCast("saved-protocol"),
        .credential_ref = @constCast("saved-ref"),
        .remembered_model = @constCast("saved-model"),
        .internal_models = .{ .permission_review = @constCast("current-reviewer") },
    };

    try std.testing.expectError(
        error.RecoveryRouteAuthorityChanged,
        RouteSnapshot.admitSelectedRecovery(
            std.testing.allocator,
            profile,
            seed,
            .{
                .connection_id = @constCast("saved"),
                .adapter_kind = @constCast("persisted-adapter"),
                .endpoint = @constCast("https://saved.invalid"),
                .protocol = @constCast("saved-protocol"),
                .credential_ref = @constCast("saved-ref"),
                .permission_review_model_id = @constCast("persisted-reviewer"),
                .vision_model_id = @constCast("persisted-vision"),
                .subagent_model_id = @constCast("persisted-child"),
            },
            model_capabilities.configuredDescriptor("persisted-model", .{}),
        ),
    );
}

test "recovery profile requires every pinned authority field" {
    const seed = connection_registry.Seed{
        .id = "saved",
        .display_name = "Saved",
        .adapter_id = "saved-adapter",
        .endpoint = "https://saved.invalid",
        .protocol = "saved-protocol",
        .credential_ref = "saved-ref",
    };
    const identity = RecoveryRouteIdentity{
        .connection_id = @constCast("saved"),
        .adapter_kind = @constCast("saved-adapter"),
        .endpoint = @constCast("https://saved.invalid"),
        .protocol = @constCast("saved-protocol"),
        .credential_ref = @constCast("saved-ref"),
        .permission_review_model_id = null,
        .vision_model_id = null,
        .subagent_model_id = @constCast("saved-model"),
    };
    const changes = [_]struct {
        endpoint: []u8,
        protocol: []u8,
        credential_ref: []u8,
    }{
        .{
            .endpoint = @constCast("https://changed.invalid"),
            .protocol = @constCast("saved-protocol"),
            .credential_ref = @constCast("saved-ref"),
        },
        .{
            .endpoint = @constCast("https://saved.invalid"),
            .protocol = @constCast("changed-protocol"),
            .credential_ref = @constCast("saved-ref"),
        },
        .{
            .endpoint = @constCast("https://saved.invalid"),
            .protocol = @constCast("saved-protocol"),
            .credential_ref = @constCast("changed-ref"),
        },
    };
    for (changes) |change| {
        const profile = connection_registry.Profile{
            .id = @constCast("saved"),
            .display_name = @constCast("Saved"),
            .adapter_id = @constCast("saved-adapter"),
            .endpoint = change.endpoint,
            .protocol = change.protocol,
            .credential_ref = change.credential_ref,
            .remembered_model = @constCast("saved-model"),
            .internal_models = .{},
        };
        try std.testing.expectError(
            error.RecoveryRouteAuthorityChanged,
            validateRecoveryProfile(profile, seed, identity),
        );
    }

    var legacy_identity = identity;
    legacy_identity.version = 0;
    const saved_profile = connection_registry.Profile{
        .id = @constCast("saved"),
        .display_name = @constCast("Saved"),
        .adapter_id = @constCast("saved-adapter"),
        .endpoint = @constCast("https://saved.invalid"),
        .protocol = @constCast("saved-protocol"),
        .credential_ref = @constCast("saved-ref"),
        .remembered_model = @constCast("saved-model"),
        .internal_models = .{},
    };
    try std.testing.expectError(
        error.RecoveryRouteAuthorityUnavailable,
        validateRecoveryProfile(saved_profile, seed, legacy_identity),
    );
}

test "recovery route owns pinned authority and model presentation" {
    const seed = connection_registry.Seed{
        .id = "saved",
        .display_name = "Saved",
        .adapter_id = "saved-adapter",
        .endpoint = "https://saved.invalid",
        .protocol = "saved-protocol",
        .credential_ref = "automatic",
    };
    const identity = RecoveryRouteIdentity{
        .connection_id = @constCast("saved"),
        .adapter_kind = @constCast("saved-adapter"),
        .endpoint = @constCast("https://saved.invalid"),
        .protocol = @constCast("saved-protocol"),
        .credential_ref = @constCast("saved-effective-ref"),
        .permission_review_model_id = @constCast("saved-reviewer"),
        .vision_model_id = @constCast("saved-vision"),
        .subagent_model_id = @constCast("saved-subagent"),
    };
    const profile = connection_registry.Profile{
        .id = @constCast("saved"),
        .display_name = @constCast("Saved"),
        .adapter_id = @constCast("saved-adapter"),
        .endpoint = @constCast("https://saved.invalid"),
        .protocol = @constCast("saved-protocol"),
        .credential_ref = @constCast("automatic"),
        .remembered_model = @constCast("changed-model"),
        .internal_models = .{},
    };
    var route = try RouteSnapshot.admitSelectedRecovery(
        std.testing.allocator,
        profile,
        seed,
        identity,
        model_capabilities.configuredDescriptor("saved-primary", .{}),
    );
    defer route.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://saved.invalid", route.endpoint);
    try std.testing.expectEqualStrings("saved-protocol", route.protocol);
    try std.testing.expectEqualStrings("saved-effective-ref", route.credential_ref);
    try std.testing.expectEqualStrings("saved-primary", route.primary_model_id);
    try std.testing.expectEqualStrings("saved-reviewer", route.permission_review_model_id.?);
    try std.testing.expectEqualStrings("saved-vision", route.vision_model_id.?);
    try std.testing.expectEqualStrings("saved-subagent", route.subagent_model_id);
}

test "recovery identity duplication frees every allocation failure boundary" {
    const identity = RecoveryRouteIdentity{
        .connection_id = @constCast("saved"),
        .adapter_kind = @constCast("saved-adapter"),
        .endpoint = @constCast("https://saved.invalid"),
        .protocol = @constCast("saved-protocol"),
        .credential_ref = @constCast("saved-ref"),
        .permission_review_model_id = @constCast("saved-reviewer"),
        .vision_model_id = @constCast("saved-vision"),
        .subagent_model_id = @constCast("saved-subagent"),
    };
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var duplicated = try identity.dupe(probe.allocator());
    duplicated.deinit(probe.allocator());

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(error.OutOfMemory, identity.dupe(failing.allocator()));
    }
}
