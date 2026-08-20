//! Provider-neutral adapter registry and connection seed composition.

const std = @import("std");
const agent_stream_provider = @import("../agent/stream_provider.zig");
pub const account_usage_provider = @import("account_usage_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const output_contracts = @import("../output/output_contracts.zig");
const connection_registry = @import("connection_registry.zig");
const adapter_registry = @import("adapter_registry.zig");
const model_catalog = @import("model_catalog.zig");

const Allocator = std.mem.Allocator;

pub const System = struct {
    connection_seed: connection_registry.Seed,
    adapter_registry: adapter_registry.AdapterRegistry = .{ .adapters = &.{} },
};

test "account usage lookup dispatches through the injected provider" {
    const Fake = struct {
        calls: usize = 0,
        saw_expected_input: bool = false,

        fn fetch(
            raw: ?*anyopaque,
            alloc: Allocator,
            input: account_usage_provider.Input,
        ) output_contracts.CreditsSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.saw_expected_input =
                std.mem.eql(u8, input.credential orelse "", "credential") and
                std.mem.eql(u8, input.tenant orelse "", "tenant");
            return .{
                .balance = alloc.dupe(u8, "10") catch null,
            };
        }
    };

    var fake: Fake = .{};
    const provider = account_usage_provider.Provider{
        .context = &fake,
        .fetch_fn = Fake.fetch,
    };
    var snapshot = provider.fetch(std.testing.allocator, .{
        .credential = "credential",
        .tenant = "tenant",
    });
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.saw_expected_input);
    try std.testing.expectEqualStrings("10", snapshot.balance.?);
}

const CapabilityResolverState = enum {
    idle,
    ready,
    failed,
};

pub const CapabilityResolver = struct {
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    state: CapabilityResolverState = .idle,

    pub fn deinit(self: *CapabilityResolver, alloc: Allocator) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
    }

    pub fn resolve(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        descriptors: model_catalog.ModelDescriptorProvider,
        input: model_catalog.FetchInput,
        model: []const u8,
    ) model_capabilities.ResolveError!model_capabilities.ModelDescriptor {
        const fallback = descriptors.fallback(model);
        if (self.state == .idle) {
            const result = model_catalog.fetchWithPublicFallback(provider, alloc, input);
            const loaded = switch (result) {
                .loaded => |loaded| loaded,
                .failed => |failed| {
                    const failure = failed.failure;
                    if (failure.category == .cancellation) {
                        debug_trace.logf(
                            "gateway",
                            "model catalog lookup outcome=cancelled model={s}",
                            .{model},
                        );
                        return error.Cancelled;
                    }
                    self.state = .failed;
                    debug_trace.logf(
                        "gateway",
                        "model catalog lookup outcome=fetch_failed model={s} category={t}",
                        .{ model, failure.category },
                    );
                    return fallback;
                },
            };
            self.catalog = loaded.catalog;
            self.state = .ready;
        }

        if (self.state == .failed) {
            debug_trace.logf(
                "gateway",
                "model catalog lookup outcome=cache_failed model={s}",
                .{model},
            );
            return fallback;
        }
        const descriptor = descriptors.resolve(self.catalog.items, model);
        debug_trace.logf(
            "gateway",
            "model catalog lookup outcome={s} model={s}",
            .{ if (descriptor.source == .catalog) "ready_hit" else "missing_entry", model },
        );
        return descriptor;
    }

    pub fn available(
        self: *const CapabilityResolver,
        descriptors: model_catalog.ModelDescriptorProvider,
        model: []const u8,
    ) model_capabilities.ModelDescriptor {
        if (self.state == .ready) return descriptors.resolve(self.catalog.items, model);
        return descriptors.fallback(model);
    }

    pub fn catalogEntries(self: *const CapabilityResolver) ?[]const model_catalog.ModelCatalogEntry {
        if (self.state != .ready) return null;
        return self.catalog.items;
    }
};

const FakeCatalog = struct {
    outcome: enum {
        cancelled,
        unavailable,
        authenticated_rejected_then_ready,
        ready,
    },
    calls: usize = 0,
    saw_authenticated_access: bool = false,
    saw_public_retry: bool = false,

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *FakeCatalog = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.outcome == .authenticated_rejected_then_ready) {
            if (self.calls == 1) {
                self.saw_authenticated_access =
                    std.mem.eql(u8, input.access.authorizationCredential() orelse "", "test-key") and
                    std.mem.eql(u8, input.access.teamContext() orelse "", "team_123");
                return .{ .failure = .{ .category = .authentication } };
            }
            self.saw_public_retry =
                input.access.authorizationCredential() == null and
                input.access.teamContext() == null and
                input.access.publicOnlyReason() == .credential_rejected;
            self.outcome = .ready;
        }
        switch (self.outcome) {
            .cancelled => return .{ .failure = .{ .category = .cancellation } },
            .unavailable => return .{ .failure = .{ .category = .transport } },
            .authenticated_rejected_then_ready => unreachable,
            .ready => {
                var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
                errdefer model_catalog.freeModelCatalog(alloc, &entries);
                const id = try alloc.dupe(u8, "provider/model");
                errdefer alloc.free(id);
                const model_type = try alloc.dupe(u8, "language");
                errdefer alloc.free(model_type);
                const entry = model_catalog.ModelCatalogEntry{
                    .id = id,
                    .model_type = model_type,
                    .has_vision = true,
                    .has_file_input = true,
                    .context_window = 256_000,
                    .max_tokens = 32_000,
                };
                try entries.append(alloc, entry);
                return .{ .catalog = entries };
            },
        }
    }

    fn provider(self: *FakeCatalog) model_catalog.Provider {
        return .{
            .context = self,
            .fetch_fn = fetch,
        };
    }
};

fn fakeFallbackDescriptor(_: ?*anyopaque, selected_model: []const u8) model_capabilities.ModelDescriptor {
    return .{
        .id = selected_model,
        .display_name = selected_model,
        .capabilities = .{},
        .source = .@"adapter-static",
    };
}

fn fakeCatalogDescriptor(_: ?*anyopaque, entry: model_catalog.ModelCatalogEntry) model_capabilities.ModelDescriptor {
    var descriptor = fakeFallbackDescriptor(null, entry.id);
    descriptor.capabilities.supports_reasoning = entry.has_reasoning or entry.reasoning_efforts.items.len > 0;
    descriptor.capabilities.reasoning_efforts = .fromSlice(entry.reasoning_efforts.items);
    descriptor.capabilities.supports_fast_mode = entry.supports_fast_mode;
    descriptor.capabilities.supports_tool_use = entry.has_tool_use;
    descriptor.capabilities.supports_vision = entry.has_vision;
    descriptor.capabilities.supports_file_input = entry.has_file_input;
    descriptor.capabilities.context_window = if (entry.context_window == 0) null else entry.context_window;
    descriptor.capabilities.max_output_tokens = if (entry.max_tokens == 0) null else entry.max_tokens;
    descriptor.source = .catalog;
    return descriptor;
}

const fake_descriptor_provider = model_catalog.ModelDescriptorProvider{
    .fallback_fn = fakeFallbackDescriptor,
    .catalog_fn = fakeCatalogDescriptor,
};

test "available capabilities never fetch and use a completed catalog snapshot" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .ready };
    const provider = model_catalog.Provider{ .context = &fake, .fetch_fn = FakeCatalog.fetch };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);

    const cold = resolver.available(fake_descriptor_provider, "provider/model");
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.@"adapter-static", cold.source);
    try std.testing.expectEqual(@as(?u32, null), cold.capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, null), cold.capabilities.max_output_tokens);

    _ = try resolver.resolve(
        alloc,
        provider,
        fake_descriptor_provider,
        .{},
        "provider/model",
    );
    const warm = resolver.available(fake_descriptor_provider, "provider/model");
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, warm.source);
    try std.testing.expectEqual(@as(?u32, 256_000), warm.capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), warm.capabilities.max_output_tokens);
}

test "capability resolver keeps exact alias catalog identity" {
    const alloc = std.testing.allocator;
    var resolver: CapabilityResolver = .{ .state = .ready };
    defer resolver.deinit(alloc);
    try model_catalog.appendClonedModelCatalogEntry(alloc, &resolver.catalog, .{
        .id = @constCast("zai/glm-4.6-fast"),
        .model_type = @constCast("language"),
        .has_reasoning = true,
        .has_tool_use = true,
        .has_vision = true,
        .has_file_input = true,
        .context_window = 262_144,
        .max_tokens = 65_536,
    });

    const fast = resolver.available(fake_descriptor_provider, "zai/glm-4.6-fast");
    var fake = FakeCatalog{ .outcome = .ready };
    const normal = try resolver.resolve(
        alloc,
        fake.provider(),
        fake_descriptor_provider,
        .{},
        "zai/glm-4.6",
    );

    try std.testing.expectEqualStrings("zai/glm-4.6-fast", fast.id);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, fast.source);
    try std.testing.expect(!fast.selected_fast_mode);
    try std.testing.expect(fast.capabilities.supports_reasoning);
    try std.testing.expect(fast.capabilities.supports_tool_use);
    try std.testing.expect(fast.capabilities.supports_vision);
    try std.testing.expect(fast.capabilities.supports_file_input);
    try std.testing.expectEqual(@as(?u32, 262_144), fast.capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 65_536), fast.capabilities.max_output_tokens);

    try std.testing.expectEqualStrings("zai/glm-4.6", normal.id);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.@"adapter-static", normal.source);
    try std.testing.expect(!normal.capabilities.supports_reasoning);
}

test "capability resolver leaves a cancelled catalog fetch retryable" {
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(std.testing.allocator);
    var fake = FakeCatalog{ .outcome = .cancelled };
    var cancel_flag = std.atomic.Value(bool).init(true);

    try std.testing.expectError(
        error.Cancelled,
        resolver.resolve(
            std.testing.allocator,
            fake.provider(),
            fake_descriptor_provider,
            .{
                .cancel_flag = &cancel_flag,
            },
            "provider/model",
        ),
    );
    try std.testing.expectEqual(CapabilityResolverState.idle, resolver.state);

    fake.outcome = .ready;
    cancel_flag.store(false, .seq_cst);
    const descriptor = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        fake_descriptor_provider,
        .{
            .cancel_flag = &cancel_flag,
        },
        "provider/model",
    );
    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, descriptor.source);
    try std.testing.expect(descriptor.capabilities.supports_vision);
}

test "capability resolver uses provider catalog metadata" {
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(std.testing.allocator);
    var fake = FakeCatalog{ .outcome = .ready };
    var cancel_flag = std.atomic.Value(bool).init(false);

    const descriptor = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        fake_descriptor_provider,
        .{
            .access = .{ .authenticated = .{
                .source = .{ .id = "test_key", .label = "test key", .refreshable = false },
                .credential = "test-key",
                .team_context = "team_123",
            } },
            .cancel_flag = &cancel_flag,
        },
        "provider/model",
    );

    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, descriptor.source);
    try std.testing.expect(descriptor.capabilities.supports_vision);
    try std.testing.expect(descriptor.capabilities.supports_file_input);
    try std.testing.expectEqual(@as(?u32, 256_000), descriptor.capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), descriptor.capabilities.max_output_tokens);

    const missing = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        fake_descriptor_provider,
        .{
            .cancel_flag = &cancel_flag,
        },
        "zai/glm-4.6",
    );
    try std.testing.expectEqual(model_capabilities.CapabilitySource.@"adapter-static", missing.source);
    try std.testing.expect(!missing.capabilities.supports_fast_mode);
    try std.testing.expect(!missing.capabilities.supports_vision);

    const unknown = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        fake_descriptor_provider,
        .{
            .cancel_flag = &cancel_flag,
        },
        "unknown/model",
    );
    try std.testing.expectEqual(model_capabilities.CapabilitySource.@"adapter-static", unknown.source);
    try std.testing.expect(!unknown.capabilities.supports_reasoning);
    try std.testing.expect(!unknown.capabilities.supports_fast_mode);
    try std.testing.expect(!unknown.capabilities.supports_vision);
}

test "capability resolver retries rejected authenticated catalog access anonymously" {
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(std.testing.allocator);
    var fake = FakeCatalog{ .outcome = .authenticated_rejected_then_ready };

    const descriptor = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        fake_descriptor_provider,
        .{
            .access = .{ .authenticated = .{
                .source = .{ .id = "test_key", .label = "test key", .refreshable = false },
                .credential = "test-key",
                .team_context = "team_123",
            } },
        },
        "provider/model",
    );

    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(fake.saw_authenticated_access);
    try std.testing.expect(fake.saw_public_retry);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, descriptor.source);
    try std.testing.expect(descriptor.capabilities.supports_vision);
}

test "capability resolver degrades terminal catalog failures to local capabilities" {
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(std.testing.allocator);
    var fake = FakeCatalog{ .outcome = .unavailable };
    var cancel_flag = std.atomic.Value(bool).init(false);

    const descriptor = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        fake_descriptor_provider,
        .{
            .cancel_flag = &cancel_flag,
        },
        "zai/glm-4.6",
    );
    try std.testing.expectEqual(model_capabilities.CapabilitySource.@"adapter-static", descriptor.source);
    try std.testing.expect(!descriptor.capabilities.supports_fast_mode);

    fake.outcome = .ready;
    const cached_failure = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        fake_descriptor_provider,
        .{
            .cancel_flag = &cancel_flag,
        },
        "provider/model",
    );
    try std.testing.expectEqual(model_capabilities.CapabilitySource.@"adapter-static", cached_failure.source);
    try std.testing.expect(!cached_failure.capabilities.supports_vision);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
