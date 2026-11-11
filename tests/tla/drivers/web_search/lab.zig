//! Drives the web search slot state (`src/core/tooling/web_search_slots.zig`)
//! for the TLA+ driver in this folder. It reads one JSON operation per line
//! from the file named by its first argument and writes one JSON result per
//! operation to the file named by its second.
//!
//! The lab plays the hosts' part and knows nothing about the model: it sets
//! the order, builds a request's view for the team the driver names, records
//! a refusal for the team the driver names, makes a team current as a turn's
//! configure does, and reports what the team the driver calls current has
//! refused after every operation.
const std = @import("std");
const web_search_slots = @import("web_search_slots");

const Op = struct {
    op: []const u8,
    team: []const u8 = "",
    current: []const u8 = "",
    slot: []const u8 = "",
    order: []const []const u8 = &.{},
};

const Result = struct {
    /// The slot a request built by this operation carries.
    slot: ?[]const u8 = null,
    /// The slots this operation newly blocked, for the notices.
    newly: []const []const u8 = &.{},
    /// What the current team has refused after the operation.
    blocked: []const []const u8 = &.{},
    @"error": ?[]const u8 = null,
};

fn names(arena: std.mem.Allocator, bits: u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (web_search_slots.configurable) |slot| {
        if (bits & (@as(u8, 1) << @backingInt(slot)) != 0) try out.append(arena, slot.name());
    }
    return out.items;
}

fn run(arena: std.mem.Allocator, state: *web_search_slots.State, op: Op, result: *Result) !void {
    const is = struct {
        fn is(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.is;
    if (is(op.op, "walk")) {
        state.* = .{};
        var offending: []const u8 = "";
        const order = web_search_slots.parseOrder(op.order, &offending) catch {
            result.@"error" = "bad order";
            return;
        };
        state.setOrder(order);
    } else if (is(op.op, "send")) {
        result.slot = state.view(op.team).slot(true).name();
    } else if (is(op.op, "block")) {
        const slot = web_search_slots.parseName(op.slot) orelse {
            result.@"error" = "unknown slot";
            return;
        };
        result.newly = try names(arena, state.block(op.team, @as(u8, 1) << @backingInt(slot)));
    } else if (is(op.op, "adopt")) {
        _ = state.view(op.team);
    } else {
        result.@"error" = "unknown op";
        return;
    }
    result.blocked = try names(arena, state.blockedFor(op.current));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // driver.ts always passes the operations file and the results file.
    if (args.len != 3) return error.ExpectedOpsAndResultsPaths;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 30));
    var file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const out = &file_writer.interface;

    var state: web_search_slots.State = .{};
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const op = try std.json.parseFromSliceLeaky(Op, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
        var result: Result = .{};
        try run(scratch.allocator(), &state, op, &result);
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
