//! An awake clock for tests: from `install` until `deinit`, `io.getIo()`
//! reads an awake clock that starts at zero, and a sleep moves it on at once,
//! so a test reads how long the code would have waited without waiting. One
//! at a time. `stuck_lookup_testing.zig` swaps the Io the same way to hang
//! DNS lookups on the real clock.
const std = @import("std");
const io_mod = @import("io.zig");

pub const FakeAwakeClock = struct {
    previous: ?std.Io,

    var vtable: std.Io.VTable = undefined;
    var base: std.Io = undefined;
    var awake_ns: std.atomic.Value(i64) = .init(0);

    pub fn install() FakeAwakeClock {
        base = io_mod.getIo();
        vtable = base.vtable.*;
        vtable.now = now;
        vtable.sleep = sleep;
        awake_ns.store(0, .seq_cst);
        return .{ .previous = io_mod.replaceIoForTest(.{ .userdata = base.userdata, .vtable = &vtable }) };
    }

    pub fn deinit(self: *FakeAwakeClock) void {
        io_mod.restoreIoForTest(self.previous);
    }

    pub fn elapsedMs() i64 {
        return @divTrunc(awake_ns.load(.seq_cst), std.time.ns_per_ms);
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        if (clock == .awake) return .fromNanoseconds(awake_ns.load(.seq_cst));
        return base.vtable.now(userdata, clock);
    }

    fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        switch (timeout) {
            .duration => |duration| _ = awake_ns.fetchAdd(@intCast(duration.raw.nanoseconds), .seq_cst),
            // The waits these tests drive sleep only for a duration.
            .none, .deadline => return error.Canceled,
        }
    }
};
