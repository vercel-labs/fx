//! Drives the request-recovery module (`src/core/recovery/`) for the TLA+
//! driver in this folder. It reads one JSON operation per line from the file
//! named by its first argument and writes one JSON result per operation to
//! the file named by its second.
//!
//! The lab plays fx's part around the module and knows nothing about the
//! model: it keeps the saved record, the save a plan asked for but fx has not
//! made durable yet, and the clock. It decodes saved records from the byte
//! layout `recovery.zig` documents, so the format is checked as well.
const std = @import("std");
const recovery = @import("recovery");

const start_ms: u64 = 1_000_000;
const tick_ms: u64 = 1_000;
/// A wait never passes 30 s, so a deadline is always within this many ticks.
const max_wait_ticks: u32 = 120;

const Op = struct {
    op: []const u8,
    fast: bool = false,
    @"resume": bool = false,
    name: []const u8 = "",
    kind: []const u8 = "",
    times: u8 = 0,
    disk: []const u8 = "",
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
    no_fast: bool,
    compacted: bool,
    clean: bool,
    streak: u8,
    streak_kind: ?[]const u8,
    flowing: bool,
};

const DiskOut = struct {
    ph: []const u8,
    clean: bool = false,
    deaths: u8 = 0,
    need: ?[]const u8 = null,
    no_fast: bool = false,
    compacted: bool = false,
    streak: u8 = 0,
    streak_kind: ?[]const u8 = null,
};

const Result = struct {
    plan: ?PlanOut = null,
    state: StateOut,
    disk: ?DiskOut,
    pending: bool,
    differs: ?bool = null,
    @"error": ?[]const u8 = null,
};

const Lab = struct {
    state: recovery.State = .{},
    /// The durable record, or null when there is no file.
    disk: ?recovery.Record = null,
    /// A save the module planned that is not durable yet.
    pending: ?recovery.Record = null,
    now_ms: u64 = start_ms,

    fn step(lab: *Lab, event: recovery.Event) recovery.Plan {
        const plan = recovery.step(&lab.state, event, lab.now_ms);
        lab.apply(plan);
        return plan;
    }

    /// fx carrying out a plan, apart from making the save durable, which is
    /// its own operation.
    fn apply(lab: *Lab, plan: recovery.Plan) void {
        if (plan.save) |save| lab.pending = save;
        if (plan.finish != null) {
            lab.disk = null;
            lab.pending = null;
        }
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

/// Whether a copy of the module, hearing `kind` up to `times` more times,
/// would send differently from its current send (request_recovery.zig
/// nextSendLocked asks the same question).
fn probeDiffers(lab: *const Lab, kind: recovery.Failure.Kind, times: u8) bool {
    var copy = lab.state;
    var now_ms = lab.now_ms;
    const current = lab.state.flags.no_fast;
    for (0..times) |_| {
        var plan = recovery.step(&copy, .{ .failed = .{ .kind = kind } }, now_ms);
        var ticks: u32 = 0;
        while (plan.send == null and ticks < max_wait_ticks) : (ticks += 1) {
            now_ms += tick_ms;
            plan = recovery.step(&copy, .tick, now_ms);
        }
        const send = plan.send orelse return false;
        if (send.no_fast != current) return true;
    }
    return false;
}

fn stateOut(state: *const recovery.State) StateOut {
    return .{
        .phase = @tagName(state.phase),
        .need = if (state.need) |need| @tagName(need) else null,
        .attempt = state.attempt,
        .deaths = state.abrupt_deaths,
        .no_fast = state.flags.no_fast,
        .compacted = state.flags.compacted,
        .clean = state.flags.clean_exit,
        .streak = state.streak,
        .streak_kind = if (state.streak_kind) |kind| @tagName(kind) else null,
        .flowing = state.flowing,
    };
}

const torn: DiskOut = .{ .ph = "torn" };

/// The record as `recovery.zig` documents its layout: byte 0 version 1,
/// byte 1 phase, byte 2 flags (bit 0 clean exit, bit 1 no Fast, bit 2
/// compacted), byte 3 need, byte 6 streak, byte 7 abrupt deaths, byte 10
/// streak kind, bytes 28 to 31 a CRC-32 of bytes 0 to 27. Anything else
/// reads as torn.
fn diskOut(record: recovery.Record) DiskOut {
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
    const streak_kind: ?[]const u8 = if (record[10] == 0)
        null
    else if (std.enums.fromInt(recovery.Failure.Kind, record[10])) |value|
        @tagName(value)
    else
        return torn;
    return .{
        .ph = ph,
        .clean = record[2] & 1 != 0,
        .deaths = record[7],
        .need = need,
        .no_fast = record[2] & 2 != 0,
        .compacted = record[2] & 4 != 0,
        .streak = record[6],
        .streak_kind = streak_kind,
    };
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
        result.plan = planOut(lab.step(.{ .start = .{ .resume_from = resume_from, .fast = op.fast } }));
    } else if (is(op.op, "event")) {
        const event = eventNamed(op.name) orelse {
            result.@"error" = "unknown event";
            return;
        };
        result.plan = planOut(lab.step(event));
    } else if (is(op.op, "failed") or is(op.op, "late")) {
        const kind = std.meta.stringToEnum(recovery.Failure.Kind, if (is(op.op, "late")) "dropped" else op.kind) orelse {
            result.@"error" = "unknown failure kind";
            return;
        };
        result.plan = planOut(lab.step(.{ .failed = .{ .kind = kind } }));
    } else if (is(op.op, "wait")) {
        result.plan = planOut(lab.wait());
    } else if (is(op.op, "probe")) {
        const kind = std.meta.stringToEnum(recovery.Failure.Kind, op.kind) orelse {
            result.@"error" = "unknown failure kind";
            return;
        };
        result.differs = probeDiffers(lab, kind, op.times);
    } else if (is(op.op, "sync")) {
        if (lab.pending) |pending| lab.disk = pending;
        lab.pending = null;
    } else if (is(op.op, "crash")) {
        // A write that was not durable survives, vanishes, or tears.
        if (lab.pending) |pending| {
            if (is(op.disk, "write")) lab.disk = pending;
            if (is(op.disk, "torn")) {
                var bytes = pending;
                bytes[31] ^= 0xff;
                lab.disk = bytes;
            }
        }
        lab.state = .{};
        lab.pending = null;
    } else if (is(op.op, "exit")) {
        lab.state = .{};
        lab.pending = null;
    } else if (is(op.op, "fx_end")) {
        // fx ends the request itself and deletes the record.
        lab.state = .{};
        lab.disk = null;
        lab.pending = null;
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
        var result: Result = .{ .state = undefined, .disk = null, .pending = false };
        run(&lab, op, &result);
        result.state = stateOut(&lab.state);
        result.disk = if (lab.disk) |disk| diskOut(disk) else null;
        result.pending = lab.pending != null;
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
