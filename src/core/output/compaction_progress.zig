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
//! This module reads no clock and allocates nothing: every time is handed in.
//! `tests/tla/compaction_progress/CompactionProgress.tla` models it, and
//! `tests/tla/drivers/compaction_progress/driver.ts` walks it along the model.

const std = @import("std");

/// The row's number in hundredths of a percent stops here, at 99%: 100%
/// shows only while fx saves the summary.
const top_hundredths: u64 = 9_900;
/// The notes' count once the model has written them all.
pub const all_notes: u8 = 99;
/// A wait's share of the room left, in ten-thousandths, approaches this.
const wait_share: u64 = 5_000;
const share_scale: u64 = 10_000;
/// The wait that earns half of `wait_share`.
const wait_half_ms: u64 = 60_000;
/// A longer wait earns no more, which keeps the arithmetic in range.
const longest_wait_ms: u64 = 24 * std.time.ms_per_hour;

pub const Progress = struct {
    /// What the row showed when the request in flight was sent, in
    /// hundredths of a percent.
    floor: u16 = 0,
    /// The notes' count when that request was sent.
    base: u8 = 0,
    /// The notes' count now, from 0 to 99.
    notes: u8 = 0,
    /// When the request in flight was sent; 0 before the first one.
    asked_ms: i64 = 0,
    /// When that request's first notes arrived; 0 while it waits.
    answered_ms: i64 = 0,

    /// A summary request is about to be sent. The row goes on from the
    /// number it shows now (CountNeverFalls, AskKeepsTheCount).
    pub fn asked(self: *Progress, now_ms: i64) void {
        self.floor = self.value(now_ms);
        self.base = self.notes;
        self.asked_ms = now_ms;
        self.answered_ms = 0;
    }

    /// The notes' count rose to `percent`. Only a higher count replaces a
    /// lower one. Returns whether anything changed.
    pub fn written(self: *Progress, percent: u8, now_ms: i64) bool {
        const count = @min(percent, all_notes);
        if (count <= self.notes) return false;
        self.notes = count;
        if (self.asked_ms > 0 and self.answered_ms == 0) self.answered_ms = now_ms;
        return true;
    }

    /// The row's number at `now_ms`, from 0 to 99.
    pub fn shown(self: Progress, now_ms: i64) u8 {
        return @intCast(self.value(now_ms) / 100);
    }

    /// The number in hundredths of a percent. One division, so that with no
    /// wait it is exactly the notes' count (ExactWithoutWaiting).
    fn value(self: Progress, now_ms: i64) u16 {
        const floor: u64 = self.floor;
        const room = top_hundredths - floor;
        const head = self.waitShare(now_ms);
        const span: u64 = all_notes - self.base;
        if (span == 0) return @intCast(floor + room * head / share_scale);
        const fresh: u64 = self.notes - self.base;
        return @intCast(floor + room * (head * span + (share_scale - head) * fresh) / (share_scale * span));
    }

    /// The share of the room left that the request in flight has earned by
    /// waiting. It stops growing once the request's first notes arrive
    /// (OnlyNotesMoveAfterNotes), and stays under `wait_share`
    /// (WaitIsBounded).
    fn waitShare(self: Progress, now_ms: i64) u64 {
        if (self.asked_ms == 0) return 0;
        const until = if (self.answered_ms > 0) self.answered_ms else now_ms;
        const waited: u64 = @min(@as(u64, @intCast(@max(until -| self.asked_ms, 0))), longest_wait_ms);
        return wait_share * waited / (waited + wait_half_ms);
    }
};

test "with no wait the row shows the notes' own count" {
    var progress: Progress = .{};
    for (0..100) |count| {
        _ = progress.written(@intCast(count), 5);
        try std.testing.expectEqual(@as(u8, @intCast(count)), progress.shown(5));
    }
    // A request whose notes arrive at once earns nothing for a wait.
    var answered: Progress = .{};
    answered.asked(1_000);
    try std.testing.expect(answered.written(66, 1_000));
    try std.testing.expectEqual(@as(u8, 66), answered.shown(90_000));
}

test "the row moves while the first request waits, and a wait earns less than half" {
    var progress: Progress = .{};
    progress.asked(1_000);
    try std.testing.expectEqual(@as(u8, 0), progress.shown(1_000));
    try std.testing.expectEqual(@as(u8, 0), progress.shown(2_249));
    try std.testing.expectEqual(@as(u8, 1), progress.shown(2_250));
    try std.testing.expectEqual(@as(u8, 7), progress.shown(11_000));
    try std.testing.expectEqual(@as(u8, 23), progress.shown(54_000));
    try std.testing.expectEqual(@as(u8, 24), progress.shown(61_000));
    try std.testing.expectEqual(@as(u8, 33), progress.shown(126_000));
    // However long the model reads, the wait stays under half of the row.
    try std.testing.expectEqual(@as(u8, 49), progress.shown(1_000 + 24 * std.time.ms_per_hour));
    try std.testing.expectEqual(@as(u8, 49), progress.shown(1_000 + 400 * 24 * std.time.ms_per_hour));
    // A clock that went back earns nothing and does not trap.
    try std.testing.expectEqual(@as(u8, 0), progress.shown(500));
}

test "the notes fill what the wait left, and the wait stops earning once they arrive" {
    var progress: Progress = .{};
    progress.asked(1_000);
    // 125 s of reading, then the first note.
    try std.testing.expect(progress.written(1, 126_000));
    try std.testing.expectEqual(@as(u8, 34), progress.shown(126_000));
    // Time alone no longer moves the row.
    try std.testing.expectEqual(@as(u8, 34), progress.shown(999_000));
    try std.testing.expect(progress.written(50, 200_000));
    try std.testing.expectEqual(@as(u8, 66), progress.shown(200_000));
    try std.testing.expect(progress.written(99, 250_000));
    try std.testing.expectEqual(@as(u8, 99), progress.shown(250_000));
    // The count stops at 99 until fx has saved the summary.
    try std.testing.expect(!progress.written(100, 251_000));
    try std.testing.expectEqual(@as(u8, 99), progress.shown(900_000));
}

test "a new request goes on from the number the row shows" {
    var progress: Progress = .{};
    progress.asked(1_000);
    try std.testing.expect(progress.written(40, 31_000));
    try std.testing.expectEqual(@as(u8, 49), progress.shown(40_000));
    // A follow-up request, or another model after a failure.
    progress.asked(40_000);
    try std.testing.expectEqual(@as(u8, 49), progress.shown(40_000));
    // Its wait earns a share of the room that is left.
    try std.testing.expectEqual(@as(u8, 62), progress.shown(100_000));
    // A lower count from the new reply changes nothing; a higher one counts on.
    try std.testing.expect(!progress.written(30, 101_000));
    try std.testing.expect(progress.written(99, 160_000));
    try std.testing.expectEqual(@as(u8, 99), progress.shown(160_000));
}

test "the row never falls and never passes 99, whatever arrives" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..2_000) |_| {
        var progress: Progress = .{};
        var now: i64 = 1_000_000;
        var last: u8 = 0;
        for (0..80) |_| {
            switch (random.uintLessThan(u8, 4)) {
                0 => now += random.uintLessThan(u32, 200_000),
                1 => now += random.uintLessThan(u32, 50),
                2 => {
                    const before = progress.shown(now);
                    progress.asked(now);
                    try std.testing.expectEqual(before, progress.shown(now));
                },
                else => _ = progress.written(random.uintAtMost(u8, 120), now),
            }
            const shown = progress.shown(now);
            try std.testing.expect(shown >= last);
            try std.testing.expect(shown <= all_notes);
            if (progress.notes == all_notes) try std.testing.expectEqual(all_notes, shown);
            last = shown;
        }
    }
}
