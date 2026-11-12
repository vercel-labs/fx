//! Bounded, always-on context-compaction breadcrumbs for the user-initiated
//! /trace report. Records the same events that the `context_compaction`
//! debug-trace scope emits so compaction decisions and failure reasons stay
//! visible even when FX_TRACE is off. Callers supply internal counters, stage
//! and enum names only, never user prompts or tool payloads; the one bounded
//! provider error detail is secret-masked and control-byte neutralized at the
//! capture site before it reaches the ring. A second ring keeps only the
//! failed events, so a failure stays in the report however many events come
//! after it.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");

const trace_scope = "context_compaction";

/// Records an informational compaction decision in the always-on ring and
/// forwards the same event to the opt-in debug-trace log unchanged.
pub fn info(ctx: debug_trace.TraceContext, comptime kind: Kind, comptime fmt: []const u8, args: anytype) void {
    record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, false, fmt, args);
    debug_trace.eventf(trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Same as `info` but marks the event as a failure so the trace report can
/// surface it under Problems.
pub fn failure(ctx: debug_trace.TraceContext, comptime kind: Kind, comptime fmt: []const u8, args: anytype) void {
    record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, true, fmt, args);
    debug_trace.eventf(trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Records a high-cadence compaction evaluation only when it changed the
/// outcome; routine no-op evaluations still reach the debug-trace log but do
/// not evict rarer events from the bounded ring.
pub fn infoIf(recorded: bool, ctx: debug_trace.TraceContext, comptime kind: Kind, comptime fmt: []const u8, args: anytype) void {
    if (recorded) record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, false, fmt, args);
    debug_trace.eventf(trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Records a free-form compaction note (no turn context available at the
/// call site) and forwards it to the debug-trace log unchanged.
pub fn log(failed: bool, comptime fmt: []const u8, args: anytype) void {
    record(.log, 0, 0, 0, failed, fmt, args);
    debug_trace.logf(trace_scope, fmt, args);
}

pub const ring_capacity = 64;
/// Failed events kept apart from the window, so later events never push them
/// out.
pub const failure_ring_capacity = 32;
const max_detail_bytes = 512;

pub const Kind = enum {
    log,
    provider_start,
    provider_completed,
    summary_transport_failed,
    summary_incomplete,
    summary_tool_call_rejected,
    summary_truncated,
    source_checkpointed,
    transaction_failed,
    credential_unauthorized,
    committed,
    decision,
    overflow_without_compaction,
    no_compactable_context,
    retention_exhausted,
    retention_forced_zero,
    installed,
    overflow_recovery_incomplete,
    provider_overflow_recovery,
    provider_block_failed,
};

pub const Event = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    turn_id: u64 = 0,
    step_id: u64 = 0,
    subagent_id: u64 = 0,
    failed: bool = false,
    kind: Kind = .log,
    detail_len: u16 = 0,
    truncated: bool = false,
    /// One byte longer than the kept detail, so a cut can see whether the
    /// next byte continues a UTF-8 sequence.
    detail_buf: [max_detail_bytes + 1]u8 = @splat(0),

    pub fn name(self: *const Event) []const u8 {
        return @tagName(self.kind);
    }

    pub fn detail(self: *const Event) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }
};

fn Ring(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        events: [capacity]Event = std.mem.zeroes([capacity]Event),
        head: usize = 0,
        stored: usize = 0,
        total: u64 = 0,

        /// Stores `event` as the newest, numbered by this ring's count, and
        /// returns the stored copy.
        fn append(self: *Self, event: *const Event) *const Event {
            const slot = self.keep(event);
            slot.sequence = self.total;
            return slot;
        }

        /// Stores `event` as the newest with the sequence number it carries.
        fn keep(self: *Self, event: *const Event) *Event {
            self.total +|= 1;
            const slot = &self.events[self.head];
            slot.* = event.*;
            self.head = (self.head + 1) % capacity;
            self.stored = @min(self.stored + 1, capacity);
            return slot;
        }

        fn snapshot(self: *const Self, out: []Event) usize {
            const count = @min(self.stored, out.len);
            for (out[0..count], 0..) |*event, index| {
                event.* = self.events[(self.head + capacity - count + index) % capacity];
            }
            return count;
        }

        fn clear(self: *Self) void {
            self.head = 0;
            self.stored = 0;
            self.total = 0;
        }
    };
}

var mutex: std.Io.Mutex = .init;
// Zero-initialized storage stays in .bss; unused slots are never read.
var ring: Ring(ring_capacity) = std.mem.zeroes(Ring(ring_capacity));
var failures: Ring(failure_ring_capacity) = std.mem.zeroes(Ring(failure_ring_capacity));

// Keep format specialization at the caller while sharing ring mutation without
// adding another Event-sized stack copy.
inline fn record(kind: Kind, turn_id: u64, step_id: u64, subagent_id: u64, failed: bool, comptime fmt: []const u8, args: anytype) void {
    var recorded: Event = .{
        .timestamp_ms = io_mod.milliTimestamp(),
        .turn_id = turn_id,
        .step_id = step_id,
        .subagent_id = subagent_id,
        .failed = failed,
        .kind = kind,
    };
    var writer: std.Io.Writer = .fixed(&recorded.detail_buf);
    writer.print(fmt, args) catch {
        recorded.truncated = true;
    };
    recorded.detail_len = @intCast(writer.buffered().len);
    append_recorded_event(&recorded);
}

noinline fn append_recorded_event(event: *Event) void {
    // The detail may hold the look-ahead byte; cut it back on a UTF-8
    // boundary before it is stored.
    const kept = text_utils.utf8PrefixByBytes(event.detail(), max_detail_bytes);
    if (kept.len < event.detail_len) event.truncated = true;
    event.detail_len = @intCast(kept.len);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const newest = ring.append(event);
    // Under the same lock, and with the window's sequence number, so a kept
    // failure and its line in the window carry the same number.
    if (event.failed) _ = failures.keep(newest);
}

pub fn snapshot(out: []Event) usize {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return ring.snapshot(out);
}

/// Copies the newest kept failed events into `out`, oldest first. Later
/// events never remove them; only newer failures and `reset` do.
pub fn snapshotFailures(out: []Event) usize {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return failures.snapshot(out);
}

/// Failed events recorded this session, including any the failure ring no
/// longer holds.
pub fn failureCount() u64 {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return failures.total;
}

pub fn reset() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.clear();
    failures.clear();
}

test "compaction diagnostic ring retains the newest events in order" {
    var local: Ring(ring_capacity) = .{};
    for (0..ring_capacity + 3) |index| {
        _ = local.append(&.{ .timestamp_ms = @intCast(index) });
    }
    var events: [ring_capacity]Event = undefined;
    try std.testing.expectEqual(ring_capacity, local.snapshot(&events));
    try std.testing.expectEqual(@as(u64, 4), events[0].sequence);
    try std.testing.expectEqual(@as(i64, 3), events[0].timestamp_ms);
    try std.testing.expectEqual(@as(u64, ring_capacity + 3), events[ring_capacity - 1].sequence);
    var tail: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), local.snapshot(&tail));
    try std.testing.expectEqual(@as(u64, ring_capacity + 2), tail[0].sequence);
    try std.testing.expectEqual(@as(usize, 0), local.snapshot(&.{}));
}

test "compaction diagnostics stay bounded and reset without file tracing" {
    reset();
    defer reset();
    record(.decision, 7, 3, 0, false, "automatic_threshold tokens={d}/{d}", .{ 279466, 280000 });
    const oversized: [max_detail_bytes + 10]u8 = @splat('x');
    record(.retention_exhausted, 7, 4, 0, true, "{s}", .{oversized});
    var events: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), snapshot(&events));
    try std.testing.expectEqualStrings("decision", events[0].name());
    try std.testing.expectEqualStrings("automatic_threshold tokens=279466/280000", events[0].detail());
    try std.testing.expect(!events[0].failed);
    try std.testing.expectEqual(@as(u64, 7), events[0].turn_id);
    try std.testing.expectEqual(@as(u64, 3), events[0].step_id);
    try std.testing.expectEqualStrings("retention_exhausted", events[1].name());
    try std.testing.expect(events[1].failed);
    try std.testing.expect(events[1].truncated);
    try std.testing.expect(events[1].detail_len <= max_detail_bytes);
    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshot(&events));
    record(.installed, 8, 0, 0, false, "kept_users={d}", .{3});
    try std.testing.expectEqual(@as(usize, 1), snapshot(&events));
    try std.testing.expectEqual(@as(u64, 1), events[0].sequence);
}

test "a cut compaction detail ends on a UTF-8 boundary" {
    reset();
    defer reset();
    // "é" is two bytes, and the cut falls between them.
    const head: [max_detail_bytes - 1]u8 = @splat('a');
    record(.summary_transport_failed, 2, 0, 0, true, "{s}\xc3\xa9", .{head});
    var events: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshot(&events));
    try std.testing.expect(events[0].truncated);
    try std.testing.expectEqual(@as(usize, max_detail_bytes - 1), events[0].detail().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(events[0].detail()));
}

test "a failed compaction event stays kept after later events move it out of the window" {
    reset();
    defer reset();
    record(.summary_transport_failed, 3, 1, 0, true, "err={s}", .{"ConnectionResetByPeer"});
    for (0..ring_capacity) |index| record(.decision, 4, index, 0, false, "decision=compact index={d}", .{index});

    var window: [ring_capacity]Event = undefined;
    const n = snapshot(&window);
    for (window[0..n]) |event| try std.testing.expect(!event.failed);
    var kept: [failure_ring_capacity]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshotFailures(&kept));
    try std.testing.expectEqualStrings("summary_transport_failed", kept[0].name());
    try std.testing.expectEqualStrings("err=ConnectionResetByPeer", kept[0].detail());
    try std.testing.expectEqual(@as(u64, 3), kept[0].turn_id);
    // It keeps the window's sequence number.
    try std.testing.expectEqual(@as(u64, 1), kept[0].sequence);
    try std.testing.expectEqual(@as(u64, 1), failureCount());
}

test "an event recorded as information is not kept as a failure" {
    reset();
    defer reset();
    // A cancelled compaction records transaction_failed through `info`.
    info(.{ .turn_id = 2 }, .transaction_failed, "stage={s} err={s}", .{ "preparation", "Cancelled" });
    log(false, "room after compaction after_tokens={d}", .{10});
    log(true, "unsettled operation at worker finish turn_id={d}", .{2});
    var kept: [failure_ring_capacity]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshotFailures(&kept));
    try std.testing.expectEqualStrings("log", kept[0].name());
    try std.testing.expectEqual(@as(u64, 3), kept[0].sequence);
}

test "the compaction failure ring keeps the newest failures in order and a reset clears it" {
    reset();
    defer reset();
    for (0..failure_ring_capacity + 1) |index| record(.retention_exhausted, index, 0, 0, true, "estimated_tokens={d}", .{index});
    var kept: [failure_ring_capacity]Event = undefined;
    try std.testing.expectEqual(failure_ring_capacity, snapshotFailures(&kept));
    try std.testing.expectEqual(@as(u64, 1), kept[0].turn_id);
    try std.testing.expectEqual(@as(u64, failure_ring_capacity), kept[failure_ring_capacity - 1].turn_id);
    try std.testing.expectEqual(@as(u64, failure_ring_capacity + 1), failureCount());
    var small: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), snapshotFailures(&small));
    try std.testing.expectEqual(@as(u64, failure_ring_capacity - 1), small[0].turn_id);
    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshotFailures(&kept));
    try std.testing.expectEqual(@as(u64, 0), failureCount());
}

test "the compaction rings match a reference list on seeded random sequences" {
    reset();
    defer reset();

    var all: std.ArrayList(u64) = .empty;
    defer all.deinit(std.testing.allocator);
    var failed: std.ArrayList(u64) = .empty;
    defer failed.deinit(std.testing.allocator);
    var window: [ring_capacity]Event = undefined;
    var kept: [failure_ring_capacity]Event = undefined;

    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        reset();
        all.clearRetainingCapacity();
        failed.clearRetainingCapacity();
        const steps = random.uintAtMost(u64, 400);
        var step: u64 = 1;
        while (step <= steps) : (step += 1) {
            const roll = random.uintLessThan(u8, 100);
            if (roll == 0) {
                reset();
                all.clearRetainingCapacity();
                failed.clearRetainingCapacity();
                continue;
            }
            const is_failure = roll < 30;
            // `step_id` names the event.
            record(.decision, 1, step, 0, is_failure, "step={d}", .{step});
            try all.append(std.testing.allocator, step);
            if (is_failure) try failed.append(std.testing.allocator, step);
        }

        const window_n = snapshot(&window);
        const want_window = all.items[all.items.len - @min(all.items.len, ring_capacity) ..];
        try std.testing.expectEqual(want_window.len, window_n);
        for (want_window, window[0..window_n]) |want, got| try std.testing.expectEqual(want, got.step_id);
        const kept_n = snapshotFailures(&kept);
        const want_kept = failed.items[failed.items.len - @min(failed.items.len, failure_ring_capacity) ..];
        try std.testing.expectEqual(want_kept.len, kept_n);
        for (want_kept, kept[0..kept_n]) |want, got| try std.testing.expectEqual(want, got.step_id);
        try std.testing.expectEqual(@as(u64, failed.items.len), failureCount());
    }
}

test "compaction detail cuts keep their bounds on seeded random text" {
    reset();
    defer reset();
    var buffer: [max_detail_bytes * 2]u8 = undefined;
    const pieces = [_][]const u8{ "a", " ", "=", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x91\x8d" };
    var events: [1]Event = undefined;
    var seed: u64 = 0;
    while (seed < 2000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var len: usize = 0;
        const target = random.uintAtMost(usize, buffer.len - 4);
        while (len < target) {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            @memcpy(buffer[len..][0..piece.len], piece);
            len += piece.len;
        }
        const value = buffer[0..len];
        record(.summary_incomplete, 1, 0, 0, true, "{s}", .{value});
        _ = snapshot(&events);
        const detail = events[0].detail();
        try std.testing.expect(std.mem.startsWith(u8, value, detail));
        try std.testing.expect(detail.len <= max_detail_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(detail));
        try std.testing.expect(detail.len + 3 >= @min(value.len, max_detail_bytes));
        try std.testing.expectEqual(detail.len < value.len, events[0].truncated);
    }
}

test "a compaction detail of bytes that are not UTF-8 is cut inside its buffer" {
    reset();
    defer reset();
    const garbage: [max_detail_bytes + 8]u8 = @splat(0x80);
    record(.summary_incomplete, 1, 0, 0, true, "ab{s}", .{garbage});
    var events: [1]Event = undefined;
    _ = snapshot(&events);
    // The cut moves back over every byte that continues a sequence, and
    // over the byte they follow.
    try std.testing.expectEqualStrings("a", events[0].detail());
    try std.testing.expect(events[0].truncated);
}
