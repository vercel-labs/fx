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

pub const Narrowed = struct {
    registry_tools: []tool_dispatch.Tool,
    order: []const []const u8,
    read_only_tool_names: []const []const u8,

    pub fn deinit(self: *Narrowed, alloc: std.mem.Allocator) void {
        alloc.free(self.registry_tools);
        alloc.free(self.order);
        alloc.free(self.read_only_tool_names);
        self.* = undefined;
    }

    pub fn view(self: *const Narrowed) ToolSet {
        return .{
            .registry = .{ .tools = self.registry_tools },
            .order = self.order,
            .read_only_tool_names = self.read_only_tool_names,
        };
    }
};

pub fn narrow(
    alloc: std.mem.Allocator,
    available: ToolSet,
    selected: ?[]const []const u8,
) !?Narrowed {
    const names = selected orelse return null;
    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(alloc);
    for (available.order) |name| {
        if (containsName(names, name)) try order.append(alloc, name);
    }
    var read_only: std.ArrayList([]const u8) = .empty;
    defer read_only.deinit(alloc);
    for (available.read_only_tool_names) |name| {
        if (containsName(names, name)) try read_only.append(alloc, name);
    }
    var registry_tools: std.ArrayList(tool_dispatch.Tool) = .empty;
    defer registry_tools.deinit(alloc);
    for (available.registry.tools) |tool| {
        if (containsName(names, tool.name)) try registry_tools.append(alloc, tool);
    }
    const owned_order = try order.toOwnedSlice(alloc);
    errdefer alloc.free(owned_order);
    const owned_read_only = try read_only.toOwnedSlice(alloc);
    errdefer alloc.free(owned_read_only);
    return .{
        .registry_tools = try registry_tools.toOwnedSlice(alloc),
        .order = owned_order,
        .read_only_tool_names = owned_read_only,
    };
}

fn containsName(names: []const []const u8, target: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, target)) return true;
    }
    return false;
}

test "narrow preserves canonical order and filters the registry" {
    const Fixture = struct {
        fn readsOnly(_: tool_dispatch.ToolInput) bool {
            return true;
        }

        fn irreversible(_: tool_dispatch.ToolInput) bool {
            return false;
        }

        const tools = [_]tool_dispatch.Tool{
            .{ .name = "list_files", .description = "list", .model_schema = .{ .name = "list_files", .description = "list", .input_schema = .{} }, .decode = undefined, .call = undefined, .reads_only_fn = readsOnly, .irreversible_fn = irreversible },
            .{ .name = "read_file", .description = "read", .model_schema = .{ .name = "read_file", .description = "read", .input_schema = .{} }, .decode = undefined, .call = undefined, .reads_only_fn = readsOnly, .irreversible_fn = irreversible },
        };
    };
    var narrowed = (try narrow(std.testing.allocator, .{
        .registry = .{ .tools = &Fixture.tools },
        .order = &.{ "list_files", "read_file" },
        .read_only_tool_names = &.{ "list_files", "read_file" },
    }, &.{"read_file"})).?;
    defer narrowed.deinit(std.testing.allocator);
    const view = narrowed.view();
    try std.testing.expectEqual(@as(usize, 1), view.registry.tools.len);
    try std.testing.expectEqualStrings("read_file", view.order[0]);
}
