//! How long a contender for a held flock keeps trying: until its budget has
//! passed on the monotonic clock, however long each sleep between tries
//! really lasted (D38). A loaded machine or a background process can stretch
//! every short sleep many times over, so counting sleeps would stretch the
//! wait as much. Pure (`RULES.md` R1.5): the caller reads the clock, tries
//! the lock, and sleeps.

const std = @import("std");

/// What a contender does after a failed try.
pub const Step = union(enum) {
    /// Sleep this many milliseconds, then try again.
    sleep_ms: u64,
    /// The budget is spent: the lock is busy.
    give_up,
};

pub const Wait = struct {
    /// How long the whole wait may last; 0 tries once.
    budget_ms: u64,
    /// How long one sleep between tries asks for. Must not be 0.
    retry_ms: u64,
};

/// The step after a failed try made `elapsed_ms` after the first one, with
/// `sleeps` sleeps done before it.
pub fn afterFailedTry(wait: Wait, elapsed_ms: u64, sleeps: u64) Step {
    std.debug.assert(wait.retry_ms > 0);
    if (elapsed_ms >= wait.budget_ms) return .give_up;
    // A clock that stopped never reaches the budget, so the wait also ends
    // after as many sleeps as fit in it when each lasts exactly `retry_ms`.
    if (sleeps *| wait.retry_ms >= wait.budget_ms) return .give_up;
    return .{ .sleep_ms = @min(wait.retry_ms, wait.budget_ms - elapsed_ms) };
}

/// Whole milliseconds from `started` to `now`; 0 when `now` reads earlier.
pub fn elapsedMs(started: std.Io.Timestamp, now: std.Io.Timestamp) u64 {
    const nanoseconds = started.durationTo(now).nanoseconds;
    if (nanoseconds <= 0) return 0;
    return std.math.cast(u64, @divTrunc(nanoseconds, std.time.ns_per_ms)) orelse std.math.maxInt(u64);
}

const testing = std.testing;

const session_wait: Wait = .{ .budget_ms = 2000, .retry_ms = 10 };

/// How a wait ends when every sleep lasts `stretch` times what it asked
/// for: the sleeps it made and the monotonic time it took.
const Outcome = struct { sleeps: u64, elapsed_ms: u64 };

/// So a wait that never ends fails its test instead of hanging it.
const max_test_sleeps: u64 = 1_000_000;

fn runWait(wait: Wait, stretch: u64) Outcome {
    var outcome: Outcome = .{ .sleeps = 0, .elapsed_ms = 0 };
    while (outcome.sleeps < max_test_sleeps) : (outcome.sleeps += 1) {
        switch (afterFailedTry(wait, outcome.elapsed_ms, outcome.sleeps)) {
            .give_up => return outcome,
            .sleep_ms => |ms| outcome.elapsed_ms += ms * stretch,
        }
    }
    return outcome;
}

test "a wait whose sleeps last what they ask takes its budget in the same sleeps as before" {
    try testing.expectEqual(Outcome{ .sleeps = 200, .elapsed_ms = 2000 }, runWait(session_wait, 1));
}

test "a wait whose sleeps last five times as long still ends at its budget" {
    try testing.expectEqual(Outcome{ .sleeps = 40, .elapsed_ms = 2000 }, runWait(session_wait, 5));
}

test "a wait on a clock that never moves ends after the sleeps its budget holds" {
    try testing.expectEqual(Outcome{ .sleeps = 200, .elapsed_ms = 0 }, runWait(session_wait, 0));
}

test "a wait with no budget gives up after its first try, as the session picker's does (D38)" {
    try testing.expectEqual(Step.give_up, afterFailedTry(.{ .budget_ms = 0, .retry_ms = 10 }, 0, 0));
}

test "the last sleep is cut so the last try lands on the deadline" {
    try testing.expectEqual(Step{ .sleep_ms = 3 }, afterFailedTry(session_wait, 1997, 7));
}

test "a step never sleeps past the deadline, and gives up exactly when the budget or its sleeps are spent" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    for (0..10_000) |_| {
        const wait: Wait = .{ .budget_ms = random.uintAtMost(u64, 5000), .retry_ms = random.intRangeAtMost(u64, 1, 50) };
        const elapsed_ms = random.uintAtMost(u64, 6000);
        const sleeps = random.uintAtMost(u64, 600);
        const spent = elapsed_ms >= wait.budget_ms or sleeps * wait.retry_ms >= wait.budget_ms;
        switch (afterFailedTry(wait, elapsed_ms, sleeps)) {
            .give_up => try testing.expect(spent),
            .sleep_ms => |ms| {
                try testing.expect(!spent);
                try testing.expect(ms > 0 and ms <= wait.retry_ms);
                try testing.expect(elapsed_ms + ms <= wait.budget_ms);
            },
        }
        // Later on the clock, a wait that gave up still gives up.
        if (afterFailedTry(wait, elapsed_ms, sleeps) == .give_up) {
            try testing.expectEqual(Step.give_up, afterFailedTry(wait, elapsed_ms + random.uintAtMost(u64, 1000), sleeps));
        }
    }
}

test "elapsed time is whole milliseconds, and 0 when the clock reads earlier" {
    const start: std.Io.Timestamp = .fromNanoseconds(5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u64, 1234), elapsedMs(start, .fromNanoseconds(5 * std.time.ns_per_s + 1_234_999_999)));
    try testing.expectEqual(@as(u64, 0), elapsedMs(start, .fromNanoseconds(4 * std.time.ns_per_s)));
}
