// In-memory ring buffer of recent model and tool network calls. Used by /trace
// to surface latency / error patterns without forcing a persistent trace
// log. Process-wide and lock-protected: callers do not need to plumb the
// buffer through their context.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const max_model_len: usize = 64;
pub const max_error_len: usize = 48;
pub const max_stop_reason_len: usize = 48;
pub const max_tool_descriptor_diagnostic_len: usize = 160;
pub const max_model_request_shape_len: usize = 512;
pub const ring_capacity: usize = 32;

pub const NetworkCallKind = enum {
    model,
    web_search,
    web_fetch_target,
};

pub const NetworkCall = struct {
    kind: NetworkCallKind = .model,
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
    model_buf: [max_model_len]u8 = [_]u8{0} ** max_model_len,
    model_len: u8 = 0,
    error_buf: [max_error_len]u8 = [_]u8{0} ** max_error_len,
    error_len: u8 = 0,
    stop_reason_buf: [max_stop_reason_len]u8 = [_]u8{0} ** max_stop_reason_len,
    stop_reason_len: u8 = 0,
    tool_descriptor_diagnostic_buf: [max_tool_descriptor_diagnostic_len]u8 = [_]u8{0} ** max_tool_descriptor_diagnostic_len,
    tool_descriptor_diagnostic_len: u16 = 0,
    model_request_shape_buf: [max_model_request_shape_len]u8 = [_]u8{0} ** max_model_request_shape_len,
    model_request_shape_len: u16 = 0,

    pub fn model(self: *const NetworkCall) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn errorName(self: *const NetworkCall) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn terminalStopReason(self: *const NetworkCall) []const u8 {
        return self.stop_reason_buf[0..self.stop_reason_len];
    }

    pub fn toolDescriptorDiagnostic(self: *const NetworkCall) []const u8 {
        return self.tool_descriptor_diagnostic_buf[0..self.tool_descriptor_diagnostic_len];
    }

    pub fn modelRequestShape(self: *const NetworkCall) []const u8 {
        return self.model_request_shape_buf[0..self.model_request_shape_len];
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

    pub fn setToolDescriptorDiagnostic(self: *NetworkCall, diagnostic: []const u8) void {
        const n = @min(diagnostic.len, max_tool_descriptor_diagnostic_len);
        @memcpy(self.tool_descriptor_diagnostic_buf[0..n], diagnostic[0..n]);
        self.tool_descriptor_diagnostic_len = @intCast(n);
    }

    pub fn setModelRequestShape(self: *NetworkCall, shape: []const u8) void {
        const n = @min(shape.len, max_model_request_shape_len);
        @memcpy(self.model_request_shape_buf[0..n], shape[0..n]);
        self.model_request_shape_len = @intCast(n);
    }
};

var mutex: std.Io.Mutex = .init;
var ring: [ring_capacity]NetworkCall = [_]NetworkCall{.{}} ** ring_capacity;
var head: usize = 0;
var stored: usize = 0;

pub fn record(call: NetworkCall) void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    ring[head] = call;
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;
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
    try std.testing.expectEqualStrings("", empty.toolDescriptorDiagnostic());
    try std.testing.expectEqualStrings("", empty.modelRequestShape());

    var long_schema: [max_tool_descriptor_diagnostic_len + 8]u8 = undefined;
    @memset(long_schema[0..], 's');
    var long_shape: [max_model_request_shape_len + 8]u8 = undefined;
    @memset(long_shape[0..], 'r');

    var call: NetworkCall = .{ .status = 400 };
    call.setToolDescriptorDiagnostic(&long_schema);
    call.setModelRequestShape(&long_shape);
    record(call);

    var buf: [1]NetworkCall = undefined;
    const n = snapshot(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(max_tool_descriptor_diagnostic_len, buf[0].toolDescriptorDiagnostic().len);
    try std.testing.expectEqual(max_model_request_shape_len, buf[0].modelRequestShape().len);
    try std.testing.expectEqual(@as(u8, 's'), buf[0].toolDescriptorDiagnostic()[0]);
    try std.testing.expectEqual(@as(u8, 'r'), buf[0].modelRequestShape()[0]);
}
