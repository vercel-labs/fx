const std = @import("std");

const builtin_tools = @import("tools.zig");
const mode_contract = @import("../core/modes/mode_contract.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const tool_projection = @import("../core/tooling/tool_projection.zig");

pub const ModeSpec = mode_contract.ModeSpec;
pub const ToolPolicy = mode_contract.ToolPolicy;
pub const default_mode_id = "auto";

/// The CLI's `/permissions` modes, in the order ACP lists them.
pub const all = [_]ModeSpec{
    .{ .id = "auto", .name = "Auto", .description = "Check actions with an automatic safety review instead of asking", .permission_mode = .auto },
    .{ .id = "ask", .name = "Ask", .description = "Request permission before making any changes", .permission_mode = .ask },
    .{ .id = "full-access", .name = "Full access", .description = "Run every action without asking, outside the sandbox", .permission_mode = .yolo },
};

pub const registry = mode_registry.Registry{
    .default_mode_id = default_mode_id,
    .modes = all[0..],
};

pub fn lookup(id: []const u8) ?*const ModeSpec {
    return registry.lookup(id);
}

test "built-in modes register the CLI permission modes in ACP order" {
    const expected = [_]struct { id: []const u8, name: []const u8, permission_mode: @TypeOf(all[0].permission_mode) }{
        .{ .id = "auto", .name = "Auto", .permission_mode = .auto },
        .{ .id = "ask", .name = "Ask", .permission_mode = .ask },
        .{ .id = "full-access", .name = "Full access", .permission_mode = .yolo },
    };
    try std.testing.expectEqual(expected.len, all.len);
    for (expected, all) |want, mode| {
        try std.testing.expectEqualStrings(want.id, mode.id);
        try std.testing.expectEqualStrings(want.name, mode.name);
        try std.testing.expectEqual(want.permission_mode, mode.permission_mode);
        try std.testing.expectEqual(ToolPolicy.full, mode.tool_policy);
    }

    try std.testing.expectEqualStrings("auto", default_mode_id);
    try std.testing.expectEqualStrings(default_mode_id, registry.default_mode_id);
    try std.testing.expect(lookup("code") == null);
    try std.testing.expect(lookup("yolo") == null);
    try std.testing.expect(lookup("unknown") == null);
}

test "built-in mode projections carry included custom provider guidance" {
    inline for (&.{ "auto", "ask", "full-access" }) |mode_id| {
        var projection = try registry.buildModelToolProjection(
            std.testing.allocator,
            builtin_tools.advertisement_set,
            mode_id,
            .{},
        );
        defer projection.deinit(std.testing.allocator);

        try std.testing.expect(tool_projection.containsName(projection.advertised_names, "web_search"));
        try std.testing.expectEqualStrings(builtin_tools.web_search.description, projection.custom_guidance);
    }
}

test "built-in mode projections use the supplied tool set" {
    const tools = [_]builtin_tools.ToolSpec{
        builtin_tools.lookup("read_file") orelse return error.TestExpectedEqual,
    };
    const ordered_names = [_][]const u8{ "write_file", "read_file" };
    const read_only_names = [_][]const u8{ "write_file", "read_file" };
    const tool_set = tool_set_contract.ToolSet{
        .registry = .{ .tools = tools[0..] },
        .order = ordered_names[0..],
        .read_only_tool_names = read_only_names[0..],
    };

    var projection = try registry.buildModelToolProjection(std.testing.allocator, tool_set, "ask", .{});
    defer projection.deinit(std.testing.allocator);
    try std.testing.expect(tool_projection.containsName(projection.advertised_names, "read_file"));
    try std.testing.expect(!tool_projection.containsName(projection.advertised_names, "write_file"));
    try std.testing.expectEqualStrings("", projection.custom_guidance);
}
