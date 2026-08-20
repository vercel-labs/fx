const std = @import("std");
const agent_stream_provider = @import("../agent/stream_provider.zig");
pub const account_usage_provider = @import("account_usage_provider.zig");
const credentials = @import("../auth/credentials.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const output_contracts = @import("../output/output_contracts.zig");
const connection_registry = @import("connection_registry.zig");
const adapter_registry = @import("adapter_registry.zig");
const model_catalog = @import("model_catalog.zig");
const model_catalog_metadata = @import("model_catalog_metadata.zig");

const Allocator = std.mem.Allocator;

pub const ResolveChatUrlFn = *const fn (?*anyopaque, []const u8) []const u8;

pub const ChatUrlProvider = struct {
    /// When set, context must remain valid until every in-flight `resolve` returns.
    context: ?*anyopaque = null,
    resolve_fn: ResolveChatUrlFn,

    pub fn resolve(self: ChatUrlProvider, fallback: []const u8) []const u8 {
        return self.resolve_fn(self.context, fallback);
    }
};

pub const Provider = struct {
    connection_seed: connection_registry.Seed,
    agent_stream: agent_stream_provider.Provider,
    provider_adapter: agent_stream_provider.ProviderAdapter,
    adapter_registry: adapter_registry.AdapterRegistry = .{ .adapters = &.{} },
    oauth_transport: oauth_transport.Provider,
    chat_url: ChatUrlProvider,
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

pub fn modelCatalogForAdapter(
    admitted_adapter_kind: []const u8,
    adapter: agent_stream_provider.ProviderAdapter,
) ?model_catalog.Provider {
    if (!std.mem.eql(u8, admitted_adapter_kind, adapter.kind)) return null;
    return adapter.model_catalog;
}

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
        input: model_catalog.FetchInput,
        model: []const u8,
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
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
                    return model_capabilities.capabilitiesForModel(model);
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
            return model_capabilities.capabilitiesForModel(model);
        }
        for (self.catalog.items) |entry| {
            if (std.mem.eql(u8, entry.id, model)) {
                debug_trace.logf(
                    "gateway",
                    "model catalog lookup outcome=ready_hit model={s}",
                    .{model},
                );
                return model_capabilities.resolveCapabilities(
                    model,
                    model_catalog_metadata.fromCatalogEntry(entry),
                );
            }
        }
        debug_trace.logf(
            "gateway",
            "model catalog lookup outcome=missing_entry model={s}",
            .{model},
        );
        return model_capabilities.capabilitiesForModel(model);
    }

    pub fn available(self: *const CapabilityResolver, model: []const u8) model_capabilities.Capabilities {
        if (self.state == .ready) {
            for (self.catalog.items) |entry| {
                if (std.mem.eql(u8, entry.id, model)) {
                    return model_capabilities.resolveCapabilities(
                        model,
                        model_catalog_metadata.fromCatalogEntry(entry),
                    );
                }
            }
        }
        return model_capabilities.capabilitiesForModel(model);
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
                return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
            }
            self.saw_public_retry =
                input.access.authorizationCredential() == null and
                input.access.teamContext() == null and
                input.access.publicOnlyReason() == .authenticated_credential_rejected;
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

test "model catalog selection requires the admitted adapter kind" {
    var fake = FakeCatalog{ .outcome = .ready };
    const adapter = agent_stream_provider.ProviderAdapter{
        .kind = "matching-adapter",
        .model_catalog = fake.provider(),
        .stream_fn = agent_stream_provider.unavailable_adapter.stream_fn,
    };

    const matching = modelCatalogForAdapter("matching-adapter", adapter).?;
    try std.testing.expect(matching.context.? == @as(*anyopaque, @ptrCast(&fake)));
    try std.testing.expect(modelCatalogForAdapter("other-adapter", adapter) == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    var without_catalog = adapter;
    without_catalog.model_catalog = null;
    try std.testing.expect(modelCatalogForAdapter("matching-adapter", without_catalog) == null);
}

test "available capabilities never fetch and use a completed catalog snapshot" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .ready };
    const provider = model_catalog.Provider{ .context = &fake, .fetch_fn = FakeCatalog.fetch };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);

    const cold = resolver.available("provider/model");
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(?u32, null), cold.context_window);
    try std.testing.expectEqual(@as(?u32, null), cold.max_output_tokens);

    _ = try resolver.resolve(
        alloc,
        provider,
        .{ .endpoint = "https://example.invalid" },
        "provider/model",
    );
    const warm = resolver.available("provider/model");
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(?u32, 256_000), warm.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), warm.max_output_tokens);
}

const FakeChatUrl = struct {
    resolved: []const u8,

    fn resolve(raw: ?*anyopaque, fallback: []const u8) []const u8 {
        const self: *FakeChatUrl = @ptrCast(@alignCast(raw.?));
        _ = fallback;
        return self.resolved;
    }
};

test "gateway provider resolves chat url through the injected policy" {
    var fake = FakeChatUrl{ .resolved = "http://127.0.0.1:43123/chat" };
    const provider = ChatUrlProvider{
        .context = &fake,
        .resolve_fn = FakeChatUrl.resolve,
    };

    try std.testing.expectEqualStrings(
        fake.resolved,
        provider.resolve("https://fallback.test/chat"),
    );
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
            .{
                .endpoint = "http://127.0.0.1:1/v1/models",
                .cancel_flag = &cancel_flag,
            },
            "provider/model",
        ),
    );
    try std.testing.expectEqual(CapabilityResolverState.idle, resolver.state);

    fake.outcome = .ready;
    cancel_flag.store(false, .seq_cst);
    const capabilities = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        .{
            .endpoint = "http://127.0.0.1:1/v1/models",
            .cancel_flag = &cancel_flag,
        },
        "provider/model",
    );
    try std.testing.expect(capabilities.supports_vision);
}

test "capability resolver uses provider catalog metadata" {
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(std.testing.allocator);
    var fake = FakeCatalog{ .outcome = .ready };
    var cancel_flag = std.atomic.Value(bool).init(false);

    const capabilities = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        .{
            .access = credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"),
            .endpoint = "/v1/models",
            .cancel_flag = &cancel_flag,
        },
        "provider/model",
    );

    try std.testing.expect(capabilities.supports_vision);
    try std.testing.expect(capabilities.supports_file_input);
    try std.testing.expectEqual(@as(?u32, 256_000), capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), capabilities.max_output_tokens);

    const missing = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        .{
            .endpoint = "/v1/models",
            .cancel_flag = &cancel_flag,
        },
        "zai/glm-4.6",
    );
    try std.testing.expect(!missing.supports_fast_mode);
    try std.testing.expect(!missing.supports_vision);
}

test "capability resolver retries rejected authenticated catalog access anonymously" {
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(std.testing.allocator);
    var fake = FakeCatalog{ .outcome = .authenticated_rejected_then_ready };

    const capabilities = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        .{
            .access = credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"),
            .endpoint = "/v1/models",
        },
        "provider/model",
    );

    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(fake.saw_authenticated_access);
    try std.testing.expect(fake.saw_public_retry);
    try std.testing.expect(capabilities.supports_vision);
}

test "capability resolver degrades terminal catalog failures to local capabilities" {
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(std.testing.allocator);
    var fake = FakeCatalog{ .outcome = .unavailable };
    var cancel_flag = std.atomic.Value(bool).init(false);

    const capabilities = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        .{
            .endpoint = "/v1/models",
            .cancel_flag = &cancel_flag,
        },
        "zai/glm-4.6",
    );
    try std.testing.expect(!capabilities.supports_fast_mode);

    fake.outcome = .ready;
    const cached_failure = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        .{
            .endpoint = "/v1/models",
            .cancel_flag = &cancel_flag,
        },
        "provider/model",
    );
    try std.testing.expect(!cached_failure.supports_vision);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
