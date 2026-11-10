//! The thinking row's clocks. The turn clock counts the turn's own work: it
//! stops while the turn waits, on an approval or a question or on a
//! compaction, and when the wait ends it goes on from the time it showed when
//! the wait began. A compaction shows a clock of its own that starts at zero,
//! whatever started it. Nothing here reads a clock; callers pass the time in.
//!
//! `tests/tla/turn_clock/TurnClock.tla` models these rules, and
//! `tests/tla/drivers/turn_clock/driver.ts` walks this file along the model.
//! The file imports only `std` and `compaction_activity.zig` so the driver's
//! lab can build it alone.
const std = @import("std");
/// Public for the driver's lab, which builds this file as its only module.
pub const compaction_activity = @import("compaction_activity.zig");

pub const ms_per_second: i64 = 1000;

/// A clock's two marks, in milliseconds. `StreamState` keeps the turn's.
pub const Marks = struct {
    /// When the clock started, moved forward past every finished wait.
    /// 0 means there is no clock.
    started_ms: i64 = 0,
    /// When the current wait began. 0 means the clock is not waiting.
    waiting_since_ms: i64 = 0,
};

/// The turn waits while an approval or a question is open, or while a
/// compaction runs. A compaction's feedback after it ends does not hold the
/// clock (`tests/tla/turn_clock/TurnClock.tla` CompactionTimeExcluded and
/// RunsWhenNothingWaits).
pub fn waits(prompt_open: bool, activity: compaction_activity.Snapshot) bool {
    if (prompt_open) return true;
    const operation = activity.operation orelse return false;
    return operation.active();
}

/// The marks after the caller checked, at `now_ms`, whether the turn waits.
/// A wait starts only on a running turn. When it ends, the start mark moves
/// forward by the wait, so the clock goes on from where it stopped
/// (`tests/tla/turn_clock/TurnClock.tla` TurnClockCountsWork).
pub fn sync(marks: Marks, running: bool, waiting: bool, now_ms: i64) Marks {
    var next = marks;
    if (waiting) {
        if (running and next.waiting_since_ms == 0) next.waiting_since_ms = now_ms;
        return next;
    }
    if (next.waiting_since_ms == 0) return next;
    const waited = now_ms - next.waiting_since_ms;
    if (waited > 0 and next.started_ms > 0) next.started_ms += waited;
    next.waiting_since_ms = 0;
    return next;
}

/// Milliseconds the clock shows at `now_ms`: frozen at the start of a wait,
/// and never below zero when the wall clock moved back. Null when there is no
/// clock or `now_ms` is before its start.
pub fn elapsedMs(marks: Marks, now_ms: i64) ?i64 {
    if (marks.started_ms <= 0 or now_ms < marks.started_ms) return null;
    const reading = if (marks.waiting_since_ms > 0 and marks.waiting_since_ms < now_ms) marks.waiting_since_ms else now_ms;
    return @max(reading - marks.started_ms, 0);
}

/// Whole seconds the clock shows at `now_ms`, or null as for `elapsedMs`.
pub fn seconds(marks: Marks, now_ms: i64) ?i64 {
    return @divTrunc(elapsedMs(marks, now_ms) orelse return null, ms_per_second);
}

/// A compaction's own clock. It starts when the compaction begins, whatever
/// started it, and runs through every step
/// (`tests/tla/turn_clock/TurnClock.tla` CompactionCountsFromZero).
pub fn compactionMarks(operation: compaction_activity.Operation) Marks {
    return .{ .started_ms = operation.started_at_ms };
}

const testing = std.testing;

test "the turn clock holds through a compaction and goes on from where it stopped" {
    var activity: compaction_activity.State = .{};
    // 10m15s into the turn a compaction starts and runs for 40 s.
    var marks: Marks = .{ .started_ms = 1_000 };
    const began = 1_000 + 615_000;
    const id = activity.begin(.automatic, 1, began);
    activity.running(id, .summary);
    marks = sync(marks, true, waits(false, activity.snapshot), began);
    try testing.expectEqual(@as(?i64, 615), seconds(marks, began + 40_000));
    try testing.expectEqual(@as(?i64, 40), seconds(compactionMarks(activity.snapshot.operation.?), began + 40_000));
    activity.settle(id, .{ .outcome = .succeeded, .publication = .committed }, began + 40_000);
    marks = sync(marks, true, waits(false, activity.snapshot), began + 40_000);
    try testing.expectEqual(@as(i64, 0), marks.waiting_since_ms);
    try testing.expectEqual(@as(?i64, 615), seconds(marks, began + 40_000));
    try testing.expectEqual(@as(?i64, 620), seconds(marks, began + 45_000));
}

test "a compaction's clock starts at zero for every origin and runs through its steps" {
    var activity: compaction_activity.State = .{};
    for ([_]compaction_activity.Origin{ .manual, .automatic, .provider_overflow }) |origin| {
        const id = activity.begin(origin, 1, 50_000);
        try testing.expectEqual(@as(?i64, 0), seconds(compactionMarks(activity.snapshot.operation.?), 50_000));
        activity.running(id, .summary);
        activity.running(id, .publication);
        activity.stopping(id);
        try testing.expectEqual(@as(?i64, 3), seconds(compactionMarks(activity.snapshot.operation.?), 53_999));
        try testing.expect(waits(false, activity.snapshot));
        activity.settle(id, .{ .outcome = .cancelled }, 54_000);
    }
}

test "a prompt that overlaps a compaction is taken off the turn once" {
    var activity: compaction_activity.State = .{};
    var marks: Marks = .{ .started_ms = 1_000 };
    const id = activity.begin(.automatic, 1, 11_000);
    marks = sync(marks, true, waits(false, activity.snapshot), 11_000);
    // An approval opens during the compaction and closes before it ends.
    marks = sync(marks, true, waits(true, activity.snapshot), 15_000);
    marks = sync(marks, true, waits(false, activity.snapshot), 20_000);
    activity.settle(id, .{ .outcome = .succeeded }, 30_000);
    // Then the approval outlives the next compaction.
    marks = sync(marks, true, waits(false, activity.snapshot), 30_000);
    try testing.expectEqual(@as(?i64, 10), seconds(marks, 30_000));
    const next = activity.begin(.provider_overflow, 1, 40_000);
    marks = sync(marks, true, waits(false, activity.snapshot), 40_000);
    marks = sync(marks, true, waits(true, activity.snapshot), 45_000);
    activity.settle(next, .{ .outcome = .succeeded }, 50_000);
    marks = sync(marks, true, waits(true, activity.snapshot), 50_000);
    marks = sync(marks, true, waits(false, activity.snapshot), 60_000);
    try testing.expectEqual(@as(?i64, 20), seconds(marks, 60_000));
}

test "a failed compaction's feedback on screen does not hold the turn clock" {
    var activity: compaction_activity.State = .{};
    const id = activity.begin(.automatic, 1, 2_000);
    activity.settle(id, compaction_activity.failure(error.ConnectionTimedOut, .summary, false), 3_000);
    try testing.expect(activity.snapshot.operation.?.visible(3_000));
    try testing.expect(!waits(false, activity.snapshot));
}

test "a wait starts only on a running turn" {
    var activity: compaction_activity.State = .{};
    _ = activity.begin(.manual, null, 1_000);
    try testing.expectEqual(Marks{}, sync(.{}, false, waits(false, activity.snapshot), 1_000));
    // A turn that starts while the compaction still runs waits from its first sync.
    var marks = sync(.{ .started_ms = 4_000 }, true, waits(false, activity.snapshot), 4_000);
    try testing.expectEqual(@as(i64, 4_000), marks.waiting_since_ms);
    try testing.expectEqual(@as(?i64, 0), seconds(marks, 9_000));
    marks = sync(marks, true, false, 9_000);
    try testing.expectEqual(@as(?i64, 1), seconds(marks, 10_000));
}

test "the clock shows nothing before its start and never a negative time" {
    try testing.expectEqual(@as(?i64, null), seconds(.{}, 5_000));
    try testing.expectEqual(@as(?i64, null), seconds(.{ .started_ms = 6_000 }, 5_000));
    // The wall clock moved back after the wait began.
    try testing.expectEqual(@as(?i64, 0), seconds(.{ .started_ms = 6_000, .waiting_since_ms = 5_000 }, 7_000));
    // A wait that ends at an earlier instant than it began is dropped without a shift.
    try testing.expectEqual(Marks{ .started_ms = 6_000 }, sync(.{ .started_ms = 6_000, .waiting_since_ms = 9_000 }, true, false, 8_000));
}

/// Drives seeded sequences of turns, prompts, compactions, time, and UI
/// syncs that lag behind them, and checks the laws after every step: the
/// turn clock shows exactly the time the turn ran with no wait seen at the
/// last sync, never goes back within a turn, holds whenever a sync saw a
/// wait, and a running compaction shows the time since it began.
fn fuzzClock(_: void, smith: *testing.Smith) !void {
    var activity: compaction_activity.State = .{};
    var id: ?compaction_activity.OperationId = null;
    var began_ms: i64 = 0;
    var marks: Marks = .{};
    var running = false;
    var prompt_open = false;
    var now: i64 = smith.valueRangeAtMost(i64, 1, 1 << 41);
    var work_ms: i64 = 0;
    var shown: ?i64 = null;
    var steps: usize = 0;
    while (steps < 256 and !smith.eos()) : (steps += 1) {
        const active = if (activity.snapshot.operation) |op| op.active() else false;
        switch (smith.valueRangeAtMost(u8, 0, 10)) {
            0 => {
                const gap = switch (smith.valueRangeAtMost(u8, 0, 3)) {
                    0 => smith.valueRangeAtMost(i64, 0, 50),
                    1 => smith.valueRangeAtMost(i64, 0, 2_000),
                    2 => smith.valueRangeAtMost(i64, 0, 10 * 60_000),
                    else => smith.valueRangeAtMost(i64, 0, 24 * 3_600_000),
                };
                if (running and marks.waiting_since_ms == 0) work_ms += gap;
                now += gap;
            },
            1 => {
                const waiting = waits(prompt_open, activity.snapshot);
                marks = sync(marks, running, waiting, now);
                if (running) try testing.expectEqual(waiting, marks.waiting_since_ms > 0);
            },
            2 => if (!running) {
                running = true;
                marks = .{ .started_ms = now };
                work_ms = 0;
                shown = null;
            },
            3 => if (running) {
                running = false;
                prompt_open = false;
                marks = .{};
                shown = null;
            },
            4 => if (running) {
                prompt_open = !prompt_open;
            },
            5 => if (!active) {
                const origins = [_]compaction_activity.Origin{ .manual, .automatic, .provider_overflow };
                id = activity.begin(origins[smith.index(origins.len)], 1, now);
                began_ms = now;
            },
            6 => if (id) |current| {
                const stages = [_]compaction_activity.Stage{ .preparation, .summary, .publication };
                activity.running(current, stages[smith.index(stages.len)]);
            },
            7 => if (id) |current| activity.stopping(current),
            8 => if (id) |current| activity.settle(current, .{ .outcome = .succeeded, .publication = .committed }, now),
            9 => if (id) |current| activity.settle(current, compaction_activity.failure(error.Cancelled, .summary, true), now),
            else => if (id) |current| {
                _ = activity.dismiss(current, activity.snapshot.revision);
            },
        }
        if (running) {
            const now_shown = seconds(marks, now);
            try testing.expectEqual(@as(?i64, @divTrunc(work_ms, ms_per_second)), now_shown);
            if (shown) |before| try testing.expect(now_shown.? >= before);
            shown = now_shown;
        }
        if (activity.snapshot.operation) |op| if (op.active()) {
            try testing.expectEqual(@as(?i64, @divTrunc(now - began_ms, ms_per_second)), seconds(compactionMarks(op), now));
        };
    }
}

test "the turn clock keeps its laws on fuzzed event sequences" {
    try testing.fuzz({}, fuzzClock, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
            "\x02\x05\x01\x00\x03\x06\x01\x00\x08\x01\x00\x04\x01\x00\x04\x01",
        }) ++ @import("fuzz_corpus").turn_clock.*),
    });
}
