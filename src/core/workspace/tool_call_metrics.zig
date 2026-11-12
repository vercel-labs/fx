// In-memory records of recent tool invocations. Used by /trace so the report
// shows which tools the model invoked, with bounded args/results for normal
// tools, without forcing a persistent trace log. web_fetch is compact-only
// because its prompt and fetched content are sensitive.
//
// Two rings hold them. The window keeps the last calls of every outcome, so a
// busy agent or a few subagents move a failure out of it within minutes. The
// failure ring keeps only calls that did not succeed, with larger head and
// tail cuts of their arguments and results, so a failure stays in the report
// however many calls succeed after it.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const tool_result_display = @import("../tooling/tool_result_display.zig");

pub const max_name_len: usize = 64;
pub const max_args_len: usize = 1200;
pub const max_result_len: usize = 2000;
pub const ring_capacity: usize = 64;
/// Longest provider call ID kept; longer IDs keep their first bytes.
pub const max_call_id_len: usize = 128;
pub const failure_ring_capacity: usize = 32;
/// Bytes kept of a failed call's arguments, and separately of its result,
/// split between the first and the last bytes.
pub const max_failure_field_len: usize = 8 * 1024;
pub const max_dir_len: usize = 1024;

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
    name_buf: [max_name_len]u8 = @splat(0),
    name_len: u8 = 0,
    call_id_buf: [max_call_id_len]u8 = @splat(0),
    call_id_len: u8 = 0,
    args_buf: [max_args_len]u8 = @splat(0),
    args_len: u16 = 0,
    args_total_bytes: u32 = 0,
    result_buf: [max_result_len]u8 = @splat(0),
    result_len: u16 = 0,
    result_total_bytes: u32 = 0,

    pub fn name(self: *const ToolCallMetric) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn callId(self: *const ToolCallMetric) []const u8 {
        return self.call_id_buf[0..self.call_id_len];
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

    pub fn setCallId(self: *ToolCallMetric, value: []const u8) void {
        const n = utf8PrefixLen(value, max_call_id_len);
        @memcpy(self.call_id_buf[0..n], value[0..n]);
        self.call_id_len = @intCast(n);
    }

    pub fn setArgs(self: *ToolCallMetric, value: []const u8) void {
        self.args_total_bytes = @intCast(@min(value.len, std.math.maxInt(u32)));
        const n = utf8PrefixLen(value, max_args_len);
        @memcpy(self.args_buf[0..n], value[0..n]);
        self.args_len = @intCast(n);
    }

    pub fn setResult(self: *ToolCallMetric, value: []const u8) void {
        const normalized = tool_result_display.contentForDisplay(value);
        self.result_total_bytes = @intCast(@min(normalized.len, std.math.maxInt(u32)));
        const n = utf8PrefixLen(normalized, max_result_len);
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

/// One field of a kept failure: its first and last bytes, each cut on a
/// UTF-8 boundary, and how many bytes the value had in all.
pub const KeptText = struct {
    buf: [max_failure_field_len]u8 = @splat(0),
    head_len: u16 = 0,
    tail_len: u16 = 0,
    total_bytes: u32 = 0,

    pub fn head(self: *const KeptText) []const u8 {
        return self.buf[0..self.head_len];
    }

    pub fn tail(self: *const KeptText) []const u8 {
        return self.buf[self.head_len..][0..self.tail_len];
    }

    /// Bytes between the head and the tail that were not kept.
    pub fn omittedBytes(self: *const KeptText) u32 {
        return self.total_bytes - self.head_len - self.tail_len;
    }

    pub fn set(self: *KeptText, value: []const u8) void {
        const kept = value[0..@min(value.len, std.math.maxInt(u32))];
        const cut = headTailCut(kept, max_failure_field_len);
        @memcpy(self.buf[0..cut.head_len], kept[0..cut.head_len]);
        @memcpy(self.buf[cut.head_len..][0..cut.tail_len], kept[kept.len - cut.tail_len ..]);
        self.head_len = @intCast(cut.head_len);
        self.tail_len = @intCast(cut.tail_len);
        self.total_bytes = @intCast(kept.len);
    }

    /// Keeps `prefix`, the first bytes of a value `total_bytes` long, as the
    /// head; the bytes after it count as omitted.
    fn setPrefix(self: *KeptText, prefix: []const u8, total_bytes: u32) void {
        const n = utf8PrefixLen(prefix, max_failure_field_len);
        @memcpy(self.buf[0..n], prefix[0..n]);
        self.head_len = @intCast(n);
        self.tail_len = 0;
        self.total_bytes = @max(total_bytes, @as(u32, @intCast(n)));
    }

    fn clear(self: *KeptText) void {
        self.head_len = 0;
        self.tail_len = 0;
        self.total_bytes = 0;
    }
};

/// A call that did not succeed, kept apart from the window.
pub const FailedToolCall = struct {
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    outcome: ToolCallOutcome = .rejected,
    subagent_id: u64 = 0,
    name_buf: [max_name_len]u8 = @splat(0),
    name_len: u8 = 0,
    call_id_buf: [max_call_id_len]u8 = @splat(0),
    call_id_len: u8 = 0,
    dir_buf: [max_dir_len]u8 = @splat(0),
    dir_len: u16 = 0,
    args: KeptText = .{},
    result: KeptText = .{},

    pub fn name(self: *const FailedToolCall) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn callId(self: *const FailedToolCall) []const u8 {
        return self.call_id_buf[0..self.call_id_len];
    }

    /// The folder the tool ran against: where a shell command starts when
    /// it names no `cwd`. Empty when the call never reached a tool.
    pub fn dir(self: *const FailedToolCall) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }
};

pub const HeadTailCut = struct {
    head_len: usize,
    tail_len: usize,
};

/// Splits `value` into a head and a tail that fit `budget` bytes together,
/// each cut on a UTF-8 boundary. A value that fits stays whole in the head.
pub fn headTailCut(value: []const u8, budget: usize) HeadTailCut {
    if (value.len <= budget) return .{ .head_len = value.len, .tail_len = 0 };
    const head_len = utf8PrefixLen(value, budget / 2);
    const tail_len = utf8SuffixLen(value, budget - head_len);
    return .{ .head_len = head_len, .tail_len = tail_len };
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

/// Length of the longest prefix of `value` no longer than `limit` that does
/// not end inside a UTF-8 sequence. Bytes that are not UTF-8 are cut as is.
pub fn utf8PrefixLen(value: []const u8, limit: usize) usize {
    if (value.len <= limit) return value.len;
    var end = limit;
    var steps: usize = 0;
    while (end > 0 and steps < 3 and isContinuationByte(value[end])) : (steps += 1) end -= 1;
    return if (isContinuationByte(value[end])) limit else end;
}

/// Length of the longest suffix of `value` no longer than `limit` that does
/// not start inside a UTF-8 sequence.
pub fn utf8SuffixLen(value: []const u8, limit: usize) usize {
    if (value.len <= limit) return value.len;
    var start = value.len - limit;
    var steps: usize = 0;
    while (start < value.len and steps < 3 and isContinuationByte(value[start])) : (steps += 1) start += 1;
    if (start < value.len and isContinuationByte(value[start])) return limit;
    return value.len - start;
}

pub const ToolCallRecord = struct {
    name: []const u8,
    arguments_json: []const u8,
    model_output: []const u8,
    outcome: ToolCallOutcome,
    started_at_ms: i64,
    subagent_id: u64 = 0,
    /// The provider's ID for the call, the `call_id` of its session-log records.
    call_id: []const u8 = "",
    /// The folder the tool ran against; see `FailedToolCall.dir`.
    dir: []const u8 = "",
};

pub fn omitsPayloadsForName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_fetch");
}

var mutex: std.Io.Mutex = .init;
// All-zero so the rings land in .bss instead of initialized data in the
// binary. At-rest slots are never observed: snapshots are bounded by their
// `stored` counts and records overwrite whole slots.
var ring: [ring_capacity]ToolCallMetric = std.mem.zeroes([ring_capacity]ToolCallMetric);
var head: usize = 0;
var stored: usize = 0;
var failures: [failure_ring_capacity]FailedToolCall = std.mem.zeroes([failure_ring_capacity]FailedToolCall);
var failures_head: usize = 0;
var failures_stored: usize = 0;

/// Session-wide totals, reset on session transitions via
/// `diagnostics.resetSession()`. Unlike the ring, these never evict: the
/// /trace report must answer "did anything fail all session" even after the
/// window slides.
pub const LifetimeStats = struct {
    total_calls: u64 = 0,
    outcome_counts: [@typeInfo(ToolCallOutcome).@"enum".field_names.len]u64 = @splat(0),
    total_duration_ms: u64 = 0,

    pub fn countFor(self: *const LifetimeStats, outcome: ToolCallOutcome) u64 {
        return self.outcome_counts[@backingInt(outcome)];
    }

    /// Calls this session that did not succeed.
    pub fn failureCount(self: *const LifetimeStats) u64 {
        return self.total_calls - self.countFor(.succeeded);
    }
};

var lifetime: LifetimeStats = .{};

pub fn record(call: ToolCallMetric) void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    recordLocked(call);
    if (call.outcome != .succeeded) recordMetricFailureLocked(&call);
}

fn recordLocked(call: ToolCallMetric) void {
    var stored_call = call;
    if (omitsPayloadsForName(stored_call.name())) stored_call.clearPayloads();

    ring[head] = stored_call;
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;

    lifetime.total_calls += 1;
    lifetime.outcome_counts[@backingInt(stored_call.outcome)] += 1;
    lifetime.total_duration_ms += stored_call.duration_ms;
}

/// The failure slot to fill next, the oldest once the ring is full. Callers
/// fill it in place: a kept failure is about 17 KiB.
fn nextFailureSlotLocked() *FailedToolCall {
    const slot = &failures[failures_head];
    failures_head = (failures_head + 1) % failure_ring_capacity;
    if (failures_stored < failure_ring_capacity) failures_stored += 1;
    return slot;
}

/// Writes a failed call into the failure ring from its whole arguments and
/// output.
fn recordFailureLocked(input: ToolCallRecord, duration_ms: u32) void {
    const slot = nextFailureSlotLocked();
    slot.started_at_ms = input.started_at_ms;
    slot.duration_ms = duration_ms;
    slot.outcome = input.outcome;
    slot.subagent_id = input.subagent_id;
    const name_len = @min(input.name.len, max_name_len);
    @memcpy(slot.name_buf[0..name_len], input.name[0..name_len]);
    slot.name_len = @intCast(name_len);
    const call_id_len = utf8PrefixLen(input.call_id, max_call_id_len);
    @memcpy(slot.call_id_buf[0..call_id_len], input.call_id[0..call_id_len]);
    slot.call_id_len = @intCast(call_id_len);
    const dir_len = utf8PrefixLen(input.dir, max_dir_len);
    @memcpy(slot.dir_buf[0..dir_len], input.dir[0..dir_len]);
    slot.dir_len = @intCast(dir_len);
    if (omitsPayloadsForName(input.name)) {
        slot.args.clear();
        slot.result.clear();
    } else {
        slot.args.set(input.arguments_json);
        slot.result.set(tool_result_display.contentForDisplay(input.model_output));
    }
}

/// Keeps a failure that arrives as a window metric, so every failure in the
/// window is also in the failure ring. A metric holds only the window's cuts
/// of its payloads, so the kept failure has those and no folder.
fn recordMetricFailureLocked(call: *const ToolCallMetric) void {
    const slot = nextFailureSlotLocked();
    slot.started_at_ms = call.started_at_ms;
    slot.duration_ms = call.duration_ms;
    slot.outcome = call.outcome;
    slot.subagent_id = call.subagent_id;
    slot.name_buf = call.name_buf;
    slot.name_len = call.name_len;
    slot.call_id_buf = call.call_id_buf;
    slot.call_id_len = call.call_id_len;
    slot.dir_len = 0;
    if (omitsPayloadsForName(call.name())) {
        slot.args.clear();
        slot.result.clear();
    } else {
        slot.args.setPrefix(call.args(), call.args_total_bytes);
        slot.result.setPrefix(call.result(), call.result_total_bytes);
    }
}

pub fn lifetimeStats() LifetimeStats {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    return lifetime;
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
    metric.setCallId(input.call_id);
    metric.setPayloadsForName(input.name, input.arguments_json, input.model_output);

    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    // One lock for both rings, so a snapshot never sees a failure in the
    // window that the failure ring does not hold yet.
    recordLocked(metric);
    if (input.outcome != .succeeded) recordFailureLocked(input, metric.duration_ms);
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

/// Copies the newest kept failures into `out`, oldest first.
pub fn snapshotFailures(out: []FailedToolCall) usize {
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

test "lifetime stats count every outcome and survive ring eviction" {
    resetForTest();
    defer resetForTest();

    var i: u32 = 0;
    while (i < ring_capacity + 3) : (i += 1) {
        var call: ToolCallMetric = .{
            .duration_ms = 5,
            .started_at_ms = 10_000 + @as(i64, i) * 100,
            .outcome = if (i % 4 == 0) .rejected else .succeeded,
        };
        call.setName("shell");
        record(call);
    }

    const stats = lifetimeStats();
    const total = ring_capacity + 3;
    try std.testing.expectEqual(@as(u64, total), stats.total_calls);
    try std.testing.expectEqual(@as(u64, total), stats.countFor(.succeeded) + stats.countFor(.rejected));
    try std.testing.expect(stats.countFor(.rejected) > 0);
    try std.testing.expectEqual(@as(u64, total * 5), stats.total_duration_ms);

    var buf: [ring_capacity]ToolCallMetric = undefined;
    const n = snapshot(&buf);
    try std.testing.expect(stats.total_calls > n);

    resetForTest();
    try std.testing.expectEqual(@as(u64, 0), lifetimeStats().total_calls);
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
    try std.testing.expectEqual(@as(u8, 0), @backingInt(ToolCallOutcome.succeeded));
}

fn recordTestCall(
    tool_name: []const u8,
    outcome: ToolCallOutcome,
    call_id: []const u8,
    arguments_json: []const u8,
    model_output: []const u8,
) void {
    recordResult(.{
        .name = tool_name,
        .arguments_json = arguments_json,
        .model_output = model_output,
        .outcome = outcome,
        .started_at_ms = io_mod.milliTimestamp(),
        .call_id = call_id,
        .dir = "/Users/example/project",
    });
}

fn snapshotFailuresForTest() ![]FailedToolCall {
    const out = try std.testing.allocator.alloc(FailedToolCall, failure_ring_capacity);
    return out[0..snapshotFailures(out)];
}

fn freeFailuresForTest(kept: []FailedToolCall) void {
    std.testing.allocator.free(kept.ptr[0..failure_ring_capacity]);
}

test "a failure stays kept after later successes move it out of the window" {
    resetForTest();
    defer resetForTest();

    recordTestCall("shell", .command_failed, "call_failed", "{\"command\":\"ls missing; exit 2\"}", "exit 2");
    var i: usize = 0;
    while (i < ring_capacity - 1) : (i += 1) recordTestCall("shell", .succeeded, "call_ok", "{}", "ok");

    var window: [ring_capacity]ToolCallMetric = undefined;
    // 63 later calls: the failure is still the window's oldest call.
    try std.testing.expectEqual(ring_capacity, snapshot(&window));
    try std.testing.expectEqualStrings("call_failed", window[0].callId());

    recordTestCall("shell", .succeeded, "call_ok", "{}", "ok");
    const n = snapshot(&window);
    for (window[0..n]) |call| try std.testing.expectEqual(ToolCallOutcome.succeeded, call.outcome);

    const kept = try snapshotFailuresForTest();
    defer freeFailuresForTest(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("shell", kept[0].name());
    try std.testing.expectEqualStrings("call_failed", kept[0].callId());
    try std.testing.expectEqualStrings("/Users/example/project", kept[0].dir());
    try std.testing.expectEqual(ToolCallOutcome.command_failed, kept[0].outcome);
    try std.testing.expectEqualStrings("{\"command\":\"ls missing; exit 2\"}", kept[0].args.head());
    try std.testing.expectEqual(@as(u32, 0), kept[0].args.omittedBytes());
    try std.testing.expectEqualStrings("exit 2", kept[0].result.head());
}

test "the failure ring keeps the newest failures in order" {
    resetForTest();
    defer resetForTest();

    var id_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < failure_ring_capacity + 1) : (i += 1) {
        const id = try std.mem.print(&id_buf, "f{d}", .{i});
        recordTestCall("read_file", .tool_failed, id, "{}", "missing");
    }
    try std.testing.expectEqual(@as(u64, failure_ring_capacity + 1), lifetimeStats().failureCount());

    const kept = try snapshotFailuresForTest();
    defer freeFailuresForTest(kept);
    try std.testing.expectEqual(failure_ring_capacity, kept.len);
    try std.testing.expectEqualStrings("f1", kept[0].callId());
    const last = try std.mem.print(&id_buf, "f{d}", .{failure_ring_capacity});
    try std.testing.expectEqualStrings(last, kept[kept.len - 1].callId());
}

test "kept text holds a value whole at the cap and its head and tail past it" {
    const at_cap = try std.testing.allocator.alloc(u8, max_failure_field_len + 1);
    defer std.testing.allocator.free(at_cap);
    for (at_cap, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));

    var kept: KeptText = .{};
    kept.set(at_cap[0..max_failure_field_len]);
    try std.testing.expectEqual(@as(usize, max_failure_field_len), kept.head().len);
    try std.testing.expectEqual(@as(usize, 0), kept.tail().len);
    try std.testing.expectEqual(@as(u32, 0), kept.omittedBytes());

    kept.set(at_cap);
    try std.testing.expectEqual(@as(u32, max_failure_field_len + 1), kept.total_bytes);
    try std.testing.expectEqual(@as(u32, 1), kept.omittedBytes());
    try std.testing.expect(std.mem.startsWith(u8, at_cap, kept.head()));
    try std.testing.expect(std.mem.endsWith(u8, at_cap, kept.tail()));
    try std.testing.expect(kept.head().len + kept.tail().len <= max_failure_field_len);
}

test "trace cuts never end inside a UTF-8 sequence" {
    // "é" is two bytes; the cut point falls between them.
    var value: [max_args_len + 1]u8 = undefined;
    @memset(value[0 .. max_args_len - 1], 'a');
    value[max_args_len - 1] = 0xc3;
    value[max_args_len] = 0xa9;
    try std.testing.expectEqual(@as(usize, max_args_len - 1), utf8PrefixLen(&value, max_args_len));

    var call: ToolCallMetric = .{};
    call.setArgs(&value);
    try std.testing.expectEqual(@as(u16, max_args_len - 1), call.args_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(call.args()));

    // The tail never starts with the second byte of "é".
    try std.testing.expectEqual(@as(usize, 0), utf8SuffixLen("\xc3\xa9", 1));
    try std.testing.expectEqual(@as(usize, 2), utf8SuffixLen("a\xc3\xa9", 2));
    // Bytes that are not UTF-8 are cut where the limit falls.
    try std.testing.expectEqual(@as(usize, 2), utf8PrefixLen("\x80\x80\x80\x80\x80", 2));
}

test "web_fetch failures keep no payloads" {
    resetForTest();
    defer resetForTest();

    recordTestCall("web_fetch", .tool_failed, "fetch_1", "{\"url\":\"https://example.com/private\"}", "fetched body");
    const kept = try snapshotFailuresForTest();
    defer freeFailuresForTest(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("fetch_1", kept[0].callId());
    try std.testing.expectEqual(@as(u32, 0), kept[0].args.total_bytes);
    try std.testing.expectEqual(@as(u32, 0), kept[0].result.total_bytes);
}

test "a session reset clears the failure ring" {
    resetForTest();
    defer resetForTest();

    recordTestCall("shell", .command_failed, "before_reset", "{}", "exit 1");
    reset();
    const kept = try snapshotFailuresForTest();
    defer freeFailuresForTest(kept);
    try std.testing.expectEqual(@as(usize, 0), kept.len);
    try std.testing.expectEqual(@as(u64, 0), lifetimeStats().failureCount());
}

test "a failure recorded from a window metric is kept with the window's cuts" {
    resetForTest();
    defer resetForTest();

    const long_args: [max_args_len + 10]u8 = @splat('a');
    var failed: ToolCallMetric = .{ .started_at_ms = 1000, .duration_ms = 4, .outcome = .tool_failed, .subagent_id = 2 };
    failed.setName("read_file");
    failed.setCallId("call_metric");
    failed.setArgs(&long_args);
    failed.setResult("missing");
    record(failed);
    var ok: ToolCallMetric = .{ .started_at_ms = 1001, .outcome = .succeeded };
    ok.setName("read_file");
    record(ok);

    const kept = try snapshotFailuresForTest();
    defer freeFailuresForTest(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("call_metric", kept[0].callId());
    try std.testing.expectEqualStrings("read_file", kept[0].name());
    try std.testing.expectEqual(@as(u32, 4), kept[0].duration_ms);
    try std.testing.expectEqual(@as(u64, 2), kept[0].subagent_id);
    try std.testing.expectEqualStrings("", kept[0].dir());
    try std.testing.expectEqual(max_args_len, kept[0].args.head().len);
    try std.testing.expectEqual(@as(u32, max_args_len + 10), kept[0].args.total_bytes);
    try std.testing.expectEqual(@as(u32, 10), kept[0].args.omittedBytes());
    try std.testing.expectEqualStrings("missing", kept[0].result.head());
    try std.testing.expectEqual(@as(u32, 0), kept[0].result.omittedBytes());
}

test "the rings match a reference list on seeded random sequences" {
    resetForTest();
    defer resetForTest();

    const kept_buf = try std.testing.allocator.alloc(FailedToolCall, failure_ring_capacity);
    defer std.testing.allocator.free(kept_buf);
    var window: [ring_capacity]ToolCallMetric = undefined;
    var reference: std.ArrayList(u32) = .empty;
    defer reference.deinit(std.testing.allocator);
    var reference_failures: std.ArrayList(u32) = .empty;
    defer reference_failures.deinit(std.testing.allocator);

    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        reset();
        reference.clearRetainingCapacity();
        reference_failures.clearRetainingCapacity();
        const steps = random.uintAtMost(u32, 300);
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            const roll = random.uintLessThan(u8, 100);
            if (roll == 0) {
                reset();
                reference.clearRetainingCapacity();
                reference_failures.clearRetainingCapacity();
                continue;
            }
            var id_buf: [16]u8 = undefined;
            const id = try std.mem.print(&id_buf, "c{d}", .{step});
            const outcome: ToolCallOutcome = if (roll < 40) .command_failed else .succeeded;
            recordTestCall("shell", outcome, id, "{}", "out");
            try reference.append(std.testing.allocator, step);
            if (outcome != .succeeded) try reference_failures.append(std.testing.allocator, step);
        }

        const window_n = snapshot(&window);
        const expect_window = reference.items[reference.items.len - @min(reference.items.len, ring_capacity) ..];
        try std.testing.expectEqual(expect_window.len, window_n);
        for (expect_window, window[0..window_n]) |want, got| {
            var id_buf: [16]u8 = undefined;
            try std.testing.expectEqualStrings(try std.mem.print(&id_buf, "c{d}", .{want}), got.callId());
        }

        const kept_n = snapshotFailures(kept_buf);
        const expect_kept = reference_failures.items[reference_failures.items.len - @min(reference_failures.items.len, failure_ring_capacity) ..];
        try std.testing.expectEqual(expect_kept.len, kept_n);
        for (expect_kept, kept_buf[0..kept_n]) |want, got| {
            var id_buf: [16]u8 = undefined;
            try std.testing.expectEqualStrings(try std.mem.print(&id_buf, "c{d}", .{want}), got.callId());
        }
        const stats = lifetimeStats();
        try std.testing.expectEqual(@as(u64, reference.items.len), stats.total_calls);
        try std.testing.expectEqual(@as(u64, reference_failures.items.len), stats.failureCount());
    }
}

test "head and tail cuts keep their bounds on seeded random text" {
    var buffer: [512]u8 = undefined;
    const pieces = [_][]const u8{ "a", " ", "\n", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x91\x8d", "\x80", "\xff" };
    var seed: u64 = 0;
    while (seed < 2000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var len: usize = 0;
        var valid = true;
        while (len < buffer.len - 4 and random.uintLessThan(u8, 64) != 0) {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            if (piece[0] == 0x80 or piece[0] == 0xff) valid = false;
            @memcpy(buffer[len..][0..piece.len], piece);
            len += piece.len;
        }
        try expectCutLaws(buffer[0..len], random.uintAtMost(usize, len + 8), valid);
    }
}

fn expectCutLaws(value: []const u8, budget: usize, valid_utf8: bool) !void {
    const cut = headTailCut(value, budget);
    if (value.len <= budget) {
        try std.testing.expectEqual(value.len, cut.head_len);
        try std.testing.expectEqual(@as(usize, 0), cut.tail_len);
        return;
    }
    try std.testing.expect(cut.head_len + cut.tail_len <= budget);
    try std.testing.expect(cut.head_len <= budget / 2);
    if (valid_utf8) {
        try std.testing.expect(std.unicode.utf8ValidateSlice(value[0..cut.head_len]));
        try std.testing.expect(std.unicode.utf8ValidateSlice(value[value.len - cut.tail_len ..]));
        // A valid cut loses at most three bytes on each side.
        try std.testing.expect(cut.head_len + 3 >= budget / 2);
        try std.testing.expect(cut.head_len + cut.tail_len + 3 >= budget);
    }
}

test "trace cuts stay bounded and keep UTF-8 whole on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzTraceCuts, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "plain text",
            "\xc3\xa9\xc3\xa9\xc3\xa9",
            "\xf0\x9f\x91\x8d\xf0\x9f\x91\x8d",
            "\x80\x80\xff\xc3",
        }) ++ @import("fuzz_corpus").trace_cuts.*),
    });
}

fn fuzzTraceCuts(_: void, smith: *std.testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const value = buffer[0..len];
    const budget = smith.valueRangeAtMost(u16, 0, 600);
    try expectCutLaws(value, budget, std.unicode.utf8ValidateSlice(value));

    var kept: KeptText = .{};
    kept.set(value);
    try std.testing.expect(std.mem.startsWith(u8, value, kept.head()));
    try std.testing.expect(std.mem.endsWith(u8, value, kept.tail()));
    try std.testing.expectEqual(@as(u32, @intCast(len)), kept.total_bytes);
}

test "records from many threads keep both rings bounded and in order" {
    resetForTest();
    defer resetForTest();

    const thread_count = 8;
    const per_thread = 12_500;
    // A 1 MiB value: every failed call copies its head and tail.
    const big = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');

    const Worker = struct {
        fn run(thread_index: usize, value: []const u8) void {
            var id_buf: [32]u8 = undefined;
            var seq: usize = 0;
            while (seq < per_thread) : (seq += 1) {
                const id = std.mem.print(&id_buf, "t{d}-{d}", .{ thread_index, seq }) catch unreachable;
                const outcome: ToolCallOutcome = if (seq % 3 == 0) .command_failed else .succeeded;
                recordTestCall("shell", outcome, id, value, value);
            }
        }
    };
    const Reader = struct {
        fn run(done: *std.atomic.Value(bool), errors: *std.atomic.Value(u32), kept_buf: []FailedToolCall) void {
            var window: [ring_capacity]ToolCallMetric = undefined;
            while (!done.load(.acquire)) {
                const window_n = snapshot(&window);
                if (!idsAscendPerThread(ToolCallMetric, window[0..window_n])) _ = errors.fetchAdd(1, .monotonic);
                const kept_n = snapshotFailures(kept_buf);
                if (kept_n > failure_ring_capacity) _ = errors.fetchAdd(1, .monotonic);
                if (!idsAscendPerThread(FailedToolCall, kept_buf[0..kept_n])) _ = errors.fetchAdd(1, .monotonic);
            }
        }
    };

    const kept_buf = try std.testing.allocator.alloc(FailedToolCall, failure_ring_capacity);
    defer std.testing.allocator.free(kept_buf);
    var done = std.atomic.Value(bool).init(false);
    var errors = std.atomic.Value(u32).init(0);
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ &done, &errors, kept_buf });
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ index, big });
    for (threads) |thread| thread.join();
    done.store(true, .release);
    reader.join();

    try std.testing.expectEqual(@as(u32, 0), errors.load(.monotonic));
    const stats = lifetimeStats();
    try std.testing.expectEqual(@as(u64, thread_count * per_thread), stats.total_calls);
    const failures_per_thread = (per_thread + 2) / 3;
    try std.testing.expectEqual(@as(u64, thread_count * failures_per_thread), stats.failureCount());
    const kept_n = snapshotFailures(kept_buf);
    try std.testing.expectEqual(failure_ring_capacity, kept_n);
    for (kept_buf[0..kept_n]) |call| {
        try std.testing.expectEqual(@as(u32, 1024 * 1024), call.args.total_bytes);
        try std.testing.expect(call.args.head().len + call.args.tail().len <= max_failure_field_len);
    }
}

/// Whether each thread's calls appear in the order it made them; IDs are
/// `t<thread>-<seq>`.
fn idsAscendPerThread(comptime T: type, calls: []const T) bool {
    var last: [8]?usize = @splat(null);
    for (calls) |call| {
        const id = call.callId();
        const dash = std.mem.findScalar(u8, id, '-') orelse return false;
        const thread_index = std.fmt.parseInt(usize, id[1..dash], 10) catch return false;
        const seq = std.fmt.parseInt(usize, id[dash + 1 ..], 10) catch return false;
        if (thread_index >= last.len) return false;
        if (last[thread_index]) |previous| if (seq <= previous) return false;
        last[thread_index] = seq;
    }
    return true;
}
