//! When to ping a Claude prompt cache entry so it stays alive while fx waits
//! for the user or for a long tool run. Anthropic keeps an entry for five
//! minutes after the start of the newest request that read or wrote it; a
//! ping resends the last real request with a one-token reply just before
//! then, so the next real request reads the conversation instead of writing
//! it again at the cache-write price.
//!
//! The planner performs no I/O, reads no clock, and never allocates:
//! `cache_warmer.zig` runs its timer and its pings. It imports only the
//! standard library, so `tests/tla/drivers/cache_warming/lab.zig` can build
//! it alone. `tests/tla/cache_warming/CacheWarming.tla` models it.

const std = @import("std");

pub const Timing = struct {
    /// How long the provider keeps an entry after the start of the newest
    /// request that read or wrote it.
    ttl_ms: i64,
    /// No ping starts later than this after the real request that armed
    /// the planner.
    cap_ms: i64,

    /// Anthropic's default cache lifetime, and the cap the session's owner
    /// chose: past 30 minutes, a pause rarely ends before the pings cost
    /// more than the cache write they save.
    pub const claude: Timing = .{ .ttl_ms = 5 * std.time.ms_per_min, .cap_ms = 30 * std.time.ms_per_min };

    /// A ping goes out a tenth of the lifetime before the entry expires.
    pub fn interval(self: Timing) i64 {
        return self.ttl_ms - @divTrunc(self.ttl_ms, 10);
    }

    /// A wake later than this past its planned time, as after the machine
    /// sleeps, leaves too little of the entry's life to trust: the ping
    /// could arrive after expiry and pay for a full write.
    pub fn late(self: Timing) i64 {
        return @divTrunc(self.ttl_ms - self.interval(), 2);
    }
};

/// Why warming stopped.
pub const Stop = enum {
    /// A real request went out, the session changed, or fx is closing.
    disarmed,
    /// The next ping would start past `Timing.cap_ms`.
    cap,
    /// The timer fired too late to trust the entry.
    late,
    /// A ping failed.
    failed,
    /// A ping wrote the entry instead of reading it: the provider evicted
    /// it, or the ping no longer matches the request.
    missed,
};

/// How a ping's answer touched the entry.
pub const Outcome = enum { read, missed, failed };

pub const State = struct {
    armed: bool = false,
    /// Bumped by every arm and disarm, so an answer to a ping sent for an
    /// earlier request is recognized as stale.
    generation: u64 = 0,
    request_started_ms: i64 = 0,
    /// Start of the newest request known to have touched the entry: the
    /// armed request, or the last ping that read it.
    last_touch_ms: i64 = 0,
    /// Pings since the planner was armed.
    pings: u32 = 0,
    /// Generation and start of the ping on the wire.
    in_flight: ?u64 = null,
    in_flight_started_ms: i64 = 0,
    /// Why warming last stopped.
    stopped: ?Stop = null,
};

pub const Event = union(enum) {
    /// A real request completed. It started at `started_ms`; the provider
    /// keeps the entry for the lifetime from then.
    armed: struct { now_ms: i64, started_ms: i64 },
    /// The armed request no longer matches the next one.
    disarmed: struct { now_ms: i64 },
    /// The timer fired.
    woke: struct { now_ms: i64 },
    /// A ping answered.
    answered: struct { now_ms: i64, generation: u64, outcome: Outcome },
};

pub const Plan = union(enum) {
    /// Nothing is armed.
    idle,
    /// Wake at this time.
    wait_until: i64,
    /// A ping is on the wire; wait for its answer.
    wait_for_answer,
    /// Send a ping now for this generation.
    ping: u64,
    /// Warming stopped; the planner is idle until the next arm.
    stopped: Stop,
};

pub fn step(state: *State, timing: Timing, event: Event) Plan {
    switch (event) {
        .armed => |armed| {
            state.generation +%= 1;
            state.armed = true;
            state.request_started_ms = armed.started_ms;
            state.last_touch_ms = armed.started_ms;
            state.pings = 0;
            state.stopped = null;
            // A reply that streamed for most of the lifetime leaves the
            // entry too close to expiry to ping.
            if (armed.now_ms > due(state, timing) + timing.late()) return stop(state, .late);
            return afterTouch(state, timing);
        },
        .disarmed => {
            state.generation +%= 1;
            if (!state.armed) return next(state, timing);
            return stop(state, .disarmed);
        },
        .woke => |woke| {
            if (!state.armed or state.in_flight != null) return next(state, timing);
            const due_ms = due(state, timing);
            if (woke.now_ms < due_ms) return .{ .wait_until = due_ms };
            if (woke.now_ms > due_ms + timing.late()) return stop(state, .late);
            state.in_flight = state.generation;
            state.in_flight_started_ms = woke.now_ms;
            state.pings +|= 1;
            return .{ .ping = state.generation };
        },
        .answered => |answered| {
            if (state.in_flight != answered.generation) return next(state, timing);
            state.in_flight = null;
            // The session moved on while this ping was out: its answer says
            // nothing about the entry the planner holds now.
            if (!state.armed or answered.generation != state.generation) return next(state, timing);
            return switch (answered.outcome) {
                .read => read: {
                    state.last_touch_ms = state.in_flight_started_ms;
                    break :read afterTouch(state, timing);
                },
                .missed => stop(state, .missed),
                .failed => stop(state, .failed),
            };
        },
    }
}

fn due(state: *const State, timing: Timing) i64 {
    return state.last_touch_ms + timing.interval();
}

/// After the entry was touched, plan the next ping, unless it would start
/// past the cap (`tests/tla/cache_warming/CacheWarming.tla` PastCap).
fn afterTouch(state: *State, timing: Timing) Plan {
    if (due(state, timing) > state.request_started_ms + timing.cap_ms) return stop(state, .cap);
    return next(state, timing);
}

fn next(state: *const State, timing: Timing) Plan {
    if (state.in_flight != null) return .wait_for_answer;
    if (!state.armed) return .idle;
    return .{ .wait_until = due(state, timing) };
}

fn stop(state: *State, reason: Stop) Plan {
    state.armed = false;
    state.stopped = reason;
    return .{ .stopped = reason };
}

/// What the agent loop knows about a request it might keep warm.
pub const Candidate = struct {
    /// The request went through AI Gateway with fx's own credential.
    gateway_with_direct_credential: bool,
    model: []const u8,
    /// The request was a root turn's, not a subagent's.
    root_turn: bool,
    prompt_caching: bool,
    /// The request carried a reasoning effort.
    reasoning: bool,
    /// The model's catalog entry lists effort levels.
    model_has_efforts: bool,
};

pub const Skip = enum { not_claude, not_gateway, subagent, no_prompt_caching, budget_thinking };

/// Why a request is not kept warm, or null when it is. Claude models with
/// only budget-based thinking derive the thinking budget apart from the
/// reply limit, so a one-token ping could still think for thousands of
/// tokens; models that list effort levels think adaptively and stop at the
/// limit.
pub fn skipReason(candidate: Candidate) ?Skip {
    if (!std.mem.startsWith(u8, candidate.model, "anthropic/")) return .not_claude;
    if (!candidate.gateway_with_direct_credential) return .not_gateway;
    if (!candidate.root_turn) return .subagent;
    if (!candidate.prompt_caching) return .no_prompt_caching;
    if (candidate.reasoning and !candidate.model_has_efforts) return .budget_thinking;
    return null;
}

const testing = std.testing;
const claude = Timing.claude;
const min = std.time.ms_per_min;

test "the five-minute lifetime pings at 4.5 minutes and trusts a wake up to 15 seconds late" {
    try testing.expectEqual(@as(i64, 270_000), claude.interval());
    try testing.expectEqual(@as(i64, 15_000), claude.late());
}

test "an armed request is pinged six times, then warming stops at the 30-minute cap" {
    var state: State = .{};
    try testing.expectEqual(Plan{ .wait_until = 270_000 }, step(&state, claude, .{ .armed = .{ .now_ms = 2_000, .started_ms = 0 } }));
    var pinged: u32 = 0;
    var now: i64 = 270_000;
    while (true) : (now += claude.interval()) {
        const plan = step(&state, claude, .{ .woke = .{ .now_ms = now } });
        try testing.expectEqual(Plan{ .ping = state.generation }, plan);
        pinged += 1;
        const after = step(&state, claude, .{ .answered = .{ .now_ms = now + 800, .generation = state.generation, .outcome = .read } });
        if (after == .stopped) {
            try testing.expectEqual(Stop.cap, after.stopped);
            break;
        }
        try testing.expectEqual(Plan{ .wait_until = now + claude.interval() }, after);
    }
    try testing.expectEqual(@as(u32, 6), pinged);
    // The last ping went out at 27 minutes; the next would start past 30.
    try testing.expectEqual(@as(i64, 27 * min), now);
    try testing.expect(!state.armed);
}

test "a wake after the machine slept past the margin stops instead of paying a write" {
    var state: State = .{};
    _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
    try testing.expectEqual(Plan{ .ping = state.generation }, step(&state, claude, .{ .woke = .{ .now_ms = 285_000 } }));
    _ = step(&state, claude, .{ .answered = .{ .now_ms = 286_000, .generation = state.generation, .outcome = .read } });
    try testing.expectEqual(Plan{ .stopped = .late }, step(&state, claude, .{ .woke = .{ .now_ms = 285_000 + 270_000 + 15_001 } }));
}

test "an early wake waits for the planned time" {
    var state: State = .{};
    _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
    try testing.expectEqual(Plan{ .wait_until = 270_000 }, step(&state, claude, .{ .woke = .{ .now_ms = 100_000 } }));
}

test "a reply that streamed past the margin is not armed" {
    var state: State = .{};
    try testing.expectEqual(Plan{ .stopped = .late }, step(&state, claude, .{ .armed = .{ .now_ms = 285_001, .started_ms = 0 } }));
    var close: State = .{};
    try testing.expectEqual(Plan{ .wait_until = 270_000 }, step(&close, claude, .{ .armed = .{ .now_ms = 285_000, .started_ms = 0 } }));
}

test "a disarm ends warming and makes the ping on the wire stale" {
    var state: State = .{};
    _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
    const generation = step(&state, claude, .{ .woke = .{ .now_ms = 270_000 } }).ping;
    try testing.expectEqual(Plan{ .stopped = .disarmed }, step(&state, claude, .{ .disarmed = .{ .now_ms = 270_100 } }));
    // A real request armed the planner again before the old ping answered.
    try testing.expectEqual(Plan.wait_for_answer, step(&state, claude, .{ .armed = .{ .now_ms = 272_000, .started_ms = 270_100 } }));
    // The old ping's failure does not stop the new arm
    // (`tests/tla/cache_warming/CacheWarming.tla` NoStaleStop).
    try testing.expectEqual(Plan{ .wait_until = 270_100 + 270_000 }, step(&state, claude, .{ .answered = .{ .now_ms = 272_500, .generation = generation, .outcome = .failed } }));
    try testing.expect(state.armed);
    try testing.expectEqual(@as(?u64, null), state.in_flight);
}

test "a failed or missed ping stops warming" {
    inline for (.{ .{ Outcome.failed, Stop.failed }, .{ Outcome.missed, Stop.missed } }) |case| {
        var state: State = .{};
        _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
        const generation = step(&state, claude, .{ .woke = .{ .now_ms = 270_000 } }).ping;
        try testing.expectEqual(Plan{ .stopped = case[1] }, step(&state, claude, .{ .answered = .{ .now_ms = 271_000, .generation = generation, .outcome = case[0] } }));
        try testing.expect(!state.armed);
    }
}

test "the timer never starts a second ping while one is on the wire" {
    var state: State = .{};
    _ = step(&state, claude, .{ .armed = .{ .now_ms = 1_000, .started_ms = 0 } });
    _ = step(&state, claude, .{ .woke = .{ .now_ms = 270_000 } });
    try testing.expectEqual(Plan.wait_for_answer, step(&state, claude, .{ .woke = .{ .now_ms = 271_000 } }));
    try testing.expectEqual(@as(u32, 1), state.pings);
}

test "nothing pings without an arm" {
    var state: State = .{};
    try testing.expectEqual(Plan.idle, step(&state, claude, .{ .woke = .{ .now_ms = 270_000 } }));
    try testing.expectEqual(Plan.idle, step(&state, claude, .{ .disarmed = .{ .now_ms = 270_000 } }));
}

test "only Claude requests through AI Gateway with fx's credential are kept warm" {
    const base: Candidate = .{
        .gateway_with_direct_credential = true,
        .model = "anthropic/claude-opus-5.5",
        .root_turn = true,
        .prompt_caching = true,
        .reasoning = true,
        .model_has_efforts = true,
    };
    try testing.expectEqual(@as(?Skip, null), skipReason(base));
    var other = base;
    other.model = "openai/gpt-6.1";
    try testing.expectEqual(@as(?Skip, .not_claude), skipReason(other));
    other = base;
    other.gateway_with_direct_credential = false;
    try testing.expectEqual(@as(?Skip, .not_gateway), skipReason(other));
    other = base;
    other.root_turn = false;
    try testing.expectEqual(@as(?Skip, .subagent), skipReason(other));
    other = base;
    other.prompt_caching = false;
    try testing.expectEqual(@as(?Skip, .no_prompt_caching), skipReason(other));
    // Budget-only thinking (Claude Sonnet 4.5) leaks thinking past a one-token reply.
    other = base;
    other.model_has_efforts = false;
    try testing.expectEqual(@as(?Skip, .budget_thinking), skipReason(other));
    other.reasoning = false;
    try testing.expectEqual(@as(?Skip, null), skipReason(other));
}
