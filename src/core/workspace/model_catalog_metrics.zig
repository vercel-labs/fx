//! Bounded, always-on model-catalog breadcrumbs for the user-initiated
//! /trace report. Records catalog load outcomes, capability lookup misses, and
//! image gate rejections so a shared trace explains why fx could not verify a
//! model's capabilities even when FX_TRACE is off. Callers supply model slugs,
//! enum names, and internal counters only, never credentials or user prompts.
//! A second ring keeps only the failed events, so a failure stays in the
//! report however many events come after it.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const ring_capacity = 32;
/// Failed events kept apart from the window, so later events never push them
/// out.
pub const failure_ring_capacity = 32;
const max_detail_bytes = 256;

pub const Kind = enum {
    load,
    lookup,
    image_gate,
};

pub const Event = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    failed: bool = false,
    kind: Kind = .load,
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

    fn matches(self: *const Event, kind: Kind, event_detail: []const u8, failed: bool) bool {
        return self.failed == failed and
            self.kind == kind and
            std.mem.eql(u8, self.detail(), event_detail);
    }
};

fn Ring(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        events: [capacity]Event = std.mem.zeroes([capacity]Event),
        head: usize = 0,
        stored: usize = 0,
        total: u64 = 0,

        /// Stores `event` as the newest, numbered by this ring's count.
        fn append(self: *Self, event: Event) void {
            self.keep(event);
            self.events[(self.head + capacity - 1) % capacity].sequence = self.total;
        }

        /// Stores `event` as the newest with the sequence number it carries.
        fn keep(self: *Self, event: Event) void {
            self.total +|= 1;
            self.events[self.head] = event;
            self.head = (self.head + 1) % capacity;
            self.stored = @min(self.stored + 1, capacity);
        }

        fn newest(self: *const Self) ?*const Event {
            if (self.stored == 0) return null;
            return &self.events[(self.head + capacity - 1) % capacity];
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

/// Records one catalog event. Consecutive identical events collapse into the
/// newest slot so a per-turn lookup miss cannot evict rarer load and rejection
/// evidence from the bounded ring.
pub fn record(kind: Kind, failed: bool, comptime fmt: []const u8, args: anytype) void {
    var event: Event = .{
        .timestamp_ms = io_mod.milliTimestamp(),
        .failed = failed,
        .kind = kind,
    };
    var writer: std.Io.Writer = .fixed(&event.detail_buf);
    writer.print(fmt, args) catch {
        event.truncated = true;
    };
    keepDetail(&event, writer.buffered().len);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (ring.newest()) |last| {
        if (last.matches(event.kind, event.detail(), event.failed)) return;
    }
    ring.append(event);
    // Under the same lock, and with the window's sequence number, so a kept
    // failure and its line in the window carry the same `seq`.
    if (event.failed) failures.keep(ring.newest().?.*);
}

/// Cuts the formatted detail back to `max_detail_bytes`, on a UTF-8 boundary.
fn keepDetail(event: *Event, written: usize) void {
    const kept = text_utils.utf8PrefixByBytes(event.detail_buf[0..written], max_detail_bytes);
    if (kept.len < written) event.truncated = true;
    event.detail_len = @intCast(kept.len);
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
/// longer holds. A repeat that collapses into the newest event is not counted.
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

test "model catalog diagnostic ring retains the newest events in order" {
    var local: Ring(ring_capacity) = .{};
    for (0..ring_capacity + 3) |index| {
        local.append(.{ .timestamp_ms = @intCast(index) });
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

test "model catalog diagnostics stay bounded, dedup consecutive repeats, and reset" {
    reset();
    defer reset();
    record(.lookup, true, "outcome=missing_entry model={s}", .{"provider/model-a"});
    record(.lookup, true, "outcome=missing_entry model={s}", .{"provider/model-a"});
    record(.image_gate, true, "model={s} image_support=unknown err=ModelImageCapabilityUnavailable", .{"provider/model-a"});
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), snapshot(&events));
    try std.testing.expectEqualStrings("lookup", events[0].name());
    try std.testing.expect(events[0].failed);
    try std.testing.expectEqualStrings("image_gate", events[1].name());
    try std.testing.expect(events[1].detail().len > 0);

    const oversized: [max_detail_bytes + 10]u8 = @splat('x');
    record(.load, true, "{s}", .{oversized});
    try std.testing.expectEqual(@as(usize, 3), snapshot(&events));
    try std.testing.expect(events[2].truncated);
    try std.testing.expect(events[2].detail_len <= max_detail_bytes);

    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshot(&events));
    record(.load, false, "entries={d}", .{12});
    try std.testing.expectEqual(@as(usize, 1), snapshot(&events));
    try std.testing.expectEqual(@as(u64, 1), events[0].sequence);
    try std.testing.expect(!events[0].failed);
}

test "a cut catalog detail ends on a UTF-8 boundary" {
    reset();
    defer reset();
    // "é" is two bytes, and the cut falls between them.
    const head: [max_detail_bytes - 1]u8 = @splat('a');
    record(.load, true, "{s}\xc3\xa9", .{head});
    var events: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshot(&events));
    try std.testing.expect(events[0].truncated);
    try std.testing.expectEqual(@as(usize, max_detail_bytes - 1), events[0].detail().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(events[0].detail()));
}

test "a failed catalog event stays kept after later events move it out of the window" {
    reset();
    defer reset();
    record(.load, true, "outcome=failed category={s}", .{"transport"});
    for (0..ring_capacity) |index| record(.lookup, false, "outcome=missing_entry model=m{d}", .{index});

    var window: [ring_capacity]Event = undefined;
    const n = snapshot(&window);
    for (window[0..n]) |event| try std.testing.expect(!event.failed);
    var kept: [failure_ring_capacity]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshotFailures(&kept));
    try std.testing.expectEqualStrings("load", kept[0].name());
    try std.testing.expectEqualStrings("outcome=failed category=transport", kept[0].detail());
    // It keeps the window's sequence number.
    try std.testing.expectEqual(@as(u64, 1), kept[0].sequence);
    try std.testing.expectEqual(@as(u64, 1), failureCount());
}

test "a repeated catalog failure collapses in both rings" {
    reset();
    defer reset();
    record(.lookup, true, "outcome=cache_failed model={s}", .{"a"});
    record(.lookup, true, "outcome=cache_failed model={s}", .{"a"});
    var kept: [failure_ring_capacity]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshotFailures(&kept));
    try std.testing.expectEqual(@as(u64, 1), failureCount());

    // Not back to back, the repeat is a new event in both.
    record(.load, false, "outcome=ready", .{});
    record(.lookup, true, "outcome=cache_failed model={s}", .{"a"});
    try std.testing.expectEqual(@as(usize, 2), snapshotFailures(&kept));
    try std.testing.expectEqual(@as(u64, 3), kept[1].sequence);
    try std.testing.expectEqual(@as(u64, 2), failureCount());
}

test "the catalog failure ring keeps the newest failures in order and a reset clears it" {
    reset();
    defer reset();
    for (0..failure_ring_capacity + 1) |index| record(.image_gate, true, "model=m{d}", .{index});
    var kept: [failure_ring_capacity]Event = undefined;
    try std.testing.expectEqual(failure_ring_capacity, snapshotFailures(&kept));
    try std.testing.expectEqualStrings("model=m1", kept[0].detail());
    try std.testing.expectEqual(@as(u64, 2), kept[0].sequence);
    try std.testing.expectEqual(@as(u64, failure_ring_capacity + 1), kept[failure_ring_capacity - 1].sequence);
    try std.testing.expectEqual(@as(u64, failure_ring_capacity + 1), failureCount());
    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshotFailures(&kept));
    try std.testing.expectEqual(@as(u64, 0), failureCount());
}

test "the catalog rings match a reference list on seeded random sequences" {
    reset();
    defer reset();

    const Recorded = struct { failed: bool, detail: u8 };
    var window_ref: std.ArrayList(Recorded) = .empty;
    defer window_ref.deinit(std.testing.allocator);
    var failed_ref: std.ArrayList(u64) = .empty;
    defer failed_ref.deinit(std.testing.allocator);
    var window: [ring_capacity]Event = undefined;
    var kept: [failure_ring_capacity]Event = undefined;

    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        reset();
        window_ref.clearRetainingCapacity();
        failed_ref.clearRetainingCapacity();
        const steps = random.uintAtMost(u32, 300);
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            const roll = random.uintLessThan(u8, 100);
            if (roll == 0) {
                reset();
                window_ref.clearRetainingCapacity();
                failed_ref.clearRetainingCapacity();
                continue;
            }
            // Few distinct details, so back-to-back repeats happen.
            const next: Recorded = .{ .failed = roll < 40, .detail = random.uintLessThan(u8, 4) };
            record(.lookup, next.failed, "d{d}", .{next.detail});
            if (window_ref.items.len > 0) {
                const last = window_ref.items[window_ref.items.len - 1];
                if (last.failed == next.failed and last.detail == next.detail) continue;
            }
            try window_ref.append(std.testing.allocator, next);
            if (next.failed) try failed_ref.append(std.testing.allocator, window_ref.items.len);
        }

        const window_n = snapshot(&window);
        const want_n = @min(window_ref.items.len, ring_capacity);
        try std.testing.expectEqual(want_n, window_n);
        for (window[0..window_n], window_ref.items.len - want_n..) |event, sequence_index| {
            try std.testing.expectEqual(@as(u64, sequence_index + 1), event.sequence);
            try std.testing.expectEqual(window_ref.items[sequence_index].failed, event.failed);
        }
        const kept_n = snapshotFailures(&kept);
        const want_kept = failed_ref.items[failed_ref.items.len - @min(failed_ref.items.len, failure_ring_capacity) ..];
        try std.testing.expectEqual(want_kept.len, kept_n);
        for (want_kept, kept[0..kept_n]) |want, got| {
            try std.testing.expectEqual(@as(u64, want), got.sequence);
            try std.testing.expect(got.failed);
        }
        try std.testing.expectEqual(@as(u64, failed_ref.items.len), failureCount());
    }
}

test "catalog detail cuts keep their bounds on seeded random text" {
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
        // Alternate failures, so no event collapses into the one before it.
        record(.load, seed % 2 == 0, "{s}", .{value});
        _ = snapshot(&events);
        const detail = events[0].detail();
        try std.testing.expect(std.mem.startsWith(u8, value, detail));
        try std.testing.expect(detail.len <= max_detail_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(detail));
        try std.testing.expect(detail.len + 3 >= @min(value.len, max_detail_bytes));
        try std.testing.expectEqual(detail.len < value.len, events[0].truncated);
    }
}
