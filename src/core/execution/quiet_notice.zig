//! When a running shell command's result asks the model to check the command,
//! and whether a wait ended past the quiet limit after seeing the command
//! under it. A command that prints nothing for the quiet limit may have hung,
//! or may be a server or watcher at rest; fx never stops it and never cuts a
//! requested wait short for quiet, so the wait runs to its ceiling, command
//! exit, or steering yield.
//!
//! Every time is an argument, so tests choose the clock. The module imports
//! only `std`. `tests/tla/managed_execution/QuietWait.tla` models it, and
//! `tests/tla/drivers/managed_execution/` walks it along that model.

const std = @import("std");

/// How long a command may print nothing before its result asks the model to
/// check it.
pub const default_limit_ms: u64 = 2 * std.time.ms_per_min;

/// The shortest limit `FX_TEST_SHELL_QUIET_NOTICE_MS` may set.
pub const min_test_limit_ms: u64 = 100;

/// One wait on a running command, such as an `interact` call.
pub const Wait = struct {
    started_ms: i64,
    /// The wait's ceiling, its `yield_time_ms`.
    ceiling_ms: u64,
    /// The wait has seen the command under the quiet limit (at start or after
    /// new output), so if it ends past the limit that counts as one crossing.
    /// A wait that begins past the limit stays unarmed until new output
    /// brings the command back under it, so a later wait in the same quiet
    /// spell does not cross again.
    armed: bool,
};

pub const End = enum {
    /// The wait ran its whole ceiling.
    ceiling,
};

pub const Poll = struct {
    wait: Wait,
    end: ?End,
    crossed: bool,
};

/// How long the command has printed nothing: from its last output, or from
/// its start when it has printed nothing yet. A clock that moves back reads
/// as no time.
pub fn quietMs(now_ms: i64, last_output_ms: i64) u64 {
    return elapsedMs(last_output_ms, now_ms);
}

/// How long the command has run.
fn runningMs(now_ms: i64, started_ms: i64) u64 {
    return elapsedMs(started_ms, now_ms);
}

/// The result asks the model to check the command.
fn noticeDue(quiet_ms: u64, limit_ms: u64) bool {
    return quiet_ms >= limit_ms;
}

/// Whether a quiet command's process tree showed new CPU or write activity
/// since the previous check.
pub const Activity = struct {
    cpu: bool = false,
    writes: bool = false,
};

/// Short description placed after the quiet duration when the command's
/// process tree is still active; null when no CPU or write growth was seen.
pub fn activityDetail(activity: Activity) ?[]const u8 {
    if (activity.cpu and activity.writes) return "still active (using CPU and writing files)";
    if (activity.cpu) return "still active (using CPU)";
    if (activity.writes) return "still active (writing files)";
    return null;
}

/// What a result for a running command says about its time.
pub const Times = struct {
    running_ms: u64,
    quiet_ms: u64,
    notice: bool,
};

/// The time fields of a result: only a running command has them.
pub fn timesFor(running: bool, now_ms: i64, started_ms: i64, last_output_ms: i64, limit_ms: u64) ?Times {
    if (!running) return null;
    const quiet_ms = quietMs(now_ms, last_output_ms);
    return .{
        .running_ms = runningMs(now_ms, started_ms),
        .quiet_ms = quiet_ms,
        .notice = noticeDue(quiet_ms, limit_ms),
    };
}

pub fn beginWait(now_ms: i64, last_output_ms: i64, ceiling_ms: u64, limit_ms: u64) Wait {
    return .{
        .started_ms = now_ms,
        .ceiling_ms = ceiling_ms,
        .armed = !noticeDue(quietMs(now_ms, last_output_ms), limit_ms),
    };
}

/// Whether a wait ending at `now_ms` counts as a quiet crossing: it saw the
/// command under the limit (`armed`) and the command is at or past the limit.
pub fn crossedAt(wait: Wait, now_ms: i64, last_output_ms: i64, limit_ms: u64) bool {
    return wait.armed and noticeDue(quietMs(now_ms, last_output_ms), limit_ms);
}

/// One look at a running command during a wait: the wait as it now stands,
/// whether it reached its ceiling, and whether that end is a crossing.
pub fn poll(wait: Wait, now_ms: i64, last_output_ms: i64, limit_ms: u64) Poll {
    const due = noticeDue(quietMs(now_ms, last_output_ms), limit_ms);
    var next = wait;
    if (!due) next.armed = true;
    if (elapsedMs(wait.started_ms, now_ms) >= wait.ceiling_ms) {
        return .{
            .wait = next,
            .end = .ceiling,
            .crossed = crossedAt(next, now_ms, last_output_ms, limit_ms),
        };
    }
    return .{ .wait = next, .end = null, .crossed = false };
}

/// The quiet limit: the default, or the value of
/// `FX_TEST_SHELL_QUIET_NOTICE_MS` when it is a whole number of milliseconds
/// from `min_test_limit_ms` to the default.
pub fn limitFromValue(value: ?[]const u8) u64 {
    const text = value orelse return default_limit_ms;
    const parsed = std.fmt.parseInt(u64, text, 10) catch return default_limit_ms;
    if (parsed < min_test_limit_ms or parsed > default_limit_ms) return default_limit_ms;
    return parsed;
}

fn elapsedMs(from_ms: i64, to_ms: i64) u64 {
    if (to_ms <= from_ms) return 0;
    return @intCast(to_ms - from_ms);
}

const testing = std.testing;

test "the notice is due exactly at the limit" {
    try testing.expect(!noticeDue(1_499, 1_500));
    try testing.expect(noticeDue(1_500, 1_500));
    try testing.expect(noticeDue(1_501, 1_500));
}

test "quiet and running time read a clock that moves back as no time" {
    try testing.expectEqual(@as(u64, 0), quietMs(1_000, 1_000));
    try testing.expectEqual(@as(u64, 0), quietMs(900, 1_000));
    try testing.expectEqual(@as(u64, 250), quietMs(1_250, 1_000));
    try testing.expectEqual(@as(u64, 0), runningMs(5, 10));
    try testing.expectEqual(@as(u64, 7), runningMs(17, 10));
}

test "only a running command's result carries time fields" {
    try testing.expectEqual(@as(?Times, null), timesFor(false, 20_000, 1_000, 2_000, 1_500));
    try testing.expectEqual(
        @as(?Times, .{ .running_ms = 1_499, .quiet_ms = 1_499, .notice = false }),
        timesFor(true, 2_499, 1_000, 1_000, 1_500),
    );
    try testing.expectEqual(
        @as(?Times, .{ .running_ms = 2_500, .quiet_ms = 1_500, .notice = true }),
        timesFor(true, 3_500, 1_000, 2_000, 1_500),
    );
}

test "a wait that begins under the limit runs to its ceiling, not ending at the crossing" {
    const wait = beginWait(10_000, 9_000, 20_000, 1_500);
    try testing.expect(wait.armed);
    // 1 ms before the crossing, at the crossing, and 1 ms before the ceiling the wait goes on.
    try testing.expectEqual(@as(?End, null), poll(wait, 10_499, 9_000, 1_500).end);
    try testing.expectEqual(@as(?End, null), poll(wait, 10_500, 9_000, 1_500).end);
    try testing.expectEqual(@as(?End, null), poll(wait, 29_999, 9_000, 1_500).end);
    // At the ceiling it ends.
    try testing.expectEqual(@as(?End, .ceiling), poll(wait, 30_000, 9_000, 1_500).end);
}

test "a wait that begins under the limit reports a crossing only at its ceiling" {
    const wait = beginWait(10_000, 9_000, 20_000, 1_500);
    try testing.expect(wait.armed);
    const at_crossing = poll(wait, 10_500, 9_000, 1_500);
    try testing.expectEqual(@as(?End, null), at_crossing.end);
    try testing.expect(!at_crossing.crossed);
    const at_ceiling = poll(at_crossing.wait, 30_000, 9_000, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), at_ceiling.end);
    try testing.expect(at_ceiling.crossed);
}

test "a wait that begins past the limit runs to its ceiling without a crossing" {
    const wait = beginWait(10_000, 5_000, 2_000, 1_500);
    try testing.expect(!wait.armed);
    const early = poll(wait, 10_001, 5_000, 1_500);
    try testing.expectEqual(@as(?End, null), early.end);
    try testing.expect(!early.crossed);
    const before_ceiling = poll(early.wait, 11_999, 5_000, 1_500);
    try testing.expectEqual(@as(?End, null), before_ceiling.end);
    try testing.expect(!before_ceiling.crossed);
    const at_ceiling = poll(before_ceiling.wait, 12_000, 5_000, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), at_ceiling.end);
    try testing.expect(!at_ceiling.crossed);
}

test "output during a wait that began past the limit arms it for a crossing at its ceiling" {
    var wait = beginWait(10_000, 5_000, 20_000, 1_500);
    try testing.expect(!wait.armed);
    // Output at 10_200 brings the command under the limit.
    var step = poll(wait, 10_300, 10_200, 1_500);
    try testing.expectEqual(@as(?End, null), step.end);
    try testing.expect(!step.crossed);
    try testing.expect(step.wait.armed);
    wait = step.wait;
    step = poll(wait, 11_699, 10_200, 1_500);
    try testing.expectEqual(@as(?End, null), step.end);
    try testing.expect(!step.crossed);
    // Reaching the limit during the wait does not end it.
    step = poll(step.wait, 11_700, 10_200, 1_500);
    try testing.expectEqual(@as(?End, null), step.end);
    try testing.expect(!step.crossed);
    // At the ceiling, still past the limit, it ends with a crossing.
    step = poll(step.wait, 30_000, 10_200, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), step.end);
    try testing.expect(step.crossed);
}

test "output just before the crossing keeps the wait under the limit past a short ceiling" {
    const wait = beginWait(10_000, 10_000, 2_000, 1_500);
    // Output at 11_400, 100 ms before the first crossing, pushes the limit past the 12_000 ceiling.
    const after_output = poll(wait, 11_500, 11_400, 1_500);
    try testing.expectEqual(@as(?End, null), after_output.end);
    try testing.expect(!after_output.crossed);
    const at_ceiling = poll(after_output.wait, 12_000, 11_400, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), at_ceiling.end);
    try testing.expect(!at_ceiling.crossed);
}

test "output just before the crossing moves it and still waits for the ceiling" {
    const wait = beginWait(10_000, 10_000, 20_000, 1_500);
    // Output at 11_400, 100 ms before the first crossing.
    const at_11500 = poll(wait, 11_500, 11_400, 1_500);
    try testing.expectEqual(@as(?End, null), at_11500.end);
    try testing.expect(!at_11500.crossed);
    try testing.expectEqual(@as(?End, null), poll(at_11500.wait, 12_899, 11_400, 1_500).end);
    const at_moved_crossing = poll(at_11500.wait, 12_900, 11_400, 1_500);
    try testing.expectEqual(@as(?End, null), at_moved_crossing.end);
    try testing.expect(!at_moved_crossing.crossed);
    const at_ceiling = poll(at_moved_crossing.wait, 30_000, 11_400, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), at_ceiling.end);
    try testing.expect(at_ceiling.crossed);
}

test "a ceiling shorter than the time left ends the wait at the ceiling without a crossing" {
    const wait = beginWait(10_000, 10_000, 500, 1_500);
    try testing.expectEqual(@as(?End, null), poll(wait, 10_499, 10_000, 1_500).end);
    const step = poll(wait, 10_500, 10_000, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), step.end);
    try testing.expect(!step.crossed);
}

test "a crossing and a ceiling at the same moment end at the ceiling and report a crossing" {
    const wait = beginWait(10_000, 10_000, 1_500, 1_500);
    const step = poll(wait, 11_500, 10_000, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), step.end);
    try testing.expect(step.crossed);
}

test "a zero ceiling ends the wait at once without a crossing" {
    const wait = beginWait(10_000, 10_000, 0, 1_500);
    const step = poll(wait, 10_000, 10_000, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), step.end);
    try testing.expect(!step.crossed);
}

test "crossedAt reports a crossing only when the wait is armed and at or past the limit" {
    const armed_wait = beginWait(10_000, 9_500, 20_000, 1_500);
    try testing.expect(!crossedAt(armed_wait, 10_999, 9_500, 1_500));
    try testing.expect(crossedAt(armed_wait, 11_000, 9_500, 1_500));
    try testing.expect(!crossedAt(armed_wait, 12_000, 11_000, 1_500));

    const unarmed_wait = beginWait(10_000, 5_000, 20_000, 1_500);
    try testing.expect(!crossedAt(unarmed_wait, 12_000, 5_000, 1_500));
}

test "the test limit takes only whole milliseconds in range" {
    try testing.expectEqual(default_limit_ms, limitFromValue(null));
    try testing.expectEqual(default_limit_ms, limitFromValue(""));
    try testing.expectEqual(default_limit_ms, limitFromValue("fast"));
    try testing.expectEqual(default_limit_ms, limitFromValue("-5"));
    try testing.expectEqual(default_limit_ms, limitFromValue("99"));
    try testing.expectEqual(@as(u64, 100), limitFromValue("100"));
    try testing.expectEqual(@as(u64, 1_500), limitFromValue("1500"));
    try testing.expectEqual(default_limit_ms, limitFromValue("120000"));
    try testing.expectEqual(default_limit_ms, limitFromValue("120001"));
    try testing.expectEqual(default_limit_ms, limitFromValue("18446744073709551616"));
}
