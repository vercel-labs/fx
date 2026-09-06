const std = @import("std");
const operation_control = @import("operation_control.zig");

pub fn check(io: std.Io, control: Control) error{ Cancelled, McpRequestTimedOut }!void {
    if (control.cancellation().cancelled()) return error.Cancelled;
    if (control.deadline) |deadline| {
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io, .awake), .lt, deadline)) return error.McpRequestTimedOut;
    }
}

pub const Control = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,

    pub fn cancellation(self: Control) operation_control.CancellationSources {
        return .{ .caller = self.cancel_flag, .runtime = self.lifecycle_cancel_flag };
    }

    /// Reserve half of the remaining startup budget for initialization when an
    /// older stdio server ignores discovery instead of returning method-not-found.
    pub fn discoveryProbeAt(self: Control, now: std.Io.Clock.Timestamp) Control {
        const end = self.deadline orelse return self;
        const remaining = std.math.sub(i96, end.raw.nanoseconds, now.raw.nanoseconds) catch std.math.maxInt(i96);
        if (remaining <= 0) return self;
        var probe = self;
        probe.deadline = .{ .clock = end.clock, .raw = .{ .nanoseconds = now.raw.nanoseconds +| @divFloor(@max(remaining, 0), 2) } };
        return probe;
    }

    /// Existing deadlines belong to the whole connection operation, including fallback.
    pub fn startAt(self: Control, now: std.Io.Clock.Timestamp, timeout_ms: u32) Control {
        if (self.deadline != null) return self;
        var started = self;
        started.deadline = startupDeadline(now, timeout_ms, null);
        return started;
    }
};

pub fn startupTimeout(configured_timeout_ms: u32, override: ?std.Io.Duration) std.Io.Duration {
    return override orelse .{ .nanoseconds = @as(i96, configured_timeout_ms) * std.time.ns_per_ms };
}

pub fn startupDeadline(
    now: std.Io.Clock.Timestamp,
    configured_timeout_ms: u32,
    override: ?std.Io.Duration,
) std.Io.Clock.Timestamp {
    const duration = startupTimeout(configured_timeout_ms, override);
    const nanoseconds = std.math.add(i96, now.raw.nanoseconds, duration.nanoseconds) catch std.math.maxInt(i96);
    return .{ .clock = now.clock, .raw = .{ .nanoseconds = nanoseconds } };
}

test "startup uses configured timeouts and a private override" {
    for ([_]u32{ 250, 2_000, 5_000, 30_000, 60_000 }) |timeout_ms| {
        try std.testing.expectEqual(@as(i64, timeout_ms), startupTimeout(timeout_ms, null).toMilliseconds());
    }
    try std.testing.expectEqual(@as(i64, 2_000), startupTimeout(60_000, .fromSeconds(2)).toMilliseconds());
}

test "fallback and restart cannot extend a started operation" {
    const now = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = 123 * std.time.ns_per_ms } };
    const control = (Control{}).startAt(now, 1_500);
    const later = startupDeadline(now, 1_000, null);
    const fallback = control.startAt(later, 30_000);
    const restart = fallback.startAt(later, 60_000);
    try std.testing.expectEqual(@as(i64, 1_500), now.durationTo(control.deadline.?).raw.toMilliseconds());
    try std.testing.expectEqual(control.deadline.?, fallback.deadline.?);
    try std.testing.expectEqual(control.deadline.?, restart.deadline.?);
}

test "deadline arithmetic saturates without changing the clock" {
    const now = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = std.math.maxInt(i96) - 1 } };
    const deadline = startupDeadline(now, std.math.maxInt(u32), null);
    try std.testing.expectEqual(std.math.maxInt(i96), deadline.raw.nanoseconds);
    try std.testing.expectEqual(now.clock, deadline.clock);
}

test "silent discovery leaves initialization inside the original deadline" {
    const now = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = 0 } };
    const whole = (Control{}).startAt(now, 1_500);
    const probe = whole.discoveryProbeAt(now);
    try std.testing.expectEqual(@as(i64, 750), probe.deadline.?.raw.toMilliseconds());
    try std.testing.expectEqual(@as(i64, 1_500), whole.deadline.?.raw.toMilliseconds());
    const elapsed = startupDeadline(now, 1_000, null);
    try std.testing.expectEqual(@as(i64, 1_250), whole.discoveryProbeAt(elapsed).deadline.?.raw.toMilliseconds());
}
