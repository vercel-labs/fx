//! The depth limit on a server's JSON, where the host turns it into a value.
//!
//! The engine hands the host a message up to about 2,580 levels deep. Writers then write that value, or
//! a part of it, again with `std.json.Stringify`, which keeps its nesting in a stack of 256 levels in a
//! safe build (Debug and ReleaseSafe, `std/json/Stringify.zig` `nesting_stack`) and aborts past it. So
//! each place that reads a server's JSON into a value checks it with `require` first: a tool call's
//! result and an error's data (`features/tools.zig`), a listed tool (`features/tools.zig`) and an
//! elicitation form (`elicitation.zig`). There is no per-writer limit.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");

/// The deepest value fx accepts from a server: 128 levels of arrays and objects, where `{}` is one level.
/// `std.json.Stringify` holds 256 levels, and a writer wraps the value it writes in at most 4 more
/// (headroom: none adds more than 2 today, `bridgeResultData`'s envelope), so 128 leaves room.
/// `tests/tla/mcp/WireDepth.tla` `NoWriterOverflow`: whatever an entry point accepts, every writer behind
/// it can write. Change this limit only with that model's `Limit` and `Capacity`.
pub const max_server_json_depth: usize = 128;

/// Where a value too deep was met, as the trace names it.
pub const Place = enum { result, tool, form, data };

const Frame = union(enum) {
    array: struct { items: []const std.json.Value, next: usize },
    object: std.json.ObjectMap.Iterator,
};

/// Whether `value` is at most `max` levels deep. The walk keeps its own stack of at most
/// `max_server_json_depth` frames, never recurses, and stops at the first level past `max`, so a value
/// nested a hundred thousand levels deep costs no more than one nested 129.
pub fn within(value: std.json.Value, max: usize) bool {
    std.debug.assert(max <= max_server_json_depth);
    var stack: [max_server_json_depth]Frame = undefined;
    var len: usize = 0;
    var pending: ?std.json.Value = value;
    while (true) {
        if (pending) |entered| {
            pending = null;
            switch (entered) {
                .array => |array| {
                    if (len == max) return false;
                    stack[len] = .{ .array = .{ .items = array.items, .next = 0 } };
                    len += 1;
                },
                .object => |object| {
                    if (len == max) return false;
                    stack[len] = .{ .object = object.iterator() };
                    len += 1;
                },
                else => {},
            }
        }
        if (len == 0) return true;
        switch (stack[len - 1]) {
            .array => |*frame| {
                if (frame.next < frame.items.len) {
                    pending = frame.items[frame.next];
                    frame.next += 1;
                } else len -= 1;
            },
            .object => |*iterator| {
                if (iterator.next()) |entry| pending = entry.value_ptr.* else len -= 1;
            },
        }
    }
}

/// Writes the trace line for a value refused past the limit: the code, the limit and the place, and
/// nothing the server sent.
pub fn traceRefused(place: Place) void {
    debug_trace.logf("mcp", "MCP server JSON refused code=NestingTooDeep limit={d} at={t}", .{ max_server_json_depth, place });
}

/// `value` as it is, or `error.NestingTooDeep` with its trace line.
pub fn require(value: std.json.Value, place: Place) error{NestingTooDeep}!void {
    if (within(value, max_server_json_depth)) return;
    traceRefused(place);
    return error.NestingTooDeep;
}

fn nested(arena: std.mem.Allocator, depth: usize, shape: enum { arrays, objects, mixed }) !std.json.Value {
    var value: std.json.Value = .{ .integer = 1 };
    for (0..depth) |level| {
        const object = shape == .objects or (shape == .mixed and level % 2 == 0);
        if (object) {
            var map: std.json.ObjectMap = .empty;
            try map.put(arena, "a", value);
            value = .{ .object = map };
        } else {
            var array = std.json.Array.init(arena);
            try array.append(value);
            value = .{ .array = array };
        }
    }
    return value;
}

test "a scalar is no level, and an empty array or object is one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(within(.{ .integer = 1 }, 0));
    try std.testing.expect(within(.null, 0));
    try std.testing.expect(within(.{ .string = "[[[[[[[[[[" }, 0));
    try std.testing.expect(!within(try nested(arena, 1, .arrays), 0));
    try std.testing.expect(within(try nested(arena, 1, .arrays), 1));
    try std.testing.expect(within(.{ .object = .empty }, 1));
    try std.testing.expect(!within(.{ .object = .empty }, 0));
}

test "a value at the limit is within it and one level more is not, whatever its shape" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    inline for (.{ .arrays, .objects, .mixed }) |shape| {
        for ([_]usize{ 1, 2, 64, 127, 128 }) |depth| {
            try std.testing.expect(within(try nested(arena, depth, shape), max_server_json_depth));
        }
        for ([_]usize{ 129, 130, 256, 257, 1000 }) |depth| {
            try std.testing.expect(!within(try nested(arena, depth, shape), max_server_json_depth));
        }
    }
    // A smaller max is honoured exactly.
    try std.testing.expect(within(try nested(arena, 5, .objects), 5));
    try std.testing.expect(!within(try nested(arena, 6, .objects), 5));
}

test "a value a hundred thousand levels deep is refused without recursion or a long walk" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(!within(try nested(arena, 100_000, .arrays), max_server_json_depth));
    try std.testing.expect(!within(try nested(arena, 100_000, .mixed), max_server_json_depth));
}

test "a wide shallow value is within the limit however many items it has" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var array = std.json.Array.init(arena);
    for (0..200_000) |index| try array.append(.{ .integer = @intCast(index) });
    try std.testing.expect(within(.{ .array = array }, max_server_json_depth));
    // The depth is the deepest branch, not the sum of the branches.
    var wide = std.json.Array.init(arena);
    for (0..1000) |_| try wide.append(try nested(arena, 100, .objects));
    try std.testing.expect(within(.{ .array = wide }, max_server_json_depth));
    var one_deep = std.json.Array.init(arena);
    for (0..1000) |_| try one_deep.append(try nested(arena, 127, .objects));
    try one_deep.append(try nested(arena, 128, .objects));
    try std.testing.expect(!within(.{ .array = one_deep }, max_server_json_depth));
}

test "require passes a value within the limit and refuses a deeper one with the trace line" {
    const alloc = std.testing.allocator;
    const depth_testing = @import("json_depth_testing.zig");
    var capture = try depth_testing.TraceCapture.start(alloc);
    defer capture.stop();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try require(try nested(arena, 128, .objects), .result);
    try std.testing.expectError(error.NestingTooDeep, require(try nested(arena, 129, .objects), .tool));
    var lines = try capture.lines("JSON refused");
    defer {
        for (lines.items) |line| alloc.free(line);
        lines.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("MCP server JSON refused code=NestingTooDeep limit=128 at=tool", lines.items[0]);
}
