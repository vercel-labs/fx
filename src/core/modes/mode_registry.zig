const std = @import("std");

const mode_contract = @import("mode_contract.zig");
const tool_projection = @import("../tooling/tool_projection.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");

pub const ModeSpec = mode_contract.ModeSpec;
const PermissionMode = @FieldType(ModeSpec, "permission_mode");

pub const Registry = struct {
    default_mode_id: []const u8,
    modes: []const ModeSpec = &.{},

    pub fn lookup(self: Registry, id: []const u8) ?*const ModeSpec {
        for (self.modes) |*mode| {
            if (std.mem.eql(u8, mode.id, id)) return mode;
        }
        return null;
    }

    /// The registered mode that applies `permission_mode`: the default mode
    /// when it does, otherwise the first that does, or null when none does.
    /// Sessions use it to start in the saved permission mode.
    pub fn forPermission(self: Registry, permission_mode: PermissionMode) ?*const ModeSpec {
        if (self.lookup(self.default_mode_id)) |mode| {
            if (mode.permission_mode == permission_mode) return mode;
        }
        for (self.modes) |*mode| {
            if (mode.permission_mode == permission_mode) return mode;
        }
        return null;
    }

    /// The mode a new session starts in under `permission_mode`: the mode
    /// that applies it, or the default mode when none does.
    pub fn startingModeId(self: Registry, permission_mode: PermissionMode) []const u8 {
        const mode = self.forPermission(permission_mode) orelse return self.default_mode_id;
        return mode.id;
    }

    pub fn buildModelToolProjection(
        self: Registry,
        alloc: std.mem.Allocator,
        tool_set: tool_set_contract.ToolSet,
        id: []const u8,
        options: tool_projection.Options,
    ) !tool_projection.EffectiveToolProjection {
        const mode = self.lookup(id) orelse
            return tool_projection.buildModelToolProjectionForSet(alloc, tool_set, options);
        return switch (mode.tool_policy) {
            .full => tool_projection.buildModelToolProjectionForSet(alloc, tool_set, options),
            .read_only => tool_projection.buildReadOnlyModelToolProjectionForSet(alloc, tool_set, options),
        };
    }

    pub fn toolAllowed(
        self: Registry,
        tool_set: tool_set_contract.ToolSet,
        id: []const u8,
        tool_name: []const u8,
    ) bool {
        if (tool_set.registry.lookup(tool_name) == null) return true;
        const mode = self.lookup(id) orelse return true;
        return switch (mode.tool_policy) {
            .full => true,
            .read_only => nameInSet(tool_set.read_only_tool_names, tool_name),
        };
    }

    pub fn toolPolicyDeniedJson(
        self: Registry,
        alloc: std.mem.Allocator,
        tool_set: tool_set_contract.ToolSet,
        id: []const u8,
        tool_name: []const u8,
    ) !?[]u8 {
        if (self.toolAllowed(tool_set, id, tool_name)) return null;
        const mode = self.lookup(id) orelse return null;
        const reason = mode.tool_policy_denial_message orelse
            "Tool blocked by the active mode policy.";
        return try tool_result_errors.preToolUseBlockedJson(alloc, tool_name, reason);
    }
};

fn nameInSet(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

test "mode registry looks up modes by id" {
    const modes = [_]ModeSpec{
        .{ .id = "ask", .name = "Ask", .permission_mode = .ask },
        .{ .id = "code", .name = "Code", .permission_mode = .auto },
    };
    const registry = Registry{ .default_mode_id = "ask", .modes = modes[0..] };

    try std.testing.expectEqualStrings("ask", registry.default_mode_id);
    const found = registry.lookup("code") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Code", found.name);
    try std.testing.expectEqual(@as(@TypeOf(found.permission_mode), .auto), found.permission_mode);
    try std.testing.expect(registry.lookup("missing") == null);
}

test "mode registry finds the mode for a permission mode, preferring the default" {
    const modes = [_]ModeSpec{
        .{ .id = "inspect", .name = "Inspect", .permission_mode = .ask },
        .{ .id = "ask", .name = "Ask", .permission_mode = .ask },
        .{ .id = "apply", .name = "Apply", .permission_mode = .auto },
    };
    const apply_default = Registry{ .default_mode_id = "apply", .modes = modes[0..] };
    try std.testing.expectEqualStrings("inspect", apply_default.forPermission(.ask).?.id);
    try std.testing.expectEqualStrings("apply", apply_default.forPermission(.auto).?.id);
    try std.testing.expect(apply_default.forPermission(.yolo) == null);

    const ask_default = Registry{ .default_mode_id = "ask", .modes = modes[0..] };
    try std.testing.expectEqualStrings("ask", ask_default.forPermission(.ask).?.id);

    try std.testing.expectEqualStrings("inspect", apply_default.startingModeId(.ask));
    try std.testing.expectEqualStrings("apply", apply_default.startingModeId(.yolo));
}

test "mode registry applies tool policy to the supplied tool set" {
    const Fixture = struct {
        fn decode(ctx: tool_dispatch.DispatchContext, _: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
            return .{ .failure = try ctx.allocator.dupe(u8, "unused") };
        }

        fn call(ctx: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
            return .{ .failure = try ctx.allocator.dupe(u8, "unused") };
        }

        fn readsOnly(_: tool_dispatch.ToolInput) bool {
            return true;
        }

        fn irreversible(_: tool_dispatch.ToolInput) bool {
            return false;
        }

        const tools = [_]tool_dispatch.Tool{
            .{
                .name = "inspect",
                .description = "Inspect",
                .model_schema = .{
                    .name = "inspect",
                    .description = "Inspect",
                    .input_schema = .{},
                },
                .decode = decode,
                .call = call,
                .reads_only_fn = readsOnly,
                .irreversible_fn = irreversible,
            },
            .{
                .name = "mutate",
                .description = "Mutate",
                .model_schema = .{
                    .name = "mutate",
                    .description = "Mutate",
                    .input_schema = .{},
                },
                .decode = decode,
                .call = call,
                .reads_only_fn = readsOnly,
                .irreversible_fn = irreversible,
            },
        };
    };
    const modes = [_]ModeSpec{
        .{ .id = "full", .name = "Full" },
        .{
            .id = "inspect",
            .name = "Inspect",
            .tool_policy = .read_only,
            .tool_policy_denial_message = "Inspection mode blocks mutations.",
        },
    };
    const registry = Registry{ .default_mode_id = "full", .modes = modes[0..] };
    const tool_set = tool_set_contract.ToolSet{
        .registry = .{ .tools = Fixture.tools[0..] },
        .order = &.{ "inspect", "mutate" },
        .read_only_tool_names = &.{"inspect"},
    };

    try std.testing.expect(registry.toolAllowed(tool_set, "full", "mutate"));
    try std.testing.expect(registry.toolAllowed(tool_set, "inspect", "inspect"));
    try std.testing.expect(!registry.toolAllowed(tool_set, "inspect", "mutate"));
    try std.testing.expect(registry.toolAllowed(tool_set, "missing", "mutate"));
    try std.testing.expect(registry.toolAllowed(tool_set, "inspect", "dynamic_tool"));

    const denied = try registry.toolPolicyDeniedJson(
        std.testing.allocator,
        tool_set,
        "inspect",
        "mutate",
    ) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(denied);
    try std.testing.expect(std.mem.find(u8, denied, "Inspection mode blocks mutations.") != null);
}
