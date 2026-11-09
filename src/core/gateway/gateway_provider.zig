const std = @import("std");
const builtin = @import("builtin");
const credentials = @import("../auth/credentials.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const secret = @import("../auth/secret.zig");
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
        /// Owned catalog entries behind `ids`, from a provider whose catalog carries model
        /// metadata; empty otherwise. The caller frees them with `model_catalog.freeModelCatalog`.
        entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
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
    /// Setting it ends an in-flight lookup early with an error snapshot.
    cancel_flag: ?*std.atomic.Value(bool) = null,
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
    /// A load `resolveWithin` or `refreshWithin` started whose wait was
    /// cancelled, kept for the next call to wait on.
    pending_load: ?*CatalogLoad = null,
    /// Loads given up on before they connected. Each runs until its own
    /// deadline; a later load frees the ones that ended, and `deinit` waits
    /// for the rest.
    abandoned_loads: ?*CatalogLoad = null,
    /// Why the last refresh failed, until one loads.
    last_failure: ?model_catalog.FailureCategory = null,

    pub fn deinit(self: *CapabilityResolver, alloc: Allocator) void {
        if (self.pending_load) |load| load.discard(alloc);
        self.pending_load = null;
        while (self.abandoned_loads) |load| {
            self.abandoned_loads = load.next;
            load.discard(alloc);
        }
        model_catalog.freeModelCatalog(alloc, &self.catalog);
    }

    /// Why the catalog is down, or null while it has entries or has not been
    /// asked yet.
    pub fn downFailure(self: *const CapabilityResolver) ?model_catalog.FailureCategory {
        if (self.state != .failed) return null;
        return self.last_failure orelse .runtime;
    }

    /// The owner must exclude capability readers during refresh. Borrowed
    /// catalog entries stay valid until the next exclusive refresh or adoption.
    pub fn refreshIfDue(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
    ) model_capabilities.ResolveError!void {
        const now = model_catalog.clockMs();
        const requested = model_catalog.AccessMetadata.init(input.access);
        if (!self.loadDue(provider, requested, now)) return;

        try self.adopt(alloc, provider, requested, now, model_catalog.fetchWithPublicFallback(provider, alloc, input));
    }

    /// Whether the catalog needs a load for `requested` access at `now`: it
    /// never loaded, its access changed, or its refresh interval passed.
    fn loadDue(
        self: *const CapabilityResolver,
        provider: model_catalog.Provider,
        requested: model_catalog.AccessMetadata,
        now: i64,
    ) bool {
        const expired = if (provider.refresh_interval_ms) |interval|
            now < self.last_attempt_ms or now - self.last_attempt_ms >= interval
        else
            false;
        return self.state == .idle or self.accessChanged(provider, requested) or expired;
    }

    fn accessChanged(
        self: *const CapabilityResolver,
        provider: model_catalog.Provider,
        requested: model_catalog.AccessMetadata,
    ) bool {
        return !std.meta.eql(self.provider_id, provider.provider_id) or
            self.requested_access == null or !std.meta.eql(self.requested_access.?, requested);
    }

    /// Takes ownership of `result`, a fetch for `requested` access that
    /// started at `attempt_ms`.
    fn adopt(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        requested: model_catalog.AccessMetadata,
        attempt_ms: i64,
        result: model_catalog.FetchResult,
    ) model_capabilities.ResolveError!void {
        const access_changed = self.accessChanged(provider, requested);
        const loaded = switch (result) {
            .loaded => |loaded| loaded,
            .failed => |failed| {
                if (failed.failure.category == .cancellation) return error.Cancelled;
                self.last_attempt_ms = attempt_ms;
                self.requested_access = requested;
                self.provider_id = provider.provider_id;
                self.last_failure = failed.failure.category;
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
        self.last_attempt_ms = attempt_ms;
        self.requested_access = requested;
        self.provider_id = provider.provider_id;
        self.last_failure = null;
    }

    /// `resolve` for a caller that must not wait out a first load that cannot
    /// reach the catalog. The load runs as `loadWithin` describes; when it is
    /// given up on, the catalog counts as failed and `fallback` answers, as
    /// after any failed load.
    pub fn resolveWithin(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
        wait_ms: i64,
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        if (self.state == .idle) try self.loadWithin(alloc, provider, input, wait_ms);
        return self.resolve(alloc, provider, input, model, fallback);
    }

    /// `refreshIfDue` for a caller that must not wait out a refresh that
    /// cannot reach the catalog. A due load runs as `loadWithin` describes;
    /// one given up on fails as any failed refresh does, so the catalog
    /// already loaded for the same access stays in use until the next
    /// refresh is due.
    pub fn refreshWithin(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        wait_ms: i64,
    ) model_capabilities.ResolveError!void {
        if (!self.loadDue(provider, .init(input.access), model_catalog.clockMs())) return;
        try self.loadWithin(alloc, provider, input, wait_ms);
    }

    /// Loads the catalog on a thread of its own, because on a dead network
    /// the load can sit in a DNS lookup that std.Io cannot cut short until
    /// the system resolver gives up. When its request still has no
    /// connection `wait_ms` after the load started, the load counts as a
    /// transport failure; it is cancelled, never adopted, and freed once it
    /// ends. A load whose request has connected is waited for until it ends,
    /// within its own deadline, so a slow link still gets the catalog. A
    /// provider that does not report its connection loads inline, as
    /// `refreshIfDue` does. A cancelled wait leaves the load running for the
    /// next call. A cancelled load's request walks away from a lookup that
    /// still hangs (`gateway_client.openRequestOnJob`), so freeing the load
    /// at shutdown does not wait the lookup out.
    fn loadWithin(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        wait_ms: i64,
    ) model_capabilities.ResolveError!void {
        if (comptime builtin.single_threaded) return self.refreshIfDue(alloc, provider, input);
        if (!provider.reports_connection) return self.refreshIfDue(alloc, provider, input);
        self.freeEndedAbandonedLoads(alloc);
        const kind: []const u8 = if (self.state == .idle) "first load" else "refresh";
        const load = self.pending_load orelse started: {
            const started = CatalogLoad.start(alloc, provider, input) catch |err| {
                debug_trace.logf("gateway", "model catalog {s} runs inline err={s}", .{ kind, @errorName(err) });
                return self.refreshIfDue(alloc, provider, input);
            };
            self.pending_load = started;
            break :started started;
        };
        while (!load.finished.load(.acquire)) {
            if (input.cancel_flag) |flag| {
                if (flag.load(.seq_cst)) return error.Cancelled;
            }
            const waited_ms = model_catalog.clockMs() - load.started_ms;
            if (waited_ms >= wait_ms and !load.connected.load(.acquire)) {
                load.cancel_requested.store(true, .seq_cst);
                self.pending_load = null;
                load.next = self.abandoned_loads;
                self.abandoned_loads = load;
                debug_trace.logf("gateway", "model catalog {s} abandoned before it connected waited_ms={d}", .{ kind, waited_ms });
                const requested = model_catalog.AccessMetadata.init(load.input.access);
                return self.adopt(alloc, provider, requested, load.started_ms, .{ .failed = .{
                    .access = requested,
                    .anonymous_fallback_used = false,
                    .failure = .{ .category = .transport },
                } });
            }
            io_mod.sleep(load_poll_ns);
        }
        self.pending_load = null;
        const requested = model_catalog.AccessMetadata.init(load.input.access);
        const started_ms = load.started_ms;
        try self.adopt(alloc, provider, requested, started_ms, load.finish(alloc));
    }

    fn freeEndedAbandonedLoads(self: *CapabilityResolver, alloc: Allocator) void {
        var link = &self.abandoned_loads;
        while (link.*) |load| {
            if (load.finished.load(.acquire)) {
                link.* = load.next;
                load.discard(alloc);
            } else {
                link = &load.next;
            }
        }
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
        self.last_attempt_ms = model_catalog.clockMs();
        self.requested_access = .init(access);
        self.provider_id = provider.provider_id;
    }
};

/// How long a request waits for a model catalog load to connect, for
/// `CapabilityResolver.resolveWithin` and `refreshWithin`. A healthy network
/// connects well within this, and a connected load is waited for until it
/// ends. On a dead network the load would hold the request until its DNS
/// lookup or connect timed out, 20 to 30 seconds, before the request could
/// go on.
pub const catalog_connect_wait_ms: i64 = 2_000;

/// How often `CapabilityResolver.loadWithin` checks on a load.
const load_poll_ns = 2 * std.time.ns_per_ms;

/// A catalog load on a thread of its own. It owns copies of the access and
/// endpoint, because the caller's credential can be replaced while the load
/// runs, and its own cancel and connection flags.
const CatalogLoad = struct {
    provider: model_catalog.Provider,
    input: model_catalog.FetchInput,
    started_ms: i64,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Set by the provider once the load's request has a connection.
    connected: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    /// Set before `finished`; owns any loaded catalog.
    result: model_catalog.FetchResult = undefined,
    thread: std.Thread = undefined,
    /// The next load in `CapabilityResolver.abandoned_loads`.
    next: ?*CatalogLoad = null,

    fn start(alloc: Allocator, provider: model_catalog.Provider, input: model_catalog.FetchInput) !*CatalogLoad {
        const load = try alloc.create(CatalogLoad);
        errdefer alloc.destroy(load);
        const endpoint = try alloc.dupe(u8, input.endpoint);
        errdefer alloc.free(endpoint);
        const access = try dupeCatalogAccess(alloc, input.access);
        errdefer freeCatalogAccess(alloc, access);
        load.* = .{
            .provider = provider,
            .input = .{
                .access = access,
                .endpoint = endpoint,
                .cancel_flag = &load.cancel_requested,
                .view = input.view,
                .connected = &load.connected,
            },
            .started_ms = model_catalog.clockMs(),
        };
        load.thread = try std.Thread.spawn(.{}, run, .{ load, alloc });
        return load;
    }

    fn run(self: *CatalogLoad, alloc: Allocator) void {
        self.result = model_catalog.fetchWithPublicFallback(self.provider, alloc, self.input);
        self.finished.store(true, .release);
    }

    /// Joins a finished load, frees it, and returns its result.
    fn finish(self: *CatalogLoad, alloc: Allocator) model_catalog.FetchResult {
        self.thread.join();
        const result = self.result;
        self.destroy(alloc);
        return result;
    }

    /// Cancels the load, waits for it, and frees it with anything it loaded.
    fn discard(self: *CatalogLoad, alloc: Allocator) void {
        self.cancel_requested.store(true, .seq_cst);
        self.thread.join();
        switch (self.result) {
            .loaded => |loaded| {
                var catalog = loaded.catalog;
                debug_trace.logf("gateway", "model catalog load discarded entries={d}", .{catalog.items.len});
                model_catalog.freeModelCatalog(alloc, &catalog);
            },
            .failed => {},
        }
        self.destroy(alloc);
    }

    fn destroy(self: *CatalogLoad, alloc: Allocator) void {
        freeCatalogAccess(alloc, self.input.access);
        alloc.free(self.input.endpoint);
        alloc.destroy(self);
    }
};

/// Returns `access` with its credential, team, and account copied; free it
/// with `freeCatalogAccess`.
fn dupeCatalogAccess(alloc: Allocator, access: credentials.CatalogAccess) Allocator.Error!credentials.CatalogAccess {
    var owned = switch (access) {
        .public_only, .host_managed => return access,
        .authenticated => |borrowed| borrowed,
    };
    const credential = try alloc.dupe(u8, owned.credential);
    errdefer secret.zeroAndFree(alloc, credential);
    const team_context = if (owned.team_context) |team| try alloc.dupe(u8, team) else null;
    errdefer if (team_context) |team| alloc.free(team);
    const account_id = if (owned.account_id) |account| try alloc.dupe(u8, account) else null;
    owned.credential = credential;
    owned.team_context = team_context;
    owned.account_id = account_id;
    return .{ .authenticated = owned };
}

fn freeCatalogAccess(alloc: Allocator, access: credentials.CatalogAccess) void {
    switch (access) {
        .public_only, .host_managed => {},
        .authenticated => |owned| {
            secret.zeroAndFree(alloc, @constCast(owned.credential));
            if (owned.team_context) |team| alloc.free(team);
            if (owned.account_id) |account| alloc.free(account);
        },
    }
}

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
    try std.testing.expect(resolver.downFailure() == null);
    try resolver.refreshIfDue(alloc, provider, input);
    try std.testing.expect(resolver.catalogEntries() == null);
    try std.testing.expectEqual(model_catalog.FailureCategory.transport, resolver.downFailure().?);
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
    try std.testing.expect(resolver.downFailure() == null);
    fake.outcome = .unavailable;
    resolver.last_attempt_ms -= 60_000;
    try resolver.refreshIfDue(alloc, provider, input);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqualStrings("provider/model", resolver.catalogEntries().?[0].id);
    // A failed refresh that keeps the earlier catalog leaves it up.
    try std.testing.expect(resolver.downFailure() == null);
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

/// A catalog that answers like `FakeCatalog.ready` once released, and fails
/// as cancelled once its fetch is cancelled, like a lookup on a dead network.
/// It reports its connection, at once when `connects` is set.
const GatedCatalog = struct {
    connects: bool = false,
    /// False for a fetch that cannot be cut short, which answers only once
    /// released.
    honors_cancel: bool = true,
    reports_connection: bool = true,
    released: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    saw_cancel: std.atomic.Value(bool) = .init(false),
    saw_credential: std.atomic.Value(bool) = .init(false),

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *GatedCatalog = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        if (self.connects) input.connected.?.store(true, .release);
        if (std.mem.eql(u8, input.access.authorizationCredential() orelse "", "test-key")) {
            self.saw_credential.store(true, .seq_cst);
        }
        while (!self.released.load(.seq_cst)) {
            if (self.honors_cancel) if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) {
                self.saw_cancel.store(true, .seq_cst);
                return .{ .failure = .{ .category = .cancellation } };
            };
            io_mod.sleep(std.time.ns_per_ms);
        }
        var ready = FakeCatalog{ .outcome = .ready };
        return FakeCatalog.fetch(&ready, alloc, input);
    }

    fn provider(self: *GatedCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch, .reports_connection = self.reports_connection };
    }

    /// Releases the catalog after `delay_ms` from a thread of its own.
    fn releaseAfter(self: *GatedCatalog, delay_ms: u64) !std.Thread {
        const Release = struct {
            fn run(gated: *GatedCatalog, ms: u64) void {
                io_mod.sleep(ms * std.time.ns_per_ms);
                gated.released.store(true, .seq_cst);
            }
        };
        return std.Thread.spawn(.{}, Release.run, .{ self, delay_ms });
    }
};

fn reportingProvider(fake: *FakeCatalog) model_catalog.Provider {
    var provider = fake.provider();
    provider.reports_connection = true;
    return provider;
}

test "a first catalog load that never connects answers from the fallback after its wait and is never adopted" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    const input = model_catalog.FetchInput{
        .access = credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"),
        .endpoint = "/v1/models",
    };

    // The catalog's request never connects, so the lookup returns the fallback.
    const capabilities = try resolver.resolveWithin(alloc, gated.provider(), input, "provider/model", .{ .context_window = 1_000 }, 20);
    try std.testing.expectEqual(@as(?u32, 1_000), capabilities.context_window);
    try std.testing.expectEqual(CapabilityResolverState.failed, resolver.state);
    // A load given up on before it connected is down for a connection fx
    // could not make.
    try std.testing.expectEqual(model_catalog.FailureCategory.transport, resolver.downFailure().?);

    // A later lookup neither waits nor fetches again.
    const later = try resolver.resolveWithin(alloc, gated.provider(), input, "provider/model", .{}, 60_000);
    try std.testing.expectEqual(@as(?u32, null), later.context_window);
    try std.testing.expect(resolver.catalogEntries() == null);

    resolver.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), gated.calls.load(.seq_cst));
    try std.testing.expect(gated.saw_credential.load(.seq_cst));
    try std.testing.expect(gated.saw_cancel.load(.seq_cst));
}

test "a first catalog load that connected is waited for past the wait and adopted" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{ .connects = true };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);

    // The request connects at once and the catalog answers well after the wait.
    const releaser = try gated.releaseAfter(600);
    defer releaser.join();
    const capabilities = try resolver.resolveWithin(alloc, gated.provider(), .{ .endpoint = "/v1/models" }, "provider/model", .{ .context_window = 1_000 }, 150);
    try std.testing.expectEqual(@as(?u32, 256_000), capabilities.context_window);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    try std.testing.expect(!gated.saw_cancel.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), gated.calls.load(.seq_cst));
}

test "a first catalog load from a provider that does not report its connection is waited for" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{ .reports_connection = false };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);

    const releaser = try gated.releaseAfter(200);
    defer releaser.join();
    const capabilities = try resolver.resolveWithin(alloc, gated.provider(), .{ .endpoint = "/v1/models" }, "provider/model", .{}, 20);
    try std.testing.expectEqual(@as(?u32, 256_000), capabilities.context_window);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    // It loads on the caller's thread, as `resolve` does.
    try std.testing.expect(resolver.pending_load == null);
}

test "a catalog that answers after its wait ended is freed, not adopted" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{ .honors_cancel = false };
    var resolver: CapabilityResolver = .{};
    const input = model_catalog.FetchInput{ .endpoint = "/v1/models" };

    _ = try resolver.resolveWithin(alloc, gated.provider(), input, "provider/model", .{}, 20);
    try std.testing.expectEqual(CapabilityResolverState.failed, resolver.state);
    gated.released.store(true, .seq_cst);
    while (!resolver.abandoned_loads.?.finished.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);

    const later = try resolver.resolveWithin(alloc, gated.provider(), input, "provider/model", .{}, 60_000);
    try std.testing.expectEqual(@as(?u32, null), later.context_window);
    try std.testing.expect(resolver.catalogEntries() == null);
    // The testing allocator fails the test if the late catalog leaks.
    resolver.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), gated.calls.load(.seq_cst));
}

test "a first catalog load that finishes within its wait is adopted" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .ready };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);

    const capabilities = try resolver.resolveWithin(alloc, reportingProvider(&fake), .{ .endpoint = "/v1/models" }, "provider/model", .{}, 60_000);
    try std.testing.expectEqual(@as(?u32, 256_000), capabilities.context_window);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    try std.testing.expect(resolver.pending_load == null);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a first catalog load keeps the public retry after a rejected credential" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .authenticated_rejected_then_ready };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);

    const capabilities = try resolver.resolveWithin(alloc, reportingProvider(&fake), .{
        .access = credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"),
        .endpoint = "/v1/models",
    }, "provider/model", .{}, 60_000);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(fake.saw_authenticated_access);
    try std.testing.expect(fake.saw_public_retry);
    try std.testing.expect(capabilities.supports_vision);
}

test "a cancelled wait for a first catalog load leaves the load for the next lookup" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(true);
    const input = model_catalog.FetchInput{ .endpoint = "/v1/models", .cancel_flag = &cancel_flag };

    try std.testing.expectError(error.Cancelled, resolver.resolveWithin(alloc, gated.provider(), input, "provider/model", .{}, 60_000));
    try std.testing.expectEqual(CapabilityResolverState.idle, resolver.state);

    cancel_flag.store(false, .seq_cst);
    gated.released.store(true, .seq_cst);
    const capabilities = try resolver.resolveWithin(alloc, gated.provider(), input, "provider/model", .{}, 60_000);
    try std.testing.expectEqual(@as(?u32, 256_000), capabilities.context_window);
    try std.testing.expectEqual(@as(usize, 1), gated.calls.load(.seq_cst));
    try std.testing.expect(!gated.saw_cancel.load(.seq_cst));
}

/// Loads `gated`'s catalog once through a provider with a refresh interval,
/// then lets the interval pass, so the next `refreshWithin` is due.
fn loadRefreshableCatalogForTest(
    alloc: Allocator,
    resolver: *CapabilityResolver,
    gated: *GatedCatalog,
) !model_catalog.Provider {
    var provider = gated.provider();
    provider.refresh_interval_ms = 60_000;
    gated.connects = true;
    gated.released.store(true, .seq_cst);
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 60_000);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    gated.released.store(false, .seq_cst);
    resolver.last_attempt_ms -= 60_000;
    return provider;
}

test "a due catalog refresh that never connects keeps the catalog after its wait" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    const provider = try loadRefreshableCatalogForTest(alloc, &resolver, &gated);
    gated.connects = false;

    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 20);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    try std.testing.expectEqualStrings("provider/model", resolver.catalogEntries().?[0].id);
    try std.testing.expect(resolver.downFailure() == null);

    // The refresh given up on counts as this interval's attempt.
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 60_000);
    resolver.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), gated.calls.load(.seq_cst));
    try std.testing.expect(gated.saw_cancel.load(.seq_cst));
}

test "a due catalog refresh that connected is waited for past the wait and adopted" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    const provider = try loadRefreshableCatalogForTest(alloc, &resolver, &gated);
    const due_since_ms = resolver.last_attempt_ms;

    // The request connects at once and the catalog answers well after the wait.
    const releaser = try gated.releaseAfter(300);
    defer releaser.join();
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 50);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    try std.testing.expect(resolver.last_attempt_ms > due_since_ms);
    try std.testing.expect(!gated.saw_cancel.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), gated.calls.load(.seq_cst));
}

test "a catalog refresh after one given up on starts its own load and frees the one that ended" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    const provider = try loadRefreshableCatalogForTest(alloc, &resolver, &gated);
    gated.connects = false;

    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 20);
    while (!resolver.abandoned_loads.?.finished.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);

    resolver.last_attempt_ms -= 60_000;
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 20);
    // Only the second load is left; the testing allocator fails the test if
    // the first leaks.
    try std.testing.expect(resolver.abandoned_loads.?.next == null);
    try std.testing.expectEqual(@as(usize, 3), gated.calls.load(.seq_cst));
    try std.testing.expectEqualStrings("provider/model", resolver.catalogEntries().?[0].id);
}
