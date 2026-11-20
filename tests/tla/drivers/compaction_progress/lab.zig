//! Drives the compaction row's number (`src/core/output/compaction_progress.zig`,
//! through the `compaction_activity.State` that owns it) for the TLA+ driver
//! in this folder. It reads one JSON operation per line from the file named
//! by its first argument and writes one JSON result per operation to the
//! file named by its second.
//!
//! The lab plays the worker's part and knows nothing about the model: it
//! applies each event at the time the driver names, and after every
//! operation it reports the number the row shows and the marks behind it.
const std = @import("std");
const compaction_activity = @import("compaction_activity");

const Op = struct {
    op: []const u8,
    now: i64 = 0,
    percent: u8 = 0,
};

const Result = struct {
    /// The model's name for the phase: `none` without a row.
    phase: []const u8,
    /// Operation.percent at the operation's time; null without a number.
    row: ?u8,
    /// Operation.progress of the operation on the row; zeros without one.
    floor: u16 = 0,
    base: u8 = 0,
    notes: u8 = 0,
    asked_ms: i64 = 0,
    answered_ms: i64 = 0,
    @"error": ?[]const u8 = null,
};

const Lab = struct {
    activity: compaction_activity.State = .{},
    id: ?compaction_activity.OperationId = null,
    now: i64 = 0,
};

/// A settled compaction leaves no row, which the model calls `none`.
fn phaseName(lab: *const Lab) []const u8 {
    const op = lab.activity.snapshot.operation orelse return "none";
    return switch (op.phase) {
        .preparing => "preparation",
        .running => |stage| @tagName(stage),
        .stopping => "stopping",
        .terminal => "none",
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
        lab.* = .{ .now = lab.now };
    } else if (is(op.op, "begin")) {
        const id = lab.activity.begin(.manual, null, lab.now);
        lab.activity.running(id, .preparation);
        lab.id = id;
    } else if (is(op.op, "summarize")) {
        lab.activity.running(lab.id orelse return, .summary);
    } else if (is(op.op, "ask")) {
        lab.activity.asked(lab.id orelse return, lab.now);
    } else if (is(op.op, "write")) {
        lab.activity.written(lab.id orelse return, op.percent, lab.now);
    } else if (is(op.op, "save")) {
        lab.activity.running(lab.id orelse return, .publication);
    } else if (is(op.op, "settle")) {
        lab.activity.settle(lab.id orelse return, .{ .outcome = .succeeded, .stage = .publication, .publication = .committed }, lab.now);
    } else if (!is(op.op, "read")) {
        result.@"error" = "unknown op";
    }
}

fn report(lab: *const Lab, result: *Result) void {
    result.phase = phaseName(lab);
    const op = lab.activity.snapshot.operation orelse return;
    result.row = if (op.active()) op.percent(lab.now) else null;
    result.floor = op.progress.floor;
    result.base = op.progress.base;
    result.notes = op.progress.notes;
    result.asked_ms = op.progress.asked_ms;
    result.answered_ms = op.progress.answered_ms;
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
        var result: Result = .{ .phase = "none", .row = null };
        run(&lab, op, &result);
        report(&lab, &result);
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
