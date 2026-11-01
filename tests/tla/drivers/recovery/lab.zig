//! Drives the request-recovery module (`src/core/recovery/`) for the TLA+
//! driver in this folder. It reads one JSON operation per line from the file
//! named by its first argument and writes one JSON result per operation to
//! the file named by its second.
//!
//! The lab plays fx's part around the module and knows nothing about the
//! model: it keeps the saved record and the clock, and it carries out each
//! plan. A save is durable as soon as the plan asks for it, as the model
//! assumes. The lab decodes saved records from the byte layout
//! `recovery.zig` documents, so the format is checked as well.
const std = @import("std");
const recovery = @import("recovery");

const start_ms: u64 = 1_000_000;
const tick_ms: u64 = 1_000;
/// A wait never passes 30 s, so a deadline is always within this many ticks.
const max_wait_ticks: u32 = 120;

const Op = struct {
    op: []const u8,
    @"resume": bool = false,
    name: []const u8 = "",
    kind: []const u8 = "",
};

const SendOut = struct { compact: bool, no_fast: bool };
const StatusOut = struct { kind: []const u8, need: ?[]const u8 };

const PlanOut = struct {
    save: bool = false,
    send: ?SendOut = null,
    status: ?StatusOut = null,
    finish: ?[]const u8 = null,
};

const StateOut = struct {
    phase: []const u8,
    need: ?[]const u8,
    attempt: u16,
    deaths: u8,
    clean: bool,
    flowing: bool,
};

const DiskOut = struct {
    ph: []const u8,
    clean: bool = false,
    deaths: u8 = 0,
    need: ?[]const u8 = null,
};

const Result = struct {
    plan: ?PlanOut = null,
    state: StateOut,
    disk: ?DiskOut,
    @"error": ?[]const u8 = null,
};

const Lab = struct {
    state: recovery.State = .{},
    /// The saved record, or null when there is none.
    disk: ?recovery.Record = null,
    now_ms: u64 = start_ms,

    fn step(lab: *Lab, event: recovery.Event) recovery.Plan {
        const plan = recovery.step(&lab.state, event, lab.now_ms);
        if (plan.save) |save| lab.disk = save;
        if (plan.finish != null) lab.disk = null;
        return plan;
    }

    /// Ticks once a second until the module sends.
    fn wait(lab: *Lab) recovery.Plan {
        var merged: recovery.Plan = .{};
        for (0..max_wait_ticks) |_| {
            lab.now_ms += tick_ms;
            const plan = lab.step(.tick);
            if (plan.status) |status| merged.status = status;
            if (plan.save) |save| merged.save = save;
            if (plan.send) |send| {
                merged.send = send;
                return merged;
            }
        }
        return merged;
    }
};

fn stateOut(state: *const recovery.State) StateOut {
    return .{
        .phase = @tagName(state.phase),
        .need = if (state.need) |need| @tagName(need) else null,
        .attempt = state.attempt,
        .deaths = state.abrupt_deaths,
        .clean = state.flags.clean_exit,
        .flowing = state.flowing,
    };
}

/// The record as `recovery.zig` documents its layout: byte 0 version 1,
/// byte 1 phase, byte 2 flags (bit 0 clean exit), byte 3 need, byte 7
/// abrupt deaths, bytes 28 to 31 a CRC-32 of bytes 0 to 27. Anything else
/// reads as torn, which the module never writes.
fn diskOut(record: recovery.Record) DiskOut {
    const torn: DiskOut = .{ .ph = "torn" };
    const crc = std.mem.readInt(u32, record[28..32], .little);
    if (crc != std.hash.Crc32.hash(record[0..28]) or record[0] != 1) return torn;
    const ph: []const u8 = switch (record[1]) {
        1 => "sending",
        2 => "waiting",
        3 => "need_user",
        else => return torn,
    };
    const need: ?[]const u8 = if (record[3] == 0)
        null
    else if (std.enums.fromInt(recovery.Status.Need, record[3])) |value|
        @tagName(value)
    else
        return torn;
    return .{ .ph = ph, .clean = record[2] & 1 != 0, .deaths = record[7], .need = need };
}

fn planOut(plan: recovery.Plan) PlanOut {
    return .{
        .save = plan.save != null,
        .send = if (plan.send) |send| .{ .compact = send.compact_first, .no_fast = send.no_fast } else null,
        .status = if (plan.status) |status| .{
            .kind = @tagName(status.kind),
            .need = if (status.need) |need| @tagName(need) else null,
        } else null,
        .finish = if (plan.finish) |finish| @tagName(finish) else null,
    };
}

fn eventNamed(name: []const u8) ?recovery.Event {
    if (std.mem.eql(u8, name, "responding")) return .responding;
    if (std.mem.eql(u8, name, "succeeded")) return .succeeded;
    if (std.mem.eql(u8, name, "user_continue")) return .user_continue;
    if (std.mem.eql(u8, name, "user_cancel")) return .user_cancel;
    if (std.mem.eql(u8, name, "closing")) return .closing;
    return null;
}

fn run(lab: *Lab, op: Op, result: *Result) void {
    const is = struct {
        fn is(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.is;
    if (is(op.op, "walk")) {
        lab.* = .{};
    } else if (is(op.op, "start")) {
        const resume_from = if (op.@"resume") lab.disk else null;
        result.plan = planOut(lab.step(.{ .start = .{ .resume_from = resume_from } }));
    } else if (is(op.op, "event")) {
        const event = eventNamed(op.name) orelse {
            result.@"error" = "unknown event";
            return;
        };
        result.plan = planOut(lab.step(event));
    } else if (is(op.op, "failed")) {
        const kind = std.meta.stringToEnum(recovery.Failure.Kind, op.kind) orelse {
            result.@"error" = "unknown failure kind";
            return;
        };
        result.plan = planOut(lab.step(.{ .failed = .{ .kind = kind } }));
    } else if (is(op.op, "wait")) {
        result.plan = planOut(lab.wait());
    } else if (is(op.op, "exit")) {
        // The process ends, by a crash or after `closing`; the record stays.
        lab.state = .{};
    } else {
        result.@"error" = "unknown op";
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: recovery_lab <ops.jsonl> <results.jsonl>\n", .{});
        std.process.exit(2);
    }
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(256 << 20));
    var file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const out = &file_writer.interface;

    var lab: Lab = .{};
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const op = try std.json.parseFromSliceLeaky(Op, arena, line, .{ .ignore_unknown_fields = true });
        var result: Result = .{ .state = undefined, .disk = null };
        run(&lab, op, &result);
        result.state = stateOut(&lab.state);
        result.disk = if (lab.disk) |disk| diskOut(disk) else null;
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
