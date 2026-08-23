const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");
const collections = @import("../shared/collections.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_catalog_metadata = @import("../gateway/model_catalog_metadata.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const list_window = @import("../shared/list_window.zig");
const text_utils = @import("../shared/text_utils.zig");
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

const OwnedCatalogAccess = struct {
    access: credentials.CatalogAccess,

    fn init(alloc: Allocator, access: credentials.CatalogAccess) !OwnedCatalogAccess {
        return switch (access) {
            .public_only => .{ .access = access },
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
            .public_only => {},
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

pub const model_provider_filter_count = std.meta.fields(ModelProviderFilter).len;

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
        if (len > 0) std.mem.copyForwards(u8, self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
        self.selected_index = 0;
        self.window_start = 0;
    }

    pub fn providerFilter(self: *const ModelMenu) ModelProviderFilter {
        return @enumFromInt(@min(self.provider_index, model_provider_filter_count - 1));
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
        if (!self.active or self.load_state != .ready) return false;
        const filter_count = model_provider_filter_count;
        if (filter_count <= 1) return false;

        var next = @as(i32, @intCast(self.provider_index)) + delta;
        if (next < 0) next = @as(i32, @intCast(filter_count)) - 1;
        if (next >= @as(i32, @intCast(filter_count))) next = 0;
        self.provider_index = @intCast(next);
        self.selected_index = 0;
        self.window_start = 0;
        return true;
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
    var count: usize = 0;
    for (items) |item| {
        if (modelMenuItemMatches(item, provider_filter, query)) count += 1;
    }
    return count;
}

pub fn modelMenuItemAt(
    items: []const ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
    display_index: usize,
) ?*const ModelMenuItem {
    var current: usize = 0;
    for (items) |*item| {
        if (!modelMenuItemMatches(item.*, provider_filter, query)) continue;
        if (current == display_index) return item;
        current += 1;
    }
    return null;
}

fn modelMenuItemMatches(
    item: ModelMenuItem,
    provider_filter: ModelProviderFilter,
    query: []const u8,
) bool {
    if (!providerMatchesFilter(item.provider, provider_filter)) return false;
    const query_text = std.mem.trim(u8, query, " \t\r\n");
    return query_text.len == 0 or
        text_utils.containsIgnoreCase(item.id, query_text) or
        text_utils.containsIgnoreCase(item.provider, query_text);
}

fn providerMatchesFilter(provider: []const u8, filter: ModelProviderFilter) bool {
    const known_filter: ?ModelProviderFilter = if (std.ascii.eqlIgnoreCase(provider, "anthropic"))
        .anthropic
    else if (std.ascii.eqlIgnoreCase(provider, "openai"))
        .openai
    else if (std.ascii.eqlIgnoreCase(provider, "xai"))
        .xai
    else if (std.ascii.eqlIgnoreCase(provider, "zai"))
        .zai
    else
        null;
    return switch (filter) {
        .all => true,
        .anthropic, .openai, .xai, .zai => known_filter == filter,
        .others => known_filter == null,
    };
}

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    models_path: []const u8,
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: ModelCacheState = .idle,
    completion_pending: bool = false,
    last_attempt_ms: i64 = 0,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    requested_access: ?model_catalog.AccessMetadata = null,
    outcome: CatalogOutcome = .{},
    menu: ModelMenu = .{},
    acp_agent_ids: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: Allocator, models_path: []const u8) Self {
        return .{
            .alloc = alloc,
            .models_path = models_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cancelAndJoin();
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        for (self.acp_agent_ids.items) |id| self.alloc.free(id);
        self.acp_agent_ids.deinit(self.alloc);
    }

    /// Replaces the ACP agent entries surfaced in the model menu. Each name
    /// becomes an `acp/<name>` menu item alongside the fetched catalog.
    pub fn setAcpAgentNames(self: *Self, names: []const []const u8) !void {
        var next: std.ArrayList([]u8) = .empty;
        errdefer {
            for (next.items) |id| self.alloc.free(id);
            next.deinit(self.alloc);
        }
        try next.ensureTotalCapacity(self.alloc, names.len);
        for (names) |name| {
            const id = try std.fmt.allocPrint(self.alloc, "acp/{s}", .{name});
            next.appendAssumeCapacity(id);
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.acp_agent_ids.items) |id| self.alloc.free(id);
        self.acp_agent_ids.deinit(self.alloc);
        self.acp_agent_ids = next;
    }

    pub fn startWarmup(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
    ) void {
        if (!self.beginLoad(access)) return;

        const owned_access = OwnedCatalogAccess.init(self.alloc, access) catch {
            self.markFailed(.{
                .access = .init(access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            });
            return;
        };

        self.thread = std.Thread.spawn(.{}, preloadThreadMain, .{ self, provider, owned_access }) catch {
            var failed_access = owned_access;
            const failure = model_catalog.FailedOutcome{
                .access = .init(failed_access.access),
                .anonymous_fallback_used = false,
                .failure = .{ .category = .runtime, .retryable = true },
            };
            failed_access.deinit(self.alloc);
            self.markFailed(failure);
            return;
        };
    }

    /// Loads the catalog inline for cooperative single-threaded hosts.
    pub fn loadCooperative(
        self: *Self,
        provider: model_catalog.Provider,
        access: credentials.CatalogAccess,
    ) void {
        if (!self.beginLoad(access)) return;

        const result = model_catalog.fetchWithPublicFallback(provider, self.alloc, .{
            .access = access,
            .endpoint = self.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        });
        var loaded = switch (result) {
            .loaded => |loaded| loaded,
            .failed => |failure| {
                self.markFailed(failure);
                self.mutex.lockUncancelable(io_mod.getIo());
                self.completion_pending = true;
                self.mutex.unlock(io_mod.getIo());
                return;
            },
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        if (loaded.catalog.items.len == 0 and self.outcome.loaded != null and self.catalog.items.len > 0) {
            model_catalog.freeModelCatalog(self.alloc, &loaded.catalog);
            self.outcome.last_failure = if (loaded.provenance.fallback_failure) |failure|
                .{
                    .access = loaded.provenance.access,
                    .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                    .failure = failure,
                }
            else
                null;
            self.state = .ready;
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
            return;
        }
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = loaded.catalog;
        self.outcome = .{ .loaded = loaded.provenance };
        self.state = .ready;
        self.completion_pending = true;
        self.mutex.unlock(io_mod.getIo());
    }

    fn beginLoad(self: *Self, access: credentials.CatalogAccess) bool {
        self.finishThreadIfDone();

        const requested_access = model_catalog.AccessMetadata.init(access);
        self.mutex.lockUncancelable(io_mod.getIo());
        const access_changed = self.state != .idle and
            (self.requested_access == null or
                !std.meta.eql(self.requested_access.?, requested_access));
        var reused_public_catalog = false;
        if (access_changed and
            self.state == .ready and
            requested_access.level == .public_only)
        {
            if (self.outcome.loaded) |*loaded| {
                if (loaded.access.level == .public_only) {
                    self.requested_access = requested_access;
                    loaded.* = .{ .access = requested_access };
                    self.outcome.last_failure = null;
                    if (self.menu.active) {
                        self.menu.catalog_state = modelMenuCatalogState(self.outcome);
                    }
                    reused_public_catalog = true;
                }
            }
        }
        self.mutex.unlock(io_mod.getIo());
        if (reused_public_catalog) return false;
        if (access_changed) self.reset();

        const now = io_mod.milliTimestamp();
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_load = switch (self.state) {
            .idle => true,
            .failed => now - self.last_attempt_ms >= 1000,
            .ready => if (self.outcome.last_failure) |failed|
                failed.failure.retryable and now - self.last_attempt_ms >= 1000
            else
                false,
            .loading => false,
        };
        if (!should_load) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        self.state = .loading;
        self.last_attempt_ms = now;
        self.requested_access = requested_access;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);
        return true;
    }

    pub fn reset(self: *Self) void {
        self.cancelAndJoin();

        self.mutex.lockUncancelable(io_mod.getIo());
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
        self.requested_access = null;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);
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
        self.menu.deinit(self.alloc);
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = owned_catalog.*;
        owned_catalog.* = .empty;
        self.outcome = .{ .loaded = .{
            .access = model_catalog.AccessMetadata.init(access),
        } };
        self.state = .ready;
        self.completion_pending = true;
        self.last_attempt_ms = io_mod.milliTimestamp();
        self.requested_access = model_catalog.AccessMetadata.init(access);
        self.cancel_requested.store(false, .seq_cst);
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

    pub fn pollLoadTransition(self: *Self) !bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
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

    pub fn resolveForRequest(
        self: *Self,
        model: []const u8,
        cancel_flag: *std.atomic.Value(bool),
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
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
                return model_capabilities.resolveCapabilities(model, metadata);
            }
            self.mutex.unlock(io_mod.getIo());

            switch (state) {
                .loading => {
                    if (cancel_flag.load(.seq_cst)) {
                        debug_trace.logf(
                            "gateway",
                            "interactive model catalog lookup outcome=cancelled model={s}",
                            .{model},
                        );
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

    pub fn modelCompletions(self: *Self, query: []const u8, out: [][]const u8) usize {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .ready) return 0;

        var count: usize = 0;
        for (self.catalog.items) |entry| {
            if (count >= out.len) break;
            if (query.len == 0 or text_utils.containsIgnoreCase(entry.id, query)) {
                out[count] = entry.id;
                count += 1;
            }
        }
        // Configured ACP agents complete alongside gateway models.
        for (self.acp_agent_ids.items) |id| {
            if (count >= out.len) break;
            if (query.len == 0 or text_utils.containsIgnoreCase(id, query)) {
                out[count] = id;
                count += 1;
            }
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

        const result = model_catalog.fetchWithPublicFallback(provider, self.alloc, .{
            .access = access.access,
            .endpoint = self.models_path,
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        });
        var loaded = switch (result) {
            .loaded => |loaded| loaded,
            .failed => |failure| {
                self.markFailed(failure);
                return;
            },
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        if (loaded.catalog.items.len == 0 and self.outcome.loaded != null and self.catalog.items.len > 0) {
            model_catalog.freeModelCatalog(self.alloc, &loaded.catalog);
            self.outcome.last_failure = if (loaded.provenance.fallback_failure) |failure|
                .{
                    .access = loaded.provenance.access,
                    .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                    .failure = failure,
                }
            else
                null;
            self.state = .ready;
            self.mutex.unlock(io_mod.getIo());
            return;
        }
        model_catalog.freeModelCatalog(self.alloc, &self.catalog);
        self.catalog = loaded.catalog;
        self.outcome = .{ .loaded = loaded.provenance };
        self.state = .ready;
        self.mutex.unlock(io_mod.getIo());
    }

    fn markFailed(self: *Self, failure: model_catalog.FailedOutcome) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.outcome.last_failure = failure;
        self.state = if (self.outcome.loaded != null and self.catalog.items.len > 0) .ready else .failed;
        self.mutex.unlock(io_mod.getIo());
    }

    fn cancelAndJoin(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn finishThreadIfDone(self: *Self) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_join = self.state != .loading and self.thread != null;
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
                menu.load_state = .failed;
            },
            .ready => try hydrateMenuSnapshot(self.alloc, menu, self.catalog.items, self.acp_agent_ids.items),
        }
        menu.catalog_state = modelMenuCatalogState(self.outcome);
    }
};

fn modelMenuCatalogState(outcome: CatalogOutcome) ModelMenuCatalogState {
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
    acp_agent_ids: []const []const u8,
) !void {
    var items: std.ArrayList(ModelMenuItem) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(alloc);
        items.deinit(alloc);
    }
    try items.ensureTotalCapacity(alloc, catalog.len + acp_agent_ids.len);

    // ACP agents lead the list so a configured agent is visible immediately.
    debug_trace.logf("acp", "hydrate catalog={d} acp={d}", .{ catalog.len, acp_agent_ids.len });
    for (acp_agent_ids) |agent_id| {
        const id = try alloc.dupe(u8, agent_id);
        const item = ModelMenuItem{
            .id = id,
            .provider = modelProvider(id),
            .capabilities = model_capabilities.resolveCapabilities(id, null),
        };
        items.append(alloc, item) catch |err| {
            item.deinit(alloc);
            return err;
        };
    }

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

    menu.clearSnapshot(alloc);
    menu.items = items;
    menu.load_state = .ready;
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

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, models_url: []const u8) !*TestEnv {
        _ = try stableEmptyTestEnviron();

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
        if (stable_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn waitForWarmup(runtime: *Runtime) !void {
    var remaining_ms: u64 = 5000;
    while (runtime.isLoading() and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }

    try std.testing.expect(!runtime.isLoading());
    try std.testing.expect(!runtime.isFailed());
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
    runtime.startWarmup(provider.provider(), .{ .public_only = .no_credential });
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
    runtime.last_attempt_ms = io_mod.milliTimestamp() - 1000;

    var provider = AuthChangeCatalog{ .model_id = "public/refreshed" };
    runtime.loadCooperative(provider.provider(), .{ .public_only = .no_credential });

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expect(runtime.outcome.last_failure == null);
    try std.testing.expectEqualStrings("public/refreshed", runtime.catalog.items[0].id);
}

test "model cache projects anonymous fallback provenance for 401 and 403" {
    for ([_]std.http.Status{ .unauthorized, .forbidden }) |status| {
        var runtime = Runtime.init(std.testing.allocator, "/v1/models");
        defer runtime.deinit();
        var provider = RefreshCatalog{
            .first_failure = .{ .category = .authentication, .http_status = status },
            .fallback_model = "public/fallback",
        };

        runtime.startWarmup(provider.provider(), authenticatedCatalogAccess("rejected-key", "team_123"));
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

        runtime.startWarmup(provider.provider(), authenticatedCatalogAccess("rejected-key", "team_123"));
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
    runtime.startWarmup(refresh_provider.provider(), authenticatedCatalogAccess("rejected-key", "team_123"));
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
    runtime.startWarmup(failed_provider.provider(), authenticatedCatalogAccess("test-key", "team_123"));
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
    runtime.last_attempt_ms = 0;
    runtime.startWarmup(failed_provider.provider(), authenticatedCatalogAccess("test-key", "team_123"));
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
        runtime.startWarmup(provider.provider(), case.access);
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

test "model cache reloads a ready authenticated catalog after Fx login access downgrades" {
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
        );
        try waitForWarmup(&runtime);

        var public_provider = AuthChangeCatalog{ .model_id = "public/base-model" };
        runtime.startWarmup(public_provider.provider(), case.access);
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
    runtime.startWarmup(initial_provider.provider(), .{ .public_only = .fx_login_refresh_required });
    try waitForWarmup(&runtime);

    var unused_provider = AuthChangeCatalog{ .model_id = "public/redundant-model" };
    runtime.startWarmup(
        unused_provider.provider(),
        credentials.catalogAccessAfterRefreshFailure(.fx_login),
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
    runtime.startWarmup(stale.provider(), .{ .public_only = .no_credential });

    var remaining_ms: u64 = 5000;
    while (!stale.started.load(.seq_cst) and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(stale.started.load(.seq_cst));

    runtime.reset();
    try std.testing.expect(stale.observed_cancel.load(.seq_cst));

    var current = RefreshCatalog{ .fallback_model = "private/current" };
    runtime.startWarmup(current.provider(), authenticatedCatalogAccess("current-key", "team_current"));
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
            std.testing.allocator,
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
            std.testing.allocator,
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
    runtime.startWarmup(stale.provider(), .{ .public_only = .no_credential });
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
    runtime.startWarmup(current.provider(), authenticatedCatalogAccess("current-key", team));
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

    const models_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/models",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(models_url);
    const env = try TestEnv.install(std.testing.allocator, models_url);
    defer env.deinit();

    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    runtime.startWarmup(test_builtin_gateway.model_catalog_provider, authenticatedCatalogAccess("test-key", "team_123"));
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
    try hydrateMenuSnapshot(alloc, &runtime.menu, &entries, &.{});
    runtime.menu.active = true;

    try std.testing.expectEqual(ModelMenuLoadState.ready, runtime.menu.load_state);
    try std.testing.expectEqual(@as(usize, 4), runtime.menu.filteredItemCount());
    try std.testing.expectEqualStrings("openai/gpt-5", runtime.menu.itemAt(0).?.id);
    try std.testing.expectEqualStrings("private/blue-hornbill", runtime.menu.itemAt(2).?.id);
    try std.testing.expect(runtime.menu.itemAt(0).?.capabilities.supports_reasoning);
    try std.testing.expect(runtime.menu.itemAt(0).?.capabilities.supports_vision);
    try std.testing.expectEqual(@as(?u32, 256_000), runtime.menu.itemAt(0).?.capabilities.context_window);
    try std.testing.expect(runtime.menu.itemAt(1).?.capabilities.supports_fast_mode);
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

    runtime.menu.provider_index = @intFromEnum(ModelProviderFilter.others);
    try std.testing.expectEqual(@as(usize, 2), runtime.menu.filteredItemCount());
    try std.testing.expectEqualStrings("private/blue-hornbill", runtime.menu.itemAt(0).?.id);
    try std.testing.expectEqualStrings("standalone", runtime.menu.itemAt(1).?.id);
    runtime.menu.provider_index = @intFromEnum(ModelProviderFilter.all);

    try std.testing.expect(runtime.menu.moveVisibleItems(-1, 2));
    try std.testing.expectEqual(@as(usize, 3), runtime.menu.selected_index);
    try std.testing.expectEqual(@as(usize, 2), runtime.menu.window_start);
    const selected = (try runtime.menu.selectedModelAlloc(alloc)).?;
    defer alloc.free(selected);
    try std.testing.expectEqualStrings("standalone", selected);
}

test "model menu snapshot lists acp agents with acp provider" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc, "unused");
    defer runtime.deinit();

    try runtime.setAcpAgentNames(&.{ "claude-acp", "gemini" });
    runtime.state = .ready;
    try hydrateMenuSnapshot(alloc, &runtime.menu, &.{}, runtime.acp_agent_ids.items);
    runtime.menu.active = true;

    try std.testing.expectEqual(@as(usize, 2), runtime.menu.filteredItemCount());
    try std.testing.expectEqualStrings("acp/claude-acp", runtime.menu.itemAt(0).?.id);
    try std.testing.expectEqualStrings("acp", runtime.menu.itemAt(0).?.provider);
    try std.testing.expectEqualStrings("acp/gemini", runtime.menu.itemAt(1).?.id);

    // Replacing the list drops stale entries.
    try runtime.setAcpAgentNames(&.{"opencode"});
    try hydrateMenuSnapshot(alloc, &runtime.menu, &.{}, runtime.acp_agent_ids.items);
    try std.testing.expectEqual(@as(usize, 1), runtime.menu.filteredItemCount());
    try std.testing.expectEqualStrings("acp/opencode", runtime.menu.itemAt(0).?.id);
}

test "model menu snapshot construction cleans every allocation failure" {
    const backing = std.testing.allocator;
    const entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("openai/gpt-5"), .model_type = @constCast("language") },
        .{ .id = @constCast("anthropic/claude-opus-4.8"), .model_type = @constCast("language") },
    };

    var probe = std.testing.FailingAllocator.init(backing, .{});
    var menu: ModelMenu = .{};
    try hydrateMenuSnapshot(probe.allocator(), &menu, &entries, &.{});
    menu.deinit(probe.allocator());
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var failed_menu: ModelMenu = .{};
        if (hydrateMenuSnapshot(failing.allocator(), &failed_menu, &entries, &.{})) {
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

    const models_url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/models",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(models_url);
    const env = try TestEnv.install(std.testing.allocator, models_url);
    defer env.deinit();

    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();
    runtime.startWarmup(test_builtin_gateway.model_catalog_provider, authenticatedCatalogAccess("test-key", "team_123"));
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

test "model cache reset replaces ready public catalog with team catalog" {
    var runtime = Runtime.init(std.testing.allocator, "/v1/models");
    defer runtime.deinit();

    {
        var fixture = try test_gateway_client.TestModelCatalogFixture.init();
        defer fixture.deinit();
        try fixture.start();
        try std.testing.expect(fixture.waitForAcceptStart(5000));

        const models_url = try std.fmt.allocPrint(
            std.testing.allocator,
            "http://127.0.0.1:{d}/v1/models",
            .{fixture.port()},
        );
        defer std.testing.allocator.free(models_url);
        const env = try TestEnv.install(std.testing.allocator, models_url);
        defer env.deinit();

        runtime.startWarmup(test_builtin_gateway.model_catalog_provider, .{ .public_only = .no_credential });
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

        const models_url = try std.fmt.allocPrint(
            std.testing.allocator,
            "http://127.0.0.1:{d}/v1/models",
            .{fixture.port()},
        );
        defer std.testing.allocator.free(models_url);
        const env = try TestEnv.install(std.testing.allocator, models_url);
        defer env.deinit();

        runtime.startWarmup(test_builtin_gateway.model_catalog_provider, authenticatedCatalogAccess("team-key", "team_123"));
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
