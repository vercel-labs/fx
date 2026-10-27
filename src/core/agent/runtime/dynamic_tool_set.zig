//! The dynamic tools a session has selected (D240). A tool the model finds
//! mid-session, through `capability_search` or a direct call to a live MCP
//! tool, stays advertised for the rest of the session in the order it was
//! first selected, so every later request repeats the tool bytes of the one
//! before it and a provider's prefix cache keeps hitting across turns.
//!
//! The set is append-only: a new tool goes at the end and a changed
//! definition keeps its place. Only an explicit retirement removes one.
//! It lives on the session runtime and is never persisted; resuming or
//! resetting the session clears it.
const std = @import("std");
const io_mod = @import("../../shared/io.zig");
const types = @import("../../shared/types.zig");
const stream_provider = @import("../stream_provider.zig");
const tool_mcp_runtime = @import("../../tooling/tool_mcp_runtime.zig");

const Allocator = std.mem.Allocator;

pub const DynamicToolSet = struct {
    lock: std.Io.Mutex = .init,
    /// Owned by the allocator passed to `remember` and `deinit`.
    tools: std.ArrayList(tool_mcp_runtime.SelectedTool) = .empty,

    pub fn deinit(self: *DynamicToolSet, alloc: Allocator) void {
        self.clear(alloc);
        self.tools.deinit(alloc);
    }

    pub fn clear(self: *DynamicToolSet, alloc: Allocator) void {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        for (self.tools.items) |tool| tool.deinit(alloc);
        self.tools.clearRetainingCapacity();
    }

    /// Replaces the set with `selected`, the turn's current list. Callers
    /// keep that list append-only, so the set only grows except for a
    /// retired tool. Copies every byte with `alloc`.
    pub fn remember(self: *DynamicToolSet, alloc: Allocator, selected: []const stream_provider.DynamicFunctionTool) !void {
        var next: std.ArrayList(tool_mcp_runtime.SelectedTool) = .empty;
        defer {
            for (next.items) |tool| tool.deinit(alloc);
            next.deinit(alloc);
        }
        try next.ensureTotalCapacity(alloc, selected.len);
        for (selected) |tool| {
            const name = try alloc.dupe(u8, tool.name);
            errdefer alloc.free(name);
            const schema_json = try schemaJson(alloc, tool);
            next.appendAssumeCapacity(.{ .name = name, .schema_json = schema_json, .mcp_binding = tool.mcp_binding });
        }
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        std.mem.swap(std.ArrayList(tool_mcp_runtime.SelectedTool), &self.tools, &next);
    }

    /// Appends each remembered tool that `selected` does not already name,
    /// in the order the session first selected it. Parsed schemas are
    /// allocated in `arena`, which must outlive every request of the turn.
    pub fn restoreInto(self: *DynamicToolSet, arena: Allocator, selected: *std.ArrayList(stream_provider.DynamicFunctionTool)) !void {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        outer: for (self.tools.items) |tool| {
            for (selected.items) |existing| {
                if (std.mem.eql(u8, existing.name, tool.name)) continue :outer;
            }
            const copy: tool_mcp_runtime.SelectedTool = .{
                .name = try arena.dupe(u8, tool.name),
                .schema_json = try arena.dupe(u8, tool.schema_json),
                .mcp_binding = tool.mcp_binding,
            };
            try @import("gateway_step.zig").recordSelectedDynamicTool(arena, selected, copy);
        }
    }

    pub fn count(self: *DynamicToolSet) usize {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        return self.tools.items.len;
    }
};

/// One session's set and the allocator that owns its bytes.
pub const SessionDynamicTools = struct {
    set: *DynamicToolSet,
    alloc: Allocator,
};

/// The definition in the shape `recordSelectedDynamicTool` parses.
fn schemaJson(alloc: Allocator, tool: stream_provider.DynamicFunctionTool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(.{
        .name = tool.name,
        .description = tool.description,
        .inputSchema = tool.input_schema,
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "a remembered set restores in first-selected order after the turn's own tools" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}", .{});
    const binding: types.McpToolBinding = .{ .runtime_generation = 1, .connection_generation = 2, .catalog_generation = 3, .auth_generation = 4 };

    var set: DynamicToolSet = .{};
    defer set.deinit(alloc);
    try set.remember(alloc, &.{
        .{ .name = "mcp_b", .description = "B", .input_schema = schema, .mcp_binding = binding },
        .{ .name = "mcp_a", .description = "A", .input_schema = schema },
    });
    try std.testing.expectEqual(@as(usize, 2), set.count());

    var selected: std.ArrayList(stream_provider.DynamicFunctionTool) = .empty;
    try selected.append(arena, .{ .name = "host_tool", .description = "Host", .input_schema = schema });
    try selected.append(arena, .{ .name = "mcp_a", .description = "A from host", .input_schema = schema });
    try set.restoreInto(arena, &selected);
    try std.testing.expectEqual(@as(usize, 3), selected.items.len);
    try std.testing.expectEqualStrings("host_tool", selected.items[0].name);
    try std.testing.expectEqualStrings("A from host", selected.items[1].description);
    try std.testing.expectEqualStrings("mcp_b", selected.items[2].name);
    try std.testing.expect(selected.items[2].mcp_binding.?.sameDefinition(binding));

    // The round trip keeps the schema bytes a provider writes.
    var first: std.Io.Writer.Allocating = .init(alloc);
    defer first.deinit();
    try std.json.Stringify.value(schema, .{}, &first.writer);
    var second: std.Io.Writer.Allocating = .init(alloc);
    defer second.deinit();
    try std.json.Stringify.value(selected.items[2].input_schema, .{}, &second.writer);
    try std.testing.expectEqualStrings(first.written(), second.written());

    set.clear(alloc);
    try std.testing.expectEqual(@as(usize, 0), set.count());
}
