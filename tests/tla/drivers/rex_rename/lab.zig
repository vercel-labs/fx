//! Drives the Rex session rename queue (`src/core/rex_rename/queue.zig`) for
//! the TLA+ driver in this folder. It reads one JSON operation per line from
//! the file named by its first argument and writes one JSON result per
//! operation to the file named by its second.
//!
//! The lab plays the renamer's part and knows nothing about the model: it
//! holds one `State`, calls the queue function each operation names, and
//! reports the outputs and the state after every operation.
const std = @import("std");
const queue = @import("rex_rename_queue");

const Op = struct {
    op: []const u8,
};

const StateOut = struct {
    waiting: bool,
    running: bool,
    stopped: bool,
};

const Result = struct {
    state: StateOut,
    keep_title: ?bool = null,
    start_task: ?bool = null,
    apply_title: ?bool = null,
    @"error": ?[]const u8 = null,
};

fn run(state: *queue.State, op: Op, result: *Result) void {
    const is = struct {
        fn is(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.is;
    if (is(op.op, "reset")) {
        state.* = .{};
    } else if (is(op.op, "request")) {
        const out = queue.request(state.*);
        state.* = out.state;
        result.keep_title = out.keep_title;
        result.start_task = out.start_task;
    } else if (is(op.op, "take")) {
        const out = queue.take(state.*);
        state.* = out.state;
        result.apply_title = out.apply_title;
    } else if (is(op.op, "start_failed")) {
        state.* = queue.startFailed(state.*);
    } else if (is(op.op, "stop")) {
        state.* = queue.stop(state.*);
    } else {
        result.@"error" = "unknown op";
    }
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

    var state: queue.State = .{};
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const op = try std.json.parseFromSliceLeaky(Op, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
        var result: Result = .{ .state = undefined };
        run(&state, op, &result);
        result.state = .{ .waiting = state.waiting, .running = state.running, .stopped = state.stopped };
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
