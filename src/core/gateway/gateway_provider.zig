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
const saved_catalog = @import("saved_catalog.zig");
const saved_catalog_plan = @import("saved_catalog_plan.zig");
const token_pass = @import("token_pass.zig");
const token_pass_team = @import("token_pass_team.zig");

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
        /// Owned text for one line on stderr, such as why part of the list is
        /// missing, or null. The caller frees it.
        notice: ?[]u8 = null,
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
    /// Whether `catalog` is the one fx saved, read at the start, rather than
    /// one this process fetched.
    catalog_saved: bool = false,
    /// Where loads save the catalog they fetch (`useSavedCatalog`).
    save_to: ?SaveTarget = null,

    pub fn deinit(self: *CapabilityResolver, alloc: Allocator) void {
        if (self.pending_load) |load| load.discard(alloc);
        self.pending_load = null;
        while (self.abandoned_loads) |load| {
            self.abandoned_loads = load.next;
            load.discard(alloc);
        }
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        if (self.save_to) |*target| target.deinit(alloc);
        self.save_to = null;
    }

    /// A copy of this resolver that a reader owns: it shares no memory with
    /// this one, so an adoption or refresh here leaves the copy as it was.
    /// A load in flight is not copied. The copy loads for itself if it is
    /// asked before anything loaded. Free it with `deinit`.
    pub fn snapshot(self: *const CapabilityResolver, alloc: Allocator) Allocator.Error!CapabilityResolver {
        return .{
            .catalog = try model_catalog.cloneModelCatalog(alloc, self.catalog.items),
            .state = self.state,
            .last_attempt_ms = self.last_attempt_ms,
            .requested_access = self.requested_access,
            .provider_id = self.provider_id,
            .last_failure = self.last_failure,
            .catalog_saved = self.catalog_saved,
        };
    }

    /// Starts from the catalog fx saved for `team` in the profile at `home`
    /// (`saved_catalog.zig`), when `saved_catalog_plan.start` says it is young
    /// enough, and has later loads for the same provider and access save what
    /// they fetch. The refresh interval counts from the time it was saved, so
    /// a saved catalog that is due starts the background load `startLoad`
    /// makes. Call it before the first load. With no catalog fx can use, the
    /// resolver stays as it was, and the first request that needs the
    /// catalog waits for it.
    pub fn useSavedCatalog(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        home: []const u8,
        team: [token_pass.identity_len]u8,
    ) void {
        const format = provider.saved orelse return;
        const requested = model_catalog.AccessMetadata.init(input.access);
        if (self.state != .idle or requested.level != .authenticated) return;
        if (self.save_to) |*earlier| earlier.deinit(alloc);
        self.save_to = SaveTarget.init(alloc, format, provider.provider_id, requested, input.endpoint, home, team) catch |err| {
            debug_trace.logf("gateway", "model catalog saved copy unused err={s}", .{@errorName(err)});
            return;
        };
        const target = &self.save_to.?;
        var saved = saved_catalog.load(alloc, home, target.key()) orelse return;
        defer saved.deinit(alloc);
        const now_ms = io_mod.milliTimestamp();
        const interval_ms = provider.refresh_interval_ms orelse 0;
        const plan = saved_catalog_plan.start(saved.saved_ms, now_ms, interval_ms);
        if (plan == .cold) {
            debug_trace.logf("gateway", "model catalog saved copy ignored reason=age age_ms={d}", .{now_ms -| saved.saved_ms});
            return;
        }
        const parsed = format.parse_fn(alloc, saved.body) catch |err| {
            debug_trace.logf("gateway", "model catalog saved copy unused err={s}", .{@errorName(err)});
            return;
        };
        const catalog = switch (parsed) {
            .catalog => |catalog| catalog,
            .failure => |failure| {
                debug_trace.logf("gateway", "model catalog saved copy ignored reason={t}", .{failure.category});
                return;
            },
        };
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = catalog;
        publishSavedTokenPassModels(provider, self.catalog.items);
        self.state = .ready;
        self.catalog_saved = true;
        self.requested_access = requested;
        self.provider_id = provider.provider_id;
        self.last_failure = null;
        // A saved catalog in use comes due once it is an interval old; one
        // that must be fetched is due now.
        self.last_attempt_ms = model_catalog.clockMs() - switch (plan) {
            .use => now_ms - saved.saved_ms,
            .use_and_fetch => interval_ms,
            .cold => unreachable,
        };
        debug_trace.logf("gateway", "model catalog saved copy used fetch={} entries={d} age_ms={d}", .{
            plan == .use_and_fetch,
            self.catalog.items.len,
            now_ms - saved.saved_ms,
        });
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
                    self.catalog_saved = false;
                    publishTokenPassModels(provider, self.catalog.items);
                }
                if (self.catalog.items.len == 0) self.state = .failed;
                debug_trace.logf("gateway", "model catalog refresh failed category={t} retained={}", .{ failed.failure.category, self.state == .ready });
                return;
            },
        };
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = loaded.catalog;
        self.catalog_saved = false;
        publishTokenPassModels(provider, self.catalog.items);
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

    /// Starts the load that `resolveWithin` or `refreshWithin` would run, on
    /// its own thread, and returns at once. Their next call waits on it, from
    /// its start, as `loadWithin` describes. It starts nothing when the
    /// catalog needs no load, a load already runs, or the provider loads only
    /// on the caller's thread; the next call then loads as before.
    pub fn startLoad(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
    ) void {
        if (comptime builtin.single_threaded) return;
        if (!canLoadInBackground(provider) or self.pending_load != null) return;
        if (!self.loadDue(provider, .init(input.access), model_catalog.clockMs())) return;
        self.pending_load = self.startCatalogLoad(alloc, provider, input) catch |err| {
            debug_trace.logf("gateway", "model catalog load not started early err={s}", .{@errorName(err)});
            return;
        };
    }

    /// A load on a thread of its own that saves what it fetches when the
    /// saved catalog is for its provider and access.
    fn startCatalogLoad(
        self: *const CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
    ) !*CatalogLoad {
        const save_to = if (self.save_to) |*target| if (target.serves(provider, input)) target else null else null;
        return CatalogLoad.start(alloc, provider, input, save_to);
    }

    /// Whether the first load runs, from `startLoad` or a wait that was
    /// cancelled, and nothing has loaded yet.
    pub fn firstLoadRunning(self: *const CapabilityResolver) bool {
        return self.state == .idle and self.pending_load != null;
    }

    /// `refreshIfDue` for a caller that must not wait for the network while
    /// fx holds a catalog for its access (`saved_catalog_plan.request`). A
    /// due refresh then loads in the background, and the first call after
    /// it ends takes its result. With no catalog for the access, the load
    /// runs as `loadWithin` describes; one given up on fails as any failed
    /// refresh does.
    pub fn refreshWithin(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        wait_ms: i64,
    ) model_capabilities.ResolveError!void {
        // No load runs on a thread of its own, so a due refresh loads inline.
        if (comptime builtin.single_threaded) {
            if (self.loadDue(provider, .init(input.access), model_catalog.clockMs())) try self.refreshIfDue(alloc, provider, input);
            return;
        }
        self.freeEndedAbandonedLoads(alloc);
        self.leaveLoadForOtherAccess(provider, input.access);
        const requested = model_catalog.AccessMetadata.init(input.access);
        const landed = if (self.pending_load) |load| load.finished.load(.acquire) else false;
        switch (saved_catalog_plan.request(.{
            .has_catalog = self.state == .ready and !self.accessChanged(provider, requested),
            .due = self.loadDue(provider, requested, model_catalog.clockMs()),
            .load_running = self.pending_load != null,
            .load_landed = landed,
            .can_load_in_background = canLoadInBackground(provider),
        })) {
            .go_on => {},
            .take_landed => try self.takeLandedLoad(alloc, provider),
            .start_background => self.startLoad(alloc, provider, input),
            .wait => try self.loadWithin(alloc, provider, input, wait_ms),
        }
    }

    /// Takes a load for `provider` and `access` that has ended, for a caller
    /// that must neither wait for nor start one, such as a prompt.
    pub fn takeLanded(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
    ) model_capabilities.ResolveError!void {
        const load = self.pending_load orelse return;
        if (!load.finished.load(.acquire) or !load.serves(provider, access)) return;
        try self.takeLandedLoad(alloc, provider);
    }

    fn takeLandedLoad(self: *CapabilityResolver, alloc: Allocator, provider: model_catalog.Provider) model_capabilities.ResolveError!void {
        const load = self.pending_load.?;
        self.pending_load = null;
        const requested = model_catalog.AccessMetadata.init(load.input.access);
        const started_ms = load.started_ms;
        try self.adopt(alloc, provider, requested, started_ms, load.finish(alloc));
    }

    /// A load started for another provider or access, such as by
    /// `startLoad`, would answer for the wrong catalog.
    fn leaveLoadForOtherAccess(self: *CapabilityResolver, provider: model_catalog.Provider, access: credentials.CatalogAccess) void {
        const pending = self.pending_load orelse return;
        if (pending.serves(provider, access)) return;
        debug_trace.logf("gateway", "model catalog load left: started for another provider or access", .{});
        self.abandonPendingLoad();
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
        self.leaveLoadForOtherAccess(provider, input.access);
        const load = self.pending_load orelse started: {
            const started = self.startCatalogLoad(alloc, provider, input) catch |err| {
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
                self.abandonPendingLoad();
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
        try self.takeLandedLoad(alloc, provider);
    }

    /// Cancels the pending load and keeps it until it ends, unadopted.
    fn abandonPendingLoad(self: *CapabilityResolver) void {
        const load = self.pending_load orelse return;
        load.cancel_requested.store(true, .seq_cst);
        self.pending_load = null;
        load.next = self.abandoned_loads;
        self.abandoned_loads = load;
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
        self.catalog_saved = false;
        publishTokenPassModels(provider, self.catalog.items);
        self.state = .ready;
        self.last_attempt_ms = model_catalog.clockMs();
        self.requested_access = .init(access);
        self.provider_id = provider.provider_id;
    }
};

/// Hands an AI Gateway catalog's Token Pass marks to `token_pass_team`, for
/// `fx ask` and ACP, which resolve models through this catalog. Another
/// provider's catalog says nothing about the AI Gateway team.
fn publishTokenPassModels(provider: model_catalog.Provider, entries: []const model_catalog.ModelCatalogEntry) void {
    if (provider.provider_id != .gateway) return;
    token_pass_team.publishCatalog(entries);
}

/// As `publishTokenPassModels`, for a saved catalog, whose marks never
/// answer for the team.
fn publishSavedTokenPassModels(provider: model_catalog.Provider, entries: []const model_catalog.ModelCatalogEntry) void {
    if (provider.provider_id != .gateway) return;
    token_pass_team.publishSavedCatalog(entries);
}

fn canLoadInBackground(provider: model_catalog.Provider) bool {
    return !builtin.single_threaded and provider.reports_connection;
}

/// Where a resolver's loads save the catalog they fetch: the saved catalog
/// of one team, for one provider and access. Owns its copies.
const SaveTarget = struct {
    home: []u8,
    team: [token_pass.identity_len]u8,
    url: []u8,
    provider_id: model_provider.ProviderId,
    access: model_catalog.AccessMetadata,
    endpoint: []u8,

    fn init(
        alloc: Allocator,
        format: model_catalog.SavedFormat,
        provider_id: model_provider.ProviderId,
        access: model_catalog.AccessMetadata,
        endpoint: []const u8,
        home: []const u8,
        team: [token_pass.identity_len]u8,
    ) !SaveTarget {
        const url = format.url_fn(alloc, endpoint) orelse return error.CatalogUrlUnknown;
        errdefer alloc.free(url);
        const owned_home = try alloc.dupe(u8, home);
        errdefer alloc.free(owned_home);
        return .{
            .home = owned_home,
            .team = team,
            .url = url,
            .provider_id = provider_id,
            .access = access,
            .endpoint = try alloc.dupe(u8, endpoint),
        };
    }

    fn dupe(self: *const SaveTarget, alloc: Allocator) !SaveTarget {
        const home = try alloc.dupe(u8, self.home);
        errdefer alloc.free(home);
        const url = try alloc.dupe(u8, self.url);
        errdefer alloc.free(url);
        return .{
            .home = home,
            .team = self.team,
            .url = url,
            .provider_id = self.provider_id,
            .access = self.access,
            .endpoint = try alloc.dupe(u8, self.endpoint),
        };
    }

    fn deinit(self: *SaveTarget, alloc: Allocator) void {
        alloc.free(self.home);
        alloc.free(self.url);
        alloc.free(self.endpoint);
    }

    fn key(self: *const SaveTarget) saved_catalog.Key {
        return .{ .team = self.team, .url = self.url };
    }

    /// Whether a load for `provider` and `input` fetches this team's catalog.
    fn serves(self: *const SaveTarget, provider: model_catalog.Provider, input: model_catalog.FetchInput) bool {
        return provider.saved != null and
            std.meta.eql(provider.provider_id, self.provider_id) and
            input.view == .full and
            std.mem.eql(u8, input.endpoint, self.endpoint) and
            std.meta.eql(model_catalog.AccessMetadata.init(input.access), self.access);
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
    /// Where the load saves the team's catalog it fetches, for the next start.
    save_to: ?SaveTarget = null,

    fn start(alloc: Allocator, provider: model_catalog.Provider, input: model_catalog.FetchInput, save_to: ?*const SaveTarget) !*CatalogLoad {
        const load = try alloc.create(CatalogLoad);
        errdefer alloc.destroy(load);
        var owned_target = if (save_to) |target| try target.dupe(alloc) else null;
        errdefer if (owned_target) |*target| target.deinit(alloc);
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
            .save_to = owned_target,
        };
        load.thread = try std.Thread.spawn(.{}, run, .{ load, alloc });
        return load;
    }

    fn run(self: *CatalogLoad, alloc: Allocator) void {
        var body: ?[]u8 = null;
        var input = self.input;
        if (self.save_to != null) input.body_out = &body;
        self.result = model_catalog.fetchWithPublicFallback(self.provider, alloc, input);
        if (body) |bytes| {
            defer alloc.free(bytes);
            self.saveFetched(alloc, bytes);
        }
        const loaded = self.result == .loaded;
        self.finished.store(true, .release);
        // The reader may free the load from here on, so only locals remain.
        debug_trace.logf("gateway", "model catalog load ended loaded={}", .{loaded});
    }

    /// Saves the team's catalog that the load fetched, before the load ends,
    /// so that its reader finds the file current.
    fn saveFetched(self: *CatalogLoad, alloc: Allocator, body: []const u8) void {
        const target = &(self.save_to orelse return);
        const loaded = switch (self.result) {
            .loaded => |loaded| loaded,
            .failed => return,
        };
        // The public list after a rejected credential is not the team's.
        if (loaded.provenance.anonymous_fallback_used or loaded.provenance.access.level != .authenticated) return;
        // A load given up on answers for nothing.
        if (self.cancel_requested.load(.seq_cst)) return;
        saved_catalog.save(alloc, target.home, target.key(), body, io_mod.milliTimestamp()) catch |err| {
            debug_trace.logf("gateway", "model catalog not saved err={s} bytes={d}", .{ @errorName(err), body.len });
            return;
        };
        debug_trace.logf("gateway", "model catalog saved entries={d} bytes={d}", .{ loaded.catalog.items.len, body.len });
    }

    fn serves(self: *const CatalogLoad, provider: model_catalog.Provider, access: credentials.CatalogAccess) bool {
        return std.meta.eql(self.provider.provider_id, provider.provider_id) and
            std.meta.eql(model_catalog.AccessMetadata.init(self.input.access), model_catalog.AccessMetadata.init(access));
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
        if (self.save_to) |*target| target.deinit(alloc);
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

fn testCatalogOf(alloc: Allocator, ids: []const []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (ids) |id| {
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try entries.append(alloc, .{ .id = owned_id, .model_type = model_type, .has_vision = true, .context_window = 1000 });
    }
    return entries;
}

test "a snapshot of the capability resolver keeps its catalog when the resolver adopts another" {
    const alloc = std.testing.allocator;
    var fake = FakeCatalog{ .outcome = .ready };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    var first = try testCatalogOf(alloc, &.{ "provider/old", "provider/other" });
    resolver.adoptOwnedCatalog(alloc, fake.provider(), .host_managed, &first);

    var copy = try resolver.snapshot(alloc);
    defer copy.deinit(alloc);
    // A switch of the provider adopts another catalog and frees the old entries.
    var second = try testCatalogOf(alloc, &.{"provider/new"});
    resolver.adoptOwnedCatalog(alloc, fake.provider(), .host_managed, &second);
    try std.testing.expectEqual(@as(usize, 1), resolver.catalogEntries().?.len);

    // The copy has what the resolver held when it was taken, in memory of its own.
    const entries = copy.catalogEntries().?;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("provider/old", entries[0].id);
    try std.testing.expectEqualStrings("provider/other", entries[1].id);
    try std.testing.expect(copy.available("provider/old", .{}).supports_vision);
    try std.testing.expect(!copy.available("provider/new", .{}).supports_vision);
    try std.testing.expect(copy.downFailure() == null);
    // A snapshot of a resolver that never loaded has nothing, and is as idle as the resolver.
    var idle: CapabilityResolver = .{};
    var idle_copy = try idle.snapshot(alloc);
    defer idle_copy.deinit(alloc);
    try std.testing.expectEqual(CapabilityResolverState.idle, idle_copy.state);
}

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
    /// When set, the fetch answers with these comma-separated ids and hands
    /// this body back for saving (`savingProvider`).
    body: ?[]const u8 = null,
    /// Rejects an authenticated request, so the public retry answers.
    rejects_credential: bool = false,

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
        if (self.rejects_credential and input.access.authorizationCredential() != null) {
            return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
        }
        while (!self.released.load(.seq_cst)) {
            if (self.honors_cancel) if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) {
                self.saw_cancel.store(true, .seq_cst);
                return .{ .failure = .{ .category = .cancellation } };
            };
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (self.body) |body| {
            var catalog = try testCatalogFromBody(alloc, body);
            errdefer model_catalog.freeModelCatalog(alloc, &catalog);
            if (input.body_out) |out| out.* = try alloc.dupe(u8, body);
            return .{ .catalog = catalog };
        }
        var ready = FakeCatalog{ .outcome = .ready };
        return FakeCatalog.fetch(&ready, alloc, input);
    }

    fn provider(self: *GatedCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch, .reports_connection = self.reports_connection };
    }

    /// A provider whose catalog fx saves, refreshed every minute.
    fn savingProvider(self: *GatedCatalog) model_catalog.Provider {
        var provider_value = self.provider();
        provider_value.refresh_interval_ms = 60_000;
        provider_value.saved = test_saved_format;
        return provider_value;
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

test "a catalog load started before the first lookup returns at once, and the lookup waits on it" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{ .connects = true };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    const input = model_catalog.FetchInput{ .endpoint = "/v1/models" };

    // The catalog is held, yet the start returns with the load running.
    resolver.startLoad(alloc, gated.provider(), input);
    try std.testing.expect(resolver.firstLoadRunning());
    // A second start leaves the one load running.
    resolver.startLoad(alloc, gated.provider(), input);

    gated.released.store(true, .seq_cst);
    const capabilities = try resolver.resolveWithin(alloc, gated.provider(), input, "provider/model", .{}, 60_000);
    try std.testing.expectEqual(@as(?u32, 256_000), capabilities.context_window);
    try std.testing.expect(!resolver.firstLoadRunning());
    try std.testing.expectEqual(@as(usize, 1), gated.calls.load(.seq_cst));

    // A catalog that loaded and is not due starts nothing.
    resolver.startLoad(alloc, gated.provider(), input);
    try std.testing.expect(resolver.pending_load == null);
}

test "a catalog load started early for another provider is left, and the lookup loads its own" {
    const alloc = std.testing.allocator;
    var early: GatedCatalog = .{ .connects = true };
    var own = FakeCatalog{ .outcome = .ready };
    var own_provider = reportingProvider(&own);
    own_provider.provider_id = .codex;
    var resolver: CapabilityResolver = .{};
    const input = model_catalog.FetchInput{ .endpoint = "/v1/models" };

    resolver.startLoad(alloc, early.provider(), input);
    // Lets the early load answer later, so a lookup that wrongly waits on it
    // ends and fails the checks below instead of hanging.
    const releaser = try early.releaseAfter(300);
    defer releaser.join();
    const capabilities = try resolver.resolveWithin(alloc, own_provider, input, "provider/model", .{}, 60_000);
    try std.testing.expectEqual(@as(?u32, 256_000), capabilities.context_window);
    try std.testing.expectEqual(@as(usize, 1), own.calls);
    try std.testing.expect(std.meta.eql(resolver.provider_id, own_provider.provider_id));

    // The early load is cancelled and freed, never adopted.
    resolver.deinit(alloc);
    try std.testing.expect(early.saw_cancel.load(.seq_cst));
}

test "a provider that does not report its connection starts no early catalog load" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{ .reports_connection = false, .released = .init(true) };
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);

    // Its first lookup loads on the caller's thread, as `resolve` does.
    resolver.startLoad(alloc, gated.provider(), .{ .endpoint = "/v1/models" });
    try std.testing.expect(!resolver.firstLoadRunning());
    try std.testing.expectEqual(@as(usize, 0), gated.calls.load(.seq_cst));
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

test "a due catalog refresh that never connects runs in the background, and the catalog stays in use" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    const provider = try loadRefreshableCatalogForTest(alloc, &resolver, &gated);
    gated.connects = false;

    // fx holds a catalog for the access, so the refresh waits for nothing,
    // whatever wait the caller allows.
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 60_000);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    try std.testing.expectEqualStrings("provider/model", resolver.catalogEntries().?[0].id);
    try std.testing.expect(resolver.downFailure() == null);
    try std.testing.expect(resolver.pending_load != null);

    // A refresh while it runs starts no second load.
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 60_000);
    resolver.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), gated.calls.load(.seq_cst));
    try std.testing.expect(gated.saw_cancel.load(.seq_cst));
}

test "a due catalog refresh runs in the background, and the first refresh after it lands takes it" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    const provider = try loadRefreshableCatalogForTest(alloc, &resolver, &gated);
    const due_since_ms = resolver.last_attempt_ms;

    // The fetch is held, so a refresh that waited for it would not return.
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 60_000);
    const load = resolver.pending_load.?;
    try std.testing.expectEqual(due_since_ms, resolver.last_attempt_ms);
    gated.released.store(true, .seq_cst);
    while (!load.finished.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);

    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 60_000);
    try std.testing.expect(resolver.pending_load == null);
    try std.testing.expectEqual(CapabilityResolverState.ready, resolver.state);
    try std.testing.expect(resolver.last_attempt_ms > due_since_ms);
    try std.testing.expect(!gated.saw_cancel.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), gated.calls.load(.seq_cst));
}

test "a catalog refresh with no catalog, after one given up on, starts its own load and frees the one that ended" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    var provider = gated.provider();
    provider.refresh_interval_ms = 60_000;
    const input = model_catalog.FetchInput{ .endpoint = "/v1/models" };

    // The first load never connects, so the catalog fails.
    try resolver.refreshWithin(alloc, provider, input, 20);
    try std.testing.expectEqual(CapabilityResolverState.failed, resolver.state);
    while (!resolver.abandoned_loads.?.finished.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);

    resolver.last_attempt_ms -= 60_000;
    try resolver.refreshWithin(alloc, provider, input, 20);
    // Only the second load is left; the testing allocator fails the test if
    // the first leaks.
    try std.testing.expect(resolver.abandoned_loads.?.next == null);
    try std.testing.expectEqual(@as(usize, 2), gated.calls.load(.seq_cst));
    try std.testing.expectEqual(CapabilityResolverState.failed, resolver.state);
}

const test_saved_format = model_catalog.SavedFormat{ .url_fn = testSavedUrl, .parse_fn = testParseSaved };

fn testSavedUrl(alloc: Allocator, endpoint: []const u8) ?[]u8 {
    return alloc.print("http://catalog.test{s}", .{endpoint}) catch null;
}

/// A body that starts with '!' does not parse.
fn testParseSaved(alloc: Allocator, body: []const u8) Allocator.Error!model_catalog.ProviderResult {
    if (body.len == 0 or body[0] == '!') return .{ .failure = .{ .category = .malformed_response } };
    return .{ .catalog = try testCatalogFromBody(alloc, body) };
}

fn testCatalogFromBody(alloc: Allocator, body: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |id| try ids.append(alloc, id);
    return testCatalogOf(alloc, ids.items);
}

fn testTeam(secret_text: []const u8) [token_pass.identity_len]u8 {
    var team: [token_pass.identity_len]u8 = undefined;
    _ = token_pass.identity(&team, .api_key, secret_text, "team_123");
    return team;
}

fn saveTestCatalog(alloc: Allocator, home: []const u8, team: [token_pass.identity_len]u8, body: []const u8, saved_ms: i64) !void {
    try saved_catalog.save(alloc, home, .{ .team = team, .url = "http://catalog.test/v1/models" }, body, saved_ms);
}

fn savedTestBody(alloc: Allocator, home: []const u8, team: [token_pass.identity_len]u8) ?[]u8 {
    var saved = saved_catalog.load(alloc, home, .{ .team = team, .url = "http://catalog.test/v1/models" }) orelse return null;
    defer saved.deinit(alloc);
    return alloc.dupe(u8, saved.body) catch null;
}

fn savingTestInput() model_catalog.FetchInput {
    return .{
        .access = credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", "team_123"),
        .endpoint = "/v1/models",
    };
}

test "a saved catalog younger than the refresh interval answers at once, and no load starts" {
    const alloc = std.testing.allocator;
    defer token_pass_team.clear();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const team = testTeam("test-key");
    try saveTestCatalog(alloc, home, team, "saved/model", io_mod.milliTimestamp() - 1_000);

    var gated: GatedCatalog = .{ .body = "fresh/model", .connects = true };
    const provider = gated.savingProvider();
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    resolver.useSavedCatalog(alloc, provider, savingTestInput(), home, team);
    resolver.startLoad(alloc, provider, savingTestInput());
    try std.testing.expect(resolver.pending_load == null);
    try std.testing.expect(resolver.catalog_saved);
    try std.testing.expectEqualStrings("saved/model", resolver.catalogEntries().?[0].id);
    try resolver.refreshWithin(alloc, provider, savingTestInput(), 60_000);
    try std.testing.expectEqual(@as(usize, 0), gated.calls.load(.seq_cst));
}

test "a due saved catalog answers while a background load saves the fresh one, and the next refresh takes it" {
    const alloc = std.testing.allocator;
    defer token_pass_team.clear();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const team = testTeam("test-key");
    try saveTestCatalog(alloc, home, team, "saved/model", io_mod.milliTimestamp() - 120_000);

    var gated: GatedCatalog = .{ .body = "fresh/model,fresh/other", .connects = true };
    const provider = gated.savingProvider();
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    resolver.useSavedCatalog(alloc, provider, savingTestInput(), home, team);
    resolver.startLoad(alloc, provider, savingTestInput());
    const load = resolver.pending_load.?;
    // The fetch is held: the saved catalog answers.
    try resolver.refreshWithin(alloc, provider, savingTestInput(), 60_000);
    try std.testing.expectEqualStrings("saved/model", resolver.catalogEntries().?[0].id);
    try std.testing.expect(resolver.pending_load == load);

    gated.released.store(true, .seq_cst);
    while (!load.finished.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    // The load saved what it fetched before it ended.
    const saved = savedTestBody(alloc, home, team).?;
    defer alloc.free(saved);
    try std.testing.expectEqualStrings("fresh/model,fresh/other", saved);

    try resolver.refreshWithin(alloc, provider, savingTestInput(), 60_000);
    try std.testing.expect(resolver.pending_load == null);
    try std.testing.expect(!resolver.catalog_saved);
    try std.testing.expectEqual(@as(usize, 2), resolver.catalogEntries().?.len);
    try std.testing.expectEqual(@as(usize, 1), gated.calls.load(.seq_cst));
}

test "a saved catalog older than a day, for another team, or broken leaves the first lookup to wait, which saves the fresh one" {
    const alloc = std.testing.allocator;
    defer token_pass_team.clear();
    const Case = enum { old, other_team, broken };
    for ([_]Case{ .old, .other_team, .broken }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(home);
        const team = testTeam("test-key");
        const now = io_mod.milliTimestamp();
        switch (case) {
            .old => try saveTestCatalog(alloc, home, team, "saved/model", now - saved_catalog_plan.max_age_ms),
            .other_team => try saveTestCatalog(alloc, home, testTeam("other-key"), "saved/model", now),
            .broken => try saveTestCatalog(alloc, home, team, "!saved/model", now),
        }

        var gated: GatedCatalog = .{ .body = "fresh/model", .connects = true };
        gated.released.store(true, .seq_cst);
        const provider = gated.savingProvider();
        var resolver: CapabilityResolver = .{};
        defer resolver.deinit(alloc);
        resolver.useSavedCatalog(alloc, provider, savingTestInput(), home, team);
        try std.testing.expectEqual(CapabilityResolverState.idle, resolver.state);
        _ = try resolver.resolveWithin(alloc, provider, savingTestInput(), "fresh/model", .{}, 60_000);
        try std.testing.expectEqualStrings("fresh/model", resolver.catalogEntries().?[0].id);
        const saved = savedTestBody(alloc, home, team).?;
        defer alloc.free(saved);
        try std.testing.expectEqualStrings("fresh/model", saved);
    }
}

test "the public catalog after a rejected credential is never saved" {
    const alloc = std.testing.allocator;
    defer token_pass_team.clear();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const team = testTeam("test-key");

    var gated: GatedCatalog = .{ .body = "public/model", .connects = true, .rejects_credential = true };
    gated.released.store(true, .seq_cst);
    const provider = gated.savingProvider();
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    resolver.useSavedCatalog(alloc, provider, savingTestInput(), home, team);
    _ = try resolver.resolveWithin(alloc, provider, savingTestInput(), "public/model", .{}, 60_000);
    try std.testing.expectEqualStrings("public/model", resolver.catalogEntries().?[0].id);
    try std.testing.expect(savedTestBody(alloc, home, team) == null);
}

test "taking a landed catalog load never starts one or waits for one" {
    const alloc = std.testing.allocator;
    var gated: GatedCatalog = .{};
    var resolver: CapabilityResolver = .{};
    defer resolver.deinit(alloc);
    const provider = try loadRefreshableCatalogForTest(alloc, &resolver, &gated);
    const access = (model_catalog.FetchInput{ .endpoint = "/v1/models" }).access;

    // Due, but nothing runs: nothing starts.
    try resolver.takeLanded(alloc, provider, access);
    try std.testing.expect(resolver.pending_load == null);
    try resolver.refreshWithin(alloc, provider, .{ .endpoint = "/v1/models" }, 60_000);
    const load = resolver.pending_load.?;
    // Running and held: nothing waits.
    try resolver.takeLanded(alloc, provider, access);
    try std.testing.expect(resolver.pending_load == load);
    gated.released.store(true, .seq_cst);
    while (!load.finished.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    try resolver.takeLanded(alloc, provider, access);
    try std.testing.expect(resolver.pending_load == null);
    try std.testing.expectEqual(@as(usize, 2), gated.calls.load(.seq_cst));
}
