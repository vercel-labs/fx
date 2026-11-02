//! A watch task that lets a `std.Io.Select` race one operation against
//! cancellation and a deadline without cancelling a running task when the
//! operation finishes first.
//!
//! Cancelling a task that is still running makes `std.Io.Threaded` signal the
//! worker thread running it, and the signal can arrive after that thread has
//! moved on to another task. A `connect` it interrupts is retried, and macOS
//! then fails it with `EISCONN`: a panic in Debug builds and `error.Unexpected`
//! otherwise. So the watch never needs a cancel on the operation's normal
//! path: its owner calls `finish`, which stops the watch and takes its result,
//! and the select is left with nothing to cancel.

const std = @import("std");
const builtin = @import("builtin");

pub const Outcome = enum { stopped, cancelled, deadline };

const poll_interval: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(5),
    .clock = .awake,
} };

/// A watch over `Condition`, which must declare `fn cancelled(Condition) bool`
/// and `fn expired(Condition, std.Io) bool`. The select running it must have a
/// `watch: std.Io.Cancelable!Outcome` event.
pub fn Watch(comptime Condition: type) type {
    return struct {
        stopped: std.Io.Event = .unset,

        const Self = @This();

        /// The watch task: `select.concurrent(.watch, W.run, .{ &watch, io, condition })`.
        /// Returns `.cancelled` or `.deadline` when the condition fires, and
        /// `.stopped` after `stop` or `finish`. Cancellation is checked first.
        pub fn run(watch: *Self, io: std.Io, condition: Condition) std.Io.Cancelable!Outcome {
            while (true) {
                if (condition.cancelled()) return .cancelled;
                if (condition.expired(io)) return .deadline;
                watch.stopped.waitTimeout(io, poll_interval) catch |err| switch (err) {
                    error.Timeout => continue,
                    error.Canceled => |e| return e,
                };
                return .stopped;
            }
        }

        /// Makes the watch return `.stopped` promptly. Call before cancelling a
        /// select whose operation must be interrupted, so the cancel finds the
        /// watch finished or about to finish.
        pub fn stop(watch: *Self, io: std.Io) void {
            watch.stopped.set(io);
        }

        /// Stops the watch, takes its event, and leaves `select` with nothing to
        /// cancel. Call only when every other event has been taken, so the
        /// watch's event is the one outstanding.
        pub fn finish(watch: *Self, select: anytype) void {
            watch.stop(select.io);
            const event = select.queue.getOneUncancelable(select.io) catch |err| switch (err) {
                // Only Select.cancel and cancelDiscard close the queue, and they
                // leave nothing outstanding.
                error.Closed => return,
            };
            std.debug.assert(event == .watch);
            std.debug.assert(select.cancel() == null);
        }
    };
}

const TestCondition = struct {
    flag: *const std.atomic.Value(bool),
    deadline_ns: ?i96 = null,

    pub fn cancelled(condition: TestCondition) bool {
        return condition.flag.load(.acquire);
    }

    pub fn expired(condition: TestCondition, io: std.Io) bool {
        const deadline = condition.deadline_ns orelse return false;
        return std.Io.Clock.awake.now(io).nanoseconds >= deadline;
    }
};

const TestWatch = Watch(TestCondition);

const TestEvent = union(enum) {
    op: std.Io.Cancelable!u32,
    watch: std.Io.Cancelable!Outcome,
};

fn shortOperation(io: std.Io) std.Io.Cancelable!u32 {
    try io.sleep(.fromMicroseconds(200), .awake);
    return 7;
}

fn eventOperation(io: std.Io, done: *std.Io.Event) std.Io.Cancelable!u32 {
    try done.wait(io);
    return 9;
}

/// Counts SIGIO deliveries while installed. `std.Io.Threaded` installs a
/// handler that does nothing so the signal interrupts blocking syscalls; this
/// one does the same with the same flags, plus a count.
const SignalCounter = struct {
    var count: std.atomic.Value(u32) = .init(0);
    var previous: std.posix.Sigaction = undefined;

    fn handler(_: std.posix.SIG) callconv(.c) void {
        _ = count.fetchAdd(1, .monotonic);
    }

    fn install() void {
        count.store(0, .monotonic);
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.IO, &act, &previous);
    }

    fn uninstall() u32 {
        std.posix.sigaction(.IO, &previous, null);
        return count.load(.monotonic);
    }
};

fn skipWithoutSignals() error{SkipZigTest}!void {
    if (builtin.single_threaded or std.posix.Sigaction == void or builtin.target.os.tag == .windows) {
        return error.SkipZigTest;
    }
}

const EndRound = enum { finish, cancel };

/// Runs rounds where the operation wins, then ends each select either way.
fn raceRounds(io: std.Io, rounds: usize, end: EndRound) !void {
    var flag = std.atomic.Value(bool).init(false);
    for (0..rounds) |_| {
        var watch: TestWatch = .{};
        var buffer: [2]TestEvent = undefined;
        var select: std.Io.Select(TestEvent) = .init(io, &buffer);
        try select.concurrent(.watch, TestWatch.run, .{ &watch, io, TestCondition{ .flag = &flag } });
        select.concurrent(.op, shortOperation, .{io}) catch |err| {
            watch.finish(&select);
            return err;
        };
        const event = select.await() catch |err| {
            watch.stop(io);
            while (select.cancel()) |_| {}
            return err;
        };
        switch (end) {
            .finish => watch.finish(&select),
            .cancel => while (select.cancel()) |_| {},
        }
        try std.testing.expectEqual(@as(u32, 7), try event.op);
    }
}

test "finish after the operation wins sends no cancellation signal" {
    try skipWithoutSignals();
    SignalCounter.install();
    const result = raceRounds(std.testing.io, 200, .finish);
    const signals = SignalCounter.uninstall();
    try result;
    try std.testing.expectEqual(@as(u32, 0), signals);
}

test "cancelling a running watch signals its worker thread" {
    // The pattern `finish` replaces. If this stops signalling, the test above
    // no longer proves anything.
    try skipWithoutSignals();
    SignalCounter.install();
    const result = raceRounds(std.testing.io, 50, .cancel);
    const signals = SignalCounter.uninstall();
    try result;
    try std.testing.expect(signals > 0);
}

test "watch reports cancellation and leaves the operation to finish" {
    const io = std.testing.io;
    var flag = std.atomic.Value(bool).init(true);
    var done: std.Io.Event = .unset;
    var watch: TestWatch = .{};
    var buffer: [2]TestEvent = undefined;
    var select: std.Io.Select(TestEvent) = .init(io, &buffer);
    try select.concurrent(.watch, TestWatch.run, .{ &watch, io, TestCondition{ .flag = &flag } });
    try select.concurrent(.op, eventOperation, .{ io, &done });

    try std.testing.expectEqual(Outcome.cancelled, try (try select.await()).watch);
    done.set(io);
    try std.testing.expectEqual(@as(u32, 9), try (try select.await()).op);
    try std.testing.expect(select.cancel() == null);
}

test "watch reports a passed deadline" {
    const io = std.testing.io;
    var flag = std.atomic.Value(bool).init(false);
    var watch: TestWatch = .{};
    const condition: TestCondition = .{ .flag = &flag, .deadline_ns = std.Io.Clock.awake.now(io).nanoseconds };
    try std.testing.expectEqual(Outcome.deadline, try TestWatch.run(&watch, io, condition));
}

test "stop makes a running watch return stopped" {
    const io = std.testing.io;
    var flag = std.atomic.Value(bool).init(false);
    var watch: TestWatch = .{};
    var buffer: [1]TestEvent = undefined;
    var select: std.Io.Select(TestEvent) = .init(io, &buffer);
    try select.concurrent(.watch, TestWatch.run, .{ &watch, io, TestCondition{ .flag = &flag } });
    io.sleep(.fromMilliseconds(12), .awake) catch {};
    watch.stop(io);
    try std.testing.expectEqual(Outcome.stopped, try (try select.await()).watch);
    try std.testing.expect(select.cancel() == null);
}
