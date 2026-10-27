//! Model roles: named slots that pick the model for one kind of work
//! (D170). The profile's `model_roles` maps a role to a model reference and
//! `cycle_order` lists the roles that Alt+P and `/role next` step through.
//!
//! A reference is one of:
//! - a bare model ID on the active provider, such as `gpt-5.4-mini` or the
//!   gateway's `openai/gpt-5`;
//! - `provider/model`, when the part before the first `/` names a provider
//!   fx knows (`gateway`, `codex`, `grok`, or a configured provider);
//! - `@role`, an alias of another role. Aliases may chain. A chain that
//!   comes back to a role it already visited, or names an unknown role,
//!   falls back to `default` (D171).
//!
//! An entry may list several references separated by commas, as proto's
//! `modelRoles` does: a fallback chain. The role takes the first one that
//! is usable now, on the active provider and known to its catalog, and
//! the first one when none is (D250). Any reference may end in a thinking
//! level, `gpt-5.5:high`, that applies when the role's model is used (D251).
//!
//! A role without an entry follows its built-in fallback: `title` and
//! `tiny` follow `small`, `small` uses the provider's own low-cost model, and
//! every other role leaves the choice to its consumer (the conversation's
//! model, or the reviewer's compiled default). The legacy `review_model`
//! setting fills `review` when the table has no entry for it (D172).

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const configured_provider = @import("configured_provider.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_ref_bytes: usize = 1024;

pub const Role = enum {
    default,
    small,
    deep,
    worker,
    tiny,
    review,
    title,
    compact,
    designer,
    commit,
    advisor,

    /// Accepts each role's name and proto's older names, `smol` for
    /// `small` and `slow` for `deep`, so proto-style settings keep working.
    pub fn parse(name: []const u8) ?Role {
        if (std.meta.stringToEnum(Role, name)) |role| return role;
        for (legacy_names) |legacy| if (std.mem.eql(u8, legacy.name, name)) return legacy.role;
        return null;
    }

    /// proto's name for this role when it differs, so a settings writer
    /// can drop the old key.
    pub fn legacyName(self: Role) ?[]const u8 {
        for (legacy_names) |legacy| if (legacy.role == self) return legacy.name;
        return null;
    }

    const LegacyName = struct { name: []const u8, role: Role };
    const legacy_names = [_]LegacyName{ .{ .name = "smol", .role = .small }, .{ .name = "slow", .role = .deep } };

    pub fn label(self: Role) []const u8 {
        return @tagName(self);
    }

    /// What the role is for, one line for `/role` and `fx models`.
    pub fn summary(self: Role) []const u8 {
        return switch (self) {
            .default => "the profile's default model",
            .small => "fast, low-cost work",
            .deep => "careful, high-reasoning work",
            .worker => "fleet workers that ask for @worker",
            .tiny => "the smallest side calls",
            .review => "automatic permission review",
            .title => "session titles",
            .compact => "context compaction summaries",
            .designer => "design work (stored for proto compatibility)",
            .commit => "commit messages (stored for proto compatibility)",
            .advisor => "advice (stored for proto compatibility)",
        };
    }
};

pub const role_count = @typeInfo(Role).@"enum".field_names.len;
pub const all_roles = std.enums.values(Role);

/// proto's default cycle order.
pub const default_cycle_order = [_]Role{ .deep, .default, .small };

pub const Error = error{ InvalidModelRolesType, InvalidModelRoleValue, InvalidCycleOrderType, InvalidCycleOrderValue, OutOfMemory };

/// The profile's role table. Owns every reference.
pub const Table = struct {
    values: [role_count]?[]u8 = @splat(null),
    cycle: [role_count]Role = undefined,
    cycle_len: usize = 0,
    /// Whether `cycle_order` was set; unset uses `default_cycle_order`.
    has_cycle: bool = false,

    pub fn deinit(self: *Table, alloc: Allocator) void {
        for (&self.values) |*value| if (value.*) |bytes| {
            alloc.free(bytes);
            value.* = null;
        };
        self.* = .{};
    }

    pub fn dupe(self: *const Table, alloc: Allocator) Allocator.Error!Table {
        var copy: Table = .{ .cycle = self.cycle, .cycle_len = self.cycle_len, .has_cycle = self.has_cycle };
        errdefer copy.deinit(alloc);
        for (self.values, 0..) |value, index| {
            if (value) |bytes| copy.values[index] = try alloc.dupe(u8, bytes);
        }
        return copy;
    }

    pub fn get(self: *const Table, role: Role) ?[]const u8 {
        return self.values[@backingInt(role)];
    }

    pub fn isEmpty(self: *const Table) bool {
        for (self.values) |value| if (value != null) return false;
        return !self.has_cycle;
    }

    /// Replaces `role`'s reference; null clears it.
    pub fn set(self: *Table, alloc: Allocator, role: Role, value: ?[]const u8) Error!void {
        const owned = if (value) |bytes| blk: {
            try validateChain(bytes);
            break :blk try alloc.dupe(u8, bytes);
        } else null;
        const slot = &self.values[@backingInt(role)];
        if (slot.*) |old| alloc.free(old);
        slot.* = owned;
    }

    pub fn cycleOrder(self: *const Table) []const Role {
        return if (self.has_cycle) self.cycle[0..self.cycle_len] else &default_cycle_order;
    }

    /// Parses `model_roles` (an object) and `cycle_order` (an array of role
    /// names). Unknown role names in `model_roles` are ignored with a trace,
    /// so a proto profile with custom roles still loads.
    pub fn parse(alloc: Allocator, roles_value: ?std.json.Value, cycle_value: ?std.json.Value) Error!Table {
        var table: Table = .{};
        errdefer table.deinit(alloc);
        if (roles_value) |value| {
            if (value != .object) return error.InvalidModelRolesType;
            var entries = value.object.iterator();
            while (entries.next()) |entry| {
                const role = Role.parse(entry.key_ptr.*) orelse {
                    debug_trace.logf("config", "ignoring unknown model role={s}", .{entry.key_ptr.*});
                    continue;
                };
                // The role's own name wins over proto's older one.
                if (!std.mem.eql(u8, entry.key_ptr.*, role.label()) and value.object.contains(role.label())) continue;
                if (entry.value_ptr.* == .null) continue;
                if (entry.value_ptr.* != .string) return error.InvalidModelRoleValue;
                const trimmed = std.mem.trim(u8, entry.value_ptr.string, " \t\r\n");
                if (trimmed.len == 0) continue;
                validateChain(trimmed) catch return error.InvalidModelRoleValue;
                try table.set(alloc, role, trimmed);
            }
        }
        if (cycle_value) |value| {
            if (value != .array) return error.InvalidCycleOrderType;
            table.has_cycle = true;
            for (value.array.items) |item| {
                if (item != .string) return error.InvalidCycleOrderValue;
                const role = Role.parse(item.string) orelse {
                    debug_trace.logf("config", "ignoring unknown cycle_order role={s}", .{item.string});
                    continue;
                };
                if (std.mem.findScalar(Role, table.cycle[0..table.cycle_len], role) != null) continue;
                table.cycle[table.cycle_len] = role;
                table.cycle_len += 1;
            }
        }
        return table;
    }

    /// A later settings layer replaces each role it names and the whole
    /// cycle order when it sets one. Takes ownership of `incoming`'s values.
    pub fn overlay(self: *Table, alloc: Allocator, incoming: *Table) void {
        for (&incoming.values, 0..) |*value, index| {
            if (value.*) |bytes| {
                if (self.values[index]) |old| alloc.free(old);
                self.values[index] = bytes;
                value.* = null;
            }
        }
        if (incoming.has_cycle) {
            self.cycle = incoming.cycle;
            self.cycle_len = incoming.cycle_len;
            self.has_cycle = true;
        }
    }
};

/// Checks a whole entry: one or more references separated by commas.
pub fn validateChain(value: []const u8) error{InvalidModelRoleValue}!void {
    if (value.len == 0 or value.len > max_ref_bytes) return error.InvalidModelRoleValue;
    if (!std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n"))) return error.InvalidModelRoleValue;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try validateRef(trimmed);
        const entry = Entry.parse(trimmed);
        if (entry.ref.len == 0 or (entry.ref[0] == '@' and entry.ref.len == 1)) return error.InvalidModelRoleValue;
        count += 1;
    }
    if (count == 0) return error.InvalidModelRoleValue;
}

/// The most entries a chain keeps; later ones are ignored.
pub const max_chain = 8;

/// The thinking levels a reference may end in, after proto's suffixes.
const thinking_suffixes = [_][]const u8{ "auto", "off", "none", "minimal", "low", "medium", "high", "xhigh", "max" };

/// One reference of a chain and the thinking level it carries.
pub const Entry = struct {
    /// The reference without its level: a model, `provider/model` or `@role`.
    ref: []const u8,
    effort: ?types.ReasoningEffort = null,

    /// Splits a trailing `:level` off when it names a thinking level, so
    /// IDs such as `llama3:8b` or `model:free` stay whole.
    pub fn parse(text: []const u8) Entry {
        const colon = std.mem.findScalarLast(u8, text, ':') orelse return .{ .ref = text };
        const suffix = text[colon + 1 ..];
        for (thinking_suffixes) |name| {
            if (!std.ascii.eqlIgnoreCase(name, suffix)) continue;
            return .{ .ref = text[0..colon], .effort = types.ReasoningEffort.parse(suffix) };
        }
        return .{ .ref = text };
    }

    pub fn format(self: Entry, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.ref);
        if (self.effort) |effort| try writer.print(":{s}", .{effort.label()});
    }
};

/// The entries of a chain, in order, at most `max_chain`.
pub const Chain = struct {
    items: [max_chain]Entry = undefined,
    len: usize = 0,

    pub fn parse(value: []const u8) Chain {
        var chain: Chain = .{};
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            if (chain.len == max_chain) break;
            chain.items[chain.len] = Entry.parse(trimmed);
            chain.len += 1;
        }
        return chain;
    }

    pub fn entries(self: *const Chain) []const Entry {
        return self.items[0..self.len];
    }

    /// The chain as a settings value, entries joined by `, `; caller owns it.
    pub fn joinAlloc(self: *const Chain, alloc: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        for (self.entries(), 0..) |entry, index| {
            if (index > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
            entry.format(&out.writer) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }
};

pub fn validateRef(value: []const u8) error{InvalidModelRoleValue}!void {
    if (value.len == 0 or value.len > max_ref_bytes or !std.unicode.utf8ValidateSlice(value)) return error.InvalidModelRoleValue;
    if (!std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n"))) return error.InvalidModelRoleValue;
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidModelRoleValue;
    if (value[0] == '@' and value.len == 1) return error.InvalidModelRoleValue;
}

/// A resolved model. `provider` is null for the active provider.
pub const Ref = struct {
    provider: ?[]const u8 = null,
    model: []const u8,
    /// The role whose entry supplied the model, after aliases.
    source: Role,
    /// The thinking level the entry names; null keeps the consumer's.
    effort: ?types.ReasoningEffort = null,

    /// The model when it runs on `active`, the active provider's label.
    /// A reference to another provider gives null: side calls go through the
    /// active provider's connection.
    pub fn on(self: Ref, active: []const u8) ?[]const u8 {
        const provider = self.provider orelse return self.model;
        return if (std.mem.eql(u8, provider, active)) self.model else null;
    }
};

pub const Context = struct {
    /// The active provider's label, such as `gateway` or a configured name.
    provider: []const u8,
    /// The profile's default model on the active provider; `@default`.
    default_model: []const u8,
    /// The provider's built-in low-cost model, used for `small` when unset.
    builtin_small: ?[]const u8 = null,
    /// The legacy `review_model` setting, used for `review` when unset.
    legacy_review: ?[]const u8 = null,
    /// Configured providers, whose names may qualify a reference alongside
    /// `gateway`, `codex` and `grok`.
    configured: []const configured_provider.Definition = &.{},
    /// Says whether a model is known on the active provider. Without it,
    /// every model on the active provider counts as known.
    known: ?Known = null,
};

/// A role's model on the active provider and the thinking level its entry
/// names, if any (D251).
pub const Picked = struct { model: []const u8, effort: ?types.ReasoningEffort = null };

/// The active provider's catalog, as far as a chain needs it (D250).
pub const Known = struct {
    context: ?*anyopaque = null,
    /// Whether `model` is in the active provider's catalog. A catalog that
    /// has not loaded yet answers true, so a chain does not skip past a
    /// model only because nothing is known yet.
    known_fn: *const fn (?*anyopaque, model: []const u8) bool,
};

/// Whether `ref` can be used now: on the active provider and known there.
pub fn usable(ref: Ref, ctx: Context) bool {
    const model = ref.on(ctx.provider) orelse return false;
    const known = ctx.known orelse return true;
    return known.known_fn(known.context, model);
}

/// The model `role` picks, or null when the consumer keeps its own default.
/// A chain gives its first usable entry, else its first entry.
pub fn resolve(table: *const Table, role: Role, ctx: Context) ?Ref {
    return resolveIn(table, role, ctx, .empty);
}

fn resolveIn(table: *const Table, role: Role, ctx: Context, seen: std.enums.EnumSet(Role)) ?Ref {
    if (seen.contains(role)) {
        debug_trace.logf("config", "model role alias cycle at={s} fallback=default", .{role.label()});
        return defaultRef(ctx);
    }
    var visited = seen;
    visited.insert(role);
    const raw = table.get(role) orelse return switch (role) {
        .review => if (ctx.legacy_review) |model| .{ .model = model, .source = .review } else null,
        .title, .tiny => resolveIn(table, .small, ctx, visited),
        .small => if (ctx.builtin_small) |model| .{ .model = model, .source = .small } else null,
        .default => defaultRef(ctx),
        else => null,
    };
    const choice = choose(table, role, Chain.parse(raw), ctx, visited) orelse return null;
    return choice.ref;
}

const Choice = struct { ref: Ref, index: usize };

/// The chain's first usable entry; else its first entry on the active
/// provider, whose catalog may simply not list it; else its first entry.
fn choose(table: *const Table, role: Role, chain: Chain, ctx: Context, visited: std.enums.EnumSet(Role)) ?Choice {
    var on_provider: ?Choice = null;
    var first: ?Choice = null;
    for (chain.entries(), 0..) |entry, index| {
        var candidate = candidateFor(table, role, entry, ctx, visited) orelse continue;
        if (entry.effort) |effort| candidate.effort = effort;
        const choice: Choice = .{ .ref = candidate, .index = index };
        if (usable(candidate, ctx)) return choice;
        if (on_provider == null and candidate.on(ctx.provider) != null) on_provider = choice;
        if (first == null) first = choice;
    }
    return on_provider orelse first;
}

/// Which of `role`'s own entries it resolves to now, for the hub; null when
/// the role has no entry or what it picks is on another provider.
pub fn chosenEntry(table: *const Table, role: Role, ctx: Context) ?usize {
    const raw = table.get(role) orelse return null;
    var visited: std.enums.EnumSet(Role) = .empty;
    visited.insert(role);
    const choice = choose(table, role, Chain.parse(raw), ctx, visited) orelse return null;
    return if (choice.ref.on(ctx.provider) != null) choice.index else null;
}

fn candidateFor(table: *const Table, role: Role, entry: Entry, ctx: Context, visited: std.enums.EnumSet(Role)) ?Ref {
    if (entry.ref[0] != '@') return parseRef(entry.ref, role, ctx.configured);
    const target = Role.parse(entry.ref[1..]) orelse {
        debug_trace.logf("config", "model role alias unknown role={s} alias={s} fallback=default", .{ role.label(), entry.ref });
        return defaultRef(ctx);
    };
    return resolveIn(table, target, ctx, visited);
}

fn defaultRef(ctx: Context) ?Ref {
    if (ctx.default_model.len == 0) return null;
    return .{ .model = ctx.default_model, .source = .default };
}

const builtin_providers = [_][]const u8{ "gateway", "codex", "grok" };

/// Splits `provider/model` when the prefix names a provider fx knows.
pub fn parseRef(raw: []const u8, source: Role, configured: []const configured_provider.Definition) Ref {
    const slash = std.mem.findScalar(u8, raw, '/') orelse return .{ .model = raw, .source = source };
    if (slash + 1 == raw.len) return .{ .model = raw, .source = source };
    const prefix = raw[0..slash];
    var known = false;
    for (builtin_providers) |name| known = known or std.mem.eql(u8, name, prefix);
    for (configured) |definition| known = known or std.mem.eql(u8, definition.id, prefix);
    if (!known) return .{ .model = raw, .source = source };
    return .{ .provider = prefix, .model = raw[slash + 1 ..], .source = source };
}

fn parseFixture(alloc: Allocator, json: []const u8) !Table {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    return Table.parse(alloc, parsed.value.object.get("model_roles"), parsed.value.object.get("cycle_order"));
}

test "roles resolve bare, provider-qualified, and aliased references, under proto's older names too" {
    const alloc = std.testing.allocator;
    var table = try parseFixture(alloc,
        \\{"model_roles":{"smol":"cheap","worker":"@smol","slow":"codex/gpt-5.5","review":"openai/gpt-5","custom":"x"}}
    );
    defer table.deinit(alloc);
    const ctx: Context = .{ .provider = "gateway", .default_model = "main" };

    const worker = resolve(&table, .worker, ctx).?;
    try std.testing.expectEqualStrings("cheap", worker.model);
    try std.testing.expectEqual(Role.small, worker.source);
    try std.testing.expectEqualStrings("cheap", worker.on("gateway").?);

    const deep = resolve(&table, .deep, ctx).?;
    try std.testing.expectEqualStrings("codex", deep.provider.?);
    try std.testing.expectEqualStrings("gpt-5.5", deep.model);
    try std.testing.expect(deep.on("gateway") == null);

    // A gateway model ID whose prefix is not a provider stays whole.
    try std.testing.expectEqualStrings("openai/gpt-5", resolve(&table, .review, ctx).?.model);
    try std.testing.expectEqualStrings("main", resolve(&table, .default, ctx).?.model);
    // title and tiny follow small; compact keeps the conversation's model.
    try std.testing.expectEqualStrings("cheap", resolve(&table, .title, ctx).?.model);
    try std.testing.expectEqualStrings("cheap", resolve(&table, .tiny, ctx).?.model);
    try std.testing.expect(resolve(&table, .compact, ctx) == null);
}

test "alias cycles and unknown aliases fall back to default" {
    const alloc = std.testing.allocator;
    var table = try parseFixture(alloc,
        \\{"model_roles":{"small":"@tiny","tiny":"@small","worker":"@nobody","default":"@worker"}}
    );
    defer table.deinit(alloc);
    const ctx: Context = .{ .provider = "gateway", .default_model = "main" };
    const small = resolve(&table, .small, ctx).?;
    try std.testing.expectEqualStrings("main", small.model);
    try std.testing.expectEqual(Role.default, small.source);
    try std.testing.expectEqualStrings("main", resolve(&table, .worker, ctx).?.model);
    // default aliasing itself through worker ends at the profile model.
    try std.testing.expectEqualStrings("main", resolve(&table, .default, ctx).?.model);
    try std.testing.expect(resolve(&table, .default, .{ .provider = "gateway", .default_model = "" }) == null);
}

test "unset roles use built-in and legacy fallbacks" {
    var table: Table = .{};
    const ctx: Context = .{ .provider = "codex", .default_model = "gpt-5.5", .builtin_small = "gpt-5.6-luna", .legacy_review = "legacy-review" };
    try std.testing.expectEqualStrings("gpt-5.6-luna", resolve(&table, .title, ctx).?.model);
    try std.testing.expectEqualStrings("legacy-review", resolve(&table, .review, ctx).?.model);
    try std.testing.expect(resolve(&table, .worker, ctx) == null);
    try table.set(std.testing.allocator, .review, "explicit");
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("explicit", resolve(&table, .review, ctx).?.model);
}

test "configured provider labels qualify references" {
    const alloc = std.testing.allocator;
    var table = try parseFixture(alloc,
        \\{"model_roles":{"worker":"cento/cento-worker","small":"cento/"}}
    );
    defer table.deinit(alloc);
    const definitions = [_]configured_provider.Definition{.{ .id = "cento", .protocol = .@"openai-chat-completions", .base_url = "http://127.0.0.1:8394/v1", .auth = .none }};
    const ctx: Context = .{ .provider = "cento", .default_model = "claude-cento", .configured = &definitions };
    try std.testing.expectEqualStrings("cento-worker", resolve(&table, .worker, ctx).?.on("cento").?);
    // A trailing slash names no model, so it is a bare ID.
    try std.testing.expectEqualStrings("cento/", resolve(&table, .small, ctx).?.model);
}

test "parse rejects bad types and overlay replaces per role" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidModelRolesType, parseFixture(alloc, "{\"model_roles\":[]}"));
    try std.testing.expectError(error.InvalidModelRoleValue, parseFixture(alloc, "{\"model_roles\":{\"small\":1}}"));
    try std.testing.expectError(error.InvalidModelRoleValue, parseFixture(alloc, "{\"model_roles\":{\"small\":\"@\"}}"));
    try std.testing.expectError(error.InvalidCycleOrderType, parseFixture(alloc, "{\"cycle_order\":\"small\"}"));

    var base = try parseFixture(alloc, "{\"model_roles\":{\"small\":\"a\",\"deep\":\"b\"}}");
    defer base.deinit(alloc);
    var layer = try parseFixture(alloc, "{\"model_roles\":{\"small\":\"c\"},\"cycle_order\":[\"smol\",\"bogus\",\"deep\",\"small\"]}");
    defer layer.deinit(alloc);
    base.overlay(alloc, &layer);
    try std.testing.expectEqualStrings("c", base.get(.small).?);
    try std.testing.expectEqualStrings("b", base.get(.deep).?);
    try std.testing.expectEqualSlices(Role, &.{ .small, .deep }, base.cycleOrder());

    var copy = try base.dupe(alloc);
    defer copy.deinit(alloc);
    try std.testing.expectEqualStrings("c", copy.get(.small).?);
}

test "a role's own name wins over proto's older name for it" {
    const alloc = std.testing.allocator;
    var table = try parseFixture(alloc,
        \\{"model_roles":{"smol":"old","small":"new","slow":"careful"}}
    );
    defer table.deinit(alloc);
    try std.testing.expectEqualStrings("new", table.get(.small).?);
    try std.testing.expectEqualStrings("careful", table.get(.deep).?);
    try std.testing.expectEqual(Role.small, Role.parse("smol").?);
    try std.testing.expectEqualStrings("smol", Role.small.legacyName().?);
    try std.testing.expect(Role.worker.legacyName() == null);
}

test "a chain takes its first usable entry and a level applies to the entry it ends" {
    const alloc = std.testing.allocator;
    var table = try parseFixture(alloc,
        \\{"model_roles":{"small":"codex/gpt-5.6-luna:low, cento-mini:high, cento-lite","worker":"@small:max","deep":"llama3:8b, gone"}}
    );
    defer table.deinit(alloc);
    const Catalog = struct {
        fn known(_: ?*anyopaque, model: []const u8) bool {
            return !std.mem.eql(u8, model, "cento-mini") and !std.mem.eql(u8, model, "gone");
        }
        fn empty(_: ?*anyopaque, _: []const u8) bool {
            return false;
        }
    };
    const definitions = [_]configured_provider.Definition{.{ .id = "cento", .protocol = .@"openai-chat-completions", .base_url = "http://127.0.0.1:8394/v1", .auth = .none }};
    var ctx: Context = .{ .provider = "cento", .default_model = "claude-cento", .configured = &definitions };

    // Without a catalog, the first entry on the active provider wins.
    const small = resolve(&table, .small, ctx).?;
    try std.testing.expectEqualStrings("cento-mini", small.model);
    try std.testing.expectEqualStrings("high", small.effort.?.label());
    // With one, an unknown model is skipped too.
    ctx.known = .{ .known_fn = Catalog.known };
    const lite = resolve(&table, .small, ctx).?;
    try std.testing.expectEqualStrings("cento-lite", lite.model);
    try std.testing.expect(lite.effort == null);
    // An alias's level replaces the target's.
    try std.testing.expectEqualStrings("max", resolve(&table, .worker, ctx).?.effort.?.label());
    // A suffix that is no level stays part of the ID.
    try std.testing.expectEqualStrings("llama3:8b", resolve(&table, .deep, ctx).?.model);
    // When the catalog lists none, the first entry on this provider stands.
    ctx.known = .{ .known_fn = Catalog.empty };
    try std.testing.expectEqualStrings("cento-mini", resolve(&table, .small, ctx).?.model);
    try std.testing.expectEqual(@as(?usize, 1), chosenEntry(&table, .small, ctx));
    // With none on this provider, the first entry stands, as before chains.
    var other = try parseFixture(alloc,
        \\{"model_roles":{"small":"codex/a, grok/b"}}
    );
    defer other.deinit(alloc);
    try std.testing.expectEqualStrings("codex", resolve(&other, .small, ctx).?.provider.?);
    try std.testing.expect(chosenEntry(&other, .small, ctx) == null);
}

test "chains parse, validate and join back" {
    const alloc = std.testing.allocator;
    const chain = Chain.parse("a:high, ,b ,@small:low");
    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqualStrings("@small", chain.entries()[2].ref);
    const joined = try chain.joinAlloc(alloc);
    defer alloc.free(joined);
    try std.testing.expectEqualStrings("a:high, b, @small:low", joined);
    try validateChain("a, b:xhigh");
    try std.testing.expectError(error.InvalidModelRoleValue, validateChain(" , "));
    try std.testing.expectError(error.InvalidModelRoleValue, validateChain("a, @"));
    try std.testing.expectError(error.InvalidModelRoleValue, validateChain("a, :high"));
    try std.testing.expectEqualStrings("model:free", Entry.parse("model:free").ref);
}
