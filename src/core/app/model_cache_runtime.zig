const std = @import("std");
const model_roles = @import("../config/model_roles.zig");
const model_provider = @import("../config/model_provider.zig");
const configured_provider = @import("../config/configured_provider.zig");
const chat_completions = @import("../../gateway/chat_completions.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const collections = @import("../shared/collections.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_catalog_metadata = @import("../gateway/model_catalog_metadata.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const io_mod = @import("../shared/io.zig");
const host_target = @import("../hosts/target.zig");
const list_window = @import("../shared/list_window.zig");
const fuzzy_match = @import("../shared/fuzzy_match.zig");
const types = @import("../shared/types.zig");
const test_builtin_gateway = if (@import("builtin").is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};
const test_gateway_client = if (@import("builtin").is_test)
    @import("../../gateway/client.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const e2e_gateway_models_url_env = "FX_E2E_GATEWAY_MODELS_URL";

/// What asked for a catalog load. Every trigger is user activity, so an idle
/// session never polls the models endpoint.
pub const LoadTrigger = enum {
    /// Refetches a loaded catalog only after the provider's refresh interval.
    activity,
    /// The model picker opened. Revalidates unless a fetch is in flight or
    /// one started less than `picker_revalidate_floor_ms` ago.
    picker_open,
    /// Ignore freshness and retry backoff for an explicit user refresh.
    force,
};

/// Reopening the picker within this window reuses the catalog it just fetched.
const picker_revalidate_floor_ms: i64 = 5_000;

/// After consecutive failures no trigger fetches again for 5 s, then 10 s,
/// 20 s, and so on, up to five minutes, so an outage is never hammered.
const failure_backoff_base_ms: i64 = 5_000;
const failure_backoff_cap_ms: i64 = 5 * std.time.ms_per_min;

/// How long a request waits for a failed catalog's retry before it goes out
/// without the catalog's limits.
const failed_catalog_retry_wait_ms: i64 = 2_000;

fn failureBackoffMs(failure_streak: u32) i64 {
    var delay = failure_backoff_base_ms;
    var step: u32 = 1;
    while (step < failure_streak and delay < failure_backoff_cap_ms) : (step += 1) delay *= 2;
    return @min(delay, failure_backoff_cap_ms);
}

const ModelCacheState = enum {
    idle,
    loading,
    ready,
    failed,
};

const CatalogOutcome = struct {
    loaded: ?model_catalog.Provenance = null,
    last_failure: ?model_catalog.FailedOutcome = null,
};

/// What publishing one fetch result did, for the /trace report.
const AppliedFetch = union(enum) {
    ready: struct {
        entries: usize,
        reused_previous: bool,
        provenance: model_catalog.Provenance,
    },
    failed: struct {
        outcome: model_catalog.FailedOutcome,
        kept_previous: bool,
    },

    fn record(self: AppliedFetch) void {
        switch (self) {
            .ready => |ready| diagnostics.recordModelCatalogEvent(false, .load, "outcome=ready entries={d} reused_previous={s} anonymous_fallback={s} fallback_failure={s}", .{
                ready.entries,
                boolLabel(ready.reused_previous),
                boolLabel(ready.provenance.anonymous_fallback_used),
                boolLabel(ready.provenance.fallback_failure != null),
            }),
            .failed => |failed| diagnostics.recordModelCatalogEvent(true, .load, "outcome=failed category={s} status={d} retryable={s} anonymous_fallback={s} kept_previous_catalog={s}", .{
                @tagName(failed.outcome.failure.category),
                if (failed.outcome.failure.http_status) |status| @backingInt(status) else 0,
                boolLabel(failed.outcome.failure.retryable),
                boolLabel(failed.outcome.anonymous_fallback_used),
                boolLabel(failed.kept_previous),
            }),
        }
    }
};

const OwnedCatalogAccess = struct {
    access: credentials.CatalogAccess,

    fn init(alloc: Allocator, access: credentials.CatalogAccess) !OwnedCatalogAccess {
        return switch (access) {
            .public_only, .host_managed => .{ .access = access },
            .authenticated => |authenticated| blk: {
                const credential = try alloc.dupe(u8, authenticated.credential);
                errdefer secret.zeroAndFree(alloc, credential);

                const team_context = if (access.teamContext()) |team|
                    try alloc.dupe(u8, team)
                else
                    null;
                errdefer if (team_context) |team| alloc.free(team);

                const account_id = if (access.accountId()) |account|
                    try alloc.dupe(u8, account)
                else
                    null;
                errdefer if (account_id) |account| alloc.free(account);

                break :blk .{
                    .access = .{
                        .authenticated = .{
                            .source = authenticated.source,
                            .credential = credential,
                            .team_context = team_context,
                            .account_id = account_id,
                        },
                    },
                };
            },
        };
    }

    fn deinit(self: *OwnedCatalogAccess, alloc: Allocator) void {
        switch (self.access) {
            .public_only, .host_managed => {},
            .authenticated => |access| {
                secret.zeroAndFree(alloc, @constCast(access.credential));
                if (access.team_context) |team| alloc.free(@constCast(team));
                if (access.account_id) |account| alloc.free(@constCast(account));
            },
        }
        self.* = undefined;
    }
};

/// A provider source and its credentials as seen by the registry. The
/// credential is borrowed for the call and copied by `syncProviders`; the
/// registry never keeps a caller-owned secret slice.
/// Builds owned seed rows from declared provider metadata. The caller keeps
/// the returned entries alive until `syncProviders` copies them, then releases
/// them with `model_catalog.freeModelCatalog`.
pub fn metadataSeed(
    alloc: Allocator,
    metadata_lists: []const []const configured_provider.ModelMetadata,
    defaults: ?*const configured_provider.ModelMetadata,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var result: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &result);
    for (metadata_lists) |list| for (list) |base| {
        if (findCatalogModel(result.items, base.id) != null) continue;
        const merged = if (defaults) |value|
            configured_provider.overlayMetadata(base, value.*)
        else
            base;
        const entry = try model_catalog.cloneModelCatalogEntry(alloc, chat_completions.metadata_entry(merged));
        result.append(alloc, entry) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, entry);
            return err;
        };
    };
    return result;
}

pub const ProviderConfig = struct {
    provider: model_provider.ProviderId,
    catalog: ?model_catalog.Provider = null,
    endpoint: []const u8 = "/v1/models",
    access: credentials.CatalogAccess = .{ .public_only = .no_credential },
    refresh_interval_ms: ?i64 = null,
    /// A seed may still require one initial live discovery. Declared-only
    /// providers leave this false and keep their seed as the catalog.
    refresh_on_seed: bool = false,
    from_profile_settings: bool = false,
    /// Optional durable provider-keyed cache. Runtime owns the copied path,
    /// reads it before the first network load, and atomically replaces it only
    /// after a non-empty catalog is published.
    cache_path: ?[]const u8 = null,
    /// Native policy metadata borrowed from the host provider registry. The
    /// registry outlives this Runtime; snapshots copy any strings they expose.
    native_overrides: ?*const configured_provider.NativeOverrides = null,
    /// Declared models are copied into the provider snapshot before a live
    /// refresh. They remain visible when the live endpoint is unavailable.
    seed: []const model_catalog.ModelCatalogEntry = &.{},
};

const PersistedCatalogEntry = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    cost: ?model_catalog.ModelCost = null,
    intelligence: ?f64 = null,
    recommended: bool = false,
    beta: bool = false,
    model_type: []const u8 = "language",
    tokenizer: ?[]const u8 = null,
    released: i64 = 0,
    has_tool_use: bool = false,
    has_reasoning: bool = false,
    reasoning_efforts: []const []const u8 = &.{},
    supports_fast_mode: bool = false,
    supports_ultrafast_mode: bool = false,
    has_vision: bool = false,
    has_file_input: bool = false,
    has_web_search: bool = false,
    has_explicit_caching: bool = false,
    has_implicit_caching: bool = false,
    context_window: u32 = 0,
    max_tokens: u32 = 0,
    web_search_price: ?[]const u8 = null,
};

const PersistedCatalog = struct {
    version: u32 = 1,
    saved_at_ms: i64 = 0,
    models: []const PersistedCatalogEntry = &.{},
};

const PersistedLoad = struct {
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry),
    age_ms: i64,
};

pub const ProviderCacheStatus = enum {
    idle,
    loading,
    ready,
    failed,
};

/// A point-in-time status for one provider. All fields are values or static
/// strings; callers may keep this after the cache lock is released.
pub const ProviderSnapshot = struct {
    provider: model_provider.NameKey,
    status: ProviderCacheStatus,
    /// True after F5 arrives during another fetch and before replay starts.
    force_refresh_pending: bool = false,
    entries: usize,
    auth_available: bool,
    access_level: ?model_catalog.AccessLevel,
    credential_source: ?credentials.Source,
    public_only_reason: ?credentials.CatalogPublicOnlyReason,
    private_models_hidden: bool,
    from_profile_settings: bool,
    last_attempt_age_ms: ?i64,
    last_success_age_ms: ?i64,
    failure: ?model_catalog.Failure,
};

/// One catalog model projected for the model hub.
pub const HubEntry = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    cost: ?model_catalog.ModelCost = null,
    intelligence: ?f64 = null,
    recommended: bool = false,
    beta: bool = false,
    released: i64 = 0,
    context_window: ?u32,
    max_tokens: ?u32 = null,
    has_tool_use: bool = false,
    has_reasoning: bool = false,
    has_vision: bool = false,
    has_file_input: bool = false,
    efforts: []const types.ReasoningEffort,
};

/// A provider's owned model projection for the model hub. `models` is copied
/// into the arena supplied to `snapshotForHubAll`.
pub const ProviderHubSnapshot = struct {
    provider: model_provider.NameKey,
    models: ?[]HubEntry,
    state: ProviderSnapshot,
};

const ProviderSlot = struct {
    alloc: Allocator,
    provider: model_provider.ProviderId,
    source: ?model_catalog.Provider,
    endpoint: []const u8,
    access: OwnedCatalogAccess,
    refresh_interval_ms: ?i64,
    refresh_on_seed: bool,
    from_profile_settings: bool,
    cache_path: ?[]u8 = null,
    native_overrides: ?*const configured_provider.NativeOverrides = null,
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: ModelCacheState = .idle,
    fetch_in_flight: bool = false,
    /// A forced refresh received during an active fetch is replayed after the
    /// current publication boundary, so F5 cannot lose a credential refresh.
    pending_force_refresh: bool = false,
    failure_streak: u32 = 0,
    retry_not_before_ms: i64 = 0,
    staged: ?model_catalog.FetchResult = null,
    completion_pending: bool = false,
    last_attempt_ms: i64 = 0,
    last_success_ms: i64 = 0,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    requested_access: ?model_catalog.AccessMetadata = null,
    outcome: CatalogOutcome = .{},

    fn init(alloc: Allocator, config: ProviderConfig) !ProviderSlot {
        var source = config.catalog;
        if (source) |*value| {
            value.provider_id = config.provider;
            if (config.refresh_interval_ms) |interval| value.refresh_interval_ms = interval;
        }
        var slot = ProviderSlot{
            .alloc = alloc,
            .provider = config.provider,
            .source = source,
            .endpoint = config.endpoint,
            .access = undefined,
            .refresh_interval_ms = config.refresh_interval_ms orelse if (source) |value| value.refresh_interval_ms else null,
            .refresh_on_seed = config.refresh_on_seed or (if (source) |value| value.refresh_on_seed else false),
            .from_profile_settings = config.from_profile_settings,
            .cache_path = if (config.cache_path) |path| try alloc.dupe(u8, path) else null,
            .native_overrides = config.native_overrides,
        };
        errdefer if (slot.cache_path) |path| alloc.free(path);
        slot.access = try OwnedCatalogAccess.init(alloc, config.access);
        errdefer slot.access.deinit(alloc);
        if (config.seed.len > 0) {
            slot.catalog = try cloneCatalog(alloc, config.seed);
            slot.state = .ready;
            slot.last_success_ms = model_catalog.clockMs();
            slot.outcome.loaded = .{ .access = model_catalog.AccessMetadata.init(config.access) };
            slot.requested_access = model_catalog.AccessMetadata.init(config.access);
        }
        if (slot.cache_path) |path| if (try loadPersistedCatalog(alloc, path)) |persisted| {
            if (persisted.catalog.items.len > 0) {
                model_catalog.freeModelCatalog(alloc, &slot.catalog);
                slot.catalog = persisted.catalog;
                slot.state = .ready;
                slot.last_success_ms = persistedSuccessTimestamp(persisted.age_ms);
                slot.outcome = .{ .loaded = .{ .access = model_catalog.AccessMetadata.init(config.access) } };
                slot.requested_access = model_catalog.AccessMetadata.init(config.access);
            } else {
                var empty = persisted.catalog;
                model_catalog.freeModelCatalog(alloc, &empty);
            }
        };
        return slot;
    }

    fn deinit(self: *ProviderSlot) void {
        slotCancelAndJoin(self);
        self.mutex.lockUncancelable(io_mod.getIo());
        slotDiscardStagedLocked(self);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.mutex.unlock(io_mod.getIo());
        self.access.deinit(self.alloc);
        if (self.cache_path) |path| self.alloc.free(path);
        self.* = undefined;
    }
};

pub const ModelMenuLoadState = enum {
    loading,
    ready,
    failed,
};

pub const ModelMenuCatalogState = struct {
    access_level: ?model_catalog.AccessLevel = null,
    source: ?credentials.Source = null,
    public_only_reason: ?credentials.CatalogPublicOnlyReason = null,
    private_models_hidden: bool = false,
    from_profile_settings: bool = false,
    failure: ?Failure = null,

    pub const Failure = struct {
        category: model_catalog.FailureCategory,
        retryable: bool,
    };
};

pub const ModelProviderFilter = enum {
    all,
    anthropic,
    openai,
    xai,
    zai,
    others,
};

pub const model_provider_filter_count = @typeInfo(ModelProviderFilter).@"enum".field_names.len;

pub const ModelMenuItem = struct {
    id: []u8,
    provider: []const u8,
    capabilities: model_capabilities.Capabilities,

    fn deinit(self: ModelMenuItem, alloc: Allocator) void {
        alloc.free(self.id);
    }
};

pub const ModelMenu = struct {
    active: bool = false,
    load_state: ModelMenuLoadState = .loading,
    catalog_state: ModelMenuCatalogState = .{},
    items: std.ArrayList(ModelMenuItem) = .empty,
    provider_index: usize = 0,
    selected_index: usize = 0,
    window_start: usize = 0,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    /// The role Enter assigns the highlighted model to; Ctrl+R steps it.
    /// Null switches models as usual (D170).
    assign_role: ?model_roles.Role = null,

    /// Steps `assign_role` through the roles and back to none.
    pub fn stepAssignRole(self: *ModelMenu) void {
        const order = [_]model_roles.Role{ .small, .deep, .worker, .tiny, .review, .title, .compact, .default, .designer, .commit, .advisor };
        const current = self.assign_role orelse {
            self.assign_role = order[0];
            return;
        };
        const index = std.mem.findScalar(model_roles.Role, &order, current) orelse order.len - 1;
        self.assign_role = if (index + 1 < order.len) order[index + 1] else null;
    }

    pub fn deinit(self: *ModelMenu, alloc: Allocator) void {
        self.clearSnapshot(alloc);
        self.* = .{};
    }

    pub fn query(self: *const ModelMenu) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *ModelMenu, query_text: []const u8) void {
        const len = @min(query_text.len, self.query_buf.len);
        if (len > 0) @memmove(self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
        self.selected_index = 0;
        self.window_start = 0;
    }

    pub fn providerFilter(self: *const ModelMenu) ModelProviderFilter {
        return @fromBackingInt(@intCast(@min(self.provider_index, model_provider_filter_count - 1)));
    }

    pub fn filteredItemCount(self: *const ModelMenu) usize {
        return modelMenuFilteredItemCount(self.items.items, self.providerFilter(), self.query());
    }

    pub fn itemAt(self: *const ModelMenu, display_index: usize) ?*const ModelMenuItem {
        return modelMenuItemAt(self.items.items, self.providerFilter(), self.query(), display_index);
    }

    pub fn moveVisibleItems(self: *ModelMenu, delta: i32, visible_items: u16) bool {
        const item_count = self.filteredItemCount();
        if (!self.active or self.load_state != .ready or item_count == 0) return false;

        const current: i32 = @intCast(self.selected_index % item_count);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(item_count)) - 1;
        if (next >= @as(i32, @intCast(item_count))) next = 0;
        self.selected_index = @intCast(next);
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            @max(visible_items, 1),
        );
        return true;
    }

    pub fn moveProvider(self: *ModelMenu, delta: i32) bool {
        if (!self.active or self.load_state != .ready or delta == 0) return false;
        const filter_count = model_provider_filter_count;
        if (filter_count <= 1) return false;

        const current = @min(self.provider_index, filter_count - 1);
        const direction: i32 = if (delta < 0) -1 else 1;
        var next: i32 = @intCast(current);
        for (0..filter_count) |_| {
            next += direction;
            if (next < 0) next = @as(i32, @intCast(filter_count)) - 1;
            if (next >= @as(i32, @intCast(filter_count))) next = 0;
            const filter: ModelProviderFilter = @fromBackingInt(@intCast(next));
            if (!modelProviderFilterAvailable(self.items.items, filter)) continue;
            if (next == current) return false;
            self.provider_index = @intCast(next);
            self.selected_index = 0;
            self.window_start = 0;
            return true;
        }
        return false;
    }

    pub fn selectedModelAlloc(self: *const ModelMenu, alloc: Allocator) !?[]u8 {
        if (!self.active or self.load_state != .ready) return null;
        const item = self.itemAt(self.selected_index) orelse return null;
        return try alloc.dupe(u8, item.id);
    }

    fn clearSnapshot(self: *ModelMenu, alloc: Allocator) void {
        for (self.items.items) |item| item.deinit(alloc);
        self.items.deinit(alloc);
        self.items = .empty;
        self.provider_index = 0;
        self.selected_index = 0;
        self.window_start = 0;
    }
};

pub fn modelMenuFilteredItemCount(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
) usize {
    return modelMenuRanking(items, provider_filter, query).count();
}

/// Returns the row at `display_index`. Better matches list first, and rows
/// that match equally well keep catalog order.
pub fn modelMenuItemAt(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
    display_index: usize,
) ?*const ModelMenuItem {
    const position = modelMenuRanking(items, provider_filter, query).at(display_index) orelse return null;
    return &items[position];
}

/// The inverse of `modelMenuItemAt` for the first item with `id`.
fn modelMenuDisplayIndex(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
    id: []const u8,
) ?usize {
    const position = for (items, 0..) |item, position| {
        if (std.mem.eql(u8, item.id, id)) break position;
    } else return null;
    return modelMenuRanking(items, provider_filter, query).rankOf(position);
}

/// Matches a model on its full id, provider prefix included, so one query
/// can name both the provider and the model, and on the model's own name
/// after the last `/`, so typing that name exactly lists it first:
/// `gpt-4o` finds `openai/gpt-4o` before `openai/gpt-4o-mini`.
pub fn modelIdMatch(query: []const u8, id: []const u8) ?fuzzy_match.Match {
    const slash = std.mem.findScalarLast(u8, id, '/') orelse return fuzzy_match.match(query, &.{.{ .text = id }});
    return fuzzy_match.match(query, &.{ .{ .text = id }, .{ .text = id[slash + 1 ..] } });
}

/// The Models menu in catalog order, without the rows outside the provider
/// tab.
const ModelMenuMatches = struct {
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,

    pub fn matchAt(self: ModelMenuMatches, position: usize) ?fuzzy_match.Match {
        const item = self.items[position];
        if (!providerMatchesFilter(item.provider, self.provider_filter)) return null;
        return modelIdMatch(self.query, item.id);
    }
};

fn modelMenuRanking(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
) fuzzy_match.Ranking(ModelMenuMatches) {
    return .{
        .context = .{ .items = items, .provider_filter = provider_filter, .query = query },
        .len = items.len,
    };
}

/// The catalog's ids matched the same way, for inline `/model` suggestions.
const CatalogIdMatches = struct {
    entries: []const model_catalog.ModelCatalogEntry,
    query: []const u8,

    pub fn matchAt(self: CatalogIdMatches, position: usize) ?fuzzy_match.Match {
        return modelIdMatch(self.query, self.entries[position].id);
    }
};

fn providerFilter(provider: []const u8) ModelProviderFilter {
    return if (std.ascii.eqlIgnoreCase(provider, "anthropic"))
        .anthropic
    else if (std.ascii.eqlIgnoreCase(provider, "openai"))
        .openai
    else if (std.ascii.eqlIgnoreCase(provider, "xai"))
        .xai
    else if (std.ascii.eqlIgnoreCase(provider, "zai"))
        .zai
    else
        .others;
}

pub fn modelProviderFilterAvailable(items: []const ModelMenuItem, filter: ModelProviderFilter) bool {
    if (filter == .all) return true;
    var seen: [model_provider_filter_count]bool = @splat(false);
    for (items) |item| seen[@backingInt(providerFilter(item.provider))] = true;

    var specific_count: usize = 0;
    for (seen[1..]) |available| specific_count += @intFromBool(available);
    return specific_count > 1 and seen[@backingInt(filter)];
}

fn providerMatchesFilter(provider: []const u8, filter: ModelProviderFilter) bool {
    return filter == .all or providerFilter(provider) == filter;
}

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    models_path: []const u8,
    /// The active provider is kept in the legacy fields below so existing app
    /// consumers can borrow menu rows without a provider switch. Every other
    /// provider lives in `provider_slots`; together they are the one cache.
    active_provider: ?model_provider.ProviderId = null,
    active_catalog_provider: ?model_catalog.Provider = null,
    active_endpoint: []const u8 = "/v1/models",
    active_access: ?OwnedCatalogAccess = null,
    active_refresh_interval_ms: ?i64 = null,
    active_refresh_on_seed: bool = false,
    active_cache_path: ?[]u8 = null,
    active_native_overrides: ?*const configured_provider.NativeOverrides = null,
    provider_slots: std.ArrayList(ProviderSlot) = .empty,
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: ModelCacheState = .idle,
    /// A fetch is running. Only the first load for an access shows as
    /// `.loading`; a revalidation or retry leaves the state readers see alone.
    /// A request waits up to `failed_catalog_retry_wait_ms` for a failed
    /// catalog's retry, and on nothing else but a first load.
    fetch_in_flight: bool = false,
    /// A forced refresh received during an active fetch is replayed after the
    /// current publication boundary, so F5 cannot lose a credential refresh.
    pending_force_refresh: bool = false,
    /// Consecutive failed fetches. A success or reset clears it.
    failure_streak: u32 = 0,
    /// After a failure, no fetch starts before this time, whatever the trigger.
    retry_not_before_ms: i64 = 0,
    /// A finished revalidation waiting for `pollLoadTransition` to adopt it.
    /// Owns any loaded catalog.
    staged: ?model_catalog.FetchResult = null,
    completion_pending: bool = false,
    last_attempt_ms: i64 = 0,
    last_success_ms: i64 = 0,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    requested_access: ?model_catalog.AccessMetadata = null,
    outcome: CatalogOutcome = .{},
    from_profile_settings: bool = false,
    menu: ModelMenu = .{},

    pub fn init(alloc: Allocator, models_path: []const u8) Self {
        return .{
            .alloc = alloc,
            .models_path = models_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cancelAndJoin();
        self.discardStagedLocked();
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        if (self.active_access) |*access| access.deinit(self.alloc);
        if (self.active_cache_path) |path| self.alloc.free(path);
        for (self.provider_slots.items) |*slot| slot.deinit();
        self.provider_slots.deinit(self.alloc);
        self.* = undefined;
    }

    /// Reconciles all known provider sources and credentials. Existing
    /// snapshots are retained when their provider identity remains present;
    /// an auth change resets only that provider and keeps a public snapshot.
    pub fn syncProviders(
        self: *Self,
        configs: []const ProviderConfig,
        active_provider: model_provider.ProviderId,
    ) !void {
        const active_config = for (configs) |config| {
            if (config.provider.eql(active_provider)) break config;
        } else return error.UnknownProvider;

        const active_changed = if (self.active_provider) |current| !current.eql(active_config.provider) else false;
        const active_source_changed = if (self.active_catalog_provider) |source|
            !sameCatalogProvider(source, active_config.catalog)
        else
            active_config.catalog != null;
        const active_access_changed = if (self.active_access) |owned|
            !catalogAccessEqual(owned.access, active_config.access)
        else
            true;
        const active_cache_changed = !optionalPathEqual(self.active_cache_path, active_config.cache_path);
        if (active_changed) self.resetForProviderChange();
        if (!active_changed and (active_source_changed or active_access_changed or active_cache_changed)) self.reset();
        self.active_provider = active_config.provider;
        self.active_catalog_provider = active_config.catalog;
        self.active_endpoint = active_config.endpoint;
        self.active_refresh_interval_ms = active_config.refresh_interval_ms orelse if (active_config.catalog) |source| source.refresh_interval_ms else null;
        self.active_refresh_on_seed = active_config.refresh_on_seed or (if (active_config.catalog) |source| source.refresh_on_seed else false);
        self.from_profile_settings = active_config.from_profile_settings;
        self.active_native_overrides = active_config.native_overrides;
        if (active_access_changed or self.active_access == null) _ = try self.rememberActiveAccess(active_config.access);
        if (active_cache_changed or self.active_cache_path == null) try self.rememberActiveCachePath(active_config.cache_path);
        if (self.state == .idle and active_config.seed.len > 0) {
            model_catalog.freeModelCatalog(self.alloc, &self.catalog);
            self.catalog = try cloneCatalog(self.alloc, active_config.seed);
            self.outcome = .{ .loaded = .{ .access = model_catalog.AccessMetadata.init(active_config.access) } };
            self.requested_access = model_catalog.AccessMetadata.init(active_config.access);
            self.last_success_ms = model_catalog.clockMs();
            self.state = .ready;
        }
        if (active_changed or active_source_changed or active_cache_changed) {
            if (self.active_cache_path != null) {
                try self.loadActivePersistedCatalog(active_config.access);
            }
        }

        var index: usize = 0;
        while (index < self.provider_slots.items.len) {
            const slot = &self.provider_slots.items[index];
            var wanted: ?ProviderConfig = null;
            for (configs) |config| {
                if (!config.provider.eql(active_config.provider) and config.provider.eql(slot.provider)) {
                    wanted = config;
                    break;
                }
            }
            if (wanted == null) {
                slot.deinit();
                _ = self.provider_slots.swapRemove(index);
                continue;
            }
            try slotReconfigure(slot, wanted.?);
            index += 1;
        }
        for (configs) |config| {
            if (config.provider.eql(active_config.provider)) continue;
            if (findProviderSlot(self.provider_slots.items, config.provider) != null) continue;
            try self.provider_slots.append(self.alloc, try ProviderSlot.init(self.alloc, config));
        }
    }

    /// Starts one background fetch per configured provider. A provider with a
    /// declared seed still refreshes independently in the background.
    pub fn warmupAll(self: *Self, trigger: LoadTrigger) void {
        if (self.active_catalog_provider) |provider| {
            const access: credentials.CatalogAccess = if (self.active_access) |owned| owned.access else .{ .public_only = .no_credential };
            self.startWarmup(provider, access, trigger);
        }
        for (self.provider_slots.items) |*slot| slotStartWarmup(slot, trigger);
    }

    /// Refreshes only `provider`; no active-provider mutation is performed.
    pub fn refresh(self: *Self, provider: model_provider.ProviderId, trigger: LoadTrigger) bool {
        if (self.active_provider) |active| if (active.eql(provider)) {
            const source = self.active_catalog_provider orelse return false;
            if (trigger == .force) {
                self.finishThreadIfDone();
                self.mutex.lockUncancelable(io_mod.getIo());
                const busy = self.fetch_in_flight or self.thread != null or self.staged != null;
                if (busy) self.pending_force_refresh = true;
                self.mutex.unlock(io_mod.getIo());
                if (busy) return true;
            }
            const access: credentials.CatalogAccess = if (self.active_access) |owned| owned.access else .{ .public_only = .no_credential };
            self.startWarmup(source, access, trigger);
            return true;
        };
        const slot = findProviderSlot(self.provider_slots.items, provider) orelse return false;
        if (trigger == .force) {
            slotFinishThreadIfDone(slot);
            slot.mutex.lockUncancelable(io_mod.getIo());
            const busy = slot.fetch_in_flight or slot.thread != null or slot.staged != null;
            if (busy) slot.pending_force_refresh = true;
            slot.mutex.unlock(io_mod.getIo());
            if (busy) return true;
        }
        slotStartWarmup(slot, trigger);
        return true;
    }

    /// Crosses every provider's publication boundary. The active menu is
    /// refreshed by `pollLoadTransition`; non-active snapshots are adopted in
    /// place and become visible to hub/role lookups on the next call.
    pub fn pollLoadTransitions(self: *Self) !bool {
        var changed = try self.pollLoadTransition();
        for (self.provider_slots.items) |*slot| changed = slotPoll(slot) or changed;
        return changed;
    }

    pub fn providerSnapshot(self: *Self, provider: model_provider.ProviderId) ProviderSnapshot {
        if (self.active_provider) |active| if (active.eql(provider)) return self.activeSnapshot();
        const slot = findProviderSlot(self.provider_slots.items, provider) orelse return .{
            .provider = model_provider.NameKey.fromProvider(provider),
            .status = .idle,
            .entries = 0,
            .auth_available = false,
            .access_level = null,
            .credential_source = null,
            .public_only_reason = null,
            .private_models_hidden = false,
            .from_profile_settings = false,
            .last_attempt_age_ms = null,
            .last_success_age_ms = null,
            .failure = null,
        };
        slotFinishThreadIfDone(slot);
        return snapshotForSlot(slot);
    }

    /// Returns independent status snapshots for the active provider and every
    /// configured provider. The returned array is owned by `arena`.
    pub fn providerSnapshots(self: *Self, arena: Allocator) ![]ProviderSnapshot {
        self.finishThreadIfDone();
        var result = try arena.alloc(ProviderSnapshot, self.provider_slots.items.len + @intFromBool(self.active_provider != null));
        var count: usize = 0;
        if (self.active_provider != null) {
            result[count] = self.activeSnapshot();
            count += 1;
        }
        for (self.provider_slots.items) |*slot| {
            slotFinishThreadIfDone(slot);
            result[count] = snapshotForSlot(slot);
            count += 1;
        }
        return result[0..count];
    }

    /// Copies every ready catalog into `arena`, retaining status for providers
    /// that are still loading or failed.
    pub fn snapshotForHubAll(self: *Self, arena: Allocator) ![]ProviderHubSnapshot {
        const states = try self.providerSnapshots(arena);
        const result = try arena.alloc(ProviderHubSnapshot, states.len);
        var index: usize = 0;
        if (self.active_provider != null) {
            result[index] = .{ .provider = states[index].provider, .models = try self.snapshotForHub(arena), .state = states[index] };
            index += 1;
        }
        for (self.provider_slots.items) |*slot| {
            const state = states[index];
            slot.mutex.lockUncancelable(io_mod.getIo());
            const models = if (slot.state == .ready) hubEntriesForCatalogWithNative(
                arena,
                slot.catalog.items,
                slot.native_overrides,
            ) catch |err| {
                slot.mutex.unlock(io_mod.getIo());
                return err;
            } else null;
            slot.mutex.unlock(io_mod.getIo());
            result[index] = .{ .provider = state.provider, .models = models, .state = state };
            index += 1;
        }
        return result;
    }

    /// Returns an ownership-safe copy of one provider's ready catalog.
    ///
    /// The returned list and every entry it contains belong to `alloc`; callers
    /// must release it with `model_catalog.freeModelCatalog`. Unknown,
    /// loading, and failed providers return null rather than exposing a
    /// borrowed catalog or creating a second cache.
    pub fn snapshotCatalogFor(
        self: *Self,
        provider: model_provider.ProviderId,
        alloc: Allocator,
    ) !?std.ArrayList(model_catalog.ModelCatalogEntry) {
        if (self.active_provider) |active| if (active.eql(provider)) {
            self.finishThreadIfDone();
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            if (self.state != .ready) return null;
            return try cloneCatalogWithNative(alloc, self.catalog.items, self.active_native_overrides);
        };
        const slot = findProviderSlot(self.provider_slots.items, provider) orelse return null;
        slotFinishThreadIfDone(slot);
        slot.mutex.lockUncancelable(io_mod.getIo());
        defer slot.mutex.unlock(io_mod.getIo());
        if (slot.state != .ready) return null;
        return try cloneCatalogWithNative(alloc, slot.catalog.items, slot.native_overrides);
    }

    /// Provider-aware availability for role resolution. An unknown or
    /// currently loading catalog deliberately returns true so a configured
    /// fallback is not rejected before discovery settles.
    pub fn knowsModelFor(self: *Self, provider: model_provider.ProviderId, model: []const u8) bool {
        if (self.active_provider) |active| if (active.eql(provider)) {
            if (nativeDeclaredModel(self.active_native_overrides, model)) return true;
            return self.knowsModel(model);
        };
        const slot = findProviderSlot(self.provider_slots.items, provider) orelse return true;
        slot.mutex.lockUncancelable(io_mod.getIo());
        defer slot.mutex.unlock(io_mod.getIo());
        if (nativeDeclaredModel(slot.native_overrides, model)) return true;
        if (slot.state != .ready or slot.catalog.items.len == 0) return true;
        return findCatalogModel(slot.catalog.items, model) != null;
    }

    pub fn metadataForModelFor(self: *Self, provider: model_provider.ProviderId, model: []const u8) ?model_capabilities.GatewayMetadata {
        if (self.active_provider) |active| if (active.eql(provider)) return self.metadataForModel(model);
        const slot = findProviderSlot(self.provider_slots.items, provider) orelse return null;
        slot.mutex.lockUncancelable(io_mod.getIo());
        defer slot.mutex.unlock(io_mod.getIo());
        const entry = if (slot.state == .ready) findCatalogModel(slot.catalog.items, model) else null;
        const base = if (entry) |found| model_catalog_metadata.fromCatalogEntry(found.*) else null;
        return overlayNativeGatewayMetadata(base, nativeMetadataFor(slot.native_overrides, model));
    }

    pub fn resolveForRequestFor(
        self: *Self,
        provider: model_provider.ProviderId,
        model: []const u8,
        cancel_flag: *std.atomic.Value(bool),
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        if (self.active_provider) |active| if (active.eql(provider)) return self.resolveForRequest(model, cancel_flag);
        const slot = findProviderSlot(self.provider_slots.items, provider) orelse return model_capabilities.capabilitiesForModel(model);
        slotFinishThreadIfDone(slot);
        slot.mutex.lockUncancelable(io_mod.getIo());
        defer slot.mutex.unlock(io_mod.getIo());
        const entry = if (slot.state == .ready) findCatalogModel(slot.catalog.items, model) else null;
        const base = if (entry) |found| model_catalog_metadata.fromCatalogEntry(found.*) else null;
        return model_capabilities.resolveCapabilities(model, overlayNativeGatewayMetadata(base, nativeMetadataFor(slot.native_overrides, model)));
    }

    fn activeSnapshot(self: *Self) ProviderSnapshot {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return snapshotForActiveLocked(self);
    }

    fn rememberActiveAccess(self: *Self, access: credentials.CatalogAccess) !credentials.CatalogAccess {
        const owned = try OwnedCatalogAccess.init(self.alloc, access);
        if (self.active_access) |*previous| previous.deinit(self.alloc);
        self.active_access = owned;
        return owned.access;
    }

    fn rememberActiveCachePath(self: *Self, path: ?[]const u8) !void {
        const replacement = if (path) |value| try self.alloc.dupe(u8, value) else null;
        if (self.active_cache_path) |previous| self.alloc.free(previous);
        self.active_cache_path = replacement;
    }

    fn loadActivePersistedCatalog(self: *Self, access: credentials.CatalogAccess) !void {
        const path = self.active_cache_path orelse return;
        const persisted = (try loadPersistedCatalog(self.alloc, path)) orelse return;
        if (persisted.catalog.items.len == 0) {
            var empty = persisted.catalog;
            model_catalog.freeModelCatalog(self.alloc, &empty);
            return;
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = persisted.catalog;
        self.outcome = .{ .loaded = .{ .access = model_catalog.AccessMetadata.init(access) } };
        self.requested_access = model_catalog.AccessMetadata.init(access);
        self.last_success_ms = persistedSuccessTimestamp(persisted.age_ms);
        self.state = .ready;
        self.completion_pending = true;
    }

    pub fn startWarmup(
        self: *Self,
        provider: model_catalog.Provider,
        requested_access: credentials.CatalogAccess,
        trigger: LoadTrigger,
    ) void {
        self.active_provider = provider.provider_id;
        self.active_catalog_provider = provider;
        self.active_refresh_interval_ms = provider.refresh_interval_ms;
        self.from_profile_settings = provider.provider_id == .configured;
        // Refresh callers may borrow active_access, which this replacement frees.
        const access = self.rememberActiveAccess(requested_access) catch return;
        if (comptime host_target.is_wasm) {
            self.loadCooperativeWithTrigger(provider, access, trigger);
            return;
        }
        if (!self.beginLoad(access, provider.refresh_interval_ms, trigger)) return;

        const owned_access = OwnedCatalogAccess.init(self.alloc, access) catch {
            self.completeFetch(.{ .failed = .{
                .access = .init(access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } });
            return;
        };

        const thread = std.Thread.spawn(.{}, preloadThreadMain, .{ self, provider, owned_access }) catch {
            var failed_access = owned_access;
            const failure = model_catalog.FailedOutcome{
                .access = .init(failed_access.access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .runtime, .retryable = true },
            };
            failed_access.deinit(self.alloc);
            self.completeFetch(.{ .failed = failure });
            return;
        };
        self.mutex.lockUncancelable(io_mod.getIo());
        self.thread = thread;
        self.mutex.unlock(io_mod.getIo());
    }

    /// Loads the catalog inline for cooperative single-threaded hosts.
    pub fn loadCooperative(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
    ) void {
        self.loadCooperativeWithTrigger(provider, access, .activity);
    }

    fn loadCooperativeWithTrigger(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
        trigger: LoadTrigger,
    ) void {
        self.from_profile_settings = provider.provider_id == .configured;
        if (!self.beginLoad(access, provider.refresh_interval_ms, trigger)) return;

        self.completeFetch(model_catalog.fetchWithPublicFallback(provider, self.alloc, .{
            .access = access,
            .endpoint = self.active_endpoint,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        }));
    }

    /// Loads one configured provider inline without replacing the active
    /// provider. This is used by one-shot hosts that need a complete
    /// provider-aware snapshot without starting background cache threads.
    pub fn loadCooperativeFor(self: *Self, provider: model_provider.ProviderId, trigger: LoadTrigger) void {
        if (self.active_provider) |active| if (active.eql(provider)) {
            const source = self.active_catalog_provider orelse return;
            const access: credentials.CatalogAccess = if (self.active_access) |owned|
                owned.access
            else
                .{ .public_only = .no_credential };
            self.loadCooperativeWithTrigger(source, access, trigger);
            return;
        };
        const slot = findProviderSlot(self.provider_slots.items, provider) orelse return;
        slotLoadCooperative(slot, trigger);
    }

    fn beginLoad(
        self: *Self,
        access: credentials.CatalogAccess,
        refresh_interval_ms: ?i64,
        trigger: LoadTrigger,
    ) bool {
        self.finishThreadIfDone();

        const requested_access = model_catalog.AccessMetadata.init(access);
        self.mutex.lockUncancelable(io_mod.getIo());
        const access_changed = self.state != .idle and
            (self.requested_access == null or
                !std.meta.eql(self.requested_access.?, requested_access));
        var reused_public_catalog = false;
        // A fetch started or staged under the old access would overwrite the
        // reused provenance, so only an idle ready catalog is reused; anything
        // else resets below.
        if (access_changed and
            self.state == .ready and
            !self.fetch_in_flight and
            self.staged == null and
            requested_access.level == .public_only)
        {
            if (self.outcome.loaded) |*loaded| {
                if (loaded.access.level == .public_only) {
                    self.requested_access = requested_access;
                    loaded.* = .{ .access = requested_access };
                    self.outcome.last_failure = null;
                    if (self.menu.active) {
                        self.menu.catalog_state = modelMenuCatalogState(self.outcome, self.from_profile_settings);
                    }
                    reused_public_catalog = true;
                }
            }
        }
        self.mutex.unlock(io_mod.getIo());
        if (reused_public_catalog) return false;
        if (access_changed) self.reset();

        const now = model_catalog.clockMs();
        self.mutex.lockUncancelable(io_mod.getIo());
        // A clock that moved backwards makes every elapsed check due.
        const elapsed = if (now < self.last_attempt_ms) std.math.maxInt(i64) else now - self.last_attempt_ms;
        const expired = if (refresh_interval_ms) |interval| elapsed >= interval else false;
        const picker_due = trigger == .picker_open and elapsed >= picker_revalidate_floor_ms;
        // A retained catalog whose refresh failed retries once its backoff ends.
        const retry_due = if (self.outcome.last_failure) |failed| failed.failure.retryable else false;
        const backoff_over = trigger == .force or now < self.last_attempt_ms or now >= self.retry_not_before_ms;
        // A staged revalidation is newer than anything a fetch would start now.
        // A fetch that finished after the join above still holds its thread;
        // the next trigger joins it before starting another.
        const should_load = !self.fetch_in_flight and self.staged == null and self.thread == null and backoff_over and switch (self.state) {
            .idle, .failed => true,
            .ready => trigger == .force or (self.active_refresh_on_seed and self.last_attempt_ms == 0) or expired or picker_due or retry_due,
            .loading => false,
        };
        if (!should_load) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        // A first load blocks request resolution, and a failed catalog's retry
        // holds it for at most `failed_catalog_retry_wait_ms`. A revalidation
        // runs behind the state readers already see.
        const first_load = self.state == .idle;
        if (first_load) self.state = .loading;
        self.fetch_in_flight = true;
        self.last_attempt_ms = now;
        self.requested_access = requested_access;
        const failure_streak = self.failure_streak;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);
        debug_trace.logf("catalog", "model catalog load begin trigger={s} first_load={s} expired={s} failure_streak={d}", .{
            @tagName(trigger),
            boolLabel(first_load),
            boolLabel(expired),
            failure_streak,
        });
        return true;
    }

    pub fn reset(self: *Self) void {
        self.cancelAndJoin();

        self.mutex.lockUncancelable(io_mod.getIo());
        self.discardStagedLocked();
        self.menu.deinit(self.alloc);
        const preserve_public = if (self.outcome.loaded) |loaded|
            loaded.access.level == .public_only
        else
            false;
        if (!preserve_public) {
            model_catalog.freeModelCatalog(self.alloc, &self.catalog);
            self.catalog = .empty;
            self.outcome = .{};
        }
        self.state = .idle;
        self.pending_force_refresh = false;
        self.completion_pending = false;
        self.last_attempt_ms = 0;
        // A new credential or provider deserves an immediate load.
        self.failure_streak = 0;
        self.retry_not_before_ms = 0;
        self.requested_access = null;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);
    }

    pub fn resetForProviderChange(self: *Self) void {
        debug_trace.logf("catalog", "model catalog reset reason=provider_changed", .{});
        self.reset();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = .empty;
        self.outcome = .{};
        self.from_profile_settings = false;
    }

    /// Installs a catalog that was completely fetched and validated before the
    /// caller's publication boundary. Ownership transfers without allocation.
    pub fn adoptOwnedCatalog(
        self: *Self,
        access: credentials.CatalogAccess,
        owned_catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    ) void {
        self.cancelAndJoin();

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.discardStagedLocked();
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = owned_catalog.*;
        owned_catalog.* = .empty;
        self.outcome = .{ .loaded = .{
            .access = model_catalog.AccessMetadata.init(access),
        } };
        self.from_profile_settings = false;
        self.state = .ready;
        self.completion_pending = true;
        self.last_attempt_ms = model_catalog.clockMs();
        self.last_success_ms = self.last_attempt_ms;
        self.failure_streak = 0;
        self.retry_not_before_ms = 0;
        self.requested_access = model_catalog.AccessMetadata.init(access);
        self.cancel_requested.store(false, .seq_cst);
        const entries = self.catalog.items.len;
        persistCatalog(self.active_cache_path, self.alloc, self.catalog.items);
        diagnostics.recordModelCatalogEvent(false, .load, "outcome=adopted entries={d}", .{entries});
    }

    pub fn isLoading(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state == .loading;
    }

    pub fn openMenu(self: *Self) !void {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        var next: ModelMenu = .{ .active = true };
        errdefer next.deinit(self.alloc);
        try self.refreshMenuLocked(&next);
        self.menu.deinit(self.alloc);
        self.menu = next;
    }

    pub fn closeMenu(self: *Self) void {
        self.menu.deinit(self.alloc);
    }

    pub fn setMenuQuery(self: *Self, query: []const u8) void {
        self.menu.setQuery(query);
    }

    /// The owner's publication boundary: adopts a staged revalidation and
    /// refreshes an open menu. Call it where no borrowed catalog id is held.
    pub fn pollLoadTransition(self: *Self) !bool {
        self.finishThreadIfDone();
        var replay_force = false;
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            if (self.staged) |staged| {
                self.staged = null;
                self.applyFetchLocked(staged).record();
            }
            if (!self.completion_pending) return false;

            if (self.menu.active) try self.refreshMenuLocked(&self.menu);
            self.completion_pending = false;
            replay_force = self.pending_force_refresh;
            self.pending_force_refresh = false;
        }
        if (replay_force) {
            if (self.active_catalog_provider) |source| {
                const access: credentials.CatalogAccess = if (self.active_access) |owned| owned.access else .{ .public_only = .no_credential };
                self.startWarmup(source, access, .force);
            }
        }
        return true;
    }

    pub fn isFailed(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state == .failed;
    }

    pub fn snapshotCachedModelIds(self: *Self, alloc: Allocator) !?std.ArrayList([]u8) {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready or self.catalog.items.len == 0) return null;

        return try model_catalog.projectModelIds(alloc, self.catalog.items);
    }

    /// The ready catalog copied into `arena`, or null while it loads or
    /// after it failed.
    pub fn snapshotForHub(self: *Self, arena: Allocator) !?[]HubEntry {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return null;
        return try hubEntriesForCatalogWithNative(arena, self.catalog.items, self.active_native_overrides);
    }

    /// Whether the ready catalog lists `model`; true while no catalog is
    /// ready, so a role's fallback chain does not skip a model only because
    /// nothing is known yet (D250). Takes only the mutex, so the worker
    /// thread may ask while it resolves a role.
    pub fn knowsModel(self: *Self, model: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready or self.catalog.items.len == 0) return true;
        return findCatalogModel(self.catalog.items, model) != null;
    }

    pub fn metadataForModel(self: *Self, model: []const u8) ?model_capabilities.GatewayMetadata {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = if (self.state == .ready) findCatalogModel(self.catalog.items, model) else null;
        const base = if (entry) |found| model_catalog_metadata.fromCatalogEntry(found.*) else null;
        return overlayNativeGatewayMetadata(base, nativeMetadataFor(self.active_native_overrides, model));
    }

    pub const TraceSnapshot = struct {
        state: []const u8,
        entries: usize,
        /// Null before the first fetch for the current access.
        last_attempt_age_ms: ?i64,
        failure_category: ?[]const u8,
        failure_http_status: ?std.http.Status,
        failure_retryable: bool,
        anonymous_fallback: bool,
    };

    /// Point-in-time catalog state for the /trace report; the returned struct
    /// owns no memory and stays valid after the lock is released.
    pub fn snapshotForTrace(self: *Self) TraceSnapshot {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const failure = self.outcome.last_failure;
        return .{
            .state = @tagName(self.state),
            .entries = self.catalog.items.len,
            .last_attempt_age_ms = if (self.last_attempt_ms > 0) model_catalog.clockMs() - self.last_attempt_ms else null,
            .failure_category = if (failure) |failed| @tagName(failed.failure.category) else null,
            .failure_http_status = if (failure) |failed| failed.failure.http_status else null,
            .failure_retryable = if (failure) |failed| failed.failure.retryable else false,
            .anonymous_fallback = if (failure) |failed| failed.anonymous_fallback_used else false,
        };
    }

    pub fn resolveForRequest(
        self: *Self,
        model: []const u8,
        cancel_flag: *std.atomic.Value(bool),
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        var retry_wait_until_ms: ?i64 = null;
        while (true) {
            self.finishThreadIfDone();
            self.mutex.lockUncancelable(io_mod.getIo());
            const state = self.state;
            if (state == .ready) {
                const metadata = if (findCatalogModel(self.catalog.items, model)) |entry|
                    model_catalog_metadata.fromCatalogEntry(entry.*)
                else
                    null;
                self.mutex.unlock(io_mod.getIo());
                debug_trace.logf(
                    "gateway",
                    "interactive model catalog lookup outcome={s} model={s}",
                    .{ if (metadata != null) "ready_hit" else "missing_entry", model },
                );
                if (metadata == null) {
                    diagnostics.recordModelCatalogEvent(false, .lookup, "outcome=missing_entry model={s}", .{model});
                }
                return model_capabilities.resolveCapabilities(model, metadata);
            }
            // A request waits a moment for a failed catalog's retry, such as
            // the one a submitted prompt starts, so a retry that lands quickly
            // gives this request its limits. A slow retry never holds it.
            const retry_in_flight = state == .failed and self.fetch_in_flight;
            self.mutex.unlock(io_mod.getIo());
            const wait_for_retry = retry_in_flight and wait: {
                const now = model_catalog.clockMs();
                const until = retry_wait_until_ms orelse now + failed_catalog_retry_wait_ms;
                retry_wait_until_ms = until;
                break :wait now < until;
            };

            switch (if (wait_for_retry) .loading else state) {
                .loading => {
                    if (cancel_flag.load(.seq_cst)) {
                        debug_trace.logf(
                            "gateway",
                            "interactive model catalog lookup outcome=cancelled model={s}",
                            .{model},
                        );
                        diagnostics.recordModelCatalogEvent(false, .lookup, "outcome=cancelled model={s}", .{model});
                        return error.Cancelled;
                    }
                    io_mod.sleep(std.time.ns_per_ms);
                },
                .failed, .idle => {
                    debug_trace.logf(
                        "gateway",
                        "interactive model catalog lookup outcome={s} model={s}",
                        .{ if (state == .failed) "cache_failed" else "cache_unavailable", model },
                    );
                    diagnostics.recordModelCatalogEvent(true, .lookup, "outcome={s} model={s}", .{
                        if (state == .failed) "cache_failed" else "cache_unavailable",
                        model,
                    });
                    return model_capabilities.capabilitiesForModel(model);
                },
                .ready => unreachable,
            }
        }
    }

    pub fn catalogModelCompletion(self: *Self, model: []const u8) ?[]const u8 {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return null;

        const entry = findCatalogModel(self.catalog.items, model) orelse return null;
        return entry.id;
    }

    /// Fills `out` with catalog ids that match `query`, ranked like the model
    /// menu, and returns how many it wrote. The ids borrow catalog storage.
    pub fn modelCompletions(self: *Self, query: []const u8, out: [][]const u8) usize {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return 0;

        const ranking: fuzzy_match.Ranking(CatalogIdMatches) = .{
            .context = .{ .entries = self.catalog.items, .query = query },
            .len = self.catalog.items.len,
        };
        var matches = ranking.iterator();
        var count: usize = 0;
        while (count < out.len) : (count += 1) {
            const position = matches.next() orelse break;
            out[count] = self.catalog.items[position].id;
        }
        return count;
    }

    fn preloadThreadMain(
        self: *Self,
        provider: model_catalog.Provider,
        owned_access: OwnedCatalogAccess,
    ) void {
        var access = owned_access;
        defer access.deinit(self.alloc);

        self.completeFetch(model_catalog.fetchWithPublicFallback(provider, self.alloc, .{
            .access = access.access,
            .endpoint = self.active_endpoint,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        }));
    }

    /// Publishes a finished fetch and takes ownership of its catalog. A first
    /// load lands at once: readers return nothing until the cache is ready, so
    /// none holds catalog memory. A revalidation waits in `staged` for
    /// `pollLoadTransition`, because UI readers borrow entry ids across calls
    /// within one frame.
    fn completeFetch(self: *Self, result: model_catalog.FetchResult) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.fetch_in_flight = false;
        self.completion_pending = true;
        switch (result) {
            .loaded => {
                self.failure_streak = 0;
                self.retry_not_before_ms = 0;
            },
            // Cancellation comes only from a reset or shutdown, which
            // discards this result, so it is not a failure to back off from.
            .failed => |failed| if (failed.failure.category != .cancellation) {
                self.failure_streak +|= 1;
                const delay_ms = failureBackoffMs(self.failure_streak);
                self.retry_not_before_ms = model_catalog.clockMs() + delay_ms;
                debug_trace.logf("catalog", "model catalog fetch failed category={s} failure_streak={d} retry_in_ms={d}", .{
                    @tagName(failed.failure.category),
                    self.failure_streak,
                    delay_ms,
                });
            },
        }
        if (self.state == .ready) {
            std.debug.assert(self.staged == null);
            self.staged = result;
            return;
        }
        self.applyFetchLocked(result).record();
    }

    /// Installs a fetch result, keeping the previous catalog when the new one
    /// failed or came back empty. Takes ownership of a loaded catalog.
    fn applyFetchLocked(self: *Self, result: model_catalog.FetchResult) AppliedFetch {
        switch (result) {
            .failed => |failure| {
                self.outcome.last_failure = failure;
                self.state = if (self.outcome.loaded != null and self.catalog.items.len > 0) .ready else .failed;
                return .{ .failed = .{ .outcome = failure, .kept_previous = self.state == .ready } };
            },
            .loaded => |loaded| {
                var catalog = loaded.catalog;
                const has_catalog = catalog.items.len > 0;
                const reuse_previous = !has_catalog and self.outcome.loaded != null and self.catalog.items.len > 0;
                if (reuse_previous) {
                    model_catalog.freeModelCatalog(self.alloc, &catalog);
                    self.outcome.last_failure = if (loaded.provenance.fallback_failure) |failure| .{
                        .access = loaded.provenance.access,
                        .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                        .failure = failure,
                    } else null;
                } else {
                    model_catalog.freeModelCatalog(self.alloc, &self.catalog);
                    self.catalog = catalog;
                    self.outcome = .{ .loaded = loaded.provenance };
                }
                self.last_success_ms = model_catalog.clockMs();
                self.state = .ready;
                if (has_catalog) persistCatalog(self.active_cache_path, self.alloc, self.catalog.items);
                return .{ .ready = .{
                    .entries = self.catalog.items.len,
                    .reused_previous = reuse_previous,
                    .provenance = loaded.provenance,
                } };
            },
        }
    }

    fn discardStagedLocked(self: *Self) void {
        const staged = self.staged orelse return;
        self.staged = null;
        switch (staged) {
            .loaded => |loaded| {
                var catalog = loaded.catalog;
                debug_trace.logf("catalog", "model catalog dropped staged revalidation reason=superseded entries={d}", .{catalog.items.len});
                model_catalog.freeModelCatalog(self.alloc, &catalog);
            },
            .failed => {},
        }
    }

    fn cancelAndJoin(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        // The worker thread can join through `finishThreadIfDone`, so the
        // handle changes hands only under the mutex.
        self.mutex.lockUncancelable(io_mod.getIo());
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
    }

    fn finishThreadIfDone(self: *Self) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_join = !self.fetch_in_flight and self.thread != null;
        const thread = if (should_join) self.thread.? else null;
        if (should_join) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| {
            handle.join();
            self.mutex.lockUncancelable(io_mod.getIo());
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
        }
    }

    fn refreshMenuLocked(self: *Self, menu: *ModelMenu) !void {
        if (!menu.active) return;
        switch (self.state) {
            .idle, .loading => {
                menu.clearSnapshot(self.alloc);
                menu.load_state = .loading;
            },
            .failed => {
                menu.clearSnapshot(self.alloc);
                // A retry runs behind the failed state; the picker shows it.
                menu.load_state = if (self.fetch_in_flight) .loading else .failed;
            },
            .ready => try hydrateMenuSnapshot(self.alloc, menu, self.catalog.items),
        }
        menu.catalog_state = modelMenuCatalogState(self.outcome, self.from_profile_settings);
    }
};

fn cloneCatalogEntry(alloc: Allocator, entry: model_catalog.ModelCatalogEntry) !model_catalog.ModelCatalogEntry {
    return model_catalog.cloneModelCatalogEntry(alloc, entry);
}

fn nativeDeclaredModel(
    overrides: ?*const configured_provider.NativeOverrides,
    model: []const u8,
) bool {
    const native = overrides orelse return false;
    for (native.model_metadata) |metadata| {
        if (std.mem.eql(u8, metadata.id, model)) return true;
    }
    return false;
}

fn nativeMetadataFor(
    overrides: ?*const configured_provider.NativeOverrides,
    model: []const u8,
) ?*const configured_provider.ModelMetadata {
    const native = overrides orelse return null;
    return native.model(model);
}

fn overlayNativeGatewayMetadata(
    base: ?model_capabilities.GatewayMetadata,
    native: ?*const configured_provider.ModelMetadata,
) ?model_capabilities.GatewayMetadata {
    var result: model_capabilities.GatewayMetadata = base orelse .{};
    const metadata = native orelse return if (base != null) result else null;
    if (metadata.tokenizer != null or nativeFieldSet(metadata.*, "tokenizer")) {
        result.tokenizer = if (metadata.tokenizer) |name|
            @import("../tokenizer/tokenizer.zig").Encoding.parse(name)
        else
            null;
    }
    if (metadata.context_window != null or nativeFieldSet(metadata.*, "context_window")) result.context_window = metadata.context_window;
    if (metadata.max_output_tokens != null or nativeFieldSet(metadata.*, "max_output_tokens")) result.max_output_tokens = metadata.max_output_tokens;
    if (metadata.max_context_window != null or nativeFieldSet(metadata.*, "max_context_window")) result.max_context_window = metadata.max_context_window;
    if (metadata.omit_max_output_tokens or nativeFieldSet(metadata.*, "omit_max_output_tokens")) result.omit_max_output_tokens = metadata.omit_max_output_tokens;
    if (metadata.prefer_websockets != null or nativeFieldSet(metadata.*, "prefer_websockets")) result.prefer_websockets = metadata.prefer_websockets;
    if (metadata.supports_tool_use != null or nativeFieldSet(metadata.*, "supports_tool_use")) result.supports_tool_use = metadata.supports_tool_use orelse false;
    if (metadata.supports_vision != null or nativeFieldSet(metadata.*, "supports_vision")) result.supports_vision = metadata.supports_vision orelse false;
    if (metadata.reasoning_efforts.len > 0 or nativeFieldSet(metadata.*, "reasoning_efforts")) {
        result.reasoning_efforts = .fromSlice(metadata.reasoning_efforts);
        result.supports_reasoning = metadata.reasoning_efforts.len > 0;
    }
    return result;
}

fn nativeFieldSet(metadata: configured_provider.ModelMetadata, field: []const u8) bool {
    for (metadata.fields) |name| if (std.mem.eql(u8, name, field)) return true;
    return false;
}

fn replaceOwnedOptionalCatalogText(
    alloc: Allocator,
    destination: *?[]u8,
    source: ?[]const u8,
) !void {
    if (source) |value| return replaceOwnedCatalogText(alloc, destination, value);
    if (destination.*) |previous| alloc.free(previous);
    destination.* = null;
}

fn replaceOwnedCatalogText(
    alloc: Allocator,
    destination: *?[]u8,
    source: []const u8,
) !void {
    const replacement = try alloc.dupe(u8, source);
    if (destination.*) |previous| alloc.free(previous);
    destination.* = replacement;
}

fn overlayNativeMetadata(
    alloc: Allocator,
    entry: *model_catalog.ModelCatalogEntry,
    metadata: configured_provider.ModelMetadata,
) !void {
    if (metadata.name != null or nativeFieldSet(metadata, "name")) {
        try replaceOwnedOptionalCatalogText(alloc, &entry.name, metadata.name);
    }
    if (metadata.description != null or nativeFieldSet(metadata, "description")) {
        try replaceOwnedOptionalCatalogText(alloc, &entry.description, metadata.description);
    }
    if (metadata.cost != null or nativeFieldSet(metadata, "cost")) entry.cost = metadata.cost;
    if (metadata.intelligence != null or nativeFieldSet(metadata, "intelligence")) entry.intelligence = metadata.intelligence;
    if (metadata.recommended or nativeFieldSet(metadata, "recommended")) entry.recommended = metadata.recommended;
    if (metadata.beta or nativeFieldSet(metadata, "beta")) entry.beta = metadata.beta;
    if (metadata.released != 0 or nativeFieldSet(metadata, "released")) entry.released = metadata.released;
    if (metadata.tokenizer != null or nativeFieldSet(metadata, "tokenizer")) {
        entry.tokenizer = if (metadata.tokenizer) |name|
            @import("../tokenizer/tokenizer.zig").Encoding.parse(name)
        else
            null;
    }
    if (metadata.context_window != null or nativeFieldSet(metadata, "context_window")) {
        entry.context_window = metadata.context_window orelse 0;
    }
    if (metadata.max_output_tokens != null or nativeFieldSet(metadata, "max_output_tokens")) {
        entry.max_tokens = metadata.max_output_tokens orelse 0;
    }
    if (metadata.max_context_window != null or nativeFieldSet(metadata, "max_context_window")) {
        entry.max_context_window = metadata.max_context_window;
    }
    if (metadata.omit_max_output_tokens or nativeFieldSet(metadata, "omit_max_output_tokens")) {
        entry.omit_max_output_tokens = metadata.omit_max_output_tokens;
    }
    if (metadata.prefer_websockets != null or nativeFieldSet(metadata, "prefer_websockets")) {
        entry.prefer_websockets = metadata.prefer_websockets;
    }
    if (metadata.supports_tool_use != null or nativeFieldSet(metadata, "supports_tool_use")) {
        entry.has_tool_use = metadata.supports_tool_use orelse false;
    }
    if (metadata.supports_vision != null or nativeFieldSet(metadata, "supports_vision")) {
        entry.has_vision = metadata.supports_vision orelse false;
        entry.has_file_input = entry.has_vision;
    }
    if (metadata.reasoning_efforts.len > 0 or nativeFieldSet(metadata, "reasoning_efforts")) {
        var replacement: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer replacement.deinit(alloc);
        try replacement.appendSlice(alloc, metadata.reasoning_efforts);
        entry.reasoning_efforts.deinit(alloc);
        entry.reasoning_efforts = replacement;
        entry.has_reasoning = metadata.reasoning_efforts.len > 0;
    }
}

fn nativeCatalogEntry(
    alloc: Allocator,
    metadata: configured_provider.ModelMetadata,
) !model_catalog.ModelCatalogEntry {
    var entry = model_catalog.ModelCatalogEntry{
        .id = try alloc.dupe(u8, metadata.id),
        .model_type = try alloc.dupe(u8, "language"),
    };
    errdefer model_catalog.freeModelCatalogEntry(alloc, entry);
    try overlayNativeMetadata(alloc, &entry, metadata);
    return entry;
}

fn cloneCatalogWithNative(
    alloc: Allocator,
    source: []const model_catalog.ModelCatalogEntry,
    overrides: ?*const configured_provider.NativeOverrides,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var result = try cloneCatalog(alloc, source);
    errdefer model_catalog.freeModelCatalog(alloc, &result);
    const native = overrides orelse return result;
    for (result.items) |*entry| {
        if (nativeMetadataFor(native, entry.id)) |metadata| try overlayNativeMetadata(alloc, entry, metadata.*);
    }
    for (native.model_metadata) |metadata| {
        if (metadata.id.len == 0 or findCatalogModel(result.items, metadata.id) != null) continue;
        const entry = try nativeCatalogEntry(alloc, metadata);
        result.append(alloc, entry) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, entry);
            return err;
        };
    }
    return result;
}

fn cloneCatalog(alloc: Allocator, source: []const model_catalog.ModelCatalogEntry) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var result: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &result);
    try result.ensureTotalCapacity(alloc, source.len);
    for (source) |entry| {
        const cloned = try cloneCatalogEntry(alloc, entry);
        result.append(alloc, cloned) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, cloned);
            return err;
        };
    }
    return result;
}

const persisted_catalog_max_bytes = 16 * 1024 * 1024;
const persisted_catalog_max_models = 2048;
const persisted_catalog_max_model_bytes = 1024;

fn persistedSuccessTimestamp(age_ms: i64) i64 {
    const now = model_catalog.clockMs();
    const age = @max(age_ms, 0);
    return now - @min(age, now);
}

fn loadPersistedCatalog(alloc: Allocator, path: []const u8) !?PersistedLoad {
    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), path, .read_only) catch return null;
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return null;
    if (stat.kind != .file or stat.nlink != 1 or stat.size > persisted_catalog_max_bytes) return null;
    const bytes = io_mod.readFileToEnd(alloc, &file, persisted_catalog_max_bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer alloc.free(bytes);

    const parsed = std.json.parseFromSlice(PersistedCatalog, alloc, bytes, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.models.len > persisted_catalog_max_models) return null;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    try catalog.ensureTotalCapacity(alloc, parsed.value.models.len);
    for (parsed.value.models) |raw| {
        if (raw.id.len == 0 or raw.id.len > persisted_catalog_max_model_bytes) continue;
        const entry = try persistedCatalogEntry(alloc, raw);
        catalog.append(alloc, entry) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, entry);
            return err;
        };
    }
    const saved_at_ms = if (parsed.value.saved_at_ms > 0) parsed.value.saved_at_ms else stat.mtime.toMilliseconds();
    const wall_now = io_mod.milliTimestamp();
    const age_ms = if (saved_at_ms > 0 and wall_now >= saved_at_ms) wall_now - saved_at_ms else 0;
    return .{ .catalog = catalog, .age_ms = age_ms };
}

fn persistedCatalogEntry(alloc: Allocator, raw: PersistedCatalogEntry) !model_catalog.ModelCatalogEntry {
    var entry = model_catalog.ModelCatalogEntry{
        .id = try alloc.dupe(u8, raw.id),
        .name = if (raw.name) |value| try alloc.dupe(u8, value) else null,
        .description = if (raw.description) |value| try alloc.dupe(u8, value) else null,
        .cost = raw.cost,
        .intelligence = raw.intelligence,
        .recommended = raw.recommended,
        .beta = raw.beta,
        .model_type = try alloc.dupe(u8, raw.model_type),
        .tokenizer = if (raw.tokenizer) |name| @import("../tokenizer/tokenizer.zig").Encoding.parse(name) else null,
        .released = raw.released,
        .has_tool_use = raw.has_tool_use,
        .has_reasoning = raw.has_reasoning,
        .supports_fast_mode = raw.supports_fast_mode,
        .supports_ultrafast_mode = raw.supports_ultrafast_mode,
        .has_vision = raw.has_vision,
        .has_file_input = raw.has_file_input,
        .has_web_search = raw.has_web_search,
        .has_explicit_caching = raw.has_explicit_caching,
        .has_implicit_caching = raw.has_implicit_caching,
        .context_window = raw.context_window,
        .max_tokens = raw.max_tokens,
        .web_search_price = if (raw.web_search_price) |value| try alloc.dupe(u8, value) else null,
    };
    errdefer model_catalog.freeModelCatalogEntry(alloc, entry);
    for (raw.reasoning_efforts) |effort_text| {
        const effort = types.ReasoningEffort.parse(effort_text) orelse continue;
        if (effort.isDefault()) continue;
        try entry.reasoning_efforts.append(alloc, effort);
    }
    return entry;
}

fn savePersistedCatalog(alloc: Allocator, path: []const u8, entries: []const model_catalog.ModelCatalogEntry) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const persisted = try a.alloc(PersistedCatalogEntry, entries.len);
    for (entries, persisted) |entry, *out| {
        const efforts = try a.alloc([]const u8, entry.reasoning_efforts.items.len);
        for (entry.reasoning_efforts.items, efforts) |*effort, *text| text.* = effort.label();
        out.* = .{
            .id = entry.id,
            .name = entry.name,
            .description = entry.description,
            .cost = entry.cost,
            .intelligence = entry.intelligence,
            .recommended = entry.recommended,
            .beta = entry.beta,
            .model_type = entry.model_type,
            .tokenizer = if (entry.tokenizer) |value| value.name() else null,
            .released = entry.released,
            .has_tool_use = entry.has_tool_use,
            .has_reasoning = entry.has_reasoning,
            .reasoning_efforts = efforts,
            .supports_fast_mode = entry.supports_fast_mode,
            .supports_ultrafast_mode = entry.supports_ultrafast_mode,
            .has_vision = entry.has_vision,
            .has_file_input = entry.has_file_input,
            .has_web_search = entry.has_web_search,
            .has_explicit_caching = entry.has_explicit_caching,
            .has_implicit_caching = entry.has_implicit_caching,
            .context_window = entry.context_window,
            .max_tokens = entry.max_tokens,
            .web_search_price = entry.web_search_price,
        };
    }
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try std.json.Stringify.value(PersistedCatalog{
        .version = 1,
        .saved_at_ms = io_mod.milliTimestamp(),
        .models = persisted,
    }, .{}, &output.writer);
    try io_mod.writeFileAtomic(alloc, path, output.written());
}

fn persistCatalog(path: ?[]const u8, alloc: Allocator, entries: []const model_catalog.ModelCatalogEntry) void {
    const cache_path = path orelse return;
    if (entries.len == 0) return;
    savePersistedCatalog(alloc, cache_path, entries) catch |err| {
        debug_trace.logf("catalog", "model catalog cache write failed err={s}", .{@errorName(err)});
    };
}

fn slotCancelAndJoin(slot: *ProviderSlot) void {
    slot.cancel_requested.store(true, .seq_cst);
    slot.mutex.lockUncancelable(io_mod.getIo());
    const thread = slot.thread;
    slot.thread = null;
    slot.mutex.unlock(io_mod.getIo());
    if (thread) |handle| handle.join();
}

fn slotFinishThreadIfDone(slot: *ProviderSlot) void {
    slot.mutex.lockUncancelable(io_mod.getIo());
    const should_join = !slot.fetch_in_flight and slot.thread != null;
    const thread = if (should_join) slot.thread.? else null;
    if (should_join) slot.thread = null;
    slot.mutex.unlock(io_mod.getIo());
    if (thread) |handle| {
        handle.join();
        slot.mutex.lockUncancelable(io_mod.getIo());
        slot.completion_pending = true;
        slot.mutex.unlock(io_mod.getIo());
    }
}

fn slotDiscardStagedLocked(slot: *ProviderSlot) void {
    const staged = slot.staged orelse return;
    slot.staged = null;
    switch (staged) {
        .loaded => |loaded| {
            var catalog = loaded.catalog;
            model_catalog.freeModelCatalog(slot.alloc, &catalog);
        },
        .failed => {},
    }
}

fn slotReset(slot: *ProviderSlot) void {
    slotCancelAndJoin(slot);
    slot.mutex.lockUncancelable(io_mod.getIo());
    slotDiscardStagedLocked(slot);
    const preserve_public = if (slot.outcome.loaded) |loaded| loaded.access.level == .public_only else false;
    if (!preserve_public) {
        model_catalog.freeModelCatalog(slot.alloc, &slot.catalog);
        slot.catalog = .empty;
        slot.outcome = .{};
    }
    slot.state = .idle;
    slot.pending_force_refresh = false;
    slot.completion_pending = false;
    slot.last_attempt_ms = 0;
    slot.last_success_ms = if (preserve_public) slot.last_success_ms else 0;
    slot.failure_streak = 0;
    slot.retry_not_before_ms = 0;
    slot.requested_access = null;
    slot.mutex.unlock(io_mod.getIo());
    slot.cancel_requested.store(false, .seq_cst);
}

fn slotBeginLoad(slot: *ProviderSlot, trigger: LoadTrigger) bool {
    slotFinishThreadIfDone(slot);
    if (slot.source == null) return false;
    const requested_access = model_catalog.AccessMetadata.init(slot.access.access);
    slot.mutex.lockUncancelable(io_mod.getIo());
    const access_changed = slot.state != .idle and
        (slot.requested_access == null or !std.meta.eql(slot.requested_access.?, requested_access));
    slot.mutex.unlock(io_mod.getIo());
    if (access_changed) slotReset(slot);

    const now = model_catalog.clockMs();
    slot.mutex.lockUncancelable(io_mod.getIo());
    const elapsed = if (now < slot.last_attempt_ms) std.math.maxInt(i64) else now - slot.last_attempt_ms;
    const interval = slot.refresh_interval_ms;
    const expired = if (interval) |value| elapsed >= value else false;
    const picker_due = trigger == .picker_open and elapsed >= picker_revalidate_floor_ms;
    const retry_due = if (slot.outcome.last_failure) |failed| failed.failure.retryable else false;
    const backoff_over = trigger == .force or now < slot.last_attempt_ms or now >= slot.retry_not_before_ms;
    const should_load = !slot.fetch_in_flight and slot.staged == null and slot.thread == null and backoff_over and switch (slot.state) {
        .idle, .failed => true,
        .ready => trigger == .force or (slot.refresh_on_seed and slot.last_attempt_ms == 0) or expired or picker_due or retry_due,
        .loading => false,
    };
    if (!should_load) {
        slot.mutex.unlock(io_mod.getIo());
        return false;
    }
    if (slot.state == .idle) slot.state = .loading;
    slot.fetch_in_flight = true;
    slot.last_attempt_ms = now;
    slot.requested_access = requested_access;
    slot.mutex.unlock(io_mod.getIo());
    slot.cancel_requested.store(false, .seq_cst);
    return true;
}

fn slotApplyFetchLocked(slot: *ProviderSlot, result: model_catalog.FetchResult) AppliedFetch {
    switch (result) {
        .failed => |failure| {
            slot.outcome.last_failure = failure;
            slot.state = if (slot.outcome.loaded != null and slot.catalog.items.len > 0) .ready else .failed;
            return .{ .failed = .{ .outcome = failure, .kept_previous = slot.state == .ready } };
        },
        .loaded => |loaded| {
            var catalog = loaded.catalog;
            const has_catalog = catalog.items.len > 0;
            const reuse_previous = !has_catalog and slot.outcome.loaded != null and slot.catalog.items.len > 0;
            if (reuse_previous) {
                model_catalog.freeModelCatalog(slot.alloc, &catalog);
                slot.outcome.last_failure = if (loaded.provenance.fallback_failure) |failure| .{
                    .access = loaded.provenance.access,
                    .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                    .failure = failure,
                } else null;
            } else {
                model_catalog.freeModelCatalog(slot.alloc, &slot.catalog);
                slot.catalog = catalog;
                slot.outcome = .{ .loaded = loaded.provenance };
            }
            slot.last_success_ms = model_catalog.clockMs();
            slot.state = .ready;
            if (has_catalog) persistCatalog(slot.cache_path, slot.alloc, slot.catalog.items);
            return .{ .ready = .{
                .entries = slot.catalog.items.len,
                .reused_previous = reuse_previous,
                .provenance = loaded.provenance,
            } };
        },
    }
}

fn slotCompleteFetch(slot: *ProviderSlot, result: model_catalog.FetchResult) void {
    slot.mutex.lockUncancelable(io_mod.getIo());
    defer slot.mutex.unlock(io_mod.getIo());
    slot.fetch_in_flight = false;
    slot.completion_pending = true;
    switch (result) {
        .loaded => {
            slot.failure_streak = 0;
            slot.retry_not_before_ms = 0;
        },
        .failed => |failed| if (failed.failure.category != .cancellation) {
            slot.failure_streak +|= 1;
            slot.retry_not_before_ms = model_catalog.clockMs() + failureBackoffMs(slot.failure_streak);
        },
    }
    if (slot.state == .ready) {
        std.debug.assert(slot.staged == null);
        slot.staged = result;
        return;
    }
    slotApplyFetchLocked(slot, result).record();
}

fn slotThreadMain(slot: *ProviderSlot, provider: model_catalog.Provider, access: OwnedCatalogAccess) void {
    var owned = access;
    defer owned.deinit(slot.alloc);
    slotCompleteFetch(slot, model_catalog.fetchWithPublicFallback(provider, slot.alloc, .{
        .access = owned.access,
        .endpoint = slot.endpoint,
        .cancel_flag = &slot.cancel_requested,
        .view = .picker,
    }));
}

fn slotStartWarmup(slot: *ProviderSlot, trigger: LoadTrigger) void {
    if (comptime host_target.is_wasm) {
        slotLoadCooperative(slot, trigger);
        return;
    }
    slotFinishThreadIfDone(slot);
    if (!slotBeginLoad(slot, trigger)) return;
    const provider = slot.source orelse return;
    const access = OwnedCatalogAccess.init(slot.alloc, slot.access.access) catch {
        slotCompleteFetch(slot, .{ .failed = .{
            .access = .init(slot.access.access),
            .anonymous_fallback_used = false,
            .failure = .{ .category = .resource_exhausted },
        } });
        return;
    };
    const thread = std.Thread.spawn(.{}, slotThreadMain, .{ slot, provider, access }) catch {
        var failed_access = access;
        const failure = model_catalog.FailedOutcome{
            .access = .init(failed_access.access),
            .anonymous_fallback_used = false,
            .failure = .{ .category = .runtime, .retryable = true },
        };
        failed_access.deinit(slot.alloc);
        slotCompleteFetch(slot, .{ .failed = failure });
        return;
    };
    slot.mutex.lockUncancelable(io_mod.getIo());
    slot.thread = thread;
    slot.mutex.unlock(io_mod.getIo());
}

fn slotLoadCooperative(slot: *ProviderSlot, trigger: LoadTrigger) void {
    if (!slotBeginLoad(slot, trigger)) return;
    const provider = slot.source orelse return;
    slotCompleteFetch(slot, model_catalog.fetchWithPublicFallback(provider, slot.alloc, .{
        .access = slot.access.access,
        .endpoint = slot.endpoint,
        .cancel_flag = &slot.cancel_requested,
        .view = .picker,
    }));
}

fn slotPoll(slot: *ProviderSlot) bool {
    slotFinishThreadIfDone(slot);
    var replay_force = false;
    {
        slot.mutex.lockUncancelable(io_mod.getIo());
        defer slot.mutex.unlock(io_mod.getIo());
        if (slot.staged) |staged| {
            slot.staged = null;
            slotApplyFetchLocked(slot, staged).record();
        }
        if (!slot.completion_pending) return false;
        slot.completion_pending = false;
        replay_force = slot.pending_force_refresh;
        slot.pending_force_refresh = false;
    }
    if (replay_force) slotStartWarmup(slot, .force);
    return true;
}

fn sameCatalogProvider(a: model_catalog.Provider, b: ?model_catalog.Provider) bool {
    const other = b orelse return false;
    return a.context == other.context and
        a.fetch_fn == other.fetch_fn and
        a.lookup_capabilities_fn == other.lookup_capabilities_fn and
        a.provider_id.eql(other.provider_id) and
        a.refresh_interval_ms == other.refresh_interval_ms;
}

fn optionalPathEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if ((a == null) != (b == null)) return false;
    if (a) |left| return std.mem.eql(u8, left, b.?);
    return true;
}

fn catalogAccessEqual(a: credentials.CatalogAccess, b: credentials.CatalogAccess) bool {
    switch (a) {
        .public_only => |left| switch (b) {
            .public_only => |right| return std.meta.eql(left, right),
            else => return false,
        },
        .host_managed => return b == .host_managed,
        .authenticated => |left| switch (b) {
            .authenticated => |right| {
                if (left.source != right.source or !std.mem.eql(u8, left.credential, right.credential)) return false;
                if ((left.team_context == null) != (right.team_context == null)) return false;
                if (left.team_context) |value| if (!std.mem.eql(u8, value, right.team_context.?)) return false;
                if ((left.account_id == null) != (right.account_id == null)) return false;
                if (left.account_id) |value| if (!std.mem.eql(u8, value, right.account_id.?)) return false;
                return std.meta.eql(left.authority, right.authority);
            },
            else => return false,
        },
    }
}

fn findProviderSlot(slots: []ProviderSlot, provider: model_provider.ProviderId) ?*ProviderSlot {
    for (slots) |*slot| if (slot.provider.eql(provider)) return slot;
    return null;
}

fn slotReconfigure(slot: *ProviderSlot, config: ProviderConfig) !void {
    const source_changed = if (slot.source) |source| !sameCatalogProvider(source, config.catalog) else config.catalog != null;
    const access_changed = !catalogAccessEqual(slot.access.access, config.access);
    const cache_changed = !optionalPathEqual(slot.cache_path, config.cache_path);
    if (source_changed or access_changed or cache_changed or !std.mem.eql(u8, slot.endpoint, config.endpoint)) slotReset(slot);
    if (access_changed) {
        const replacement = try OwnedCatalogAccess.init(slot.alloc, config.access);
        slot.access.deinit(slot.alloc);
        slot.access = replacement;
    }
    var source = config.catalog;
    if (source) |*value| {
        value.provider_id = config.provider;
        if (config.refresh_interval_ms) |interval| value.refresh_interval_ms = interval;
    }
    slot.provider = config.provider;
    slot.source = source;
    slot.endpoint = config.endpoint;
    slot.refresh_interval_ms = config.refresh_interval_ms orelse if (source) |value| value.refresh_interval_ms else null;
    slot.refresh_on_seed = config.refresh_on_seed or (if (source) |value| value.refresh_on_seed else false);
    slot.from_profile_settings = config.from_profile_settings;
    slot.native_overrides = config.native_overrides;
    if (cache_changed) {
        const replacement = if (config.cache_path) |path| try slot.alloc.dupe(u8, path) else null;
        if (slot.cache_path) |previous| slot.alloc.free(previous);
        slot.cache_path = replacement;
    }
    if (slot.state == .idle and config.seed.len > 0) {
        slot.catalog = try cloneCatalog(slot.alloc, config.seed);
        slot.outcome = .{ .loaded = .{ .access = model_catalog.AccessMetadata.init(config.access) } };
        slot.requested_access = model_catalog.AccessMetadata.init(config.access);
        slot.last_success_ms = model_catalog.clockMs();
        slot.state = .ready;
    }
    if (cache_changed) {
        if (slot.cache_path) |path| {
            if (try loadPersistedCatalog(slot.alloc, path)) |persisted| {
                if (persisted.catalog.items.len > 0) {
                    model_catalog.freeModelCatalog(slot.alloc, &slot.catalog);
                    slot.catalog = persisted.catalog;
                    slot.outcome = .{ .loaded = .{ .access = model_catalog.AccessMetadata.init(config.access) } };
                    slot.requested_access = model_catalog.AccessMetadata.init(config.access);
                    slot.last_success_ms = persistedSuccessTimestamp(persisted.age_ms);
                    slot.state = .ready;
                } else {
                    var empty = persisted.catalog;
                    model_catalog.freeModelCatalog(slot.alloc, &empty);
                }
            }
        }
    }
}

fn snapshotAccess(outcome: CatalogOutcome, fallback: credentials.CatalogAccess) model_catalog.AccessMetadata {
    if (outcome.last_failure) |failed| {
        if (outcome.loaded == null or failed.anonymous_fallback_used) return failed.access;
    }
    if (outcome.loaded) |loaded| return loaded.access;
    return model_catalog.AccessMetadata.init(fallback);
}

fn snapshotFailure(outcome: CatalogOutcome) ?model_catalog.Failure {
    if (outcome.last_failure) |failure| return failure.failure;
    if (outcome.loaded) |loaded| return loaded.fallback_failure;
    return null;
}

fn projectedCatalogEntryCount(
    catalog: []const model_catalog.ModelCatalogEntry,
    overrides: ?*const configured_provider.NativeOverrides,
) usize {
    const native = overrides orelse return catalog.len;
    var count = catalog.len;
    for (native.model_metadata) |metadata| {
        if (metadata.id.len > 0 and findCatalogModel(catalog, metadata.id) == null) count += 1;
    }
    return count;
}

fn snapshotForActiveLocked(runtime: *Runtime) ProviderSnapshot {
    const provider = runtime.active_provider orelse .gateway;
    const access = snapshotAccess(runtime.outcome, if (runtime.active_access) |owned| owned.access else credentials.CatalogAccess{ .public_only = .no_credential });
    return .{
        .provider = model_provider.NameKey.fromProvider(provider),
        .status = switch (runtime.state) {
            .idle => .idle,
            .loading => .loading,
            .ready => .ready,
            .failed => .failed,
        },
        .force_refresh_pending = runtime.pending_force_refresh,
        .entries = projectedCatalogEntryCount(runtime.catalog.items, runtime.active_native_overrides),
        .auth_available = access.level == .authenticated,
        .access_level = access.level,
        .credential_source = access.source,
        .public_only_reason = access.public_only_reason,
        .private_models_hidden = access.private_models_may_be_hidden,
        .from_profile_settings = runtime.from_profile_settings,
        .last_attempt_age_ms = if (runtime.last_attempt_ms > 0) model_catalog.clockMs() - runtime.last_attempt_ms else null,
        .last_success_age_ms = if (runtime.last_success_ms > 0) model_catalog.clockMs() - runtime.last_success_ms else null,
        .failure = snapshotFailure(runtime.outcome),
    };
}

fn snapshotForSlot(slot: *ProviderSlot) ProviderSnapshot {
    slot.mutex.lockUncancelable(io_mod.getIo());
    defer slot.mutex.unlock(io_mod.getIo());
    const access = snapshotAccess(slot.outcome, slot.access.access);
    return .{
        .provider = model_provider.NameKey.fromProvider(slot.provider),
        .status = switch (slot.state) {
            .idle => .idle,
            .loading => .loading,
            .ready => .ready,
            .failed => .failed,
        },
        .force_refresh_pending = slot.pending_force_refresh,
        .entries = projectedCatalogEntryCount(slot.catalog.items, slot.native_overrides),
        .auth_available = access.level == .authenticated,
        .access_level = access.level,
        .credential_source = access.source,
        .public_only_reason = access.public_only_reason,
        .private_models_hidden = access.private_models_may_be_hidden,
        .from_profile_settings = slot.from_profile_settings,
        .last_attempt_age_ms = if (slot.last_attempt_ms > 0) model_catalog.clockMs() - slot.last_attempt_ms else null,
        .last_success_age_ms = if (slot.last_success_ms > 0) model_catalog.clockMs() - slot.last_success_ms else null,
        .failure = snapshotFailure(slot.outcome),
    };
}

fn hubEntryFromCatalog(arena: Allocator, entry: model_catalog.ModelCatalogEntry) !HubEntry {
    return .{
        .id = try arena.dupe(u8, entry.id),
        .name = try arena.dupe(u8, entry.name orelse ""),
        .description = if (entry.description) |description| try arena.dupe(u8, description) else null,
        .cost = entry.cost,
        .intelligence = entry.intelligence,
        .recommended = entry.recommended,
        .beta = entry.beta,
        .released = entry.released,
        .context_window = if (entry.context_window > 0) entry.context_window else null,
        .max_tokens = if (entry.max_tokens > 0) entry.max_tokens else null,
        .has_tool_use = entry.has_tool_use,
        .has_reasoning = entry.has_reasoning,
        .has_vision = entry.has_vision,
        .has_file_input = entry.has_file_input,
        .efforts = try arena.dupe(types.ReasoningEffort, entry.reasoning_efforts.items),
    };
}

fn hubEntriesForCatalog(arena: Allocator, catalog: []const model_catalog.ModelCatalogEntry) ![]HubEntry {
    const entries = try arena.alloc(HubEntry, catalog.len);
    for (catalog, entries) |entry, *out| out.* = try hubEntryFromCatalog(arena, entry);
    return entries;
}

fn hubEntriesForCatalogWithNative(
    arena: Allocator,
    catalog: []const model_catalog.ModelCatalogEntry,
    overrides: ?*const configured_provider.NativeOverrides,
) ![]HubEntry {
    var projected = try cloneCatalogWithNative(arena, catalog, overrides);
    defer model_catalog.freeModelCatalog(arena, &projected);
    return hubEntriesForCatalog(arena, projected.items);
}

fn boolLabel(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn modelMenuCatalogState(outcome: CatalogOutcome, from_profile_settings: bool) ModelMenuCatalogState {
    const access = if (outcome.last_failure) |failed|
        if (outcome.loaded == null or failed.anonymous_fallback_used)
            failed.access
        else
            outcome.loaded.?.access
    else if (outcome.loaded) |loaded|
        loaded.access
    else
        return .{};
    const failure = if (outcome.last_failure) |failed|
        failed.failure
    else if (outcome.loaded) |loaded|
        loaded.fallback_failure
    else
        null;
    return .{
        .access_level = access.level,
        .source = access.source,
        .public_only_reason = access.public_only_reason,
        .private_models_hidden = access.private_models_may_be_hidden,
        .from_profile_settings = from_profile_settings,
        .failure = if (failure) |failed| .{
            .category = failed.category,
            .retryable = failed.retryable,
        } else null,
    };
}

fn hydrateMenuSnapshot(
    alloc: Allocator,
    menu: *ModelMenu,
    catalog: []const model_catalog.ModelCatalogEntry,
) !void {
    var items: std.ArrayList(ModelMenuItem) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(alloc);
        items.deinit(alloc);
    }
    try items.ensureTotalCapacity(alloc, catalog.len);

    for (catalog) |entry| {
        const item = item: {
            const id = try alloc.dupe(u8, entry.id);
            errdefer alloc.free(id);
            break :item ModelMenuItem{
                .id = id,
                .provider = modelProvider(id),
                .capabilities = model_capabilities.resolveCapabilities(
                    id,
                    model_catalog_metadata.fromCatalogEntry(entry),
                ),
            };
        };
        items.append(alloc, item) catch |err| {
            item.deinit(alloc);
            return err;
        };
    }

    // A revalidated catalog replaces rows under an open menu; keep the
    // provider tab and the selected model so the cursor does not jump.
    const previous_ready = menu.load_state == .ready;
    const filter = if (previous_ready and modelProviderFilterAvailable(items.items, menu.providerFilter()))
        menu.providerFilter()
    else
        .all;
    const selected_index = if (!previous_ready) 0 else selected: {
        const previous = menu.itemAt(menu.selected_index) orelse break :selected 0;
        if (modelMenuDisplayIndex(items.items, filter, menu.query(), previous.id)) |index| break :selected index;
        const match_count = modelMenuFilteredItemCount(items.items, filter, menu.query());
        break :selected @min(menu.selected_index, match_count -| 1);
    };
    // Shift the window with the selection so its row stays put on screen.
    const window_start = if (previous_ready)
        (menu.window_start + selected_index) -| menu.selected_index
    else
        0;

    menu.clearSnapshot(alloc);
    menu.items = items;
    menu.load_state = .ready;
    menu.provider_index = @backingInt(filter);
    menu.selected_index = selected_index;
    menu.window_start = window_start;
}

fn modelProvider(model: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, model, '/') orelse return "";
    if (slash == 0) return "";
    return model[0..slash];
}

fn findCatalogModel(catalog: []const model_catalog.ModelCatalogEntry, model: []const u8) ?*const model_catalog.ModelCatalogEntry {
    for (catalog) |*entry| {
        if (std.mem.eql(u8, entry.id, model)) return entry;
    }
    return null;
}

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, models_url: []const u8) !*TestEnv {
        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put(e2e_gateway_models_url_env, models_url);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn waitForFetchToSettle(runtime: *Runtime) !void {
    var remaining_ms: u64 = 5000;
    while (fetchInFlight(runtime) and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(!fetchInFlight(runtime));
}

/// Waits for the running fetch, then crosses the publication boundary the UI
/// tick crosses, so a staged revalidation lands too.
fn waitForWarmup(runtime: *Runtime) !void {
    try waitForFetchToSettle(runtime);
    _ = try runtime.pollLoadTransition();
    try std.testing.expect(!runtime.isLoading());
    try std.testing.expect(!runtime.isFailed());
}

fn fetchInFlight(runtime: *Runtime) bool {
    runtime.mutex.lockUncancelable(io_mod.getIo());
    defer runtime.mutex.unlock(io_mod.getIo());
    return runtime.fetch_in_flight;
}

fn modelIdListContains(ids: []const []u8, needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}

fn authenticatedCatalogAccess(credential: []const u8, team_context: ?[]const u8) credentials.CatalogAccess {
    return credentials.catalogAccessForCredential(.ai_gateway_api_key, credential, team_context);
}

fn testCatalog(alloc: Allocator, model_id: []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    const id = try alloc.dupe(u8, model_id);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    try entries.append(alloc, .{ .id = id, .model_type = model_type });
    return entries;
}

const RefreshCatalog = struct {
    first_failure: ?model_catalog.Failure = null,
    fallback_model: ?[]const u8 = null,
    calls: usize = 0,

    fn fetch(raw: ?*anyopaque, alloc: Allocator, _: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *RefreshCatalog = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == 1) {
            if (self.first_failure) |failure| return .{ .failure = failure };
        }
        if (self.fallback_model) |model| return .{ .catalog = try testCatalog(alloc, model) };
        return .{ .catalog = .empty };
    }

    fn provider(self: *RefreshCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

const AuthChangeCatalog = struct {
    model_id: []const u8 = "",
    calls: usize = 0,
    credential_present: bool = false,
    team: [32]u8 = undefined,
    team_len: usize = 0,

    fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *AuthChangeCatalog = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.credential_present = input.access.authorizationCredential() != null;
        const team = input.access.teamContext() orelse "";
        std.debug.assert(team.len <= self.team.len);
        @memcpy(self.team[0..team.len], team);
        self.team_len = team.len;
        return .{ .catalog = try testCatalog(alloc, self.model_id) };
    }

    fn provider(self: *AuthChangeCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

const StaleCatalog = struct {
    started: std.atomic.Value(bool) = .init(false),
    observed_cancel: std.atomic.Value(bool) = .init(false),

    fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *StaleCatalog = @ptrCast(@alignCast(raw.?));
        const cancel_flag = input.cancel_flag orelse return .{ .failure = .{ .category = .runtime } };
        self.started.store(true, .seq_cst);
        while (!cancel_flag.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        self.observed_cancel.store(true, .seq_cst);
        return .{ .catalog = try testCatalog(alloc, "public/stale") };
    }

    fn provider(self: *StaleCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch };
    }
};

test "provider catalog snapshot is ownership safe for active and side providers" {
    const alloc = std.testing.allocator;
    var fixture = RefreshCatalog{ .fallback_model = "snapshot-model" };
    var runtime = Runtime.init(alloc, "/v1/models");
    defer runtime.deinit();
    const provider = fixture.provider();
    const configs = [_]ProviderConfig{
        .{ .provider = .gateway, .catalog = provider },
        .{ .provider = .codex, .catalog = provider },
    };
    try runtime.syncProviders(&configs, .gateway);
    runtime.loadCooperativeFor(.gateway, .activity);
    runtime.loadCooperativeFor(.codex, .activity);
    _ = try runtime.pollLoadTransitions();

    var active = (try runtime.snapshotCatalogFor(.gateway, alloc)).?;
    defer model_catalog.freeModelCatalog(alloc, &active);
    try std.testing.expectEqual(@as(usize, 1), active.items.len);
    try std.testing.expectEqualStrings("snapshot-model", active.items[0].id);

    var side = (try runtime.snapshotCatalogFor(.codex, alloc)).?;
    defer model_catalog.freeModelCatalog(alloc, &side);
    try std.testing.expectEqual(@as(usize, 1), side.items.len);
    try std.testing.expectEqualStrings("snapshot-model", side.items[0].id);
}

test "native defaults do not make arbitrary catalog models known" {
    const alloc = std.testing.allocator;
    var fixture = RefreshCatalog{ .fallback_model = "listed-model" };
    var storage = std.heap.ArenaAllocator.init(alloc);
    defer storage.deinit();
    const declared = [_]configured_provider.ModelMetadata{.{ .id = "declared-model" }};
    const defaults = configured_provider.ModelMetadata{ .id = "native-default", .context_window = 128_000 };
    var overrides = configured_provider.NativeOverrides{
        .id = "gateway",
        .model_metadata = &declared,
        .defaults = &defaults,
        .storage = storage,
    };
    var runtime = Runtime.init(alloc, "/v1/models");
    defer runtime.deinit();
    const provider = fixture.provider();
    const configs = [_]ProviderConfig{.{
        .provider = .gateway,
        .catalog = provider,
        .native_overrides = &overrides,
    }};
    try runtime.syncProviders(&configs, .gateway);
    runtime.loadCooperativeFor(.gateway, .activity);
    _ = try runtime.pollLoadTransitions();
    try std.testing.expect(runtime.knowsModelFor(.gateway, "declared-model"));
    try std.testing.expect(runtime.knowsModelFor(.gateway, "listed-model"));
    try std.testing.expect(!runtime.knowsModelFor(.gateway, "arbitrary-model"));
}

test "model cache expires successful catalogs only when the provider requests refresh" {
    for ([_]bool{ false, true }) |expires| {
        var runtime = Runtime.init(std.testing.allocator, "/v1/models");
        defer runtime.deinit();
        var source = AuthChangeCatalog{ .model_id = "first" };
        var provider = source.provider();
        provider.refresh_interval_ms = if (expires) 60_000 else null;
        runtime.loadCooperative(provider, .{ .public_only = .no_credential });
        source.model_id = "new-release";
        runtime.loadCooperative(provider, .{ .public_only = .no_credential });
        try std.testing.expectEqual(@as(usize, 1), source.calls);
        runtime.last_attempt_ms -= 60_000;
        runtime.loadCooperative(provider, .{ .public_only = .no_credential });
        try std.testing.expectEqual(@as(usize, if (expires) 2 else 1), source.calls);
        // The refreshed catalog lands at the owner's publication boundary.
        try std.testing.expectEqualStrings("first", runtime.catalog.items[0].id);
        _ = try runtime.pollLoadTransition();
        try std.testing.expectEqualStrings(if (expires) "new-release" else "first", runtime.catalog.items[0].id);
    }
}

test "model cache clears an old failure after a clean empty refresh" {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    runtime.catalog = try testCatalog(std.testing.allocator, "public/original");
    runtime.outcome = .{
        .loaded = .{ .access = .init(.{ .public_only = .no_credential }) },
        .last_failure = .{
            .access = .init(.{ .public_only = .no_credential }),
            .anonymous_fallback_used = false,
            .failure = .{ .category = .transport, .retryable = true },
        },
    };
    runtime.state = .ready;
    runtime.reset();

    var provider = RefreshCatalog{};
    runtime.startWarmup(provider.provider(), .{ .public_only = .no_credential }, .activity);
    try waitForWarmup(&runtime);

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expect(runtime.outcome.last_failure == null);
    var snapshot = (try runtime.snapshotCachedModelIds(std.testing.allocator)).?;
    defer collections.freeStringList(std.testing.allocator, &snapshot);
    try std.testing.expectEqualStrings("public/original", snapshot.items[0]);
}

test "cooperative model cache retries a ready catalog after a retryable fallback failure" {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    runtime.catalog = try testCatalog(std.testing.allocator, "public/original");
    runtime.outcome = .{
        .loaded = .{ .access = .init(.{ .public_only = .no_credential }) },
        .last_failure = .{
            .access = .init(.{ .public_only = .no_credential }),
            .anonymous_fallback_used = false,
            .failure = .{ .category = .transport, .retryable = true },
        },
    };
    runtime.state = .ready;
    runtime.requested_access = .init(.{ .public_only = .no_credential });
    runtime.last_attempt_ms = model_catalog.clockMs() - 1000;

    var provider = AuthChangeCatalog{ .model_id = "public/refreshed" };
    runtime.loadCooperative(provider.provider(), .{ .public_only = .no_credential });
    try std.testing.expect(try runtime.pollLoadTransition());

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expect(runtime.outcome.last_failure == null);
    try std.testing.expectEqualStrings("public/refreshed", runtime.catalog.items[0].id);
}

fn testCatalogIds(alloc: Allocator, ids: []const []const u8) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (ids) |model_id| {
        var one = try testCatalog(alloc, model_id);
        defer one.deinit(alloc);
        entries.append(alloc, one.items[0]) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, one.items[0]);
            return err;
        };
    }
    return entries;
}

/// Holds each fetch until released so a test can observe a revalidation in flight.
const GatedCatalog = struct {
    model_id: []const u8 = "first",
    fail: bool = false,
    refresh_interval_ms: ?i64 = 60_000,
    calls: std.atomic.Value(usize) = .init(0),
    open: std.atomic.Value(bool) = .init(true),

    fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
        const self: *GatedCatalog = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        while (!self.open.load(.seq_cst)) {
            if (input.cancel_flag) |flag| {
                if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (self.fail) return .{ .failure = .{
            .category = .gateway_unavailable,
            .http_status = .service_unavailable,
            .retryable = true,
        } };
        return .{ .catalog = try testCatalog(alloc, self.model_id) };
    }

    fn provider(self: *GatedCatalog) model_catalog.Provider {
        return .{ .context = self, .fetch_fn = fetch, .refresh_interval_ms = self.refresh_interval_ms };
    }
};

test "model cache serves the cached catalog while it revalidates and adopts the refresh at the next poll" {
    const public: credentials.CatalogAccess = .{ .public_only = .no_credential };
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    var source = GatedCatalog{};
    runtime.startWarmup(source.provider(), public, .activity);
    try waitForWarmup(&runtime);

    source.model_id = "second";
    source.open.store(false, .seq_cst);
    runtime.last_attempt_ms -= 60_000;
    runtime.startWarmup(source.provider(), public, .activity);
    try std.testing.expect(fetchInFlight(&runtime));

    // Readers keep answering from the cached catalog without waiting.
    try std.testing.expect(!runtime.isLoading());
    var completions: [1][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), runtime.modelCompletions("", &completions));
    try std.testing.expectEqualStrings("first", completions[0]);
    var cancel_flag = std.atomic.Value(bool).init(false);
    _ = try runtime.resolveForRequest("first", &cancel_flag);

    // Another trigger joins the running fetch instead of starting one.
    runtime.last_attempt_ms -= picker_revalidate_floor_ms;
    runtime.startWarmup(source.provider(), public, .picker_open);
    source.open.store(true, .seq_cst);
    try waitForFetchToSettle(&runtime);
    try std.testing.expectEqual(@as(usize, 2), source.calls.load(.seq_cst));

    // Ids borrowed before the fetch finished stay valid until the owner polls.
    try std.testing.expectEqualStrings("first", completions[0]);
    try std.testing.expectEqualStrings("first", runtime.catalogModelCompletion("first").?);
    try std.testing.expect(try runtime.pollLoadTransition());
    try std.testing.expectEqualStrings("second", runtime.catalogModelCompletion("second").?);
    try std.testing.expect(runtime.catalogModelCompletion("first") == null);
}

test "model cache keeps the cached catalog when a revalidation fails" {
    const public: credentials.CatalogAccess = .{ .public_only = .no_credential };
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    var source = GatedCatalog{};
    runtime.startWarmup(source.provider(), public, .activity);
    try waitForWarmup(&runtime);

    source.fail = true;
    runtime.last_attempt_ms -= 60_000;
    runtime.startWarmup(source.provider(), public, .activity);
    try waitForWarmup(&runtime);

    try std.testing.expectEqual(@as(usize, 2), source.calls.load(.seq_cst));
    try std.testing.expectEqualStrings("first", runtime.catalogModelCompletion("first").?);
    try std.testing.expectEqual(model_catalog.FailureCategory.gateway_unavailable, runtime.outcome.last_failure.?.failure.category);
    try runtime.openMenu();
    try std.testing.expectEqual(ModelMenuLoadState.ready, runtime.menu.load_state);
    try std.testing.expectEqual(@as(usize, 1), runtime.menu.items.items.len);
    try std.testing.expect(runtime.menu.catalog_state.failure.?.retryable);
}

test "model picker revalidates past the reopen floor while activity waits for the refresh interval" {
    const public: credentials.CatalogAccess = .{ .public_only = .no_credential };
    for ([_]?i64{ 60_000, null }) |interval| {
        var runtime = Runtime.init(std.testing.allocator, "/v1/models");
        defer runtime.deinit();
        var source = GatedCatalog{ .refresh_interval_ms = interval };
        runtime.startWarmup(source.provider(), public, .activity);
        try waitForWarmup(&runtime);

        runtime.startWarmup(source.provider(), public, .activity);
        runtime.startWarmup(source.provider(), public, .picker_open);
        try std.testing.expect(!fetchInFlight(&runtime));
        try std.testing.expectEqual(@as(usize, 1), source.calls.load(.seq_cst));

        runtime.last_attempt_ms -= picker_revalidate_floor_ms;
        runtime.startWarmup(source.provider(), public, .activity);
        try std.testing.expect(!fetchInFlight(&runtime));
        runtime.startWarmup(source.provider(), public, .picker_open);
        try waitForWarmup(&runtime);
        try std.testing.expectEqual(@as(usize, 2), source.calls.load(.seq_cst));
    }
}

test "model cache retries a failed catalog behind the failed state so requests wait on it only briefly" {
    const public: credentials.CatalogAccess = .{ .public_only = .no_credential };
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    var source = GatedCatalog{ .fail = true };
    runtime.startWarmup(source.provider(), public, .activity);
    try waitForFetchToSettle(&runtime);
    _ = try runtime.pollLoadTransition();
    try std.testing.expect(runtime.isFailed());

    source.fail = false;
    source.open.store(false, .seq_cst);
    runtime.retry_not_before_ms = model_catalog.clockMs();
    runtime.startWarmup(source.provider(), public, .activity);
    try std.testing.expect(fetchInFlight(&runtime));
    try std.testing.expect(runtime.isFailed());
    try std.testing.expect(!runtime.isLoading());

    // A set cancel flag fails any wait at once, so the error proves the
    // request waits on the retry.
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, runtime.resolveForRequest("first", &cancelled));
    // A retry that has not landed holds a request only for the bound.
    var live = std.atomic.Value(bool).init(false);
    const started_ms = model_catalog.clockMs();
    const unresolved = try runtime.resolveForRequest("first", &live);
    try std.testing.expect(model_catalog.clockMs() - started_ms >= failed_catalog_retry_wait_ms);
    try std.testing.expectEqual(@as(?u32, null), unresolved.max_output_tokens);
    try std.testing.expect(fetchInFlight(&runtime));
    try runtime.openMenu();
    try std.testing.expectEqual(ModelMenuLoadState.loading, runtime.menu.load_state);

    source.open.store(true, .seq_cst);
    try waitForFetchToSettle(&runtime);
    try std.testing.expect(try runtime.pollLoadTransition());
    try std.testing.expectEqual(ModelMenuLoadState.ready, runtime.menu.load_state);
    try std.testing.expectEqualStrings("first", runtime.catalogModelCompletion("first").?);
    try std.testing.expectEqual(@as(u32, 0), runtime.failure_streak);
}

test "model catalog failures back off every trigger until a success or access change" {
    try std.testing.expectEqual(@as(i64, 5_000), failureBackoffMs(1));
    try std.testing.expectEqual(@as(i64, 10_000), failureBackoffMs(2));
    try std.testing.expectEqual(@as(i64, 160_000), failureBackoffMs(6));
    try std.testing.expectEqual(failure_backoff_cap_ms, failureBackoffMs(7));
    try std.testing.expectEqual(failure_backoff_cap_ms, failureBackoffMs(std.math.maxInt(u32)));

    const public: credentials.CatalogAccess = .{ .public_only = .no_credential };
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    var source = GatedCatalog{ .fail = true };
    runtime.startWarmup(source.provider(), public, .activity);
    try waitForFetchToSettle(&runtime);
    try std.testing.expectEqual(@as(u32, 1), runtime.failure_streak);

    // Neither activity nor the picker fetches during the backoff.
    runtime.last_attempt_ms -= picker_revalidate_floor_ms;
    runtime.startWarmup(source.provider(), public, .activity);
    runtime.startWarmup(source.provider(), public, .picker_open);
    try std.testing.expectEqual(@as(usize, 1), source.calls.load(.seq_cst));

    runtime.retry_not_before_ms = model_catalog.clockMs();
    const before_second_failure = model_catalog.clockMs();
    runtime.startWarmup(source.provider(), public, .picker_open);
    try waitForFetchToSettle(&runtime);
    try std.testing.expectEqual(@as(usize, 2), source.calls.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 2), runtime.failure_streak);
    try std.testing.expect(runtime.retry_not_before_ms >= before_second_failure + failureBackoffMs(2));

    // An access change starts over with an immediate load.
    runtime.reset();
    try std.testing.expectEqual(@as(u32, 0), runtime.failure_streak);
    runtime.startWarmup(source.provider(), public, .activity);
    try waitForFetchToSettle(&runtime);
    try std.testing.expectEqual(@as(usize, 3), source.calls.load(.seq_cst));

    // A success clears the backoff.
    source.fail = false;
    runtime.retry_not_before_ms = model_catalog.clockMs();
    runtime.startWarmup(source.provider(), public, .activity);
    try waitForWarmup(&runtime);
    try std.testing.expectEqual(@as(usize, 4), source.calls.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 0), runtime.failure_streak);
    try std.testing.expectEqual(@as(i64, 0), runtime.retry_not_before_ms);
}

test "model cache reloads a public catalog whose public reason changes while a refresh runs" {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    var source = GatedCatalog{};
    runtime.startWarmup(source.provider(), .{ .public_only = .fx_login_refresh_required }, .activity);
    try waitForWarmup(&runtime);

    source.open.store(false, .seq_cst);
    runtime.last_attempt_ms -= picker_revalidate_floor_ms;
    runtime.startWarmup(source.provider(), .{ .public_only = .fx_login_refresh_required }, .picker_open);
    try std.testing.expect(fetchInFlight(&runtime));

    // The refresh started under the old reason must not land over the new one.
    runtime.startWarmup(source.provider(), credentials.catalogAccessAfterRefreshFailure(.fx_login), .activity);
    source.open.store(true, .seq_cst);
    try waitForWarmup(&runtime);
    try std.testing.expectEqual(@as(usize, 3), source.calls.load(.seq_cst));
    try std.testing.expectEqual(
        credentials.CatalogPublicOnlyReason.credential_refresh_failed,
        runtime.outcome.loaded.?.access.public_only_reason.?,
    );
}

test "open model menu keeps its provider tab and selection when a revalidated catalog lands" {
    const alloc = std.testing.allocator;
    const access = model_catalog.AccessMetadata.init(.{ .public_only = .no_credential });
    var runtime = Runtime.init(alloc, "/v1/models");
    defer runtime.deinit();
    runtime.catalog = try testCatalogIds(alloc, &.{ "openai/a", "openai/b", "anthropic/c" });
    runtime.outcome = .{ .loaded = .{ .access = access } };
    runtime.state = .ready;
    try runtime.openMenu();
    runtime.menu.provider_index = @backingInt(ModelProviderFilter.openai);
    runtime.menu.selected_index = 1;
    try std.testing.expectEqualStrings("openai/b", runtime.menu.itemAt(runtime.menu.selected_index).?.id);

    runtime.staged = .{ .loaded = .{
        .catalog = try testCatalogIds(alloc, &.{ "xai/new", "openai/new", "openai/a", "openai/b", "anthropic/c" }),
        .provenance = .{ .access = access },
    } };
    runtime.completion_pending = true;
    try std.testing.expect(try runtime.pollLoadTransition());
    try std.testing.expectEqual(ModelProviderFilter.openai, runtime.menu.providerFilter());
    try std.testing.expectEqual(@as(usize, 2), runtime.menu.selected_index);
    try std.testing.expectEqualStrings("openai/b", runtime.menu.itemAt(runtime.menu.selected_index).?.id);
    try std.testing.expectEqual(@as(usize, 1), runtime.menu.window_start);

    // A removed selection and provider fall back to the same position in All.
    runtime.staged = .{ .loaded = .{
        .catalog = try testCatalogIds(alloc, &.{ "xai/new", "anthropic/c" }),
        .provenance = .{ .access = access },
    } };
    runtime.completion_pending = true;
    try std.testing.expect(try runtime.pollLoadTransition());
    try std.testing.expectEqual(ModelProviderFilter.all, runtime.menu.providerFilter());
    try std.testing.expectEqualStrings("anthropic/c", runtime.menu.itemAt(runtime.menu.selected_index).?.id);
    try std.testing.expectEqual(@as(usize, 0), runtime.menu.window_start);
}

test "model cache projects anonymous fallback provenance for 401 and 403" {
    for ([_]std.http.Status{ .unauthorized, .forbidden }) |status| {
        var runtime = Runtime.init(std.testing.allocator, "/v1/models");
        defer runtime.deinit();
        var provider = RefreshCatalog{
            .first_failure = .{ .category = .authentication, .http_status = status },
            .fallback_model = "public/fallback",
        };

        runtime.startWarmup(provider.provider(), authenticatedCatalogAccess("rejected-key", "team_123"), .activity);
        try waitForWarmup(&runtime);

        const provenance = runtime.outcome.loaded.?;
        try std.testing.expectEqual(model_catalog.AccessLevel.public_only, provenance.access.level);
        try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, provenance.access.source.?);
        try std.testing.expectEqual(credentials.CatalogPublicOnlyReason.authenticated_credential_rejected, provenance.access.public_only_reason.?);
        try std.testing.expect(provenance.access.private_models_may_be_hidden);
        try std.testing.expect(provenance.anonymous_fallback_used);
        try std.testing.expectEqual(model_catalog.FailureCategory.authentication, provenance.fallback_failure.?.category);
        try std.testing.expectEqual(status, provenance.fallback_failure.?.http_status.?);
        try std.testing.expect(runtime.outcome.last_failure == null);

        try runtime.openMenu();
        try std.testing.expectEqual(model_catalog.AccessLevel.public_only, runtime.menu.catalog_state.access_level.?);
        try std.testing.expectEqual(credentials.CatalogPublicOnlyReason.authenticated_credential_rejected, runtime.menu.catalog_state.public_only_reason.?);
        try std.testing.expect(runtime.menu.catalog_state.private_models_hidden);
        try std.testing.expectEqual(model_catalog.FailureCategory.authentication, runtime.menu.catalog_state.failure.?.category);
        try std.testing.expect(!runtime.menu.catalog_state.failure.?.retryable);

        runtime.startWarmup(provider.provider(), authenticatedCatalogAccess("rejected-key", "team_123"), .activity);
        try std.testing.expectEqual(@as(usize, 2), provider.calls);
    }
}

test "model cache catalog auth refresh preserves the last public catalog" {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    runtime.catalog = try testCatalog(std.testing.allocator, "public/original");
    runtime.outcome.loaded = .{
        .access = .init(.{ .public_only = .no_credential }),
    };
    runtime.state = .ready;
    runtime.reset();

    var refresh_provider = RefreshCatalog{ .first_failure = .{
        .category = .authentication,
        .http_status = .forbidden,
    } };
    runtime.startWarmup(refresh_provider.provider(), authenticatedCatalogAccess("rejected-key", "team_123"), .activity);
    try waitForWarmup(&runtime);

    try std.testing.expectEqual(@as(usize, 2), refresh_provider.calls);
    try std.testing.expectEqual(model_catalog.FailureCategory.authentication, runtime.outcome.last_failure.?.failure.category);
    try std.testing.expectEqual(std.http.Status.forbidden, runtime.outcome.last_failure.?.failure.http_status.?);
    try std.testing.expect(runtime.outcome.last_failure.?.anonymous_fallback_used);
    try runtime.openMenu();
    try std.testing.expectEqual(
        credentials.CatalogPublicOnlyReason.authenticated_credential_rejected,
        runtime.menu.catalog_state.public_only_reason.?,
    );
    runtime.closeMenu();
    runtime.reset();
    var failed_provider = RefreshCatalog{ .first_failure = .{
        .category = .transport,
        .retryable = true,
    } };
    runtime.startWarmup(failed_provider.provider(), authenticatedCatalogAccess("test-key", "team_123"), .activity);
    try waitForWarmup(&runtime);
    try std.testing.expectEqual(@as(usize, 1), failed_provider.calls);
    try std.testing.expectEqual(model_catalog.AccessLevel.public_only, runtime.outcome.loaded.?.access.level);
    try std.testing.expect(runtime.outcome.loaded.?.access.source == null);
    try std.testing.expectEqual(credentials.CatalogPublicOnlyReason.no_credential, runtime.outcome.loaded.?.access.public_only_reason.?);
    try std.testing.expect(runtime.outcome.loaded.?.access.private_models_may_be_hidden);
    try std.testing.expectEqual(model_catalog.FailureCategory.transport, runtime.outcome.last_failure.?.failure.category);
    try std.testing.expect(runtime.outcome.last_failure.?.failure.retryable);
    try runtime.openMenu();
    try std.testing.expectEqual(credentials.CatalogPublicOnlyReason.no_credential, runtime.menu.catalog_state.public_only_reason.?);
    try std.testing.expectEqual(model_catalog.FailureCategory.transport, runtime.menu.catalog_state.failure.?.category);
    try std.testing.expect(runtime.menu.catalog_state.failure.?.retryable);
    runtime.closeMenu();
    // The retained catalog retries once the failure backoff runs out.
    runtime.startWarmup(failed_provider.provider(), authenticatedCatalogAccess("test-key", "team_123"), .activity);
    try std.testing.expectEqual(@as(usize, 1), failed_provider.calls);
    runtime.retry_not_before_ms = model_catalog.clockMs();
    runtime.startWarmup(failed_provider.provider(), authenticatedCatalogAccess("test-key", "team_123"), .activity);
    try waitForWarmup(&runtime);
    try std.testing.expectEqual(@as(usize, 2), failed_provider.calls);
    try std.testing.expect(runtime.outcome.last_failure == null);
    var snapshot = (try runtime.snapshotCachedModelIds(std.testing.allocator)).?;
    defer collections.freeStringList(std.testing.allocator, &snapshot);
    try std.testing.expectEqualStrings("public/original", snapshot.items[0]);
}

test "model cache refetches effective access across auth and team changes" {
    const public_access: credentials.CatalogAccess = .{ .public_only = .no_credential };
    const team_a_access = authenticatedCatalogAccess("team-key", "team_a");
    const team_b_access = authenticatedCatalogAccess("team-key", "team_b");
    const fx_login_access = credentials.catalogAccessForCredential(.fx_login, "login-token", "ignored-team");
    const cases = [_]struct { access: credentials.CatalogAccess, model_id: []const u8 }{
        .{ .access = public_access, .model_id = "public/original" },
        .{ .access = team_a_access, .model_id = "private/team-a" },
        .{ .access = team_b_access, .model_id = "private/team-b" },
        .{ .access = fx_login_access, .model_id = "public/login" },
    };

    var provider = AuthChangeCatalog{};
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();

    for (cases, 0..) |case, index| {
        if (index > 0) runtime.reset();
        provider.model_id = case.model_id;
        runtime.startWarmup(provider.provider(), case.access, .activity);
        try waitForWarmup(&runtime);

        const expected_access = model_catalog.AccessMetadata.init(case.access);
        try std.testing.expectEqual(expected_access.level, runtime.outcome.loaded.?.access.level);
        try std.testing.expectEqual(expected_access.public_only_reason, runtime.outcome.loaded.?.access.public_only_reason);
        try std.testing.expectEqualStrings(case.access.teamContext() orelse "", provider.team[0..provider.team_len]);
        var snapshot = (try runtime.snapshotCachedModelIds(std.testing.allocator)).?;
        defer collections.freeStringList(std.testing.allocator, &snapshot);
        try std.testing.expectEqualStrings(case.model_id, snapshot.items[0]);

        // Refresh reads the credential owned by the cache, not an external copy.
        try std.testing.expect(runtime.refresh(.gateway, .force));
        try waitForWarmup(&runtime);
        try std.testing.expectEqualStrings(case.access.teamContext() orelse "", provider.team[0..provider.team_len]);
    }

    try std.testing.expectEqual(@as(usize, cases.len * 2), provider.calls);
}

test "model cache reloads a ready authenticated catalog after fx login access downgrades" {
    const cases = [_]struct {
        access: credentials.CatalogAccess,
        reason: credentials.CatalogPublicOnlyReason,
    }{
        .{
            .access = .{ .public_only = .fx_login_refresh_required },
            .reason = .fx_login_refresh_required,
        },
        .{
            .access = credentials.catalogAccessAfterRefreshFailure(.fx_login),
            .reason = .credential_refresh_failed,
        },
    };

    for (cases) |case| {
        var runtime = Runtime.init(std.testing.allocator, "/v1/models");
        defer runtime.deinit();
        var private_provider = AuthChangeCatalog{ .model_id = "private/team-model" };
        runtime.startWarmup(
            private_provider.provider(),
            credentials.catalogAccessForCredential(.fx_login, "login-token", "team_123"),
            .activity,
        );
        try waitForWarmup(&runtime);

        var public_provider = AuthChangeCatalog{ .model_id = "public/base-model" };
        runtime.startWarmup(public_provider.provider(), case.access, .activity);
        try waitForWarmup(&runtime);

        try std.testing.expectEqual(@as(usize, 1), public_provider.calls);
        try std.testing.expect(!public_provider.credential_present);
        try std.testing.expectEqual(@as(usize, 0), public_provider.team_len);
        try std.testing.expectEqual(case.reason, runtime.outcome.loaded.?.access.public_only_reason.?);
        try std.testing.expect(runtime.catalogModelCompletion("private/team-model") == null);
        try std.testing.expectEqualStrings("public/base-model", runtime.catalogModelCompletion("public/base-model").?);
    }
}

test "model cache reuses a ready public catalog when only its public reason changes" {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    var initial_provider = AuthChangeCatalog{ .model_id = "public/base-model" };
    runtime.startWarmup(initial_provider.provider(), .{ .public_only = .fx_login_refresh_required }, .activity);
    try waitForWarmup(&runtime);

    var unused_provider = AuthChangeCatalog{ .model_id = "public/redundant-model" };
    runtime.startWarmup(
        unused_provider.provider(),
        credentials.catalogAccessAfterRefreshFailure(.fx_login),
        .activity,
    );

    try std.testing.expectEqual(@as(usize, 0), unused_provider.calls);
    try std.testing.expectEqual(
        credentials.CatalogPublicOnlyReason.credential_refresh_failed,
        runtime.outcome.loaded.?.access.public_only_reason.?,
    );
    try std.testing.expectEqualStrings("public/base-model", runtime.catalogModelCompletion("public/base-model").?);
    try std.testing.expect(runtime.catalogModelCompletion("public/redundant-model") == null);
}

test "model cache auth change prevents a stale load from replacing the newer catalog" {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    var stale = StaleCatalog{};
    runtime.startWarmup(stale.provider(), .{ .public_only = .no_credential }, .activity);

    var remaining_ms: u64 = 5000;
    while (!stale.started.load(.seq_cst) and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(stale.started.load(.seq_cst));

    runtime.reset();
    try std.testing.expect(stale.observed_cancel.load(.seq_cst));

    var current = RefreshCatalog{ .fallback_model = "private/current" };
    runtime.startWarmup(current.provider(), authenticatedCatalogAccess("current-key", "team_current"), .activity);
    try waitForWarmup(&runtime);

    try std.testing.expectEqual(model_catalog.AccessLevel.authenticated, runtime.outcome.loaded.?.access.level);
    var snapshot = (try runtime.snapshotCachedModelIds(std.testing.allocator)).?;
    defer collections.freeStringList(std.testing.allocator, &snapshot);
    try std.testing.expectEqualStrings("private/current", snapshot.items[0]);
}

test "model cache access copies clean up every induced allocation failure" {
    const access = authenticatedCatalogAccess("copied-secret", "copied-team");
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            testing_allocator.no_resize,
            .{ .fail_index = fail_index },
        );

        try std.testing.expectError(
            error.OutOfMemory,
            OwnedCatalogAccess.init(failing.allocator(), access),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "model cache access owns Grok account identity with its credential" {
    const access = credentials.catalogAccessForCredentialAndAccount(
        .grok_subscription,
        "copied-secret",
        null,
        "acct_grok",
    );
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            testing_allocator.no_resize,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            OwnedCatalogAccess.init(failing.allocator(), access),
        );
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }

    var owned = try OwnedCatalogAccess.init(std.testing.allocator, access);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("acct_grok", owned.access.accountId().?);
}

fn runRepeatedAuthChangeCycle(iteration: usize) !void {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();

    var stale = StaleCatalog{};
    runtime.startWarmup(stale.provider(), .{ .public_only = .no_credential }, .activity);
    var remaining_ms: u64 = 5000;
    while (!stale.started.load(.seq_cst) and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(stale.started.load(.seq_cst));

    runtime.reset();
    try std.testing.expect(stale.observed_cancel.load(.seq_cst));

    const model_id = if (iteration % 2 == 0) "private/repeated-a" else "private/repeated-b";
    const team = if (iteration % 2 == 0) "team_a" else "team_b";
    var current = RefreshCatalog{ .fallback_model = model_id };
    runtime.startWarmup(current.provider(), authenticatedCatalogAccess("current-key", team), .activity);
    try waitForWarmup(&runtime);

    try std.testing.expectEqual(@as(usize, 1), current.calls);
    try std.testing.expectEqual(model_catalog.AccessLevel.authenticated, runtime.outcome.loaded.?.access.level);
    var snapshot = (try runtime.snapshotCachedModelIds(std.testing.allocator)).?;
    defer collections.freeStringList(std.testing.allocator, &snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try std.testing.expectEqualStrings(model_id, snapshot.items[0]);
}

test "model cache repeated auth changes join stale loads before publication" {
    for (0..128) |iteration| try runRepeatedAuthChangeCycle(iteration);
}

test "model cache warmup publishes a snapshot and filtered completion" {
    var fixture = try test_gateway_client.TestModelCatalogFixture.initPrivate();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const models_url = try std.testing.allocator.print(
        "http://127.0.0.1:{d}/v1/models",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(models_url);
    const env = try TestEnv.install(std.testing.allocator, models_url);
    defer env.deinit();

    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    runtime.startWarmup(test_builtin_gateway.model_catalog_provider, authenticatedCatalogAccess("test-key", "team_123"), .activity);
    try waitForWarmup(&runtime);

    const provenance = runtime.outcome.loaded.?;
    try std.testing.expectEqual(model_catalog.AccessLevel.authenticated, provenance.access.level);
    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, provenance.access.source.?);
    try std.testing.expect(!provenance.access.private_models_may_be_hidden);
    try std.testing.expect(!provenance.anonymous_fallback_used);
    try std.testing.expect(provenance.fallback_failure == null);
    try std.testing.expect(runtime.outcome.last_failure == null);

    var snapshot = (try runtime.snapshotCachedModelIds(std.testing.allocator)).?;
    defer collections.freeStringList(std.testing.allocator, &snapshot);
    try std.testing.expectEqual(@as(usize, 4), snapshot.items.len);
    try std.testing.expectEqualStrings("openai/gpt-5", snapshot.items[0]);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4", snapshot.items[1]);
    try std.testing.expect(modelIdListContains(snapshot.items, "anthropic/claude-sonnet-4"));
    try std.testing.expect(modelIdListContains(snapshot.items, "private/blue-hornbill"));

    const metadata = runtime.metadataForModel("openai/gpt-5").?;
    try std.testing.expect(metadata.supports_tool_use);
    try std.testing.expect(metadata.supports_reasoning);
    try std.testing.expect(metadata.supports_vision);
    try std.testing.expect(metadata.supports_file_input);
    try std.testing.expect(metadata.supports_web_search);
    try std.testing.expect(metadata.supports_explicit_caching);
    try std.testing.expect(metadata.supports_implicit_caching);
    try std.testing.expectEqual(@as(?u32, 256_000), metadata.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), metadata.max_output_tokens);

    var completions: [2][]const u8 = undefined;
    const count = runtime.modelCompletions("OPUS", completions[0..]);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4", completions[0]);

    var private_completions: [1][]const u8 = undefined;
    const private_count = runtime.modelCompletions("blue", private_completions[0..]);
    try std.testing.expectEqual(@as(usize, 1), private_count);
    try std.testing.expectEqualStrings("private/blue-hornbill", private_completions[0]);
    try std.testing.expectEqualStrings("private/blue-hornbill", runtime.catalogModelCompletion("private/blue-hornbill").?);
    try std.testing.expect(runtime.catalogModelCompletion("private/blue") == null);

    try std.testing.expectEqualStrings("team_123", fixture.capturedHeaderValue(test_gateway_client.vercel_ai_gateway_team_header).?);
    if (fixture.failure()) |err| return err;
}

test "model menu owns resolved catalog state and filters without changing catalog order" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, "/v1/models");
    defer runtime.deinit();

    const entries = [_]model_catalog.ModelCatalogEntry{
        .{
            .id = @constCast("openai/gpt-5"),
            .model_type = @constCast("language"),
            .has_reasoning = true,
            .has_tool_use = true,
            .has_vision = true,
            .context_window = 256_000,
            .max_tokens = 32_000,
        },
        .{
            .id = @constCast("anthropic/claude-opus-4.8"),
            .model_type = @constCast("language"),
            .has_tool_use = true,
            .has_file_input = true,
            .has_web_search = true,
            .supports_fast_mode = true,
            .supports_ultrafast_mode = true,
        },
        .{
            .id = @constCast("private/blue-hornbill"),
            .model_type = @constCast("language"),
        },
        .{
            .id = @constCast("standalone"),
            .model_type = @constCast("language"),
        },
    };
    runtime.state = .ready;
    try hydrateMenuSnapshot(alloc, &runtime.menu, &entries);
    runtime.menu.active = true;

    try std.testing.expectEqual(ModelMenuLoadState.ready, runtime.menu.load_state);
    try std.testing.expectEqual(@as(usize, 4), runtime.menu.filteredItemCount());
    try std.testing.expectEqualStrings("openai/gpt-5", runtime.menu.itemAt(0).?.id);
    try std.testing.expectEqualStrings("private/blue-hornbill", runtime.menu.itemAt(2).?.id);
    try std.testing.expect(runtime.menu.itemAt(0).?.capabilities.supports_reasoning);
    try std.testing.expect(runtime.menu.itemAt(0).?.capabilities.supports_vision);
    try std.testing.expectEqual(@as(?u32, 256_000), runtime.menu.itemAt(0).?.capabilities.context_window);
    try std.testing.expect(runtime.menu.itemAt(1).?.capabilities.supports_fast_mode);
    try std.testing.expect(runtime.menu.itemAt(1).?.capabilities.supports_ultrafast_mode);
    try std.testing.expect(runtime.menu.itemAt(1).?.capabilities.supports_file_input);
    try std.testing.expect(runtime.menu.itemAt(1).?.capabilities.supports_web_search);

    runtime.menu.setQuery("BLUE");
    try std.testing.expectEqual(@as(usize, 1), runtime.menu.filteredItemCount());
    try std.testing.expectEqualStrings("private/blue-hornbill", runtime.menu.itemAt(0).?.id);

    runtime.menu.setQuery("");
    try std.testing.expect(runtime.menu.moveProvider(1));
    try std.testing.expectEqual(ModelProviderFilter.anthropic, runtime.menu.providerFilter());
    try std.testing.expectEqual(@as(usize, 1), runtime.menu.filteredItemCount());
    try std.testing.expect(runtime.menu.moveProvider(-1));
    try std.testing.expectEqual(ModelProviderFilter.all, runtime.menu.providerFilter());

    runtime.menu.provider_index = @backingInt(ModelProviderFilter.others);
    try std.testing.expectEqual(@as(usize, 2), runtime.menu.filteredItemCount());
    try std.testing.expectEqualStrings("private/blue-hornbill", runtime.menu.itemAt(0).?.id);
    try std.testing.expectEqualStrings("standalone", runtime.menu.itemAt(1).?.id);
    runtime.menu.provider_index = @backingInt(ModelProviderFilter.all);

    try std.testing.expect(runtime.menu.moveVisibleItems(-1, 2));
    try std.testing.expectEqual(@as(usize, 3), runtime.menu.selected_index);
    try std.testing.expectEqual(@as(usize, 2), runtime.menu.window_start);
    const selected = (try runtime.menu.selectedModelAlloc(alloc)).?;
    defer alloc.free(selected);
    try std.testing.expectEqualStrings("standalone", selected);
}

test "model menu ranks fuzzy matches below verbatim ones and keeps the selection" {
    const alloc = std.testing.allocator;
    const entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("openai/gpt-4.5-preview"), .model_type = @constCast("language") },
        .{ .id = @constCast("openai/gpt-5"), .model_type = @constCast("language") },
        .{ .id = @constCast("anthropic/claude-opus-4.8"), .model_type = @constCast("language") },
        .{ .id = @constCast("acme/gpt5-lite"), .model_type = @constCast("language") },
    };
    var menu: ModelMenu = .{};
    defer menu.deinit(alloc);
    try hydrateMenuSnapshot(alloc, &menu, &entries);
    menu.active = true;

    menu.setQuery("gpt5");
    try std.testing.expectEqual(@as(usize, 3), menu.filteredItemCount());
    try std.testing.expectEqualStrings("acme/gpt5-lite", menu.itemAt(0).?.id);
    try std.testing.expectEqualStrings("openai/gpt-5", menu.itemAt(1).?.id);
    try std.testing.expectEqualStrings("openai/gpt-4.5-preview", menu.itemAt(2).?.id);
    try std.testing.expect(menu.itemAt(3) == null);

    menu.provider_index = @backingInt(ModelProviderFilter.openai);
    try std.testing.expectEqual(@as(usize, 2), menu.filteredItemCount());
    try std.testing.expectEqualStrings("openai/gpt-5", menu.itemAt(0).?.id);
    try std.testing.expectEqualStrings("openai/gpt-4.5-preview", menu.itemAt(1).?.id);
    menu.provider_index = @backingInt(ModelProviderFilter.all);

    try std.testing.expect(menu.moveVisibleItems(1, 3));
    try std.testing.expectEqualStrings("openai/gpt-5", menu.itemAt(menu.selected_index).?.id);

    // A revalidated catalog that adds a better match keeps the cursor on the
    // same model even though its row moves down.
    const revalidated = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("acme/gpt5-pro"), .model_type = @constCast("language") },
    } ++ entries;
    try hydrateMenuSnapshot(alloc, &menu, &revalidated);
    try std.testing.expectEqual(@as(usize, 2), menu.selected_index);
    try std.testing.expectEqualStrings("openai/gpt-5", menu.itemAt(menu.selected_index).?.id);
}

test "a model's own name ranks it above longer ids that contain it" {
    const alloc = std.testing.allocator;
    const entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("openai/gpt-4o-mini"), .model_type = @constCast("language") },
        .{ .id = @constCast("azure/gpt-4o-mini-tts"), .model_type = @constCast("language") },
        .{ .id = @constCast("openai/gpt-4o"), .model_type = @constCast("language") },
        .{ .id = @constCast("standalone"), .model_type = @constCast("language") },
    };
    var menu: ModelMenu = .{};
    defer menu.deinit(alloc);
    try hydrateMenuSnapshot(alloc, &menu, &entries);
    menu.active = true;

    menu.setQuery("GPT-4o");
    try std.testing.expectEqual(@as(usize, 3), menu.filteredItemCount());
    try std.testing.expectEqualStrings("openai/gpt-4o", menu.itemAt(0).?.id);
    try std.testing.expectEqualStrings("openai/gpt-4o-mini", menu.itemAt(1).?.id);
    try std.testing.expectEqualStrings("azure/gpt-4o-mini-tts", menu.itemAt(2).?.id);

    menu.setQuery("stand");
    try std.testing.expectEqualStrings("standalone", menu.itemAt(0).?.id);
    try std.testing.expectEqual(@as(?fuzzy_match.Match, .{ .tier = .prefix, .field = 0 }), modelIdMatch("stand", "standalone"));
    try std.testing.expectEqual(@as(?fuzzy_match.Match, .{ .tier = .exact, .field = 1 }), modelIdMatch("gpt-4o", "openai/gpt-4o"));
    try std.testing.expectEqual(@as(?fuzzy_match.Match, .{ .tier = .substring, .field = 0 }), modelIdMatch("ai/gpt", "openai/gpt-4o"));
}

test "model completions rank fuzzy matches below verbatim ones" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, "/v1/models");
    defer runtime.deinit();
    for ([_][]const u8{
        "openai/gpt-4.5-preview",
        "openai/gpt-5",
        "anthropic/claude-opus-4.8",
        "acme/gpt5-lite",
    }) |model| {
        const id = try alloc.dupe(u8, model);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try runtime.catalog.append(alloc, .{ .id = id, .model_type = model_type });
    }
    runtime.state = .ready;

    var completions: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), runtime.modelCompletions("gpt5", &completions));
    try std.testing.expectEqualStrings("acme/gpt5-lite", completions[0]);
    try std.testing.expectEqualStrings("openai/gpt-5", completions[1]);
    try std.testing.expectEqualStrings("openai/gpt-4.5-preview", completions[2]);

    try std.testing.expectEqual(@as(usize, 2), runtime.modelCompletions("gpt5", completions[0..2]));
    try std.testing.expectEqualStrings("openai/gpt-5", completions[1]);

    try std.testing.expectEqual(@as(usize, 1), runtime.modelCompletions("anthropic opus", &completions));
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.8", completions[0]);
    try std.testing.expectEqual(@as(usize, 4), runtime.modelCompletions("", &completions));
    try std.testing.expectEqualStrings("openai/gpt-4.5-preview", completions[0]);
}

test "model menu provider navigation skips absent and redundant filters" {
    const alloc = std.testing.allocator;
    const mixed_entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("openai/gpt-5"), .model_type = @constCast("language") },
        .{ .id = @constCast("xai/grok-4"), .model_type = @constCast("language") },
    };
    var mixed: ModelMenu = .{};
    defer mixed.deinit(alloc);
    try hydrateMenuSnapshot(alloc, &mixed, &mixed_entries);
    mixed.active = true;

    try std.testing.expect(mixed.moveProvider(1));
    try std.testing.expectEqual(ModelProviderFilter.openai, mixed.providerFilter());
    try std.testing.expect(mixed.moveProvider(1));
    try std.testing.expectEqual(ModelProviderFilter.xai, mixed.providerFilter());
    try std.testing.expect(mixed.moveProvider(1));
    try std.testing.expectEqual(ModelProviderFilter.all, mixed.providerFilter());

    const codex_entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("gpt-5.6-sol"), .model_type = @constCast("language") },
        .{ .id = @constCast("gpt-5.4-mini"), .model_type = @constCast("language") },
    };
    var codex: ModelMenu = .{};
    defer codex.deinit(alloc);
    try hydrateMenuSnapshot(alloc, &codex, &codex_entries);
    codex.active = true;

    try std.testing.expect(!codex.moveProvider(1));
    try std.testing.expectEqual(ModelProviderFilter.all, codex.providerFilter());
}

test "model menu snapshot construction cleans every allocation failure" {
    const backing = testing_allocator.no_resize;
    const entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("openai/gpt-5"), .model_type = @constCast("language") },
        .{ .id = @constCast("anthropic/claude-opus-4.8"), .model_type = @constCast("language") },
    };

    var probe = std.testing.FailingAllocator.init(backing, .{});
    var menu: ModelMenu = .{};
    try hydrateMenuSnapshot(probe.allocator(), &menu, &entries);
    menu.deinit(probe.allocator());
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var failed_menu: ModelMenu = .{};
        if (hydrateMenuSnapshot(failing.allocator(), &failed_menu, &entries)) {
            failed_menu.deinit(failing.allocator());
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "model cache completion hydrates an open menu and reports once" {
    var fixture = try test_gateway_client.TestModelCatalogFixture.initPrivate();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const models_url = try std.testing.allocator.print(
        "http://127.0.0.1:{d}/v1/models",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(models_url);
    const env = try TestEnv.install(std.testing.allocator, models_url);
    defer env.deinit();

    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    runtime.startWarmup(test_builtin_gateway.model_catalog_provider, authenticatedCatalogAccess("test-key", "team_123"), .activity);
    try runtime.openMenu();
    try std.testing.expectEqual(ModelMenuLoadState.loading, runtime.menu.load_state);

    var changed = false;
    var remaining_ms: u64 = 5000;
    while (!changed and remaining_ms > 0) : (remaining_ms -= 1) {
        changed = try runtime.pollLoadTransition();
        if (!changed) io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(changed);
    try std.testing.expectEqual(ModelMenuLoadState.ready, runtime.menu.load_state);
    try std.testing.expectEqual(model_catalog.AccessLevel.authenticated, runtime.menu.catalog_state.access_level.?);
    try std.testing.expect(runtime.menu.catalog_state.public_only_reason == null);
    try std.testing.expect(!runtime.menu.catalog_state.private_models_hidden);
    try std.testing.expect(runtime.menu.catalog_state.failure == null);
    try std.testing.expectEqual(@as(usize, 4), runtime.menu.items.items.len);
    try std.testing.expect(!(try runtime.pollLoadTransition()));

    runtime.reset();
    try std.testing.expect(!runtime.menu.active);
    try std.testing.expectEqual(ModelCacheState.idle, runtime.state);
    if (fixture.failure()) |err| return err;
}

test "provider changes discard public catalog fallback without changing ordinary reset" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, "/v1/models");
    defer runtime.deinit();
    {
        const id = try alloc.dupe(u8, "gateway-model");
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try runtime.catalog.append(alloc, .{ .id = id, .model_type = model_type });
    }
    runtime.outcome = .{ .loaded = .{
        .access = model_catalog.AccessMetadata.init(.{ .public_only = .no_credential }),
    } };
    runtime.state = .ready;

    runtime.reset();
    try std.testing.expectEqual(@as(usize, 1), runtime.catalog.items.len);
    try std.testing.expect(runtime.outcome.loaded != null);
    runtime.resetForProviderChange();
    try std.testing.expectEqual(@as(usize, 0), runtime.catalog.items.len);
    try std.testing.expect(runtime.outcome.loaded == null);
    try std.testing.expectEqual(ModelCacheState.idle, runtime.state);
}

test "model cache reset replaces ready public catalog with team catalog" {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();

    {
        var fixture = try test_gateway_client.TestModelCatalogFixture.init();
        defer fixture.deinit();
        try fixture.start();
        try std.testing.expect(fixture.waitForAcceptStart(5000));

        const models_url = try std.testing.allocator.print(
            "http://127.0.0.1:{d}/v1/models",
            .{fixture.port()},
        );
        defer std.testing.allocator.free(models_url);
        const env = try TestEnv.install(std.testing.allocator, models_url);
        defer env.deinit();

        runtime.startWarmup(test_builtin_gateway.model_catalog_provider, .{ .public_only = .no_credential }, .activity);
        try waitForWarmup(&runtime);

        var snapshot = (try runtime.snapshotCachedModelIds(std.testing.allocator)).?;
        defer collections.freeStringList(std.testing.allocator, &snapshot);
        try std.testing.expect(!modelIdListContains(snapshot.items, "private/blue-hornbill"));
        try std.testing.expect(fixture.capturedHeaderValue("authorization") == null);
        try std.testing.expect(fixture.capturedHeaderValue(test_gateway_client.vercel_ai_gateway_team_header) == null);
        if (fixture.failure()) |err| return err;
    }

    runtime.reset();

    {
        var fixture = try test_gateway_client.TestModelCatalogFixture.initPrivate();
        defer fixture.deinit();
        try fixture.start();
        try std.testing.expect(fixture.waitForAcceptStart(5000));

        const models_url = try std.testing.allocator.print(
            "http://127.0.0.1:{d}/v1/models",
            .{fixture.port()},
        );
        defer std.testing.allocator.free(models_url);
        const env = try TestEnv.install(std.testing.allocator, models_url);
        defer env.deinit();

        runtime.startWarmup(test_builtin_gateway.model_catalog_provider, authenticatedCatalogAccess("team-key", "team_123"), .activity);
        try waitForWarmup(&runtime);

        var snapshot = (try runtime.snapshotCachedModelIds(std.testing.allocator)).?;
        defer collections.freeStringList(std.testing.allocator, &snapshot);
        try std.testing.expect(modelIdListContains(snapshot.items, "private/blue-hornbill"));
        try std.testing.expectEqualStrings("team_123", fixture.capturedHeaderValue(test_gateway_client.vercel_ai_gateway_team_header).?);
        if (fixture.failure()) |err| return err;
    }
}

test "model cache request resolution distinguishes readiness miss failure idle and cancellation" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, "/v1/models");
    defer runtime.deinit();

    {
        const id = try alloc.dupe(u8, "provider/new-reasoning-model");
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        try efforts.append(alloc, types.ReasoningEffort.literal("future-tier"));
        try runtime.catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_reasoning = true,
            .reasoning_efforts = efforts,
        });
    }
    runtime.state = .ready;

    var cancel_flag = std.atomic.Value(bool).init(false);
    const ready = try runtime.resolveForRequest("provider/new-reasoning-model", &cancel_flag);
    try std.testing.expect(model_capabilities.reasoningEffortSupported(ready, types.ReasoningEffort.literal("future-tier")));
    try std.testing.expect(!model_capabilities.reasoningEffortSupported(ready, types.ReasoningEffort.literal("max")));

    const missing = try runtime.resolveForRequest("zai/glm-5.2", &cancel_flag);
    try std.testing.expect(!missing.supports_fast_mode);
    try std.testing.expectEqual(@as(usize, 0), missing.reasoning_efforts.len);

    runtime.state = .idle;
    const idle = try runtime.resolveForRequest("zai/glm-5.2", &cancel_flag);
    try std.testing.expect(!idle.supports_fast_mode);
    try std.testing.expectEqual(@as(usize, 0), idle.reasoning_efforts.len);

    runtime.state = .failed;
    const failed = try runtime.resolveForRequest("zai/glm-5.2", &cancel_flag);
    try std.testing.expect(!failed.supports_fast_mode);

    const ReadyTransition = struct {
        fn run(cache: *Runtime) void {
            io_mod.sleep(5 * std.time.ns_per_ms);
            cache.mutex.lockUncancelable(io_mod.getIo());
            cache.state = .ready;
            cache.mutex.unlock(io_mod.getIo());
        }
    };
    runtime.state = .loading;
    const transition_thread = try std.Thread.spawn(.{}, ReadyTransition.run, .{&runtime});
    defer transition_thread.join();
    const warmed = try runtime.resolveForRequest("provider/new-reasoning-model", &cancel_flag);
    try std.testing.expect(model_capabilities.reasoningEffortSupported(warmed, types.ReasoningEffort.literal("future-tier")));

    runtime.state = .loading;
    cancel_flag.store(true, .seq_cst);
    try std.testing.expectError(
        error.Cancelled,
        runtime.resolveForRequest("provider/new-reasoning-model", &cancel_flag),
    );
    runtime.state = .ready;
}

test "model cache request resolution records lookup misses for the trace report" {
    const alloc = std.testing.allocator;
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    var runtime = Runtime.init(alloc, "/v1/models");
    defer runtime.deinit();
    runtime.state = .ready;

    var cancel_flag = std.atomic.Value(bool).init(false);
    _ = try runtime.resolveForRequest("zai/glm-5.2", &cancel_flag);
    _ = try runtime.resolveForRequest("zai/glm-5.2", &cancel_flag);

    runtime.state = .failed;
    _ = try runtime.resolveForRequest("zai/glm-5.2", &cancel_flag);
    runtime.state = .idle;
    _ = try runtime.resolveForRequest("zai/glm-5.2", &cancel_flag);

    var events: [diagnostics.model_catalog_ring_capacity]diagnostics.ModelCatalogEvent = undefined;
    const count = diagnostics.snapshotModelCatalogEvents(&events);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("lookup", events[0].name());
    try std.testing.expect(!events[0].failed);
    try std.testing.expectEqualStrings("outcome=missing_entry model=zai/glm-5.2", events[0].detail());
    try std.testing.expect(events[1].failed);
    try std.testing.expect(events[2].failed);
    try std.testing.expectEqualStrings("outcome=cache_failed model=zai/glm-5.2", events[1].detail());
    try std.testing.expectEqualStrings("outcome=cache_unavailable model=zai/glm-5.2", events[2].detail());
}
