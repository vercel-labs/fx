//! The pure core of a terminal's report channel: complete lines framed out
//! of reads of any size.
//!
//! A line ends at a newline, which is not part of it. A line longer than
//! `limit` is dropped whole, up to and including its newline, and so is a
//! line that cannot be buffered. When the writer is gone, `end` drops a
//! partial last line. So the owner only ever sees lines the child finished,
//! and `dropped` counts every line it does not see.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The longest report line delivered, newline excluded.
pub const max_line = 1 << 20;

pub const Emit = struct {
    ctx: *anyopaque,
    /// One complete line. `line` is valid only during the call.
    line: *const fn (ctx: *anyopaque, line: []const u8) void,
};

pub const Lines = struct {
    /// The longest line delivered.
    limit: usize = max_line,
    /// The line being framed, while it has no newline yet.
    buf: std.ArrayList(u8) = .empty,
    /// The line being framed is too long; drop it up to its newline.
    skipping: bool = false,
    /// Lines dropped so far. Each line counts once.
    dropped: usize = 0,

    pub fn deinit(self: *Lines, gpa: Allocator) void {
        self.buf.deinit(gpa);
        self.* = .{ .limit = self.limit };
    }

    /// Frames `chunk`, calling `emit.line` for each line it completes, in
    /// order.
    pub fn feed(self: *Lines, gpa: Allocator, chunk: []const u8, emit: Emit) void {
        var rest = chunk;
        while (rest.len > 0) {
            const newline = std.mem.findScalar(u8, rest, '\n');
            const part = rest[0 .. newline orelse rest.len];
            if (!self.skipping) {
                if (self.buf.items.len + part.len > self.limit) {
                    self.drop();
                } else if (newline != null and self.buf.items.len == 0) {
                    // A whole line inside this chunk needs no copy.
                    emit.line(emit.ctx, part);
                } else {
                    self.buf.appendSlice(gpa, part) catch self.drop();
                }
            }
            if (newline) |at| {
                if (!self.skipping and self.buf.items.len > 0) emit.line(emit.ctx, self.buf.items);
                self.buf.clearRetainingCapacity();
                self.skipping = false;
                rest = rest[at + 1 ..];
            } else {
                rest = &.{};
            }
        }
    }

    /// Accounts for bytes that followed what was fed but were lost unread.
    /// They held `newlines` newlines and, when `trailing`, bytes after the
    /// last one. Every line they touch is dropped.
    pub fn lose(self: *Lines, newlines: usize, trailing: bool) void {
        if (newlines > 0) {
            // The first lost newline ends the line being framed.
            if (!self.skipping) self.dropped += 1;
            self.dropped += newlines - 1;
            self.buf.clearRetainingCapacity();
            self.skipping = false;
        }
        if (trailing and !self.skipping) self.drop();
    }

    /// The writer is gone: drops a partial last line.
    pub fn end(self: *Lines) void {
        if (self.buf.items.len > 0) self.dropped += 1;
        self.buf.clearRetainingCapacity();
        self.skipping = false;
    }

    fn drop(self: *Lines) void {
        self.buf.clearRetainingCapacity();
        self.skipping = true;
        self.dropped += 1;
    }
};

const testing = std.testing;

const Collected = struct {
    gpa: Allocator,
    lines: std.ArrayList([]u8) = .empty,

    fn emit(self: *Collected) Emit {
        return .{ .ctx = self, .line = line };
    }

    fn line(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Collected = @ptrCast(@alignCast(ctx));
        const copy = self.gpa.dupe(u8, bytes) catch @panic("out of memory");
        self.lines.append(self.gpa, copy) catch @panic("out of memory");
    }

    fn deinit(self: *Collected) void {
        for (self.lines.items) |item| self.gpa.free(item);
        self.lines.deinit(self.gpa);
    }

    fn expect(self: Collected, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len, self.lines.items.len);
        for (expected, self.lines.items) |want, got| try testing.expectEqualStrings(want, got);
    }
};

test "lines split across reads arrive whole and in order" {
    var lines: Lines = .{};
    defer lines.deinit(testing.allocator);
    var got: Collected = .{ .gpa = testing.allocator };
    defer got.deinit();
    for ([_][]const u8{ "fir", "st\nsec", "ond\n", "\nthird\nfour" }) |chunk| {
        lines.feed(testing.allocator, chunk, got.emit());
    }
    try got.expect(&.{ "first", "second", "", "third" });
    try testing.expectEqual(@as(usize, 0), lines.dropped);
}

test "a line over the limit is dropped up to its newline" {
    var lines: Lines = .{ .limit = 4 };
    defer lines.deinit(testing.allocator);
    var got: Collected = .{ .gpa = testing.allocator };
    defer got.deinit();
    for ([_][]const u8{ "four\nlo", "ng", "er\nok\nfive5\n", "x\n" }) |chunk| {
        lines.feed(testing.allocator, chunk, got.emit());
    }
    try got.expect(&.{ "four", "ok", "x" });
    try testing.expectEqual(@as(usize, 2), lines.dropped);
}

test "a line that cannot be buffered is dropped and counted" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const gpa = failing.allocator();
    var lines: Lines = .{};
    defer lines.deinit(gpa);
    var got: Collected = .{ .gpa = testing.allocator };
    defer got.deinit();
    for ([_][]const u8{ "par", "tial\nok\n" }) |chunk| lines.feed(gpa, chunk, got.emit());
    try got.expect(&.{"ok"});
    try testing.expectEqual(@as(usize, 1), lines.dropped);
}

test "a partial line is dropped when the writer is gone" {
    var lines: Lines = .{};
    defer lines.deinit(testing.allocator);
    var got: Collected = .{ .gpa = testing.allocator };
    defer got.deinit();
    lines.feed(testing.allocator, "whole\npart", got.emit());
    lines.end();
    try got.expect(&.{"whole"});
    try testing.expectEqual(@as(usize, 0), lines.buf.items.len);
    try testing.expectEqual(@as(usize, 1), lines.dropped);
}

test "lost bytes drop each line they touch once" {
    var lines: Lines = .{ .limit = 4 };
    defer lines.deinit(testing.allocator);
    var got: Collected = .{ .gpa = testing.allocator };
    defer got.deinit();
    // Lost "x\nc\n\nd": they finish "ab", hold "c" and "", and start "d".
    lines.feed(testing.allocator, "ok\nab", got.emit());
    lines.lose(3, true);
    lines.end();
    try got.expect(&.{"ok"});
    try testing.expectEqual(@as(usize, 4), lines.dropped);

    // A line already dropped for its length is not counted again.
    lines.feed(testing.allocator, "toolong", got.emit());
    lines.lose(1, false);
    lines.feed(testing.allocator, "next\n", got.emit());
    try got.expect(&.{ "ok", "next" });
    try testing.expectEqual(@as(usize, 5), lines.dropped);
}

// Random runs drive the core the way a terminal's report channel does: a
// simulated child writes a script of lines one byte at a time and may exit
// mid-line, the reader frames reads of 1 to `read_max` bytes, drains the
// channel and ends the lines when it sees the exit, possibly losing the end
// of the drain, and the owner may close first. After every step the test
// checks that every delivered line is a whole, short line the child
// finished, in order, that when the exit is reported every such line that
// was not lost has been delivered, and that every line the reader saw is
// either delivered or counted as dropped.

/// The longest delivered line and the largest read in a run, small so that
/// long lines and split reads are common.
const run_limit = 2;
const read_max = 3;

const Phase = enum { open, exited, closed };

const Run = struct {
    gpa: Allocator,
    script: []const usize,
    stream: []const u8,
    sent: usize = 0,
    read: usize = 0,
    /// Bytes past this were lost unread when the exit was reported.
    kept: ?usize = null,
    alive: bool = true,
    phase: Phase = .open,
    lines: Lines = .{ .limit = run_limit },
    got: Collected,

    /// The lines the child has finished that are short enough and were
    /// not lost, in order.
    fn deliverable(self: Run, out: *std.ArrayList(usize)) !void {
        var end: usize = 0;
        for (self.script) |len| {
            end += len + 1;
            if (end <= (self.kept orelse self.sent) and len <= run_limit) try out.append(self.gpa, len);
        }
    }

    fn check(self: Run) !void {
        var expected: std.ArrayList(usize) = .empty;
        defer expected.deinit(self.gpa);
        try self.deliverable(&expected);
        const got = self.got.lines.items;
        try testing.expect(got.len <= expected.items.len);
        if (self.phase == .exited) try testing.expectEqual(expected.items.len, got.len);
        // Each line is all one letter, so its content shows it is whole.
        for (got, expected.items[0..got.len]) |line, len| {
            try testing.expectEqual(len, line.len);
            if (line.len > 0) for (line) |byte| try testing.expectEqual(line[0], byte);
        }
        const seen = startedLines(self.stream[0..self.read]);
        try testing.expect(got.len + self.lines.dropped <= seen);
        if (self.phase != .open) try testing.expectEqual(seen, got.len + self.lines.dropped);
    }
};

/// Lines that `bytes` finish or start.
fn startedLines(bytes: []const u8) usize {
    const partial: usize = @intFromBool(bytes.len > 0 and bytes[bytes.len - 1] != '\n');
    return std.mem.count(u8, bytes, "\n") + partial;
}

fn runRandom(gpa: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var script: [5]usize = undefined;
    const line_count = random.intRangeAtMost(usize, 1, script.len);
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for (script[0..line_count], 0..) |*len, index| {
        len.* = random.uintAtMost(usize, run_limit + 1);
        try stream.appendNTimes(gpa, @intCast('a' + index), len.*);
        try stream.append(gpa, '\n');
    }

    var run: Run = .{
        .gpa = gpa,
        .script = script[0..line_count],
        .stream = stream.items,
        .got = .{ .gpa = gpa },
    };
    defer run.lines.deinit(gpa);
    defer run.got.deinit();

    while (run.phase == .open) {
        switch (random.uintLessThan(u8, 6)) {
            0, 1 => if (run.alive and run.sent < run.stream.len) {
                run.sent += 1;
            },
            2 => if (run.alive and random.uintLessThan(u8, 4) == 0) {
                run.alive = false;
            },
            3, 4 => if (run.read < run.sent) {
                const n = random.intRangeAtMost(usize, 1, @min(read_max, run.sent - run.read));
                run.lines.feed(gpa, run.stream[run.read..][0..n], run.got.emit());
                run.read += n;
            },
            else => if (!run.alive) {
                // A drain short of memory loses everything after some byte.
                const kept = if (random.uintLessThan(u8, 4) == 0) random.intRangeAtMost(usize, run.read, run.sent) else run.sent;
                run.lines.feed(gpa, run.stream[run.read..kept], run.got.emit());
                const lost = run.stream[kept..run.sent];
                run.lines.lose(std.mem.count(u8, lost, "\n"), lost.len > 0 and lost[lost.len - 1] != '\n');
                run.read = run.sent;
                run.kept = kept;
                run.lines.end();
                run.phase = .exited;
            } else if (random.uintLessThan(u8, 8) == 0) {
                run.lines.end();
                run.phase = .closed;
            },
        }
        // A child that wrote everything exits.
        if (run.alive and run.sent == run.stream.len and random.boolean()) {
            run.alive = false;
        }
        try run.check();
    }
}

test "random runs keep the report channel's rules" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) try runRandom(testing.allocator, seed);
}
