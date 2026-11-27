//! Bounded, always-on sign-in breadcrumbs for the user-initiated `/trace`
//! report: each wait for the fx login's `auth.lock`, each refresh of the
//! saved login and its request to the issuer, and each prompt that stopped
//! for its credential. A shared trace then shows why a prompt waits for a
//! sign-in even when FX_TRACE is off. Callers supply enum and error names,
//! counts, and durations only, never a token, an account, or a prompt. A
//! second ring keeps only the failed events, so a failure stays in the report
//! however many events come after it.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const ring_capacity = 32;
/// Failed events kept apart from the window, so later events never push them
/// out.
pub const failure_ring_capacity = 32;
const max_detail_bytes = 256;

pub const Kind = enum {
    /// A wait for the fx login's `auth.lock`, which every fx process that
    /// shares the login takes before it reads, refreshes, or saves it.
    lock_wait,
    /// One refresh of the saved fx login, from taking the lock to its result.
    refresh,
    /// The request to the issuer inside a refresh.
    issuer,
    /// A prompt that stopped for its credential, or went on after a sign-in.
    prompt,
};

pub const Event = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    failed: bool = false,
    kind: Kind = .refresh,
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

/// Records one sign-in event. Any thread may call it: a prompt's refresh runs
/// on its own thread and a request's on the worker's.
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
    ring.append(event);
    // Under the same lock, and with the window's sequence number, so a kept
    // failure and its line in the window carry the same `sequence`.
    if (event.failed) failures.keep(ring.newest().?.*);
}

/// Cuts the formatted detail back to `max_detail_bytes`, on a UTF-8 boundary.
fn keepDetail(event: *Event, written: usize) void {
    const kept = text_utils.utf8PrefixByBytes(event.detail_buf[0..written], max_detail_bytes);
    if (kept.len < written) event.truncated = true;
    event.detail_len = @intCast(kept.len);
}

/// Copies the newest events into `out`, oldest first.
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

/// Events recorded this session, including any the window no longer holds.
pub fn total() u64 {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return ring.total;
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

test "sign-in events keep the newest window and every recent failure" {
    reset();
    defer reset();
    record(.refresh, true, "outcome=failed err={s}", .{"Timeout"});
    for (0..ring_capacity) |index| record(.lock_wait, false, "outcome=taken waited_ms={d}", .{index});

    var events: [ring_capacity]Event = undefined;
    try std.testing.expectEqual(@as(usize, ring_capacity), snapshot(&events));
    try std.testing.expectEqualStrings("lock_wait", events[0].name());
    try std.testing.expectEqualStrings("outcome=taken waited_ms=0", events[0].detail());
    try std.testing.expectEqual(@as(u64, 2), events[0].sequence);
    try std.testing.expectEqual(@as(u64, ring_capacity + 1), total());

    var kept: [failure_ring_capacity]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshotFailures(&kept));
    try std.testing.expectEqualStrings("refresh", kept[0].name());
    try std.testing.expectEqualStrings("outcome=failed err=Timeout", kept[0].detail());
    try std.testing.expectEqual(@as(u64, 1), kept[0].sequence);
    try std.testing.expectEqual(@as(u64, 1), failureCount());
}

test "sign-in events cut a long detail on a character boundary" {
    reset();
    defer reset();
    const long: [max_detail_bytes + 10]u8 = @splat('x');
    record(.issuer, true, "{s}", .{long});
    var events: [1]Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshot(&events));
    try std.testing.expect(events[0].truncated);
    try std.testing.expectEqual(@as(u16, max_detail_bytes), events[0].detail_len);

    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshot(&events));
    try std.testing.expectEqual(@as(u64, 0), failureCount());
}
