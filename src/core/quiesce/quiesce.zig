//! When a running turn stops for its host.
//!
//! fx reports each save of a running turn between steps through `step`, and
//! `step` answers `.proceed` or `.yield`. The turn then sends its model
//! request or stops there. The module decides and fx acts.
//!
//! A turn yields only at the save right before a model request, and only after
//! the prompt has sent its first request, so every prompt makes progress
//! however late it starts. A compaction or a paused retry finishes where it
//! is.
//!
//! The libfx journal stops a durable turn at its host's time (`yieldAt`); the
//! TUI stops every turn for an upgrade's restart (Ctrl+G).
//!
//! The module performs no I/O, reads no clock, starts no thread, keeps no
//! global state, and never allocates, so the same events always produce the
//! same decisions. `tests/tla/recovery/Resume.tla` models the relaunch
//! (actions Upgrade and Relaunch).
//!
//! Outside code imports only this file, and this file imports only `std`.

const std = @import("std");

/// One prompt's state. Starts at `.{}`; `step(.start)` resets it.
pub const State = struct {
    /// When the host wants the turn to stop, in milliseconds since the
    /// epoch; null when it gave no time.
    stop_at_ms: ?i64 = null,
    /// The prompt has sent a model request.
    sent: bool = false,
};

/// What fx reports.
pub const Event = union(enum) {
    /// A prompt starts.
    start: Start,
    /// The turn saved itself between steps.
    boundary: Boundary,
};

pub const Start = struct {
    stop_at_ms: ?i64 = null,
};

pub const Boundary = struct {
    /// The wall clock now, in milliseconds since the epoch. fx reads it;
    /// the module never does.
    now_ms: i64,
    /// The host asked the turn to stop at its next boundary, as Ctrl+G does.
    stop_requested: bool = false,
    kind: Kind = .request,

    pub const Kind = enum {
        /// The save right before a model request goes out.
        request,
        /// The save before a compaction summarizes, or before a request
        /// that resumes one.
        compaction,
        /// Any other save, such as the one a paused retry makes before it
        /// waits.
        other,
    };
};

pub const Decision = enum { proceed, yield };

/// The one entry point. The caller passes the wall clock in the boundary;
/// the module never reads it.
pub fn step(state: *State, event: Event) Decision {
    return switch (event) {
        .start => |start| onStart(state, start),
        .boundary => |boundary| onBoundary(state, boundary),
    };
}

fn onStart(state: *State, start: Start) Decision {
    state.* = .{ .stop_at_ms = start.stop_at_ms };
    return .proceed;
}

fn onBoundary(state: *State, boundary: Boundary) Decision {
    switch (boundary.kind) {
        // A compaction or a paused retry finishes where it is.
        .compaction, .other => return .proceed,
        .request => {},
    }
    // The prompt's first request always goes out.
    if (!state.sent) {
        state.sent = true;
        return .proceed;
    }
    if (boundary.stop_requested) return .yield;
    if (state.stop_at_ms) |stop_at_ms| {
        if (boundary.now_ms >= stop_at_ms) return .yield;
    }
    return .proceed;
}

test "the first request of a prompt always goes out" {
    var state: State = .{};
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .start = .{ .stop_at_ms = 0 } }));
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 100, .stop_requested = true } }));
    try std.testing.expectEqual(Decision.yield, step(&state, .{ .boundary = .{ .now_ms = 100, .stop_requested = true } }));
}

test "a stop request yields at the next request after the first" {
    var state: State = .{};
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .start = .{} }));
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 10 } }));
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 20, .stop_requested = false } }));
    try std.testing.expectEqual(Decision.yield, step(&state, .{ .boundary = .{ .now_ms = 30, .stop_requested = true } }));
}

test "a deadline yields at or after its time and not before" {
    var state: State = .{};
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .start = .{ .stop_at_ms = 1000 } }));
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 0 } }));
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 999 } }));
    try std.testing.expectEqual(Decision.yield, step(&state, .{ .boundary = .{ .now_ms = 1000 } }));

    var fresh: State = .{};
    try std.testing.expectEqual(Decision.proceed, step(&fresh, .{ .start = .{ .stop_at_ms = 1000 } }));
    try std.testing.expectEqual(Decision.proceed, step(&fresh, .{ .boundary = .{ .now_ms = 2000 } }));
    try std.testing.expectEqual(Decision.yield, step(&fresh, .{ .boundary = .{ .now_ms = 2000 } }));
}

test "a compaction or another save never yields and does not count as the first request" {
    var state: State = .{};
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .start = .{ .stop_at_ms = 0 } }));
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 5000, .stop_requested = true, .kind = .compaction } }));
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 5000, .stop_requested = true, .kind = .other } }));
    try std.testing.expectEqual(false, state.sent);
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 5000, .kind = .request } }));
    try std.testing.expectEqual(Decision.yield, step(&state, .{ .boundary = .{ .now_ms = 5000, .kind = .request } }));
}

test "start forgets the last prompt" {
    var state: State = .{};
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .start = .{ .stop_at_ms = 500 } }));
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 100 } }));
    try std.testing.expectEqual(true, state.sent);

    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .start = .{} }));
    try std.testing.expectEqual(false, state.sent);
    try std.testing.expectEqual(null, state.stop_at_ms);
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = 1000 } }));
}

test "with no deadline and no stop request the turn never yields" {
    var state: State = .{};
    try std.testing.expectEqual(Decision.proceed, step(&state, .{ .start = .{} }));
    for (0..10) |i| {
        try std.testing.expectEqual(Decision.proceed, step(&state, .{ .boundary = .{ .now_ms = @intCast(i * 1000) } }));
    }
}
