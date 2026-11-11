//! When a wait on a running shell command ends because the command went
//! quiet, and when its result asks the model to check the command. A command
//! that prints nothing for the quiet limit may have hung, or may be a server
//! or watcher at rest; fx never stops it, but a model that waits on it learns
//! how long it has been quiet.
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
    /// The wait has seen the command under the quiet limit, so the moment
    /// the quiet time reaches the limit ends it. A wait that begins past the
    /// limit runs to its ceiling until new output brings the command back
    /// under it, so a model that waits again is not woken at once.
    armed: bool,
};

pub const End = enum {
    /// The command reached the quiet limit during the wait.
    quiet,
    /// The wait ran its whole ceiling.
    ceiling,
};

pub const Poll = struct {
    wait: Wait,
    end: ?End,
};

/// How long the command has printed nothing: from its last output, or from
/// its start when it has printed nothing yet. A clock that moves back reads
/// as no time.
pub fn quietMs(now_ms: i64, last_output_ms: i64) u64 {
    return elapsedMs(last_output_ms, now_ms);
}

/// How long the command has run.
pub fn runningMs(now_ms: i64, started_ms: i64) u64 {
    return elapsedMs(started_ms, now_ms);
}

/// The result asks the model to check the command.
pub fn noticeDue(quiet_ms: u64, limit_ms: u64) bool {
    return quiet_ms >= limit_ms;
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

/// One look at a running command during a wait: the wait as it now stands,
/// and why it ends, or null while it goes on.
pub fn poll(wait: Wait, now_ms: i64, last_output_ms: i64, limit_ms: u64) Poll {
    const due = noticeDue(quietMs(now_ms, last_output_ms), limit_ms);
    var next = wait;
    if (!due) next.armed = true;
    if (next.armed and due) return .{ .wait = next, .end = .quiet };
    if (elapsedMs(wait.started_ms, now_ms) >= wait.ceiling_ms) return .{ .wait = next, .end = .ceiling };
    return .{ .wait = next, .end = null };
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

test "a wait that begins under the limit ends at the crossing, not before" {
    const wait = beginWait(10_000, 9_000, 20_000, 1_500);
    try testing.expect(wait.armed);
    // 1 ms before the crossing the wait goes on.
    try testing.expectEqual(@as(?End, null), poll(wait, 10_499, 9_000, 1_500).end);
    // At the crossing it ends for quiet.
    try testing.expectEqual(@as(?End, .quiet), poll(wait, 10_500, 9_000, 1_500).end);
}

test "a wait that begins past the limit runs to its ceiling" {
    const wait = beginWait(10_000, 5_000, 2_000, 1_500);
    try testing.expect(!wait.armed);
    try testing.expectEqual(@as(?End, null), poll(wait, 10_001, 5_000, 1_500).end);
    try testing.expectEqual(@as(?End, null), poll(wait, 11_999, 5_000, 1_500).end);
    try testing.expectEqual(@as(?End, .ceiling), poll(wait, 12_000, 5_000, 1_500).end);
}

test "output during a wait that began past the limit arms it for the next crossing" {
    var wait = beginWait(10_000, 5_000, 20_000, 1_500);
    try testing.expect(!wait.armed);
    // Output at 10_200 brings the command under the limit.
    var step = poll(wait, 10_300, 10_200, 1_500);
    try testing.expectEqual(@as(?End, null), step.end);
    try testing.expect(step.wait.armed);
    wait = step.wait;
    step = poll(wait, 11_699, 10_200, 1_500);
    try testing.expectEqual(@as(?End, null), step.end);
    step = poll(step.wait, 11_700, 10_200, 1_500);
    try testing.expectEqual(@as(?End, .quiet), step.end);
}

test "output just before the crossing moves it" {
    const wait = beginWait(10_000, 10_000, 20_000, 1_500);
    // Output at 11_400, 100 ms before the first crossing.
    try testing.expectEqual(@as(?End, null), poll(wait, 11_500, 11_400, 1_500).end);
    try testing.expectEqual(@as(?End, null), poll(wait, 12_899, 11_400, 1_500).end);
    try testing.expectEqual(@as(?End, .quiet), poll(wait, 12_900, 11_400, 1_500).end);
}

test "a ceiling shorter than the time left ends the wait at the ceiling" {
    const wait = beginWait(10_000, 10_000, 500, 1_500);
    try testing.expectEqual(@as(?End, null), poll(wait, 10_499, 10_000, 1_500).end);
    try testing.expectEqual(@as(?End, .ceiling), poll(wait, 10_500, 10_000, 1_500).end);
}

test "a crossing and a ceiling at the same moment end the wait for quiet" {
    const wait = beginWait(10_000, 10_000, 1_500, 1_500);
    try testing.expectEqual(@as(?End, .quiet), poll(wait, 11_500, 10_000, 1_500).end);
}

test "a zero ceiling ends the wait at once" {
    const wait = beginWait(10_000, 10_000, 0, 1_500);
    try testing.expectEqual(@as(?End, .ceiling), poll(wait, 10_000, 10_000, 1_500).end);
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
