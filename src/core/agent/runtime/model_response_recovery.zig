const std = @import("std");

pub const default_max_provider_attempts: usize = 10;
pub const max_retry_after_seconds: u64 = 30;
/// Past this much total recovery time, billable retries throttle to once a
/// minute and the UI shows a patient "still trying" state instead of attempt
/// counters. The turn never dies from transient failure.
const billable_retry_window_ns: u64 = 15 * 60 * std.time.ns_per_s;
const throttled_retry_delay_ns: u64 = 60 * std.time.ns_per_s;

pub const FailureCause = enum {
    /// The network path is provably down (connection refused, unreachable,
    /// DNS failure, dead socket after wake). Nothing was or can be sent.
    connectivity_lost,
    transport_interrupted,
    response_interrupted,
    provider_stream_timeout,
    provider_unavailable,
    rate_limited,
    system_resumed,
    compaction_prepared,
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

/// Whether attempts keep making forward progress. A stall (the same failure at
/// the same progress point, repeatedly) is a broken response, not a network
/// problem; retrying it forever is the failure mode budgets used to mask.
pub const Progress = enum {
    unknown,
    advancing,
    stalled,
};

pub const AttemptState = struct {
    consumed: usize,
    limit: usize = default_max_provider_attempts,
};

/// Ephemeral backoff state. AttemptState remains the durable diagnostic budget;
/// exhaustion no longer terminates the turn.
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
        // A zero or missing server hint carries no useful information; a
        // failing endpoint saying "retry instantly" must not disable backoff.
        if (retry_after_seconds != null and retry_after_seconds.? > 0) return .idle;
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
    /// Park the turn and probe connectivity until the path returns. Never
    /// consumes the attempt budget: probes transmit nothing.
    wait_for_connectivity,
    /// Silence is ambiguous (a thinking model and a hung gateway are identical
    /// on the wire). Probe the liveness channel; never retry on silence alone.
    probe_liveness,
    pause,
    stop,
};

pub const RequiredAction = enum {
    none,
    continue_later,
    inspect_uncertain_tool,
    change_request,
    /// The same failure repeated at the same progress point. Surface it as a
    /// broken response instead of restarting forever.
    surface_stall,
};

pub const Evidence = struct {
    cause: FailureCause,
    delivery: Delivery,
    attempts: AttemptState,
    /// Experimental strict budget. Normal recovery remains patient.
    enforce_attempt_limit: bool = false,
    output: OutputEvidence = .none,
    tool: ToolEvidence = .none,
    pacing: RetryPacingState = .idle,
    retry_after_seconds: ?u64 = null,
    cancelled: bool = false,
    progress: Progress = .unknown,
    /// Total wall-clock time spent recovering this turn, when known.
    recovery_elapsed_ns: ?u64 = null,
};

pub const Decision = struct {
    strategy: Strategy,
    delay_ns: u64 = 0,
    next_pacing: RetryPacingState = .idle,
    reserve_provider_attempt: bool = false,
    required_action: RequiredAction = .none,
    /// True once recovery runs longer than the billable window: delays floor at
    /// one minute so billable retransmission throttles without the turn dying.
    throttled: bool = false,

    /// The turn keeps working without asking anyone. Probes and connectivity
    /// waits transmit nothing, so they recover without spending the attempt
    /// budget; ordinary retries reserve one.
    pub fn autoRecovers(self: Decision) bool {
        return self.reserve_provider_attempt or
            self.strategy == .wait_for_connectivity or
            self.strategy == .probe_liveness;
    }
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
        // The provider's own request limit does not recover by retrying within
        // this turn. Stop honestly instead of pausing for a manual /continue.
        .request_limit_reached => return .{
            .strategy = .stop,
            .required_action = .continue_later,
        },
        else => {},
    }

    // Connectivity loss waits indefinitely; probes transmit nothing, so there
    // is nothing to budget and nothing to bill. The cadence ramps 1s, 2s, then
    // a 5s cap so a down network is polled gently, not hammered.
    if (evidence.cause == .connectivity_lost) {
        const next_pacing = evidence.pacing.afterFailure(.connectivity_lost, null);
        const probe_attempt = switch (next_pacing) {
            .idle => 1,
            .implicit => |pacing| pacing.attempt,
        };
        return .{
            .strategy = .wait_for_connectivity,
            .delay_ns = connectivityProbeDelayNs(probe_attempt),
            .next_pacing = next_pacing,
            .required_action = .none,
        };
    }

    // A stalled exchange (identical failure, identical progress, repeatedly) is
    // a broken response, not a flaky network. Stop instead of restarting the
    // same failure forever. Scoped to stream evidence: bare status failures
    // (5xx) carry no progress information and keep retrying patiently. Checked
    // before the silence probe: repeated hangs at the same byte offset are not
    // ambiguous, so probing them forever would defeat the stall detector.
    if (evidence.progress == .stalled) {
        return .{
            .strategy = .stop,
            .required_action = .surface_stall,
        };
    }

    // Silence is never a retry trigger. Probe the liveness channel first, on a
    // paced cadence so a provider that always times out cannot hot-loop.
    if (evidence.cause == .provider_stream_timeout) {
        const next_pacing = evidence.pacing.afterFailure(.provider_stream_timeout, null);
        const probe_attempt = switch (next_pacing) {
            .idle => 1,
            .implicit => |pacing| pacing.attempt,
        };
        return .{
            .strategy = .probe_liveness,
            .delay_ns = retryDelayNs(probe_attempt),
            .next_pacing = next_pacing,
            .required_action = if (evidence.tool == .uncertain)
                .inspect_uncertain_tool
            else
                .none,
        };
    }

    if (evidence.enforce_attempt_limit and evidence.attempts.consumed >= @max(1, evidence.attempts.limit)) {
        return .{
            .strategy = .pause,
            .required_action = if (evidence.tool == .uncertain) .inspect_uncertain_tool else .continue_later,
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
    const throttled = evidence.recovery_elapsed_ns orelse 0 > billable_retry_window_ns;
    // A positive server hint bounds the wait from below, but never below the
    // throttled floor: a misbehaving endpoint retrying "in 1s" forever must
    // not defeat the billable-spend throttle.
    const delay_ns = if (evidence.retry_after_seconds) |seconds| blk: {
        if (seconds == 0) break :blk switch (next_pacing) {
            .idle => unreachable,
            .implicit => |pacing| retryDelayNs(pacing.attempt),
        };
        const bounded_seconds: u64 = @min(seconds, max_retry_after_seconds);
        const hinted_ns = bounded_seconds * std.time.ns_per_s;
        break :blk if (throttled) @max(hinted_ns, throttled_retry_delay_ns) else hinted_ns;
    } else if (throttled)
        throttled_retry_delay_ns
    else switch (next_pacing) {
        .idle => unreachable,
        .implicit => |pacing| retryDelayNs(pacing.attempt),
    };
    return .{
        .strategy = strategy,
        .delay_ns = delay_ns,
        .next_pacing = next_pacing,
        .reserve_provider_attempt = true,
        .throttled = throttled,
    };
}

test "adaptive retry strict budget pauses while control remains patient" {
    var evidence: Evidence = .{
        .cause = .provider_unavailable,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 3, .limit = 3 },
    };
    try std.testing.expect(decide(evidence).reserve_provider_attempt);
    evidence.enforce_attempt_limit = true;
    try std.testing.expectEqual(Strategy.pause, decide(evidence).strategy);
    try std.testing.expect(!decide(evidence).reserve_provider_attempt);
    try std.testing.expectEqual(RequiredAction.continue_later, decide(evidence).required_action);
    evidence.tool = .uncertain;
    try std.testing.expectEqual(RequiredAction.inspect_uncertain_tool, decide(evidence).required_action);
    evidence.cause = .connectivity_lost;
    try std.testing.expectEqual(Strategy.wait_for_connectivity, decide(evidence).strategy);
}

/// Connectivity probe cadence after `attempt` consecutive connectivity
/// failures: 1 s, 2 s, then 5 s flat. Probes transmit nothing, so the cadence
/// exists to keep the UI calm and the loop cheap, not to protect a provider.
fn connectivityProbeDelayNs(attempt: usize) u64 {
    if (attempt <= 1) return std.time.ns_per_s;
    if (attempt == 2) return 2 * std.time.ns_per_s;
    return 5 * std.time.ns_per_s;
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

test "fast fallback is limited to replay safe provider outages" {
    try std.testing.expect(shouldDisableFastRoute(true, .provider_unavailable, true));
    try std.testing.expect(!shouldDisableFastRoute(false, .provider_unavailable, true));
    try std.testing.expect(!shouldDisableFastRoute(true, .provider_unavailable, false));
    try std.testing.expect(!shouldDisableFastRoute(true, .rate_limited, true));
    try std.testing.expect(!shouldDisableFastRoute(true, .transport_interrupted, true));
}

test "model response recovery policy is deterministic and never pauses transient failure" {
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

    // Exhaustion no longer pauses the turn: the strategy keeps retrying with
    // the same pacing discipline.
    var exhausted = base;
    exhausted.attempts.consumed = exhausted.attempts.limit;
    const kept = decide(exhausted);
    try std.testing.expectEqual(Strategy.retry_request, kept.strategy);
    try std.testing.expect(kept.reserve_provider_attempt);

    var request_limit = base;
    request_limit.cause = .request_limit_reached;
    const stopped = decide(request_limit);
    try std.testing.expectEqual(Strategy.stop, stopped.strategy);
    try std.testing.expectEqual(RequiredAction.continue_later, stopped.required_action);
    try std.testing.expect(!stopped.reserve_provider_attempt);
}

test "connectivity loss waits without consuming the attempt budget" {
    const waiting = decide(.{
        .cause = .connectivity_lost,
        .delivery = .definitely_unsent,
        .attempts = .{ .consumed = 3 },
    });
    try std.testing.expectEqual(Strategy.wait_for_connectivity, waiting.strategy);
    try std.testing.expect(!waiting.reserve_provider_attempt);
    try std.testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), waiting.delay_ns);

    const waiting_again = decide(.{
        .cause = .connectivity_lost,
        .delivery = .definitely_unsent,
        .attempts = .{ .consumed = 4 },
        .pacing = waiting.next_pacing,
    });
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), waiting_again.delay_ns);
    const waiting_third = decide(.{
        .cause = .connectivity_lost,
        .delivery = .definitely_unsent,
        .attempts = .{ .consumed = 5 },
        .pacing = waiting_again.next_pacing,
    });
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), waiting_third.delay_ns);
    const waiting_steady = decide(.{
        .cause = .connectivity_lost,
        .delivery = .definitely_unsent,
        .attempts = .{ .consumed = 6 },
        .pacing = waiting_third.next_pacing,
    });
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), waiting_steady.delay_ns);

    // Even an "exhausted" budget still waits: connectivity probes are free.
    const still_waiting = decide(.{
        .cause = .connectivity_lost,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 10 },
    });
    try std.testing.expectEqual(Strategy.wait_for_connectivity, still_waiting.strategy);
}

test "stream timeout probes liveness instead of pausing" {
    const probing = decide(.{
        .cause = .provider_stream_timeout,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 1 },
    });
    try std.testing.expectEqual(Strategy.probe_liveness, probing.strategy);
    try std.testing.expectEqual(RequiredAction.none, probing.required_action);
    try std.testing.expect(!probing.reserve_provider_attempt);
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), probing.delay_ns);

    const probing_again = decide(.{
        .cause = .provider_stream_timeout,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 2 },
        .pacing = probing.next_pacing,
    });
    try std.testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), probing_again.delay_ns);

    const uncertain_tool = decide(.{
        .cause = .provider_stream_timeout,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 1 },
        .tool = .uncertain,
    });
    try std.testing.expectEqual(Strategy.probe_liveness, uncertain_tool.strategy);
    try std.testing.expectEqual(
        RequiredAction.inspect_uncertain_tool,
        uncertain_tool.required_action,
    );

    const cancelled = decide(.{
        .cause = .provider_stream_timeout,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 1 },
        .cancelled = true,
    });
    try std.testing.expectEqual(Strategy.stop, cancelled.strategy);
}

test "stalled progress stops instead of restarting forever" {
    const stalled_evidence = Evidence{
        .cause = .response_interrupted,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 4 },
        .progress = .stalled,
    };
    const stalled = decide(stalled_evidence);
    try std.testing.expectEqual(Strategy.stop, stalled.strategy);
    try std.testing.expectEqual(RequiredAction.surface_stall, stalled.required_action);

    var advancing_evidence = stalled_evidence;
    advancing_evidence.progress = .advancing;
    try std.testing.expectEqual(Strategy.retry_request, decide(advancing_evidence).strategy);

    // A stream that times out repeatedly at the same byte offset is stalled,
    // not merely silent: stop instead of probing liveness forever.
    var stalled_timeout = stalled_evidence;
    stalled_timeout.cause = .provider_stream_timeout;
    const stopped = decide(stalled_timeout);
    try std.testing.expectEqual(Strategy.stop, stopped.strategy);
    try std.testing.expectEqual(RequiredAction.surface_stall, stopped.required_action);
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

    var cancelled_evidence = base;
    cancelled_evidence.cancelled = true;
    try std.testing.expectEqual(Strategy.stop, decide(cancelled_evidence).strategy);
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

test "billable retries throttle past the recovery window without dying" {
    const base = Evidence{
        .cause = .provider_unavailable,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 8 },
    };
    const within_window = decide(base);
    try std.testing.expect(!within_window.throttled);
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), within_window.delay_ns);

    var past_window = base;
    past_window.recovery_elapsed_ns = billable_retry_window_ns + 1;
    const throttled = decide(past_window);
    try std.testing.expect(throttled.throttled);
    try std.testing.expectEqual(throttled_retry_delay_ns, throttled.delay_ns);
    try std.testing.expectEqual(Strategy.retry_request, throttled.strategy);

    // A positive Retry-After hint bounds the wait from below but never below
    // the throttled floor: a misbehaving endpoint saying "in 1s" forever must
    // not pin the turn at 60 billable requests per minute.
    var hinted = past_window;
    hinted.retry_after_seconds = 1;
    const hinted_throttled = decide(hinted);
    try std.testing.expect(hinted_throttled.throttled);
    try std.testing.expectEqual(throttled_retry_delay_ns, hinted_throttled.delay_ns);
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

    // A zero server hint carries no timing information: implicit pacing keeps
    // backing off instead of an instant retry. An endpoint failing with
    // retry-after: 0 must not produce a zero-delay request flood.
    const zero_hinted = decide(.{
        .cause = .provider_unavailable,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 9 },
        .pacing = provider_failure.next_pacing,
        .retry_after_seconds = 0,
    });
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), zero_hinted.delay_ns);
    try std.testing.expect(std.meta.activeTag(zero_hinted.next_pacing) == .implicit);

    const zero_hinted_again = decide(.{
        .cause = .provider_unavailable,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 10 },
        .pacing = zero_hinted.next_pacing,
        .retry_after_seconds = 0,
    });
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), zero_hinted_again.delay_ns);

    // A positive server hint still wins and resets pacing, as before.
    const explicitly_timed = decide(.{
        .cause = .provider_unavailable,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 11 },
        .pacing = zero_hinted_again.next_pacing,
        .retry_after_seconds = 4,
    });
    try std.testing.expectEqual(@as(u64, 4 * std.time.ns_per_s), explicitly_timed.delay_ns);
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

    const past_budget = decide(.{
        .cause = .system_resumed,
        .delivery = .possibly_sent,
        .attempts = .{ .consumed = 10 },
        .output = .partial,
    });
    try std.testing.expectEqual(Strategy.continue_response, past_budget.strategy);
    try std.testing.expect(past_budget.reserve_provider_attempt);
}
