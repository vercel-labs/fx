//! The tools of a server's list that fx leaves out of what the model gets, counted by reason. The engine counts what
//! `Store.addPage` skips (`Server.droppedTools`). This counts what the host's own reading of a tool refuses
//! (`parseToolJson`, which `Catalog.build` applies to the same tools), so `fx mcp show` and the `/mcp` screen can say
//! what the trace line "MCP tool left out" said alone.

const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const tools_feature = @import("../mcp/features/tools.zig");

const Allocator = std.mem.Allocator;
const tools = mcp.tools;

/// How many tools of `list` the host's reading refuses, by reason. Reads each tool once; nothing it allocates outlives
/// the call.
pub fn count(gpa: Allocator, list: *const tools.List) Allocator.Error!tools.Dropped {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var out: tools.Dropped = .{};
    for (0..list.len()) |k| {
        _ = scratch.reset(.retain_capacity);
        _ = tools_feature.parseToolJson(scratch.allocator(), list.get(k).raw, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |refused| out.add(reasonOf(refused), 1),
        };
    }
    return out;
}

/// The reason for an error `parseToolJson` gave, from a closed set: nothing the server wrote is in it.
fn reasonOf(err: tools_feature.Error) tools.Drop {
    return switch (err) {
        error.SchemaLimitExceeded, error.NestingTooDeep, error.MetadataLimitExceeded => .over_limit,
        else => .unusable,
    };
}

fn listOf(gpa: Allocator, raws: []const []const u8) !tools.List {
    var wrapped: std.ArrayList(u8) = .empty;
    defer wrapped.deinit(gpa);
    try wrapped.appendSlice(gpa, "{\"tools\":[");
    for (raws, 0..) |raw, k| {
        if (k > 0) try wrapped.append(gpa, ',');
        try wrapped.appendSlice(gpa, raw);
    }
    try wrapped.appendSlice(gpa, "]}");
    var store: tools.Store = .{};
    defer store.deinit(gpa);
    _ = try store.addPage(gpa, try tools.parsePage(wrapped.items));
    store.publish();
    const taken = store.current;
    store.current = .{};
    return taken;
}

/// A schema with `n` properties: the host refuses one past 4096 values, and the engine's scanner reads it.
fn wide(gpa: Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"type\":\"object\",\"properties\":{");
    for (0..n) |k| {
        if (k > 0) try out.append(gpa, ',');
        try out.print(gpa, "\"p{d}\":{{}}", .{k});
    }
    try out.appendSlice(gpa, "}}");
    return out.toOwnedSlice(gpa);
}

test "a tool the host's reading refuses is counted by why; a good one and a repeated name are not" {
    const gpa = std.testing.allocator;
    const wide_schema = try wide(gpa, 5000);
    defer gpa.free(wide_schema);
    const too_big = try gpa.print("{{\"name\":\"big\",\"inputSchema\":{s}}}", .{wide_schema});
    defer gpa.free(too_big);
    var list = try listOf(gpa, &.{
        "{\"name\":\"good\",\"inputSchema\":{\"type\":\"object\"}}",
        too_big,
        "{\"name\":\"odd\",\"description\":7,\"inputSchema\":{\"type\":\"object\"}}",
        "{\"name\":\"twin\",\"inputSchema\":{\"type\":\"object\"}}",
        "{\"name\":\"twin\",\"inputSchema\":{\"type\":\"object\"}}",
    });
    defer list.deinit(gpa);
    // The engine's `addPage` kept the first `twin` and skipped the second; this counts only what is left.
    try std.testing.expectEqual(@as(usize, 4), list.len());
    const got = try count(gpa, &list);
    try std.testing.expectEqual(@as(u32, 2), got.total());
    try std.testing.expectEqual(@as(u32, 1), got.counts[@backingInt(tools.Drop.over_limit)]);
    try std.testing.expectEqual(@as(u32, 1), got.counts[@backingInt(tools.Drop.unusable)]);
    try std.testing.expectEqual(@as(?tools.Drop, null), got.single());
}

test "a list whose tools all read cleanly counts nothing, and an empty one too" {
    const gpa = std.testing.allocator;
    var list = try listOf(gpa, &.{"{\"name\":\"good\",\"inputSchema\":{\"type\":\"object\"}}"});
    defer list.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), (try count(gpa, &list)).total());
    var none: tools.List = .{};
    try std.testing.expectEqual(@as(u32, 0), (try count(gpa, &none)).total());
}
