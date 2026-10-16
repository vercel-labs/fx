//! A connection's byte budget. Its readers wait for room before
//! they post a message, and the host gives the bytes back when it takes the
//! message off the queue, so one server keeps at most one largest message
//! waiting for the host however fast it sends. Readers wait first come,
//! first served, so small messages never starve a large one, and a reader
//! cancelled while it waits leaves the line. Spec: Backpressure.tla.
//!
//! A large message's buffer is kept for the next one: macOS keeps a freed
//! 16 MiB block resident instead of reusing it, so copying each message into
//! a new one grew fx by every message a server sent.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Buffers from this size up are kept for reuse.
const spare_min = 64 * 1024;

pub const Budget = struct {
    mutex: Io.Mutex = .init,
    room: Io.Condition = .init,
    /// The waiting readers, oldest first.
    line: std.DoublyLinkedList = .{},
    used: usize = 0,
    max: usize,
    /// The largest buffer recycled since one was last reused.
    spare: ?[]u8 = null,

    pub fn deinit(b: *Budget, gpa: Allocator) void {
        if (b.spare) |s| gpa.free(s);
        b.spare = null;
    }

    /// Waits until `n` bytes fit, then counts them. Once nothing is held any
    /// one message goes, so a message of up to `max` never waits for ever.
    pub fn take(b: *Budget, io: Io, n: usize) Io.Cancelable!void {
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        var me: std.DoublyLinkedList.Node = .{};
        b.line.append(&me);
        defer {
            b.line.remove(&me);
            // The next in line may fit now.
            b.room.broadcast(io);
        }
        while (b.line.first != &me or (b.used != 0 and b.used + n > b.max)) try b.room.wait(io, &b.mutex);
        b.used += n;
    }

    /// Waits for room for `bytes`, then copies them, into the spare when they
    /// fit; null, with the room given back, when memory runs out.
    pub fn copy(b: *Budget, io: Io, gpa: Allocator, bytes: []const u8) Io.Cancelable!?[]u8 {
        try b.take(io, bytes.len);
        if (bytes.len >= spare_min) if (b.swap(io, null)) |s| {
            if (gpa.resize(s, bytes.len)) {
                const out = s.ptr[0..bytes.len];
                @memcpy(out, bytes);
                return out;
            }
            gpa.free(s);
        };
        return gpa.dupe(u8, bytes) catch {
            b.give(io, bytes.len);
            return null;
        };
    }

    /// Frees `bytes`, a buffer from `gpa`, or keeps it as the spare when it
    /// is large and the larger.
    pub fn recycle(b: *Budget, io: Io, gpa: Allocator, bytes: []u8) void {
        if (bytes.len < spare_min) return gpa.free(bytes);
        b.mutex.lockUncancelable(io);
        const keep = if (b.spare) |s| bytes.len >= s.len else true;
        const out = if (keep) b.spare else bytes;
        if (keep) b.spare = bytes;
        b.mutex.unlock(io);
        if (out) |o| gpa.free(o);
    }

    fn swap(b: *Budget, io: Io, next: ?[]u8) ?[]u8 {
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        const old = b.spare;
        b.spare = next;
        return old;
    }

    /// Gives back `n` bytes taken before.
    pub fn give(b: *Budget, io: Io, n: usize) void {
        if (n == 0) return;
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        b.used -= n;
        b.room.broadcast(io);
    }
};

const testing = std.testing;

fn takeThenMark(b: *Budget, n: usize, done: *std.atomic.Value(bool)) Io.Cancelable!void {
    try b.take(testing.io, n);
    done.store(true, .release);
}

/// Long enough for a started reader to reach its wait.
fn settle() void {
    Io.sleep(testing.io, .fromMilliseconds(50), .awake) catch {};
}

/// Whether `done` is set within `ms`: a reader that never wakes fails a test
/// instead of hanging it.
fn doneWithin(done: *std.atomic.Value(bool), ms: u32) bool {
    var waited: u32 = 0;
    while (!done.load(.acquire)) : (waited += 10) {
        if (waited >= ms) return false;
        Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return true;
}

test "a message over the budget goes once nothing is held, and one that fits waits behind it" {
    var b: Budget = .{ .max = 16 };
    try b.take(testing.io, 8);
    var big_done: std.atomic.Value(bool) = .init(false);
    var big = try testing.io.concurrent(takeThenMark, .{ &b, 20, &big_done });
    defer big.cancel(testing.io) catch {};
    settle();
    var small_done: std.atomic.Value(bool) = .init(false);
    var small = try testing.io.concurrent(takeThenMark, .{ &b, 4, &small_done });
    defer small.cancel(testing.io) catch {};
    settle();
    // Four more would fit, but the large one came first.
    try testing.expect(!big_done.load(.acquire) and !small_done.load(.acquire));
    b.give(testing.io, 8);
    try testing.expect(doneWithin(&big_done, 2_000));
    settle();
    try testing.expect(!small_done.load(.acquire));
    b.give(testing.io, 20);
    try testing.expect(doneWithin(&small_done, 2_000));
    try testing.expectEqual(@as(usize, 4), b.used);
}

test "a large message's buffer is reused for the next, and a small one is freed" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counting.allocator();
    var b: Budget = .{ .max = 1 << 20 };
    defer b.deinit(gpa);
    const big: [200 * 1024]u8 = @splat('a');
    const first = (try b.copy(testing.io, gpa, &big)).?;
    b.give(testing.io, first.len);
    b.recycle(testing.io, gpa, first);
    try testing.expectEqual(@as(usize, 0), counting.deallocations);
    // The spare is resized in place, not freed and allocated again.
    const next = (try b.copy(testing.io, gpa, big[0 .. 150 * 1024])).?;
    try testing.expectEqual(@as(usize, 1), counting.allocations);
    try testing.expectEqual(@as(usize, 150 * 1024), next.len);
    try testing.expect(b.spare == null);
    b.give(testing.io, next.len);
    b.recycle(testing.io, gpa, next);
    const small = (try b.copy(testing.io, gpa, "small")).?;
    try testing.expect(b.spare != null);
    b.give(testing.io, small.len);
    b.recycle(testing.io, gpa, small);
    try testing.expectEqual(@as(usize, 0), b.used);
}

test "a reader cancelled while it waits leaves the line, and the one behind it goes" {
    var b: Budget = .{ .max = 16 };
    try b.take(testing.io, 12);
    var first_done: std.atomic.Value(bool) = .init(false);
    var first = try testing.io.concurrent(takeThenMark, .{ &b, 16, &first_done });
    // Cancelled below; on an earlier failure, here, so no reader outlives the test.
    var first_ended = false;
    defer if (!first_ended) first.cancel(testing.io) catch {};
    settle();
    var second_done: std.atomic.Value(bool) = .init(false);
    var second = try testing.io.concurrent(takeThenMark, .{ &b, 4, &second_done });
    defer second.cancel(testing.io) catch {};
    settle();
    try testing.expect(!second_done.load(.acquire));
    first_ended = true;
    try testing.expectError(error.Canceled, first.cancel(testing.io));
    try testing.expect(doneWithin(&second_done, 2_000));
    try testing.expect(!first_done.load(.acquire));
    try testing.expectEqual(@as(usize, 16), b.used);
}
