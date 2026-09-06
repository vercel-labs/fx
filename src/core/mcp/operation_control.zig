const std = @import("std");
const atomic_value = @import("atomic_value.zig");

pub fn monotonicMillis(io: std.Io) u64 {
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    if (now.raw.nanoseconds <= 0) return 0;
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(u64, milliseconds) orelse std.math.maxInt(u64);
}

pub const CancellationState = enum {
    active,
    caller_cancelled,
    runtime_retired,
    caller_cancelled_and_runtime_retired,

    pub fn cancelled(self: CancellationState) bool {
        return self != .active;
    }
};

pub fn cancellationState(
    caller_cancelled: bool,
    runtime_retired: bool,
) CancellationState {
    if (caller_cancelled and runtime_retired) {
        return .caller_cancelled_and_runtime_retired;
    }
    if (caller_cancelled) return .caller_cancelled;
    if (runtime_retired) return .runtime_retired;
    return .active;
}

pub const CancellationSources = struct {
    caller: ?*const std.atomic.Value(bool) = null,
    runtime: ?*const std.atomic.Value(bool) = null,

    pub fn state(self: CancellationSources) CancellationState {
        return cancellationState(
            if (self.caller) |flag| flag.load(.acquire) else false,
            if (self.runtime) |flag| flag.load(.acquire) else false,
        );
    }

    pub fn cancelled(self: CancellationSources) bool {
        return self.state().cancelled();
    }
};

pub const DeadlineGate = struct {
    deadline_ms: atomic_value.Value(i64),

    pub fn init(deadline_ms: i64) DeadlineGate {
        return .{ .deadline_ms = .init(deadline_ms) };
    }

    pub fn pauseUntil(self: *DeadlineGate, deadline_ms: i64) void {
        self.deadline_ms.store(deadline_ms, .release);
    }

    pub fn resumeAt(self: *DeadlineGate, now_ms: i64, timeout_ms: u32) void {
        self.deadline_ms.store(resumedDeadlineMs(now_ms, timeout_ms), .release);
    }

    pub fn expired(self: *const DeadlineGate, now_ms: i64) bool {
        return now_ms >= self.deadline_ms.load(.acquire);
    }

    pub fn currentDeadlineMs(self: *const DeadlineGate) i64 {
        return self.deadline_ms.load(.acquire);
    }
};

fn resumedDeadlineMs(now_ms: i64, timeout_ms: u32) i64 {
    return std.math.add(i64, now_ms, timeout_ms) catch std.math.maxInt(i64);
}

test "cancellation state preserves caller and runtime retirement signals" {
    const Case = struct {
        caller: bool,
        runtime: bool,
        expected: CancellationState,
    };
    const cases = [_]Case{
        .{ .caller = false, .runtime = false, .expected = .active },
        .{ .caller = true, .runtime = false, .expected = .caller_cancelled },
        .{ .caller = false, .runtime = true, .expected = .runtime_retired },
        .{ .caller = true, .runtime = true, .expected = .caller_cancelled_and_runtime_retired },
    };
    for (cases) |case| {
        const state = cancellationState(case.caller, case.runtime);
        try std.testing.expectEqual(case.expected, state);
        try std.testing.expectEqual(case.expected != .active, state.cancelled());
    }
}

test "cancellation sources do not rewrite either owner" {
    var caller = std.atomic.Value(bool).init(false);
    var runtime = std.atomic.Value(bool).init(false);
    const sources = CancellationSources{ .caller = &caller, .runtime = &runtime };

    try std.testing.expectEqual(CancellationState.active, sources.state());
    runtime.store(true, .release);
    try std.testing.expectEqual(CancellationState.runtime_retired, sources.state());
    try std.testing.expect(!caller.load(.acquire));
    caller.store(true, .release);
    try std.testing.expectEqual(
        CancellationState.caller_cancelled_and_runtime_retired,
        sources.state(),
    );
}

test "deadline gate pauses input and resumes with one fresh operation budget" {
    var gate = DeadlineGate.init(1_000);
    try std.testing.expect(!gate.expired(999));
    try std.testing.expect(gate.expired(1_000));

    gate.pauseUntil(31_000);
    try std.testing.expect(!gate.expired(20_000));
    try std.testing.expectEqual(@as(i64, 31_000), gate.currentDeadlineMs());
    try std.testing.expect(gate.expired(31_000));

    gate.resumeAt(20_000, 1_500);
    try std.testing.expect(!gate.expired(21_499));
    try std.testing.expect(gate.expired(21_500));
}

test "deadline gate saturates resumed deadlines" {
    try std.testing.expectEqual(
        std.math.maxInt(i64),
        resumedDeadlineMs(std.math.maxInt(i64) - 1, 2),
    );
}

pub fn timestampMillis(timestamp: std.Io.Clock.Timestamp) i64 {
    const milliseconds = @divFloor(timestamp.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

pub fn awakeMillis(io: std.Io) i64 {
    return timestampMillis(std.Io.Clock.Timestamp.now(io, .awake));
}

pub fn elicitationDeadline(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(@import("mcp_contract.zig").default_elicitation_timeout_ms),
    });
}
