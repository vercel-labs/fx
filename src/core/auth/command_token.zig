//! Plans the token requests of one command-auth connection: send the held
//! token, join or start a helper run, deliver a printed token, fail, or stop
//! a run. Each function is one action of tests/tla/configured_provider/
//! ConfiguredAuth.tla (design "b") for a single connection. Pure: no I/O,
//! no clock, no allocation.

const std = @import("std");

/// Token generation. 1 is the first token a helper prints.
pub const Gen = u32;

pub const Reason = enum { helper };

pub const max_waiters: u16 = 1024;

pub const State = struct {
    /// 0 means no token is held.
    cached: Gen = 0,
    cached_expired: bool = false,
    running: bool = false,
    waiters: u16 = 0,
    newest: Gen = 0,
};

pub const Plan = union(enum) {
    /// Send now with this token.
    send: Gen,
    /// Join the run already in flight.
    wait,
    /// Start a helper run, then wait on it.
    start_and_wait,
    /// Give this token to every waiting request.
    deliver: Gen,
    /// End every waiting request with this reason.
    fail_waiters: Reason,
    /// End the calling request.
    fail: Reason,
    /// Stop the helper: nobody waits on it.
    stop_run,
    none,
};

/// ConfiguredAuth.tla Begin and Replay.
pub fn need(state: *State) Plan {
    if (state.cached != 0 and !state.cached_expired) return .{ .send = state.cached };
    return joinOrStart(state);
}

/// ConfiguredAuth.tla HelperPrints.
pub fn printed(state: *State) Plan {
    if (!state.running) return .none;
    state.newest += 1;
    state.cached = state.newest;
    state.cached_expired = false;
    state.running = false;
    state.waiters = 0;
    return .{ .deliver = state.newest };
}

/// ConfiguredAuth.tla HelperFails and Deadline.
pub fn runEnded(state: *State) Plan {
    if (!state.running) return .none;
    state.running = false;
    state.waiters = 0;
    return .{ .fail_waiters = .helper };
}

/// ConfiguredAuth.tla Reject's cache step. The transport calls it on every
/// 401; the one replay is decided by `auth_transition.decideAuthReplay`, and
/// the replay asks for a token with `need`, as a new request does.
pub fn refused(state: *State, sent: Gen) void {
    if (sent != 0 and state.cached == sent) {
        state.cached = 0;
        state.cached_expired = false;
    }
}

/// ConfiguredAuth.tla Expire. Gen 0 means no token, so it never marks one.
pub fn expired(state: *State, gen: Gen) void {
    if (gen != 0 and state.cached == gen) state.cached_expired = true;
}

/// ConfiguredAuth.tla Cancel. `was_waiting` is false when the request had
/// already sent its token, so it held no place in a run.
pub fn cancelled(state: *State, was_waiting: bool) Plan {
    if (!was_waiting) return .none;
    if (state.waiters > 0) state.waiters -= 1;
    if (state.waiters == 0 and state.running) {
        state.running = false;
        return .stop_run;
    }
    return .none;
}

fn joinOrStart(state: *State) Plan {
    if (state.waiters == max_waiters) return .{ .fail = .helper };
    state.waiters += 1;
    if (state.running) return .wait;
    state.running = true;
    return .start_and_wait;
}

test "the first request starts one helper run and a second request joins it" {
    var state: State = .{};
    try std.testing.expectEqual(Plan.start_and_wait, need(&state));
    try std.testing.expectEqual(Plan.wait, need(&state));
    try std.testing.expectEqual(2, state.waiters);
    try std.testing.expect(state.running);
}

test "printed delivers generation one and the next request sends it without a run" {
    var state: State = .{};
    _ = need(&state);
    _ = need(&state);
    try std.testing.expectEqual(Plan{ .deliver = 1 }, printed(&state));
    try std.testing.expectEqual(1, state.cached);
    try std.testing.expect(!state.running);
    try std.testing.expectEqual(0, state.waiters);
    try std.testing.expectEqual(Plan{ .send = 1 }, need(&state));
    try std.testing.expect(!state.running);
}

test "a held token that expired is not sent and a request starts a run" {
    var state: State = .{};
    _ = need(&state);
    _ = printed(&state);
    expired(&state, 2);
    try std.testing.expect(!state.cached_expired);
    expired(&state, 1);
    try std.testing.expectEqual(Plan.start_and_wait, need(&state));
    try std.testing.expect(state.running);
}

test "expiring generation zero never marks an empty cache" {
    var state: State = .{};
    expired(&state, 0);
    try std.testing.expect(!state.cached_expired);
}

test "a failed helper run fails every waiter with helper and leaves no run" {
    var state: State = .{};
    _ = need(&state);
    _ = need(&state);
    try std.testing.expectEqual(Plan{ .fail_waiters = .helper }, runEnded(&state));
    try std.testing.expect(!state.running);
    try std.testing.expectEqual(0, state.waiters);
}

test "refused drops the cached token and the next need starts a run" {
    var state: State = .{};
    _ = need(&state);
    _ = printed(&state);
    refused(&state, 1);
    try std.testing.expectEqual(0, state.cached);
    try std.testing.expect(!state.cached_expired);
    try std.testing.expectEqual(Plan.start_and_wait, need(&state));
    try std.testing.expect(state.running);
}

test "refused for an older generation keeps the newer cached token and need sends it" {
    var state: State = .{};
    _ = need(&state);
    _ = printed(&state);
    expired(&state, 1);
    _ = need(&state);
    _ = printed(&state);
    refused(&state, 1);
    try std.testing.expectEqual(2, state.cached);
    try std.testing.expect(!state.cached_expired);
    try std.testing.expect(!state.running);
    try std.testing.expectEqual(Plan{ .send = 2 }, need(&state));
    try std.testing.expect(!state.running);
}

test "refused with generation zero or an empty cache changes nothing" {
    var empty: State = .{};
    refused(&empty, 0);
    refused(&empty, 1);
    try std.testing.expectEqual(State{}, empty);

    var cached: State = .{ .cached = 1, .cached_expired = true, .newest = 1 };
    refused(&cached, 0);
    try std.testing.expectEqual(State{ .cached = 1, .cached_expired = true, .newest = 1 }, cached);
}

test "cancelling the last waiter stops the run and cancelling one of two keeps it" {
    var one: State = .{};
    _ = need(&one);
    try std.testing.expectEqual(Plan.stop_run, cancelled(&one, true));
    try std.testing.expect(!one.running);
    try std.testing.expectEqual(0, one.waiters);

    var two: State = .{};
    _ = need(&two);
    _ = need(&two);
    try std.testing.expectEqual(Plan.none, cancelled(&two, true));
    try std.testing.expect(two.running);
    try std.testing.expectEqual(1, two.waiters);
    try std.testing.expectEqual(Plan.stop_run, cancelled(&two, true));
}

test "cancelling a request that already sent its token changes nothing" {
    var state: State = .{ .running = true, .waiters = 1 };
    try std.testing.expectEqual(Plan.none, cancelled(&state, false));
    try std.testing.expect(state.running);
    try std.testing.expectEqual(1, state.waiters);
}

test "the request past the waiter cap fails with helper" {
    var state: State = .{ .waiters = max_waiters, .running = true };
    try std.testing.expectEqual(Plan{ .fail = .helper }, need(&state));
    try std.testing.expectEqual(max_waiters, state.waiters);
}

test "printed and runEnded with no run in flight change nothing" {
    var state: State = .{ .cached = 3, .newest = 3 };
    try std.testing.expectEqual(Plan.none, printed(&state));
    try std.testing.expectEqual(Plan.none, runEnded(&state));
    try std.testing.expectEqual(State{ .cached = 3, .newest = 3 }, state);
}
