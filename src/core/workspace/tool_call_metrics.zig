// In-memory ring buffer of recent tool invocations. Used by /trace so
// the report shows which tools the model invoked, with bounded args/results
// for normal tools, without forcing a persistent trace log. web_fetch is
// compact-only because its prompt and fetched content are sensitive.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const tool_result_display = @import("../tooling/tool_result_display.zig");

pub const max_name_len: usize = 64;
pub const max_args_len: usize = 1200;
pub const max_result_len: usize = 2000;
pub const ring_capacity: usize = 64;

pub const ToolCallOutcome = enum(u8) {
    succeeded,
    rejected,
    command_failed,
    tool_failed,
    runtime_failed,
};

pub const ToolCallMetric = struct {
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    outcome: ToolCallOutcome = .succeeded,
    subagent_id: u64 = 0,
    name_buf: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    name_len: u8 = 0,
    args_buf: [max_args_len]u8 = [_]u8{0} ** max_args_len,
    args_len: u16 = 0,
    args_total_bytes: u32 = 0,
    result_buf: [max_result_len]u8 = [_]u8{0} ** max_result_len,
    result_len: u16 = 0,
    result_total_bytes: u32 = 0,

    pub fn name(self: *const ToolCallMetric) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn args(self: *const ToolCallMetric) []const u8 {
        return self.args_buf[0..self.args_len];
    }

    pub fn result(self: *const ToolCallMetric) []const u8 {
        return self.result_buf[0..self.result_len];
    }

    pub fn setName(self: *ToolCallMetric, value: []const u8) void {
        const n = @min(value.len, max_name_len);
        @memcpy(self.name_buf[0..n], value[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn setArgs(self: *ToolCallMetric, value: []const u8) void {
        self.args_total_bytes = @intCast(@min(value.len, std.math.maxInt(u32)));
        const n = @min(value.len, max_args_len);
        @memcpy(self.args_buf[0..n], value[0..n]);
        self.args_len = @intCast(n);
    }

    pub fn setResult(self: *ToolCallMetric, value: []const u8) void {
        const normalized = tool_result_display.contentForDisplay(value);
        self.result_total_bytes = @intCast(@min(normalized.len, std.math.maxInt(u32)));
        const n = @min(normalized.len, max_result_len);
        @memcpy(self.result_buf[0..n], normalized[0..n]);
        self.result_len = @intCast(n);
    }

    pub fn setPayloadsForName(self: *ToolCallMetric, tool_name: []const u8, arguments_json: []const u8, model_output: []const u8) void {
        if (omitsPayloadsForName(tool_name)) {
            self.clearPayloads();
            return;
        }
        self.setArgs(arguments_json);
        self.setResult(model_output);
    }

    fn clearPayloads(self: *ToolCallMetric) void {
        @memset(&self.args_buf, 0);
        self.args_len = 0;
        self.args_total_bytes = 0;
        @memset(&self.result_buf, 0);
        self.result_len = 0;
        self.result_total_bytes = 0;
    }
};

pub const ToolCallRecord = struct {
    name: []const u8,
    arguments_json: []const u8,
    model_output: []const u8,
    outcome: ToolCallOutcome,
    started_at_ms: i64,
    subagent_id: u64 = 0,
};

pub fn omitsPayloadsForName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_fetch");
}

var mutex: std.Io.Mutex = .init;
// All-zero so the ring lands in .bss instead of ~200KB of initialized data
// in the binary. At-rest slots are never observed: snapshot() is bounded by
// `stored` and record() overwrites whole slots.
var ring: [ring_capacity]ToolCallMetric = std.mem.zeroes([ring_capacity]ToolCallMetric);
var head: usize = 0;
var stored: usize = 0;

pub fn record(call: ToolCallMetric) void {
    var stored_call = call;
    if (omitsPayloadsForName(stored_call.name())) stored_call.clearPayloads();

    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    ring[head] = stored_call;
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;
}

pub fn recordResult(input: ToolCallRecord) void {
    const now_ms = io_mod.milliTimestamp();
    const elapsed = if (now_ms > input.started_at_ms) now_ms - input.started_at_ms else 0;
    var metric: ToolCallMetric = .{
        .started_at_ms = input.started_at_ms,
        .duration_ms = @intCast(@min(@as(i64, elapsed), std.math.maxInt(u32))),
        .outcome = input.outcome,
        .subagent_id = input.subagent_id,
    };
    metric.setName(input.name);
    metric.setPayloadsForName(input.name, input.arguments_json, input.model_output);
    record(metric);
}

pub fn snapshot(out: []ToolCallMetric) usize {
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

test "tool call ring keeps last N records in chronological order" {
    resetForTest();
    defer resetForTest();

    var i: u32 = 0;
    while (i < ring_capacity + 3) : (i += 1) {
        var call: ToolCallMetric = .{ .duration_ms = i };
        call.setName("read_file");
        call.setArgs("{}");
        call.setResult("ok");
        record(call);
    }

    var buf: [ring_capacity]ToolCallMetric = undefined;
    const n = snapshot(&buf);
    try std.testing.expectEqual(ring_capacity, n);
    try std.testing.expectEqual(@as(u32, 3), buf[0].duration_ms);
    try std.testing.expectEqual(@as(u32, ring_capacity + 3 - 1), buf[ring_capacity - 1].duration_ms);
}

test "args and result are truncated and total length tracked" {
    resetForTest();
    defer resetForTest();

    const huge_len: usize = @as(usize, @max(max_args_len, max_result_len)) + 200;
    var huge: [huge_len]u8 = undefined;
    @memset(&huge, 'a');
    var call: ToolCallMetric = .{};
    call.setName("read_file");
    call.setArgs(&huge);
    call.setResult(&huge);
    record(call);

    var buf: [1]ToolCallMetric = undefined;
    const n = snapshot(&buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u16, max_args_len), buf[0].args_len);
    try std.testing.expectEqual(@as(u32, huge_len), buf[0].args_total_bytes);
    try std.testing.expectEqual(@as(u16, max_result_len), buf[0].result_len);
    try std.testing.expectEqual(@as(u32, huge_len), buf[0].result_total_bytes);
}

test "tool call outcome labels remain exact" {
    const cases = [_]struct {
        outcome: ToolCallOutcome,
        label: []const u8,
        success: bool,
    }{
        .{ .outcome = .succeeded, .label = "succeeded", .success = true },
        .{ .outcome = .rejected, .label = "rejected", .success = false },
        .{ .outcome = .command_failed, .label = "command_failed", .success = false },
        .{ .outcome = .tool_failed, .label = "tool_failed", .success = false },
        .{ .outcome = .runtime_failed, .label = "runtime_failed", .success = false },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.label, @tagName(case.outcome));
        try std.testing.expectEqual(case.success, case.outcome == .succeeded);
    }
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ToolCallOutcome.succeeded));
}
