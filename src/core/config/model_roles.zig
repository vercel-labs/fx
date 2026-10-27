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
//! A role without an entry follows its built-in fallback: `title` and
//! `tiny` follow `smol`, `smol` uses the provider's own low-cost model, and
//! every other role leaves the choice to its consumer (the conversation's
//! model, or the reviewer's compiled default). The legacy `review_model`
//! setting fills `review` when the table has no entry for it (D172).

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const configured_provider = @import("configured_provider.zig");

const Allocator = std.mem.Allocator;

pub const max_ref_bytes: usize = 1024;

pub const Role = enum {
    default,
    smol,
    slow,
    worker,
    tiny,
    review,
    title,
    compact,
    designer,
    commit,
    advisor,

    pub fn parse(name: []const u8) ?Role {
        return std.meta.stringToEnum(Role, name);
    }

    pub fn label(self: Role) []const u8 {
        return @tagName(self);
    }

    /// What the role is for, one line for `/role` and `fx models`.
    pub fn summary(self: Role) []const u8 {
        return switch (self) {
            .default => "the profile's default model",
            .smol => "fast, low-cost work",
            .slow => "careful, high-reasoning work",
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
pub const default_cycle_order = [_]Role{ .slow, .default, .smol };

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
            try validateRef(bytes);
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
                if (entry.value_ptr.* == .null) continue;
                if (entry.value_ptr.* != .string) return error.InvalidModelRoleValue;
                const trimmed = std.mem.trim(u8, entry.value_ptr.string, " \t\r\n");
                if (trimmed.len == 0) continue;
                validateRef(trimmed) catch return error.InvalidModelRoleValue;
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
    /// The provider's built-in low-cost model, used for `smol` when unset.
    builtin_smol: ?[]const u8 = null,
    /// The legacy `review_model` setting, used for `review` when unset.
    legacy_review: ?[]const u8 = null,
    /// Configured providers, whose names may qualify a reference alongside
    /// `gateway`, `codex` and `grok`.
    configured: []const configured_provider.Definition = &.{},
};

/// The model `role` picks, or null when the consumer keeps its own default.
pub fn resolve(table: *const Table, role: Role, ctx: Context) ?Ref {
    var visited: std.enums.EnumSet(Role) = .empty;
    var current = role;
    while (true) {
        if (visited.contains(current)) {
            debug_trace.logf("config", "model role alias cycle role={s} at={s} fallback=default", .{ role.label(), current.label() });
            return defaultRef(ctx);
        }
        visited.insert(current);
        const raw = table.get(current) orelse switch (current) {
            .review => ctx.legacy_review orelse return null,
            .title, .tiny => "@smol",
            .smol => return if (ctx.builtin_smol) |model| .{ .model = model, .source = .smol } else null,
            .default => return defaultRef(ctx),
            else => return null,
        };
        if (raw[0] == '@') {
            current = Role.parse(raw[1..]) orelse {
                debug_trace.logf("config", "model role alias unknown role={s} alias={s} fallback=default", .{ role.label(), raw });
                return defaultRef(ctx);
            };
            continue;
        }
        return parseRef(raw, current, ctx.configured);
    }
}

fn defaultRef(ctx: Context) ?Ref {
    if (ctx.default_model.len == 0) return null;
    return .{ .model = ctx.default_model, .source = .default };
}

const builtin_providers = [_][]const u8{ "gateway", "codex", "grok" };

fn parseRef(raw: []const u8, source: Role, configured: []const configured_provider.Definition) Ref {
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

test "roles resolve bare, provider-qualified, and aliased references" {
    const alloc = std.testing.allocator;
    var table = try parseFixture(alloc,
        \\{"model_roles":{"smol":"cheap","worker":"@smol","slow":"codex/gpt-5.5","review":"openai/gpt-5","custom":"x"}}
    );
    defer table.deinit(alloc);
    const ctx: Context = .{ .provider = "gateway", .default_model = "main" };

    const worker = resolve(&table, .worker, ctx).?;
    try std.testing.expectEqualStrings("cheap", worker.model);
    try std.testing.expectEqual(Role.smol, worker.source);
    try std.testing.expectEqualStrings("cheap", worker.on("gateway").?);

    const slow = resolve(&table, .slow, ctx).?;
    try std.testing.expectEqualStrings("codex", slow.provider.?);
    try std.testing.expectEqualStrings("gpt-5.5", slow.model);
    try std.testing.expect(slow.on("gateway") == null);

    // A gateway model ID whose prefix is not a provider stays whole.
    try std.testing.expectEqualStrings("openai/gpt-5", resolve(&table, .review, ctx).?.model);
    try std.testing.expectEqualStrings("main", resolve(&table, .default, ctx).?.model);
    // title and tiny follow smol; compact keeps the conversation's model.
    try std.testing.expectEqualStrings("cheap", resolve(&table, .title, ctx).?.model);
    try std.testing.expectEqualStrings("cheap", resolve(&table, .tiny, ctx).?.model);
    try std.testing.expect(resolve(&table, .compact, ctx) == null);
}

test "alias cycles and unknown aliases fall back to default" {
    const alloc = std.testing.allocator;
    var table = try parseFixture(alloc,
        \\{"model_roles":{"smol":"@tiny","tiny":"@smol","worker":"@nobody","default":"@worker"}}
    );
    defer table.deinit(alloc);
    const ctx: Context = .{ .provider = "gateway", .default_model = "main" };
    const smol = resolve(&table, .smol, ctx).?;
    try std.testing.expectEqualStrings("main", smol.model);
    try std.testing.expectEqual(Role.default, smol.source);
    try std.testing.expectEqualStrings("main", resolve(&table, .worker, ctx).?.model);
    // default aliasing itself through worker ends at the profile model.
    try std.testing.expectEqualStrings("main", resolve(&table, .default, ctx).?.model);
    try std.testing.expect(resolve(&table, .default, .{ .provider = "gateway", .default_model = "" }) == null);
}

test "unset roles use built-in and legacy fallbacks" {
    var table: Table = .{};
    const ctx: Context = .{ .provider = "codex", .default_model = "gpt-5.5", .builtin_smol = "gpt-5.6-luna", .legacy_review = "legacy-review" };
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
        \\{"model_roles":{"worker":"cento/cento-worker","smol":"cento/"}}
    );
    defer table.deinit(alloc);
    const definitions = [_]configured_provider.Definition{.{ .id = "cento", .protocol = .@"openai-chat-completions", .base_url = "http://127.0.0.1:8394/v1", .auth = .none }};
    const ctx: Context = .{ .provider = "cento", .default_model = "claude-cento", .configured = &definitions };
    try std.testing.expectEqualStrings("cento-worker", resolve(&table, .worker, ctx).?.on("cento").?);
    // A trailing slash names no model, so it is a bare ID.
    try std.testing.expectEqualStrings("cento/", resolve(&table, .smol, ctx).?.model);
}

test "parse rejects bad types and overlay replaces per role" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidModelRolesType, parseFixture(alloc, "{\"model_roles\":[]}"));
    try std.testing.expectError(error.InvalidModelRoleValue, parseFixture(alloc, "{\"model_roles\":{\"smol\":1}}"));
    try std.testing.expectError(error.InvalidModelRoleValue, parseFixture(alloc, "{\"model_roles\":{\"smol\":\"@\"}}"));
    try std.testing.expectError(error.InvalidCycleOrderType, parseFixture(alloc, "{\"cycle_order\":\"smol\"}"));

    var base = try parseFixture(alloc, "{\"model_roles\":{\"smol\":\"a\",\"slow\":\"b\"}}");
    defer base.deinit(alloc);
    var layer = try parseFixture(alloc, "{\"model_roles\":{\"smol\":\"c\"},\"cycle_order\":[\"smol\",\"bogus\",\"slow\",\"smol\"]}");
    defer layer.deinit(alloc);
    base.overlay(alloc, &layer);
    try std.testing.expectEqualStrings("c", base.get(.smol).?);
    try std.testing.expectEqualStrings("b", base.get(.slow).?);
    try std.testing.expectEqualSlices(Role, &.{ .smol, .slow }, base.cycleOrder());

    var copy = try base.dupe(alloc);
    defer copy.deinit(alloc);
    try std.testing.expectEqualStrings("c", copy.get(.smol).?);
}
