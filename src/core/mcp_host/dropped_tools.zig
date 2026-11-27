//! The tools of a server's list that fx leaves out of what the model gets, counted by reason. The engine keeps a tool it
//! can index, a plain name, and counts what `Store.addPage` skips for that (`Server.droppedTools`). This owns the host's
//! reading of a tool: `read` decides whether a listed tool is kept or left out and why, and `Catalog.build` (what the
//! model gets), `reading` (how many tools `fx mcp show` and the `/mcp` screen count, and how many they say are left out)
//! and `Runtime.copyTools` (which tools they list) all go through it, so none of them can differ.
//!
//! One skip is not counted. `Catalog.build` also leaves out a tool whose name no longer fits the session's full alias
//! registry (`McpToolNameLimitExceeded`, 65,536 names): that needs the session's name registry, which the runtime that
//! counts does not have, so it is only traced.

const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const tools_feature = @import("../mcp/features/tools.zig");

const Allocator = std.mem.Allocator;
const tools = mcp.tools;

/// What the host's reading makes of one listed tool.
pub const Read = union(enum) {
    /// The tool, allocated in the caller's allocator.
    tool: tools_feature.Tool,
    /// Left out: `why` is the closed reason, `err` what the reading said, for the trace.
    left_out: struct { why: tools.Drop, err: tools_feature.Error },
};

/// Reads the tool object `raw` the way the model's catalog does. The one place that decides whether the host keeps a
/// listed tool.
pub fn read(a: Allocator, raw: []const u8) Allocator.Error!Read {
    const parsed = tools_feature.parseToolJson(a, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |refused| return .{ .left_out = .{ .why = reasonOf(refused), .err = refused } },
    };
    return .{ .tool = parsed };
}

/// What the host's reading makes of a whole list.
pub const Reading = struct {
    /// The tools it keeps.
    kept: u32 = 0,
    /// The tools it leaves out, by reason.
    dropped: tools.Dropped = .{},
};

/// Reads each tool of `list` once; nothing it allocates outlives the call.
pub fn reading(gpa: Allocator, list: *const tools.List) Allocator.Error!Reading {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var out: Reading = .{};
    for (0..list.len()) |k| {
        _ = scratch.reset(.retain_capacity);
        switch (try read(scratch.allocator(), list.get(k).raw)) {
            .tool => out.kept +|= 1,
            .left_out => |left_out| out.dropped.add(left_out.why, 1),
        }
    }
    return out;
}

/// The reason for an error `parseToolJson` gave, from a closed set: nothing the server wrote is in it.
fn reasonOf(err: tools_feature.Error) tools.Drop {
    return switch (err) {
        error.UnnamedTool => .unnamed,
        error.SchemaLimitExceeded, error.NestingTooDeep, error.MetadataLimitExceeded => .over_limit,
        else => .unusable,
    };
}

/// A published list of the tool objects `raws`, as the engine keeps one. Public for the catalog's test of the shared
/// decision.
pub fn listOf(gpa: Allocator, raws: []const []const u8) !tools.List {
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

/// A schema with `n` properties: the host refuses one past 4096 values, and the engine's scanner reads it. Public for
/// the catalog's test of the shared decision.
pub fn wide(gpa: Allocator, n: usize) ![]u8 {
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
    const got = try reading(gpa, &list);
    try std.testing.expectEqual(@as(u32, 2), got.kept);
    try std.testing.expectEqual(@as(u32, 2), got.dropped.total());
    try std.testing.expectEqual(@as(u32, 1), got.dropped.counts[@backingInt(tools.Drop.over_limit)]);
    try std.testing.expectEqual(@as(u32, 1), got.dropped.counts[@backingInt(tools.Drop.unusable)]);
    try std.testing.expectEqual(@as(?tools.Drop, null), got.dropped.single());
}

test "a list whose tools all read cleanly counts nothing, and an empty one too" {
    const gpa = std.testing.allocator;
    var list = try listOf(gpa, &.{"{\"name\":\"good\",\"inputSchema\":{\"type\":\"object\"}}"});
    defer list.deinit(gpa);
    const clean = try reading(gpa, &list);
    try std.testing.expectEqual(@as(u32, 1), clean.kept);
    try std.testing.expectEqual(@as(u32, 0), clean.dropped.total());
    var none: tools.List = .{};
    const empty = try reading(gpa, &none);
    try std.testing.expectEqual(@as(u32, 0), empty.kept);
    try std.testing.expectEqual(@as(u32, 0), empty.dropped.total());
}

test "the engine keeps a tool whose inputSchema is missing or no object, and the host's reading leaves it out as unnamed" {
    const gpa = std.testing.allocator;
    var list = try listOf(gpa, &.{
        "{\"name\":\"good\",\"inputSchema\":{\"type\":\"object\"}}",
        "{\"name\":\"none\"}",
        "{\"name\":\"list\",\"inputSchema\":[]}",
        "{\"name\":\"flat\",\"inputSchema\":{}}",
    });
    defer list.deinit(gpa);
    // The engine indexes all four: it judges a plain name, and the rest is the host's to read.
    try std.testing.expectEqual(@as(usize, 4), list.len());
    const got = try reading(gpa, &list);
    try std.testing.expectEqual(@as(u32, 1), got.kept);
    try std.testing.expectEqual(@as(u32, 2), got.dropped.counts[@backingInt(tools.Drop.unnamed)]);
    try std.testing.expectEqual(@as(u32, 1), got.dropped.counts[@backingInt(tools.Drop.unusable)]);
}
