//! Dynamic model-role identity, selection and fallback policy.
//!
//! A role is intentionally not an enum slot: built-ins are convenient typed
//! names, while profile-defined names remain first-class values.  The table
//! owns every configured name and reference.  Resolved selections always carry
//! the provider that will execute the request; a model string is never enough
//! to identify a side call.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const configured_provider = @import("configured_provider.zig");
const model_provider = @import("model_provider.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_ref_bytes: usize = 1024;
pub const max_chain: usize = 8;
pub const max_role_bytes: usize = 128;
pub const max_selector_bytes: usize = 1024;

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

    pub fn parse(name: []const u8) ?Role {
        if (std.meta.stringToEnum(Role, name)) |role| return role;
        for (legacy_names) |legacy| if (std.ascii.eqlIgnoreCase(legacy.name, name)) return legacy.role;
        return null;
    }

    pub fn legacyName(self: Role) ?[]const u8 {
        for (legacy_names) |legacy| if (legacy.role == self) return legacy.name;
        return null;
    }

    const LegacyName = struct { name: []const u8, role: Role };
    const legacy_names = [_]LegacyName{
        .{ .name = "smol", .role = .small },
        .{ .name = "slow", .role = .deep },
    };

    pub fn label(self: Role) []const u8 {
        return @tagName(self);
    }

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
            .designer => "design work",
            .commit => "commit messages",
            .advisor => "advice",
        };
    }
};

pub const role_count = @typeInfo(Role).@"enum".field_names.len;
pub const all_roles = std.enums.values(Role);

pub const RoleId = union(enum) {
    builtin: Role,
    custom: []const u8,

    pub fn label(self: RoleId) []const u8 {
        return switch (self) {
            .builtin => |role| role.label(),
            .custom => |name| name,
        };
    }

    pub fn eql(self: RoleId, other: RoleId) bool {
        return switch (self) {
            .builtin => |role| switch (other) {
                .builtin => |candidate| role == candidate,
                .custom => false,
            },
            .custom => |name| switch (other) {
                .builtin => false,
                .custom => |candidate| std.mem.eql(u8, name, candidate),
            },
        };
    }

    pub fn fromBuiltin(role: Role) RoleId {
        return .{ .builtin = role };
    }
};

pub const default_cycle_order = [_]Role{ .deep, .default, .small };
const default_cycle_ids = [_]RoleId{ .{ .builtin = .deep }, .{ .builtin = .default }, .{ .builtin = .small } };

pub const Error = error{
    InvalidModelRolesType,
    InvalidModelRoleValue,
    InvalidCycleOrderType,
    InvalidCycleOrderValue,
    InvalidModelRoleBankType,
    InvalidModelRoleBankValue,
    InvalidModelTagsType,
    InvalidModelTagValue,
    InvalidFallbackChainsType,
    InvalidFallbackChainValue,
    InvalidRoleName,
    OutOfMemory,
};

pub const RoleEntry = struct {
    /// Empty for built-ins; custom names are owned by the table.
    name: []u8 = &.{},
    builtin: ?Role = null,
    value: ?[]u8 = null,

    pub fn id(self: *const RoleEntry) RoleId {
        return if (self.builtin) |role| .{ .builtin = role } else .{ .custom = self.name };
    }
};

pub const Tag = struct {
    role: RoleId,
    tag: []u8 = &.{},
    name: []u8 = &.{},
    color: []u8 = &.{},
    hidden: bool = false,
};

/// Borrowed tag fields accepted by mutation callers. The table copies every
/// string into its owned metadata entry before publishing the replacement.
pub const TagInput = struct {
    tag: []const u8 = "",
    name: []const u8 = "",
    color: []const u8 = "",
    hidden: bool = false,
};

pub const BankEntry = struct {
    role: RoleId,
    selectors: std.ArrayList([]u8) = .empty,
};

pub const FallbackEntry = struct {
    selector: []u8,
    chain: []u8,
};

/// The profile role table.  Built-in values and custom values share one
/// dynamic entry list; no fixed-size slot can discard a custom role.
pub const Table = struct {
    entries: std.ArrayList(RoleEntry) = .empty,
    cycle: std.ArrayList(RoleId) = .empty,
    has_cycle: bool = false,
    /// Stable builtin-only projection for legacy callers of cycleOrder().
    builtin_cycle: [role_count]Role = undefined,
    builtin_cycle_len: usize = 0,
    tags: std.ArrayList(Tag) = .empty,
    banks: std.ArrayList(BankEntry) = .empty,
    fallbacks: std.ArrayList(FallbackEntry) = .empty,

    pub fn deinit(self: *Table, alloc: Allocator) void {
        for (self.entries.items) |*entry| {
            if (entry.value) |value| alloc.free(value);
            if (entry.builtin == null and entry.name.len > 0) alloc.free(entry.name);
        }
        self.entries.deinit(alloc);
        for (self.cycle.items) |id| if (id == .custom and id.custom.len > 0) alloc.free(@constCast(id.custom));
        self.cycle.deinit(alloc);
        for (self.tags.items) |*tag| {
            if (tag.role == .custom and tag.role.custom.len > 0) alloc.free(@constCast(tag.role.custom));
            if (tag.tag.len > 0) alloc.free(tag.tag);
            if (tag.name.len > 0) alloc.free(tag.name);
            if (tag.color.len > 0) alloc.free(tag.color);
        }
        self.tags.deinit(alloc);
        for (self.banks.items) |*bank| {
            for (bank.selectors.items) |selector| alloc.free(selector);
            bank.selectors.deinit(alloc);
            if (bank.role == .custom and bank.role.custom.len > 0) alloc.free(@constCast(bank.role.custom));
        }
        self.banks.deinit(alloc);
        for (self.fallbacks.items) |entry| {
            alloc.free(entry.selector);
            alloc.free(entry.chain);
        }
        self.fallbacks.deinit(alloc);
        self.* = .{};
    }

    pub fn dupe(self: *const Table, alloc: Allocator) Allocator.Error!Table {
        var copy: Table = .{ .has_cycle = self.has_cycle };
        errdefer copy.deinit(alloc);
        for (self.entries.items) |entry| {
            const name: []u8 = if (entry.builtin == null) try alloc.dupe(u8, entry.name) else &.{};
            const value = if (entry.value) |bytes| try alloc.dupe(u8, bytes) else null;
            try copy.entries.append(alloc, .{ .name = name, .builtin = entry.builtin, .value = value });
        }
        for (self.cycle.items) |id| {
            const copy_id: RoleId = switch (id) {
                .builtin => id,
                .custom => .{ .custom = try alloc.dupe(u8, id.custom) },
            };
            try copy.cycle.append(alloc, copy_id);
        }
        copy.refreshBuiltinCycle();
        for (self.tags.items) |tag| {
            try copy.tags.append(alloc, .{
                .role = switch (tag.role) {
                    .builtin => tag.role,
                    .custom => .{ .custom = try alloc.dupe(u8, tag.role.custom) },
                },
                .tag = try alloc.dupe(u8, tag.tag),
                .name = try alloc.dupe(u8, tag.name),
                .color = try alloc.dupe(u8, tag.color),
                .hidden = tag.hidden,
            });
        }
        for (self.banks.items) |bank| {
            var copy_bank: BankEntry = .{ .role = switch (bank.role) {
                .builtin => bank.role,
                .custom => .{ .custom = try alloc.dupe(u8, bank.role.custom) },
            } };
            errdefer {
                for (copy_bank.selectors.items) |value| alloc.free(value);
                copy_bank.selectors.deinit(alloc);
            }
            for (bank.selectors.items) |value| try copy_bank.selectors.append(alloc, try alloc.dupe(u8, value));
            try copy.banks.append(alloc, copy_bank);
        }
        for (self.fallbacks.items) |entry| try copy.fallbacks.append(alloc, .{ .selector = try alloc.dupe(u8, entry.selector), .chain = try alloc.dupe(u8, entry.chain) });
        return copy;
    }

    fn findIndex(self: *const Table, role: RoleId) ?usize {
        for (self.entries.items, 0..) |entry, index| if (entry.id().eql(role)) return index;
        return null;
    }

    fn ensureRole(self: *Table, alloc: Allocator, role: RoleId) Error!void {
        if (self.findIndex(role) != null) return;
        switch (role) {
            .builtin => |builtin| try self.entries.append(alloc, .{ .builtin = builtin }),
            .custom => |name| {
                try validateRoleName(name);
                try self.entries.append(alloc, .{ .name = try alloc.dupe(u8, name) });
            },
        }
    }

    pub fn hasRole(self: *const Table, role: RoleId) bool {
        return switch (role) {
            .builtin => self.findIndex(role) != null or role.builtin == .default,
            .custom => self.findIndex(role) != null,
        };
    }

    pub fn getId(self: *const Table, role: RoleId) ?[]const u8 {
        const index = self.findIndex(role) orelse return null;
        return self.entries.items[index].value;
    }

    /// Built-in convenience lookup. Dynamic consumers use `getId`.
    pub fn get(self: *const Table, role: Role) ?[]const u8 {
        return self.getId(.{ .builtin = role });
    }

    pub fn customRoles(self: *const Table) []const RoleEntry {
        return self.entries.items;
    }

    /// Returns all configured role identities. Custom names borrow this table;
    /// only the returned slice is owned by the caller.
    pub fn roleIds(self: *const Table, alloc: Allocator) Allocator.Error![]RoleId {
        var out = try alloc.alloc(RoleId, role_count + self.entries.items.len);
        var len: usize = 0;
        for (all_roles) |role| {
            out[len] = .{ .builtin = role };
            len += 1;
        }
        for (self.entries.items) |entry| {
            if (entry.builtin != null) continue;
            out[len] = .{ .custom = entry.name };
            len += 1;
        }
        return out[0..len];
    }

    pub fn isEmpty(self: *const Table) bool {
        for (self.entries.items) |entry| if (entry.value != null) return false;
        return !self.has_cycle and self.tags.items.len == 0 and self.banks.items.len == 0 and self.fallbacks.items.len == 0;
    }

    pub fn setId(self: *Table, alloc: Allocator, role: RoleId, value: ?[]const u8) Error!void {
        if (value) |bytes| {
            try validateChain(bytes);
            try self.ensureRole(alloc, role);
        } else if (self.findIndex(role) == null) return;
        const index = self.findIndex(role).?;
        const owned = if (value) |bytes| try alloc.dupe(u8, bytes) else null;
        if (self.entries.items[index].value) |old| alloc.free(old);
        self.entries.items[index].value = owned;
    }

    /// Creates an empty custom role (or confirms an existing role).
    /// The hub uses this before assigning the first model so role identity is
    /// durable even when the user has not picked a model yet.
    pub fn createRole(self: *Table, alloc: Allocator, role: RoleId) Error!void {
        try self.ensureRole(alloc, role);
    }

    /// Removes a role identity and every piece of role metadata attached to it.
    /// Built-in identities remain available and are only cleared by setId(null).
    pub fn deleteRole(self: *Table, alloc: Allocator, role: RoleId) Error!void {
        if (role == .builtin) return error.InvalidRoleName;
        if (self.findIndex(role)) |index| {
            const entry = self.entries.orderedRemove(index);
            if (entry.value) |value| alloc.free(value);
            if (entry.name.len > 0) alloc.free(entry.name);
        }
        var cycle_index: usize = 0;
        while (cycle_index < self.cycle.items.len) {
            if (self.cycle.items[cycle_index].eql(role)) {
                const id = self.cycle.orderedRemove(cycle_index);
                if (id == .custom) alloc.free(@constCast(id.custom));
            } else cycle_index += 1;
        }
        var tag_index: usize = 0;
        while (tag_index < self.tags.items.len) {
            if (self.tags.items[tag_index].role.eql(role)) {
                var tag = self.tags.orderedRemove(tag_index);
                tagDeinit(alloc, &tag);
            } else tag_index += 1;
        }
        var bank_index: usize = 0;
        while (bank_index < self.banks.items.len) {
            if (self.banks.items[bank_index].role.eql(role)) {
                var bank = self.banks.orderedRemove(bank_index);
                bankDeinit(alloc, &bank);
            } else bank_index += 1;
        }
    }

    pub fn setTagInput(self: *Table, alloc: Allocator, role: RoleId, input: TagInput) Error!void {
        try self.ensureRole(alloc, role);
        var copy: Tag = .{ .role = try ownedRoleId(alloc, role), .hidden = input.hidden };
        errdefer tagDeinit(alloc, &copy);
        copy.tag = try alloc.dupe(u8, input.tag);
        copy.name = try alloc.dupe(u8, input.name);
        copy.color = try alloc.dupe(u8, input.color);
        try self.replaceTag(alloc, copy);
    }

    pub fn setTag(self: *Table, alloc: Allocator, role: RoleId, tag: Tag) Error!void {
        return self.setTagInput(alloc, role, .{ .tag = tag.tag, .name = tag.name, .color = tag.color, .hidden = tag.hidden });
    }

    pub fn clearTag(self: *Table, alloc: Allocator, role: RoleId) void {
        for (self.tags.items, 0..) |*tag, index| if (tag.role.eql(role)) {
            var old = self.tags.orderedRemove(index);
            tagDeinit(alloc, &old);
            return;
        };
    }

    pub fn setBank(self: *Table, alloc: Allocator, role: RoleId, selectors: []const []const u8) Error!void {
        try self.ensureRole(alloc, role);
        var bank: BankEntry = .{ .role = try ownedRoleId(alloc, role) };
        errdefer bankDeinit(alloc, &bank);
        for (selectors) |selector| {
            try validateSelector(selector);
            var duplicate = false;
            for (bank.selectors.items) |old| {
                if (std.mem.eql(u8, old, selector)) {
                    duplicate = true;
                }
            }
            if (!duplicate) try bank.selectors.append(alloc, try alloc.dupe(u8, selector));
        }
        try self.replaceBank(alloc, bank);
    }

    pub fn clearBank(self: *Table, alloc: Allocator, role: RoleId) void {
        for (self.banks.items, 0..) |*bank, index| if (bank.role.eql(role)) {
            var old = self.banks.orderedRemove(index);
            bankDeinit(alloc, &old);
            return;
        };
    }

    pub fn setFallback(self: *Table, alloc: Allocator, selector: []const u8, chain: []const u8) Error!void {
        try validateSelector(selector);
        try validateChain(chain);
        try self.replaceFallback(alloc, selector, chain);
    }

    pub fn clearFallback(self: *Table, alloc: Allocator, selector: []const u8) void {
        for (self.fallbacks.items, 0..) |entry, index| if (std.ascii.eqlIgnoreCase(entry.selector, selector)) {
            const old = self.fallbacks.orderedRemove(index);
            alloc.free(old.selector);
            alloc.free(old.chain);
            return;
        };
    }

    pub fn set(self: *Table, alloc: Allocator, role: Role, value: ?[]const u8) Error!void {
        return self.setId(alloc, .{ .builtin = role }, value);
    }

    pub fn cycleOrderIds(self: *const Table) []const RoleId {
        return if (self.has_cycle) self.cycle.items else &default_cycle_ids;
    }

    /// Legacy builtin-only projection for callers that explicitly operate on
    /// builtin roles. A custom cycle must use `cycleOrderIds`.
    pub fn cycleOrder(self: *const Table) []const Role {
        if (!self.has_cycle) return &default_cycle_order;
        return self.builtin_cycle[0..self.builtin_cycle_len];
    }

    pub fn builtinCycleOrder(self: *const Table, out: *[role_count]Role) []const Role {
        _ = out;
        return self.cycleOrder();
    }

    pub fn setCycleIds(self: *Table, alloc: Allocator, order: []const RoleId) Error!void {
        if (order.len > role_count + self.entries.items.len) return error.InvalidCycleOrderValue;
        var next: std.ArrayList(RoleId) = .empty;
        errdefer {
            for (next.items) |id| if (id == .custom) alloc.free(@constCast(id.custom));
            next.deinit(alloc);
        }
        for (order) |id| {
            if (!self.hasRole(id)) try self.ensureRole(alloc, id);
            var duplicate = false;
            for (next.items) |old| {
                if (old.eql(id)) {
                    duplicate = true;
                }
            }
            if (duplicate) continue;
            try next.append(alloc, switch (id) {
                .builtin => id,
                .custom => .{ .custom = try alloc.dupe(u8, id.custom) },
            });
        }
        for (self.cycle.items) |id| if (id == .custom) alloc.free(@constCast(id.custom));
        self.cycle.deinit(alloc);
        self.cycle = next;
        self.has_cycle = true;
        self.refreshBuiltinCycle();
    }

    fn refreshBuiltinCycle(self: *Table) void {
        self.builtin_cycle_len = 0;
        if (!self.has_cycle or self.cycle.items.len > role_count) return;
        for (self.cycle.items, 0..) |id, index| switch (id) {
            .builtin => |role| self.builtin_cycle[index] = role,
            .custom => return,
        };
        self.builtin_cycle_len = self.cycle.items.len;
    }

    pub fn setCycle(self: *Table, alloc: Allocator, order: []const Role) Error!void {
        var ids: [role_count]RoleId = undefined;
        for (order, 0..) |role, index| ids[index] = .{ .builtin = role };
        return self.setCycleIds(alloc, ids[0..order.len]);
    }

    pub fn tagFor(self: *const Table, role: RoleId) ?*const Tag {
        for (self.tags.items) |*tag| if (tag.role.eql(role)) return tag;
        return null;
    }

    pub fn bankFor(self: *const Table, role: RoleId) ?[]const []u8 {
        for (self.banks.items) |*bank| if (bank.role.eql(role)) return bank.selectors.items;
        return null;
    }

    pub fn fallbackFor(self: *const Table, selector: []const u8) ?[]const u8 {
        for (self.fallbacks.items) |entry| if (std.ascii.eqlIgnoreCase(entry.selector, selector)) return entry.chain;
        return null;
    }

    pub fn fallbackForGlob(self: *const Table, selector: []const u8) ?[]const u8 {
        for (self.fallbacks.items) |entry| if (globMatch(entry.selector, selector)) return entry.chain;
        return null;
    }

    /// Parses all role-related profile settings. The old three-argument form
    /// remains the canonical builtin-only entry point; callers with proto's
    /// extended settings pass the optional values through this method.
    pub fn parse(alloc: Allocator, roles_value: ?std.json.Value, cycle_value: ?std.json.Value) Error!Table {
        return parseExtended(alloc, roles_value, cycle_value, null, null, null);
    }

    pub fn parseExtended(
        alloc: Allocator,
        roles_value: ?std.json.Value,
        cycle_value: ?std.json.Value,
        bank_value: ?std.json.Value,
        tags_value: ?std.json.Value,
        fallback_value: ?std.json.Value,
    ) Error!Table {
        var table: Table = .{};
        errdefer table.deinit(alloc);
        if (roles_value) |value| {
            if (value != .object) return error.InvalidModelRolesType;
            var iterator = value.object.iterator();
            while (iterator.next()) |item| {
                const id = parseRoleId(item.key_ptr.*) orelse return error.InvalidRoleName;
                // Canonical builtin name wins over its proto alias.
                if (id == .builtin and !std.mem.eql(u8, item.key_ptr.*, id.builtin.label()) and value.object.contains(id.builtin.label())) continue;
                if (item.value_ptr.* == .null) continue;
                if (item.value_ptr.* != .string) return error.InvalidModelRoleValue;
                const trimmed = std.mem.trim(u8, item.value_ptr.string, " \t\r\n");
                if (trimmed.len == 0) continue;
                try table.setId(alloc, id, trimmed);
            }
        }
        if (cycle_value) |value| {
            if (value != .array) return error.InvalidCycleOrderType;
            var order: std.ArrayList(RoleId) = .empty;
            defer order.deinit(alloc);
            for (value.array.items) |item| {
                if (item != .string) return error.InvalidCycleOrderValue;
                const id = parseRoleId(item.string) orelse return error.InvalidCycleOrderValue;
                try order.append(alloc, id);
            }
            try table.setCycleIds(alloc, order.items);
        }
        if (bank_value) |value| try table.parseBanks(alloc, value);
        if (tags_value) |value| try table.parseTags(alloc, value);
        if (fallback_value) |value| try table.parseFallbacks(alloc, value);
        return table;
    }

    fn parseBanks(self: *Table, alloc: Allocator, value: std.json.Value) Error!void {
        if (value != .object) return error.InvalidModelRoleBankType;
        var iterator = value.object.iterator();
        while (iterator.next()) |item| {
            const role = parseRoleId(item.key_ptr.*) orelse return error.InvalidRoleName;
            try self.ensureRole(alloc, role);
            var bank: BankEntry = .{ .role = try ownedRoleId(alloc, role) };
            errdefer {
                for (bank.selectors.items) |selector| alloc.free(selector);
                bank.selectors.deinit(alloc);
            }
            switch (item.value_ptr.*) {
                .string => |text| {
                    try validateSelector(text);
                    try bank.selectors.append(alloc, try alloc.dupe(u8, text));
                },
                .array => |array| for (array.items) |entry| {
                    if (entry != .string) return error.InvalidModelRoleBankValue;
                    try validateSelector(entry.string);
                    try bank.selectors.append(alloc, try alloc.dupe(u8, entry.string));
                },
                else => return error.InvalidModelRoleBankValue,
            }
            try self.replaceBank(alloc, bank);
        }
    }

    fn parseTags(self: *Table, alloc: Allocator, value: std.json.Value) Error!void {
        if (value != .object) return error.InvalidModelTagsType;
        var iterator = value.object.iterator();
        while (iterator.next()) |item| {
            const role = parseRoleId(item.key_ptr.*) orelse return error.InvalidRoleName;
            if (item.value_ptr.* != .object) return error.InvalidModelTagValue;
            try self.ensureRole(alloc, role);
            var tag: Tag = .{ .role = try ownedRoleId(alloc, role) };
            errdefer tagDeinit(alloc, &tag);
            if (item.value_ptr.object.get("tag")) |raw| {
                if (raw != .string) return error.InvalidModelTagValue;
                tag.tag = try alloc.dupe(u8, raw.string);
            }
            if (item.value_ptr.object.get("name")) |raw| {
                if (raw != .string) return error.InvalidModelTagValue;
                tag.name = try alloc.dupe(u8, raw.string);
            }
            if (item.value_ptr.object.get("color")) |raw| {
                if (raw != .string) return error.InvalidModelTagValue;
                tag.color = try alloc.dupe(u8, raw.string);
            }
            if (item.value_ptr.object.get("hidden")) |raw| {
                if (raw != .bool) return error.InvalidModelTagValue;
                tag.hidden = raw.bool;
            }
            try self.replaceTag(alloc, tag);
        }
    }

    fn parseFallbacks(self: *Table, alloc: Allocator, value: std.json.Value) Error!void {
        if (value != .object) return error.InvalidFallbackChainsType;
        var iterator = value.object.iterator();
        while (iterator.next()) |item| {
            try validateSelector(item.key_ptr.*);
            var chain: std.ArrayList(u8) = .empty;
            defer chain.deinit(alloc);
            switch (item.value_ptr.*) {
                .string => |text| {
                    try validateChain(text);
                    try chain.appendSlice(alloc, text);
                },
                .array => |array| for (array.items, 0..) |entry, index| {
                    if (entry != .string) return error.InvalidFallbackChainValue;
                    try validateRef(entry.string);
                    if (index > 0) try chain.appendSlice(alloc, ", ");
                    try chain.appendSlice(alloc, entry.string);
                },
                else => return error.InvalidFallbackChainValue,
            }
            if (chain.items.len == 0) return error.InvalidFallbackChainValue;
            try self.replaceFallback(alloc, item.key_ptr.*, chain.items);
        }
    }

    fn replaceTag(self: *Table, alloc: Allocator, tag: Tag) Error!void {
        for (self.tags.items, 0..) |*old, index| if (old.role.eql(tag.role)) {
            tagDeinit(alloc, old);
            self.tags.items[index] = tag;
            return;
        };
        try self.tags.append(alloc, tag);
    }

    fn replaceBank(self: *Table, alloc: Allocator, bank: BankEntry) Error!void {
        for (self.banks.items, 0..) |*old, index| if (old.role.eql(bank.role)) {
            bankDeinit(alloc, old);
            self.banks.items[index] = bank;
            return;
        };
        try self.banks.append(alloc, bank);
    }

    fn replaceFallback(self: *Table, alloc: Allocator, selector: []const u8, chain: []const u8) Error!void {
        for (self.fallbacks.items, 0..) |*old, index| if (std.ascii.eqlIgnoreCase(old.selector, selector)) {
            alloc.free(old.selector);
            alloc.free(old.chain);
            self.fallbacks.items[index] = .{ .selector = try alloc.dupe(u8, selector), .chain = try alloc.dupe(u8, chain) };
            return;
        };
        try self.fallbacks.append(alloc, .{ .selector = try alloc.dupe(u8, selector), .chain = try alloc.dupe(u8, chain) });
    }

    /// Layer merge: each named role replaces only its own value; dynamic
    /// metadata maps replace entries by key, and a cycle replaces the whole
    /// cycle. Incoming remains valid and can be deinitialized by its owner.
    pub fn overlay(self: *Table, alloc: Allocator, incoming: *Table) void {
        for (incoming.entries.items) |entry| {
            const id = entry.id();
            self.ensureRole(alloc, id) catch unreachable;
            if (entry.value) |value| self.setId(alloc, id, value) catch unreachable;
        }
        if (incoming.has_cycle) self.setCycleIds(alloc, incoming.cycle.items) catch unreachable;
        for (incoming.tags.items) |tag| {
            self.ensureRole(alloc, tag.role) catch unreachable;
            var copy: Tag = .{ .role = tag.role };
            copy.role = ownedRoleId(alloc, tag.role) catch unreachable;
            copy.tag = alloc.dupe(u8, tag.tag) catch unreachable;
            copy.name = alloc.dupe(u8, tag.name) catch unreachable;
            copy.color = alloc.dupe(u8, tag.color) catch unreachable;
            copy.hidden = tag.hidden;
            self.replaceTag(alloc, copy) catch unreachable;
        }
        for (incoming.banks.items) |bank| {
            var copy: BankEntry = .{ .role = bank.role };
            for (bank.selectors.items) |selector| copy.selectors.append(alloc, alloc.dupe(u8, selector) catch unreachable) catch unreachable;
            self.replaceBank(alloc, copy) catch unreachable;
        }
        for (incoming.fallbacks.items) |entry| self.replaceFallback(alloc, entry.selector, entry.chain) catch unreachable;
    }
};

fn ownedRoleId(alloc: Allocator, role: RoleId) Allocator.Error!RoleId {
    return switch (role) {
        .builtin => role,
        .custom => .{ .custom = try alloc.dupe(u8, role.custom) },
    };
}

fn tagDeinit(alloc: Allocator, tag: *Tag) void {
    if (tag.role == .custom and tag.role.custom.len > 0) alloc.free(@constCast(tag.role.custom));
    if (tag.tag.len > 0) alloc.free(tag.tag);
    if (tag.name.len > 0) alloc.free(tag.name);
    if (tag.color.len > 0) alloc.free(tag.color);
}

fn bankDeinit(alloc: Allocator, bank: *BankEntry) void {
    for (bank.selectors.items) |selector| alloc.free(selector);
    bank.selectors.deinit(alloc);
    if (bank.role == .custom and bank.role.custom.len > 0) alloc.free(@constCast(bank.role.custom));
}

pub fn validateRoleName(name: []const u8) error{InvalidRoleName}!void {
    if (name.len == 0 or name.len > max_role_bytes or !std.unicode.utf8ValidateSlice(name)) return error.InvalidRoleName;
    if (Role.parse(name) != null) return;
    for (name) |byte| if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte) or byte == '@' or byte == ',' or byte == '/') return error.InvalidRoleName;
}

pub fn parseRoleId(name: []const u8) ?RoleId {
    if (std.mem.eql(u8, name, "*")) return .{ .builtin = .default };
    if (Role.parse(name)) |role| return .{ .builtin = role };
    validateRoleName(name) catch return null;
    return .{ .custom = name };
}

pub const Entry = struct {
    ref: []const u8,
    effort: ?types.ReasoningEffort = null,

    pub fn parse(text: []const u8) Entry {
        const colon = std.mem.findScalarLast(u8, text, ':') orelse return .{ .ref = text };
        const suffix = text[colon + 1 ..];
        const levels = [_][]const u8{ "auto", "off", "none", "minimal", "low", "medium", "high", "xhigh", "max" };
        for (levels) |name| if (std.ascii.eqlIgnoreCase(name, suffix)) return .{ .ref = text[0..colon], .effort = types.ReasoningEffort.parse(suffix) };
        return .{ .ref = text };
    }

    pub fn format(self: Entry, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.ref);
        if (self.effort) |effort| try writer.print(":{s}", .{effort.label()});
    }
};

pub const Chain = struct {
    items: [max_chain]Entry = undefined,
    len: usize = 0,

    pub fn parse(value: []const u8) Chain {
        var chain: Chain = .{};
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0 or chain.len == max_chain) continue;
            chain.items[chain.len] = Entry.parse(trimmed);
            chain.len += 1;
        }
        return chain;
    }

    pub fn entries(self: *const Chain) []const Entry {
        return self.items[0..self.len];
    }

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

pub fn validateChain(value: []const u8) error{InvalidModelRoleValue}!void {
    if (value.len == 0 or value.len > max_ref_bytes or !std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n"))) return error.InvalidModelRoleValue;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try validateRef(trimmed);
        count += 1;
    }
    if (count == 0) return error.InvalidModelRoleValue;
}

pub fn validateRef(value: []const u8) error{InvalidModelRoleValue}!void {
    if (value.len == 0 or value.len > max_ref_bytes or !std.unicode.utf8ValidateSlice(value)) return error.InvalidModelRoleValue;
    if (!std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n"))) return error.InvalidModelRoleValue;
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidModelRoleValue;
    if (value[0] == '@' and value.len == 1) return error.InvalidModelRoleValue;
}

pub fn validateSelector(value: []const u8) error{InvalidModelRoleValue}!void {
    return validateRef(value);
}

/// A parsed reference. `source` is retained for builtin callers; `source_id`
/// is the authoritative identity for custom roles.
pub const Ref = struct {
    provider: ?[]const u8 = null,
    model: []const u8,
    source: Role = .default,
    source_id: RoleId = .{ .builtin = .default },
    effort: ?types.ReasoningEffort = null,
    routing: ?[]const u8 = null,

    pub fn on(self: Ref, active: []const u8) ?[]const u8 {
        const provider = self.provider orelse return self.model;
        return if (std.ascii.eqlIgnoreCase(provider, active)) self.model else null;
    }
};

pub const Selection = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: ?types.ReasoningEffort = null,
    routing: ?[]const u8 = null,
    source: RoleId,

    pub fn providerLabel(self: *const Selection) []const u8 {
        return self.provider.label();
    }
};

pub const Candidate = struct {
    provider: []const u8,
    model: []const u8,
    routing: ?[]const u8 = null,
    credential_ready: bool = true,
};

pub const Picked = struct { model: []const u8, effort: ?types.ReasoningEffort = null };

pub const Known = struct {
    context: ?*anyopaque = null,
    known_fn: *const fn (?*anyopaque, model: []const u8) bool,
    known_for_fn: ?*const fn (?*anyopaque, provider: []const u8, model: []const u8) bool = null,
};

pub const Context = struct {
    provider: []const u8,
    default_model: []const u8,
    builtin_small: ?[]const u8 = null,
    legacy_review: ?[]const u8 = null,
    configured: []const configured_provider.Definition = &.{},
    known: ?Known = null,
    /// Provider/model inventory supplied by the model registry. Unknown or
    /// unloaded inventories are represented by an empty slice and do not
    /// make a candidate unavailable.
    candidates: []const Candidate = &.{},
    provider_order: []const []const u8 = &.{},
};

fn knownFor(ctx: Context, provider: []const u8, model: []const u8) bool {
    const known = ctx.known orelse return true;
    if (known.known_for_fn) |callback| return callback(known.context, provider, model);
    if (!std.ascii.eqlIgnoreCase(provider, ctx.provider)) return true;
    return known.known_fn(known.context, model);
}

fn providerKnown(name: []const u8, configured: []const configured_provider.Definition) bool {
    if (model_provider.parse(name) != null) return true;
    for (configured) |definition| if (std.ascii.eqlIgnoreCase(definition.id, name)) return true;
    return false;
}

fn splitRoute(raw: []const u8) struct { model: []const u8, route: ?[]const u8 } {
    const at = std.mem.findScalarLast(u8, raw, '@') orelse return .{ .model = raw, .route = null };
    if (at == 0 or at + 1 == raw.len) return .{ .model = raw, .route = null };
    return .{ .model = raw[0..at], .route = raw[at + 1 ..] };
}

/// Splits a known `provider/model` prefix and preserves model-local `@route`.
pub fn parseRefId(raw: []const u8, source: RoleId, configured: []const configured_provider.Definition) Ref {
    const routed = splitRoute(raw);
    const slash = std.mem.findScalar(u8, routed.model, '/') orelse return .{ .model = routed.model, .source = sourceRole(source), .source_id = source, .routing = routed.route };
    if (slash + 1 == routed.model.len) return .{ .model = routed.model, .source = sourceRole(source), .source_id = source, .routing = routed.route };
    const prefix = routed.model[0..slash];
    if (!providerKnown(prefix, configured) and !std.mem.eql(u8, prefix, "*")) return .{ .model = routed.model, .source = sourceRole(source), .source_id = source, .routing = routed.route };
    return .{ .provider = prefix, .model = routed.model[slash + 1 ..], .source = sourceRole(source), .source_id = source, .routing = routed.route };
}

pub fn parseRef(raw: []const u8, source: Role, configured: []const configured_provider.Definition) Ref {
    return parseRefId(raw, .{ .builtin = source }, configured);
}

fn sourceRole(id: RoleId) Role {
    return switch (id) {
        .builtin => |role| role,
        .custom => .default,
    };
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(text[t]))) {
            p += 1;
            t += 1;
            continue;
        }
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            mark = t;
            continue;
        }
        if (star) |s| {
            p = s + 1;
            mark += 1;
            t = mark;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn candidateMatches(ref: Ref, candidate: Candidate, ctx: Context) bool {
    const provider_pattern = ref.provider orelse ctx.provider;
    if (!globMatch(provider_pattern, candidate.provider)) return false;
    if (!globMatch(ref.model, candidate.model)) return false;
    if (ref.routing) |route| if (!globMatch(route, candidate.routing orelse "")) return false;
    return candidate.credential_ready and knownFor(ctx, candidate.provider, candidate.model);
}

fn candidateRef(ref: Ref, ctx: Context) ?Ref {
    if (ctx.candidates.len == 0) return ref;
    for (ctx.provider_order) |preferred| for (ctx.candidates) |candidate| {
        if (!std.ascii.eqlIgnoreCase(preferred, candidate.provider)) continue;
        if (candidateMatches(ref, candidate, ctx)) return .{ .provider = candidate.provider, .model = candidate.model, .source = ref.source, .source_id = ref.source_id, .effort = ref.effort, .routing = ref.routing orelse candidate.routing };
    };
    for (ctx.candidates) |candidate| if (candidateMatches(ref, candidate, ctx)) return .{ .provider = candidate.provider, .model = candidate.model, .source = ref.source, .source_id = ref.source_id, .effort = ref.effort, .routing = ref.routing orelse candidate.routing };
    return null;
}

fn usable(ref: Ref, ctx: Context) bool {
    if (ctx.candidates.len > 0) return candidateRef(ref, ctx) != null;
    const provider = ref.provider orelse ctx.provider;
    return knownFor(ctx, provider, ref.model);
}

fn seenRole(seen: []const RoleId, role: RoleId) bool {
    for (seen) |old| if (old.eql(role)) return true;
    return false;
}

fn defaultRef(ctx: Context) ?Ref {
    if (ctx.default_model.len == 0) return null;
    return .{ .model = ctx.default_model, .source = .default, .source_id = .{ .builtin = .default } };
}

fn candidateFor(table: *const Table, role: RoleId, entry: Entry, ctx: Context, seen: []const RoleId) ?Ref {
    if (entry.ref.len == 0) return null;
    if (std.mem.eql(u8, entry.ref, "*")) return defaultRef(ctx);
    if (entry.ref[0] != '@') {
        var ref = parseRefId(entry.ref, role, ctx.configured);
        ref.effort = entry.effort;
        return candidateRef(ref, ctx) orelse ref;
    }
    const target = parseRoleId(entry.ref[1..]) orelse return defaultRef(ctx);
    if (!table.hasRole(target) and !(target == .builtin and target.builtin == .default)) {
        debug_trace.logf("config", "model role alias unknown role={s} alias={s} fallback=default", .{ role.label(), entry.ref });
        return defaultRef(ctx);
    }
    if (seenRole(seen, target)) {
        debug_trace.logf("config", "model role alias cycle at={s} fallback=default", .{role.label()});
        return defaultRef(ctx);
    }
    return resolveIn(table, target, ctx, seen);
}

const Choice = struct { ref: Ref, index: usize };

fn choose(table: *const Table, role: RoleId, chain: Chain, ctx: Context, seen: []const RoleId) ?Choice {
    var first: ?Choice = null;
    for (chain.entries(), 0..) |entry, index| {
        const candidate = candidateFor(table, role, entry, ctx, seen) orelse continue;
        const choice: Choice = .{ .ref = candidate, .index = index };
        if (first == null) {
            first = choice;
        }
        if (usable(candidate, ctx)) return choice;
    }
    return first;
}

fn resolveIn(table: *const Table, role: RoleId, ctx: Context, prior: []const RoleId) ?Ref {
    if (seenRole(prior, role)) return defaultRef(ctx);
    var seen: [64]RoleId = undefined;
    if (prior.len >= seen.len) return defaultRef(ctx);
    @memcpy(seen[0..prior.len], prior);
    seen[prior.len] = role;
    const seen_slice = seen[0 .. prior.len + 1];
    const raw = table.getId(role) orelse switch (role) {
        .builtin => |builtin| switch (builtin) {
            .review => if (ctx.legacy_review) |model| return .{ .model = model, .source = .review, .source_id = role } else return null,
            .title, .tiny => return resolveIn(table, .{ .builtin = .small }, ctx, seen_slice),
            .small => if (ctx.builtin_small) |model| return .{ .model = model, .source = .small, .source_id = role } else return null,
            .default => return defaultRef(ctx),
            else => return null,
        },
        .custom => return null,
    };
    const choice = choose(table, role, Chain.parse(raw), ctx, seen_slice) orelse return null;
    return choice.ref;
}

/// Resolves a role identity, including custom names and provider-qualified
/// references. The first currently usable chain entry wins; when catalog
/// data is unavailable the first entry remains the optimistic choice.
pub fn resolveId(table: *const Table, role: RoleId, ctx: Context) ?Ref {
    return resolveIn(table, role, ctx, &.{});
}
pub fn resolve(table: *const Table, role: Role, ctx: Context) ?Ref {
    return resolveId(table, .{ .builtin = role }, ctx);
}

pub fn chosenEntryId(table: *const Table, role: RoleId, ctx: Context) ?usize {
    const raw = table.getId(role) orelse return null;
    var seen: [1]RoleId = .{role};
    const choice = choose(table, role, Chain.parse(raw), ctx, &seen) orelse return null;
    return if (std.mem.eql(u8, choice.ref.provider orelse ctx.provider, ctx.provider)) choice.index else null;
}
pub fn chosenEntry(table: *const Table, role: Role, ctx: Context) ?usize {
    return chosenEntryId(table, .{ .builtin = role }, ctx);
}

pub fn selectionFromRef(ref: Ref, ctx: Context) ?Selection {
    const provider_name = ref.provider orelse ctx.provider;
    const provider = model_provider.parse(provider_name) orelse return null;
    return .{ .provider = provider, .model = ref.model, .effort = ref.effort, .routing = ref.routing, .source = ref.source_id };
}

pub fn resolveSelection(table: *const Table, role: RoleId, ctx: Context) ?Selection {
    const ref = resolveId(table, role, ctx) orelse return null;
    return selectionFromRef(ref, ctx);
}

fn selectorForSelection(selection: Selection) [2][]const u8 {
    return .{ selection.provider.label(), selection.model };
}

fn fallbackChainFor(table: *const Table, selection: Selection, role: RoleId) ?[]const u8 {
    if (table.fallbackFor(role.label())) |chain| return chain;
    var qualified: [1024]u8 = undefined;
    const route = if (selection.routing) |r| std.mem.print(&qualified, "{s}/{s}@{s}", .{ selection.provider.label(), selection.model, r }) catch return null else std.mem.print(&qualified, "{s}/{s}", .{ selection.provider.label(), selection.model }) catch return null;
    if (table.fallbackFor(route)) |chain| return chain;
    if (table.fallbackForGlob(route)) |chain| return chain;
    if (table.fallbackFor(selection.model)) |chain| return chain;
    if (table.fallbackForGlob(selection.model)) |chain| return chain;
    var wildcard: [1024]u8 = undefined;
    const exact_prefix = std.mem.findScalar(u8, selection.model, '/') orelse selection.model.len;
    const prefix = selection.model[0..exact_prefix];
    const id_prefix = std.mem.print(&wildcard, "{s}/{s}/*", .{ selection.provider.label(), prefix }) catch return null;
    if (table.fallbackFor(id_prefix)) |chain| return chain;
    if (table.fallbackForGlob(id_prefix)) |chain| return chain;
    const provider_wildcard = std.mem.print(&wildcard, "{s}/*", .{selection.provider.label()}) catch return null;
    return table.fallbackForGlob(provider_wildcard);
}

/// Appends the role's executable candidates and transitively configured
/// runtime fallbacks. Route variants remain distinct entries.
pub fn selectionChain(table: *const Table, role: RoleId, ctx: Context, out: []Selection) usize {
    var count: usize = 0;
    var queue: [64]Selection = undefined;
    var queue_len: usize = 0;
    const raw = table.getId(role);
    if (raw) |value| {
        var seen: [1]RoleId = .{role};
        for (Chain.parse(value).entries()) |entry| {
            const ref = candidateFor(table, role, entry, ctx, &seen) orelse continue;
            if (ctx.candidates.len > 0 and candidateRef(ref, ctx) == null) continue;
            const resolved = candidateRef(ref, ctx) orelse ref;
            if (selectionFromRef(resolved, ctx)) |selection| if (queue_len < queue.len) {
                queue[queue_len] = selection;
                queue_len += 1;
            };
        }
    } else if (resolveSelection(table, role, ctx)) |selection| {
        queue[queue_len] = selection;
        queue_len += 1;
    }
    var index: usize = 0;
    while (index < queue_len and count < out.len) : (index += 1) {
        const selection = queue[index];
        var duplicate = false;
        for (out[0..count]) |old| {
            if (old.provider.eql(selection.provider) and std.mem.eql(u8, old.model, selection.model) and std.mem.eql(u8, old.routing orelse "", selection.routing orelse "")) {
                duplicate = true;
            }
        }
        if (duplicate) continue;
        out[count] = selection;
        count += 1;
        const chain = fallbackChainFor(table, selection, role) orelse continue;
        for (Chain.parse(chain).entries()) |entry| {
            const ref = candidateFor(table, role, entry, ctx, &.{}) orelse continue;
            if (ctx.candidates.len > 0 and candidateRef(ref, ctx) == null) continue;
            const resolved = candidateRef(ref, ctx) orelse ref;
            if (selectionFromRef(resolved, ctx)) |next| if (queue_len < queue.len) {
                queue[queue_len] = next;
                queue_len += 1;
            };
        }
    }
    return count;
}

pub fn bankAllows(table: *const Table, role: RoleId, selection: Selection) bool {
    const selectors = table.bankFor(role) orelse return true;
    for (selectors) |selector| {
        const ref = parseRefId(selector, role, &.{});
        const provider = ref.provider orelse selection.provider.label();
        if (globMatch(provider, selection.provider.label()) and globMatch(ref.model, selection.model)) {
            if (ref.routing == null or globMatch(ref.routing.?, selection.routing orelse "")) return true;
        }
    }
    return false;
}

test "custom role identities, tags, banks and provider-qualified route candidates" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"model_roles":{"planner":"openrouter/google/gemini-*@nitro, codex/mini:low"},"cycle_order":["planner","default"],"modelRoleBank":{"planner":["openrouter/google/*","codex/mini"]},"modelTags":{"planner":{"tag":"plan","name":"Planner","color":"blue","hidden":false}},"fallbackChains":{"openrouter/google/*":["codex/mini:low"]}}
    , .{});
    defer parsed.deinit();
    var table = try Table.parseExtended(alloc, parsed.value.object.get("model_roles"), parsed.value.object.get("cycle_order"), parsed.value.object.get("modelRoleBank"), parsed.value.object.get("modelTags"), parsed.value.object.get("fallbackChains"));
    defer table.deinit(alloc);
    const planner = parseRoleId("planner").?;
    try std.testing.expect(planner == .custom);
    try std.testing.expectEqualStrings("plan", table.tagFor(planner).?.tag);
    try std.testing.expectEqual(@as(usize, 2), table.cycleOrderIds().len);
    const candidates = [_]Candidate{
        .{ .provider = "openrouter", .model = "google/gemini-2.5", .routing = "nitro" },
        .{ .provider = "codex", .model = "mini" },
    };
    const ctx: Context = .{ .provider = "gateway", .default_model = "main", .candidates = &candidates };
    const picked = resolveSelection(&table, planner, ctx).?;
    try std.testing.expectEqualStrings("openrouter", picked.provider.label());
    try std.testing.expectEqualStrings("google/gemini-2.5", picked.model);
    try std.testing.expectEqualStrings("nitro", picked.routing.?);
    try std.testing.expect(bankAllows(&table, planner, picked));
    var chain: [8]Selection = undefined;
    const count = selectionChain(&table, planner, ctx, &chain);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("mini", chain[1].model);
    try std.testing.expectEqualStrings("codex", chain[1].provider.label());
}

test "role aliases cycle safely and glob selectors are case insensitive" {
    const alloc = std.testing.allocator;
    var table = try Table.parse(alloc, .{ .object = .empty }, null);
    defer table.deinit(alloc);
    try table.setId(alloc, .{ .custom = "reviewer" }, "@reviewer");
    const ctx: Context = .{ .provider = "gateway", .default_model = "main" };
    const fallback = resolveSelection(&table, .{ .custom = "reviewer" }, ctx).?;
    try std.testing.expectEqualStrings("main", fallback.model);
    const candidates = [_]Candidate{.{ .provider = "OpenRouter", .model = "Google/Gemini" }};
    const selected = parseRefId("openrouter/google/*", .{ .builtin = .worker }, &.{});
    try std.testing.expect(candidateMatches(selected, candidates[0], .{ .provider = "gateway", .default_model = "main", .candidates = &candidates }));
}
