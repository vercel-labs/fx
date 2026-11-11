//! Drives the quiet notice (`src/core/execution/quiet_notice.zig`) for the
//! TLA+ walk in this folder. It reads one JSON operation per line from the
//! file named by its first argument and writes one JSON result per operation
//! to the file named by its second.
//!
//! The lab plays `Runtime.wait`'s part and knows nothing about the model: it
//! keeps one command's start, last output, and exit, opens and polls one wait
//! at the times the driver names, and reports what the module decided. Like
//! `Runtime.wait`, it ends a wait on a finished command before it asks the
//! module.
const std = @import("std");
const quiet_notice = @import("quiet_notice");

const Op = struct {
    op: []const u8,
    now: i64 = 0,
    limit: u64 = 0,
    ceiling: u64 = 0,
};

const Result = struct {
    running: bool,
    waiting: bool,
    armed: bool,
    quiet_ms: u64,
    end: ?[]const u8 = null,
    ended_armed: ?bool = null,
    times: ?quiet_notice.Times = null,
    @"error": ?[]const u8 = null,
};

const Lab = struct {
    limit_ms: u64 = 0,
    started_ms: i64 = 0,
    last_output_ms: i64 = 0,
    running: bool = true,
    wait: ?quiet_notice.Wait = null,
};

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn run(lab: *Lab, op: Op, result: *Result) void {
    if (is(op.op, "walk")) {
        lab.* = .{ .limit_ms = op.limit, .started_ms = op.now, .last_output_ms = op.now };
    } else if (is(op.op, "output")) {
        if (!lab.running) result.@"error" = "output after exit";
        lab.last_output_ms = op.now;
    } else if (is(op.op, "finish")) {
        lab.running = false;
    } else if (is(op.op, "begin")) {
        if (lab.wait != null) result.@"error" = "a wait is already open";
        lab.wait = quiet_notice.beginWait(op.now, lab.last_output_ms, op.ceiling, lab.limit_ms);
    } else if (is(op.op, "poll")) {
        const wait = lab.wait orelse {
            result.@"error" = "no wait is open";
            return;
        };
        var armed = wait.armed;
        var end: ?[]const u8 = null;
        if (!lab.running) {
            end = "done";
        } else {
            const step = quiet_notice.poll(wait, op.now, lab.last_output_ms, lab.limit_ms);
            armed = step.wait.armed;
            lab.wait = step.wait;
            if (step.end) |reason| end = @tagName(reason);
        }
        if (end) |reason| {
            lab.wait = null;
            result.end = reason;
            result.ended_armed = armed;
            result.times = quiet_notice.timesFor(lab.running, op.now, lab.started_ms, lab.last_output_ms, lab.limit_ms);
        }
    } else {
        result.@"error" = "unknown op";
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // walk.ts always passes the operations file and the results file.
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
        var result: Result = .{ .running = true, .waiting = false, .armed = false, .quiet_ms = 0 };
        run(&lab, op, &result);
        result.running = lab.running;
        result.waiting = lab.wait != null;
        if (lab.wait) |wait| result.armed = wait.armed;
        result.quiet_ms = quiet_notice.quietMs(op.now, lab.last_output_ms);
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
