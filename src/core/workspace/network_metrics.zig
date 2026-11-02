// In-memory ring buffer of recent gateway HTTP calls. Used by /trace
// to surface latency / error patterns without forcing a persistent trace
// log. Process-wide and lock-protected: callers do not need to plumb the
// buffer through their context.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const max_model_len: usize = 64;
pub const max_error_len: usize = 48;
pub const max_stop_reason_len: usize = 48;
pub const max_gateway_schema_diagnostic_len: usize = 160;
pub const max_gateway_request_shape_len: usize = 512;
pub const ring_capacity: usize = 32;

pub const NetworkCallKind = enum {
    gateway,
    web_search,
    web_fetch_target,
};

pub const NetworkCall = struct {
    kind: NetworkCallKind = .gateway,
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    status: u16 = 0,
    response_bytes: u32 = 0,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    is_web_search: bool = false,
    web_search_requests: u32 = 0,
    turn_id: u64 = 0,
    step_id: u64 = 0,
    subagent_id: u64 = 0,
    model_buf: [max_model_len]u8 = @splat(0),
    model_len: u8 = 0,
    error_buf: [max_error_len]u8 = @splat(0),
    error_len: u8 = 0,
    stop_reason_buf: [max_stop_reason_len]u8 = @splat(0),
    stop_reason_len: u8 = 0,
    gateway_schema_diagnostic_buf: [max_gateway_schema_diagnostic_len]u8 = @splat(0),
    gateway_schema_diagnostic_len: u16 = 0,
    gateway_request_shape_buf: [max_gateway_request_shape_len]u8 = @splat(0),
    gateway_request_shape_len: u16 = 0,

    pub fn model(self: *const NetworkCall) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn errorName(self: *const NetworkCall) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn terminalStopReason(self: *const NetworkCall) []const u8 {
        return self.stop_reason_buf[0..self.stop_reason_len];
    }

    pub fn gatewaySchemaDiagnostic(self: *const NetworkCall) []const u8 {
        return self.gateway_schema_diagnostic_buf[0..self.gateway_schema_diagnostic_len];
    }

    pub fn gatewayRequestShape(self: *const NetworkCall) []const u8 {
        return self.gateway_request_shape_buf[0..self.gateway_request_shape_len];
    }

    pub fn setModel(self: *NetworkCall, name: []const u8) void {
        const n = @min(name.len, max_model_len);
        @memcpy(self.model_buf[0..n], name[0..n]);
        self.model_len = @intCast(n);
    }

    pub fn setError(self: *NetworkCall, name: []const u8) void {
        const n = @min(name.len, max_error_len);
        @memcpy(self.error_buf[0..n], name[0..n]);
        self.error_len = @intCast(n);
    }

    pub fn setTerminalStopReason(self: *NetworkCall, reason: []const u8) void {
        const n = @min(reason.len, max_stop_reason_len);
        @memcpy(self.stop_reason_buf[0..n], reason[0..n]);
        self.stop_reason_len = @intCast(n);
    }

    pub fn setGatewaySchemaDiagnostic(self: *NetworkCall, diagnostic: []const u8) void {
        const n = @min(diagnostic.len, max_gateway_schema_diagnostic_len);
        @memcpy(self.gateway_schema_diagnostic_buf[0..n], diagnostic[0..n]);
        self.gateway_schema_diagnostic_len = @intCast(n);
    }

    pub fn setGatewayRequestShape(self: *NetworkCall, shape: []const u8) void {
        const n = @min(shape.len, max_gateway_request_shape_len);
        @memcpy(self.gateway_request_shape_buf[0..n], shape[0..n]);
        self.gateway_request_shape_len = @intCast(n);
    }

    /// Failure predicate shared by the /trace renderer and the lifetime
    /// counters so the window and the session totals never disagree.
    pub fn isError(self: *const NetworkCall) bool {
        return self.error_len > 0 or (self.status != 0 and self.status >= 400);
    }
};

var mutex: std.Io.Mutex = .init;
var ring: [ring_capacity]NetworkCall = @splat(.{});
var head: usize = 0;
var stored: usize = 0;

/// Session-wide totals, reset on session transitions via
/// `diagnostics.resetSession()`. Unlike the ring, these never evict: the
/// /trace report must answer "did anything fail all session" even after the
/// window slides.
pub const LifetimeStats = struct {
    total_calls: u64 = 0,
    ok_calls: u64 = 0,
    error_calls: u64 = 0,
    total_duration_ms: u64 = 0,
    /// Turn buckets dropped to make room for newer ones. Zero means the
    /// rendered turns list covers every tagged turn in the session.
    evicted_turns: u64 = 0,
};

/// Bounded per-turn accounting for model calls. Turn ids increase
/// monotonically within a process, so a full table evicts the coldest turn.
pub const turn_rollup_capacity: usize = 16;

pub const TurnRollup = struct {
    turn_id: u64 = 0,
    calls: u32 = 0,
    error_calls: u32 = 0,
    subagent_calls: u32 = 0,
    total_duration_ms: u64 = 0,
    first_started_at_ms: i64 = 0,
};

var lifetime: LifetimeStats = .{};
var turn_rollups: [turn_rollup_capacity]TurnRollup = @splat(.{});
var turn_rollup_count: usize = 0;

pub fn record(call: NetworkCall) void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    ring[head] = call;
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;
    recordLifetime(call);
}

fn recordLifetime(call: NetworkCall) void {
    lifetime.total_calls += 1;
    if (call.isError()) lifetime.error_calls += 1 else lifetime.ok_calls += 1;
    lifetime.total_duration_ms += call.duration_ms;
    if (call.turn_id == 0) return;
    const rollup = turnRollupFor(call.turn_id);
    rollup.calls += 1;
    if (call.isError()) rollup.error_calls += 1;
    if (call.subagent_id != 0) rollup.subagent_calls += 1;
    rollup.total_duration_ms += call.duration_ms;
    if (call.started_at_ms > 0 and
        (rollup.first_started_at_ms == 0 or call.started_at_ms < rollup.first_started_at_ms))
    {
        rollup.first_started_at_ms = call.started_at_ms;
    }
}

fn turnRollupFor(turn_id: u64) *TurnRollup {
    var oldest: usize = 0;
    var i: usize = 0;
    while (i < turn_rollup_count) : (i += 1) {
        if (turn_rollups[i].turn_id == turn_id) return &turn_rollups[i];
        if (turn_rollups[i].turn_id < turn_rollups[oldest].turn_id) oldest = i;
    }
    if (turn_rollup_count < turn_rollup_capacity) {
        defer turn_rollup_count += 1;
        turn_rollups[turn_rollup_count] = .{ .turn_id = turn_id };
        return &turn_rollups[turn_rollup_count];
    }
    lifetime.evicted_turns += 1;
    turn_rollups[oldest] = .{ .turn_id = turn_id };
    return &turn_rollups[oldest];
}

pub fn lifetimeStats() LifetimeStats {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    return lifetime;
}

/// Copies up to `out.len` most recent turn rollups, ascending by turn id.
pub fn snapshotTurnRollups(out: []TurnRollup) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    var all: [turn_rollup_capacity]TurnRollup = turn_rollups;
    const count = turn_rollup_count;
    var index: usize = 1;
    while (index < count) : (index += 1) {
        const candidate = all[index];
        var insertion = index;
        while (insertion > 0 and candidate.turn_id < all[insertion - 1].turn_id) : (insertion -= 1) {
            all[insertion] = all[insertion - 1];
        }
        all[insertion] = candidate;
    }
    const n = @min(count, out.len);
    @memcpy(out[0..n], all[count - n .. count]);
    return n;
}

pub fn snapshot(out: []NetworkCall) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const n = @min(stored, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (head + ring_capacity - n + i) % ring_capacity;
        out[i] = ring[idx];
    }
    return n;
}

pub fn reset() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    head = 0;
    stored = 0;
    lifetime = .{};
    turn_rollups = @as([turn_rollup_capacity]TurnRollup, @splat(.{}));
    turn_rollup_count = 0;
}

pub fn resetForTest() void {
    reset();
}

test "ring keeps last N records in chronological order" {
    resetForTest();
    defer resetForTest();

    var i: u32 = 0;
    while (i < ring_capacity + 5) : (i += 1) {
        var call: NetworkCall = .{ .duration_ms = i };
        call.setModel("anthropic/claude-opus-4.6");
        record(call);
    }

    var buf: [ring_capacity]NetworkCall = undefined;
    const n = snapshot(&buf);
    try std.testing.expectEqual(ring_capacity, n);
    try std.testing.expectEqual(@as(u32, 5), buf[0].duration_ms);
    try std.testing.expectEqual(@as(u32, ring_capacity + 5 - 1), buf[ring_capacity - 1].duration_ms);
}

test "lifetime stats cover evicted calls and reset clears them" {
    resetForTest();
    defer resetForTest();

    var i: u32 = 0;
    while (i < ring_capacity + 5) : (i += 1) {
        var call: NetworkCall = .{ .duration_ms = 10, .started_at_ms = 1000 + @as(i64, i) * 100 };
        if (i % 7 == 0) call.status = 500;
        record(call);
    }

    const stats = lifetimeStats();
    try std.testing.expectEqual(@as(u64, ring_capacity + 5), stats.total_calls);
    try std.testing.expect(stats.error_calls > 0);
    try std.testing.expectEqual(@as(u64, (ring_capacity + 5) * 10), stats.total_duration_ms);

    var buf: [ring_capacity]NetworkCall = undefined;
    const n = snapshot(&buf);
    try std.testing.expect(stats.total_calls > n);

    resetForTest();
    const cleared = lifetimeStats();
    try std.testing.expectEqual(@as(u64, 0), cleared.total_calls);
    try std.testing.expectEqual(@as(u64, 0), cleared.total_duration_ms);
}

test "turn rollups aggregate per turn and evict the coldest turn" {
    resetForTest();
    defer resetForTest();

    // Three calls on turn 2 (one error, one subagent) and one on turn 9.
    record(.{ .duration_ms = 10, .started_at_ms = 1000, .turn_id = 2 });
    var failed: NetworkCall = .{ .duration_ms = 20, .started_at_ms = 2000, .turn_id = 2, .subagent_id = 7 };
    failed.setError("Timeout");
    record(failed);
    record(.{ .duration_ms = 30, .started_at_ms = 3000, .turn_id = 2 });
    record(.{ .duration_ms = 40, .started_at_ms = 4000, .turn_id = 9 });
    // Untagged calls count toward lifetime only.
    record(.{ .duration_ms = 50, .started_at_ms = 5000 });

    var out: [turn_rollup_capacity]TurnRollup = undefined;
    const n = snapshotTurnRollups(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 2), out[0].turn_id);
    try std.testing.expectEqual(@as(u32, 3), out[0].calls);
    try std.testing.expectEqual(@as(u32, 1), out[0].error_calls);
    try std.testing.expectEqual(@as(u32, 1), out[0].subagent_calls);
    try std.testing.expectEqual(@as(u64, 60), out[0].total_duration_ms);
    try std.testing.expectEqual(@as(i64, 1000), out[0].first_started_at_ms);
    try std.testing.expectEqual(@as(u64, 9), out[1].turn_id);
    try std.testing.expectEqual(@as(u32, 1), out[1].calls);
    try std.testing.expectEqual(@as(u64, 0), lifetimeStats().evicted_turns);

    // Overflow the table: turn 2 and turn 9 must be evicted as the coldest.
    var t: u64 = 100;
    while (t < 100 + turn_rollup_capacity) : (t += 1) {
        record(.{ .duration_ms = 1, .started_at_ms = 6000, .turn_id = t });
    }
    const m = snapshotTurnRollups(&out);
    try std.testing.expectEqual(turn_rollup_capacity, m);
    for (out[0..m]) |rollup| {
        try std.testing.expect(rollup.turn_id != 2);
        try std.testing.expect(rollup.turn_id != 9);
    }
    for (out[1..m], 1..) |rollup, index| {
        try std.testing.expect(out[index - 1].turn_id < rollup.turn_id);
    }
    try std.testing.expectEqual(@as(u64, 2), lifetimeStats().evicted_turns);

    var recent: [3]TurnRollup = undefined;
    try std.testing.expectEqual(@as(usize, recent.len), snapshotTurnRollups(&recent));
    try std.testing.expectEqual(@as(u64, 113), recent[0].turn_id);
    try std.testing.expectEqual(@as(u64, 114), recent[1].turn_id);
    try std.testing.expectEqual(@as(u64, 115), recent[2].turn_id);
}

test "snapshot truncates to caller buffer" {
    resetForTest();
    defer resetForTest();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        record(.{ .duration_ms = i });
    }

    var small: [4]NetworkCall = undefined;
    const n = snapshot(&small);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u32, 6), small[0].duration_ms);
    try std.testing.expectEqual(@as(u32, 9), small[3].duration_ms);
}

test "gateway diagnostics default empty truncate and survive snapshot" {
    resetForTest();
    defer resetForTest();

    var empty: NetworkCall = .{};
    try std.testing.expectEqualStrings("", empty.gatewaySchemaDiagnostic());
    try std.testing.expectEqualStrings("", empty.gatewayRequestShape());

    var long_schema: [max_gateway_schema_diagnostic_len + 8]u8 = undefined;
    @memset(long_schema[0..], 's');
    var long_shape: [max_gateway_request_shape_len + 8]u8 = undefined;
    @memset(long_shape[0..], 'r');

    var call: NetworkCall = .{ .status = 400 };
    call.setGatewaySchemaDiagnostic(&long_schema);
    call.setGatewayRequestShape(&long_shape);
    record(call);

    var buf: [1]NetworkCall = undefined;
    const n = snapshot(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(max_gateway_schema_diagnostic_len, buf[0].gatewaySchemaDiagnostic().len);
    try std.testing.expectEqual(max_gateway_request_shape_len, buf[0].gatewayRequestShape().len);
    try std.testing.expectEqual(@as(u8, 's'), buf[0].gatewaySchemaDiagnostic()[0]);
    try std.testing.expectEqual(@as(u8, 'r'), buf[0].gatewayRequestShape()[0]);
}
