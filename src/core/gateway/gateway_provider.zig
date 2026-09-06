const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const output_contracts = @import("../output/output_contracts.zig");
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

pub const CliModelCatalogInput = struct {
    access: credentials.CatalogAccess = .{ .public_only = .no_credential },
    endpoint: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const CliModelCatalogResult = union(enum) {
    loaded: struct {
        /// Owned model id strings; the caller frees them with `collections.freeStringList`.
        ids: std.ArrayList([]u8),
        provenance: model_catalog.Provenance,
    },
    failure: model_catalog.FailedOutcome,
};

pub const FetchCliModelCatalogFn = *const fn (
    ?*anyopaque,
    Allocator,
    CliModelCatalogInput,
) CliModelCatalogResult;

pub const CliModelCatalogProvider = struct {
    /// When set, context must remain valid until every in-flight `fetch` returns.
    context: ?*anyopaque = null,
    fetch_fn: FetchCliModelCatalogFn,

    pub fn fetch(
        self: CliModelCatalogProvider,
        alloc: Allocator,
        input: CliModelCatalogInput,
    ) CliModelCatalogResult {
        return self.fetch_fn(self.context, alloc, input);
    }
};

pub const CreditsLookupInput = struct {
    credential: ?[]const u8,
    credential_source: ?credentials.Source = null,
    tenant: ?[]const u8,
};

pub const FetchCreditsFn = *const fn (
    ?*anyopaque,
    Allocator,
    CreditsLookupInput,
) output_contracts.CreditsSnapshot;

pub const CreditsProvider = struct {
    /// When set, context must remain valid until every in-flight `fetch` returns.
    context: ?*anyopaque = null,
    fetch_fn: FetchCreditsFn,

    /// The returned snapshot owns its populated provider fields. The caller
    /// must call `CreditsSnapshot.deinit`.
    pub fn fetch(
        self: CreditsProvider,
        alloc: Allocator,
        input: CreditsLookupInput,
    ) output_contracts.CreditsSnapshot {
        return self.fetch_fn(self.context, alloc, input);
    }
};

fn fetchCreditsUnavailable(
    _: ?*anyopaque,
    alloc: Allocator,
    _: CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return .{
        .err_message = alloc.dupe(u8, "Credits are unavailable for the selected provider.") catch null,
    };
}

pub const unavailable_credits_provider = CreditsProvider{
    .fetch_fn = fetchCreditsUnavailable,
};

pub const Provider = struct {
    oauth_transport: oauth_transport.Provider,
    chat_url: ChatUrlProvider,
};

test "credits lookup dispatches through the injected provider" {
    const Fake = struct {
        calls: usize = 0,
        saw_expected_input: bool = false,

        fn fetch(
            raw: ?*anyopaque,
            alloc: Allocator,
            input: CreditsLookupInput,
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
    const provider = CreditsProvider{
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
    last_attempt_ms: i64 = 0,
    requested_access: ?model_catalog.AccessMetadata = null,
    provider_id: ?model_provider.ProviderId = null,

    pub fn deinit(self: *CapabilityResolver, alloc: Allocator) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
    }

    /// The owner must exclude capability readers during refresh. Borrowed
    /// catalog entries stay valid until the next exclusive refresh or adoption.
    pub fn refreshIfDue(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
    ) model_capabilities.ResolveError!void {
        const now = io_mod.milliTimestamp();
        const requested = model_catalog.AccessMetadata.init(input.access);
        const access_changed = self.provider_id != provider.provider_id or
            self.requested_access == null or !std.meta.eql(self.requested_access.?, requested);
        const expired = if (provider.refresh_interval_ms) |interval|
            now < self.last_attempt_ms or now - self.last_attempt_ms >= interval
        else
            false;
        if (self.state != .idle and !access_changed and !expired) return;

        const result = model_catalog.fetchWithPublicFallback(provider, alloc, input);
        const loaded = switch (result) {
            .loaded => |loaded| loaded,
            .failed => |failed| {
                if (failed.failure.category == .cancellation) return error.Cancelled;
                self.last_attempt_ms = now;
                self.requested_access = requested;
                self.provider_id = provider.provider_id;
                if (access_changed) {
                    if (self.catalog.items.len > 0) debug_trace.logf("gateway", "dropping model catalog after access changed entries={d}", .{self.catalog.items.len});
                    model_catalog.freeModelCatalog(alloc, &self.catalog);
                    self.catalog = .empty;
                }
                if (self.catalog.items.len == 0) self.state = .failed;
                debug_trace.logf("gateway", "model catalog refresh failed category={t} retained={}", .{ failed.failure.category, self.state == .ready });
                return;
            },
        };
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = loaded.catalog;
        self.state = .ready;
        self.last_attempt_ms = now;
        self.requested_access = requested;
        self.provider_id = provider.provider_id;
    }

    pub fn resolve(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        if (self.state == .idle) {
            try self.refreshIfDue(alloc, provider, input);
        }

        if (self.state == .failed) {
            debug_trace.logf(
                "gateway",
                "model catalog lookup outcome=cache_failed model={s}",
                .{model},
            );
            return fallback;
        }
        for (self.catalog.items) |entry| {
            if (std.mem.eql(u8, entry.id, model)) {
                debug_trace.logf(
                    "gateway",
                    "model catalog lookup outcome=ready_hit model={s}",
                    .{model},
                );
                return model_capabilities.mergeCapabilities(
                    fallback,
                    model_catalog_metadata.fromCatalogEntry(entry),
                );
            }
        }
        debug_trace.logf(
            "gateway",
            "model catalog lookup outcome=missing_entry model={s}",
            .{model},
        );
        return fallback;
    }

    pub fn available(
        self: *const CapabilityResolver,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
    ) model_capabilities.Capabilities {
        if (self.state == .ready) {
            for (self.catalog.items) |entry| {
                if (std.mem.eql(u8, entry.id, model)) {
                    return model_capabilities.mergeCapabilities(
                        fallback,
                        model_catalog_metadata.fromCatalogEntry(entry),
                    );
                }
            }
        }
        return fallback;
    }

    pub fn catalogEntries(self: *const CapabilityResolver) ?[]const model_catalog.ModelCatalogEntry {
        if (self.state != .ready) return null;
        return self.catalog.items;
    }

    pub fn adoptOwnedCatalog(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
        owned_catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    ) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = owned_catalog.*;
        owned_catalog.* = .empty;
        self.state = .ready;
        self.last_attempt_ms = io_mod.milliTimestamp();
        self.requested_access = .init(access);
        self.provider_id = provider.provider_id;
    }
};

inline fn failCapabilities(err: anytype) @TypeOf(err)!model_capabilities.Capabilities {
    return @errorCast(failCapabilitiesDynamic(err));
}

noinline fn failCapabilitiesDynamic(err: anyerror) anyerror!model_capabilities.Capabilities {
    return err;
}

test "capability failure writer preserves exact error type and identity" {
    const failure = failCapabilities(error.Cancelled);
    try std.testing.expect(
        @TypeOf(failure) == error{Cancelled}!model_capabilities.Capabilities,
    );
    try std.testing.expectError(error.Cancelled, failure);
}

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

test "capability resolver refreshes expired snapshots at the owner boundary and retains a usable catalog" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .unavailable };
    var provider = fake.provider();
    provider.refresh_interval_ms = 60_000;
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    const input = model_catalog.FetchInput{ .endpoint = "https://example.invalid" };
    try resolver.refreshIfDue(alloc, provider, input);
    try std.testing.expect(resolver.catalogEntries() == null);
    fake.outcome = .ready;
    try resolver.refreshIfDue(alloc, provider, input);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    resolver.last_attempt_ms -= 60_000;
    // Worker capability reads keep the established snapshot until its owner refreshes.
    _ = try resolver.resolve(alloc, provider, input, "provider/model", .{});
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try resolver.refreshIfDue(alloc, provider, input);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), resolver.catalogEntries().?.len);
    fake.outcome = .unavailable;
    resolver.last_attempt_ms -= 60_000;
    try resolver.refreshIfDue(alloc, provider, input);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqualStrings("provider/model", resolver.catalogEntries().?[0].id);
}

test "capability refresh does not retain a catalog for changed access" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .ready };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    try resolver.refreshIfDue(alloc, fake.provider(), .{ .endpoint = "https://example.invalid" });
    fake.outcome = .unavailable;
    try resolver.refreshIfDue(alloc, fake.provider(), .{
        .endpoint = "https://example.invalid",
        .access = .host_managed,
    });
    try std.testing.expect(resolver.catalogEntries() == null);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "capability refresh keys host-managed catalogs by provider" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .ready };
    var provider = fake.provider();
    provider.refresh_interval_ms = 60_000;
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    const input = model_catalog.FetchInput{ .endpoint = "https://example.invalid", .access = .host_managed };
    try resolver.refreshIfDue(alloc, provider, input);
    provider.provider_id = .codex;
    try resolver.refreshIfDue(alloc, provider, input);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    fake.outcome = .unavailable;
    provider.provider_id = .grok;
    try resolver.refreshIfDue(alloc, provider, input);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expect(resolver.catalogEntries() == null);
}

test "available capabilities never fetch and use a completed catalog snapshot" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .ready };
    const provider = model_catalog.Provider{ .context = &fake, .fetch_fn = FakeCatalog.fetch };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);

    const cold = resolver.available("provider/model", .{});
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(?u32, null), cold.context_window);
    try std.testing.expectEqual(@as(?u32, null), cold.max_output_tokens);

    _ = try resolver.resolve(
        alloc,
        provider,
        .{ .endpoint = "https://example.invalid" },
        "provider/model",
        .{},
    );
    const warm = resolver.available("provider/model", .{});
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
            .{},
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
        .{},
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
        .{},
    );

    try std.testing.expect(capabilities.supports_vision);
    try std.testing.expect(capabilities.supports_file_input);
    try std.testing.expectEqual(model_capabilities.ImageInputSupport.native, capabilities.image_input_support);
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
        .{},
    );
    try std.testing.expect(!missing.supports_fast_mode);
    try std.testing.expect(!missing.supports_vision);
    try std.testing.expectEqual(model_capabilities.ImageInputSupport.unknown, missing.image_input_support);
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
        .{},
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
        .{},
    );
    try std.testing.expect(!capabilities.supports_fast_mode);
    try std.testing.expectEqual(model_capabilities.ImageInputSupport.unknown, capabilities.image_input_support);

    fake.outcome = .ready;
    const cached_failure = try resolver.resolve(
        std.testing.allocator,
        fake.provider(),
        .{
            .endpoint = "/v1/models",
            .cancel_flag = &cancel_flag,
        },
        "provider/model",
        .{},
    );
    try std.testing.expect(!cached_failure.supports_vision);
    try std.testing.expectEqual(model_capabilities.ImageInputSupport.unknown, cached_failure.image_input_support);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
