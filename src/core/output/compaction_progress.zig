//! The number on the compaction row, such as the 23 in
//! `• Compacting 23% (53s)`.
//!
//! The notes' own count (`src/core/compactor/progress.zig`) can move only
//! while the model writes them, and a model reads and reasons first: a large
//! conversation can take minutes before its first line. So each summary
//! request first earns a share of the room left on the row for the time it
//! waits, and its notes then fill what remains. The share grows with the wait
//! and stays under half of that room, so the row moves while the model reads
//! without claiming notes that were not written.
//!
//! This module reads no clock and allocates nothing. Every time is handed in.
//! Only time that passed forward counts as waiting, in steps of at most
//! `longest_step_ms`, so a system clock set back takes nothing from the
//! number, and a clock set forward, or a sleep, adds nothing to it. The
//! number is read from the state alone.
//! `tests/tla/compaction_progress/CompactionProgress.tla` models it, and
//! `tests/tla/drivers/compaction_progress/driver.ts` walks it along the
//! model.

const std = @import("std");

/// The highest count of notes the row takes before fx saves them, since 100%
/// shows only while fx saves the summary. The limit is defined here alone:
/// the compactor reports the plain share of the notes, up to 100.
pub const all_notes: u8 = 99;
/// Where the row's number stops before fx saves, in hundredths of a percent.
const top_hundredths: u64 = @as(u64, all_notes) * 100;
/// A wait's share of the room left, in ten-thousandths, approaches this.
const wait_share: u64 = 5_000;
const share_scale: u64 = 10_000;
/// The wait that earns half of `wait_share`.
const wait_half_ms: u64 = 60_000;
/// A longer wait earns no more, which keeps the wait in a `u32`.
const longest_wait_ms: u64 = 24 * std.time.ms_per_hour;
/// The longest step between two times the row is handed that counts as
/// waiting. The UI's tick hands in the time far more often than this, so a
/// longer step is a sleep or a system clock set forward, and it earns
/// nothing.
const longest_step_ms: u64 = 60 * std.time.ms_per_s;

pub const Progress = struct {
    /// What the row showed when the request in flight was sent, in
    /// hundredths of a percent.
    floor: u16 = 0,
    /// The notes' count when that request was sent.
    base: u8 = 0,
    /// The notes' count now, from 0 to 99.
    notes: u8 = 0,
    /// A request is in flight and none of its notes have arrived.
    waiting: bool = false,
    /// How long that request has waited for its first notes, as far as the
    /// row saw time pass.
    waited_ms: u32 = 0,
    /// The time the row was handed last; 0 before the first.
    seen_ms: i64 = 0,

    /// The row is handed the time. Only time that passed forward since the
    /// time before counts as waiting, and only in a step of at most
    /// `longest_step_ms`. So a system clock set back takes nothing from the
    /// number (CountNeverFalls), a clock set forward or a sleep adds nothing
    /// to it (JumpEarnsNothing), and the wait goes on from the new time.
    pub fn observed(self: *Progress, now_ms: i64) void {
        if (self.waiting and now_ms > self.seen_ms) {
            const passed: u64 = @intCast(now_ms -| self.seen_ms);
            if (passed <= longest_step_ms) {
                self.waited_ms = @intCast(@min(self.waited_ms + passed, longest_wait_ms));
            }
        }
        self.seen_ms = now_ms;
    }

    /// A summary request is about to be sent. The row goes on from the
    /// number it shows now (AskKeepsTheCount).
    pub fn asked(self: *Progress, now_ms: i64) void {
        self.observed(now_ms);
        self.floor = self.value();
        self.base = self.notes;
        self.waited_ms = 0;
        self.waiting = true;
    }

    /// The notes' count rose to `percent`. Only a higher count replaces a
    /// lower one, and the request's wait stops earning
    /// (OnlyNotesMoveAfterNotes). Returns whether anything changed.
    pub fn written(self: *Progress, percent: u8, now_ms: i64) bool {
        const count = @min(percent, all_notes);
        if (count <= self.notes) return false;
        self.observed(now_ms);
        self.notes = count;
        self.waiting = false;
        return true;
    }

    /// The row's number, from 0 to 99.
    pub fn shown(self: Progress) u8 {
        return @intCast(self.value() / 100);
    }

    /// The number in hundredths of a percent. One division, so that with no
    /// wait it is exactly the notes' count (ExactWithoutWaiting).
    fn value(self: Progress) u16 {
        const floor: u64 = self.floor;
        const room = top_hundredths - floor;
        const head = self.waitShare();
        const span: u64 = all_notes - self.base;
        if (span == 0) return @intCast(floor + room * head / share_scale);
        const fresh: u64 = self.notes - self.base;
        return @intCast(floor + room * (head * span + (share_scale - head) * fresh) / (share_scale * span));
    }

    /// The share of the room left that the request in flight has earned by
    /// waiting. It stays under `wait_share` (WaitIsBounded).
    fn waitShare(self: Progress) u64 {
        const waited: u64 = self.waited_ms;
        return wait_share * waited / (waited + wait_half_ms);
    }
};

/// Hands the row the time up to `until_ms` in steps that count as waiting,
/// as the UI's tick does.
fn tick(progress: *Progress, until_ms: i64) void {
    const step: i64 = @intCast(longest_step_ms);
    while (progress.seen_ms < until_ms) progress.observed(@min(progress.seen_ms + step, until_ms));
}

test "with no wait the row shows the notes' own count" {
    var progress: Progress = .{};
    for (0..100) |count| {
        _ = progress.written(@intCast(count), 5);
        try std.testing.expectEqual(@as(u8, @intCast(count)), progress.shown());
    }
    // A request whose notes arrive at once earns nothing for a wait.
    var answered: Progress = .{};
    answered.asked(1_000);
    try std.testing.expect(answered.written(66, 1_000));
    answered.observed(90_000);
    try std.testing.expectEqual(@as(u8, 66), answered.shown());
}

test "the row moves while the first request waits, and a wait earns less than half" {
    var progress: Progress = .{};
    progress.asked(1_000);
    try std.testing.expectEqual(@as(u8, 0), progress.shown());
    const steps = [_]struct { now_ms: i64, shown: u8 }{
        .{ .now_ms = 2_249, .shown = 0 },
        .{ .now_ms = 2_250, .shown = 1 },
        .{ .now_ms = 11_000, .shown = 7 },
        .{ .now_ms = 54_000, .shown = 23 },
        .{ .now_ms = 61_000, .shown = 24 },
        .{ .now_ms = 126_000, .shown = 33 },
        // However long the model reads, the wait stays under half of the row.
        .{ .now_ms = 1_000 + 24 * std.time.ms_per_hour, .shown = 49 },
        .{ .now_ms = 1_000 + 400 * 24 * std.time.ms_per_hour, .shown = 49 },
    };
    for (steps) |step| {
        tick(&progress, step.now_ms);
        try std.testing.expectEqual(step.shown, progress.shown());
    }
}

test "the notes fill what the wait left, and the wait stops earning once they arrive" {
    var progress: Progress = .{};
    progress.asked(1_000);
    // 125 s of reading, then the first note.
    tick(&progress, 126_000);
    try std.testing.expect(progress.written(1, 126_000));
    try std.testing.expectEqual(@as(u8, 34), progress.shown());
    // Time alone no longer moves the row.
    progress.observed(190_000);
    try std.testing.expectEqual(@as(u8, 34), progress.shown());
    try std.testing.expect(progress.written(50, 200_000));
    try std.testing.expectEqual(@as(u8, 66), progress.shown());
    try std.testing.expect(progress.written(99, 250_000));
    try std.testing.expectEqual(@as(u8, 99), progress.shown());
    // The count stops at 99 until fx has saved the summary.
    try std.testing.expect(!progress.written(100, 251_000));
    progress.observed(900_000);
    try std.testing.expectEqual(@as(u8, 99), progress.shown());
}

test "a new request goes on from the number the row shows" {
    var progress: Progress = .{};
    progress.asked(1_000);
    try std.testing.expect(progress.written(40, 31_000));
    progress.observed(40_000);
    try std.testing.expectEqual(@as(u8, 49), progress.shown());
    // A follow-up request, or another model after a failure.
    progress.asked(40_000);
    try std.testing.expectEqual(@as(u8, 49), progress.shown());
    // Its wait earns a share of the room that is left.
    progress.observed(100_000);
    try std.testing.expectEqual(@as(u8, 62), progress.shown());
    // A lower count from the new reply changes nothing; a higher one counts on.
    try std.testing.expect(!progress.written(30, 101_000));
    try std.testing.expect(progress.written(99, 160_000));
    try std.testing.expectEqual(@as(u8, 99), progress.shown());
}

test "a system clock set back takes nothing from the number, and the wait goes on from the new time" {
    var progress: Progress = .{};
    progress.asked(1_000);
    progress.observed(54_000);
    try std.testing.expectEqual(@as(u8, 23), progress.shown());
    // The clock is set back 52 s. The 53 s the request waited still count.
    progress.observed(2_000);
    try std.testing.expectEqual(@as(u8, 23), progress.shown());
    // Seven more seconds make the wait 60 s.
    progress.observed(9_000);
    try std.testing.expectEqual(@as(u8, 24), progress.shown());
    // The notes arrive at a time before the request's own.
    try std.testing.expect(progress.written(99, 500));
    try std.testing.expectEqual(@as(u8, 99), progress.shown());
}

test "a clock set forward, or a sleep, adds nothing to the number, and the wait goes on from the new time" {
    var progress: Progress = .{};
    progress.asked(1_000);
    progress.observed(54_000);
    try std.testing.expectEqual(@as(u8, 23), progress.shown());
    // The machine sleeps for two hours, or the clock is set forward.
    const woke = 54_000 + 2 * std.time.ms_per_hour;
    progress.observed(woke);
    try std.testing.expectEqual(@as(u8, 23), progress.shown());
    // Seven more seconds make the wait 60 s.
    progress.observed(woke + 7_000);
    try std.testing.expectEqual(@as(u8, 24), progress.shown());
    // The longest step that counts, and the first that does not.
    var counted: Progress = .{};
    counted.asked(1_000);
    counted.observed(61_000);
    try std.testing.expectEqual(@as(u8, 24), counted.shown());
    var skipped: Progress = .{};
    skipped.asked(1_000);
    skipped.observed(61_001);
    try std.testing.expectEqual(@as(u8, 0), skipped.shown());
}

test "the row never falls and never passes 99, whatever arrives and whichever way the clock goes" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..2_000) |_| {
        var progress: Progress = .{};
        var now: i64 = 1_000_000;
        var last: u8 = 0;
        for (0..80) |_| {
            switch (random.uintLessThan(u8, 6)) {
                0 => now += random.uintLessThan(u32, 200_000),
                1 => now += random.uintLessThan(u32, 50),
                // The system clock is set back.
                2 => now -= random.uintLessThan(u32, 300_000),
                3 => {
                    const before = progress.shown();
                    progress.asked(now);
                    try std.testing.expectEqual(before, progress.shown());
                },
                4 => _ = progress.written(random.uintAtMost(u8, 120), now),
                else => {},
            }
            progress.observed(now);
            const shown = progress.shown();
            try std.testing.expect(shown >= last);
            try std.testing.expect(shown <= all_notes);
            if (progress.notes == all_notes) try std.testing.expectEqual(all_notes, shown);
            last = shown;
        }
    }
}
