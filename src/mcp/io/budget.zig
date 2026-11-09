//! A connection's byte budget. Its readers wait for room before
//! they post a message, and the host gives the bytes back when it takes the
//! message off the queue, so one server keeps at most one largest message
//! waiting for the host however fast it sends. Readers wait first come,
//! first served, so small messages never starve a large one, and a reader
//! cancelled while it waits leaves the line. Spec: Backpressure.tla.
//!
//! An HTTP reader counts what it reads, not only what it posts: its
//! first `allowance` bytes are free, and past them it needs the one large
//! read, taken in the same line, and counts each `allowance`-sized step as
//! it reads it. A small message leaves the large read room for its next step
//! and its allowance, so the large read never starves, and only it holds
//! bytes counted but not posted, so no two readers wait for each other. What
//! a connection holds is then set by `max`, not by how many messages come at
//! once: `max` counted, the spare, each reader's allowance, and the
//! allocator's growth slack. The stdio reader, alone on its connection,
//! reads a line whole and posts it with `copy`.
//!
//! A large message's buffer is kept for the next one: macOS keeps a freed
//! 16 MiB block resident instead of reusing it, so copying each message into
//! a new one grew fx by every message a server sent.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Buffers from this size up are kept for reuse.
const spare_min = 64 * 1024;

/// A reader's message as it is read. Starts empty; `post` or `drop`
/// ends it, and on any error from `grow` or `post` it still needs `drop`.
pub const Read = struct {
    /// The most its buffer has held.
    held: usize = 0,
    /// What of `held` the budget counts: the large read's, past its allowance.
    counted: usize = 0,
    large: bool = false,
    node: std.DoublyLinkedList.Node = .{},
};

pub const Budget = struct {
    mutex: Io.Mutex = .init,
    room: Io.Condition = .init,
    /// The waiting readers, oldest first.
    line: std.DoublyLinkedList = .{},
    used: usize = 0,
    max: usize,
    /// What a reader holds before it counts, and the most `grow` may add at
    /// once.
    allowance: usize = 64 * 1024,
    /// The reader with the large read.
    large: ?*Read = null,
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

    /// Before `r`'s buffer holds `held` bytes, at most `allowance` more than
    /// before. Within the allowance it costs nothing; past it `r` waits in
    /// line for the large read, then for room, and counts the new bytes.
    pub fn grow(b: *Budget, io: Io, r: *Read, held: usize) Io.Cancelable!void {
        if (held <= r.held) return;
        if (held <= b.allowance) {
            r.held = held;
            return;
        }
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        if (!r.large) {
            b.line.append(&r.node);
            defer {
                b.line.remove(&r.node);
                b.room.broadcast(io);
            }
            while (b.line.first != &r.node or b.large != null) try b.room.wait(io, &b.mutex);
            b.large = r;
            r.large = true;
        }
        const more = held - @max(r.held, b.allowance);
        while (b.used + more > b.max) try b.room.wait(io, &b.mutex);
        b.used += more;
        r.counted += more;
        r.held = held;
    }

    /// Posts `r`'s message of `len` bytes, which the host gives back when it
    /// takes it. A small one goes in turn and leaves the large read its next
    /// step and its allowance; the large read counts its allowance too.
    pub fn post(b: *Budget, io: Io, r: *Read, len: usize) Io.Cancelable!void {
        try b.mutex.lock(io);
        defer b.mutex.unlock(io);
        if (r.large) {
            while (b.used - r.counted + len > b.max) try b.room.wait(io, &b.mutex);
            b.used = b.used - r.counted + len;
            b.large = null;
        } else {
            b.line.append(&r.node);
            defer b.line.remove(&r.node);
            while (b.line.first != &r.node or b.used + len + b.reserve() > b.max) try b.room.wait(io, &b.mutex);
            b.used += len;
        }
        r.* = .{};
        b.room.broadcast(io);
    }

    /// Ends `r` without posting: the large read gives back what it counted.
    pub fn drop(b: *Budget, io: Io, r: *Read) void {
        if (r.large) {
            b.mutex.lockUncancelable(io);
            defer b.mutex.unlock(io);
            b.used -= r.counted;
            b.large = null;
            b.room.broadcast(io);
        }
        r.* = .{};
    }

    /// The room a small message leaves the large read.
    fn reserve(b: *const Budget) usize {
        return if (b.large != null) 2 * b.allowance else 0;
    }

    /// Moves what `list` holds into the spare when the spare is larger, so a
    /// large read reuses the last large buffer (see `recycle`).
    pub fn adopt(b: *Budget, io: Io, gpa: Allocator, list: *std.ArrayList(u8)) void {
        const s = b.swap(io, null) orelse return;
        if (s.len <= list.capacity) return b.recycle(io, gpa, s);
        @memcpy(s[0..list.items.len], list.items);
        const len = list.items.len;
        list.deinit(gpa);
        list.* = .fromOwnedSlice(s);
        list.items.len = len;
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

fn growThenMark(b: *Budget, r: *Read, held: usize, done: *std.atomic.Value(bool)) Io.Cancelable!void {
    try b.grow(testing.io, r, held);
    done.store(true, .release);
}

fn postThenMark(b: *Budget, r: *Read, len: usize, done: *std.atomic.Value(bool)) Io.Cancelable!void {
    try b.post(testing.io, r, len);
    done.store(true, .release);
}

test "a read within its allowance never waits, even with the budget full" {
    var b: Budget = .{ .max = 16, .allowance = 4 };
    try b.take(testing.io, 16);
    var r: Read = .{};
    try b.grow(testing.io, &r, 4);
    try testing.expectEqual(@as(usize, 16), b.used);
    try testing.expect(!r.large and b.large == null);
}

test "one reader at a time reads past its allowance, and the next waits until it posts" {
    var b: Budget = .{ .max = 64, .allowance = 4 };
    var first: Read = .{};
    try b.grow(testing.io, &first, 4);
    try b.grow(testing.io, &first, 8);
    try testing.expect(first.large and b.used == 4);
    var second: Read = .{};
    try b.grow(testing.io, &second, 4);
    var second_done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(growThenMark, .{ &b, &second, 6, &second_done });
    defer task.cancel(testing.io) catch {};
    settle();
    try testing.expect(!second_done.load(.acquire));
    try b.post(testing.io, &first, 8);
    try testing.expect(doneWithin(&second_done, 2_000));
    try testing.expect(second.large);
    // The first's message, and the second's two bytes past its allowance.
    try testing.expectEqual(@as(usize, 10), b.used);
}

test "a small message leaves the large read room for its next step and its allowance" {
    var b: Budget = .{ .max = 16, .allowance = 2 };
    var large: Read = .{};
    try b.grow(testing.io, &large, 2);
    try b.grow(testing.io, &large, 4);
    try testing.expectEqual(@as(usize, 2), b.used);
    var small: Read = .{};
    // Five small ones fit with the reserve of 4 left: 2 + 5 * 2 + 4 = 16.
    for (0..5) |_| {
        try b.grow(testing.io, &small, 2);
        try b.post(testing.io, &small, 2);
    }
    // A sixth would leave less than the reserve: it waits.
    try b.grow(testing.io, &small, 2);
    var small_done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(postThenMark, .{ &b, &small, 2, &small_done });
    var task_ended = false;
    defer if (!task_ended) task.cancel(testing.io) catch {};
    settle();
    try testing.expect(!small_done.load(.acquire));
    // The large read goes on and posts without waiting.
    try b.grow(testing.io, &large, 6);
    try b.post(testing.io, &large, 6);
    try testing.expectEqual(@as(usize, 16), b.used);
    settle();
    try testing.expect(!small_done.load(.acquire));
    // Once the host takes a message, the small one fits.
    b.give(testing.io, 2);
    try testing.expect(doneWithin(&small_done, 2_000));
    task_ended = true;
    try task.await(testing.io);
    try testing.expectEqual(@as(usize, 16), b.used);
}

test "a large read cancelled while it waits for room gives back what it counted, and the next takes the large read" {
    var b: Budget = .{ .max = 8, .allowance = 2 };
    try b.take(testing.io, 4);
    var first: Read = .{};
    try b.grow(testing.io, &first, 2);
    try b.grow(testing.io, &first, 4);
    try b.grow(testing.io, &first, 6);
    try testing.expectEqual(@as(usize, 8), b.used);
    var first_done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(growThenMark, .{ &b, &first, 8, &first_done });
    var task_ended = false;
    defer if (!task_ended) task.cancel(testing.io) catch {};
    settle();
    try testing.expect(!first_done.load(.acquire));
    task_ended = true;
    try testing.expectError(error.Canceled, task.cancel(testing.io));
    b.drop(testing.io, &first);
    try testing.expectEqual(@as(usize, 4), b.used);
    try testing.expect(b.large == null);
    var second: Read = .{};
    try b.grow(testing.io, &second, 2);
    try b.grow(testing.io, &second, 4);
    try testing.expect(second.large);
    b.drop(testing.io, &second);
    try testing.expectEqual(@as(usize, 4), b.used);
}

test "the large read posts once there is room for its allowance too" {
    var b: Budget = .{ .max = 8, .allowance = 2 };
    try b.take(testing.io, 6);
    var large: Read = .{};
    try b.grow(testing.io, &large, 2);
    try b.grow(testing.io, &large, 4);
    try testing.expectEqual(@as(usize, 8), b.used);
    // Its message of 4 with the host's 6 is 10: more than the budget.
    var done: std.atomic.Value(bool) = .init(false);
    var task = try testing.io.concurrent(postThenMark, .{ &b, &large, 4, &done });
    var task_ended = false;
    defer if (!task_ended) task.cancel(testing.io) catch {};
    settle();
    try testing.expect(!done.load(.acquire));
    b.give(testing.io, 6);
    try testing.expect(doneWithin(&done, 2_000));
    task_ended = true;
    try task.await(testing.io);
    try testing.expectEqual(@as(usize, 4), b.used);
}
