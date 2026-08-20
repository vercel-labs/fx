const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const account_usage = @import("account_usage_provider.zig");
const adapter_auth = @import("adapter_auth.zig");
const connection_registry = @import("connection_registry.zig");
const generation_usage = @import("../session/generation_usage_provider.zig");
const model_catalog = @import("model_catalog.zig");
const output_contracts = @import("../output/output_contracts.zig");
const route_snapshot = @import("route_snapshot.zig");
const web_search_contract = @import("../tooling/web_search_contract.zig");
const web_search_provider = @import("../tooling/web_search_provider.zig");

const max_adapters: usize = 16;

pub const InitError = error{
    EmptyRegistry,
    TooManyAdapters,
    EmptyAdapterKind,
    DuplicateAdapterKind,
    AuthAdapterKindMismatch,
};

pub const ResolveError = error{
    MissingAdapter,
    MissingAuthCapability,
    MissingAccountUsageCapability,
    MissingGenerationUsageCapability,
    MissingModelCatalogCapability,
};

/// A bounded, borrowed registry assembled once by composition. It owns no
/// adapters, persistence, discovery, or mutation API.
pub const AdapterRegistry = struct {
    adapters: []const stream_provider.ProviderAdapter,

    pub fn init(adapters: []const stream_provider.ProviderAdapter) InitError!AdapterRegistry {
        if (adapters.len == 0) return error.EmptyRegistry;
        if (adapters.len > max_adapters) return error.TooManyAdapters;
        for (adapters, 0..) |adapter, index| {
            if (adapter.kind.len == 0) return error.EmptyAdapterKind;
            if (adapter.auth) |auth| {
                if (!std.mem.eql(u8, adapter.kind, auth.kind)) return error.AuthAdapterKindMismatch;
            }
            for (adapters[0..index]) |previous| {
                if (std.mem.eql(u8, adapter.kind, previous.kind)) return error.DuplicateAdapterKind;
            }
        }
        return .{ .adapters = adapters };
    }

    pub fn resolve(self: AdapterRegistry, kind: []const u8) ResolveError!stream_provider.ProviderAdapter {
        for (self.adapters) |adapter| {
            if (std.mem.eql(u8, adapter.kind, kind)) return adapter;
        }
        return error.MissingAdapter;
    }

    pub fn resolveRoute(self: AdapterRegistry, route: *const route_snapshot.RouteSnapshot) ResolveError!stream_provider.ProviderAdapter {
        return self.resolve(route.adapter_kind);
    }

    pub fn resolveProfile(self: AdapterRegistry, profile: connection_registry.Profile) ResolveError!stream_provider.ProviderAdapter {
        return self.resolve(profile.adapter_id);
    }

    pub fn resolveAuthForProfile(self: AdapterRegistry, profile: connection_registry.Profile) ResolveError!@import("adapter_auth.zig").Provider {
        const adapter = try self.resolveProfile(profile);
        return adapter.auth orelse error.MissingAuthCapability;
    }

    pub fn resolveAccountUsageForProfile(self: AdapterRegistry, profile: connection_registry.Profile) ResolveError!account_usage.Provider {
        const adapter = try self.resolveProfile(profile);
        return adapter.account_usage orelse error.MissingAccountUsageCapability;
    }

    pub fn resolveGenerationUsageForProfile(self: AdapterRegistry, profile: connection_registry.Profile) ResolveError!generation_usage.Provider {
        const adapter = try self.resolveProfile(profile);
        return adapter.generation_usage orelse error.MissingGenerationUsageCapability;
    }

    pub fn resolveModelCatalogForProfile(self: AdapterRegistry, profile: connection_registry.Profile) ResolveError!model_catalog.Provider {
        const adapter = try self.resolveProfile(profile);
        return adapter.model_catalog orelse error.MissingModelCatalogCapability;
    }
};

fn unavailableStream(
    _: *const stream_provider.ProviderAdapter,
    _: std.mem.Allocator,
    _: stream_provider.AdapterRequest,
    _: stream_provider.EventSink,
) anyerror!void {}

test "adapter registry rejects invalid manifests and missing kinds" {
    const adapter = stream_provider.ProviderAdapter{ .kind = "one", .stream_fn = unavailableStream };
    try std.testing.expectError(error.EmptyRegistry, AdapterRegistry.init(&.{}));
    try std.testing.expectError(error.EmptyAdapterKind, AdapterRegistry.init(&.{.{ .kind = "", .stream_fn = unavailableStream }}));
    try std.testing.expectError(error.DuplicateAdapterKind, AdapterRegistry.init(&.{ adapter, adapter }));
    try std.testing.expectError(error.AuthAdapterKindMismatch, AdapterRegistry.init(&.{.{
        .kind = "one",
        .auth = .{ .kind = "two" },
        .stream_fn = unavailableStream,
    }}));

    const registry = try AdapterRegistry.init(&.{adapter});
    try std.testing.expectError(error.MissingAdapter, registry.resolve("two"));
    var route = route_snapshot.RouteSnapshot{
        .connection_id = @constCast("two"),
        .adapter_kind = @constCast("two"),
        .endpoint = @constCast("https://example.invalid"),
        .protocol = @constCast("two"),
        .credential_ref = @constCast("automatic"),
        .primary_model_id = @constCast("model"),
        .permission_review_model_id = null,
        .vision_model_id = null,
        .subagent_model_id = @constCast("model"),
        .capabilities = .{},
        .capability_source = .configured,
        .selected_fast_mode = false,
        .fast_model_suffix = null,
    };
    try std.testing.expectError(error.MissingAdapter, registry.resolveRoute(&route));
    try std.testing.expectError(error.MissingAuthCapability, registry.resolveAuthForProfile(.{
        .id = @constCast("one"),
        .display_name = @constCast("One"),
        .adapter_id = @constCast("one"),
        .endpoint = null,
        .protocol = null,
        .credential_ref = @constCast("automatic"),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    }));
    const profile = connection_registry.Profile{
        .id = @constCast("one"),
        .display_name = @constCast("One"),
        .adapter_id = @constCast("one"),
        .endpoint = null,
        .protocol = null,
        .credential_ref = @constCast("automatic"),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    };
    try std.testing.expectError(error.MissingAccountUsageCapability, registry.resolveAccountUsageForProfile(profile));
    try std.testing.expectError(error.MissingGenerationUsageCapability, registry.resolveGenerationUsageForProfile(profile));
    try std.testing.expectError(error.MissingModelCatalogCapability, registry.resolveModelCatalogForProfile(profile));
}

test "adapter registry accepts sixteen adapters and rejects seventeen" {
    const adapters = comptime blk: {
        var values: [17]stream_provider.ProviderAdapter = undefined;
        for (&values, 0..) |*adapter, index| {
            adapter.* = .{
                .kind = std.fmt.comptimePrint("adapter-{d}", .{index}),
                .stream_fn = unavailableStream,
            };
        }
        break :blk values;
    };
    try std.testing.expectEqual(@as(usize, 16), (try AdapterRegistry.init(adapters[0..16])).adapters.len);
    try std.testing.expectError(error.TooManyAdapters, AdapterRegistry.init(&adapters));
}

test "Vercel and test peer traffic follows profile route and prepared dispatch authorities" {
    const Traffic = struct {
        auth: usize = 0,
        catalog: usize = 0,
        account: usize = 0,
        root: usize = 0,
        reviewer: usize = 0,
        vision: usize = 0,
        subagent: usize = 0,
        search_calls: usize = 0,
        generation_credential: usize = 0,
        generation_usage: usize = 0,

        fn acquire(
            raw: *const anyopaque,
            _: std.mem.Allocator,
            _: adapter_auth.Request,
        ) std.mem.Allocator.Error!adapter_auth.Acquisition {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.auth += 1;
            return .{ .missing = .not_found };
        }

        fn fetchCatalog(
            raw: ?*anyopaque,
            _: std.mem.Allocator,
            _: model_catalog.FetchInput,
        ) std.mem.Allocator.Error!model_catalog.ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.catalog += 1;
            return .{ .catalog = .empty };
        }

        fn fetchAccount(
            raw: ?*anyopaque,
            _: std.mem.Allocator,
            _: account_usage.Input,
        ) output_contracts.CreditsSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.account += 1;
            return .{};
        }

        fn stream(
            provider_adapter: *const stream_provider.ProviderAdapter,
            _: std.mem.Allocator,
            request: stream_provider.AdapterRequest,
            events: stream_provider.EventSink,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(provider_adapter.context.?));
            if (std.mem.eql(u8, request.model_id, "root")) self.root += 1 else if (std.mem.eql(u8, request.model_id, "reviewer")) self.reviewer += 1 else if (std.mem.eql(u8, request.model_id, "vision")) self.vision += 1 else if (std.mem.eql(u8, request.model_id, "subagent")) self.subagent += 1 else return error.TestUnexpectedModel;
            try events.emit(.provider_admitted);
            try events.emit(.{ .finish = .{ .reason = .stop } });
        }

        fn preferredBackends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
            return null;
        }

        fn search(
            raw: ?*anyopaque,
            _: std.mem.Allocator,
            _: web_search_provider.Inputs,
            _: web_search_contract.ProviderRequest,
            _: ?web_search_contract.ProgressFn,
            _: ?*anyopaque,
        ) anyerror!web_search_contract.ProviderResponse {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.search_calls += 1;
            return .{};
        }

        fn resolveGenerationCredential(
            raw: ?*anyopaque,
            alloc: std.mem.Allocator,
            reference: generation_usage.CredentialReference,
        ) generation_usage.ResolveCredentialError!generation_usage.ResolvedCredential {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (reference.connection_id.len == 0 or reference.adapter_kind.len == 0) {
                return error.Unavailable;
            }
            self.generation_credential += 1;
            return .{ .token = try alloc.dupe(u8, "credential") };
        }

        fn lookupGeneration(
            raw: ?*anyopaque,
            _: std.mem.Allocator,
            _: generation_usage.LookupInput,
        ) generation_usage.LookupError!generation_usage.LookupOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.generation_usage += 1;
            return .preserve_pending;
        }

        fn adapter(self: *@This(), kind: []const u8) stream_provider.ProviderAdapter {
            return .{
                .kind = kind,
                .auth = .{ .kind = kind, .context = self, .acquire_fn = acquire },
                .context = self,
                .account_usage = .{ .context = self, .fetch_fn = fetchAccount },
                .generation_usage = .{ .context = self, .lookup_fn = lookupGeneration },
                .model_catalog = .{ .context = self, .fetch_fn = fetchCatalog },
                .web_search = .{
                    .context = self,
                    .policy = .{},
                    .preferred_backends_fn = preferredBackends,
                    .execute_fn = search,
                },
                .stream_fn = stream,
            };
        }

        fn expectSelected(self: @This()) !void {
            inline for (.{
                self.auth,
                self.catalog,
                self.account,
                self.root,
                self.reviewer,
                self.vision,
                self.subagent,
                self.search_calls,
                self.generation_credential,
                self.generation_usage,
            }) |calls| try std.testing.expectEqual(@as(usize, 1), calls);
        }

        fn expectIdle(self: @This()) !void {
            try std.testing.expectEqual(@as(@TypeOf(self), .{}), self);
        }
    };

    const Harness = struct {
        fn emit(_: *anyopaque, _: stream_provider.StreamEvent) anyerror!void {}

        fn streamOnce(
            alloc: std.mem.Allocator,
            adapter: stream_provider.ProviderAdapter,
            route: *const route_snapshot.RouteSnapshot,
            model: []const u8,
        ) !void {
            var state = stream_provider.EventState.init(alloc);
            defer state.deinit();
            var sink_error: ?anyerror = null;
            var cancel = std.atomic.Value(bool).init(false);
            var delivery = stream_provider.DeliveryCertainty.init();
            var attempt_evidence: stream_provider.AttemptEvidence = .{};
            try adapter.stream(alloc, .{
                .model_request = .{
                    .tools = &.{},
                    .messages = &.{},
                    .tool_choice = .none,
                    .capabilities = .{},
                },
                .route = route,
                .credential = "credential",
                .tenant = null,
                .model_id = model,
                .retry_count = 0,
                .trace_ctx = .{},
                .content_capture_limit = null,
                .delivery = &delivery,
                .attempt_evidence = &attempt_evidence,
                .cancel_flag = &cancel,
            }, .{
                .context = @ptrCast(&state),
                .state = &state,
                .sink_error = &sink_error,
                .emit_fn = emit,
            });
        }

        fn run(
            alloc: std.mem.Allocator,
            registry: AdapterRegistry,
            kind: []const u8,
            selected: *Traffic,
            other: *Traffic,
        ) !void {
            const profile = connection_registry.Profile{
                .id = @constCast(kind),
                .display_name = @constCast(kind),
                .adapter_id = @constCast(kind),
                .endpoint = @constCast("https://example.invalid"),
                .protocol = @constCast(kind),
                .credential_ref = @constCast("credential_ref"),
                .remembered_model = @constCast("root"),
                .internal_models = .{
                    .permission_review = @constCast("reviewer"),
                    .vision = @constCast("vision"),
                    .subagent = @constCast("subagent"),
                },
            };
            _ = try registry.resolveProfile(profile);
            var acquisition = try (try registry.resolveAuthForProfile(profile)).acquire(
                alloc,
                .{
                    .profile = profile,
                    .host = .{ .secret_store = @import("../hosts/host.zig").unavailable_secret_store },
                    .mode = .stored,
                    .source_resolution = .exact,
                },
            );
            switch (acquisition) {
                .acquired => |*credential| credential.deinit(alloc),
                .missing => {},
                .failed, .cancelled => return error.TestUnexpectedAuthOutcome,
            }
            var catalog_result = try (try registry.resolveModelCatalogForProfile(profile)).fetch(
                alloc,
                .{ .endpoint = "/models" },
            );
            switch (catalog_result) {
                .catalog => |*catalog| model_catalog.freeModelCatalog(alloc, catalog),
                .failure => return error.TestUnexpectedCatalogFailure,
            }
            var account = (try registry.resolveAccountUsageForProfile(profile)).fetch(
                alloc,
                .{ .credential = "credential", .tenant = null },
            );
            account.deinit(alloc);

            const route = route_snapshot.RouteSnapshot{
                .connection_id = @constCast(kind),
                .adapter_kind = @constCast(kind),
                .endpoint = @constCast("https://example.invalid"),
                .protocol = @constCast(kind),
                .credential_ref = @constCast("credential_ref"),
                .primary_model_id = @constCast("root"),
                .permission_review_model_id = @constCast("reviewer"),
                .vision_model_id = @constCast("vision"),
                .subagent_model_id = @constCast("subagent"),
                .capabilities = .{},
                .capability_source = .configured,
                .selected_fast_mode = false,
                .fast_model_suffix = null,
            };
            const route_adapter = try registry.resolveRoute(&route);
            inline for (.{ "root", "reviewer", "vision", "subagent" }) |model| {
                try streamOnce(alloc, route_adapter, &route, model);
            }
            var cancel = std.atomic.Value(bool).init(false);
            var search_result = try route_adapter.web_search.?.execute(
                alloc,
                .{
                    .connection_id = kind,
                    .credential = "credential",
                    .model = "root",
                    .retry_count = 0,
                    .endpoint = route.endpoint,
                },
                .{
                    .backend = .{ .value = "test" },
                    .query = "query",
                    .cancel_flag = &cancel,
                },
                null,
                null,
            );
            search_result.deinit(alloc);

            var dispatch = try generation_usage.Dispatch.init(alloc, &.{.{
                .id = profile.id,
                .adapter_kind = profile.adapter_id,
                .credential_ref = profile.credential_ref,
                .provider = try registry.resolveGenerationUsageForProfile(profile),
            }}, .{
                .context = selected,
                .resolve_fn = Traffic.resolveGenerationCredential,
            });
            defer dispatch.deinit(alloc);
            try std.testing.expectEqual(
                generation_usage.LookupOutcome.preserve_pending,
                try dispatch.lookup(alloc, profile.id, "generation", null, &cancel),
            );
            try selected.expectSelected();
            try other.expectIdle();
        }
    };

    var vercel: Traffic = .{};
    var peer: Traffic = .{};
    const adapters = [_]stream_provider.ProviderAdapter{
        vercel.adapter("vercel_ai_gateway"),
        peer.adapter("test_peer"),
    };
    const registry = try AdapterRegistry.init(&adapters);
    try Harness.run(std.testing.allocator, registry, "vercel_ai_gateway", &vercel, &peer);
    vercel = .{};
    peer = .{};
    try Harness.run(std.testing.allocator, registry, "test_peer", &peer, &vercel);
}
