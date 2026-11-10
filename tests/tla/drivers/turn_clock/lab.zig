//! Drives the thinking row's clocks (`src/core/output/turn_clock.zig` and the
//! `compaction_activity.State` it reads) for the TLA+ driver in this folder.
//! It reads one JSON operation per line from the file named by its first
//! argument and writes one JSON result per operation to the file named by its
//! second.
//!
//! The lab plays the worker's and the UI thread's parts and knows nothing
//! about the model: it applies each event at the time the driver names, syncs
//! the turn clock the way `syncState` does, and reports both clocks after
//! every operation.
const std = @import("std");
const turn_clock = @import("turn_clock");
const compaction_activity = turn_clock.compaction_activity;

const Op = struct {
    op: []const u8,
    now: i64 = 0,
    origin: []const u8 = "",
    stage: []const u8 = "",
    ok: bool = true,
    open: bool = false,
};

const Result = struct {
    turn: bool,
    prompt: bool,
    started_ms: i64,
    waiting_since_ms: i64,
    turn_seconds: ?i64,
    phase: []const u8,
    compaction_seconds: ?i64,
    @"error": ?[]const u8 = null,
};

const Lab = struct {
    activity: compaction_activity.State = .{},
    id: ?compaction_activity.OperationId = null,
    marks: turn_clock.Marks = .{},
    turn: bool = false,
    prompt: bool = false,
    now: i64 = 0,
};

/// The model's name for the operation's phase: a failure or cancel still on
/// screen is `failed`; a success or a dismissed failure is `done`.
fn phaseName(lab: *const Lab) []const u8 {
    const op = lab.activity.snapshot.operation orelse return "none";
    return switch (op.phase) {
        .preparing => "preparation",
        .running => |stage| @tagName(stage),
        .stopping => "stopping",
        .terminal => if (op.visible(lab.now)) "failed" else "done",
    };
}

fn run(lab: *Lab, op: Op, result: *Result) void {
    const is = struct {
        fn is(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.is;
    if (op.now != 0) lab.now = op.now;
    if (is(op.op, "walk")) {
        lab.* = .{};
    } else if (is(op.op, "turn_start")) {
        // resetStream, then turn_started_ms = now.
        lab.turn = true;
        lab.marks = .{ .started_ms = lab.now };
    } else if (is(op.op, "turn_end")) {
        lab.turn = false;
        lab.prompt = false;
        lab.marks = .{};
    } else if (is(op.op, "prompt")) {
        lab.prompt = op.open;
    } else if (is(op.op, "begin")) {
        const origin = std.meta.stringToEnum(compaction_activity.Origin, op.origin) orelse {
            result.@"error" = "unknown origin";
            return;
        };
        const id = lab.activity.begin(origin, 1, lab.now);
        lab.activity.running(id, .preparation);
        lab.id = id;
    } else if (is(op.op, "advance")) {
        const stage = std.meta.stringToEnum(compaction_activity.Stage, op.stage) orelse {
            result.@"error" = "unknown stage";
            return;
        };
        lab.activity.running(lab.id orelse return, stage);
    } else if (is(op.op, "stop")) {
        lab.activity.stopping(lab.id orelse return);
    } else if (is(op.op, "settle")) {
        const feedback: compaction_activity.Feedback = if (op.ok)
            .{ .outcome = .succeeded, .stage = .publication, .publication = .committed }
        else
            compaction_activity.failure(error.ConnectionTimedOut, .summary, false);
        lab.activity.settle(lab.id orelse return, feedback, lab.now);
    } else if (is(op.op, "dismiss")) {
        if (!lab.activity.dismiss(lab.id orelse return, lab.activity.snapshot.revision)) result.@"error" = "dismiss refused";
    } else if (is(op.op, "sync")) {
        lab.marks = turn_clock.sync(lab.marks, lab.turn, turn_clock.waits(lab.prompt, lab.activity.snapshot), lab.now);
    } else if (!is(op.op, "read")) {
        result.@"error" = "unknown op";
    }
}

fn report(lab: *const Lab, result: *Result) void {
    result.turn = lab.turn;
    result.prompt = lab.prompt;
    result.started_ms = lab.marks.started_ms;
    result.waiting_since_ms = lab.marks.waiting_since_ms;
    result.turn_seconds = turn_clock.seconds(lab.marks, lab.now);
    result.phase = phaseName(lab);
    result.compaction_seconds = if (lab.activity.snapshot.operation) |op|
        if (op.active()) turn_clock.seconds(turn_clock.compactionMarks(op), lab.now) else null
    else
        null;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // driver.ts always passes the operations file and the results file.
    if (args.len != 3) return error.ExpectedOpsAndResultsPaths;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 31));
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
        var result: Result = .{ .turn = false, .prompt = false, .started_ms = 0, .waiting_since_ms = 0, .turn_seconds = null, .phase = "none", .compaction_seconds = null };
        run(&lab, op, &result);
        report(&lab, &result);
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
