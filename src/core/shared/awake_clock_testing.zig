//! An awake clock for tests: from `install` until `deinit`, `io.getIo()`
//! reads an awake clock that starts at zero, and a sleep or a timed futex
//! wait on it moves it on at once, so a test reads how long the code would
//! have waited without waiting. `deliverAt` releases a held reply, and
//! `releaseAt` a test thread, at a set time inside such a wait. One at a time. `stuck_lookup_testing.zig` swaps
//! the Io the same way to hang DNS lookups on the real clock.
const std = @import("std");
const io_mod = @import("io.zig");

pub const FakeAwakeClock = struct {
    previous: ?std.Io,

    var vtable: std.Io.VTable = undefined;
    var base: std.Io = undefined;
    var awake_ns: std.atomic.Value(i64) = .init(0);
    var delivery: ?Delivery = null;
    /// The word the wait a delivery fell in sleeps on, and the wakes the
    /// code sent it.
    var watched: std.atomic.Value(usize) = .init(0);
    var wakes: std.atomic.Value(u32) = .init(0);

    const Delivery = struct { at_ms: i64, release: *std.atomic.Value(bool), done: ?*std.Io.Event };

    /// How long a wait that a delivery reached waits, for real, for the
    /// work to finish or to wake it. Past it, the wake counts as lost.
    const real_wake_limit_ms: i64 = 1_000;

    pub fn install() FakeAwakeClock {
        base = io_mod.getIo();
        vtable = base.vtable.*;
        vtable.now = now;
        vtable.sleep = sleep;
        vtable.futexWait = futexWait;
        vtable.futexWake = futexWake;
        awake_ns.store(0, .seq_cst);
        delivery = null;
        watched.store(0, .seq_cst);
        wakes.store(0, .seq_cst);
        return .{ .previous = io_mod.replaceIoForTest(.{ .userdata = base.userdata, .vtable = &vtable }) };
    }

    pub fn deinit(self: *FakeAwakeClock) void {
        delivery = null;
        io_mod.restoreIoForTest(self.previous);
    }

    pub fn elapsedMs() i64 {
        return @divTrunc(awake_ns.load(.seq_cst), std.time.ns_per_ms);
    }

    /// Sets `release` when the clock reaches `at_ms`, for work that sets
    /// `done` once it ends.
    pub fn deliverAt(at_ms: i64, release: *std.atomic.Value(bool), done: *std.Io.Event) void {
        delivery = .{ .at_ms = at_ms, .release = release, .done = done };
    }

    /// Sets `release` when the clock reaches `at_ms`, for a test thread that
    /// then acts, such as one that cancels. A timed wait the time falls in
    /// ends then only if the code wakes it.
    pub fn releaseAt(at_ms: i64, release: *std.atomic.Value(bool)) void {
        delivery = .{ .at_ms = at_ms, .release = release, .done = null };
    }

    /// The delivery due by `end_ns`, taken but not released yet, or null.
    fn takeDue(end_ns: i64) ?Delivery {
        const due = delivery orelse return null;
        if (due.at_ms * std.time.ns_per_ms > end_ns) return null;
        delivery = null;
        return due;
    }

    fn realMs() i64 {
        const timestamp = base.vtable.now(base.userdata, .awake);
        return @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms));
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        if (clock == .awake) return .fromNanoseconds(awake_ns.load(.seq_cst));
        return base.vtable.now(userdata, clock);
    }

    /// A sleep a delivery falls in still lasts its whole time, and its end
    /// sees the work finished, as a poll after it would.
    fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const ns: i64 = switch (timeout) {
            .duration => |duration| @intCast(duration.raw.nanoseconds),
            // The waits these tests drive sleep only for a duration.
            .none, .deadline => return error.Canceled,
        };
        const end_ns = awake_ns.load(.seq_cst) + ns;
        if (takeDue(end_ns)) |due| {
            due.release.store(true, .seq_cst);
            if (due.done) |done| {
                const give_up_ms = realMs() + real_wake_limit_ms;
                // A failed yield only spins once more.
                while (!done.isSet() and realMs() < give_up_ms) std.Thread.yield() catch {};
            }
        }
        awake_ns.store(end_ns, .seq_cst);
    }

    /// A timed wait on the awake clock that a delivery falls in ends at the
    /// delivery only if the work wakes it; otherwise it lasts its whole
    /// time, as a lost wake would make it. Every other wait is real.
    fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const ns: i64 = switch (timeout) {
            .duration => |duration| if (duration.clock == .awake)
                @intCast(duration.raw.nanoseconds)
            else
                return base.vtable.futexWait(userdata, ptr, expected, timeout),
            .none, .deadline => return base.vtable.futexWait(userdata, ptr, expected, timeout),
        };
        if (@atomicLoad(u32, ptr, .acquire) != expected) return;
        const end_ns = awake_ns.load(.seq_cst) + ns;
        if (takeDue(end_ns)) |due| {
            // The word this wait sleeps on, watched before the release, so
            // the wake the release leads to counts.
            watched.store(@intFromPtr(ptr), .seq_cst);
            const wakes_before = wakes.load(.seq_cst);
            due.release.store(true, .seq_cst);
            awake_ns.store(due.at_ms * std.time.ns_per_ms, .seq_cst);
            const give_up_ms = realMs() + real_wake_limit_ms;
            // A failed yield only spins once more.
            while (wakes.load(.seq_cst) == wakes_before and realMs() < give_up_ms) std.Thread.yield() catch {};
            if (wakes.load(.seq_cst) != wakes_before) return;
        }
        awake_ns.store(end_ns, .seq_cst);
    }

    fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        if (@intFromPtr(ptr) == watched.load(.seq_cst)) _ = wakes.fetchAdd(1, .seq_cst);
        base.vtable.futexWake(userdata, ptr, max_waiters);
    }
};
