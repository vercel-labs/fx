// In-memory ring buffer of recent gateway HTTP calls. Used by /trace
// to surface latency / error patterns without forcing a persistent trace
// log. Process-wide and lock-protected: callers do not need to plumb the
// buffer through their context.
//
// A second ring keeps only the calls that failed, so a failure stays in the
// report however many calls succeed after it.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const max_model_len: usize = 64;
pub const max_error_len: usize = 48;
pub const max_stop_reason_len: usize = 48;
pub const max_gateway_schema_diagnostic_len: usize = 160;
pub const max_gateway_request_shape_len: usize = 512;
/// The gateway's own words for a failed call, so a trace says why it failed.
pub const max_gateway_error_message_len: usize = 200;
pub const ring_capacity: usize = 32;
/// Failed calls kept apart from the window, so later successful calls never
/// push them out.
pub const failure_ring_capacity: usize = 32;

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
    /// The provider's own reason behind the unified stop reason, such as
    /// Gemini's UNEXPECTED_TOOL_CALL behind `other`.
    provider_stop_reason_buf: [max_stop_reason_len]u8 = @splat(0),
    provider_stop_reason_len: u8 = 0,
    gateway_schema_diagnostic_buf: [max_gateway_schema_diagnostic_len]u8 = @splat(0),
    gateway_schema_diagnostic_len: u16 = 0,
    gateway_request_shape_buf: [max_gateway_request_shape_len]u8 = @splat(0),
    gateway_request_shape_len: u16 = 0,
    gateway_error_message_buf: [max_gateway_error_message_len]u8 = @splat(0),
    gateway_error_message_len: u16 = 0,

    pub fn model(self: *const NetworkCall) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn errorName(self: *const NetworkCall) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn terminalStopReason(self: *const NetworkCall) []const u8 {
        return self.stop_reason_buf[0..self.stop_reason_len];
    }

    pub fn providerStopReason(self: *const NetworkCall) []const u8 {
        return self.provider_stop_reason_buf[0..self.provider_stop_reason_len];
    }

    pub fn gatewaySchemaDiagnostic(self: *const NetworkCall) []const u8 {
        return self.gateway_schema_diagnostic_buf[0..self.gateway_schema_diagnostic_len];
    }

    pub fn gatewayRequestShape(self: *const NetworkCall) []const u8 {
        return self.gateway_request_shape_buf[0..self.gateway_request_shape_len];
    }

    pub fn gatewayErrorMessage(self: *const NetworkCall) []const u8 {
        return self.gateway_error_message_buf[0..self.gateway_error_message_len];
    }

    pub fn setModel(self: *NetworkCall, name: []const u8) void {
        self.model_len = @intCast(keepPrefix(&self.model_buf, name));
    }

    pub fn setError(self: *NetworkCall, name: []const u8) void {
        self.error_len = @intCast(keepPrefix(&self.error_buf, name));
    }

    pub fn setTerminalStopReason(self: *NetworkCall, reason: []const u8) void {
        self.stop_reason_len = @intCast(keepPrefix(&self.stop_reason_buf, reason));
    }

    pub fn setProviderStopReason(self: *NetworkCall, reason: []const u8) void {
        self.provider_stop_reason_len = @intCast(keepPrefix(&self.provider_stop_reason_buf, reason));
    }

    pub fn setGatewaySchemaDiagnostic(self: *NetworkCall, diagnostic: []const u8) void {
        self.gateway_schema_diagnostic_len = @intCast(keepPrefix(&self.gateway_schema_diagnostic_buf, diagnostic));
    }

    pub fn setGatewayRequestShape(self: *NetworkCall, shape: []const u8) void {
        self.gateway_request_shape_len = @intCast(keepPrefix(&self.gateway_request_shape_buf, shape));
    }

    /// Keeps `message` as one line the trace can quote: control bytes and
    /// double quotes become spaces and single quotes, and a cut never splits
    /// a UTF-8 sequence. Bytes that are not UTF-8 become `?`.
    pub fn setGatewayErrorMessage(self: *NetworkCall, message: []const u8) void {
        var out: usize = 0;
        var at: usize = 0;
        while (at < message.len) {
            const byte = message[at];
            const width: usize = std.unicode.utf8ByteSequenceLength(byte) catch 0;
            const valid = width > 0 and at + width <= message.len and
                (width == 1 or std.unicode.utf8ValidateSlice(message[at .. at + width]));
            if (!valid) {
                if (out + 1 > max_gateway_error_message_len) break;
                self.gateway_error_message_buf[out] = '?';
                out += 1;
                at += 1;
                continue;
            }
            if (out + width > max_gateway_error_message_len) break;
            if (width == 1) {
                self.gateway_error_message_buf[out] = switch (byte) {
                    0...0x1f, 0x7f => ' ',
                    '"' => '\'',
                    else => byte,
                };
            } else {
                @memcpy(self.gateway_error_message_buf[out .. out + width], message[at .. at + width]);
            }
            out += width;
            at += width;
        }
        self.gateway_error_message_len = @intCast(out);
    }

    /// Failure predicate shared by the /trace renderer and the lifetime
    /// counters so the window and the session totals never disagree.
    pub fn isError(self: *const NetworkCall) bool {
        return self.error_len > 0 or (self.status != 0 and self.status >= 400);
    }
};

/// Copies the longest prefix of `value` that fits `buf` and does not end
/// inside a UTF-8 sequence, and returns its length.
fn keepPrefix(buf: []u8, value: []const u8) usize {
    const kept = text_utils.utf8PrefixByBytes(value, buf.len);
    @memcpy(buf[0..kept.len], kept);
    return kept.len;
}

var mutex: std.Io.Mutex = .init;
var ring: [ring_capacity]NetworkCall = @splat(.{});
var head: usize = 0;
var stored: usize = 0;
// All-zero so it lands in .bss; snapshots read only `failures_stored` slots.
var failures: [failure_ring_capacity]NetworkCall = std.mem.zeroes([failure_ring_capacity]NetworkCall);
var failures_head: usize = 0;
var failures_stored: usize = 0;

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
    // Under the same lock, so a snapshot never sees a failure in the window
    // that the failure ring does not hold yet.
    if (call.isError()) {
        failures[failures_head] = call;
        failures_head = (failures_head + 1) % failure_ring_capacity;
        if (failures_stored < failure_ring_capacity) failures_stored += 1;
    }
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

/// Copies the newest kept failed calls into `out`, oldest first. Later
/// successful calls never remove them; only newer failures and `reset` do.
pub fn snapshotFailures(out: []NetworkCall) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const n = @min(failures_stored, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (failures_head + failure_ring_capacity - n + i) % failure_ring_capacity;
        out[i] = failures[idx];
    }
    return n;
}

pub fn reset() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    head = 0;
    stored = 0;
    failures_head = 0;
    failures_stored = 0;
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

fn fuzzGatewayErrorMessage(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len = smith.slice(&buffer);
    var call: NetworkCall = .{};
    call.setGatewayErrorMessage(buffer[0..len]);
    const kept = call.gatewayErrorMessage();
    try std.testing.expect(kept.len <= max_gateway_error_message_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(kept));
    for (kept) |byte| {
        try std.testing.expect(byte >= 0x20 and byte != 0x7f and byte != '"');
    }
}

test "fuzzed gateway error messages stay one bounded line of UTF-8" {
    try std.testing.fuzz({}, fuzzGatewayErrorMessage, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "HTTP 401: token expired",
            "multi\nline \"quoted\" \x00\x7f",
            "caf\xc3\xa9 \xe2\x80",
            "\xff\xfe broken",
        }) ++ @import("fuzz_corpus").network_error_message.*),
    });
}

const TextField = struct {
    set: *const fn (*NetworkCall, []const u8) void,
    get: *const fn (*const NetworkCall) []const u8,
    limit: usize,
};

/// The fields whose setters cut with `keepPrefix`.
const text_fields = [_]TextField{
    .{ .set = NetworkCall.setModel, .get = NetworkCall.model, .limit = max_model_len },
    .{ .set = NetworkCall.setError, .get = NetworkCall.errorName, .limit = max_error_len },
    .{ .set = NetworkCall.setTerminalStopReason, .get = NetworkCall.terminalStopReason, .limit = max_stop_reason_len },
    .{ .set = NetworkCall.setProviderStopReason, .get = NetworkCall.providerStopReason, .limit = max_stop_reason_len },
    .{ .set = NetworkCall.setGatewaySchemaDiagnostic, .get = NetworkCall.gatewaySchemaDiagnostic, .limit = max_gateway_schema_diagnostic_len },
    .{ .set = NetworkCall.setGatewayRequestShape, .get = NetworkCall.gatewayRequestShape, .limit = max_gateway_request_shape_len },
};

test "network call text cuts end on a UTF-8 boundary" {
    var call: NetworkCall = .{};
    var value: [max_gateway_request_shape_len + 4]u8 = undefined;
    const sequences = [_][]const u8{ "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x91\x8d" };
    for (text_fields) |field| {
        for (sequences) |sequence| {
            // The cut falls after the first byte of `sequence`.
            @memset(value[0 .. field.limit - 1], 'a');
            @memcpy(value[field.limit - 1 ..][0..sequence.len], sequence);
            field.set(&call, value[0 .. field.limit - 1 + sequence.len]);
            try std.testing.expectEqual(field.limit - 1, field.get(&call).len);
            try std.testing.expect(std.unicode.utf8ValidateSlice(field.get(&call)));
        }
        // A value that fits stays whole, and one byte more is cut there.
        @memset(value[0 .. field.limit + 1], 'b');
        field.set(&call, value[0..field.limit]);
        try std.testing.expectEqual(field.limit, field.get(&call).len);
        field.set(&call, value[0 .. field.limit + 1]);
        try std.testing.expectEqual(field.limit, field.get(&call).len);
    }
}

fn fuzzNetworkCallText(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_gateway_request_shape_len + 64]u8 = undefined;
    const len = smith.slice(&buffer);
    const value = buffer[0..len];
    const valid = std.unicode.utf8ValidateSlice(value);
    var call: NetworkCall = .{};
    for (text_fields) |field| {
        field.set(&call, value);
        const kept = field.get(&call);
        try std.testing.expect(std.mem.startsWith(u8, value, kept));
        try std.testing.expect(kept.len <= field.limit);
        if (value.len <= field.limit) try std.testing.expectEqual(value.len, kept.len);
        if (valid) {
            try std.testing.expect(std.unicode.utf8ValidateSlice(kept));
            // A cut on valid text gives up at most the three bytes before it.
            try std.testing.expect(kept.len + 3 >= @min(value.len, field.limit));
        }
    }
}

test "fuzzed network call text stays a bounded prefix that keeps UTF-8 whole" {
    try std.testing.fuzz({}, fuzzNetworkCallText, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "openai/gpt-5",
            "\xc3\xa9\xc3\xa9\xc3\xa9",
            "\xf0\x9f\x91\x8d\xf0\x9f\x91\x8d",
            "\x80\x80\xff\xc3",
        }) ++ @import("fuzz_corpus").network_call_text.*),
    });
}

/// Records one call whose `subagent_id` and `step_id` name it in tests.
fn recordTestCall(status: u16, error_name: []const u8, subagent_id: u64, step_id: u64) void {
    var call: NetworkCall = .{ .status = status, .subagent_id = subagent_id, .step_id = step_id, .duration_ms = 1 };
    if (error_name.len > 0) call.setError(error_name);
    record(call);
}

test "a failed call stays kept after later calls move it out of the window" {
    resetForTest();
    defer resetForTest();

    recordTestCall(503, "", 0, 1);
    var step: u64 = 2;
    while (step <= ring_capacity) : (step += 1) recordTestCall(200, "", 0, step);
    var window: [ring_capacity]NetworkCall = undefined;
    // 31 later calls: the failure is still the window's oldest call.
    try std.testing.expectEqual(ring_capacity, snapshot(&window));
    try std.testing.expectEqual(@as(u64, 1), window[0].step_id);

    recordTestCall(200, "", 0, step);
    const n = snapshot(&window);
    for (window[0..n]) |call| try std.testing.expect(!call.isError());
    var kept: [failure_ring_capacity]NetworkCall = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshotFailures(&kept));
    try std.testing.expectEqual(@as(u16, 503), kept[0].status);
    try std.testing.expectEqual(@as(u64, 1), kept[0].step_id);
    try std.testing.expectEqual(@as(u64, 1), lifetimeStats().error_calls);
}

test "only calls that count as errors enter the failure ring" {
    resetForTest();
    defer resetForTest();

    recordTestCall(399, "", 0, 1);
    recordTestCall(400, "", 0, 2);
    recordTestCall(200, "Timeout", 0, 3);
    recordTestCall(0, "", 0, 4);
    recordTestCall(0, "ConnectionRefused", 0, 5);
    var kept: [failure_ring_capacity]NetworkCall = undefined;
    const n = snapshotFailures(&kept);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u64, 2), kept[0].step_id);
    try std.testing.expectEqual(@as(u64, 3), kept[1].step_id);
    try std.testing.expectEqual(@as(u64, 5), kept[2].step_id);
    try std.testing.expectEqual(lifetimeStats().error_calls, n);
}

test "the failure ring keeps the newest failures in order and a reset clears it" {
    resetForTest();
    defer resetForTest();

    var step: u64 = 0;
    while (step < failure_ring_capacity + 1) : (step += 1) recordTestCall(500, "", 0, step);
    var kept: [failure_ring_capacity]NetworkCall = undefined;
    try std.testing.expectEqual(failure_ring_capacity, snapshotFailures(&kept));
    try std.testing.expectEqual(@as(u64, 1), kept[0].step_id);
    try std.testing.expectEqual(@as(u64, failure_ring_capacity), kept[failure_ring_capacity - 1].step_id);
    var small: [2]NetworkCall = undefined;
    try std.testing.expectEqual(@as(usize, 2), snapshotFailures(&small));
    try std.testing.expectEqual(@as(u64, failure_ring_capacity - 1), small[0].step_id);
    try std.testing.expectEqual(@as(usize, 0), snapshotFailures(&.{}));

    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshotFailures(&kept));
    try std.testing.expectEqual(@as(u64, 0), lifetimeStats().error_calls);
}

test "the network rings match a reference list on seeded random sequences" {
    resetForTest();
    defer resetForTest();

    var calls: std.ArrayList(u64) = .empty;
    defer calls.deinit(std.testing.allocator);
    var failed: std.ArrayList(u64) = .empty;
    defer failed.deinit(std.testing.allocator);
    var window: [ring_capacity]NetworkCall = undefined;
    var kept: [failure_ring_capacity]NetworkCall = undefined;

    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        reset();
        calls.clearRetainingCapacity();
        failed.clearRetainingCapacity();
        const steps = random.uintAtMost(u64, 300);
        var step: u64 = 1;
        while (step <= steps) : (step += 1) {
            const roll = random.uintLessThan(u8, 100);
            if (roll == 0) {
                reset();
                calls.clearRetainingCapacity();
                failed.clearRetainingCapacity();
                continue;
            }
            const status: u16 = if (roll < 30) 500 else if (roll < 40) 302 else 200;
            const error_name: []const u8 = if (roll >= 95) "Timeout" else "";
            recordTestCall(status, error_name, 0, step);
            try calls.append(std.testing.allocator, step);
            if (status >= 400 or error_name.len > 0) try failed.append(std.testing.allocator, step);
        }

        const window_n = snapshot(&window);
        const want_window = calls.items[calls.items.len - @min(calls.items.len, ring_capacity) ..];
        try std.testing.expectEqual(want_window.len, window_n);
        for (want_window, window[0..window_n]) |want, got| try std.testing.expectEqual(want, got.step_id);

        const kept_n = snapshotFailures(&kept);
        const want_kept = failed.items[failed.items.len - @min(failed.items.len, failure_ring_capacity) ..];
        try std.testing.expectEqual(want_kept.len, kept_n);
        for (want_kept, kept[0..kept_n]) |want, got| try std.testing.expectEqual(want, got.step_id);
        try std.testing.expectEqual(@as(u64, failed.items.len), lifetimeStats().error_calls);
    }
}

test "records from many threads keep both network rings bounded and in order" {
    resetForTest();
    defer resetForTest();

    const thread_count = 8;
    const per_thread = 12_500;
    const Worker = struct {
        fn run(thread_index: usize) void {
            var seq: u64 = 0;
            while (seq < per_thread) : (seq += 1) {
                // A third fail; `subagent_id` names the thread and `step_id` its order.
                recordTestCall(if (seq % 3 == 0) 500 else 200, "", thread_index + 1, seq);
            }
        }
    };
    const Reader = struct {
        fn run(done: *std.atomic.Value(bool), errors: *std.atomic.Value(u32)) void {
            var window: [ring_capacity]NetworkCall = undefined;
            var kept: [failure_ring_capacity]NetworkCall = undefined;
            while (!done.load(.acquire)) {
                const window_n = snapshot(&window);
                if (!stepsAscendPerThread(window[0..window_n])) _ = errors.fetchAdd(1, .monotonic);
                const kept_n = snapshotFailures(&kept);
                if (!stepsAscendPerThread(kept[0..kept_n])) _ = errors.fetchAdd(1, .monotonic);
                for (kept[0..kept_n]) |call| {
                    if (!call.isError()) _ = errors.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var done = std.atomic.Value(bool).init(false);
    var errors = std.atomic.Value(u32).init(0);
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ &done, &errors });
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, Worker.run, .{index});
    for (threads) |thread| thread.join();
    done.store(true, .release);
    reader.join();

    try std.testing.expectEqual(@as(u32, 0), errors.load(.monotonic));
    const stats = lifetimeStats();
    try std.testing.expectEqual(@as(u64, thread_count * per_thread), stats.total_calls);
    try std.testing.expectEqual(@as(u64, thread_count * ((per_thread + 2) / 3)), stats.error_calls);
    var kept: [failure_ring_capacity]NetworkCall = undefined;
    try std.testing.expectEqual(failure_ring_capacity, snapshotFailures(&kept));
}

/// Whether each thread's calls appear in the order it made them.
fn stepsAscendPerThread(calls: []const NetworkCall) bool {
    var last: [9]?u64 = @splat(null);
    for (calls) |call| {
        if (call.subagent_id >= last.len) return false;
        if (last[call.subagent_id]) |previous| if (call.step_id <= previous) return false;
        last[call.subagent_id] = call.step_id;
    }
    return true;
}

test "a gateway error message keeps its words on one line and cuts at a character" {
    var call: NetworkCall = .{};
    call.setGatewayErrorMessage("HTTP 401: \"token\"\nexpired");
    try std.testing.expectEqualStrings("HTTP 401: 'token' expired", call.gatewayErrorMessage());
    var long: [max_gateway_error_message_len + 8]u8 = undefined;
    @memset(&long, 'a');
    // An e with an acute accent across the limit is dropped whole.
    @memcpy(long[max_gateway_error_message_len - 1 ..][0..2], "\xc3\xa9");
    call.setGatewayErrorMessage(&long);
    try std.testing.expectEqual(max_gateway_error_message_len - 1, call.gatewayErrorMessage().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(call.gatewayErrorMessage()));
    call.setGatewayErrorMessage("");
    try std.testing.expectEqualStrings("", call.gatewayErrorMessage());
}
