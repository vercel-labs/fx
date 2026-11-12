//! The loops one conversation holds for `/loop`: parsing the command, and
//! deciding when each loop is due and what a run's outcome means. It owns no
//! clock and does no I/O; the app passes the time in and starts the runs.
//! It imports only `std`, so `Agent` can hold it without crossing the agents
//! boundary (`scripts/check-agents-boundary.sh`).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The most loops one conversation holds. Each run is a full agent turn and
/// loops never expire, so the cap bounds what a forgotten loop set costs.
pub const max_loops: usize = 10;
pub const min_interval_ms: u64 = 60_000;
/// A loop that waits longer than a year is a typo, not a schedule.
pub const max_interval_ms: u64 = 365 * 24 * 60 * 60_000;
pub const max_prompt_bytes: usize = 4_000;
/// Consecutive failed runs after which a loop pauses instead of spending
/// every interval on a failure nobody sees.
pub const pause_after_failures: u8 = 3;

pub const Target = union(enum) { all, id: u32 };

pub const Command = union(enum) {
    list,
    arm: struct { interval_ms: u64, prompt: []const u8 },
    stop: Target,
    resume_loop: u32,
};

pub const ParseError = error{ MissingPrompt, InvalidInterval, IntervalTooShort, IntervalTooLong, PromptTooLong, InvalidId };

/// Reads the text after `/loop`. Returned slices borrow `payload`.
pub fn parseCommand(payload: []const u8) ParseError!Command {
    const text = std.mem.trim(u8, payload, " \t");
    if (text.len == 0) return .list;
    const first_end = std.mem.findAny(u8, text, " \t") orelse text.len;
    const first = text[0..first_end];
    const rest = std.mem.trim(u8, text[first_end..], " \t");
    if (std.mem.eql(u8, first, "stop")) {
        if (std.mem.eql(u8, rest, "all")) return .{ .stop = .all };
        return .{ .stop = .{ .id = try parseId(rest) } };
    }
    if (std.mem.eql(u8, first, "resume")) return .{ .resume_loop = try parseId(rest) };
    const interval_ms = try parseInterval(first);
    if (rest.len == 0) return error.MissingPrompt;
    if (rest.len > max_prompt_bytes) return error.PromptTooLong;
    return .{ .arm = .{ .interval_ms = interval_ms, .prompt = rest } };
}

fn parseId(text: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, text, 10) catch error.InvalidId;
}

/// Reads an interval such as `90s`, `5m`, `2h`, or `1d`, in milliseconds.
pub fn parseInterval(token: []const u8) ParseError!u64 {
    if (token.len < 2) return error.InvalidInterval;
    const unit_ms: u64 = switch (token[token.len - 1]) {
        's' => 1_000,
        'm' => 60_000,
        'h' => 60 * 60_000,
        'd' => 24 * 60 * 60_000,
        else => return error.InvalidInterval,
    };
    const digits = token[0 .. token.len - 1];
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidInterval;
    const amount = std.fmt.parseInt(u64, digits, 10) catch |err| switch (err) {
        error.Overflow => return error.IntervalTooLong,
        error.InvalidCharacter => return error.InvalidInterval,
    };
    const interval_ms = std.math.mul(u64, amount, unit_ms) catch return error.IntervalTooLong;
    if (interval_ms > max_interval_ms) return error.IntervalTooLong;
    if (interval_ms < min_interval_ms) return error.IntervalTooShort;
    return interval_ms;
}

/// How a run's turn ended. Mirrors `types.TurnPresentationOutcome`; only
/// `failed` counts toward a pause.
pub const Outcome = enum { completed, interrupted, failed, paused };

pub const State = enum { waiting, running, paused };

pub const Loop = struct {
    id: u32,
    interval_ms: u64,
    /// Owned by `Loops`.
    prompt: []u8,
    state: State,
    next_due_ms: i64,
    /// The turn a running loop started; 0 when none is running.
    running_turn_id: u64 = 0,
    runs: u32 = 0,
    consecutive_failures: u8 = 0,
};

pub const Finished = struct { id: u32, failed: bool, failures: u8, paused: bool };

pub const Loops = struct {
    items: std.ArrayList(Loop) = .empty,
    next_id: u32 = 1,
    /// Test hook: the wait between runs for every loop, in place of each
    /// loop's interval. Lists and notices still show the interval.
    wait_override_ms: ?u64 = null,
    /// The ids `endForConversation` ended, kept until the new conversation
    /// can say so, because a switch redraws the screen in between.
    ended_ids: std.ArrayList(u32) = .empty,

    /// Copies `prompt`. The first run is due one interval from `now_ms`.
    pub fn arm(self: *Loops, alloc: Allocator, interval_ms: u64, prompt: []const u8, now_ms: i64) error{ TooManyLoops, OutOfMemory }!u32 {
        if (self.items.items.len >= max_loops) return error.TooManyLoops;
        const owned = try alloc.dupe(u8, prompt);
        errdefer alloc.free(owned);
        const id = self.next_id;
        try self.items.append(alloc, .{
            .id = id,
            .interval_ms = interval_ms,
            .prompt = owned,
            .state = .waiting,
            .next_due_ms = after(now_ms, self.wait_override_ms orelse interval_ms),
        });
        self.next_id += 1;
        return id;
    }

    /// Removes the loop `target` names, or every loop; how many it removed.
    pub fn stop(self: *Loops, alloc: Allocator, target: Target) error{UnknownLoop}!usize {
        switch (target) {
            .all => return self.endAll(alloc),
            .id => |id| {
                const index = self.indexOf(id) orelse return error.UnknownLoop;
                const removed = self.items.orderedRemove(index);
                alloc.free(removed.prompt);
                return 1;
            },
        }
    }

    pub fn resumeLoop(self: *Loops, id: u32, now_ms: i64) error{ UnknownLoop, NotPaused }!void {
        const loop = &self.items.items[self.indexOf(id) orelse return error.UnknownLoop];
        if (loop.state != .paused) return error.NotPaused;
        loop.state = .waiting;
        loop.consecutive_failures = 0;
        loop.next_due_ms = after(now_ms, self.waitMs(loop.*));
    }

    /// The waiting loop due earliest at `now_ms`, or null. Running and paused
    /// loops never come due, so a backlog of missed intervals runs once.
    pub fn nextDue(self: *Loops, now_ms: i64) ?*Loop {
        var earliest: ?*Loop = null;
        for (self.items.items) |*loop| {
            if (loop.state != .waiting or loop.next_due_ms > now_ms) continue;
            if (earliest == null or loop.next_due_ms < earliest.?.next_due_ms) earliest = loop;
        }
        return earliest;
    }

    pub fn markStarted(self: *Loops, loop: *Loop, turn_id: u64) void {
        _ = self;
        loop.state = .running;
        loop.running_turn_id = turn_id;
        loop.runs += 1;
    }

    /// Records how the run that started `turn_id` ended, and schedules the
    /// next run one interval from `now_ms`. Null when no running loop started
    /// that turn, which also ignores a repeated report.
    pub fn noteTurnFinished(self: *Loops, turn_id: u64, outcome: Outcome, now_ms: i64) ?Finished {
        if (turn_id == 0) return null;
        for (self.items.items) |*loop| {
            if (loop.state != .running or loop.running_turn_id != turn_id) continue;
            loop.running_turn_id = 0;
            switch (outcome) {
                .failed => return self.recordFailure(loop, now_ms),
                .completed => loop.consecutive_failures = 0,
                .interrupted, .paused => {},
            }
            loop.state = .waiting;
            loop.next_due_ms = after(now_ms, self.waitMs(loop.*));
            return .{ .id = loop.id, .failed = false, .failures = loop.consecutive_failures, .paused = false };
        }
        return null;
    }

    /// Counts a run that could not be queued as a failure, so a persistent
    /// queue error waits an interval instead of retrying on every pass.
    pub fn noteAdmissionFailed(self: *Loops, loop: *Loop, now_ms: i64) Finished {
        return self.recordFailure(loop, now_ms);
    }

    /// Frees every loop; how many there were.
    pub fn endAll(self: *Loops, alloc: Allocator) usize {
        const ended = self.items.items.len;
        for (self.items.items) |loop| alloc.free(loop.prompt);
        self.items.clearRetainingCapacity();
        return ended;
    }

    /// Ends every loop because its conversation changed, and records their
    /// ids in `ended_ids` for the notice the next conversation writes.
    pub fn endForConversation(self: *Loops, alloc: Allocator) error{OutOfMemory}!void {
        for (self.items.items) |loop| try self.ended_ids.append(alloc, loop.id);
        _ = self.endAll(alloc);
    }

    /// Every loop, paused ones included, as `/loop` lists them.
    pub fn count(self: *const Loops) usize {
        return self.items.items.len;
    }

    pub fn deinit(self: *Loops, alloc: Allocator) void {
        _ = self.endAll(alloc);
        self.items.deinit(alloc);
        self.ended_ids.deinit(alloc);
        self.* = .{};
    }

    fn indexOf(self: *const Loops, id: u32) ?usize {
        for (self.items.items, 0..) |loop, index| if (loop.id == id) return index;
        return null;
    }

    fn waitMs(self: *const Loops, loop: Loop) u64 {
        return self.wait_override_ms orelse loop.interval_ms;
    }

    fn recordFailure(self: *const Loops, loop: *Loop, now_ms: i64) Finished {
        loop.consecutive_failures +|= 1;
        loop.running_turn_id = 0;
        loop.next_due_ms = after(now_ms, self.waitMs(loop.*));
        loop.state = if (loop.consecutive_failures >= pause_after_failures) .paused else .waiting;
        return .{ .id = loop.id, .failed = true, .failures = loop.consecutive_failures, .paused = loop.state == .paused };
    }
};

/// `now_ms` plus `interval_ms`, saturating instead of overflowing.
fn after(now_ms: i64, interval_ms: u64) i64 {
    const interval = std.math.cast(i64, interval_ms) orelse return std.math.maxInt(i64);
    return std.math.add(i64, now_ms, interval) catch std.math.maxInt(i64);
}

const testing = std.testing;
const minute_ms: u64 = 60_000;
const hour_ms: u64 = 60 * minute_ms;

test "parseCommand reads every form" {
    const arm = try parseCommand("1h check X");
    try testing.expectEqual(@as(u64, hour_ms), arm.arm.interval_ms);
    try testing.expectEqualStrings("check X", arm.arm.prompt);
    try testing.expect(try parseCommand("") == .list);
    try testing.expect(try parseCommand("  \t") == .list);
    try testing.expect((try parseCommand("stop all")).stop == .all);
    try testing.expectEqual(@as(u32, 3), (try parseCommand("stop 3")).stop.id);
    try testing.expectEqual(@as(u32, 2), (try parseCommand("resume 2")).resume_loop);
    try testing.expectError(error.InvalidId, parseCommand("stop"));
    try testing.expectError(error.InvalidId, parseCommand("resume x"));
}

test "parseInterval rejects below one minute" {
    try testing.expectError(error.IntervalTooShort, parseInterval("59s"));
    try testing.expectError(error.IntervalTooShort, parseCommand("30s ping"));
    try testing.expectEqual(@as(u64, 90_000), try parseInterval("90s"));
    try testing.expectEqual(@as(u64, 5 * minute_ms), try parseInterval("5m"));
    try testing.expectEqual(@as(u64, 24 * hour_ms), try parseInterval("1d"));
}

test "parseCommand requires a prompt" {
    try testing.expectError(error.MissingPrompt, parseCommand("1h"));
    try testing.expectError(error.MissingPrompt, parseCommand("1h   "));
}

test "parseInterval rejects unknown units" {
    try testing.expectError(error.InvalidInterval, parseInterval("soon"));
    try testing.expectError(error.InvalidInterval, parseInterval("5"));
    try testing.expectError(error.InvalidInterval, parseInterval("m"));
    try testing.expectError(error.InvalidInterval, parseInterval("5w"));
}

test "parseInterval rejects overflow" {
    try testing.expectError(error.IntervalTooLong, parseInterval("99999999d"));
    try testing.expectError(error.IntervalTooLong, parseInterval("99999999999999999999999s"));
}

test "parseCommand rejects an oversized prompt" {
    var payload: [3 + max_prompt_bytes + 1]u8 = undefined;
    @memcpy(payload[0..3], "1h ");
    @memset(payload[3..], 'x');
    try testing.expectError(error.PromptTooLong, parseCommand(&payload));
    try testing.expect(try parseCommand(payload[0 .. 3 + max_prompt_bytes]) == .arm);
}

test "arm refuses an eleventh loop" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    for (1..max_loops + 1) |n| {
        try testing.expectEqual(@as(u32, @intCast(n)), try loops.arm(testing.allocator, hour_ms, "p", 0));
    }
    try testing.expectError(error.TooManyLoops, loops.arm(testing.allocator, hour_ms, "p", 0));
    _ = try loops.stop(testing.allocator, .{ .id = 4 });
    // An id is never reused after stop.
    try testing.expectEqual(@as(u32, 11), try loops.arm(testing.allocator, hour_ms, "p", 0));
}

test "stop reports unknown ids" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, hour_ms, "p", 0);
    try testing.expectError(error.UnknownLoop, loops.stop(testing.allocator, .{ .id = 7 }));
    try testing.expectEqual(@as(usize, 1), try loops.stop(testing.allocator, .{ .id = 1 }));
    try testing.expectEqual(@as(usize, 0), loops.count());
}

test "stop all removes every loop" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), try loops.stop(testing.allocator, .all));
    _ = try loops.arm(testing.allocator, hour_ms, "a", 0);
    _ = try loops.arm(testing.allocator, hour_ms, "b", 0);
    try testing.expectEqual(@as(usize, 2), try loops.stop(testing.allocator, .all));
    try testing.expectEqual(@as(usize, 0), loops.count());
}

test "backlog collapses to one run" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    const t0: i64 = 1_000;
    _ = try loops.arm(testing.allocator, hour_ms, "p", t0);
    try testing.expect(loops.nextDue(t0 + hour_ms - 1) == null);
    const due = loops.nextDue(t0 + 5 * hour_ms).?;
    loops.markStarted(due, 42);
    try testing.expect(loops.nextDue(t0 + 5 * hour_ms) == null);
    const finished_at: i64 = t0 + 6 * hour_ms;
    const finished = loops.noteTurnFinished(42, .completed, finished_at).?;
    try testing.expect(!finished.failed);
    // Fixed delay: due one interval after the run finished, not on the old grid.
    try testing.expectEqual(finished_at + hour_ms, loops.items.items[0].next_due_ms);
    try testing.expect(loops.nextDue(finished_at + hour_ms - 1) == null);
    try testing.expectEqual(@as(u32, 1), loops.items.items[0].runs);
}

test "one loop per tick, earliest due first" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, 2 * hour_ms, "late", 0);
    _ = try loops.arm(testing.allocator, hour_ms, "early", 0);
    const first = loops.nextDue(3 * hour_ms).?;
    try testing.expectEqualStrings("early", first.prompt);
    loops.markStarted(first, 1);
    const second = loops.nextDue(3 * hour_ms).?;
    try testing.expectEqualStrings("late", second.prompt);
}

test "three failures pause" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "p", 0);
    var now: i64 = 0;
    var turn: u64 = 1;
    for (1..pause_after_failures + 1) |n| {
        now += minute_ms;
        loops.markStarted(loops.nextDue(now).?, turn);
        const finished = loops.noteTurnFinished(turn, .failed, now).?;
        try testing.expect(finished.failed);
        try testing.expectEqual(@as(u8, @intCast(n)), finished.failures);
        try testing.expectEqual(n == pause_after_failures, finished.paused);
        turn += 1;
    }
    try testing.expectEqual(State.paused, loops.items.items[0].state);
    try testing.expect(loops.nextDue(now + 10 * minute_ms) == null);
}

test "a completed run resets failures" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "p", 0);
    const outcomes = [_]Outcome{ .failed, .failed, .completed, .failed, .failed };
    var now: i64 = 0;
    for (outcomes, 1..) |outcome, turn| {
        now += minute_ms;
        loops.markStarted(loops.nextDue(now).?, turn);
        _ = loops.noteTurnFinished(turn, outcome, now).?;
    }
    try testing.expectEqual(@as(u8, 2), loops.items.items[0].consecutive_failures);
    try testing.expectEqual(State.waiting, loops.items.items[0].state);
}

test "interrupted does not count as failure" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "p", 0);
    loops.markStarted(loops.nextDue(minute_ms).?, 9);
    _ = loops.noteTurnFinished(9, .failed, minute_ms).?;
    loops.markStarted(loops.nextDue(2 * minute_ms).?, 10);
    const interrupted = loops.noteTurnFinished(10, .interrupted, 2 * minute_ms).?;
    try testing.expect(!interrupted.failed);
    try testing.expectEqual(@as(u8, 1), interrupted.failures);
    loops.markStarted(loops.nextDue(3 * minute_ms).?, 11);
    _ = loops.noteTurnFinished(11, .paused, 3 * minute_ms).?;
    try testing.expectEqual(@as(u8, 1), loops.items.items[0].consecutive_failures);
    try testing.expectEqual(State.waiting, loops.items.items[0].state);
}

test "a repeated turn_finished is ignored" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "p", 0);
    loops.markStarted(loops.nextDue(minute_ms).?, 5);
    try testing.expect(loops.noteTurnFinished(5, .failed, minute_ms) != null);
    try testing.expect(loops.noteTurnFinished(5, .failed, minute_ms) == null);
    try testing.expect(loops.noteTurnFinished(99, .failed, minute_ms) == null);
    try testing.expectEqual(@as(u8, 1), loops.items.items[0].consecutive_failures);
}

test "admission failure counts and reschedules" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "p", 0);
    var now: i64 = 0;
    for (1..pause_after_failures + 1) |n| {
        now += minute_ms;
        const due = loops.nextDue(now).?;
        const finished = loops.noteAdmissionFailed(due, now);
        try testing.expectEqual(@as(u8, @intCast(n)), finished.failures);
        try testing.expectEqual(n == pause_after_failures, finished.paused);
        if (!finished.paused) {
            try testing.expectEqual(now + minute_ms, loops.items.items[0].next_due_ms);
            try testing.expect(loops.nextDue(now) == null);
        }
    }
    try testing.expectEqual(State.paused, loops.items.items[0].state);
}

test "resume refuses a running loop" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "p", 0);
    try testing.expectError(error.NotPaused, loops.resumeLoop(1, 0));
    try testing.expectError(error.UnknownLoop, loops.resumeLoop(2, 0));
}

test "resume restarts a paused loop" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "p", 0);
    for (0..pause_after_failures) |_| _ = loops.noteAdmissionFailed(&loops.items.items[0], 0);
    try testing.expectEqual(State.paused, loops.items.items[0].state);
    try loops.resumeLoop(1, 100);
    try testing.expectEqual(State.waiting, loops.items.items[0].state);
    try testing.expectEqual(@as(u8, 0), loops.items.items[0].consecutive_failures);
    try testing.expectEqual(@as(i64, 100 + minute_ms), loops.items.items[0].next_due_ms);
}

test "count includes paused loops and endAll empties the list" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "a", 0);
    _ = try loops.arm(testing.allocator, minute_ms, "b", 0);
    for (0..pause_after_failures) |_| _ = loops.noteAdmissionFailed(&loops.items.items[0], 0);
    try testing.expectEqual(@as(usize, 2), loops.count());
    try testing.expectEqual(@as(usize, 2), loops.endAll(testing.allocator));
    try testing.expectEqual(@as(usize, 0), loops.count());
}

test "wait override schedules runs without changing the interval" {
    var loops: Loops = .{ .wait_override_ms = 500 };
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, hour_ms, "p", 0);
    try testing.expectEqual(@as(u64, hour_ms), loops.items.items[0].interval_ms);
    loops.markStarted(loops.nextDue(500).?, 1);
    _ = loops.noteTurnFinished(1, .completed, 600).?;
    try testing.expectEqual(@as(i64, 1_100), loops.items.items[0].next_due_ms);
}

test "endForConversation records the ids it ended" {
    var loops: Loops = .{};
    defer loops.deinit(testing.allocator);
    _ = try loops.arm(testing.allocator, minute_ms, "a", 0);
    _ = try loops.arm(testing.allocator, minute_ms, "b", 0);
    try loops.endForConversation(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loops.count());
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, loops.ended_ids.items);
}
