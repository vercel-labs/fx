const std = @import("std");

const builtin_tools = @import("tools.zig");
const mode_contract = @import("../core/modes/mode_contract.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");

pub const ModeSpec = mode_contract.ModeSpec;
pub const ToolPolicy = mode_contract.ToolPolicy;
pub const default_mode_id = "ask";

pub const all = [_]ModeSpec{
    .{ .id = "code", .name = "Code", .description = "Write and modify code with full tool access", .permission_mode = .auto },
    .{ .id = "ask", .name = "Ask", .description = "Request permission before making any changes", .permission_mode = .ask },
};

pub const registry = mode_registry.Registry{
    .default_mode_id = default_mode_id,
    .modes = all[0..],
};

pub fn lookup(id: []const u8) ?*const ModeSpec {
    return registry.lookup(id);
}

test "built-in modes register exact ACP order and permission policy" {
    const expected_ids = [_][]const u8{ "code", "ask" };
    try std.testing.expectEqual(expected_ids.len, all.len);
    for (expected_ids, all) |expected, mode| {
        try std.testing.expectEqualStrings(expected, mode.id);
    }

    try std.testing.expectEqualStrings("ask", default_mode_id);
    try std.testing.expectEqualStrings(default_mode_id, registry.default_mode_id);
    try std.testing.expectEqual(@as(@TypeOf(all[0].permission_mode), .auto), lookup("code").?.permission_mode);
    try std.testing.expectEqual(@as(@TypeOf(all[1].permission_mode), .ask), lookup("ask").?.permission_mode);
    try std.testing.expectEqual(ToolPolicy.full, lookup("code").?.tool_policy);
    try std.testing.expectEqual(ToolPolicy.full, lookup("ask").?.tool_policy);
    try std.testing.expect(lookup("unknown") == null);
}

test "ask and code mode projections carry included custom provider guidance" {
    inline for (&.{ "ask", "code" }) |mode_id| {
        var projection = try registry.buildModelToolProjection(
            std.testing.allocator,
            builtin_tools.advertisement_set,
            mode_id,
            .{ .provider_tools = &.{.web_search} },
        );
        defer projection.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), projection.provider_tools.len);
        try std.testing.expectEqual(.web_search, projection.provider_tools[0].tool);
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
    try std.testing.expect(projection.contains("read_file"));
    try std.testing.expect(!projection.contains("write_file"));
    try std.testing.expectEqualStrings("", projection.custom_guidance);
}
