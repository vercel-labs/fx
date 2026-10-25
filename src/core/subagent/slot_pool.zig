//! Bounded run slots for subagent turns (D92). A child's turn holds one
//! slot of its tree's pool and one of the process pool while it runs. A
//! parent blocked on a child lends its slot back until the child is done,
//! so a chain from the root to the deepest node always finds a slot
//! (`tests/tla/session_manager/Tree.tla` `SlotsBounded`, `WaitersRun`).
const std = @import("std");
const io_mod = @import("../shared/io.zig");

/// How often a blocked acquire looks at its cancel flags.
const cancel_pulse_ms: u64 = 20;

pub const default_tree_slots: usize = 8;
pub const default_process_slots: usize = 32;

pub const AcquireError = error{Cancelled};

/// Flags that end a wait for a slot. Any set flag cancels it.
pub const CancelFlags = struct {
    first: ?*const std.atomic.Value(bool) = null,
    second: ?*const std.atomic.Value(bool) = null,

    fn set(self: CancelFlags) bool {
        if (self.first) |flag| if (flag.load(.seq_cst)) return true;
        if (self.second) |flag| if (flag.load(.seq_cst)) return true;
        return false;
    }
};

/// A counting semaphore whose waits observe cancellation.
pub const Pool = struct {
    capacity: usize,
    mutex: std.Io.Mutex = .init,
    used: usize = 0,

    pub fn acquire(self: *Pool, cancel: CancelFlags) AcquireError!void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.used >= self.capacity) {
            if (cancel.set()) return error.Cancelled;
            self.waitPulse();
        }
        self.used += 1;
    }

    pub fn release(self: *Pool) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.used > 0);
        self.used -= 1;
    }

    pub fn inUse(self: *Pool) usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.used;
    }

    /// One pulse with the mutex released, held again on return, so a
    /// release lands and cancellation is seen within a pulse.
    fn waitPulse(self: *Pool) void {
        const io = io_mod.getIo();
        self.mutex.unlock(io);
        io_mod.sleep(cancel_pulse_ms * std.time.ns_per_ms);
        self.mutex.lockUncancelable(io);
    }
};

/// Every process shares one pool, so trees together stay bounded.
pub var process_pool: Pool = .{ .capacity = default_process_slots };

/// The tree and process slots one running turn holds. Taken in that order
/// and given back in reverse, so two waiters never hold each other's next
/// slot.
pub const Permit = struct {
    tree: *Pool,
    process: *Pool,
    mutex: std.Io.Mutex = .init,
    held: bool = false,
    /// Parent waits currently lending this permit back (parallel calls).
    lenders: usize = 0,

    pub fn acquire(self: *Permit, cancel: CancelFlags) AcquireError!void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.held) return;
        try self.take(cancel);
    }

    /// Gives the slots back for good, at the end of the turn.
    pub fn release(self: *Permit) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.held) self.give();
    }

    /// A wait on a child starts: the first one lends the slots back.
    pub fn lend(self: *Permit) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.lenders += 1;
        if (self.lenders == 1 and self.held) self.give();
    }

    /// A wait on a child ends: the last one takes the slots again before
    /// the turn goes on. Cancelled leaves the permit empty, and the turn
    /// unwinds without one.
    pub fn reclaim(self: *Permit, cancel: CancelFlags) AcquireError!void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.lenders > 0);
        self.lenders -= 1;
        if (self.lenders == 0 and !self.held) try self.take(cancel);
    }

    fn take(self: *Permit, cancel: CancelFlags) AcquireError!void {
        try self.tree.acquire(cancel);
        self.process.acquire(cancel) catch |err| {
            self.tree.release();
            return err;
        };
        self.held = true;
    }

    fn give(self: *Permit) void {
        self.process.release();
        self.tree.release();
        self.held = false;
    }
};

test "a permit takes both pools and lends them back while it waits" {
    var tree: Pool = .{ .capacity = 1 };
    var process: Pool = .{ .capacity = 4 };
    var parent: Permit = .{ .tree = &tree, .process = &process };
    try parent.acquire(.{});
    try std.testing.expectEqual(@as(usize, 1), tree.inUse());
    try std.testing.expectEqual(@as(usize, 1), process.inUse());

    // A child cannot run while the parent holds the only tree slot.
    var cancelled = std.atomic.Value(bool).init(true);
    var child: Permit = .{ .tree = &tree, .process = &process };
    try std.testing.expectError(error.Cancelled, child.acquire(.{ .first = &cancelled }));
    try std.testing.expectEqual(@as(usize, 1), process.inUse());

    // Two parallel waits lend once; the last one to end takes it back.
    parent.lend();
    parent.lend();
    try std.testing.expectEqual(@as(usize, 0), tree.inUse());
    try child.acquire(.{});
    child.release();
    try parent.reclaim(.{});
    try std.testing.expect(!parent.held);
    try parent.reclaim(.{});
    try std.testing.expect(parent.held);
    parent.release();
    parent.release();
    try std.testing.expectEqual(@as(usize, 0), tree.inUse());
    try std.testing.expectEqual(@as(usize, 0), process.inUse());
}

test "a blocked acquire runs once a slot is released" {
    var tree: Pool = .{ .capacity = 1 };
    var process: Pool = .{ .capacity = 1 };
    var first: Permit = .{ .tree = &tree, .process = &process };
    try first.acquire(.{});
    const Waiter = struct {
        permit: Permit,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.permit.acquire(.{}) catch return;
            self.done.store(true, .seq_cst);
        }
    };
    var waiter = Waiter{ .permit = .{ .tree = &tree, .process = &process } };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    io_mod.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!waiter.done.load(.seq_cst));
    first.release();
    thread.join();
    try std.testing.expect(waiter.done.load(.seq_cst));
    waiter.permit.release();
    try std.testing.expectEqual(@as(usize, 0), tree.inUse());
}
