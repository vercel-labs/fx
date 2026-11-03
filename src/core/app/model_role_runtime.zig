//! The app's model roles (D170): the profile's table, what each role
//! resolves to on the active provider, `/role`, and role cycling.
//!
//! Side calls, turns and fleet workers borrow the model bytes a role
//! resolves to for as long as they run. A change replaces the whole table
//! and keeps the old one until the app exits, so no borrow dangles (D173).
//! The worker thread resolves roles for turns and compaction while the UI
//! thread may assign one, so the table pointer swaps under `mutex`.

const std = @import("std");
const model_roles = @import("../config/model_roles.zig");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const provider_runtime = @import("provider_runtime.zig");
const session_backend = @import("session_backend.zig");
const session_commands = @import("../session/session_commands.zig");

const Allocator = std.mem.Allocator;
const Role = model_roles.Role;
const model_provider = @import("../config/model_provider.zig");
const provider_set = @import("../gateway/provider_set.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const configured_provider = @import("../config/configured_provider.zig");

const types = @import("../shared/types.zig");

/// The next role in `cycle_order` whose model or thinking level differs
/// from the session's, with the thinking level the role names (D251).
/// As proto does, the cycle continues from the role it last picked while
/// that role still names the session's model. A role without a level is
/// effort-blind, except the default role, which returns to the startup
/// level, so a deep role on the default model still cycles back (D265).
pub const Step = struct { role: model_roles.RoleId, model: []const u8, effort: ?types.ReasoningEffort = null };

fn roleEffort(view: Host, role: model_roles.RoleId, picked: Picked) ?types.ReasoningEffort {
    if (picked.effort) |effort| return effort;
    return if (role == .builtin and role.builtin == .default) view.state.default_effort else null;
}

/// Unknown levels on either side compare equal.
fn sameEffort(a: ?types.ReasoningEffort, b: ?types.ReasoningEffort) bool {
    const left = a orelse return true;
    const right = b orelse return true;
    return std.mem.eql(u8, left.label(), right.label());
}

fn cycleStep(view: Host, backward: bool) ?Step {
    const order = view.state.table.cycleOrderIds();
    if (order.len == 0) return null;
    var start: usize = if (backward) 0 else order.len - 1;
    var current_effort = view.current_effort orelse view.state.default_effort;
    const last: ?usize = if (view.state.last_cycled) |role| blk: {
        for (order, 0..) |candidate, index| if (candidate.eql(role)) break :blk index;
        break :blk null;
    } else null;
    const resumed = if (last) |index| if (view.pickId(order[index])) |picked| std.mem.eql(u8, picked.model, view.current_model) else false else false;
    if (resumed) {
        start = last.?;
        current_effort = roleEffort(view, order[start], view.pickId(order[start]).?);
    } else for (order, 0..) |role, index| {
        const picked = view.pickId(role) orelse continue;
        if (std.mem.eql(u8, picked.model, view.current_model) and sameEffort(roleEffort(view, role, picked), current_effort)) {
            start = index;
            break;
        }
    }
    var offset: usize = 1;
    while (offset <= order.len) : (offset += 1) {
        const index = if (backward) (start + order.len * 2 - offset) % order.len else (start + offset) % order.len;
        const picked = view.pickId(order[index]) orelse continue;
        const effort = roleEffort(view, order[index], picked);
        if (std.mem.eql(u8, picked.model, view.current_model) and sameEffort(effort, current_effort)) continue;
        return .{ .role = order[index], .model = picked.model, .effort = effort };
    }
    return null;
}

pub const State = struct {
    table: model_roles.Table = .{},
    /// The profile's default model and the provider it belongs to; owned.
    default_provider: []u8 = &.{},
    default_model: []u8 = &.{},
    /// The session's startup thinking level, which the default role
    /// returns to when cycling (D265).
    default_effort: ?types.ReasoningEffort = null,
    /// The role Alt+P or `/role next` last switched to.
    last_cycled: ?model_roles.RoleId = null,
    /// Tables replaced while the app ran. Their bytes may still be borrowed.
    retired: std.ArrayList(model_roles.Table) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.table.deinit(alloc);
        for (self.retired.items) |*table| table.deinit(alloc);
        self.retired.deinit(alloc);
        if (self.default_provider.len > 0) alloc.free(self.default_provider);
        if (self.default_model.len > 0) alloc.free(self.default_model);
        self.* = .{};
    }

    /// Takes ownership of `table`; records the startup default model.
    pub fn init(self: *State, alloc: Allocator, table: model_roles.Table, provider: []const u8, default_model: []const u8) !void {
        self.deinit(alloc);
        self.table = table;
        self.default_provider = try alloc.dupe(u8, provider);
        self.default_model = try alloc.dupe(u8, default_model);
    }

    /// Replaces the whole table with one reread from the profile, keeping
    /// the old one for borrowers. Takes ownership of `table`.
    pub fn reload(self: *State, alloc: Allocator, table: model_roles.Table) !void {
        var owned = table;
        errdefer owned.deinit(alloc);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = owned;
    }

    /// Replaces a dynamic role entry; null clears it.
    pub fn assignId(self: *State, alloc: Allocator, role: model_roles.RoleId, value: ?[]const u8) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        try next.setId(alloc, role, value);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    pub fn assign(self: *State, alloc: Allocator, role: Role, value: ?[]const u8) !void {
        return self.assignId(alloc, .{ .builtin = role }, value);
    }

    /// Adds a custom role while preserving borrowed snapshots held by active
    /// model-hub views. The new table owns the role name.
    pub fn createRole(self: *State, alloc: Allocator, role: model_roles.RoleId) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        try next.createRole(alloc, role);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    /// Removes a custom role and its metadata from the live role table.
    pub fn deleteRole(self: *State, alloc: Allocator, role: model_roles.RoleId) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        try next.deleteRole(alloc, role);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    /// Renames a custom role while preserving its assignment, tag, bank and
    /// cycle membership in the copy-on-write replacement table.
    pub fn renameRole(self: *State, alloc: Allocator, old: model_roles.RoleId, new: model_roles.RoleId) !void {
        if (old != .custom or new != .custom) return error.InvalidRoleName;
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);

        var value_copy: ?[]u8 = null;
        defer if (value_copy) |value| alloc.free(value);
        if (next.getId(old)) |value| value_copy = try alloc.dupe(u8, value);

        var tag_text: []u8 = &.{};
        var tag_name: []u8 = &.{};
        var tag_color: []u8 = &.{};
        var tag_hidden = false;
        var has_tag = false;
        defer {
            if (tag_text.len > 0) alloc.free(tag_text);
            if (tag_name.len > 0) alloc.free(tag_name);
            if (tag_color.len > 0) alloc.free(tag_color);
        }
        if (next.tagFor(old)) |tag| {
            has_tag = true;
            tag_text = try alloc.dupe(u8, tag.tag);
            tag_name = try alloc.dupe(u8, tag.name);
            tag_color = try alloc.dupe(u8, tag.color);
            tag_hidden = tag.hidden;
        }

        var bank_selectors: [64][]const u8 = undefined;
        var bank_len: usize = 0;
        defer for (bank_selectors[0..bank_len]) |selector| alloc.free(selector);
        if (next.bankFor(old)) |selectors| {
            for (selectors) |selector| {
                if (bank_len == bank_selectors.len) break;
                bank_selectors[bank_len] = try alloc.dupe(u8, selector);
                bank_len += 1;
            }
        }

        const had_cycle = next.has_cycle;
        var cycle_order: [64]model_roles.RoleId = undefined;
        const original_cycle = next.cycleOrderIds();
        const cycle_len = @min(original_cycle.len, cycle_order.len);
        for (original_cycle[0..cycle_len], 0..) |id, index| {
            cycle_order[index] = if (id.eql(old)) new else id;
        }

        try next.deleteRole(alloc, old);
        try next.createRole(alloc, new);
        if (value_copy) |value| try next.setId(alloc, new, value);
        if (has_tag) try next.setTagInput(alloc, new, .{ .tag = tag_text, .name = tag_name, .color = tag_color, .hidden = tag_hidden });
        if (bank_len > 0) try next.setBank(alloc, new, bank_selectors[0..bank_len]);
        if (had_cycle) try next.setCycleIds(alloc, cycle_order[0..cycle_len]);

        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    pub fn setTag(self: *State, alloc: Allocator, role: model_roles.RoleId, tag: model_roles.TagInput) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        try next.setTagInput(alloc, role, tag);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    pub fn clearTag(self: *State, alloc: Allocator, role: model_roles.RoleId) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        next.clearTag(alloc, role);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    pub fn setBank(self: *State, alloc: Allocator, role: model_roles.RoleId, selectors: []const []const u8) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        try next.setBank(alloc, role, selectors);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    pub fn clearBank(self: *State, alloc: Allocator, role: model_roles.RoleId) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        next.clearBank(alloc, role);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    pub fn setFallback(self: *State, alloc: Allocator, selector: []const u8, chain: []const u8) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        try next.setFallback(alloc, selector, chain);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    pub fn clearFallback(self: *State, alloc: Allocator, selector: []const u8) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        next.clearFallback(alloc, selector);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    /// Replaces dynamic `cycle_order` (D222).
    pub fn setCycleIds(self: *State, alloc: Allocator, order: []const model_roles.RoleId) !void {
        var next = try self.table.dupe(alloc);
        errdefer next.deinit(alloc);
        try next.setCycleIds(alloc, order);
        try self.retired.ensureUnusedCapacity(alloc, 1);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.retired.appendAssumeCapacity(self.table);
        self.table = next;
    }

    pub fn setCycle(self: *State, alloc: Allocator, order: []const Role) !void {
        var ids: [model_roles.role_count]model_roles.RoleId = undefined;
        for (order, 0..) |role, index| ids[index] = .{ .builtin = role };
        return self.setCycleIds(alloc, ids[0..order.len]);
    }
};

/// What role resolution needs from its host: the TUI app, `fx ask`, or
/// the ACP server that runs a daemon's sessions.
pub const Host = struct {
    state: *State,
    provider: model_provider.ProviderId,
    /// The session's model; `@default` when the profile has none here.
    current_model: []const u8,
    /// The session's thinking level; null matches roles on model alone.
    current_effort: ?types.ReasoningEffort = null,
    set: provider_set.Set,
    /// The legacy `review_model` setting or FX_REVIEW_MODEL; empty for none.
    review_model: []const u8 = "",
    /// Provider/model candidates supplied by the registry. Empty means the
    /// registry has not loaded and role references remain optimistic.
    candidates: []const model_roles.Candidate = &.{},
    /// The active provider's catalog, which a fallback chain checks (D250).
    known: ?model_roles.Known = null,

    /// Resolves a role to a provider-qualified executable selection. This is
    /// the only role API side calls should use.
    pub fn pickSelectionId(self: Host, role: model_roles.RoleId) ?model_roles.Selection {
        const provider = self.provider;
        const label = provider.label();
        self.state.mutex.lockUncancelable(io_mod.getIo());
        defer self.state.mutex.unlock(io_mod.getIo());
        const default_model = self.defaultModelLocked(label);
        return model_roles.resolveSelection(&self.state.table, role, .{
            .provider = label,
            .default_model = default_model,
            .builtin_small = self.set.select(provider).title_model,
            .legacy_review = reviewerModelFor(self.set, provider, self.review_model),
            .configured = self.set.definitions,
            .known = self.known,
            .candidates = self.candidates,
        });
    }

    pub fn pickSelection(self: Host, role: Role) ?model_roles.Selection {
        return self.pickSelectionId(.{ .builtin = role });
    }

    pub fn pickId(self: Host, role: model_roles.RoleId) ?Picked {
        const selection = self.pickSelectionId(role) orelse return null;
        if (!std.ascii.eqlIgnoreCase(selection.provider.label(), self.provider.label())) return null;
        return .{ .model = selection.model, .effort = selection.effort };
    }

    pub fn defaultModel(self: Host) []const u8 {
        self.state.mutex.lockUncancelable(io_mod.getIo());
        defer self.state.mutex.unlock(io_mod.getIo());
        return self.defaultModelLocked(self.provider.label());
    }

    fn defaultModelLocked(self: Host, label: []const u8) []const u8 {
        return if (self.state.default_model.len > 0 and std.ascii.eqlIgnoreCase(self.state.default_provider, label))
            self.state.default_model
        else
            self.current_model;
    }

    pub fn selectionChain(self: Host, role: model_roles.RoleId, out: []model_roles.Selection) usize {
        const provider = self.provider;
        const label = provider.label();
        self.state.mutex.lockUncancelable(io_mod.getIo());
        defer self.state.mutex.unlock(io_mod.getIo());
        return model_roles.selectionChain(&self.state.table, role, .{
            .provider = label,
            .default_model = self.defaultModelLocked(label),
            .builtin_small = self.set.select(provider).title_model,
            .legacy_review = reviewerModelFor(self.set, provider, self.review_model),
            .configured = self.set.definitions,
            .known = self.known,
            .candidates = self.candidates,
        }, out);
    }

    /// Built-in convenience for callers that explicitly require the active
    /// provider's model string. Cross-provider selections are unavailable to
    /// this API; side calls must use `pickSelection` instead.
    pub fn pick(self: Host, role: Role) ?Picked {
        const selection = self.pickSelection(role) orelse return null;
        if (!std.ascii.eqlIgnoreCase(selection.provider.label(), self.provider.label())) return null;
        return .{ .model = selection.model, .effort = selection.effort };
    }

    pub fn resolve(self: Host, role: Role) ?[]const u8 {
        return if (self.pick(role)) |picked| picked.model else null;
    }

    /// The model for session titles: the title role, the provider's own
    /// low-cost model, then, as proto does, the session's model (D206).
    /// Null disables generated titles.
    pub fn titleSelection(self: Host) ?model_roles.Selection {
        if (self.pickSelection(.title)) |selection| return selection;
        if (self.set.select(self.provider).title_model) |model| return .{ .provider = self.provider, .model = model, .source = .{ .builtin = .title } };
        if (self.current_model.len == 0 or self.current_model[0] == '@') return null;
        return .{ .provider = self.provider, .model = self.current_model, .source = .{ .builtin = .default } };
    }

    pub fn titleModel(self: Host) ?[]const u8 {
        return if (self.titleSelection()) |selection| selection.model else null;
    }

    /// The web search side worker's model: the profile's small role when
    /// it sets one on this provider, else the session's model, as before
    /// roles (D213).
    pub fn workerSelection(self: Host) ?model_roles.Selection {
        self.state.mutex.lockUncancelable(io_mod.getIo());
        const configured = self.state.table.get(.small) != null;
        self.state.mutex.unlock(io_mod.getIo());
        if (configured) return self.pickSelection(.small);
        return if (self.current_model.len > 0 and self.current_model[0] != '@')
            .{ .provider = self.provider, .model = self.current_model, .source = .{ .builtin = .worker } }
        else
            null;
    }

    pub fn searchWorkerSelection(self: Host) ?model_roles.Selection {
        return self.workerSelection();
    }

    pub fn searchWorkerModel(self: Host) []const u8 {
        const configured = blk: {
            self.state.mutex.lockUncancelable(io_mod.getIo());
            defer self.state.mutex.unlock(io_mod.getIo());
            break :blk self.state.table.get(.small) != null;
        };
        if (!configured) return self.current_model;
        return self.resolve(.small) orelse self.current_model;
    }

    /// The permission reviewer's model; empty keeps the reviewer's default.
    pub fn reviewSelection(self: Host) ?model_roles.Selection {
        if (self.provider == .gateway and self.review_model.len > 0 and io_mod.getenv("FX_REVIEW_MODEL") != null)
            return .{ .provider = .gateway, .model = self.review_model, .source = .{ .builtin = .review } };
        return self.pickSelection(.review);
    }

    pub fn reviewModel(self: Host) []const u8 {
        // FX_REVIEW_MODEL, a gateway override, outranks the profile's role.
        if (self.provider == .gateway and self.review_model.len > 0 and io_mod.getenv("FX_REVIEW_MODEL") != null) return self.review_model;
        return self.resolve(.review) orelse "";
    }

    /// The compactor's summary model. A model-level compaction target takes
    /// precedence over the role fallback, matching provider metadata policy.
    pub fn compactSelection(self: Host) ?model_roles.Selection {
        if (self.set.modelMetadata(self.provider, self.current_model)) |metadata|
            if (metadata.compaction_model) |target_text| {
                const ref = model_roles.parseRefId(target_text, .{ .builtin = .compact }, self.set.definitions);
                const provider = model_provider.parse(ref.provider orelse self.provider.label()) orelse return self.pickSelection(.compact);
                if (ref.model.len > 0) return .{
                    .provider = provider,
                    .model = ref.model,
                    .effort = ref.effort,
                    .routing = ref.routing,
                    .source = .{ .builtin = .compact },
                };
            };
        return self.pickSelection(.compact);
    }

    pub fn compactModel(self: Host) []const u8 {
        return self.resolve(.compact) orelse "";
    }

    /// Resolves a fleet worker's `@role` model request, including custom
    /// names and provider identity.
    pub fn lookup(self: Host, name: []const u8) Lookup {
        const role_name = if (name.len > 0 and name[0] == '@') name[1..] else name;
        const role = model_roles.parseRoleId(role_name) orelse return .unknown_role;
        const known = switch (role) {
            .builtin => true,
            .custom => self.state.table.hasRole(role),
        };
        if (!known) return .unknown_role;
        return if (self.pickSelectionId(role)) |selection| .{ .selection = selection } else .unavailable;
    }

    pub fn rolesForIds(self: Host, alloc: Allocator, model: []const u8) ![]model_roles.RoleId {
        self.state.mutex.lockUncancelable(io_mod.getIo());
        const ids = try self.state.table.roleIds(alloc);
        self.state.mutex.unlock(io_mod.getIo());
        defer alloc.free(ids);
        var out = try alloc.alloc(model_roles.RoleId, ids.len);
        var count: usize = 0;
        for (ids) |id| {
            if (id != .builtin or id.builtin != .default) if (self.state.table.getId(id) == null) continue;
            const selection = self.pickSelectionId(id) orelse continue;
            if (!std.mem.eql(u8, selection.model, model)) continue;
            out[count] = id;
            count += 1;
        }
        return out[0..count];
    }

    /// Built-in projection used by legacy command completion. Dynamic callers
    /// use `rolesForIds`.
    pub fn rolesFor(self: Host, model: []const u8, out: *[model_roles.role_count]Role) usize {
        var count: usize = 0;
        for (model_roles.all_roles) |role| {
            if (role != .default and self.state.table.get(role) == null) continue;
            const picked = self.pick(role) orelse continue;
            if (!std.mem.eql(u8, picked.model, model)) continue;
            out[count] = role;
            count += 1;
        }
        return count;
    }
};

pub const Picked = model_roles.Picked;

/// Returns the review model for a provider, honoring the explicit Gateway
/// setting first and then native/catalog provider policy. Native overrides
/// cover providers such as Codex and Grok that have no Definition entry.
fn reviewerModelFor(set: provider_set.Set, provider: model_provider.ProviderId, legacy: []const u8) ?[]const u8 {
    if (provider == .gateway and legacy.len > 0) return legacy;
    const label = provider.label();
    for (set.native_overrides) |overrides| {
        if (std.ascii.eqlIgnoreCase(overrides.id, label)) return overrides.reviewer_model;
    }
    for (set.definitions) |definition| {
        if (std.ascii.eqlIgnoreCase(definition.id, label)) return definition.reviewer_model;
    }
    return null;
}

/// Binds one provider-qualified role selection to the host's transport and
/// credential. The returned binding borrows `arena`, so callers can use it for
/// the complete request/compaction attempt and release the arena afterward.
pub fn bindSelection(app: anytype, arena: Allocator, selection: model_roles.Selection) anyerror!?agent_runtime.ModelBinding {
    const App = @TypeOf(app.*);
    if (comptime !@hasField(App, "auth")) return null;
    const active_provider = provider_runtime.provider(app);
    const bundle: ?provider_set.Bundle = if (comptime @hasDecl(App, "providerSet"))
        app.providerSet().select(selection.provider)
    else if (selection.provider.eql(active_provider))
        null
    else
        return null;
    const stream = if (bundle) |value|
        value.agent_stream_or_unavailable()
    else if (comptime @hasDecl(App, "agentStreamProvider"))
        app.agentStreamProvider()
    else
        agent_stream_provider.unavailable_provider;
    const credential: agent_stream_provider.CredentialLease = if (selection.provider.eql(active_provider)) blk: {
        if (app.auth.credentialSource() == .host_managed) break :blk .host_managed;
        break :blk .{ .direct = .{
            .secret_bytes = app.auth.apiKey() orelse "",
            .source = app.auth.credentialSource(),
            .account_id = app.auth.accountId(),
            .tenant_context = app.auth.gatewayTeam(),
        } };
    } else blk: {
        if (comptime !@hasDecl(@TypeOf(app.auth), "oauthTransport") or !@hasDecl(@TypeOf(app.auth), "secretStore")) return null;
        const prepared = auth_runtime.prepareCredential(
            arena,
            app.auth.oauthTransport(),
            app.auth.secretStore(),
            selection.provider,
            null,
        ) catch return null;
        const value = prepared orelse return null;
        break :blk .{ .direct = .{
            .secret_bytes = value.token,
            .source = value.source,
            .account_id = value.accountId(),
            .tenant_context = value.gatewayTeam(),
        } };
    };
    const capabilities = if (comptime @hasDecl(App, "providerSet"))
        app.providerSet().modelCapabilities(selection.provider, selection.model)
    else if (bundle) |value|
        value.fallbackModelCapabilities(selection.model)
    else
        model_capabilities.capabilitiesForModel(selection.model);
    return .{
        .selection = selection,
        .stream_provider = stream,
        .credential = credential,
        .capabilities = capabilities,
        .provider_options = model_capabilities.resolveProviderOptionsForCapabilities(
            capabilities,
            selection.effort orelse .auto,
            false,
        ),
    };
}

pub const SideCall = struct {
    selection: model_roles.Selection,
    attempt: usize,
};

pub const SideCallFn = *const fn (?*anyopaque, SideCall) anyerror!void;

pub const FallbackError = error{ NoUsableRoleSelection, Cancelled };

/// Executes a role's provider-qualified candidate chain. The callback owns
/// transport/credential acquisition for the selection; runtime fallback is
/// deliberately separate from provider-native fallback request fields.
pub fn dispatchFallback(host_view: Host, role: model_roles.RoleId, context: ?*anyopaque, run: SideCallFn) anyerror!void {
    var candidates: [64]model_roles.Selection = undefined;
    const count = host_view.selectionChain(role, &candidates);
    if (count == 0) return error.NoUsableRoleSelection;
    var last_error: ?anyerror = null;
    for (candidates[0..count], 0..) |selection, index| {
        run(context, .{ .selection = selection, .attempt = index }) catch |err| {
            if (err == error.Cancelled) return error.Cancelled;
            last_error = err;
            continue;
        };
        return;
    }
    return last_error orelse error.NoUsableRoleSelection;
}

pub const Lookup = union(enum) {
    /// Provider-qualified role selection. Consumers that only support the
    /// active provider may inspect `model`; side-call consumers use this.
    selection: model_roles.Selection,
    model: Picked,
    unknown_role,
    /// The role resolves to nothing, or to another provider.
    unavailable,
};

/// The app's host view. In a detached frontend the session's model comes
/// from the backend.
pub fn host(app: anytype) Host {
    const App = @TypeOf(app.*);
    const view_model = if (comptime @hasDecl(App, "backend") or @hasField(App, "backend"))
        session_backend.Ops(App).view(app).model
    else
        null;
    return .{
        .state = @constCast(&app.model_roles),
        .provider = provider_runtime.provider(app),
        .current_model = view_model orelse provider_runtime.model(app),
        // A detached frontend does not track the backend's level.
        .current_effort = if (comptime @hasField(App, "effort")) if (view_model == null) app.effort else null else null,
        .set = app.providerSet(),
        .review_model = app.review_model,
        .candidates = if (comptime @hasField(App, "model_role_candidates")) app.model_role_candidates else &.{},
        .known = if (comptime @hasField(App, "model_cache")) .{
            .context = @ptrCast(@constCast(&app.model_cache)),
            .known_fn = knownInCache(@TypeOf(app.model_cache)),
            .known_for_fn = if (comptime @hasDecl(@TypeOf(app.model_cache), "knowsModelFor")) knownForInCache(@TypeOf(app.model_cache)) else null,
        } else null,
    };
}

fn knownForInCache(comptime Cache: type) *const fn (?*anyopaque, []const u8, []const u8) bool {
    return struct {
        fn known(raw: ?*anyopaque, provider: []const u8, model: []const u8) bool {
            const cache: *Cache = @ptrCast(@alignCast(raw.?));
            const id = model_provider.parse(provider) orelse return true;
            return cache.knowsModelFor(id, model);
        }
    }.known;
}

fn knownInCache(comptime Cache: type) *const fn (?*anyopaque, []const u8) bool {
    return struct {
        fn known(raw: ?*anyopaque, model: []const u8) bool {
            const cache: *Cache = @ptrCast(@alignCast(raw.?));
            return cache.knowsModel(model);
        }
    }.known;
}

pub fn resolveSelection(app: anytype, role: model_roles.RoleId) ?model_roles.Selection {
    return host(app).pickSelectionId(role);
}

pub fn selectionChain(app: anytype, role: model_roles.RoleId, out: []model_roles.Selection) usize {
    return host(app).selectionChain(role, out);
}

pub fn titleSelection(app: anytype) ?model_roles.Selection {
    return host(app).titleSelection();
}
pub fn tinySelection(app: anytype) ?model_roles.Selection {
    return host(app).pickSelection(.tiny);
}
pub fn workerSelection(app: anytype) ?model_roles.Selection {
    return host(app).workerSelection();
}
pub fn reviewSelection(app: anytype) ?model_roles.Selection {
    return host(app).reviewSelection();
}
pub fn compactSelection(app: anytype) ?model_roles.Selection {
    return host(app).compactSelection();
}

pub fn resolveModel(app: anytype, role: Role) ?[]const u8 {
    return host(app).resolve(role);
}

pub fn titleModel(app: anytype) ?[]const u8 {
    return host(app).titleModel();
}

pub fn searchWorkerModel(app: anytype) []const u8 {
    return host(app).searchWorkerModel();
}

pub fn workerProvider(app: anytype) model_provider.ProviderId {
    return if (host(app).workerSelection()) |selection| selection.provider else provider_runtime.provider(app);
}

pub fn reviewModel(app: anytype) []const u8 {
    return host(app).reviewModel();
}

pub fn compactModel(app: anytype) []const u8 {
    return host(app).compactModel();
}

pub fn lookup(app: anytype, name: []const u8) Lookup {
    return host(app).lookup(name);
}

pub fn rolesFor(app: anytype, model: []const u8, out: *[model_roles.role_count]Role) usize {
    return host(app).rolesFor(model, out);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const usage = "usage: /role [next|prev|<role> [model[:level], fallback…|@role|clear]]";

        /// `/role`: lists roles, assigns one, or cycles.
        pub fn handle(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            var words = std.mem.tokenizeAny(u8, trimmed, " \t");
            const first = words.next() orelse return writeTable(app);
            if (std.mem.eql(u8, first, "next")) return cycle(app, false);
            if (std.mem.eql(u8, first, "prev")) return cycle(app, true);
            const role = model_roles.parseRoleId(first) orelse {
                return app.writeDomainNotice(.{ .topic = "role", .tone = .@"error", .body = usage }, true);
            };
            const value_text = std.mem.trim(u8, trimmed[first.len..], " \t");
            if (value_text.len == 0) return assignId(app, role, provider_runtime.model(app));
            if (std.mem.eql(u8, value_text, "clear")) return assignId(app, role, null);
            return assignId(app, role, value_text);
        }

        /// Saves a dynamic role in the profile and applies it, without a notice.
        pub fn saveId(app: *App, role: model_roles.RoleId, value: ?[]const u8) !bool {
            if (value) |text| model_roles.validateChain(text) catch {
                try app.writeDomainNotice(.{ .topic = "role", .tone = .@"error", .body = "That is not a model reference." }, true);
                return false;
            };
            const owned = if (value) |text| try app.alloc.dupe(u8, text) else null;
            defer if (owned) |bytes| app.alloc.free(bytes);
            const patch_role: config_runtime.UserSettingsPatch = .{ .model_role = .{
                .role = switch (role) {
                    .builtin => |builtin| builtin,
                    .custom => .default,
                },
                .name = switch (role) {
                    .builtin => null,
                    .custom => |name| name,
                },
                .value = owned,
            } };
            var attempt = config_runtime.attemptUserPreferences(app.alloc, patch_role);
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| {
                    try session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false);
                    return false;
                },
                .outcome => {},
            }
            try app.model_roles.assignId(app.alloc, role, owned);
            return true;
        }

        /// Saves a builtin role in the profile and applies it, without a notice.
        pub fn save(app: *App, role: Role, value: ?[]const u8) !bool {
            return saveId(app, .{ .builtin = role }, value);
        }

        pub fn assignId(app: *App, role: model_roles.RoleId, value: ?[]const u8) !void {
            if (!try saveId(app, role, value)) return;
            const body = if (value) |text|
                try app.alloc.print("{s} → {s}", .{ role.label(), text })
            else
                try app.alloc.print("{s} cleared", .{role.label()});
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = body }, true);
        }

        pub fn assign(app: *App, role: Role, value: ?[]const u8) !void {
            return assignId(app, .{ .builtin = role }, value);
        }

        /// Switches the session to the next role's model in `cycle_order`.
        pub fn cycle(app: *App, backward: bool) !void {
            const view = host(app);
            const step = cycleStep(view, backward) orelse {
                return app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = "No other role has a model on this provider. Assign one with /role <role> <model>." }, true);
            };
            const model = try app.alloc.dupe(u8, step.model);
            defer app.alloc.free(model);
            try session_backend.Ops(App).selectModel(app, .{
                .model = model,
                .effort = step.effort orelse app.effort,
                .fast_mode = app.fast_mode,
                .ultrafast_mode = app.worker.agent_turn_settings.ultrafast_mode,
            });
            app.model_roles.last_cycled = step.role;
            // A detached session takes the level as its own option.
            if (step.effort) |effort| if (comptime @hasField(App, "backend")) if (app.backend == .detached) {
                const command = try app.alloc.print("/effort {s}", .{effort.label()});
                defer app.alloc.free(command);
                if (comptime @hasDecl(App, "handleCommand")) try app.handleCommand(command);
            };
            const body = if (step.effort) |effort|
                try app.alloc.print("{s} · {s} · {s}", .{ step.role.label(), model, effort.label() })
            else
                try app.alloc.print("{s} · {s}", .{ step.role.label(), model });
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = body }, true);
        }

        fn writeTable(app: *App) !void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            const table = &app.model_roles.table;
            const ids = try table.roleIds(app.alloc);
            defer app.alloc.free(ids);
            for (ids, 0..) |role, index| {
                if (index > 0) try out.writer.writeByte('\n');
                const selection = host(app).pickSelectionId(role) orelse {
                    try out.writer.print("{s:<16} not set", .{role.label()});
                    continue;
                };
                try out.writer.print("{s:<16} {s}/{s}", .{ role.label(), selection.provider.label(), selection.model });
                if (table.getId(role)) |raw| if (!std.mem.eql(u8, raw, selection.model)) try out.writer.print("  {s}", .{raw});
            }
            try out.writer.writeAll("\ncycle     ");
            for (table.cycleOrderIds(), 0..) |role, index| {
                if (index > 0) try out.writer.writeAll(" → ");
                try out.writer.writeAll(role.label());
            }
            try app.writeDomainNotice(.{ .topic = "roles", .tone = .neutral, .body = out.written() }, true);
        }
    };
}

test "state assignment keeps replaced tables alive" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    try state.assign(alloc, .small, "fast");
    const borrowed = state.table.get(.small).?;
    try state.assign(alloc, .small, "faster");
    // The first assignment's bytes stay valid for borrowers.
    try std.testing.expectEqualStrings("fast", borrowed);
    try std.testing.expectEqualStrings("faster", state.table.get(.small).?);
    try state.assign(alloc, .small, null);
    try std.testing.expect(state.table.get(.small) == null);
}

test "cycling steps through roles with distinct models and tags list roles" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    try state.assign(alloc, .small, "fast");
    try state.assign(alloc, .deep, "careful");
    try state.assign(alloc, .worker, "@small");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .set = .{ .gateway = .{}, .codex = .{}, .grok = .{} } };
    // Default order: deep, default, small.
    try std.testing.expectEqualStrings("fast", cycleStep(view, false).?.model);
    view.current_model = "fast";
    try std.testing.expectEqualStrings("careful", cycleStep(view, false).?.model);
    view.current_model = "careful";
    try std.testing.expectEqualStrings("main", cycleStep(view, false).?.model);
    view.current_model = "main";
    try std.testing.expectEqualStrings("careful", cycleStep(view, true).?.model);
    // A model outside the order starts from the first role.
    view.current_model = "other";
    try std.testing.expectEqual(model_roles.RoleId{ .builtin = Role.deep }, cycleStep(view, false).?.role);

    var roles: [model_roles.role_count]Role = undefined;
    const count = view.rolesFor("fast", &roles);
    try std.testing.expectEqualSlices(Role, &.{ .small, .worker }, roles[0..count]);
    try std.testing.expectEqual(@as(usize, 1), view.rolesFor("main", &roles));
    const worker_lookup = view.lookup("worker");
    try std.testing.expect(worker_lookup == .selection);
    try std.testing.expectEqualStrings("fast", worker_lookup.selection.model);
    try std.testing.expect(view.lookup("nobody") == .unknown_role);
    try std.testing.expect(view.lookup("compact") == .unavailable);

    var lone: State = .{};
    defer lone.deinit(alloc);
    try lone.init(alloc, .{}, "gateway", "main");
    view.state = &lone;
    view.current_model = "main";
    try std.testing.expect(cycleStep(view, false) == null);
}

test "cycling reaches the default role when the deep role differs only in thinking level" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    state.default_effort = .auto;
    try state.assign(alloc, .small, "fast");
    try state.assign(alloc, .deep, "main:high");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .current_effort = .auto, .set = .{ .gateway = .{}, .codex = .{}, .grok = .{} } };
    // Order: deep, default, small. The session starts on the default.
    var step = cycleStep(view, false).?;
    try std.testing.expectEqual(model_roles.RoleId{ .builtin = Role.small }, step.role);
    state.last_cycled = step.role;
    view.current_model = "fast";
    view.current_effort = null;
    step = cycleStep(view, false).?;
    try std.testing.expectEqual(model_roles.RoleId{ .builtin = Role.deep }, step.role);
    try std.testing.expectEqualStrings("high", step.effort.?.label());
    state.last_cycled = step.role;
    view.current_model = "main";
    view.current_effort = types.ReasoningEffort.literal("high");
    step = cycleStep(view, false).?;
    try std.testing.expectEqual(model_roles.RoleId{ .builtin = Role.default }, step.role);
    try std.testing.expectEqualStrings("auto", step.effort.?.label());
    // A detached frontend knows no level; the last role still places it.
    view.current_effort = null;
    try std.testing.expectEqual(model_roles.RoleId{ .builtin = Role.default }, cycleStep(view, false).?.role);
    try std.testing.expectEqual(model_roles.RoleId{ .builtin = Role.small }, cycleStep(view, true).?.role);
    // Without a last role it is taken to be at the startup level, so roles
    // that differ from the default only in level still cycle.
    try state.assign(alloc, .small, "main:low");
    state.last_cycled = null;
    step = cycleStep(view, false).?;
    try std.testing.expectEqual(model_roles.RoleId{ .builtin = Role.small }, step.role);
    try std.testing.expectEqualStrings("low", step.effort.?.label());
}

test "the default role stays on the profile's model after the session switches" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    try state.assign(alloc, .small, "fast");
    // Alt+P moved the session to the small role's model.
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "fast", .set = .{ .gateway = .{}, .codex = .{}, .grok = .{} } };
    try std.testing.expectEqualStrings("main", view.defaultModel());
    var roles: [model_roles.role_count]Role = undefined;
    try std.testing.expectEqualSlices(Role, &.{.small}, roles[0..view.rolesFor("fast", &roles)]);
    try std.testing.expectEqualSlices(Role, &.{.default}, roles[0..view.rolesFor("main", &roles)]);
    // On another provider the default follows the session.
    view.provider = .codex;
    try std.testing.expectEqualStrings("fast", view.defaultModel());
}

test "compact selection honors provider-qualified metadata target" {
    const alloc = std.testing.allocator;
    var registry = try configured_provider.Registry.parse_json(alloc,
        \\{"small":{"protocol":"openai-responses","base_url":"http://localhost:12011/v1","auth":{"type":"none"},"model_metadata":{"source":{"compaction_model":"large/summary"}}},"large":{"protocol":"openai-responses","base_url":"http://localhost:12012/v1","auth":{"type":"none"},"model_metadata":{"summary":{"context_window":64000}}}}
    );
    defer registry.deinit(alloc);
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "small", "source");
    const set: provider_set.Set = .{ .gateway = .{}, .codex = .{}, .grok = .{}, .definitions = registry.definitions };
    const view: Host = .{ .state = &state, .provider = model_provider.parse("small").?, .current_model = "source", .set = set };
    const selection = view.compactSelection().?;
    try std.testing.expectEqualStrings("large", selection.provider.label());
    try std.testing.expectEqualStrings("summary", selection.model);
}

test "review falls back to the legacy gateway setting and titles to the bundle" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .set = .{ .gateway = .{ .title_model = "luna" }, .codex = .{}, .grok = .{} }, .review_model = "legacy" };
    try std.testing.expectEqualStrings("legacy", view.reviewModel());
    try std.testing.expectEqualStrings("luna", view.titleModel().?);
    try std.testing.expectEqualStrings("", view.compactModel());
    view.provider = .codex;
    try std.testing.expectEqualStrings("", view.reviewModel());
    try state.assign(alloc, .review, "codex/strict");
    try std.testing.expectEqualStrings("strict", view.reviewModel());
    try state.assign(alloc, .compact, "@small");
    try state.assign(alloc, .small, "codex-mini");
    try std.testing.expectEqualStrings("codex-mini", view.compactModel());
    try std.testing.expectEqualStrings("codex-mini", view.titleModel().?);
}

test "a provider without a low-cost model titles with the session's model" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "codex", "main");
    var view: Host = .{ .state = &state, .provider = .codex, .current_model = "gpt-main", .set = .{ .gateway = .{ .title_model = "luna" }, .codex = .{}, .grok = .{} } };
    try std.testing.expectEqualStrings("gpt-main", view.titleModel().?);
    view.current_model = "@default";
    try std.testing.expect(view.titleModel() == null);
}

test "the web search worker takes the profile's small role, else the session's model" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try state.init(alloc, .{}, "gateway", "main");
    var view: Host = .{ .state = &state, .provider = .gateway, .current_model = "main", .set = .{ .gateway = .{ .title_model = "luna" }, .codex = .{}, .grok = .{} } };
    // Without a small entry the session's model stays, not the bundle's.
    try std.testing.expectEqualStrings("main", view.searchWorkerModel());
    try state.assign(alloc, .small, "swift");
    try std.testing.expectEqualStrings("swift", view.searchWorkerModel());
    // A small model on another provider leaves the session's model.
    try state.assign(alloc, .small, "codex/mini");
    try std.testing.expectEqualStrings("main", view.searchWorkerModel());
    view.provider = .codex;
    try std.testing.expectEqualStrings("mini", view.searchWorkerModel());
    try state.assign(alloc, .small, null);
    try std.testing.expectEqualStrings("main", view.searchWorkerModel());
}
