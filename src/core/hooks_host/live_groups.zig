//! The hook process groups fx has started and not yet reaped. A signal handler
//! reads the slots to stop them, so the slots are atomics, and nothing here
//! allocates, locks, or traces.

const std = @import("std");

/// The most hook process groups alive at once in this process. The size is a bound, not a measured
/// peak: a turn runs its hooks one at a time, and detached runs stop at 8 (`max_detached_runs`). A
/// fixed size lets a signal handler read the registry without allocating. Past it, a hook does not start.
pub const max_live_groups = 64;

/// A registered group: the slot it sits in, and the group id, which is its leader's pid.
pub const Slot = struct {
    index: usize,
    pid: std.posix.pid_t,
};

/// 0 means free. A slot holds a pid from `add` until `remove`.
var slots: [max_live_groups]std.atomic.Value(std.posix.pid_t) = @splat(.init(0));

/// Records a started group in a free slot. Fails when every slot is in use; the caller then does not
/// run the hook.
pub fn add(pid: std.posix.pid_t) error{TooManyGroups}!Slot {
    std.debug.assert(pid > 0);
    for (&slots, 0..) |*slot, index| {
        if (slot.cmpxchgStrong(0, pid, .acq_rel, .acquire) == null) return .{ .index = index, .pid = pid };
    }
    return error.TooManyGroups;
}

/// Whether any slot is free. A hint only: `add` makes the decision.
pub fn hasRoom() bool {
    for (&slots) |*slot| {
        if (slot.load(.acquire) == 0) return true;
    }
    return false;
}

/// Frees a slot. A slot that is already free stays free, so a second call does nothing.
pub fn remove(slot: Slot) void {
    _ = slots[slot.index].cmpxchgStrong(slot.pid, 0, .acq_rel, .acquire);
}

/// Sends SIGKILL to every registered group. It only loads atomics and calls `kill(2)`, the one thing
/// a signal handler may do: no allocation, no lock, and no trace. A group that has already ended is
/// skipped by the kernel.
pub fn killAll() void {
    for (&slots) |*slot| {
        const pid = slot.load(.acquire);
        if (pid > 0) _ = std.c.kill(-pid, std.c.SIG.KILL);
    }
}

/// How many slots hold a group. For tests.
pub fn liveCount() usize {
    var count: usize = 0;
    for (&slots) |*slot| {
        if (slot.load(.acquire) != 0) count += 1;
    }
    return count;
}

/// A pid no process has. Tests that fill the registry use it, and no test signals it.
const fake_pid: std.posix.pid_t = 0x7ffffff0;

test "add takes a free slot, remove gives it back, and a second remove does nothing" {
    const before = liveCount();
    const slot = try add(fake_pid);
    try std.testing.expectEqual(before + 1, liveCount());
    remove(slot);
    try std.testing.expectEqual(before, liveCount());
    remove(slot);
    try std.testing.expectEqual(before, liveCount());
}

test "a full registry refuses another group, and the test frees the slots it took" {
    const before = liveCount();
    var taken: [max_live_groups]Slot = undefined;
    var count: usize = 0;
    defer for (taken[0..count]) |slot| remove(slot);
    while (count < max_live_groups - before) : (count += 1) {
        taken[count] = try add(fake_pid);
    }
    try std.testing.expect(!hasRoom());
    try std.testing.expectError(error.TooManyGroups, add(fake_pid));
    try std.testing.expectEqual(max_live_groups, liveCount());
}

test "killAll ends the group of a sleeping child, which then reports a signal" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const slot = try add(child.id.?);
    defer remove(slot);
    killAll();
    const term = try child.wait(io);
    switch (term) {
        .signal => |signal| try std.testing.expectEqual(std.posix.SIG.KILL, signal),
        else => return error.ChildNotSignaled,
    }
}
