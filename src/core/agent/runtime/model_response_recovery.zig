const std = @import("std");

pub const default_max_provider_attempts: usize = 10;
pub const max_retry_after_seconds: u64 = 30;

pub const FailureCause = enum {
    transport_interrupted,
    response_interrupted,
    provider_stream_timeout,
    provider_unavailable,
    rate_limited,
    system_resumed,
    authentication,
    request_limit_reached,
    content_filter,
};

pub const Delivery = enum {
    definitely_unsent,
    possibly_sent,
};

pub const OutputEvidence = enum {
    none,
    partial,
};

pub const ToolEvidence = enum {
    none,
    proven_unexecuted,
    confirmed,
    uncertain,
};

pub const AttemptState = struct {
    consumed: usize,
    limit: usize = default_max_provider_attempts,

    pub fn remaining(self: AttemptState) usize {
        return self.limit -| self.consumed;
    }
};

/// Ephemeral backoff state. AttemptState remains the durable request budget.
pub const RetryPacingState = union(enum) {
    idle,
    implicit: struct {
        cause: FailureCause,
        attempt: usize,
    },

    fn afterFailure(
        self: RetryPacingState,
        cause: FailureCause,
        retry_after_seconds: ?u64,
    ) RetryPacingState {
        if (retry_after_seconds != null) return .idle;
        return switch (self) {
            .idle => .{ .implicit = .{ .cause = cause, .attempt = 1 } },
            .implicit => |previous| if (previous.cause == cause)
                .{ .implicit = .{
                    .cause = cause,
                    .attempt = previous.attempt +| 1,
                } }
            else
                .{ .implicit = .{ .cause = cause, .attempt = 1 } },
        };
    }
};

pub const Strategy = enum {
    retry_request,
    continue_response,
    regenerate_tool,
    continue_after_confirmed_tool,
    reconcile_tool,
    pause,
    stop,
};

pub const RequiredAction = enum {
    none,
    continue_later,
    inspect_uncertain_tool,
    change_request,
};

pub const Evidence = struct {
    cause: FailureCause,
    delivery: Delivery,
    attempts: AttemptState,
    output: OutputEvidence = .none,
    tool: ToolEvidence = .none,
    pacing: RetryPacingState = .idle,
    retry_after_seconds: ?u64 = null,
    cancelled: bool = false,
};

pub const Decision = struct {
    strategy: Strategy,
    delay_ns: u64 = 0,
    next_pacing: RetryPacingState = .idle,
    reserve_provider_attempt: bool = false,
    required_action: RequiredAction = .none,
};

/// Pure model-response policy. It describes the next effect but never sleeps,
/// sends, mutates stream state, or persists a checkpoint.
pub noinline fn decide(evidence: Evidence) Decision {
    if (evidence.cancelled) return .{ .strategy = .stop };

    switch (evidence.cause) {
        .content_filter => return .{
            .strategy = .stop,
            .required_action = .change_request,
        },
        .provider_stream_timeout => return .{
            .strategy = .pause,
            .required_action = if (evidence.tool == .uncertain)
                .inspect_uncertain_tool
            else
                .continue_later,
        },
        .request_limit_reached => return .{
            .strategy = .pause,
            .required_action = .continue_later,
        },
        else => {},
    }

    if (evidence.attempts.remaining() == 0) {
        return .{
            .strategy = .pause,
            .required_action = if (evidence.tool == .uncertain)
                .inspect_uncertain_tool
            else
                .continue_later,
        };
    }

    const strategy: Strategy = if (evidence.delivery == .definitely_unsent)
        .retry_request
    else switch (evidence.tool) {
        .proven_unexecuted => .regenerate_tool,
        .confirmed => .continue_after_confirmed_tool,
        .uncertain => .reconcile_tool,
        .none => if (evidence.output == .partial)
            .continue_response
        else
            .retry_request,
    };
    const next_pacing = evidence.pacing.afterFailure(
        evidence.cause,
        evidence.retry_after_seconds,
    );
    const delay_ns = if (evidence.retry_after_seconds) |seconds| blk: {
        const bounded_seconds: u64 = @min(seconds, max_retry_after_seconds);
        break :blk bounded_seconds * std.time.ns_per_s;
    } else switch (next_pacing) {
        .idle => unreachable,
        .implicit => |pacing| retryDelayNs(pacing.attempt),
    };
    return .{
        .strategy = strategy,
        .delay_ns = delay_ns,
        .next_pacing = next_pacing,
        .reserve_provider_attempt = true,
    };
}

/// Delay before the next provider request after `attempt` consecutive implicit
/// backoffs: 250 ms,
/// 1 s, then exponential growth capped at 30 s.
pub fn retryDelayNs(attempt: usize) u64 {
    if (attempt == 0) return 0;
    if (attempt == 1) return 250 * std.time.ns_per_ms;

    var seconds: u64 = 1;
    var current: usize = 2;
    while (current < attempt and seconds < max_retry_after_seconds) : (current += 1) {
        seconds = @min(seconds * 2, max_retry_after_seconds);
    }
    return seconds * std.time.ns_per_s;
}

/// Fast is an optimization, not a recovery requirement. A replay-safe
/// provider outage may fall back to the canonical route without changing the
/// semantic request budget.
pub fn shouldDisableFastRoute(
    fast_mode: bool,
    cause: FailureCause,
    replay_safe: bool,
) bool {
    return fast_mode and cause == .provider_unavailable and replay_safe;
}

test "model response recovery policy is deterministic and bounded" {
    const base = Evidence{
        .cause = .transport_interrupted,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 1 },
    };
    const first = decide(base);
    try std.testing.expectEqual(first, decide(base));
    try std.testing.expectEqual(Strategy.retry_request, first.strategy);
    try std.testing.expect(first.reserve_provider_attempt);
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), first.delay_ns);

    var partial = base;
    partial.output = .partial;
    try std.testing.expectEqual(Strategy.continue_response, decide(partial).strategy);

    var unexecuted = partial;
    unexecuted.tool = .proven_unexecuted;
    try std.testing.expectEqual(Strategy.regenerate_tool, decide(unexecuted).strategy);

    var uncertain = partial;
    uncertain.tool = .uncertain;
    try std.testing.expectEqual(Strategy.reconcile_tool, decide(uncertain).strategy);

    var definitely_unsent = uncertain;
    definitely_unsent.delivery = .definitely_unsent;
    try std.testing.expectEqual(Strategy.retry_request, decide(definitely_unsent).strategy);

    var exhausted = base;
    exhausted.attempts.consumed = exhausted.attempts.limit;
    const paused = decide(exhausted);
    try std.testing.expectEqual(Strategy.pause, paused.strategy);
    try std.testing.expect(!paused.reserve_provider_attempt);

    var request_limit = base;
    request_limit.cause = .request_limit_reached;
    const request_limit_pause = decide(request_limit);
    try std.testing.expectEqual(Strategy.pause, request_limit_pause.strategy);
    try std.testing.expect(!request_limit_pause.reserve_provider_attempt);
}

test "gateway stream timeout pauses without reserving another attempt" {
    const paused = decide(.{
        .cause = .provider_stream_timeout,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 1 },
    });
    try std.testing.expectEqual(Strategy.pause, paused.strategy);
    try std.testing.expectEqual(RequiredAction.continue_later, paused.required_action);
    try std.testing.expect(!paused.reserve_provider_attempt);
    try std.testing.expectEqual(@as(u64, 0), paused.delay_ns);

    const uncertain_tool = decide(.{
        .cause = .provider_stream_timeout,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 1 },
        .tool = .uncertain,
    });
    try std.testing.expectEqual(Strategy.pause, uncertain_tool.strategy);
    try std.testing.expectEqual(
        RequiredAction.inspect_uncertain_tool,
        uncertain_tool.required_action,
    );
    try std.testing.expect(!uncertain_tool.reserve_provider_attempt);

    const cancelled = decide(.{
        .cause = .provider_stream_timeout,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 1 },
        .cancelled = true,
    });
    try std.testing.expectEqual(Strategy.stop, cancelled.strategy);
}

test "retry after and cancellation override automatic recovery" {
    const base = Evidence{
        .cause = .rate_limited,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 3 },
    };

    var bounded = base;
    bounded.retry_after_seconds = 30;
    const wait = decide(bounded);
    try std.testing.expectEqual(Strategy.retry_request, wait.strategy);
    try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), wait.delay_ns);

    var over_cap = base;
    over_cap.retry_after_seconds = 31;
    const capped = decide(over_cap);
    try std.testing.expectEqual(Strategy.retry_request, capped.strategy);
    try std.testing.expectEqual(
        @as(u64, max_retry_after_seconds * std.time.ns_per_s),
        capped.delay_ns,
    );
    try std.testing.expect(capped.reserve_provider_attempt);

    var overflow = base;
    overflow.retry_after_seconds = std.math.maxInt(u64);
    const overflow_capped = decide(overflow);
    try std.testing.expectEqual(Strategy.retry_request, overflow_capped.strategy);
    try std.testing.expectEqual(
        @as(u64, max_retry_after_seconds * std.time.ns_per_s),
        overflow_capped.delay_ns,
    );
    try std.testing.expect(overflow_capped.reserve_provider_attempt);

    var cancelled = base;
    cancelled.cancelled = true;
    try std.testing.expectEqual(Strategy.stop, decide(cancelled).strategy);
}

test "retry schedule uses the approved cap" {
    const expected = [_]u64{
        250 * std.time.ns_per_ms,
        1 * std.time.ns_per_s,
        2 * std.time.ns_per_s,
        4 * std.time.ns_per_s,
        8 * std.time.ns_per_s,
        16 * std.time.ns_per_s,
        30 * std.time.ns_per_s,
        30 * std.time.ns_per_s,
        30 * std.time.ns_per_s,
    };
    var total: u64 = 0;
    for (expected, 1..) |delay, attempt| {
        try std.testing.expectEqual(delay, retryDelayNs(attempt));
        total += delay;
    }
    try std.testing.expectEqual(
        @as(u64, 121_250 * std.time.ns_per_ms),
        total,
    );
}

test "implicit retry pacing is independent from the shared attempt budget" {
    const first_network = decide(.{
        .cause = .transport_interrupted,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 6 },
    });

    try std.testing.expectEqual(Strategy.retry_request, first_network.strategy);
    try std.testing.expectEqual(
        @as(u64, 250 * std.time.ns_per_ms),
        first_network.delay_ns,
    );

    const second_network = decide(.{
        .cause = .transport_interrupted,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 7 },
        .pacing = first_network.next_pacing,
    });
    try std.testing.expectEqual(
        @as(u64, std.time.ns_per_s),
        second_network.delay_ns,
    );

    const provider_failure = decide(.{
        .cause = .provider_unavailable,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 8 },
        .pacing = second_network.next_pacing,
    });
    try std.testing.expectEqual(
        @as(u64, 250 * std.time.ns_per_ms),
        provider_failure.delay_ns,
    );

    const explicitly_timed = decide(.{
        .cause = .provider_unavailable,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 9 },
        .pacing = provider_failure.next_pacing,
        .retry_after_seconds = 0,
    });
    try std.testing.expectEqual(@as(u64, 0), explicitly_timed.delay_ns);
    try std.testing.expectEqual(RetryPacingState.idle, explicitly_timed.next_pacing);
}

test "system resume strategy uses independent retry pacing" {
    const retrying = decide(.{
        .cause = .system_resumed,
        .delivery = .definitely_unsent,
        .attempts = .{ .consumed = 4 },
    });
    try std.testing.expectEqual(Strategy.retry_request, retrying.strategy);
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), retrying.delay_ns);
    try std.testing.expect(retrying.reserve_provider_attempt);

    const continuing = decide(.{
        .cause = .system_resumed,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 4 },
        .output = .partial,
    });
    try std.testing.expectEqual(Strategy.continue_response, continuing.strategy);
    try std.testing.expect(continuing.reserve_provider_attempt);

    const exhausted = decide(.{
        .cause = .system_resumed,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 10 },
    });
    try std.testing.expectEqual(Strategy.pause, exhausted.strategy);
}

test "fast fallback is limited to replay safe provider outages" {
    try std.testing.expect(shouldDisableFastRoute(true, .provider_unavailable, true));
    try std.testing.expect(!shouldDisableFastRoute(false, .provider_unavailable, true));
    try std.testing.expect(!shouldDisableFastRoute(true, .provider_unavailable, false));
    try std.testing.expect(!shouldDisableFastRoute(true, .rate_limited, true));
    try std.testing.expect(!shouldDisableFastRoute(true, .transport_interrupted, true));
}
