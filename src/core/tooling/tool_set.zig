const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");

/// Effective tool registry and the named subsets used by agent roles.
pub const ToolSet = struct {
    registry: tool_dispatch.Registry,
    order: []const []const u8,
    read_only_tool_names: []const []const u8,
};

pub const empty = ToolSet{
    .registry = .{},
    .order = &.{},
    .read_only_tool_names = &.{},
};

/// `base` keeping only the tools `keep.allows(name)` accepts, or null when it
/// keeps every one. A tool left out is unknown to the agent using the set, so
/// a call to it is refused as unsupported. The result belongs to `arena`.
pub fn narrow(arena: std.mem.Allocator, base: ToolSet, keep: anytype) !?ToolSet {
    var kept: std.ArrayList(tool_dispatch.Tool) = .empty;
    for (base.registry.tools) |tool| {
        if (keep.allows(tool.name)) try kept.append(arena, tool);
    }
    if (kept.items.len == base.registry.tools.len) return null;
    var narrowed = base;
    narrowed.registry.tools = kept.items;
    narrowed.order = try keepNames(arena, base.order, keep);
    narrowed.read_only_tool_names = try keepNames(arena, base.read_only_tool_names, keep);
    return narrowed;
}

fn keepNames(arena: std.mem.Allocator, names: []const []const u8, keep: anytype) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (names) |name| if (keep.allows(name)) try kept.append(arena, name);
    return kept.items;
}

test "narrowing a tool set keeps only the allowed tools, and keeping them all changes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tools: [3]tool_dispatch.Tool = undefined;
    for (&tools, [_][]const u8{ "read_file", "write_file", "subagent" }) |*tool, name| tool.name = name;
    var base = empty;
    base.registry.tools = &tools;
    base.order = &.{ "read_file", "write_file", "subagent" };
    base.read_only_tool_names = &.{"read_file"};

    const ReadOnly = struct {
        fn allows(_: @This(), name: []const u8) bool {
            return std.mem.eql(u8, name, "read_file");
        }
    };
    const narrowed = (try narrow(arena, base, ReadOnly{})).?;
    try std.testing.expectEqual(@as(usize, 1), narrowed.registry.tools.len);
    try std.testing.expect(narrowed.registry.lookup("read_file") != null);
    try std.testing.expect(narrowed.registry.lookup("write_file") == null);
    try std.testing.expectEqual(@as(usize, 1), narrowed.order.len);
    try std.testing.expectEqual(@as(usize, 1), narrowed.read_only_tool_names.len);

    const All = struct {
        fn allows(_: @This(), _: []const u8) bool {
            return true;
        }
    };
    try std.testing.expect((try narrow(arena, base, All{})) == null);
}
