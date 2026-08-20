const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const account_usage = @import("account_usage_provider.zig");
const adapter_auth = @import("adapter_auth.zig");
const connection_registry = @import("connection_registry.zig");
const generation_usage = @import("../session/generation_usage_provider.zig");
const host = @import("../hosts/host.zig");
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
    EmptySupportedProtocol,
    DuplicateAdapterKind,
    AuthAdapterKindMismatch,
};

pub const ResolveError = error{
    MissingAdapter,
    UnsupportedProtocol,
    MissingAuthCapability,
    MissingAccountUsageCapability,
    MissingGenerationUsageCapability,
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
            if (adapter.supported_protocol.len == 0) return error.EmptySupportedProtocol;
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
        const adapter = try self.resolve(route.adapter_kind);
        if (!std.mem.eql(u8, adapter.supported_protocol, route.protocol)) {
            return error.UnsupportedProtocol;
        }
        return adapter;
    }

    pub fn resolveProfile(self: AdapterRegistry, profile: connection_registry.Profile) ResolveError!stream_provider.ProviderAdapter {
        const adapter = try self.resolve(profile.adapter_id);
        const protocol = profile.protocol orelse return error.UnsupportedProtocol;
        if (!std.mem.eql(u8, adapter.supported_protocol, protocol)) {
            return error.UnsupportedProtocol;
        }
        return adapter;
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
};

fn unavailableStream(
    _: *const stream_provider.ProviderAdapter,
    _: std.mem.Allocator,
    _: stream_provider.AdapterRequest,
    _: stream_provider.EventSink,
) anyerror!void {}

test "adapter registry rejects invalid manifests and missing kinds" {
    const adapter = stream_provider.ProviderAdapter{
        .kind = "one",
        .supported_protocol = "one",
        .stream_fn = unavailableStream,
    };
    try std.testing.expectError(error.EmptyRegistry, AdapterRegistry.init(&.{}));
    try std.testing.expectError(error.EmptyAdapterKind, AdapterRegistry.init(&.{.{
        .kind = "",
        .supported_protocol = "one",
        .stream_fn = unavailableStream,
    }}));
    try std.testing.expectError(error.EmptySupportedProtocol, AdapterRegistry.init(&.{.{
        .kind = "one",
        .supported_protocol = "",
        .stream_fn = unavailableStream,
    }}));
    try std.testing.expectError(error.DuplicateAdapterKind, AdapterRegistry.init(&.{ adapter, adapter }));
    try std.testing.expectError(error.AuthAdapterKindMismatch, AdapterRegistry.init(&.{.{
        .kind = "one",
        .supported_protocol = "one",
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
        .protocol = @constCast("one"),
        .credential_ref = @constCast("automatic"),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    }));
    const profile = connection_registry.Profile{
        .id = @constCast("one"),
        .display_name = @constCast("One"),
        .adapter_id = @constCast("one"),
        .endpoint = null,
        .protocol = @constCast("one"),
        .credential_ref = @constCast("automatic"),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    };
    try std.testing.expectError(error.MissingAccountUsageCapability, registry.resolveAccountUsageForProfile(profile));
    try std.testing.expectError(error.MissingGenerationUsageCapability, registry.resolveGenerationUsageForProfile(profile));
}

test "adapter registry rejects profile and admitted route protocol mismatches" {
    const registry = try AdapterRegistry.init(&.{.{
        .kind = "one",
        .supported_protocol = "one",
        .stream_fn = unavailableStream,
    }});
    const profile = connection_registry.Profile{
        .id = @constCast("one"),
        .display_name = @constCast("One"),
        .adapter_id = @constCast("one"),
        .endpoint = @constCast("https://example.invalid"),
        .protocol = @constCast("unexpected-protocol"),
        .credential_ref = @constCast("automatic"),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    };
    try std.testing.expectError(error.UnsupportedProtocol, registry.resolveProfile(profile));

    const route = route_snapshot.RouteSnapshot{
        .connection_id = @constCast("one"),
        .adapter_kind = @constCast("one"),
        .endpoint = @constCast("https://example.invalid"),
        .protocol = @constCast("unexpected-protocol"),
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
    try std.testing.expectError(error.UnsupportedProtocol, registry.resolveRoute(&route));
}

test "adapter registry accepts sixteen adapters and rejects seventeen" {
    const adapters = comptime blk: {
        var values: [17]stream_provider.ProviderAdapter = undefined;
        for (&values, 0..) |*adapter, index| {
            adapter.* = .{
                .kind = std.fmt.comptimePrint("adapter-{d}", .{index}),
                .supported_protocol = std.fmt.comptimePrint("adapter-{d}", .{index}),
                .stream_fn = unavailableStream,
            };
        }
        break :blk values;
    };
    try std.testing.expectEqual(@as(usize, 16), (try AdapterRegistry.init(adapters[0..16])).adapters.len);
    try std.testing.expectError(error.TooManyAdapters, AdapterRegistry.init(&adapters));
}

test "Vercel and Example Cloud keep every non-selected effect at zero" {
    const Traffic = struct {
        service_label: []const u8 = "",
        auth: usize = 0,
        environment: usize = 0,
        inventory: usize = 0,
        entry: usize = 0,
        validation: usize = 0,
        persistence: usize = 0,
        reacquisition: usize = 0,
        secret_store: usize = 0,
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
            self.environment += 1;
            return .{ .missing = .not_found };
        }

        fn sourceInventory(
            raw: *const anyopaque,
            alloc: std.mem.Allocator,
            request: *adapter_auth.SourceInventoryRequest,
        ) std.mem.Allocator.Error!adapter_auth.SourceInventoryOutcome {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.inventory += 1;
            const sources = try alloc.alloc(adapter_auth.CredentialSourceDescriptor, 0);
            errdefer alloc.free(sources);
            var origin_profile = try request.profile.clone(alloc);
            errdefer origin_profile.deinit(alloc);
            var presentation = adapter_auth.AuthServicePresentation.init(
                alloc,
                self.service_label,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            errdefer presentation.deinit(alloc);
            return .{ .loaded = .{
                .origin_profile = origin_profile,
                .auth_service = presentation,
                .sources = sources,
            } };
        }

        fn submitEnteredSecret(
            raw: *const anyopaque,
            alloc: std.mem.Allocator,
            submission: *adapter_auth.EnteredSecretSubmission,
        ) adapter_auth.EnteredSecretCompletion {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            self.entry += 1;
            self.validation += 1;
            const report = submission.host.secret_store.storeWithDisposition(
                alloc,
                submission.secret_value.bytes,
            );
            self.persistence += 1;
            if (report.durable_write != .replaced) {
                return adapter_auth.takeEnteredSecretCompletion(alloc, submission, .{
                    .durable_write = report.durable_write,
                    .terminal = .{ .failed = .{
                        .stage = .persistence,
                        .cause = .{ .adapter = .{ .category = .persistence } },
                    } },
                });
            }
            self.reacquisition += 1;
            const token = alloc.dupe(u8, "selected-secret") catch
                return adapter_auth.takeEnteredSecretCompletion(alloc, submission, .{
                    .durable_write = .replaced,
                    .terminal = .{ .failed = .{
                        .stage = .reacquisition,
                        .cause = .allocation,
                    } },
                });
            const source_value = adapter_auth.Source{
                .id = "entered_key",
                .label = "entered key",
                .refreshable = false,
            };
            return adapter_auth.takeEnteredSecretCompletion(alloc, submission, .{
                .durable_write = .replaced,
                .terminal = .{ .acquired = .{
                    .secret_bytes = token,
                    .source = source_value,
                    .catalog_access = .{ .authenticated = .{
                        .source = source_value,
                        .credential = token,
                        .team_context = null,
                    } },
                } },
            });
        }

        fn storeIsDisabled(_: ?*anyopaque) bool {
            return false;
        }

        fn loadSecret(_: ?*anyopaque, _: std.mem.Allocator) host.SecretStoreLoadError!?[]u8 {
            return null;
        }

        fn storeSecret(raw: ?*anyopaque, _: std.mem.Allocator, _: []const u8) host.SecretStoreWriteError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.secret_store += 1;
        }

        fn storeInteractive(_: ?*anyopaque) host.SecretStoreWriteError!bool {
            return false;
        }

        fn storeSecretWithDisposition(
            raw: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) host.SecretStoreWriteReport {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.secret_store += 1;
            return .{ .durable_write = .replaced };
        }

        fn secretStore(self: *@This()) host.SecretStore {
            return .{
                .context = self,
                .backend_label = "test store",
                .is_disabled_fn = storeIsDisabled,
                .load_fn = loadSecret,
                .store_fn = storeSecret,
                .store_interactive_fn = storeInteractive,
                .store_with_disposition_fn = storeSecretWithDisposition,
            };
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
            route_adapter: *const stream_provider.ProviderAdapter,
            _: std.mem.Allocator,
            request: stream_provider.AdapterRequest,
            events: stream_provider.EventSink,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(route_adapter.context.?));
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
                .supported_protocol = kind,
                .auth = .{
                    .kind = kind,
                    .auth_service_label = self.service_label,
                    .context = self,
                    .acquire_fn = acquire,
                    .source_inventory_fn = sourceInventory,
                    .submit_entered_secret_fn = submitEnteredSecret,
                },
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
                self.environment,
                self.inventory,
                self.entry,
                self.validation,
                self.persistence,
                self.reacquisition,
                self.secret_store,
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
            inline for (.{
                self.auth,
                self.environment,
                self.inventory,
                self.entry,
                self.validation,
                self.persistence,
                self.reacquisition,
                self.secret_store,
                self.catalog,
                self.account,
                self.root,
                self.reviewer,
                self.vision,
                self.subagent,
                self.search_calls,
                self.generation_credential,
                self.generation_usage,
            }) |calls| try std.testing.expectEqual(@as(usize, 0), calls);
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
            var inventory_request = adapter_auth.SourceInventoryRequest{
                .profile = try adapter_auth.AuthProfileIdentity.init(alloc, profile),
                .host = .{ .secret_store = selected.secretStore() },
            };
            defer inventory_request.deinit(alloc);
            var inventory_outcome = try (try registry.resolveAuthForProfile(profile)).sourceInventory(
                alloc,
                &inventory_request,
            );
            defer inventory_outcome.deinit(alloc);
            switch (inventory_outcome) {
                .loaded => |inventory| try std.testing.expectEqualStrings(
                    selected.service_label,
                    inventory.auth_service.service_label,
                ),
                else => return error.TestUnexpectedInventoryOutcome,
            }
            var entered_presentation = try adapter_auth.EnteredSecretPresentation.init(
                alloc,
                "API key",
                "Gateway",
                "test store",
            );
            defer entered_presentation.deinit(alloc);
            var submission = adapter_auth.EnteredSecretSubmission{
                .request_id = 1,
                .profile = try adapter_auth.AuthProfileIdentity.init(alloc, profile),
                .source_id = try alloc.dupe(u8, "entered_key"),
                .presentation = try entered_presentation.clone(alloc),
                .secret_value = .{ .bytes = try alloc.dupe(u8, "submitted-secret") },
                .host = .{ .secret_store = selected.secretStore() },
            };
            var completion = (try registry.resolveAuthForProfile(profile)).submitEnteredSecret(
                alloc,
                &submission,
            );
            defer completion.deinit(alloc);
            try std.testing.expect(completion.outcome.terminal == .acquired);
            try std.testing.expectEqualStrings("entered_key", completion.outcome.terminal.acquired.source.id);
            const selected_adapter = try registry.resolveProfile(profile);
            var catalog_result = try selected_adapter.model_catalog.?.fetch(alloc, .{});
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

    var vercel = Traffic{ .service_label = "Vercel" };
    var peer = Traffic{ .service_label = "Example Cloud" };
    const adapters = [_]stream_provider.ProviderAdapter{
        vercel.adapter("vercel_ai_gateway"),
        peer.adapter("test_peer"),
    };
    const registry = try AdapterRegistry.init(&adapters);
    const mismatch_profile = connection_registry.Profile{
        .id = @constCast("vercel_ai_gateway"),
        .display_name = @constCast("Vercel"),
        .adapter_id = @constCast("vercel_ai_gateway"),
        .endpoint = @constCast("https://example.invalid"),
        .protocol = @constCast("test_peer"),
        .credential_ref = @constCast("credential_ref"),
        .remembered_model = @constCast("root"),
        .internal_models = .{},
    };
    try std.testing.expectError(error.UnsupportedProtocol, registry.resolveProfile(mismatch_profile));
    try std.testing.expectError(error.UnsupportedProtocol, registry.resolveAuthForProfile(mismatch_profile));
    try std.testing.expectError(error.UnsupportedProtocol, registry.resolveAccountUsageForProfile(mismatch_profile));
    try std.testing.expectError(error.UnsupportedProtocol, registry.resolveGenerationUsageForProfile(mismatch_profile));
    const mismatch_route = route_snapshot.RouteSnapshot{
        .connection_id = @constCast("vercel_ai_gateway"),
        .adapter_kind = @constCast("vercel_ai_gateway"),
        .endpoint = @constCast("https://example.invalid"),
        .protocol = @constCast("test_peer"),
        .credential_ref = @constCast("credential_ref"),
        .primary_model_id = @constCast("root"),
        .permission_review_model_id = null,
        .vision_model_id = null,
        .subagent_model_id = @constCast("root"),
        .capabilities = .{},
        .capability_source = .configured,
        .selected_fast_mode = false,
        .fast_model_suffix = null,
    };
    try std.testing.expectError(error.UnsupportedProtocol, registry.resolveRoute(&mismatch_route));
    try vercel.expectIdle();
    try peer.expectIdle();

    try Harness.run(std.testing.allocator, registry, "vercel_ai_gateway", &vercel, &peer);
    vercel = .{ .service_label = "Vercel" };
    peer = .{ .service_label = "Example Cloud" };
    try Harness.run(std.testing.allocator, registry, "test_peer", &peer, &vercel);
}
