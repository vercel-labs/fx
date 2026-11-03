//! What the model hub shows (D221): every provider fx knows with its
//! sign-in state, the models of each signed-in provider, the role table and
//! the web search bank, copied into one arena when the hub opens or after a
//! change. The hub's state and its renderer read this snapshot; nothing in
//! it is borrowed from the live app.

const std = @import("std");
const model_roles = @import("../config/model_roles.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const Role = model_roles.Role;
pub const RoleId = model_roles.RoleId;

/// How a provider signs in, which picks what the hub offers for it.
pub const SignIn = enum {
    /// The `/login` flow for the provider: a browser, a key, or both.
    login,
    /// Nothing to sign in to: settings describe the endpoint and its key.
    settings,
    /// Signed in outside fx, as Codex and Grok subscriptions are.
    external,
};

pub const Provider = struct {
    /// The provider's settings key. Used to act on it, never shown.
    key: []const u8,
    /// The name shown.
    name: []const u8,
    /// One line on how it is signed in, or how to sign in.
    detail: []const u8,
    signed_in: bool,
    /// The session's provider.
    active: bool,
    sign_in: SignIn,
    /// A saved key or login that sign out removes.
    can_sign_out: bool,
    /// False for a provider whose catalog only loads once it is active.
    models_known: bool = true,
    model_count: usize = 0,
    /// A catalog request is in flight; the sidebar keeps the row visible and
    /// renders a spinner rather than moving focus.
    refreshing: bool = false,
    last_attempt_age_ms: ?i64 = null,
    last_success_age_ms: ?i64 = null,
    failure_category: ?[]const u8 = null,
    failure_status: ?u16 = null,
    credential_source: ?[]const u8 = null,
};

pub const ModelCost = struct {
    /// Prices per million tokens, as displayed by the model catalog.
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,

    pub fn isFree(self: ModelCost) bool {
        return self.input == 0 and self.output == 0;
    }
};

pub const Model = struct {
    provider: u16,
    /// The model's ID, used to select it; shown only when it has no name.
    id: []const u8,
    /// The name shown: the catalog's name, else the ID.
    name: []const u8,
    description: []const u8 = "",
    context_window: ?u32 = null,
    max_tokens: ?u32 = null,
    cost: ?ModelCost = null,
    intelligence: ?f64 = null,
    /// Catalog lifecycle and product badges.
    is_new: bool = false,
    is_beta: bool = false,
    is_recommended: bool = false,
    released: i64 = 0,
    catalog_priority: ?u32 = null,
    mru_index: ?usize = null,
    ttft_ms: ?u32 = null,
    tokens_per_second: ?f64 = null,
    has_reasoning: bool = false,
    has_vision: bool = false,
    /// `auto` is always offered; these follow it.
    efforts: []const types.ReasoningEffort = &.{},
    current: bool = false,
    /// Roles that pick this model, in table order.
    roles: []const RoleId = &.{},
};

/// Whether a role's chain entry can be used now (D250).
pub const EntryState = enum {
    ready,
    /// On the active provider, but its catalog does not list the model.
    unknown_model,
    /// On a signed-in provider that is not the session's.
    other_provider,
    /// On a provider that is not signed in.
    signed_out,
    /// `@role`: follows another role.
    alias,
};

/// One reference of a role's chain: the first is the assignment, the rest
/// its fallbacks, in order.
pub const EntryRow = struct {
    /// The reference as saved, without its level. Used to save, not shown.
    ref: []const u8,
    /// The reference as people read it, such as `cento · claude-cento`.
    shown: []const u8,
    effort: ?types.ReasoningEffort = null,
    /// The levels the entry's model offers, for its thinking strip.
    efforts: []const types.ReasoningEffort = &.{},
    state: EntryState = .ready,
};

pub const RoleRow = struct {
    role: RoleId,
    /// Optional configured display metadata for custom roles.
    label: []const u8 = "",
    summary: []const u8 = "",
    hidden: bool = false,
    /// The model the profile assigns, as shown; null when unset.
    assigned: ?[]const u8 = null,
    /// The role's chain; empty when unset.
    entries: []const EntryRow = &.{},
    /// The entry the role resolves to now.
    in_use: ?usize = null,
    /// What the role resolves to now, through its fallbacks.
    resolved: ?[]const u8 = null,
    /// The fallback chain when nothing is assigned, as shown.
    chain: []const u8 = "",
    /// Position in `cycle_order`, from 1.
    cycle_position: ?usize = null,
};

pub const WebSearchRow = struct {
    /// The provider's settings ID, used to save the order, never shown.
    id: []const u8,
    name: []const u8,
    excluded: bool,
    ready: bool,
    /// What the row says while it is not ready.
    needs: []const u8 = "needs a key",
    needs_detail: []const u8 = " is tried once its key is set",
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    providers: []Provider = &.{},
    models: []Model = &.{},
    roles: []RoleRow = &.{},
    cycle: []RoleId = &.{},
    web_search: []WebSearchRow = &.{},
    /// The session's reasoning effort; null when the session does not
    /// report it, as a detached one does not.
    effort: ?types.ReasoningEffort = null,
    /// The active provider's catalog is still loading.
    loading: bool = false,
    /// Prompt tokens used by the current turn, when the host reports them.
    /// Used only to mark models that need compaction before switching.
    current_context_tokens: ?u32 = null,

    pub fn init(alloc: Allocator) Snapshot {
        return .{ .arena = .init(alloc) };
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn providerName(self: *const Snapshot, index: u16) []const u8 {
        return if (index < self.providers.len) self.providers[index].name else "";
    }

    pub fn currentModel(self: *const Snapshot) ?usize {
        for (self.models, 0..) |model, index| if (model.current) return index;
        return null;
    }

    pub fn roleRow(self: *const Snapshot, role: RoleId) ?*const RoleRow {
        for (self.roles) |*row| if (row.role.eql(role)) return row;
        return null;
    }
};

/// The role's name for people.
pub fn roleName(role: Role) []const u8 {
    return switch (role) {
        .default => "Default",
        .small => "Small",
        .deep => "Deep",
        .worker => "Worker",
        .tiny => "Tiny",
        .review => "Review",
        .title => "Title",
        .compact => "Compact",
        .designer => "Designer",
        .commit => "Commit",
        .advisor => "Advisor",
    };
}

/// Label for a dynamic role identity. Configured tag/name overrides are
/// carried on RoleRow; this helper is the stable fallback for chips/badges.
pub fn roleNameId(role: RoleId) []const u8 {
    return switch (role) {
        .builtin => |builtin| roleName(builtin),
        .custom => |name| name,
    };
}

/// The order roles are listed in, as proto lists its built-in roles first.
pub const role_order = [_]Role{ .default, .small, .deep, .worker, .tiny, .review, .title, .compact, .designer, .commit, .advisor };

/// Builds a snapshot. Every string is copied into the snapshot's arena.
pub const Builder = struct {
    snapshot: Snapshot,
    providers: std.ArrayList(Provider) = .empty,
    models: std.ArrayList(Model) = .empty,
    roles: std.ArrayList(RoleRow) = .empty,
    web_search: std.ArrayList(WebSearchRow) = .empty,

    pub fn init(alloc: Allocator) Builder {
        return .{ .snapshot = .init(alloc) };
    }

    pub fn deinit(self: *Builder) void {
        self.snapshot.deinit();
    }

    pub fn arena(self: *Builder) Allocator {
        return self.snapshot.arena.allocator();
    }

    pub fn dupe(self: *Builder, text: []const u8) ![]const u8 {
        return self.arena().dupe(u8, text);
    }

    /// Adds a provider; returns its index for its models.
    pub fn addProvider(self: *Builder, provider: Provider) !u16 {
        var copy = provider;
        copy.key = try self.dupe(provider.key);
        copy.name = try self.dupe(provider.name);
        copy.detail = try self.dupe(provider.detail);
        try self.providers.append(self.arena(), copy);
        return @intCast(self.providers.items.len - 1);
    }

    /// Adds a model unless its provider already lists that ID.
    pub fn addModel(self: *Builder, model: Model) !void {
        for (self.models.items) |*existing| {
            if (existing.provider != model.provider or !std.mem.eql(u8, existing.id, model.id)) continue;
            // Catalog and configured declarations often describe the same
            // model. Keep the first non-empty display values while filling
            // fields the first source did not know.
            if (existing.name.len == 0 or std.mem.eql(u8, existing.name, existing.id)) {
                if (model.name.len > 0) existing.name = try self.dupe(model.name);
            }
            if (existing.description.len == 0 and model.description.len > 0) existing.description = try self.dupe(model.description);
            if (existing.context_window == null) existing.context_window = model.context_window;
            if (existing.max_tokens == null) existing.max_tokens = model.max_tokens;
            if (existing.cost == null) existing.cost = model.cost;
            if (existing.intelligence == null) existing.intelligence = model.intelligence;
            if (existing.released == 0) existing.released = model.released;
            if (existing.catalog_priority == null) existing.catalog_priority = model.catalog_priority;
            if (existing.mru_index == null) existing.mru_index = model.mru_index;
            if (existing.ttft_ms == null) existing.ttft_ms = model.ttft_ms;
            if (existing.tokens_per_second == null) existing.tokens_per_second = model.tokens_per_second;
            existing.is_new = existing.is_new or model.is_new;
            existing.is_beta = existing.is_beta or model.is_beta;
            existing.is_recommended = existing.is_recommended or model.is_recommended;
            existing.has_reasoning = existing.has_reasoning or model.has_reasoning;
            existing.has_vision = existing.has_vision or model.has_vision;
            existing.current = existing.current or model.current;
            if (existing.efforts.len == 0 and model.efforts.len > 0) existing.efforts = try self.arena().dupe(types.ReasoningEffort, model.efforts);
            if (existing.roles.len == 0 and model.roles.len > 0) existing.roles = try self.arena().dupe(RoleId, model.roles);
            return;
        }
        var copy = model;
        copy.id = try self.dupe(model.id);
        copy.name = try self.dupe(if (model.name.len > 0) model.name else model.id);
        copy.description = try self.dupe(model.description);
        copy.efforts = try self.arena().dupe(types.ReasoningEffort, model.efforts);
        copy.roles = try self.arena().dupe(RoleId, model.roles);
        try self.models.append(self.arena(), copy);
        self.providers.items[model.provider].model_count += 1;
    }

    pub fn addRole(self: *Builder, row: RoleRow) !void {
        var copy = row;
        if (row.assigned) |text| copy.assigned = try self.dupe(text);
        if (row.resolved) |text| copy.resolved = try self.dupe(text);
        copy.label = try self.dupe(row.label);
        copy.summary = try self.dupe(row.summary);
        copy.chain = try self.dupe(row.chain);
        const entries = try self.arena().alloc(EntryRow, row.entries.len);
        for (row.entries, entries) |entry, *out| {
            out.* = entry;
            out.ref = try self.dupe(entry.ref);
            out.shown = try self.dupe(entry.shown);
            out.efforts = try self.arena().dupe(types.ReasoningEffort, entry.efforts);
        }
        copy.entries = entries;
        try self.roles.append(self.arena(), copy);
    }

    pub fn addWebSearch(self: *Builder, row: WebSearchRow) !void {
        var copy = row;
        copy.id = try self.dupe(row.id);
        copy.name = try self.dupe(row.name);
        try self.web_search.append(self.arena(), copy);
    }

    /// Orders providers signed in first, then by name, and models by
    /// provider and name, then hands the snapshot over.
    pub fn finish(self: *Builder, cycle: []const RoleId) !Snapshot {
        const a = self.arena();
        const count = self.providers.items.len;
        const order = try a.alloc(u16, count);
        for (order, 0..) |*slot, index| slot.* = @intCast(index);
        std.mem.sort(u16, order, self.providers.items, providerBefore);
        // Remap model provider indices to the sorted order.
        const remap = try a.alloc(u16, count);
        const sorted = try a.alloc(Provider, count);
        for (order, 0..) |old, new| {
            remap[old] = @intCast(new);
            sorted[new] = self.providers.items[old];
        }
        for (self.models.items) |*model| model.provider = remap[model.provider];
        self.snapshot.providers = sorted;
        std.mem.sort(Model, self.models.items, self.snapshot.providers, modelBefore);
        self.snapshot.models = self.models.items;
        self.snapshot.roles = self.roles.items;
        self.snapshot.web_search = self.web_search.items;
        self.snapshot.cycle = try a.dupe(RoleId, cycle);
        const result = self.snapshot;
        self.* = .{ .snapshot = .init(result.arena.child_allocator) };
        return result;
    }
};

fn providerBefore(providers: []const Provider, a: u16, b: u16) bool {
    const left = providers[a];
    const right = providers[b];
    if (left.signed_in != right.signed_in) return left.signed_in;
    return std.ascii.lessThanIgnoreCase(left.name, right.name);
}

fn modelBefore(providers: []const Provider, a: Model, b: Model) bool {
    // Proto's browser keeps role models first, then recent use, provider, and
    // catalog/version recency. The final ID comparison makes ties stable and
    // deterministic without depending on fetch order.
    const a_roles = a.roles.len > 0;
    const b_roles = b.roles.len > 0;
    if (a_roles != b_roles) return a_roles;
    const a_mru = a.mru_index orelse std.math.maxInt(usize);
    const b_mru = b.mru_index orelse std.math.maxInt(usize);
    if (a_mru != b_mru) return a_mru < b_mru;
    if (a.provider != b.provider) return std.ascii.lessThanIgnoreCase(providers[a.provider].name, providers[b.provider].name);
    const a_priority = a.catalog_priority orelse std.math.maxInt(u32);
    const b_priority = b.catalog_priority orelse std.math.maxInt(u32);
    if (a_priority != b_priority) return a_priority < b_priority;
    if (a.released != b.released) return a.released > b.released;
    return std.ascii.lessThanIgnoreCase(a.id, b.id);
}

/// A fuzzy match score for `query` against `text`, or null when the query's
/// characters do not all appear in order. Higher is better: consecutive
/// characters and matches at word starts score more.
fn fuzzyScore(text: []const u8, query: []const u8) ?u32 {
    if (query.len == 0) return 0;
    var score: u32 = 0;
    var position: usize = 0;
    var previous: ?usize = null;
    for (query) |raw| {
        if (raw == ' ') continue;
        const needle = std.ascii.toLower(raw);
        var found: ?usize = null;
        while (position < text.len) : (position += 1) {
            if (std.ascii.toLower(text[position]) == needle) {
                found = position;
                break;
            }
        }
        const at = found orelse return null;
        score += 1;
        if (previous != null and previous.? + 1 == at) score += 4;
        if (at == 0 or !std.ascii.isAlphanumeric(text[at - 1])) score += 3;
        previous = at;
        position = at + 1;
    }
    // The query as one piece beats scattered letters, more so at a word start.
    if (findIgnoreCase(text, query)) |at| {
        score += 64;
        if (at == 0 or !std.ascii.isAlphanumeric(text[at - 1])) score += 32;
    }
    // Shorter texts rank above longer ones with the same matches.
    return score * 64 -| @as(u32, @intCast(@min(text.len, 63)));
}

fn findIgnoreCase(text: []const u8, query: []const u8) ?usize {
    if (query.len == 0 or query.len > text.len) return null;
    var index: usize = 0;
    while (index + query.len <= text.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(text[index..][0..query.len], query)) return index;
    }
    return null;
}

/// The text a model matches against: provider, name and ID.
pub fn modelSearchScore(snapshot: *const Snapshot, model: Model, query: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, query, " \t");
    if (trimmed.len == 0) return 0;
    var best: ?u32 = null;
    for ([_][]const u8{ model.name, model.id }) |text| {
        if (fuzzyScore(text, trimmed)) |score| best = @max(best orelse 0, score + 16);
    }
    var buf: [256]u8 = undefined;
    const joined = std.mem.print(&buf, "{s}/{s}", .{ snapshot.providerName(model.provider), model.id }) catch model.id;
    if (fuzzyScore(joined, trimmed)) |score| best = @max(best orelse 0, score);
    if (model.cost == null or model.cost.?.isFree()) {
        if (fuzzyScore("free", trimmed)) |score| best = @max(best orelse 0, score);
    }
    return best;
}

test "fuzzy scores prefer consecutive and word-start matches" {
    try std.testing.expect(fuzzyScore("claude-cento", "cc") != null);
    try std.testing.expect(fuzzyScore("claude-cento", "xz") == null);
    try std.testing.expect(fuzzyScore("claude-cento", "cento").? > fuzzyScore("claude-cento", "cdeno").?);
    try std.testing.expect(fuzzyScore("gpt-5", "gpt").? > fuzzyScore("a-long-gpt-model-name", "gpt").?);
    // A whole-word match beats letters scattered through a shorter name.
    try std.testing.expect(fuzzyScore("claude-cento-lite", "lite").? > fuzzyScore("ling-3.0-tiny-free", "lite").?);
}

test "the builder orders signed-in providers first and remaps their models" {
    var builder: Builder = .init(std.testing.allocator);
    defer builder.deinit();
    const zen = try builder.addProvider(.{ .key = "opencode-zen", .name = "OpenCode Zen", .detail = "", .signed_in = false, .active = false, .sign_in = .login, .can_sign_out = false });
    const cento = try builder.addProvider(.{ .key = "cento", .name = "cento", .detail = "", .signed_in = true, .active = true, .sign_in = .settings, .can_sign_out = false });
    try builder.addModel(.{ .provider = zen, .id = "glm", .name = "" });
    try builder.addModel(.{ .provider = cento, .id = "claude-cento", .name = "Claude Cento", .roles = &.{.{ .builtin = .default }} });
    try builder.addModel(.{ .provider = cento, .id = "claude-cento", .name = "dupe" });
    var snapshot = try builder.finish(&.{ .{ .builtin = .deep }, .{ .builtin = .default } });
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("cento", snapshot.providers[0].name);
    try std.testing.expectEqual(@as(usize, 1), snapshot.providers[0].model_count);
    try std.testing.expectEqual(@as(usize, 2), snapshot.models.len);
    try std.testing.expectEqualStrings("Claude Cento", snapshot.models[0].name);
    try std.testing.expectEqual(@as(u16, 0), snapshot.models[0].provider);
    try std.testing.expectEqualStrings("glm", snapshot.models[1].name);
    try std.testing.expectEqual(@as(u16, 1), snapshot.models[1].provider);
    try std.testing.expectEqualSlices(RoleId, &.{ .{ .builtin = .deep }, .{ .builtin = .default } }, snapshot.cycle);
}
