const std = @import("std");

const mode_contract = @import("mode_contract.zig");
const tool_advertisement = @import("../tooling/tool_advertisement.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");

pub const ModeSpec = mode_contract.ModeSpec;

pub const Registry = struct {
    default_mode_id: []const u8,
    modes: []const ModeSpec = &.{},

    pub fn lookup(self: Registry, id: []const u8) ?*const ModeSpec {
        for (self.modes) |*mode| {
            if (std.mem.eql(u8, mode.id, id)) return mode;
        }
        return null;
    }

    pub fn buildModelToolProjection(
        self: Registry,
        alloc: std.mem.Allocator,
        tool_set: tool_set_contract.ToolSet,
        id: []const u8,
        options: tool_advertisement.Options,
    ) !tool_advertisement.EffectiveToolProjection {
        const mode = self.lookup(id) orelse
            return tool_advertisement.buildModelToolProjectionForSet(alloc, tool_set, options);
        return switch (mode.tool_policy) {
            .full => tool_advertisement.buildModelToolProjectionForSet(alloc, tool_set, options),
            .read_only => tool_advertisement.buildReadOnlyModelToolProjectionForSet(alloc, tool_set, options),
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
                .descriptor = .{
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
                .descriptor = .{
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
