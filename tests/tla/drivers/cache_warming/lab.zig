//! Drives the cache-warming planner (`src/core/agent/runtime/cache_warming.zig`)
//! for the TLA+ driver in this folder. It reads one JSON operation per line
//! from the file named by its first argument and writes one JSON result per
//! operation to the file named by its second.
//!
//! The lab plays the warmer's part and knows nothing about the model: it
//! delivers each event at the time the driver names, answers the ping on the
//! wire with the outcome the driver names, and reports the planner's plan
//! and state after every operation.
const std = @import("std");
const cache_warming = @import("cache_warming");

const Op = struct {
    op: []const u8,
    ttl: i64 = 0,
    cap: i64 = 0,
    now: i64 = 0,
    started: i64 = 0,
    outcome: []const u8 = "",
};

const PlanOut = struct {
    kind: []const u8,
    at: ?i64 = null,
    stop: ?[]const u8 = null,
};

const StateOut = struct {
    armed: bool,
    pings: u32,
    in_flight: bool,
    stopped: []const u8,
    last_touch: i64,
    request_started: i64,
};

const Result = struct {
    plan: ?PlanOut = null,
    state: StateOut,
    @"error": ?[]const u8 = null,
};

const Lab = struct {
    state: cache_warming.State = .{},
    timing: cache_warming.Timing = .{ .ttl_ms = 20, .cap_ms = 20 },
};

fn planOut(plan: cache_warming.Plan) PlanOut {
    return switch (plan) {
        .idle => .{ .kind = "idle" },
        .wait_until => |at| .{ .kind = "wait_until", .at = at },
        .wait_for_answer => .{ .kind = "wait_for_answer" },
        .ping => .{ .kind = "ping" },
        .stopped => |reason| .{ .kind = "stopped", .stop = @tagName(reason) },
    };
}

fn stateOut(state: *const cache_warming.State) StateOut {
    return .{
        .armed = state.armed,
        .pings = state.pings,
        .in_flight = state.in_flight != null,
        .stopped = if (state.stopped) |reason| @tagName(reason) else "none",
        .last_touch = state.last_touch_ms,
        .request_started = state.request_started_ms,
    };
}

fn run(lab: *Lab, op: Op, result: *Result) void {
    const is = struct {
        fn is(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.is;
    const event: cache_warming.Event = if (is(op.op, "walk")) {
        lab.* = .{ .timing = .{ .ttl_ms = op.ttl, .cap_ms = op.cap } };
        return;
    } else if (is(op.op, "armed"))
        .{ .armed = .{ .now_ms = op.now, .started_ms = op.started } }
    else if (is(op.op, "disarmed"))
        .{ .disarmed = .{ .now_ms = op.now } }
    else if (is(op.op, "woke"))
        .{ .woke = .{ .now_ms = op.now } }
    else if (is(op.op, "answered")) answered: {
        const generation = lab.state.in_flight orelse {
            result.@"error" = "no ping on the wire";
            return;
        };
        const outcome = std.meta.stringToEnum(cache_warming.Outcome, op.outcome) orelse {
            result.@"error" = "unknown outcome";
            return;
        };
        break :answered .{ .answered = .{ .now_ms = op.now, .generation = generation, .outcome = outcome } };
    } else {
        result.@"error" = "unknown op";
        return;
    };
    result.plan = planOut(cache_warming.step(&lab.state, lab.timing, event));
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

    var lab: Lab = .{};
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const op = try std.json.parseFromSliceLeaky(Op, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
        var result: Result = .{ .state = undefined };
        run(&lab, op, &result);
        result.state = stateOut(&lab.state);
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
