//! How long one model request may wait: to connect, for the first response,
//! and, once the response has started, for its next bytes. `expired` is the
//! one place that decides a wait has run out. The connection watch in
//! `client.zig` asks it, and so does the lab that walks it along
//! `tests/tla/configured_provider/ConfiguredDeadlines.tla`.
//!
//! The module reads no clock: its caller passes the time, in milliseconds on
//! any clock that does not go backwards. Imports only the standard library.
const std = @import("std");

/// A bound that never runs out.
pub const never: u64 = std.math.maxInt(u64);

pub const Bounds = struct {
    connect_ms: u64 = never,
    first_response_ms: u64 = never,
    stall_ms: u64 = never,
};

pub const Wait = enum {
    connecting,
    awaiting_head,
    streaming,

    /// The settings key that bounds the wait, for a message that names it.
    pub fn setting(self: Wait) []const u8 {
        return switch (self) {
            .connecting => "timeouts.connect_ms",
            .awaiting_head => "timeouts.first_response_ms",
            .streaming => "timeouts.stall_ms",
        };
    }
};

pub const Deadlines = struct {
    bounds: Bounds,
    wait: Wait = .connecting,
    /// When the current wait began.
    wait_started_ms: u64,
    /// When the response last sent bytes. Only `streaming` reads it.
    last_bytes_ms: u64,

    pub fn init(bounds: Bounds, now_ms: u64) Deadlines {
        return .{ .bounds = bounds, .wait_started_ms = now_ms, .last_bytes_ms = now_ms };
    }

    pub fn connected(self: *Deadlines, now_ms: u64) void {
        self.begin(.awaiting_head, now_ms);
    }

    pub fn headArrived(self: *Deadlines, now_ms: u64) void {
        self.begin(.streaming, now_ms);
    }

    /// The response sent bytes.
    pub fn bytes(self: *Deadlines, now_ms: u64) void {
        self.last_bytes_ms = now_ms;
    }

    fn begin(self: *Deadlines, wait: Wait, now_ms: u64) void {
        self.wait = wait;
        self.wait_started_ms = now_ms;
        self.last_bytes_ms = now_ms;
    }

    /// The wait that has run out at `now_ms`, or null. A wait ends exactly
    /// at its bound, so what it waited for loses when it arrives then
    /// (NeverPastConfigured, NeverBeforeConfigured). The stall bound times
    /// silence, never the whole response.
    pub fn expired(self: *const Deadlines, now_ms: u64) ?Wait {
        const bound_ms = switch (self.wait) {
            .connecting => self.bounds.connect_ms,
            .awaiting_head => self.bounds.first_response_ms,
            .streaming => self.bounds.stall_ms,
        };
        if (bound_ms == never) return null;
        const silence_ms = switch (self.wait) {
            .connecting, .awaiting_head => now_ms -| self.wait_started_ms,
            .streaming => now_ms -| self.last_bytes_ms,
        };
        return if (silence_ms >= bound_ms) self.wait else null;
    }
};

test "a wait runs out exactly at its bound and names itself" {
    var deadlines = Deadlines.init(.{ .connect_ms = 30, .first_response_ms = 120, .stall_ms = 60 }, 1_000);
    try std.testing.expectEqual(@as(?Wait, null), deadlines.expired(1_029));
    try std.testing.expectEqual(@as(?Wait, .connecting), deadlines.expired(1_030));
    deadlines.connected(1_010);
    try std.testing.expectEqual(@as(?Wait, null), deadlines.expired(1_129));
    try std.testing.expectEqual(@as(?Wait, .awaiting_head), deadlines.expired(1_130));
    try std.testing.expectEqualStrings("timeouts.first_response_ms", Wait.awaiting_head.setting());
    deadlines.headArrived(1_100);
    try std.testing.expectEqual(@as(?Wait, null), deadlines.expired(1_159));
    try std.testing.expectEqual(@as(?Wait, .streaming), deadlines.expired(1_160));
}

test "the stall bound times silence, not the whole response" {
    var deadlines = Deadlines.init(.{ .stall_ms = 60 }, 0);
    deadlines.connected(0);
    deadlines.headArrived(0);
    var now: u64 = 0;
    // A response that keeps sending never stalls, however long it runs.
    while (now < 10_000) : (now += 59) {
        try std.testing.expectEqual(@as(?Wait, null), deadlines.expired(now));
        deadlines.bytes(now);
    }
    try std.testing.expectEqual(@as(?Wait, .streaming), deadlines.expired(now - 59 + 60));
}

test "a wait with no bound never runs out, and a clock that went back counts as no time" {
    var deadlines = Deadlines.init(.{}, 500);
    try std.testing.expectEqual(@as(?Wait, null), deadlines.expired(std.math.maxInt(u64) - 1));
    deadlines.connected(500);
    deadlines.bounds.first_response_ms = 10;
    try std.testing.expectEqual(@as(?Wait, null), deadlines.expired(400));
    try std.testing.expectEqual(@as(?Wait, .awaiting_head), deadlines.expired(510));
}
