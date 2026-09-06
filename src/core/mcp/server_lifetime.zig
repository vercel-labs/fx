const std = @import("std");
const atomic_value = @import("atomic_value.zig");

var next_identity: atomic_value.Value(u64) = .init(1);

pub fn allocateIdentity() u64 {
    const identity = next_identity.fetchAdd(1, .monotonic);
    std.debug.assert(identity != 0);
    return identity;
}

/// A server may leave the session table while an operation still owns a lease.
/// Retirement rejects new leases and cancels existing work before waiting.
pub const Lifetime = struct {
    mutex: std.Io.Mutex = .init,
    settled: std.Io.Condition = .init,
    users: usize = 0,
    retiring: std.atomic.Value(bool) = .init(false),

    pub fn acquire(self: *Lifetime, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.retiring.load(.acquire)) return false;
        self.users += 1;
        return true;
    }

    pub fn release(self: *Lifetime, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.users > 0);
        self.users -= 1;
        if (self.users == 0) self.settled.broadcast(io);
    }

    pub fn retire(self: *Lifetime) void {
        self.retiring.store(true, .release);
    }

    pub fn wait(self: *Lifetime, io: std.Io) void {
        std.debug.assert(self.retiring.load(.acquire));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.users > 0) self.settled.waitUncancelable(io, &self.mutex);
    }
};

test "retiring one server cancels its leases without retiring another" {
    var first: Lifetime = .{};
    var second: Lifetime = .{};
    try std.testing.expect(first.acquire(std.testing.io));
    first.retire();
    try std.testing.expect(!first.acquire(std.testing.io));
    try std.testing.expect(second.acquire(std.testing.io));
    first.release(std.testing.io);
    first.wait(std.testing.io);
    second.release(std.testing.io);
    second.retire();
    second.wait(std.testing.io);
}
