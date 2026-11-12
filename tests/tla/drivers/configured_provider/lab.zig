//! Drives the per-connection request bounds (`src/gateway/request_deadlines.zig`)
//! for the TLA+ driver in this folder. It reads one JSON operation per line
//! from the file named by its first argument and writes one JSON result per
//! operation to the file named by its second.
//!
//! The lab owns the clock, which the module never reads: one model tick is
//! `tick_ms` milliseconds, and the bounds are the model's, in ticks. It knows
//! nothing else about the model. After every operation it reports the wait
//! the module is in, how long that wait and the response's silence have
//! lasted, and whether the module says the wait has run out.
const std = @import("std");
const request_deadlines = @import("request_deadlines");

const tick_ms: u64 = 100;
const max_clock_ticks: u64 = 4;
const bounds: request_deadlines.Bounds = .{
    .connect_ms = 1 * tick_ms,
    .first_response_ms = 2 * tick_ms,
    .stall_ms = 2 * tick_ms,
};

const Op = struct {
    op: []const u8,
};

const Result = struct {
    phase: []const u8,
    clock: u64,
    quiet: u64,
    cause: []const u8,
    waited: u64,
    due: bool,
    @"error": ?[]const u8 = null,
};

const Lab = struct {
    deadlines: request_deadlines.Deadlines,
    now_ms: u64,
    wait_started_ms: u64,
    last_bytes_ms: u64,
    ended: enum { no, completed, failed } = .no,
    cause: ?request_deadlines.Wait = null,
    waited_ms: u64 = 0,

    // A start far from zero, so a module that subtracts the wrong way shows.
    const epoch_ms: u64 = 1_000_000;

    fn init() Lab {
        return .{
            .deadlines = .init(bounds, epoch_ms),
            .now_ms = epoch_ms,
            .wait_started_ms = epoch_ms,
            .last_bytes_ms = epoch_ms,
        };
    }

    fn ticks(self: *const Lab, since_ms: u64) u64 {
        return @min((self.now_ms - since_ms) / tick_ms, max_clock_ticks);
    }
};

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn run(lab: *Lab, op: Op) ?[]const u8 {
    if (is(op.op, "walk")) {
        lab.* = .init();
        return null;
    }
    if (lab.ended != .no) return "the request has ended";
    if (is(op.op, "tick")) {
        // Time always moves. The model's clocks stop at their cap, and
        // `ticks` reports them capped the same way.
        lab.now_ms += tick_ms;
    } else if (is(op.op, "connects")) {
        lab.deadlines.connected(lab.now_ms);
        lab.wait_started_ms = lab.now_ms;
        lab.last_bytes_ms = lab.now_ms;
    } else if (is(op.op, "head")) {
        lab.deadlines.headArrived(lab.now_ms);
        lab.wait_started_ms = lab.now_ms;
        lab.last_bytes_ms = lab.now_ms;
    } else if (is(op.op, "bytes")) {
        lab.deadlines.bytes(lab.now_ms);
        lab.last_bytes_ms = lab.now_ms;
    } else if (is(op.op, "completes")) {
        lab.ended = .completed;
    } else if (is(op.op, "expires")) {
        const wait = lab.deadlines.expired(lab.now_ms) orelse return "the module says no wait has run out";
        lab.ended = .failed;
        lab.cause = wait;
        lab.waited_ms = lab.now_ms - (if (wait == .streaming) lab.last_bytes_ms else lab.wait_started_ms);
    } else {
        return "unknown op";
    }
    return null;
}

fn report(lab: *const Lab, failure: ?[]const u8) Result {
    return .{
        .phase = switch (lab.ended) {
            .no => @tagName(lab.deadlines.wait),
            .completed => "completed",
            .failed => "failed",
        },
        .clock = lab.ticks(lab.wait_started_ms),
        .quiet = lab.ticks(lab.last_bytes_ms),
        .cause = if (lab.cause) |wait| @tagName(wait) else "none",
        .waited = @min(lab.waited_ms / tick_ms, max_clock_ticks),
        .due = lab.ended == .no and lab.deadlines.expired(lab.now_ms) != null,
        .@"error" = failure,
    };
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

    var lab: Lab = .init();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const op = try std.json.parseFromSliceLeaky(Op, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
        const failure = run(&lab, op);
        try std.json.Stringify.value(report(&lab, failure), .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
