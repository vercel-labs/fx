const std = @import("std");
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
const e2e_gateway_models_url_env = "FX_TEST_GATEWAY_MODELS_URL";

/// What asked for a catalog load. Every trigger is user activity, so an idle
/// session never polls the models endpoint.
pub const LoadTrigger = enum {
    /// Refetches a loaded catalog only after the provider's refresh interval.
    activity,
    /// The model picker opened. Revalidates unless a fetch is in flight or
    /// one started less than `picker_revalidate_floor_ms` ago.
    picker_open,
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
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: ModelCacheState = .idle,
    /// A fetch is running. Only the first load for an access shows as
    /// `.loading`; a revalidation or retry leaves the state readers see alone.
    /// A request waits up to `failed_catalog_retry_wait_ms` for a failed
    /// catalog's retry, and on nothing else but a first load.
    fetch_in_flight: bool = false,
    /// Consecutive failed fetches. A success or reset clears it.
    failure_streak: u32 = 0,
    /// After a failure, no fetch starts before this time, whatever the trigger.
    retry_not_before_ms: i64 = 0,
    /// A finished revalidation waiting for `pollLoadTransition` to adopt it.
    /// Owns any loaded catalog.
    staged: ?model_catalog.FetchResult = null,
    completion_pending: bool = false,
    last_attempt_ms: i64 = 0,
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
    }

    pub fn startWarmup(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
        trigger: LoadTrigger,
    ) void {
        self.from_profile_settings = provider.provider_id == .configured;
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
        self.from_profile_settings = provider.provider_id == .configured;
        if (!self.beginLoad(access, provider.refresh_interval_ms, .activity)) return;

        self.completeFetch(model_catalog.fetchWithPublicFallback(provider, self.alloc, .{
            .access = access,
            .endpoint = self.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        }));
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
        const backoff_over = now < self.last_attempt_ms or now >= self.retry_not_before_ms;
        // A staged revalidation is newer than anything a fetch would start now.
        // A fetch that finished after the join above still holds its thread;
        // the next trigger joins it before starting another.
        const should_load = !self.fetch_in_flight and self.staged == null and self.thread == null and backoff_over and switch (self.state) {
            .idle, .failed => true,
            .ready => expired or picker_due or retry_due,
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
        self.failure_streak = 0;
        self.retry_not_before_ms = 0;
        self.requested_access = model_catalog.AccessMetadata.init(access);
        self.cancel_requested.store(false, .seq_cst);
        const entries = self.catalog.items.len;
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
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.staged) |staged| {
            self.staged = null;
            self.applyFetchLocked(staged).record();
        }
        if (!self.completion_pending) return false;

        if (self.menu.active) try self.refreshMenuLocked(&self.menu);
        self.completion_pending = false;
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

    pub fn metadataForModel(self: *Self, model: []const u8) ?model_capabilities.GatewayMetadata {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return null;

        const entry = findCatalogModel(self.catalog.items, model) orelse return null;
        return model_catalog_metadata.fromCatalogEntry(entry.*);
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
            .endpoint = self.models_path,
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
                const reuse_previous = catalog.items.len == 0 and self.outcome.loaded != null and self.catalog.items.len > 0;
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
                self.state = .ready;
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
    }

    try std.testing.expectEqual(@as(usize, cases.len), provider.calls);
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
