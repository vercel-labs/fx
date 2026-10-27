//! The fleet tool's transcript rows (D112): proto's fleet cards in fx's
//! row idiom. A call shows one `● <verb> <worker> · <message>` row while it
//! runs; its result replaces it with the receipt, and a list adds one
//! continuation row per worker under it. People read worker labels; worker
//! and job ids stay in the result the model reads.
const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const human_text = @import("../shared/human_text.zig");
const tool_args = @import("tool_args.zig");

const Allocator = std.mem.Allocator;

pub const Op = enum { run, spawn, send, message, list, inspect, inbox, terminate };

pub const Call = struct {
    op: Op,
    /// A labelled run, a spawn's label, or the worker id a call names.
    target: ?[]const u8 = null,
    /// Whether `target` is a label a person reads, not a worker id.
    target_is_label: bool = true,
    message: ?[]const u8 = null,
    /// `list` scope `visible`: every other agent of the tree (D186).
    visible: bool = false,
};

/// The fleet call `args` describe; null for the older `subagent` shapes.
pub fn parseCall(args: std.json.ObjectMap) ?Call {
    const op = std.meta.stringToEnum(Op, tool_args.optionalStringArg(args, "op") orelse return null) orelse return null;
    const label = tool_args.optionalStringArg(args, "label");
    if (op == .message) {
        // `to` is an id unless it names a relation a person reads.
        const to = tool_args.optionalStringArg(args, "to");
        const named = if (to) |value| relationName(value) else null;
        return .{ .op = op, .target = named orelse to, .target_is_label = named != null, .message = tool_args.optionalStringArg(args, "message") };
    }
    return .{
        .op = op,
        .target = label orelse tool_args.optionalStringArg(args, "id"),
        .target_is_label = label != null,
        .message = tool_args.optionalStringArg(args, "message"),
        .visible = std.mem.eql(u8, tool_args.optionalStringArg(args, "scope") orelse "", "visible"),
    };
}

fn relationName(to: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, to, "all")) return "all";
    if (std.mem.eql(u8, to, "parent")) return "parent";
    if (std.mem.eql(u8, to, "root")) return "root";
    return null;
}

/// A run's worker as a person names it: its label, or the task's first words.
fn runName(arena: Allocator, call: Call) ![]const u8 {
    if (call.target_is_label) if (call.target) |label| return safe(arena, label, 48);
    return preview_line(arena, call.message orelse "", 40);
}

/// The running row's text, `<verb> <worker>` and a detail. Owned by `alloc`.
pub fn activeRow(alloc: Allocator, scratch: Allocator, call: Call, completed: bool) !struct { label: []u8, detail: []u8 } {
    const target = try safe(scratch, if (call.target_is_label) call.target orelse "worker" else "worker", 64);
    const label = switch (call.op) {
        .run => try alloc.print("{s} worker {s}", .{ if (completed) "Ran" else "Running", try runName(scratch, call) }),
        .spawn => try alloc.print("{s} {s}", .{ if (completed) "Spawned" else "Spawning", target }),
        .send => try alloc.print("{s} {s}", .{ if (completed) "Sent to" else "Sending to", target }),
        .message => try alloc.print("{s} {s}", .{ if (completed) "Messaged" else "Messaging", if (call.target_is_label) target else "agent" }),
        .inbox => try alloc.dupe(u8, if (completed) "Read inbox" else "Reading inbox"),
        .list => try alloc.dupe(u8, if (call.visible)
            (if (completed) "Listed agents" else "Listing agents")
        else if (completed) "Listed workers" else "Listing workers"),
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
    receipts: ?[]const Receipt = null,
    messages: ?[]const Message = null,
    peers: ?[]const Peer = null,
};

/// The mailbox's shapes (`subagent/mailbox.zig`, `mail_ops.zig`).
const Receipt = struct {
    to: []const u8,
    label: []const u8 = "",
    outcome: []const u8,
    effect: ?[]const u8 = null,
    revived: bool = false,
    dropped_oldest: ?[]const u8 = null,
};
const Message = struct {
    from: []const u8,
    label: []const u8 = "",
    body: []const u8 = "",
    reply_to: ?[]const u8 = null,
    broadcast: bool = false,
};
const Peer = struct {
    label: []const u8,
    lifecycle: []const u8,
    turn: []const u8,
    unread: usize = 0,
    depth: u8 = 0,
};

/// The settled row for a fleet result, with its continuation rows; null
/// keeps the ordinary row (a blocking `run` result). Owned by `alloc`.
pub fn settledRow(alloc: Allocator, call: Call, output: []const u8, now_ms: i64) Allocator.Error!?[]u8 {
    return settledRowWriting(alloc, call, output, now_ms) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
    };
}

fn settledRowWriting(alloc: Allocator, call: Call, output: []const u8, now_ms: i64) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = std.json.parseFromSliceLeaky(Body, arena, output, .{ .ignore_unknown_fields = true }) catch return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const name = try safe(arena, body.label orelse if (call.target_is_label) call.target orelse "worker" else "worker", 64);
    if (!body.ok and !std.mem.eql(u8, body.receipt orelse "", "terminal")) {
        // Errors: what was asked, then the first line of why, as proto does.
        try w.print("Fleet {s} {s}", .{ @tagName(call.op), if (body.receipt != null) "rejected" else "failed" });
        if (call.target_is_label) if (call.target) |target| try w.print(" · {s}", .{try safe(arena, target, 64)});
        if (body.result) |text| try w.print("\n{s}", .{try preview_line(arena, try human_text.scrubIds(arena, text), 160)});
        return try out.toOwnedSlice();
    }
    switch (call.op) {
        // A blocking run's row carries its outcome: the reply's first line.
        .run => {
            try w.print("Ran worker {s}", .{try runName(arena, call)});
            const reply = std.mem.trim(u8, body.result orelse "", " \t\r\n");
            if (reply.len > 0) try w.print("\n{s}", .{try preview_line(arena, firstLine(reply), 120)});
        },
        // The task is the row's detail; a receipt is worth a word only when
        // the turn did not simply start.
        .spawn, .send => {
            const turn = body.turn orelse 0;
            const receipt = body.receipt orelse "accepted";
            try w.print("{s} {s}", .{ if (call.op == .spawn) "Spawned" else "Sent to", name });
            if (std.mem.eql(u8, receipt, "steered")) {
                try w.print(" · steered into turn {d}", .{turn});
            } else if (std.mem.eql(u8, receipt, "queued")) {
                try w.print(" · queued as turn {d}", .{turn});
            }
            if (call.message) |message| try w.print(" · {s}", .{try preview_line(arena, message, 80)});
        },
        .message => try writeMessaged(w, arena, call, body.receipts orelse &.{}),
        .inbox => {
            const messages = body.messages orelse &.{};
            if (messages.len == 0) {
                try w.writeAll("Read inbox · empty");
                return try out.toOwnedSlice();
            }
            try w.print("Read inbox · {d} message{s}", .{ messages.len, if (messages.len == 1) "" else "s" });
            for (messages) |message| {
                const from = if (message.label.len > 0) message.label else "agent";
                try w.print("\n{s} → {s} · {s}", .{ try safe(arena, from, 48), if (message.broadcast) "all" else "you", try preview_line(arena, firstLine(std.mem.trim(u8, message.body, " \t\r\n")), 100) });
            }
        },
        .list => if (call.visible) {
            const peers = body.peers orelse &.{};
            if (peers.len == 0) {
                try w.writeAll("Listed agents · none");
                return try out.toOwnedSlice();
            }
            try w.print("Listed agents · {d}", .{peers.len});
            for (peers) |peer| {
                try w.print("\n{s} · {s}/{s}", .{ try safe(arena, peer.label, 48), try safe(arena, peer.lifecycle, 16), try safe(arena, peer.turn, 16) });
                if (peer.unread > 0) try w.print(" · {d} unread", .{peer.unread});
            }
        } else try writeWorkers(w, arena, call, body.workers orelse &.{}, now_ms),
        .terminate => {
            try w.print("Terminated {s}", .{name});
            if (std.mem.eql(u8, body.error_code orelse "", "turn_cancelled")) try w.writeAll(" · in-flight turn cancelled");
        },
        .inspect => try writeWorkers(w, arena, call, body.workers orelse &.{}, now_ms),
    }
    return try out.toOwnedSlice();
}

fn writeWorkers(w: *std.Io.Writer, arena: Allocator, call: Call, workers: []const Worker, now_ms: i64) !void {
    if (workers.len == 0) return w.writeAll(if (call.op == .inspect) "Inspected worker · not found" else "Listed workers · none");
    if (call.op == .inspect) {
        // One worker: its state fits on the phrase, and only its last
        // activity earns a row.
        try w.print("Inspected {s} · ", .{try safe(arena, workers[0].label, 64)});
        try writeWorker(w, arena, workers[0], now_ms, false);
        return writeInspectRows(w, arena, workers[0]);
    }
    try w.writeAll("Listed workers");
    try writeStateCounts(w, arena, workers);
    for (workers) |worker| {
        try w.writeAll("\n");
        try writeWorker(w, arena, worker, now_ms, true);
    }
}

/// "Message → beta · first line", then one row per recipient when it was
/// a broadcast or a message did not simply arrive. Labels, never ids.
fn writeMessaged(w: *std.Io.Writer, arena: Allocator, call: Call, receipts: []const Receipt) !void {
    const preview = try preview_line(arena, firstLine(std.mem.trim(u8, call.message orelse "", " \t\r\n")), 100);
    const target = if (call.target_is_label) call.target orelse "agent" else if (receipts.len == 1) receipts[0].label else "agent";
    try w.print("Message → {s}", .{try safe(arena, if (target.len > 0) target else "agent", 48)});
    if (preview.len > 0) try w.print(" · {s}", .{preview});
    const broadcast = receipts.len != 1;
    for (receipts) |receipt| {
        const plain = std.mem.eql(u8, receipt.outcome, "delivered") and !receipt.revived and receipt.dropped_oldest == null;
        if (!broadcast and plain) continue;
        try w.print("\n{s} · {s}", .{ try safe(arena, if (receipt.label.len > 0) receipt.label else "agent", 48), receiptWords(receipt) });
        if (receipt.revived) try w.writeAll(" · reopened");
        if (receipt.dropped_oldest != null) try w.writeAll(" · mailbox full, oldest dropped");
    }
}

fn receiptWords(receipt: Receipt) []const u8 {
    if (std.mem.eql(u8, receipt.outcome, "delivered")) {
        return if (std.mem.eql(u8, receipt.effect orelse "", "injected")) "joined its turn" else "woke it";
    }
    if (std.mem.eql(u8, receipt.outcome, "queued")) return "waiting in its mailbox";
    return "not delivered";
}

/// "1 running · 2 idle": how many workers are in each state, in first-seen order.
fn writeStateCounts(w: *std.Io.Writer, arena: Allocator, workers: []const Worker) !void {
    var seen: [8][]const u8 = undefined;
    var counts: [8]usize = @splat(0);
    var kinds: usize = 0;
    for (workers) |worker| {
        const index = for (seen[0..kinds], 0..) |state, i| {
            if (std.mem.eql(u8, state, worker.state)) break i;
        } else blk: {
            if (kinds == seen.len) continue;
            seen[kinds] = worker.state;
            kinds += 1;
            break :blk kinds - 1;
        };
        counts[index] += 1;
    }
    for (seen[0..kinds], counts[0..kinds]) |state, count| {
        try w.print(" · {d} {s}", .{ count, try safe(arena, state, 32) });
    }
}

/// One worker: label, state and turns, then how long its turn has run.
/// A list row leads with the label; an inspect phrase already named it.
fn writeWorker(w: *std.Io.Writer, arena: Allocator, worker: Worker, now_ms: i64, with_label: bool) !void {
    if (with_label) try w.print("{s} · ", .{try safe(arena, worker.label, 48)});
    try w.print("{s} · {d} turn{s}", .{ try safe(arena, worker.state, 32), worker.turns, if (worker.turns == 1) "" else "s" });
    if (worker.queued > 0) try w.print(" · {d} queued", .{worker.queued});
    if (worker.started_ms) |started| if (now_ms > started and std.mem.eql(u8, worker.state, "running")) {
        var buf: [32]u8 = undefined;
        try w.print(" · {s}", .{formatDuration(&buf, @intCast(now_ms - started))});
    };
}

fn writeInspectRows(w: *std.Io.Writer, arena: Allocator, worker: Worker) !void {
    if (std.mem.eql(u8, worker.lifecycle, "terminal")) {
        try w.writeAll("\nterminated · browse it in the session tree");
    } else if (worker.activity) |activity| try w.print("\nlast: {s}", .{try preview_line(arena, activity, 100)});
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.findAny(u8, text, "\r\n") orelse text.len];
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
    try std.testing.expectEqualStrings("Spawned parser · Fix the tokenizer in src/lex.ts", spawn);
    const queued = (try settledRow(alloc, .{ .op = .send, .target = "W1", .target_is_label = false, .message = "more" }, "{\"ok\":true,\"result\":\"x\",\"error_code\":null,\"receipt\":\"queued\",\"worker\":\"W1\",\"label\":\"parser\",\"job\":\"W1-t3\",\"turn\":3}", 0)).?;
    defer alloc.free(queued);
    try std.testing.expectEqualStrings("Sent to parser · queued as turn 3 · more", queued);
    const listed = (try settledRow(alloc, .{ .op = .list }, "{\"ok\":true,\"result\":\"x\",\"error_code\":null,\"workers\":[{\"id\":\"W1\",\"label\":\"parser\",\"lifecycle\":\"live\",\"state\":\"running\",\"turns\":2,\"queued\":1,\"started_ms\":1000,\"model\":\"m\"},{\"id\":\"W2\",\"label\":\"lexer\",\"lifecycle\":\"terminal\",\"state\":\"terminated\",\"turns\":1,\"queued\":0}]}", 13_300)).?;
    defer alloc.free(listed);
    try std.testing.expectEqualStrings("Listed workers · 1 running · 1 terminated\nparser · running · 2 turns · 1 queued · 12.3s\nlexer · terminated · 1 turn", listed);
    const inspected = (try settledRow(alloc, .{ .op = .inspect, .target = "W1", .target_is_label = false }, "{\"ok\":true,\"workers\":[{\"id\":\"W1\",\"label\":\"parser\",\"lifecycle\":\"live\",\"state\":\"idle\",\"turns\":1,\"job\":\"W1-t1\",\"activity\":\"Read src/lex.ts\"}]}", 0)).?;
    defer alloc.free(inspected);
    try std.testing.expectEqualStrings("Inspected parser · idle · 1 turn\nlast: Read src/lex.ts", inspected);
    const ran = (try settledRow(alloc, .{ .op = .run, .message = "Summarize the repository in one line" }, "{\"ok\":true,\"result\":\"A tiny app.\\nNo tests.\"}", 0)).?;
    defer alloc.free(ran);
    try std.testing.expectEqualStrings("Ran worker Summarize the repository in one line\nA tiny app.", ran);
    const rejected = (try settledRow(alloc, .{ .op = .send, .target = "W9", .target_is_label = false, .message = "x" }, "{\"ok\":false,\"result\":\"Unknown worker `W9`.\",\"error_code\":\"unknown_worker\",\"receipt\":\"rejected\"}", 0)).?;
    defer alloc.free(rejected);
    try std.testing.expectEqualStrings("Fleet send rejected\nUnknown worker `W9`.", rejected);
}

test "messages, inboxes and the tree's agents become rows without ids" {
    const alloc = std.testing.allocator;
    const one = (try settledRow(alloc, .{ .op = .message, .target = "01JX", .target_is_label = false, .message = "Take the parser\nthen report" }, "{\"ok\":true,\"receipts\":[{\"to\":\"01JX\",\"label\":\"beta\",\"id\":\"M1\",\"outcome\":\"delivered\",\"effect\":\"wake_requested\"}]}", 0)).?;
    defer alloc.free(one);
    try std.testing.expectEqualStrings("Message → beta · Take the parser", one);
    const all = (try settledRow(alloc, .{ .op = .message, .target = "all", .message = "done" }, "{\"ok\":true,\"receipts\":[{\"to\":\"R\",\"label\":\"root\",\"outcome\":\"delivered\",\"effect\":\"injected\"},{\"to\":\"B\",\"label\":\"beta\",\"outcome\":\"queued\",\"revived\":true}]}", 0)).?;
    defer alloc.free(all);
    try std.testing.expectEqualStrings("Message → all · done\nroot · joined its turn\nbeta · waiting in its mailbox · reopened", all);
    const read = (try settledRow(alloc, .{ .op = .inbox }, "{\"ok\":true,\"messages\":[{\"id\":\"M2\",\"from\":\"A\",\"label\":\"alpha\",\"body\":\"status?\\nmore\"}]}", 0)).?;
    defer alloc.free(read);
    try std.testing.expectEqualStrings("Read inbox · 1 message\nalpha → you · status?", read);
    const peers = (try settledRow(alloc, .{ .op = .list, .visible = true }, "{\"ok\":true,\"peers\":[{\"id\":\"R\",\"label\":\"root\",\"lifecycle\":\"live\",\"turn\":\"idle\",\"unread\":2}]}", 0)).?;
    defer alloc.free(peers);
    try std.testing.expectEqualStrings("Listed agents · 1\nroot · live/idle · 2 unread", peers);
}
