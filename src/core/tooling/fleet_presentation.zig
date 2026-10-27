//! The fleet tool's transcript rows (D101): proto's fleet cards in fx's
//! row idiom. A call shows one `● <verb> <worker> · <message>` row while it
//! runs; its result replaces it with the receipt, and list and inspect add
//! one continuation row per worker under it.
const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");

const Allocator = std.mem.Allocator;

pub const Op = enum { run, spawn, send, list, inspect, terminate };

pub const Call = struct {
    op: Op,
    /// A labelled run, a spawn's label, or the worker id a call names.
    target: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// The fleet call `args` describe; null for the older `subagent` shapes.
pub fn parseCall(args: std.json.ObjectMap) ?Call {
    const op = std.meta.stringToEnum(Op, tool_args.optionalStringArg(args, "op") orelse return null) orelse return null;
    return .{
        .op = op,
        .target = tool_args.optionalStringArg(args, "label") orelse tool_args.optionalStringArg(args, "id"),
        .message = tool_args.optionalStringArg(args, "message"),
    };
}

/// The running row's text, `<verb> <worker>` and a detail. Owned by `alloc`.
pub fn activeRow(alloc: Allocator, scratch: Allocator, call: Call, completed: bool) !struct { label: []u8, detail: []u8 } {
    const target = try safe(scratch, call.target orelse switch (call.op) {
        .run => "Subagent",
        .spawn => "worker",
        else => "worker",
    }, 64);
    const label = switch (call.op) {
        .run => try alloc.print("{s} {s}", .{ target, if (completed) "finished" else "working" }),
        .spawn => try alloc.print("{s} {s}", .{ if (completed) "Spawned" else "Spawning", target }),
        .send => try alloc.print("{s} {s}", .{ if (completed) "Sent to" else "Sending to", target }),
        .list => try alloc.dupe(u8, if (completed) "Listed workers" else "Listing workers"),
        .inspect => try alloc.print("{s} {s}", .{ if (completed) "Inspected" else "Inspecting", target }),
        .terminate => try alloc.print("{s} {s}", .{ if (completed) "Terminated" else "Terminating", target }),
    };
    errdefer alloc.free(label);
    const preview = if (call.message) |message| try preview_line(scratch, message, 120) else "";
    const detail = if (preview.len == 0) try alloc.dupe(u8, "") else try alloc.print("· {s}", .{preview});
    return .{ .label = label, .detail = detail };
}

const Worker = struct {
    id: []const u8,
    label: []const u8,
    lifecycle: []const u8,
    state: []const u8,
    turns: u32 = 0,
    queued: usize = 0,
    job: ?[]const u8 = null,
    queued_jobs: []const []const u8 = &.{},
    started_ms: ?i64 = null,
    model: ?[]const u8 = null,
    activity: ?[]const u8 = null,
};

const Body = struct {
    ok: bool = false,
    result: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    receipt: ?[]const u8 = null,
    worker: ?[]const u8 = null,
    label: ?[]const u8 = null,
    turn: ?u32 = null,
    job: ?[]const u8 = null,
    workers: ?[]const Worker = null,
};

/// The settled row for a fleet result, with its continuation rows; null
/// keeps the ordinary row (a blocking `run` result). Owned by `alloc`.
pub fn settledRow(alloc: Allocator, call: Call, output: []const u8, now_ms: i64) Allocator.Error!?[]u8 {
    return settledRowWriting(alloc, call, output, now_ms) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
    };
}

fn settledRowWriting(alloc: Allocator, call: Call, output: []const u8, now_ms: i64) !?[]u8 {
    if (call.op == .run) return null;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = std.json.parseFromSliceLeaky(Body, arena, output, .{ .ignore_unknown_fields = true }) catch return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const name = try safe(arena, body.label orelse call.target orelse "worker", 64);
    if (!body.ok and !std.mem.eql(u8, body.receipt orelse "", "terminal")) {
        // Errors: what was asked, then the first line of why, as proto does.
        try w.print("Fleet {s} {s}", .{ @tagName(call.op), if (body.receipt != null) "rejected" else "failed" });
        if (call.target) |target| try w.print(" · {s}", .{try safe(arena, target, 64)});
        if (body.result) |text| try w.print("\n{s}", .{try preview_line(arena, text, 160)});
        return try out.toOwnedSlice();
    }
    switch (call.op) {
        .run => unreachable,
        .spawn, .send => {
            const turn = body.turn orelse 0;
            const receipt = body.receipt orelse "accepted";
            try w.print("{s} {s} · ", .{ if (call.op == .spawn) "Spawned" else "Sent to", name });
            if (std.mem.eql(u8, receipt, "steered")) {
                try w.print("steered into turn {d}", .{turn});
            } else if (std.mem.eql(u8, receipt, "queued")) {
                try w.print("queued as turn {d}", .{turn});
            } else try w.print("turn {d} accepted", .{turn});
            if (body.job) |job| try w.print("\njob {s}", .{try safe(arena, job, 80)});
            if (call.message) |message| try w.print("{s}{s}", .{ if (body.job == null) "\n" else " · ", try preview_line(arena, message, 120) });
        },
        .terminate => {
            try w.print("Terminated {s}", .{name});
            if (std.mem.eql(u8, body.error_code orelse "", "turn_cancelled")) try w.writeAll(" · in-flight turn cancelled");
        },
        .list, .inspect => {
            const workers = body.workers orelse &.{};
            if (workers.len == 0) {
                try w.writeAll("Fleet workers · none");
                return try out.toOwnedSlice();
            }
            var on_air: usize = 0;
            for (workers) |worker| {
                if (std.mem.eql(u8, worker.state, "running")) on_air += 1;
            }
            if (call.op == .inspect) {
                try w.print("Inspected {s}", .{try safe(arena, workers[0].label, 64)});
            } else try w.print("Fleet workers ({d})", .{workers.len});
            if (on_air > 0) try w.print(" · {d} on air", .{on_air});
            for (workers, 0..) |worker, index| {
                const last = index + 1 == workers.len;
                try w.print("\n{s} ", .{if (last) "└" else "├"});
                try writeWorker(w, arena, worker, now_ms);
                if (call.op == .inspect) try writeInspectRows(w, arena, worker);
            }
        },
    }
    return try out.toOwnedSlice();
}

fn writeWorker(w: *std.Io.Writer, arena: Allocator, worker: Worker, now_ms: i64) !void {
    try w.print("{s} · {s} · {d}t", .{ try safe(arena, worker.label, 48), try safe(arena, worker.state, 32), worker.turns });
    if (worker.queued > 0) try w.print("+{d}q", .{worker.queued});
    if (worker.started_ms) |started| if (now_ms > started) {
        var buf: [32]u8 = undefined;
        try w.print(" · {s}", .{formatDuration(&buf, @intCast(now_ms - started))});
    };
    if (worker.model) |model| try w.print(" · {s}", .{try safe(arena, model, 48)});
}

fn writeInspectRows(w: *std.Io.Writer, arena: Allocator, worker: Worker) !void {
    try w.print("\n  id {s}", .{try safe(arena, worker.id, 64)});
    if (worker.job) |job| try w.print("\n  job {s}", .{try safe(arena, job, 80)});
    for (worker.queued_jobs) |job| try w.print("\n  queued {s}", .{try safe(arena, job, 80)});
    if (worker.activity) |activity| try w.print("\n  last {s}", .{try preview_line(arena, activity, 100)});
    if (std.mem.eql(u8, worker.lifecycle, "terminal")) try w.writeAll("\n  terminal · browse it in the session tree");
}

/// proto's duration form: 850ms, 4.1s, 1m2s, 2m, 1h5m, 2d3h.
pub fn formatDuration(buf: []u8, ms: u64) []const u8 {
    const s = ms / 1000;
    const out = if (ms < 1000)
        std.mem.print(buf, "{d}ms", .{ms})
    else if (s < 60)
        std.mem.print(buf, "{d}.{d}s", .{ s, (ms % 1000) / 100 })
    else if (s < 3600)
        (if (s % 60 == 0) std.mem.print(buf, "{d}m", .{s / 60}) else std.mem.print(buf, "{d}m{d}s", .{ s / 60, s % 60 }))
    else if (s < 86400)
        (if ((s % 3600) / 60 == 0) std.mem.print(buf, "{d}h", .{s / 3600}) else std.mem.print(buf, "{d}h{d}m", .{ s / 3600, (s % 3600) / 60 }))
    else if ((s % 86400) / 3600 == 0)
        std.mem.print(buf, "{d}d", .{s / 86400})
    else
        std.mem.print(buf, "{d}d{d}h", .{ s / 86400, (s % 86400) / 3600 });
    return out catch buf[0..0];
}

fn safe(arena: Allocator, raw: []const u8, max: usize) ![]const u8 {
    return (try text_utils.encodeTerminalSafe(arena, raw, max)).bytes;
}

/// The text's whitespace folded to single spaces, bounded and terminal safe.
fn preview_line(arena: Allocator, raw: []const u8, max: usize) ![]const u8 {
    var folded: std.ArrayList(u8) = .empty;
    var pending_space = false;
    const source = raw[0..text_utils.utf8BackwardBoundary(raw, @min(raw.len, 16 * 1024))];
    for (source) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = folded.items.len > 0;
            continue;
        }
        if (pending_space) try folded.append(arena, ' ');
        pending_space = false;
        try folded.append(arena, byte);
        if (folded.items.len > max + 4) break;
    }
    const bounded = folded.items[0..text_utils.utf8BackwardBoundary(folded.items, @min(folded.items.len, max))];
    const text = if (bounded.len < folded.items.len) try std.mem.concat(arena, u8, &.{ bounded, "…" }) else bounded;
    return safe(arena, text, max + 8);
}

test "fleet durations read like proto's" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("850ms", formatDuration(&buf, 850));
    try std.testing.expectEqualStrings("4.1s", formatDuration(&buf, 4100));
    try std.testing.expectEqualStrings("1m2s", formatDuration(&buf, 62_000));
    try std.testing.expectEqualStrings("2m", formatDuration(&buf, 120_000));
    try std.testing.expectEqualStrings("1h5m", formatDuration(&buf, 3_900_000));
    try std.testing.expectEqualStrings("2d3h", formatDuration(&buf, 2 * 86_400_000 + 3 * 3_600_000));
}

test "fleet receipts and worker lists become rows" {
    const alloc = std.testing.allocator;
    const spawn = (try settledRow(alloc, .{ .op = .spawn, .target = "parser", .message = "Fix the tokenizer\nin src/lex.ts" }, "{\"ok\":true,\"result\":\"x\",\"error_code\":null,\"receipt\":\"accepted\",\"worker\":\"W1\",\"label\":\"parser\",\"job\":\"W1-t1\",\"turn\":1}", 0)).?;
    defer alloc.free(spawn);
    try std.testing.expectEqualStrings("Spawned parser · turn 1 accepted\njob W1-t1 · Fix the tokenizer in src/lex.ts", spawn);
    const queued = (try settledRow(alloc, .{ .op = .send, .target = "W1", .message = "more" }, "{\"ok\":true,\"result\":\"x\",\"error_code\":null,\"receipt\":\"queued\",\"worker\":\"W1\",\"label\":\"parser\",\"job\":\"W1-t3\",\"turn\":3}", 0)).?;
    defer alloc.free(queued);
    try std.testing.expectEqualStrings("Sent to parser · queued as turn 3\njob W1-t3 · more", queued);
    const listed = (try settledRow(alloc, .{ .op = .list }, "{\"ok\":true,\"result\":\"x\",\"error_code\":null,\"workers\":[{\"id\":\"W1\",\"label\":\"parser\",\"lifecycle\":\"live\",\"state\":\"running\",\"turns\":2,\"queued\":1,\"started_ms\":1000,\"model\":\"m\"},{\"id\":\"W2\",\"label\":\"lexer\",\"lifecycle\":\"terminal\",\"state\":\"terminated\",\"turns\":1,\"queued\":0}]}", 13_300)).?;
    defer alloc.free(listed);
    try std.testing.expectEqualStrings("Fleet workers (2) · 1 on air\n├ parser · running · 2t+1q · 12.3s · m\n└ lexer · terminated · 1t", listed);
    const rejected = (try settledRow(alloc, .{ .op = .send, .target = "W9", .message = "x" }, "{\"ok\":false,\"result\":\"Unknown worker `W9`.\",\"error_code\":\"unknown_worker\",\"receipt\":\"rejected\"}", 0)).?;
    defer alloc.free(rejected);
    try std.testing.expectEqualStrings("Fleet send rejected · W9\nUnknown worker `W9`.", rejected);
    try std.testing.expect(try settledRow(alloc, .{ .op = .run }, "{\"ok\":true}", 0) == null);
}
