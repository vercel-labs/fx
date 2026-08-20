const std = @import("std");
const adapter_auth = @import("adapter_auth.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const collections = @import("../shared/collections.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const View = enum {
    full,
    picker,
};

pub const FetchInput = struct {
    access: adapter_auth.CatalogAccess = .{ .public_only = .{ .reason = .no_credential } },
    cancel_flag: ?*std.atomic.Value(bool) = null,
    view: View = .full,
};

pub const FailureCategory = enum {
    authentication,
    rate_limited,
    unavailable,
    cancellation,
    transport,
    invalid_content,
    protocol,
    resource_exhausted,
    runtime,
};

pub const Failure = struct {
    category: FailureCategory,
    http_status: ?u16 = null,
    retryable: bool = false,

    pub fn asError(self: Failure) error{
        AuthenticationRejected,
        Cancelled,
        CatalogUnavailable,
        MalformedResponse,
        OutOfMemory,
        RateLimited,
        TransportFailure,
        Unavailable,
    } {
        return switch (self.category) {
            .authentication => error.AuthenticationRejected,
            .rate_limited => error.RateLimited,
            .unavailable => error.CatalogUnavailable,
            .cancellation => error.Cancelled,
            .transport => error.TransportFailure,
            .invalid_content => error.MalformedResponse,
            .resource_exhausted => error.OutOfMemory,
            .protocol, .runtime => error.Unavailable,
        };
    }

    pub fn allowsPublicFallback(self: Failure) bool {
        return self.category == .authentication;
    }
};

pub const AccessLevel = enum {
    authenticated,
    public_only,
};

pub const AccessMetadata = struct {
    level: AccessLevel,
    source: ?adapter_auth.Source,
    public_only_reason: ?adapter_auth.CatalogPublicOnlyReason,
    private_models_may_be_hidden: bool,

    pub fn init(access: adapter_auth.CatalogAccess) AccessMetadata {
        const public_only_reason = access.publicOnlyReason();
        return .{
            .level = if (public_only_reason == null) .authenticated else .public_only,
            .source = access.credentialSource(),
            .public_only_reason = public_only_reason,
            .private_models_may_be_hidden = public_only_reason != null,
        };
    }
};

pub const Provenance = struct {
    access: AccessMetadata,
    anonymous_fallback_used: bool = false,
    fallback_failure: ?Failure = null,
};

pub const FailedOutcome = struct {
    access: AccessMetadata,
    anonymous_fallback_used: bool,
    failure: Failure,
};

pub const ProviderResult = union(enum) {
    catalog: std.ArrayList(ModelCatalogEntry),
    failure: Failure,
};

pub const FetchFn = *const fn (
    ?*anyopaque,
    Allocator,
    FetchInput,
) Allocator.Error!ProviderResult;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight `fetch` returns.
    context: ?*anyopaque = null,
    fetch_fn: FetchFn,

    /// Returns owned catalog entries; the caller frees them with `freeModelCatalog`.
    pub fn fetch(self: Provider, alloc: Allocator, input: FetchInput) Allocator.Error!ProviderResult {
        return self.fetch_fn(self.context, alloc, input);
    }
};

pub const FetchResult = union(enum) {
    loaded: struct {
        /// Owned catalog entries; the caller frees them with `freeModelCatalog`.
        catalog: std.ArrayList(ModelCatalogEntry),
        provenance: Provenance,
    },
    failed: FailedOutcome,
};

fn failedOutcome(access: adapter_auth.CatalogAccess, anonymous_fallback_used: bool, failure: Failure) FetchResult {
    return .{ .failed = .{
        .access = .init(access),
        .anonymous_fallback_used = anonymous_fallback_used,
        .failure = failure,
    } };
}

pub fn fetchWithPublicFallback(
    provider: Provider,
    alloc: Allocator,
    input: FetchInput,
) FetchResult {
    const requested_access = AccessMetadata.init(input.access);
    const result = fetchWithPublicFallbackUntraced(provider, alloc, input);
    traceCatalogLoad(requested_access, &result);
    return result;
}

fn fetchWithPublicFallbackUntraced(
    provider: Provider,
    alloc: Allocator,
    input: FetchInput,
) FetchResult {
    var attempt = input;
    const first = provider.fetch(alloc, attempt) catch
        return failedOutcome(attempt.access, false, .{ .category = .resource_exhausted });
    switch (first) {
        .catalog => |catalog| return .{ .loaded = .{
            .catalog = catalog,
            .provenance = .{ .access = .init(attempt.access) },
        } },
        .failure => |failure| {
            if (!failure.allowsPublicFallback()) {
                return failedOutcome(attempt.access, false, failure);
            }
            attempt.access = attempt.access.publicFallbackAfterRejection() orelse
                return failedOutcome(attempt.access, false, failure);

            const fallback = provider.fetch(alloc, attempt) catch
                return failedOutcome(attempt.access, true, .{ .category = .resource_exhausted });
            return switch (fallback) {
                .catalog => |catalog| .{ .loaded = .{
                    .catalog = catalog,
                    .provenance = .{
                        .access = .init(attempt.access),
                        .anonymous_fallback_used = true,
                        .fallback_failure = failure,
                    },
                } },
                .failure => |fallback_failure| failedOutcome(attempt.access, true, fallback_failure),
            };
        },
    }
}

fn traceCatalogLoad(requested: AccessMetadata, result: *const FetchResult) void {
    switch (result.*) {
        .loaded => |loaded| traceCatalogLoadOutcome(
            requested,
            loaded.provenance.access,
            loaded.provenance.anonymous_fallback_used,
            "loaded",
            loaded.provenance.fallback_failure,
        ),
        .failed => |failed| traceCatalogLoadOutcome(
            requested,
            failed.access,
            failed.anonymous_fallback_used,
            "failed",
            failed.failure,
        ),
    }
}

fn traceCatalogLoadOutcome(
    requested: AccessMetadata,
    effective: AccessMetadata,
    anonymous_fallback_used: bool,
    outcome: []const u8,
    failure: ?Failure,
) void {
    const credential_source = if (requested.source) |source| source.id else "none";
    var public_only_reason_buffer: [adapter_auth.max_credential_source_id_bytes + 32]u8 = undefined;
    const public_only_reason = catalogReasonTraceLabel(&public_only_reason_buffer, effective);
    const failure_category = if (failure) |detail| @tagName(detail.category) else "none";
    var http_status_buffer: [5]u8 = undefined;
    const http_status = if (failure) |detail|
        if (detail.http_status) |status|
            std.fmt.bufPrint(&http_status_buffer, "{d}", .{status}) catch "none"
        else
            "none"
    else
        "none";
    const retryable = if (failure) |detail|
        if (detail.retryable) "true" else "false"
    else
        "none";
    const common_format = "requested_access={s} credential_source={s} effective_access={s} public_only_reason={s} anonymous_fallback={s} outcome={s} failure_category={s} http_status={s}";
    const common_args = .{
        @tagName(requested.level),
        credential_source,
        @tagName(effective.level),
        public_only_reason,
        if (anonymous_fallback_used) "true" else "false",
        outcome,
        failure_category,
        http_status,
    };

    debug_trace.eventf(
        "catalog",
        "model_catalog_load",
        .{},
        common_format ++ " retryable={s}",
        common_args ++ .{retryable},
    );
}

fn catalogReasonTraceLabel(
    buffer: *[adapter_auth.max_credential_source_id_bytes + 32]u8,
    access: AccessMetadata,
) []const u8 {
    const reason = access.public_only_reason orelse return "none";
    return switch (reason) {
        .no_credential => "no_credential",
        .tenant_required => if (access.source) |source|
            std.fmt.bufPrint(buffer, "{s}_team_required", .{source.id}) catch "tenant_required"
        else
            "tenant_required",
        .refresh_required => if (access.source) |source|
            std.fmt.bufPrint(buffer, "{s}_refresh_required", .{source.id}) catch "refresh_required"
        else
            "refresh_required",
        .refresh_failed => "credential_refresh_failed",
        .credential_rejected => "authenticated_credential_rejected",
    };
}

pub const ModelCatalogEntry = struct {
    id: []u8,
    model_type: []u8,
    released: i64 = 0,
    has_tool_use: bool = false,
    has_reasoning: bool = false,
    reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty,
    supports_fast_mode: bool = false,
    has_vision: bool = false,
    has_file_input: bool = false,
    has_web_search: bool = false,
    has_explicit_caching: bool = false,
    has_implicit_caching: bool = false,
    context_window: u32 = 0,
    max_tokens: u32 = 0,
    web_search_price: ?[]u8 = null,
};

pub const ModelDescriptorProvider = struct {
    context: ?*anyopaque = null,
    fallback_fn: *const fn (?*anyopaque, []const u8) model_capabilities.ModelDescriptor,
    catalog_fn: *const fn (?*anyopaque, ModelCatalogEntry) model_capabilities.ModelDescriptor,

    pub fn fallback(self: ModelDescriptorProvider, model: []const u8) model_capabilities.ModelDescriptor {
        return self.fallback_fn(self.context, model);
    }

    pub fn catalog(self: ModelDescriptorProvider, entry: ModelCatalogEntry) model_capabilities.ModelDescriptor {
        return self.catalog_fn(self.context, entry);
    }

    pub fn resolve(
        self: ModelDescriptorProvider,
        entries: []const ModelCatalogEntry,
        selected_model: []const u8,
    ) model_capabilities.ModelDescriptor {
        const fallback_descriptor = self.fallback(selected_model);

        // A canonical row is the authority when both it and an alias are present.
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, fallback_descriptor.id)) {
                return catalogSelection(fallback_descriptor, self.catalog(entry));
            }
        }
        // Without a canonical row, catalog order selects the normalized alias.
        for (entries) |entry| {
            const descriptor = self.catalog(entry);
            if (std.mem.eql(u8, descriptor.id, fallback_descriptor.id)) {
                return catalogSelection(fallback_descriptor, descriptor);
            }
        }
        return fallback_descriptor;
    }
};

fn catalogSelection(
    fallback: model_capabilities.ModelDescriptor,
    catalog: model_capabilities.ModelDescriptor,
) model_capabilities.ModelDescriptor {
    std.debug.assert(catalog.source == .catalog);
    var resolved = catalog;
    resolved.id = fallback.id;
    resolved.display_name = fallback.display_name;
    resolved.provider = fallback.provider;
    resolved.selected_fast_mode = fallback.selected_fast_mode;
    return resolved;
}

fn configuredModelDescriptor(_: ?*anyopaque, model: []const u8) model_capabilities.ModelDescriptor {
    return model_capabilities.configuredDescriptor(model, .{});
}

fn configuredCatalogDescriptor(_: ?*anyopaque, entry: ModelCatalogEntry) model_capabilities.ModelDescriptor {
    return .{
        .id = entry.id,
        .display_name = entry.id,
        .capabilities = .{
            .supports_reasoning = entry.has_reasoning or entry.reasoning_efforts.items.len > 0,
            .reasoning_efforts = .fromSlice(entry.reasoning_efforts.items),
            .supports_fast_mode = entry.supports_fast_mode,
            .supports_tool_use = entry.has_tool_use,
            .supports_vision = entry.has_vision,
            .supports_file_input = entry.has_file_input,
            .supports_web_search = entry.has_web_search,
            .supports_explicit_caching = entry.has_explicit_caching,
            .supports_implicit_caching = entry.has_implicit_caching,
            .context_window = if (entry.context_window == 0) null else entry.context_window,
            .max_output_tokens = if (entry.max_tokens == 0) null else entry.max_tokens,
        },
        .source = .catalog,
    };
}

pub const configured_model_descriptor_provider = ModelDescriptorProvider{
    .fallback_fn = configuredModelDescriptor,
    .catalog_fn = configuredCatalogDescriptor,
};

pub fn rebaseDescriptorIdentity(
    source_id: []const u8,
    stable_id: []const u8,
    descriptor: model_capabilities.ModelDescriptor,
) model_capabilities.ModelDescriptor {
    std.debug.assert(std.mem.eql(u8, source_id, stable_id));
    var rebased = descriptor;
    rebased.id = stable_id;
    rebased.display_name = rebaseIdentitySlice(source_id, stable_id, descriptor.display_name);
    rebased.provider = rebaseIdentitySlice(source_id, stable_id, descriptor.provider);
    return rebased;
}

fn rebaseIdentitySlice(source_id: []const u8, stable_id: []const u8, value: []const u8) []const u8 {
    const source_start = @intFromPtr(source_id.ptr);
    const value_start = @intFromPtr(value.ptr);
    if (value_start < source_start) return value;
    const offset = value_start - source_start;
    if (offset > source_id.len or value.len > source_id.len - offset) return value;
    return stable_id[offset .. offset + value.len];
}

pub fn freeModelCatalog(alloc: std.mem.Allocator, entries: *std.ArrayList(ModelCatalogEntry)) void {
    for (entries.items) |entry| freeModelCatalogEntry(alloc, entry);
    entries.deinit(alloc);
}

pub fn freeModelCatalogEntry(alloc: std.mem.Allocator, entry: ModelCatalogEntry) void {
    alloc.free(entry.id);
    alloc.free(entry.model_type);
    var reasoning_efforts = entry.reasoning_efforts;
    reasoning_efforts.deinit(alloc);
    if (entry.web_search_price) |price| alloc.free(price);
}

/// Returns owned model id strings in catalog order; caller frees with `collections.freeStringList`.
pub fn projectModelIds(alloc: std.mem.Allocator, candidates: []const ModelCatalogEntry) !std.ArrayList([]u8) {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer collections.freeStringList(alloc, &ids);
    try ids.ensureTotalCapacity(alloc, candidates.len);
    for (candidates) |candidate| {
        try ids.append(alloc, try alloc.dupe(u8, candidate.id));
    }
    return ids;
}

pub fn appendClonedModelCatalogEntry(alloc: std.mem.Allocator, entries: *std.ArrayList(ModelCatalogEntry), entry: ModelCatalogEntry) !void {
    const cloned = try cloneModelCatalogEntry(alloc, entry);
    entries.append(alloc, cloned) catch |err| {
        freeModelCatalogEntry(alloc, cloned);
        return err;
    };
}

fn cloneModelCatalogEntry(alloc: std.mem.Allocator, entry: ModelCatalogEntry) !ModelCatalogEntry {
    const id = try alloc.dupe(u8, entry.id);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, entry.model_type);
    errdefer alloc.free(model_type);
    var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer reasoning_efforts.deinit(alloc);
    try reasoning_efforts.appendSlice(alloc, entry.reasoning_efforts.items);

    var cloned = ModelCatalogEntry{
        .id = id,
        .model_type = model_type,
        .released = entry.released,
        .has_tool_use = entry.has_tool_use,
        .has_reasoning = entry.has_reasoning,
        .reasoning_efforts = reasoning_efforts,
        .supports_fast_mode = entry.supports_fast_mode,
        .has_vision = entry.has_vision,
        .has_file_input = entry.has_file_input,
        .has_web_search = entry.has_web_search,
        .has_explicit_caching = entry.has_explicit_caching,
        .has_implicit_caching = entry.has_implicit_caching,
        .context_window = entry.context_window,
        .max_tokens = entry.max_tokens,
        .web_search_price = null,
    };
    if (entry.web_search_price) |price| {
        cloned.web_search_price = try alloc.dupe(u8, price);
    }
    return cloned;
}

const FallbackProbe = struct {
    failures: [2]?Failure,
    calls: usize = 0,
    anonymous_retry: bool = false,

    fn fetch(raw: ?*anyopaque, _: Allocator, input: FetchInput) Allocator.Error!ProviderResult {
        const self: *FallbackProbe = @ptrCast(@alignCast(raw.?));
        const index = self.calls;
        self.calls += 1;
        if (index == 1) {
            self.anonymous_retry = input.access.authorizationCredential() == null and
                input.access.teamContext() == null;
        }
        if (self.failures[index]) |failure| return .{ .failure = failure };
        return .{ .catalog = .empty };
    }

    fn provider(self: *FallbackProbe) Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

test "catalog authentication fallback is anonymous and bounded" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "catalog-trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "catalog");

    const source = adapter_auth.Source{ .id = "test_key", .label = "test key", .refreshable = false };
    const access = adapter_auth.CatalogAccess{ .authenticated = .{
        .source = source,
        .credential = "test-key",
        .team_context = "team_123",
    } };
    const rejection = Failure{ .category = .authentication };
    var accepted = FallbackProbe{ .failures = .{ rejection, null } };
    var loaded = fetchWithPublicFallback(accepted.provider(), std.testing.allocator, .{
        .access = access,
    });
    defer freeModelCatalog(std.testing.allocator, &loaded.loaded.catalog);
    try std.testing.expectEqual(AccessLevel.public_only, loaded.loaded.provenance.access.level);
    try std.testing.expectEqualStrings(source.id, loaded.loaded.provenance.access.source.?.id);
    try std.testing.expectEqual(adapter_auth.CatalogPublicOnlyReason.credential_rejected, loaded.loaded.provenance.access.public_only_reason.?);
    try std.testing.expect(loaded.loaded.provenance.access.private_models_may_be_hidden);
    try std.testing.expect(loaded.loaded.provenance.anonymous_fallback_used);
    try std.testing.expectEqual(FailureCategory.authentication, loaded.loaded.provenance.fallback_failure.?.category);
    try std.testing.expect(!loaded.loaded.provenance.fallback_failure.?.retryable);
    try std.testing.expectEqual(@as(usize, 2), accepted.calls);
    try std.testing.expect(accepted.anonymous_retry);

    for ([_]Failure{
        .{ .category = .cancellation },
        .{ .category = .transport, .retryable = true },
    }) |failure| {
        var rejected = FallbackProbe{ .failures = .{ failure, null } };
        const failed = fetchWithPublicFallback(rejected.provider(), std.testing.allocator, .{
            .access = access,
        }).failed;
        try std.testing.expectEqual(failure.category, failed.failure.category);
        try std.testing.expectEqual(AccessLevel.authenticated, failed.access.level);
        try std.testing.expect(!failed.anonymous_fallback_used);
        try std.testing.expectEqual(@as(usize, 1), rejected.calls);
    }

    var twice = FallbackProbe{ .failures = .{ rejection, rejection } };
    const failed = fetchWithPublicFallback(twice.provider(), std.testing.allocator, .{
        .access = access,
    }).failed;
    try std.testing.expectEqual(AccessLevel.public_only, failed.access.level);
    try std.testing.expect(failed.anonymous_fallback_used);
    try std.testing.expectEqual(@as(usize, 2), twice.calls);

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, trace, "event=model_catalog_load "));
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "requested_access=authenticated credential_source=test_key effective_access=public_only public_only_reason=authenticated_credential_rejected anonymous_fallback=true outcome=loaded failure_category=authentication http_status=none retryable=false",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "requested_access=authenticated credential_source=test_key effective_access=authenticated public_only_reason=none anonymous_fallback=false outcome=failed failure_category=transport http_status=none retryable=true",
    ) != null);
    try std.testing.expect(std.mem.find(u8, trace, "test-key") == null);
    try std.testing.expect(std.mem.find(u8, trace, "team_123") == null);
    try std.testing.expect(std.mem.find(u8, trace, "/v1/models") == null);
}

test "catalog fallback classification stays bounded across repeated cycles" {
    const access = adapter_auth.CatalogAccess{ .authenticated = .{
        .source = .{ .id = "test_key", .label = "test key", .refreshable = false },
        .credential = "repeated-test-key",
        .team_context = "repeated-team",
    } };
    const terminal_failures = [_]Failure{
        .{ .category = .rate_limited, .retryable = true },
        .{ .category = .unavailable, .retryable = true },
        .{ .category = .cancellation },
        .{ .category = .transport, .retryable = true },
        .{ .category = .invalid_content },
        .{ .category = .protocol },
    };

    for (0..128) |iteration| {
        const rejection = Failure{ .category = .authentication };
        var fallback = FallbackProbe{ .failures = .{ rejection, null } };
        var loaded = fetchWithPublicFallback(fallback.provider(), std.testing.allocator, .{
            .access = access,
        });
        switch (loaded) {
            .loaded => |*result| {
                defer freeModelCatalog(std.testing.allocator, &result.catalog);
                try std.testing.expectEqual(AccessLevel.public_only, result.provenance.access.level);
                try std.testing.expectEqual(FailureCategory.authentication, result.provenance.fallback_failure.?.category);
                try std.testing.expect(result.provenance.anonymous_fallback_used);
            },
            .failed => return error.TestExpectedEqual,
        }
        try std.testing.expectEqual(@as(usize, 2), fallback.calls);
        try std.testing.expect(fallback.anonymous_retry);

        const expected = terminal_failures[iteration % terminal_failures.len];
        var terminal = FallbackProbe{ .failures = .{ expected, null } };
        const failed = fetchWithPublicFallback(terminal.provider(), std.testing.allocator, .{
            .access = access,
        });
        switch (failed) {
            .loaded => |result| {
                var catalog = result.catalog;
                freeModelCatalog(std.testing.allocator, &catalog);
                return error.TestExpectedEqual;
            },
            .failed => |result| {
                try std.testing.expectEqual(expected.category, result.failure.category);
                try std.testing.expectEqual(AccessLevel.authenticated, result.access.level);
                try std.testing.expect(!result.anonymous_fallback_used);
            },
        }
        try std.testing.expectEqual(@as(usize, 1), terminal.calls);
        try std.testing.expect(!terminal.anonymous_retry);
    }
}

test "projectModelIds preserves order and returns owned copies" {
    var first = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    var second = [_]u8{ 'b', 'e', 't', 'a' };
    const candidates = [_]ModelCatalogEntry{
        .{ .id = first[0..], .model_type = @constCast("language") },
        .{ .id = second[0..], .model_type = @constCast("language") },
    };

    var ids = try projectModelIds(std.testing.allocator, &candidates);
    defer collections.freeStringList(std.testing.allocator, &ids);

    first[0] = 'z';
    second[0] = 'y';

    try std.testing.expectEqual(@as(usize, 2), ids.items.len);
    try std.testing.expectEqualStrings("alpha", ids.items[0]);
    try std.testing.expectEqualStrings("beta", ids.items[1]);
}

test "descriptor identity rebasing keeps catalog projections on stable storage" {
    var source = [_]u8{ 'a', 'c', 'm', 'e', '/', 'm', 'o', 'd', 'e', 'l' };
    const stable = "acme/model";
    const descriptor = model_capabilities.ModelDescriptor{
        .id = source[0..],
        .display_name = source[0..],
        .provider = source[0..4],
        .source = .catalog,
    };
    const rebased = rebaseDescriptorIdentity(source[0..], stable, descriptor);
    source[0] = 'x';

    try std.testing.expectEqualStrings(stable, rebased.id);
    try std.testing.expectEqualStrings(stable, rebased.display_name);
    try std.testing.expectEqualStrings("acme", rebased.provider);
}

test "descriptor resolution treats aliases as one catalog identity" {
    const Fake = struct {
        fn fallback(_: ?*anyopaque, selected_model: []const u8) model_capabilities.ModelDescriptor {
            const fast = std.mem.endsWith(u8, selected_model, "-fast");
            const model = if (fast) selected_model[0 .. selected_model.len - "-fast".len] else selected_model;
            return .{
                .id = model,
                .display_name = model,
                .capabilities = .{ .supports_fast_mode = true },
                .source = .@"adapter-static",
                .selected_fast_mode = fast,
                .fast_route = .{ .suffix = "-fast" },
            };
        }

        fn catalog(_: ?*anyopaque, entry: ModelCatalogEntry) model_capabilities.ModelDescriptor {
            var descriptor = fallback(null, entry.id);
            descriptor.capabilities.context_window = entry.context_window;
            descriptor.source = .catalog;
            return descriptor;
        }
    };
    const descriptors = ModelDescriptorProvider{
        .fallback_fn = Fake.fallback,
        .catalog_fn = Fake.catalog,
    };
    const alias = ModelCatalogEntry{
        .id = @constCast("provider/model-fast"),
        .model_type = @constCast("language"),
        .context_window = 128_000,
    };
    const canonical = ModelCatalogEntry{
        .id = @constCast("provider/model"),
        .model_type = @constCast("language"),
        .context_window = 256_000,
    };

    const canonical_wins = descriptors.resolve(&.{ alias, canonical }, alias.id);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, canonical_wins.source);
    try std.testing.expectEqualStrings(canonical.id, canonical_wins.id);
    try std.testing.expect(canonical_wins.selected_fast_mode);
    try std.testing.expectEqual(@as(?u32, 256_000), canonical_wins.capabilities.context_window);

    const alias_fast = descriptors.resolve(&.{alias}, alias.id);
    const alias_normal = descriptors.resolve(&.{alias}, canonical.id);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, alias_fast.source);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, alias_normal.source);
    try std.testing.expect(alias_fast.selected_fast_mode);
    try std.testing.expect(!alias_normal.selected_fast_mode);
    try std.testing.expectEqual(@as(?u32, 128_000), alias_normal.capabilities.context_window);

    const missing = descriptors.resolve(&.{alias}, "provider/other");
    try std.testing.expectEqual(model_capabilities.CapabilitySource.@"adapter-static", missing.source);
}
