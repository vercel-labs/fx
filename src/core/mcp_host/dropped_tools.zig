//! The tools of a server's list that fx leaves out of what the model gets, counted by reason. The engine checks the
//! structure of a listed tool, a plain name and an `inputSchema` that is an object, and counts what `Store.addPage`
//! skips (`Server.droppedTools`). This owns the host's reading of what a tool means: `read` decides whether a listed
//! tool is kept or left out and why, and `Catalog.build` (what the model gets), `reading` (how many tools `fx mcp show`
//! and the `/mcp` screen count, and how many they say are left out) and `Runtime.copyTools` (which tools they list) all
//! go through it, so none of them can differ.
//!
//! A name belongs to the first tool that passes the engine's structure check and this reading. The engine asks `judge`,
//! which is `read`, for each tool before it gives out the name, so a tool the reading refuses takes no name, is counted by
//! its own reason, and a later tool of the name is kept; a name used again by a tool that passes both is the engine's
//! `repeated_name`. A list from an owner that predates `judge` can hold a refused tool: `reading` and `copyTools` still
//! refuse it.
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

/// The engine's judge of a tool that passed its structure check: the reason `read` leaves it out, or null when it keeps it.
/// `gpa` is only for the scratch the reading needs, and must outlive the engine that calls it.
pub fn judge(gpa: *const Allocator) tools.Judge {
    return .{ .context = gpa, .refuses = refuses };
}

fn refuses(context: *const anyopaque, raw: []const u8) Allocator.Error!?tools.Drop {
    const gpa: *const Allocator = @ptrCast(@alignCast(context));
    var scratch: std.heap.ArenaAllocator = .init(gpa.*);
    defer scratch.deinit();
    return switch (try read(scratch.allocator(), raw)) {
        .tool => null,
        .left_out => |left_out| left_out.why,
    };
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
        error.SchemaLimitExceeded, error.NestingTooDeep, error.MetadataLimitExceeded => .over_limit,
        else => .unusable,
    };
}

/// A published list of the tool objects `raws`, as the engine keeps one with no `judge`, which is how an owner that
/// predates it sends one. Public for the catalog's test of the shared decision.
pub fn listOf(gpa: Allocator, raws: []const []const u8) !tools.List {
    var store: tools.Store = .{};
    defer store.deinit(gpa);
    _ = try gather(gpa, &store, raws);
    store.publish();
    const taken = store.current;
    store.current = .{};
    return taken;
}

/// Adds the tool objects `raws` to `store` as one page; what it skipped.
fn gather(gpa: Allocator, store: *tools.Store, raws: []const []const u8) !tools.Added {
    var wrapped: std.ArrayList(u8) = .empty;
    defer wrapped.deinit(gpa);
    try wrapped.appendSlice(gpa, "{\"tools\":[");
    for (raws, 0..) |raw, k| {
        if (k > 0) try wrapped.append(gpa, ',');
        try wrapped.appendSlice(gpa, raw);
    }
    try wrapped.appendSlice(gpa, "]}");
    return store.addPage(gpa, try tools.parsePage(wrapped.items));
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

test "a tool the engine skips for its inputSchema takes no name: the reading keeps a later good tool of the name" {
    const gpa = std.testing.allocator;
    var list = try listOf(gpa, &.{
        "{\"name\":\"a\"}",
        "{\"name\":\"a\",\"description\":\"the good one\",\"inputSchema\":{\"type\":\"object\"}}",
        "{\"name\":\"flat\",\"inputSchema\":{}}",
    });
    defer list.deinit(gpa);
    // The engine skipped the first `a` and kept the second and `flat`; `flat` is the host's to refuse.
    try std.testing.expectEqual(@as(usize, 2), list.len());
    try std.testing.expect(std.mem.find(u8, list.find("a").?.raw, "the good one") != null);
    const got = try reading(gpa, &list);
    try std.testing.expectEqual(@as(u32, 1), got.kept);
    try std.testing.expectEqual(@as(u32, 1), got.dropped.counts[@backingInt(tools.Drop.unusable)]);
    try std.testing.expectEqual(@as(u32, 1), got.dropped.total());
}

test "the host has no reason of its own for an inputSchema that is missing or no object: the engine owns that rule" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const never_listed = [_][]const u8{
        "{\"name\":\"x\"}",
        "{\"name\":\"x\",\"inputSchema\":null}",
        "{\"name\":\"x\",\"inputSchema\":[]}",
        "{\"name\":\"x\",\"inputSchema\":\"x\"}",
    };
    for (never_listed) |raw| {
        const got = try read(arena.allocator(), raw);
        switch (got) {
            .left_out => |left_out| try std.testing.expectEqual(tools.Drop.unusable, left_out.why),
            .tool => return error.TestUnexpectedResult,
        }
    }
}

const meaningless_a = "{\"name\":\"a\",\"description\":\"meaningless\",\"inputSchema\":{}}";
const first_a = "{\"name\":\"a\",\"description\":\"first\",\"inputSchema\":{\"type\":\"object\"}}";
const second_a = "{\"name\":\"a\",\"description\":\"second\",\"inputSchema\":{\"type\":\"object\"}}";

test "a name belongs to the first tool that passes the structure check and the reading, whatever the order" {
    const gpa = std.testing.allocator;
    const orders = [_]struct { raws: []const []const u8, unusable: u32, repeated: u32 }{
        .{ .raws = &.{ meaningless_a, first_a }, .unusable = 1, .repeated = 0 },
        .{ .raws = &.{ first_a, meaningless_a }, .unusable = 1, .repeated = 0 },
        .{ .raws = &.{ meaningless_a, first_a, second_a }, .unusable = 1, .repeated = 1 },
        .{ .raws = &.{ first_a, meaningless_a, second_a }, .unusable = 1, .repeated = 1 },
        .{ .raws = &.{ meaningless_a, meaningless_a, first_a }, .unusable = 2, .repeated = 0 },
    };
    for (orders) |order| {
        var store: tools.Store = .{ .judge = judge(&gpa) };
        defer store.deinit(gpa);
        const added = try gather(gpa, &store, order.raws);
        store.publish();
        try std.testing.expectEqual(@as(usize, 1), store.current.len());
        try std.testing.expect(std.mem.find(u8, store.current.find("a").?.raw, "first") != null);

        // The engine counts the tools it left out, each by its own reason, and the reading of the list it kept finds
        // nothing more to refuse: the host's count is the sum, and the model gets the one tool.
        const left = added.dropped();
        try std.testing.expectEqual(order.unusable, left.counts[@backingInt(tools.Drop.unusable)]);
        try std.testing.expectEqual(order.repeated, left.counts[@backingInt(tools.Drop.repeated_name)]);
        try std.testing.expectEqual(order.unusable + order.repeated, left.total());
        const got = try reading(gpa, &store.current);
        try std.testing.expectEqual(@as(u32, 1), got.kept);
        try std.testing.expectEqual(@as(u32, 0), got.dropped.total());
    }
}

test "the judge gives the reason read gives, for every tool the structure check keeps" {
    const gpa = std.testing.allocator;
    const wide_schema = try wide(gpa, 5000);
    defer gpa.free(wide_schema);
    const too_big = try gpa.print("{{\"name\":\"big\",\"inputSchema\":{s}}}", .{wide_schema});
    defer gpa.free(too_big);
    const raws = [_][]const u8{
        first_a,
        meaningless_a,
        too_big,
        "{\"name\":\"odd\",\"description\":7,\"inputSchema\":{\"type\":\"object\"}}",
    };
    const reasons = [_]?tools.Drop{ null, .unusable, .over_limit, .unusable };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (raws, reasons) |raw, want| {
        try std.testing.expectEqual(want, try judge(&gpa).refuses(judge(&gpa).context, raw));
        switch (try read(arena.allocator(), raw)) {
            .tool => try std.testing.expectEqual(@as(?tools.Drop, null), want),
            .left_out => |left_out| try std.testing.expectEqual(want, left_out.why),
        }
    }
}

test "a list an owner without the judge sent holds the refused tool: the reading still refuses it" {
    const gpa = std.testing.allocator;
    // The engine of such an owner kept the first `a`, which the host refuses, and skipped the second: the host reads what
    // it was given, and the session that gets the list is no worse than it was.
    var list = try listOf(gpa, &.{ meaningless_a, first_a });
    defer list.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), list.len());
    const got = try reading(gpa, &list);
    try std.testing.expectEqual(@as(u32, 0), got.kept);
    try std.testing.expectEqual(@as(u32, 1), got.dropped.counts[@backingInt(tools.Drop.unusable)]);
}
