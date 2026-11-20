//! Schedules turning a terminal mode on again while fx runs. A terminal reset,
//! or another program's restore on the same terminal, can turn a DEC private
//! mode off under a running fx, and nothing tells fx. Each owner of such a
//! mode keeps one `Schedule` and writes the mode's enable sequence again when
//! the schedule is due. Enabling a mode that is already on changes nothing, so
//! the extra writes are harmless.
const std = @import("std");

/// How often fx turns each mode on again.
pub const interval_ms: i64 = 30_000;

pub const Schedule = struct {
    /// When the mode is next due. Null until the first check, which schedules
    /// it one interval out, because fx turned the mode on just before.
    next_ms: ?i64 = null,

    /// Makes the mode due at once, such as after a job-control resume whose
    /// terminal restore turned it off.
    pub fn requestNow(self: *Schedule) void {
        self.next_ms = std.math.minInt(i64);
    }

    /// Reports whether the mode is due. The first check only schedules it.
    pub fn due(self: *Schedule, now_ms: i64) bool {
        const next_ms = self.next_ms orelse {
            self.schedule(now_ms);
            return false;
        };
        return now_ms >= next_ms;
    }

    /// Makes the mode due one interval after `now_ms`.
    pub fn schedule(self: *Schedule, now_ms: i64) void {
        self.next_ms = std.math.add(i64, now_ms, interval_ms) catch std.math.maxInt(i64);
    }

    /// Returns true when the mode is due, and schedules the next time.
    pub fn take(self: *Schedule, now_ms: i64) bool {
        if (!self.due(now_ms)) return false;
        self.schedule(now_ms);
        return true;
    }
};

test "mode rearm schedule waits one interval after its first check" {
    var schedule = Schedule{};

    try std.testing.expect(!schedule.take(1_000));
    try std.testing.expect(!schedule.take(1_000 + interval_ms - 1));
    try std.testing.expect(schedule.take(1_000 + interval_ms));
    try std.testing.expect(!schedule.take(1_000 + interval_ms + 1));
    try std.testing.expect(schedule.take(1_000 + 2 * interval_ms));
}

test "mode rearm schedule is due at once on request" {
    var schedule = Schedule{};
    try std.testing.expect(!schedule.take(0));

    schedule.requestNow();
    try std.testing.expect(schedule.take(1));
    try std.testing.expect(!schedule.take(2));
    try std.testing.expect(schedule.take(1 + interval_ms));
}

test "mode rearm schedule stays due until the owner schedules it" {
    var schedule = Schedule{};
    schedule.requestNow();

    try std.testing.expect(schedule.due(5));
    try std.testing.expect(schedule.due(6));
    schedule.schedule(6);
    try std.testing.expect(!schedule.due(7));
    try std.testing.expect(schedule.due(6 + interval_ms));
}

test "mode rearm schedule saturates far in the future" {
    var schedule = Schedule{};
    schedule.schedule(std.math.maxInt(i64) - 1);

    try std.testing.expectEqual(std.math.maxInt(i64), schedule.next_ms.?);
    try std.testing.expect(!schedule.due(std.math.maxInt(i64) - 1));
}
