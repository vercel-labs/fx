//! The pure core of one terminal: its lifecycle, its queues of unsent bytes
//! and the child's exit status. It makes no syscalls and reads no clock.
//!
//! The shell (`terminal.zig`) asks the core before every fd operation and
//! every signal, and reports what the kernel did. The core refuses anything
//! its state does not allow, so the shell cannot use a closed fd, wait for
//! the child twice or signal a reaped child.
//!
//! Transitions: `queue`, `flushed`, `queueReply`, `flushedReply`,
//! `dropReplies`, `checkOpen` (before a read, write or resize), `reap`,
//! `closeStart`, `kill`, `closeFinish`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The longest reply line, without its newline.
pub const max_reply_line: usize = 16 * 1024;

/// Unsent bytes allowed at once. A child that stops reading cannot make the
/// owner buffer without bound.
const max_pending_bytes: usize = 1 << 20;
/// Unsent reply bytes allowed at once, for the same reason: room for four
/// of the longest replies.
const max_pending_reply_bytes: usize = 4 * (max_reply_line + 1);

const Phase = enum { running, closing, closed };

/// How the child ended.
pub const Exit = union(enum) {
    /// The child exited with this status.
    code: u8,
    /// A signal with this number killed the child.
    signal: u8,
};

/// Bytes waiting for an fd that would block.
const Queue = struct {
    /// Unsent bytes are `bytes.items[head..]`, oldest first.
    bytes: std.ArrayList(u8) = .empty,
    head: usize = 0,

    fn pending(self: Queue) []const u8 {
        return self.bytes.items[self.head..];
    }

    /// Appends `parts` in order, all of them or none: fails when they would
    /// grow the queue past `limit`.
    fn push(
        self: *Queue,
        gpa: Allocator,
        parts: []const []const u8,
        limit: usize,
    ) error{ QueueFull, OutOfMemory }!void {
        var len: usize = 0;
        for (parts) |part| len += part.len;
        if (len > limit - self.pending().len) return error.QueueFull;
        if (self.head > 0) {
            const rest = self.bytes.items[self.head..];
            std.mem.copyForwards(u8, self.bytes.items[0..rest.len], rest);
            self.bytes.shrinkRetainingCapacity(rest.len);
            self.head = 0;
        }
        try self.bytes.ensureUnusedCapacity(gpa, len);
        for (parts) |part| self.bytes.appendSliceAssumeCapacity(part);
    }

    /// Records that the kernel took the first `n` pending bytes.
    fn flushed(self: *Queue, n: usize) void {
        std.debug.assert(n <= self.pending().len);
        self.head += n;
        if (self.head == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.head = 0;
        }
    }

    /// Drops every pending byte and frees the storage.
    fn clear(self: *Queue, gpa: Allocator) void {
        self.bytes.clearAndFree(gpa);
        self.head = 0;
    }
};

pub const Core = struct {
    phase: Phase = .running,
    exit: ?Exit = null,
    /// Input for the PTY.
    input: Queue = .{},
    /// Reply lines for the report channel, each with its newline.
    replies: Queue = .{},

    /// Frees the queues. Safe in any phase.
    pub fn deinit(self: *Core, gpa: Allocator) void {
        self.input.bytes.deinit(gpa);
        self.replies.bytes.deinit(gpa);
        self.* = undefined;
    }

    /// Adds bytes to the end of the input queue. Fails without queueing any
    /// of them when the terminal is closing or the queue would grow past
    /// `max_pending_bytes`.
    pub fn queue(
        self: *Core,
        gpa: Allocator,
        bytes: []const u8,
    ) error{ Closed, QueueFull, OutOfMemory }!void {
        if (self.phase != .running) return error.Closed;
        return self.input.push(gpa, &.{bytes}, max_pending_bytes);
    }

    /// The input to write next, oldest first. Empty unless running.
    pub fn pending(self: Core) []const u8 {
        if (self.phase != .running) return &.{};
        return self.input.pending();
    }

    /// Records that the kernel took the first `n` pending input bytes.
    pub fn flushed(self: *Core, n: usize) void {
        std.debug.assert(self.phase == .running);
        self.input.flushed(n);
    }

    /// Adds `line` and a newline to the end of the reply queue. Fails
    /// without queueing any of it when the terminal is closing or the queue
    /// would grow past `max_pending_reply_bytes`.
    pub fn queueReply(
        self: *Core,
        gpa: Allocator,
        line: []const u8,
    ) error{ Closed, QueueFull, OutOfMemory }!void {
        if (self.phase != .running) return error.Closed;
        return self.replies.push(gpa, &.{ line, "\n" }, max_pending_reply_bytes);
    }

    /// The reply bytes to send next, oldest first. Empty unless running.
    pub fn pendingReply(self: Core) []const u8 {
        if (self.phase != .running) return &.{};
        return self.replies.pending();
    }

    /// Records that the kernel took the first `n` pending reply bytes.
    pub fn flushedReply(self: *Core, n: usize) void {
        std.debug.assert(self.phase == .running);
        self.replies.flushed(n);
    }

    /// The child's end of the report channel is closed: drops the unsent
    /// replies, which can no longer reach it.
    pub fn dropReplies(self: *Core, gpa: Allocator) void {
        std.debug.assert(self.phase == .running);
        self.replies.clear(gpa);
    }

    /// Allows one fd operation (read, write or resize) only while running.
    pub fn checkOpen(self: Core) error{Closed}!void {
        if (self.phase != .running) return error.Closed;
    }

    /// Whether the child may still be waited for: it has not been reaped.
    /// A second wait could reap an unrelated process that reused the id.
    pub fn mayWait(self: Core) bool {
        return self.exit == null;
    }

    /// Records the exit status that waiting returned.
    pub fn reap(self: *Core, exit: Exit) void {
        std.debug.assert(self.mayWait());
        self.exit = exit;
    }

    /// Starts closing: the fds are no longer usable and the unsent input
    /// and replies are dropped. Returns how many bytes were dropped.
    pub fn closeStart(self: *Core, gpa: Allocator) error{Closed}!usize {
        if (self.phase != .running) return error.Closed;
        const dropped = self.input.pending().len + self.replies.pending().len;
        self.phase = .closing;
        self.input.clear(gpa);
        self.replies.clear(gpa);
        return dropped;
    }

    /// Allows the SIGKILL that ends a close: only while closing and only
    /// before the reap, so the signal cannot reach a process that reused the
    /// child's id.
    pub fn kill(self: Core) error{ NotClosing, Reaped }!void {
        if (self.phase != .closing) return error.NotClosing;
        if (self.exit != null) return error.Reaped;
    }

    /// Finishes closing. Only allowed after the reap.
    pub fn closeFinish(self: *Core) error{ NotClosing, NotReaped }!void {
        if (self.phase != .closing) return error.NotClosing;
        if (self.exit == null) return error.NotReaped;
        self.phase = .closed;
    }
};

const testing = std.testing;

test "the queue keeps every byte in order through short writes" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    for (0..200) |_| {
        var core: Core = .{};
        defer core.deinit(gpa);
        var sent: std.ArrayList(u8) = .empty;
        defer sent.deinit(gpa);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(gpa);

        var next: u8 = 0;
        for (0..40) |_| {
            if (random.boolean()) {
                var chunk: [7]u8 = undefined;
                const len = random.intRangeAtMost(usize, 1, chunk.len);
                for (chunk[0..len]) |*byte| {
                    byte.* = next;
                    next +%= 1;
                }
                try core.queue(gpa, chunk[0..len]);
                try sent.appendSlice(gpa, chunk[0..len]);
            } else if (core.pending().len > 0) {
                const n = random.intRangeAtMost(usize, 1, core.pending().len);
                try received.appendSlice(gpa, core.pending()[0..n]);
                core.flushed(n);
            }
        }
        try received.appendSlice(gpa, core.pending());
        core.flushed(core.pending().len);

        try testing.expectEqualSlices(u8, sent.items, received.items);
        try testing.expectEqual(@as(usize, 0), core.pending().len);
    }
}

test "the queue refuses bytes past the limit without taking any" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    const big = try gpa.alloc(u8, max_pending_bytes);
    defer gpa.free(big);
    @memset(big, 'x');
    try core.queue(gpa, big);
    try testing.expectError(error.QueueFull, core.queue(gpa, "y"));
    try testing.expectEqual(max_pending_bytes, core.pending().len);

    core.flushed(1);
    try core.queue(gpa, "y");
    try testing.expectEqual(max_pending_bytes, core.pending().len);
}

test "closing drops unsent bytes and stops fd use" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    try core.queue(gpa, "abcdef");
    core.flushed(2);
    try testing.expectEqual(@as(usize, 4), try core.closeStart(gpa));

    try testing.expectError(error.Closed, core.checkOpen());
    try testing.expectError(error.Closed, core.queue(gpa, "x"));
    try testing.expectError(error.Closed, core.closeStart(gpa));
    try testing.expectEqual(@as(usize, 0), core.pending().len);
}

test "the child is reaped once and never signaled after the reap" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    try testing.expectError(error.NotClosing, core.kill());
    _ = try core.closeStart(gpa);
    try core.kill();
    try testing.expectError(error.NotReaped, core.closeFinish());

    try testing.expect(core.mayWait());
    core.reap(.{ .signal = 9 });
    try testing.expect(!core.mayWait());
    try testing.expectError(error.Reaped, core.kill());

    try core.closeFinish();
    try testing.expectEqual(Phase.closed, core.phase);
    try testing.expectEqual(Exit{ .signal = 9 }, core.exit.?);
    try testing.expectError(error.NotClosing, core.closeFinish());
}

test "a child that exits while running keeps its status through close" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    core.reap(.{ .code = 3 });
    try core.checkOpen();
    _ = try core.closeStart(gpa);
    try testing.expectError(error.Reaped, core.kill());
    try core.closeFinish();
    try testing.expectEqual(Exit{ .code = 3 }, core.exit.?);
}

test "replies queue whole lines, and close counts the unsent ones" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    try core.queueReply(gpa, "one");
    try core.queueReply(gpa, "two");
    try testing.expectEqualStrings("one\ntwo\n", core.pendingReply());
    core.flushedReply(5);
    try testing.expectEqualStrings("wo\n", core.pendingReply());

    // A reply that does not fit is refused whole.
    const long = [_]u8{'x'} ** max_reply_line;
    while (true) {
        core.queueReply(gpa, &long) catch |err| {
            try testing.expectEqual(error.QueueFull, err);
            break;
        };
    }
    const queued = core.pendingReply().len;
    try testing.expect(queued + long.len + 1 > max_pending_reply_bytes);
    try testing.expectEqual(@as(u8, '\n'), core.pendingReply()[queued - 1]);

    core.dropReplies(gpa);
    try testing.expectEqual(@as(usize, 0), core.pendingReply().len);
    try core.queueReply(gpa, "after");
    try core.queue(gpa, "in");
    try testing.expectEqual(@as(usize, "after\n".len + "in".len), try core.closeStart(gpa));
    try testing.expectEqual(@as(usize, 0), core.pendingReply().len);
    try testing.expectError(error.Closed, core.queueReply(gpa, "late"));
}

// Random runs of the core against a simulated child. After every step the
// test checks that the child is reaped once and never signaled after the
// reap, that no fd is used after close, that no queued input or reply byte
// is lost while running, that close counts every byte it drops, and that
// close finishes only after the reap.

const Child = enum { alive, dead, reaped };

/// Bytes per queued input chunk, and input chunks per run.
const chunk_len = 2;
const max_chunks = 6;

fn runRandom(gpa: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var core: Core = .{};
    defer core.deinit(gpa);
    var child: Child = .alive;
    const ignores_hup = random.boolean();
    var fd_open = true;
    var chunks: usize = 0;
    var queued: usize = 0;
    var written: usize = 0;
    var replies_queued: usize = 0;
    var replies_sent: usize = 0;
    var signaled_after_reap = false;

    var steps: usize = 0;
    while (core.phase != .closed and steps < 80) : (steps += 1) {
        switch (random.uintLessThan(u8, 11)) {
            0 => if (chunks < max_chunks) {
                const chunk = [_]u8{@intCast(chunks)} ** chunk_len;
                if (core.queue(gpa, &chunk)) {
                    chunks += 1;
                    queued += chunk_len;
                } else |err| try testing.expectEqual(error.Closed, err);
            },
            1 => if (core.pending().len > 0) {
                try core.checkOpen();
                const n = random.intRangeAtMost(usize, 1, core.pending().len);
                core.flushed(n);
                written += n;
            },
            2 => if (core.checkOpen()) {
                try testing.expect(fd_open);
            } else |_| {},
            3 => if (core.queueReply(gpa, "r")) {
                replies_queued += "r\n".len;
            } else |err| try testing.expectEqual(error.Closed, err),
            4 => if (core.pendingReply().len > 0) {
                try core.checkOpen();
                const n = random.intRangeAtMost(usize, 1, core.pendingReply().len);
                core.flushedReply(n);
                replies_sent += n;
            },
            // The shell waits only when the core allows it, and the wait
            // reaps only a child that has exited.
            5 => if (core.mayWait() and child == .dead) {
                core.reap(if (random.boolean()) .{ .code = 0 } else .{ .signal = 9 });
                child = .reaped;
            },
            6 => if (core.closeStart(gpa)) |dropped| {
                try testing.expectEqual((queued - written) + (replies_queued - replies_sent), dropped);
                fd_open = false;
            } else |_| {},
            7 => if (core.kill()) {
                if (child == .reaped) signaled_after_reap = true;
                if (child == .alive) child = .dead;
            } else |_| {},
            8 => core.closeFinish() catch {},
            // The child may exit at any time, and the hangup ends it unless
            // it ignores SIGHUP.
            else => if (child == .alive and (random.uintLessThan(u8, 4) == 0 or (!fd_open and !ignores_hup))) {
                child = .dead;
            },
        }

        try testing.expect(!signaled_after_reap);
        try testing.expect(core.phase == .running or !fd_open);
        try testing.expect(written + core.pending().len <= queued);
        if (core.phase == .running) {
            try testing.expectEqual(queued, written + core.pending().len);
            try testing.expectEqual(replies_queued, replies_sent + core.pendingReply().len);
        }
        if (core.phase == .closed) try testing.expectEqual(Child.reaped, child);
        try testing.expectEqual(child == .reaped, core.exit != null);
    }
}

test "random runs keep the terminal's lifecycle invariants" {
    for (0..64) |seed| try runRandom(testing.allocator, seed);
}
