//! Bounded, always-on renderer breadcrumbs for the user-initiated /trace report.
//! Callers supply internal state and counters, never transcript or input payloads.
const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const ring_capacity = 256;
const max_detail_bytes = 512;

pub const Kind = enum {
    source_rewrite,
    source_invalidated,
    history_projection,
    transition,
    commit,
    reset,
    redraw,
    resize,
};

pub const Event = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    kind: Kind = .source_rewrite,
    detail_len: u16 = 0,
    truncated: bool = false,
    detail_buf: [max_detail_bytes]u8 = @splat(0),

    pub fn detail(self: *const Event) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }
};

const Ring = struct {
    events: [ring_capacity]Event = std.mem.zeroes([ring_capacity]Event),
    head: usize = 0,
    stored: usize = 0,
    total: u64 = 0,

    fn append(self: *Ring, event: Event) void {
        self.total +|= 1;
        self.events[self.head] = event;
        self.events[self.head].sequence = self.total;
        self.head = (self.head + 1) % ring_capacity;
        self.stored = @min(self.stored + 1, ring_capacity);
    }

    fn snapshot(self: *const Ring, out: []Event) usize {
        const count = @min(self.stored, out.len);
        for (out[0..count], 0..) |*event, index| {
            event.* = self.events[(self.head + ring_capacity - count + index) % ring_capacity];
        }
        return count;
    }
};

var mutex: std.Io.Mutex = .init;
// Zero-initialized storage stays in .bss; unused slots are never read.
var ring: Ring = std.mem.zeroes(Ring);

pub fn record(kind: Kind, comptime fmt: []const u8, args: anytype) void {
    var event: Event = .{ .kind = kind, .timestamp_ms = io_mod.milliTimestamp() };
    var writer: std.Io.Writer = .fixed(&event.detail_buf);
    writer.print(fmt, args) catch {
        event.truncated = true;
    };
    event.detail_len = @intCast(writer.buffered().len);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.append(event);
}

pub fn snapshot(out: []Event) usize {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return ring.snapshot(out);
}

pub fn reset() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.head = 0;
    ring.stored = 0;
    ring.total = 0;
}

test "render diagnostic ring retains the newest events in order" {
    var local: Ring = .{};
    for (0..ring_capacity + 3) |index| {
        local.append(.{ .timestamp_ms = @intCast(index), .kind = .commit });
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

test "render diagnostics are bounded and reset without enabling file tracing" {
    reset();
    defer reset();
    record(.source_rewrite, "view={d} history={d}", .{ 20, 17 });
    const oversized: [max_detail_bytes + 10]u8 = @splat('x');
    record(.transition, "{s}", .{oversized});
    var events: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), snapshot(&events));
    try std.testing.expectEqualStrings("view=20 history=17", events[0].detail());
    try std.testing.expect(!events[0].truncated);
    try std.testing.expect(events[1].truncated);
    try std.testing.expect(events[1].detail_len <= max_detail_bytes);
    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshot(&events));
    record(.reset, "terminal_reset", .{});
    try std.testing.expectEqual(@as(usize, 1), snapshot(&events));
    try std.testing.expectEqual(@as(u64, 1), events[0].sequence);
}
