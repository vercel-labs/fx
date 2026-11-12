//! In-memory record of recent subagent turns, for `/trace`.
//!
//! Each subagent turn gets a new number (`debug_trace.nextSubagentId`), and a
//! tool call names only that number, as its trace record's `subagent_id`.
//! This ring keeps which subagent session each number ran for, with the
//! turn's model, effort, the start of its prompt, and how it ended, so the
//! report can say which subagent did what. Every agent's worker thread
//! records here, so one mutex guards the ring.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const ring_capacity: usize = 128;
pub const max_session_id_len: usize = 64;
pub const max_model_len: usize = 96;
pub const max_label_len: usize = 16;
/// Bytes kept of a turn's prompt: enough to say what the subagent was asked.
pub const max_prompt_len: usize = 240;

/// The outcome label of a turn that has not ended.
pub const running_label = "running";

pub const Turn = struct {
    subagent_id: u64 = 0,
    started_at_ms: i64 = 0,
    /// Zero while the turn runs.
    ended_at_ms: i64 = 0,
    session_id_buf: [max_session_id_len]u8 = @splat(0),
    session_id_len: u8 = 0,
    model_buf: [max_model_len]u8 = @splat(0),
    model_len: u8 = 0,
    effort_buf: [max_label_len]u8 = @splat(0),
    effort_len: u8 = 0,
    outcome_buf: [max_label_len]u8 = @splat(0),
    outcome_len: u8 = 0,
    prompt_buf: [max_prompt_len]u8 = @splat(0),
    prompt_len: u8 = 0,
    prompt_total_bytes: u32 = 0,

    /// The subagent's session ID: the name of its folder in the session store.
    pub fn sessionId(self: *const Turn) []const u8 {
        return self.session_id_buf[0..self.session_id_len];
    }

    pub fn model(self: *const Turn) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn effort(self: *const Turn) []const u8 {
        return self.effort_buf[0..self.effort_len];
    }

    /// `running`, or how the turn ended, such as `completed` or `failed`.
    pub fn outcome(self: *const Turn) []const u8 {
        if (self.outcome_len == 0) return running_label;
        return self.outcome_buf[0..self.outcome_len];
    }

    /// The first bytes of the turn's prompt, cut on a UTF-8 boundary.
    pub fn prompt(self: *const Turn) []const u8 {
        return self.prompt_buf[0..self.prompt_len];
    }
};

pub const Start = struct {
    subagent_id: u64,
    session_id: []const u8,
    model: []const u8,
    effort: []const u8,
    prompt: []const u8,
    started_at_ms: i64,
};

var mutex: std.Io.Mutex = .init;
// All-zero, so the ring lands in .bss. Snapshots read only `stored` slots,
// and a start overwrites a whole slot.
var ring: [ring_capacity]Turn = std.mem.zeroes([ring_capacity]Turn);
var head: usize = 0;
var stored: usize = 0;
var total: u64 = 0;

fn copyInto(buf: []u8, len: *u8, value: []const u8) void {
    const kept = text_utils.utf8PrefixByBytes(value, buf.len);
    @memcpy(buf[0..kept.len], kept);
    len.* = @intCast(kept.len);
}

/// Records a subagent turn as it starts. A turn with no number is not a
/// subagent turn and is not recorded.
pub fn recordStart(start: Start) void {
    if (start.subagent_id == 0) return;
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const slot = &ring[head];
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;
    total += 1;
    slot.subagent_id = start.subagent_id;
    slot.started_at_ms = start.started_at_ms;
    slot.ended_at_ms = 0;
    slot.outcome_len = 0;
    copyInto(&slot.session_id_buf, &slot.session_id_len, start.session_id);
    copyInto(&slot.model_buf, &slot.model_len, start.model);
    copyInto(&slot.effort_buf, &slot.effort_len, start.effort);
    copyInto(&slot.prompt_buf, &slot.prompt_len, start.prompt);
    slot.prompt_total_bytes = @intCast(@min(start.prompt.len, std.math.maxInt(u32)));
}

/// Records how turn `subagent_id` ended. A turn the ring no longer holds, or
/// one that already ended, is left as it is.
pub fn recordEnd(subagent_id: u64, outcome: []const u8, ended_at_ms: i64) void {
    if (subagent_id == 0) return;
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    var i: usize = 0;
    while (i < stored) : (i += 1) {
        const idx = (head + ring_capacity - 1 - i) % ring_capacity;
        const slot = &ring[idx];
        if (slot.subagent_id != subagent_id) continue;
        if (slot.ended_at_ms != 0) return;
        slot.ended_at_ms = @max(ended_at_ms, 1);
        copyInto(&slot.outcome_buf, &slot.outcome_len, outcome);
        return;
    }
}

/// Copies the kept turns into `out`, oldest first.
pub fn snapshot(out: []Turn) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const n = @min(stored, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = ring[(head + ring_capacity - n + i) % ring_capacity];
    }
    return n;
}

/// Subagent turns started this session, kept or not.
pub fn totalTurns() u64 {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    return total;
}

pub fn reset() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    head = 0;
    stored = 0;
    total = 0;
}

const testing = std.testing;

fn startForTest(subagent_id: u64, session_id: []const u8) Start {
    return .{
        .subagent_id = subagent_id,
        .session_id = session_id,
        .model = "openai/gpt-5",
        .effort = "high",
        .prompt = "check the card title",
        .started_at_ms = 1000 + @as(i64, @intCast(subagent_id)),
    };
}

fn snapshotForTest() ![]Turn {
    const out = try testing.allocator.alloc(Turn, ring_capacity);
    return out[0..snapshot(out)];
}

fn freeForTest(turns: []Turn) void {
    testing.allocator.free(turns.ptr[0..ring_capacity]);
}

test "a subagent turn keeps its session, model, prompt, and outcome" {
    reset();
    defer reset();

    recordStart(startForTest(4, "child-cards"));
    var turns = try snapshotForTest();
    try testing.expectEqual(@as(usize, 1), turns.len);
    try testing.expectEqualStrings("running", turns[0].outcome());
    freeForTest(turns);

    recordEnd(4, "completed", 2000);
    // A second end for the same turn changes nothing.
    recordEnd(4, "failed", 3000);
    turns = try snapshotForTest();
    defer freeForTest(turns);
    try testing.expectEqual(@as(u64, 4), turns[0].subagent_id);
    try testing.expectEqualStrings("child-cards", turns[0].sessionId());
    try testing.expectEqualStrings("openai/gpt-5", turns[0].model());
    try testing.expectEqualStrings("high", turns[0].effort());
    try testing.expectEqualStrings("check the card title", turns[0].prompt());
    try testing.expectEqualStrings("completed", turns[0].outcome());
    try testing.expectEqual(@as(i64, 2000), turns[0].ended_at_ms);
}

test "a turn with no number, and an end with no start, record nothing" {
    reset();
    defer reset();

    recordStart(startForTest(0, "child-root"));
    recordEnd(9, "completed", 2000);
    const turns = try snapshotForTest();
    defer freeForTest(turns);
    try testing.expectEqual(@as(usize, 0), turns.len);
    try testing.expectEqual(@as(u64, 0), totalTurns());
}

test "the ring keeps the newest turns and counts every turn" {
    reset();
    defer reset();

    var id: u64 = 1;
    while (id <= ring_capacity + 1) : (id += 1) recordStart(startForTest(id, "child"));
    // The oldest turn is gone, so its end is dropped.
    recordEnd(1, "completed", 5000);
    const turns = try snapshotForTest();
    defer freeForTest(turns);
    try testing.expectEqual(ring_capacity, turns.len);
    try testing.expectEqual(@as(u64, 2), turns[0].subagent_id);
    try testing.expectEqual(@as(u64, ring_capacity + 1), turns[turns.len - 1].subagent_id);
    try testing.expectEqual(@as(u64, ring_capacity + 1), totalTurns());
    for (turns) |turn| try testing.expectEqualStrings("running", turn.outcome());
}

test "long values are cut on a UTF-8 boundary" {
    reset();
    defer reset();

    var prompt: [max_prompt_len + 1]u8 = undefined;
    @memset(prompt[0 .. max_prompt_len - 1], 'a');
    // "é" is two bytes; the cut falls between them.
    prompt[max_prompt_len - 1] = 0xc3;
    prompt[max_prompt_len] = 0xa9;
    var start = startForTest(3, "child");
    start.prompt = &prompt;
    recordStart(start);
    const turns = try snapshotForTest();
    defer freeForTest(turns);
    try testing.expectEqual(@as(usize, max_prompt_len - 1), turns[0].prompt().len);
    try testing.expectEqual(@as(u32, max_prompt_len + 1), turns[0].prompt_total_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(turns[0].prompt()));
}

test "a reset clears the turns" {
    reset();
    defer reset();

    recordStart(startForTest(2, "child"));
    reset();
    const turns = try snapshotForTest();
    defer freeForTest(turns);
    try testing.expectEqual(@as(usize, 0), turns.len);
    try testing.expectEqual(@as(u64, 0), totalTurns());
}

test "the ring matches a reference list on seeded random sequences" {
    reset();
    defer reset();

    const Ref = struct { id: u64, ended: bool };
    var reference: std.ArrayList(Ref) = .empty;
    defer reference.deinit(testing.allocator);
    const out = try testing.allocator.alloc(Turn, ring_capacity);
    defer testing.allocator.free(out);

    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        reset();
        reference.clearRetainingCapacity();
        var next_id: u64 = 1;
        const steps = random.uintAtMost(u32, 400);
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            const roll = random.uintLessThan(u8, 100);
            if (roll == 0) {
                reset();
                reference.clearRetainingCapacity();
            } else if (roll < 60 or reference.items.len == 0) {
                recordStart(startForTest(next_id, "child"));
                try reference.append(testing.allocator, .{ .id = next_id, .ended = false });
                next_id += 1;
            } else {
                // End a random turn the reference has, kept or not.
                const pick = random.uintLessThan(usize, reference.items.len);
                const kept_from = reference.items.len - @min(reference.items.len, ring_capacity);
                recordEnd(reference.items[pick].id, "completed", 9000);
                if (pick >= kept_from) reference.items[pick].ended = true;
            }
        }
        const n = snapshot(out);
        const expected = reference.items[reference.items.len - @min(reference.items.len, ring_capacity) ..];
        try testing.expectEqual(expected.len, n);
        for (expected, out[0..n]) |want, got| {
            try testing.expectEqual(want.id, got.subagent_id);
            try testing.expectEqualStrings(if (want.ended) "completed" else "running", got.outcome());
        }
        try testing.expectEqual(@as(u64, reference.items.len), totalTurns());
    }
}

test "turns recorded from many threads stay bounded and each end lands on its start" {
    reset();
    defer reset();

    const thread_count = 16;
    const per_thread = 10_000;
    const Worker = struct {
        fn run(thread_index: u64) void {
            var seq: u64 = 0;
            while (seq < per_thread) : (seq += 1) {
                const id = thread_index * 1_000_000 + seq + 1;
                var session_buf: [16]u8 = undefined;
                const session = std.mem.print(&session_buf, "child-{d}", .{thread_index}) catch unreachable;
                recordStart(.{
                    .subagent_id = id,
                    .session_id = session,
                    .model = "openai/gpt-5",
                    .effort = "auto",
                    .prompt = "stress",
                    .started_at_ms = @intCast(id),
                });
                recordEnd(id, if (seq % 2 == 0) "completed" else "failed", @intCast(id + 1));
            }
        }
    };
    const Reader = struct {
        fn run(done: *std.atomic.Value(bool), errors: *std.atomic.Value(u32), out: []Turn) void {
            while (!done.load(.acquire)) {
                const n = snapshot(out);
                if (n > ring_capacity) _ = errors.fetchAdd(1, .monotonic);
                for (out[0..n]) |*turn| {
                    if (!turnIsWhole(turn)) _ = errors.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    const out = try testing.allocator.alloc(Turn, ring_capacity);
    defer testing.allocator.free(out);
    var done = std.atomic.Value(bool).init(false);
    var errors = std.atomic.Value(u32).init(0);
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ &done, &errors, out });
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, Worker.run, .{@as(u64, index)});
    for (threads) |thread| thread.join();
    done.store(true, .release);
    reader.join();

    try testing.expectEqual(@as(u32, 0), errors.load(.monotonic));
    try testing.expectEqual(@as(u64, thread_count * per_thread), totalTurns());
    const n = snapshot(out);
    try testing.expectEqual(ring_capacity, n);
    // Every thread ends each turn right after starting it, so every kept
    // turn has ended, with its own outcome.
    for (out[0..n]) |*turn| {
        try testing.expect(turnIsWhole(turn));
        try testing.expect(turn.ended_at_ms != 0);
    }
}

/// Whether a stress turn's fields all belong to the same turn: its session
/// names its thread, and an end carries the outcome its number calls for.
fn turnIsWhole(turn: *const Turn) bool {
    const thread_index = turn.subagent_id / 1_000_000;
    var session_buf: [16]u8 = undefined;
    const session = std.mem.print(&session_buf, "child-{d}", .{thread_index}) catch return false;
    if (!std.mem.eql(u8, turn.sessionId(), session)) return false;
    if (turn.started_at_ms != @as(i64, @intCast(turn.subagent_id))) return false;
    if (turn.ended_at_ms == 0) return std.mem.eql(u8, turn.outcome(), running_label);
    const seq = turn.subagent_id % 1_000_000 - 1;
    const want: []const u8 = if (seq % 2 == 0) "completed" else "failed";
    return std.mem.eql(u8, turn.outcome(), want) and turn.ended_at_ms == turn.started_at_ms + 1;
}
