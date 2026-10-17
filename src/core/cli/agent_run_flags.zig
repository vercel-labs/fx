//! The flags that shape an agent run, one set for every command that runs the
//! agent: `fx ask`, `fx pr`, `fx issue`, and `fx acp`. Each command documents
//! them in `src/builtins/commands.zig` and parses them here, so a flag means
//! the same thing everywhere.

const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Flag = enum {
    permission_mode,
    ask,
    auto,
    full_access,
    yolo,
    provider,
    model,
    effort,
    fast,
    no_fast,
    ultrafast,
    no_ultrafast,
    provider_order,
    provider_strict,
    no_provider_strict,
};

/// The shared flag a command's own flag id names, or null for a flag only
/// that command has. Command flag enums use the same field names.
pub fn fromId(id: anytype) ?Flag {
    return std.meta.stringToEnum(Flag, @tagName(id));
}

pub const Overrides = struct {
    permission: ?types.PermissionMode = null,
    provider: ?model_provider.ProviderId = null,
    /// Owned.
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast: ?bool = null,
    ultrafast: ?bool = null,
    /// Owned, as are its slugs.
    provider_order: ?[][]const u8 = null,
    provider_strict: ?bool = null,

    pub fn deinit(self: *Overrides, alloc: Allocator) void {
        if (self.model) |model| alloc.free(model);
        if (self.provider_order) |order| freeOrder(alloc, order);
        self.* = .{};
    }

    /// Applies one flag; a later flag replaces an earlier one. `value` is the
    /// flag's argument, or empty for a switch. Fails with
    /// `InvalidAgentRunValue` for a value the flag can't take.
    pub fn apply(self: *Overrides, alloc: Allocator, flag: Flag, value: []const u8) !void {
        switch (flag) {
            .permission_mode => self.permission = types.PermissionMode.parse(value) orelse return error.InvalidAgentRunValue,
            .ask => self.permission = .ask,
            .auto => self.permission = .auto,
            .full_access, .yolo => self.permission = .yolo,
            .provider => self.provider = model_provider.parse(value) orelse return error.InvalidAgentRunValue,
            .model => {
                const model = std.mem.trim(u8, value, " \t\r\n");
                if (model.len == 0) return error.InvalidAgentRunValue;
                const owned = try alloc.dupe(u8, model);
                if (self.model) |old| alloc.free(old);
                self.model = owned;
            },
            .effort => self.effort = types.ReasoningEffort.parse(value) orelse return error.InvalidAgentRunValue,
            // Fast and Ultra are separate service tiers, so asking for one
            // turns the other off.
            .fast => {
                self.fast = true;
                self.ultrafast = false;
            },
            .no_fast => self.fast = false,
            .ultrafast => {
                self.ultrafast = true;
                self.fast = false;
            },
            .no_ultrafast => self.ultrafast = false,
            .provider_order => {
                const order = switch (config_runtime.parseProviderOrderList(alloc, value)) {
                    .ok => |maybe| maybe orelse return error.InvalidAgentRunValue,
                    .invalid => return error.InvalidAgentRunValue,
                };
                if (self.provider_order) |old| freeOrder(alloc, old);
                self.provider_order = order;
            },
            .provider_strict => self.provider_strict = true,
            .no_provider_strict => self.provider_strict = false,
        }
    }
};

fn freeOrder(alloc: Allocator, order: [][]const u8) void {
    for (order) |slug| alloc.free(@constCast(slug));
    if (order.len > 0) alloc.free(order);
}

test "agent-run flags keep the last value and keep Fast and Ultra apart" {
    const alloc = std.testing.allocator;
    var overrides: Overrides = .{};
    defer overrides.deinit(alloc);

    try overrides.apply(alloc, .auto, "");
    try overrides.apply(alloc, .permission_mode, "full-access");
    try std.testing.expectEqual(types.PermissionMode.yolo, overrides.permission.?);
    try overrides.apply(alloc, .model, " first ");
    try overrides.apply(alloc, .model, "second");
    try std.testing.expectEqualStrings("second", overrides.model.?);
    try overrides.apply(alloc, .ultrafast, "");
    try overrides.apply(alloc, .fast, "");
    try std.testing.expect(overrides.fast.? and !overrides.ultrafast.?);
    try overrides.apply(alloc, .provider_order, "a,b");
    try overrides.apply(alloc, .provider_order, "c");
    try std.testing.expectEqual(@as(usize, 1), overrides.provider_order.?.len);
    try overrides.apply(alloc, .effort, "high");
    try overrides.apply(alloc, .provider, "codex");
    try std.testing.expectEqualStrings("codex", overrides.provider.?.label());

    for ([_]struct { flag: Flag, value: []const u8 }{
        .{ .flag = .permission_mode, .value = "sometimes" },
        .{ .flag = .model, .value = "  " },
        // Effort names come from the model's catalog, so only a malformed one fails.
        .{ .flag = .effort, .value = "high effort" },
        .{ .flag = .provider_order, .value = "" },
    }) |case| try std.testing.expectError(error.InvalidAgentRunValue, overrides.apply(alloc, case.flag, case.value));
}

test "command flag ids map onto the shared flags by name" {
    const Local = enum { model, create, no_fast };
    try std.testing.expectEqual(Flag.model, fromId(Local.model).?);
    try std.testing.expectEqual(Flag.no_fast, fromId(Local.no_fast).?);
    try std.testing.expect(fromId(Local.create) == null);
}
