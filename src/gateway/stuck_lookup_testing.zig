//! An `std.Io` for tests whose DNS lookups hang, the way `getaddrinfo` does
//! on a network that drops DNS traffic: a lookup ignores cancellation and
//! fails only once the test lets it go, or after `max_stall_ms`. Requests
//! run through std's own connect, so a test sees what a user would.
const std = @import("std");
const io_mod = @import("../core/shared/io.zig");

/// The longest a lookup hangs, so a test of code that waits lookups out
/// fails on its time bound instead of hanging.
pub const max_stall_ms = 3_000;

/// Makes every lookup through `io_mod.getIo()` hang from `install` until
/// `deinit`. One at a time.
pub const StuckLookups = struct {
    previous: ?std.Io,

    var vtable: std.Io.VTable = undefined;
    var entered: std.atomic.Value(u32) = .init(0);
    var active: std.atomic.Value(u32) = .init(0);
    var released: std.atomic.Value(bool) = .init(false);

    pub fn install() StuckLookups {
        const base = io_mod.getIo();
        vtable = base.vtable.*;
        vtable.netLookup = netLookup;
        entered.store(0, .seq_cst);
        released.store(false, .seq_cst);
        return .{ .previous = io_mod.replaceIoForTest(.{ .userdata = base.userdata, .vtable = &vtable }) };
    }

    /// Lets every hung lookup fail, waits for them to return, and puts the
    /// previous Io back. Work that outlives a lookup, such as an open job,
    /// is the test's to wait for.
    pub fn deinit(self: *StuckLookups) void {
        released.store(true, .seq_cst);
        while (active.load(.acquire) != 0) io_mod.sleep(std.time.ns_per_ms);
        io_mod.restoreIoForTest(self.previous);
        self.* = undefined;
    }

    /// Sets `flag`, as Esc or shutdown would, once a lookup hangs. Join the
    /// returned thread.
    pub fn cancelOnceStuck(_: *const StuckLookups, flag: *std.atomic.Value(bool)) !std.Thread {
        return std.Thread.spawn(.{}, setOnceEntered, .{flag});
    }

    fn setOnceEntered(flag: *std.atomic.Value(bool)) void {
        var waited_ms: usize = 0;
        while (entered.load(.seq_cst) == 0 and waited_ms < max_stall_ms) : (waited_ms += 1) {
            io_mod.sleep(std.time.ns_per_ms);
        }
        flag.store(true, .seq_cst);
    }

    fn netLookup(
        userdata: ?*anyopaque,
        _: std.Io.net.HostName,
        resolved: *std.Io.Queue(std.Io.net.HostName.LookupResult),
        _: std.Io.net.HostName.LookupOptions,
    ) std.Io.net.HostName.LookupError!void {
        const io: std.Io = .{ .userdata = userdata, .vtable = &vtable };
        _ = active.fetchAdd(1, .acq_rel);
        defer _ = active.fetchSub(1, .acq_rel);
        defer resolved.close(io);
        _ = entered.fetchAdd(1, .seq_cst);
        var cancel_pending = false;
        var waited_ms: usize = 0;
        while (!released.load(.seq_cst) and waited_ms < max_stall_ms) : (waited_ms += 1) {
            io.sleep(.fromMilliseconds(1), .awake) catch |err| switch (err) {
                error.Canceled => cancel_pending = true,
            };
        }
        // getaddrinfo cannot be interrupted, so a cancel during it shows only
        // once it returns.
        if (cancel_pending) io.recancel();
        return error.UnknownHostName;
    }
};

/// Milliseconds since `started` on the awake clock.
pub fn elapsedMsSince(started: std.Io.Clock.Timestamp) i64 {
    return started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
}
