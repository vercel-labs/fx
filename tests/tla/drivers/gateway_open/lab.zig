//! Drives the connection-open hand-off (`src/gateway/open_job.zig`) for the
//! TLA+ driver in this folder. It reads one JSON operation per line from the
//! file named by its first argument and writes one JSON result per operation
//! to the file named by its second.
//!
//! The lab plays both sides the way `src/gateway/client.zig` does and knows
//! nothing about the model: the job's open returns when the driver says, the
//! job then publishes and closes a late connection when told to, and the
//! waiting request polls with Esc as the driver set it. After every
//! operation it reports what each side holds.
const std = @import("std");
const open_job = @import("open_job");

const Op = struct {
    op: []const u8,
};

const StateOut = struct {
    worker: []const u8,
    job: []const u8,
    conn: []const u8,
    state: []const u8,
    cancelled: bool,
};

const Result = struct {
    state: StateOut,
    @"error": ?[]const u8 = null,
};

const Lab = struct {
    handoff: open_job.Handoff = .{},
    worker: enum { waiting, returned, using } = .waiting,
    job: enum { lookup, finished, published } = .lookup,
    conn: enum { none, open, closed } = .none,
    cancelled: bool = false,
};

fn run(lab: *Lab, op: Op, result: *Result) void {
    const is = struct {
        fn is(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.is;
    if (is(op.op, "walk")) {
        lab.* = .{};
    } else if (is(op.op, "cancel")) {
        lab.cancelled = true;
    } else if (is(op.op, "lookup_returns")) {
        if (lab.job != .lookup) result.@"error" = "the open already returned";
        lab.job = .finished;
        lab.conn = .open;
    } else if (is(op.op, "job_publish")) {
        if (lab.job != .finished) result.@"error" = "nothing to publish";
        lab.job = .published;
        switch (lab.handoff.publish()) {
            .hand_over => {},
            .close_late => lab.conn = .closed,
        }
    } else if (is(op.op, "worker_poll")) {
        if (lab.worker != .waiting) result.@"error" = "the request is not waiting";
        if (lab.cancelled) switch (lab.handoff.stop()) {
            .walk_away => lab.worker = .returned,
            .close_handed => {
                lab.conn = .closed;
                lab.worker = .returned;
            },
        } else switch (lab.handoff.poll()) {
            .wait => {},
            .take => lab.worker = .using,
        }
    } else {
        result.@"error" = "unknown op";
    }
}

fn stateOut(lab: *const Lab) StateOut {
    return .{
        .worker = @tagName(lab.worker),
        .job = @tagName(lab.job),
        .conn = @tagName(lab.conn),
        .state = @tagName(lab.handoff.state.load(.acquire)),
        .cancelled = lab.cancelled,
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
        result.state = stateOut(&lab);
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
