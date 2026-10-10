//! The pure core of the pool: which terminal occupies each slot, and in
//! what state. It makes no syscalls and has no threads; the pool calls it
//! under its table lock.
//!
//! An id is a slot plus a generation that goes up on every open, so a
//! reused slot never answers to an old id.
//!
//! Transitions: `open`, `markEnded` (the PTY's child side closed),
//! `claimExit`, `remove` (close starts), `release` (close returns).

const std = @import("std");

pub const max_terminals = 10;

pub const Id = struct {
    slot: u8,
    gen: u32,
};

pub const SlotState = enum { free, open, ended, closing };

const Slot = struct {
    state: SlotState = .free,
    gen: u32 = 0,
    exit_sent: bool = false,
};

pub const Table = struct {
    slots: [max_terminals]Slot = [_]Slot{.{}} ** max_terminals,

    pub fn hasFree(self: Table) bool {
        for (self.slots) |slot| {
            if (slot.state == .free) return true;
        }
        return false;
    }

    /// Claims the lowest free slot for a new terminal.
    pub fn open(self: *Table) error{LimitReached}!Id {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.state != .free) continue;
            slot.* = .{ .state = .open, .gen = slot.gen +% 1 };
            return .{ .slot = @intCast(index), .gen = slot.gen };
        }
        return error.LimitReached;
    }

    /// The id's terminal is open: the reader polls it and owners may write
    /// to it.
    pub fn isCurrent(self: Table, id: Id) bool {
        return self.matches(id, &.{.open});
    }

    /// The id's terminal is open or ended: its child may still exit, and it
    /// has not started closing.
    pub fn isLive(self: Table, id: Id) bool {
        return self.matches(id, &.{ .open, .ended });
    }

    /// The live id in `slot`, if there is one.
    pub fn liveId(self: Table, slot: usize) ?Id {
        const s = self.slots[slot];
        if (s.state != .open and s.state != .ended) return null;
        return .{ .slot = @intCast(slot), .gen = s.gen };
    }

    /// The PTY's child side closed: stop polling the terminal.
    pub fn markEnded(self: *Table, id: Id) void {
        std.debug.assert(self.isCurrent(id));
        self.slots[id.slot].state = .ended;
    }

    /// True the first time it is called for a live id, so each exit is
    /// reported once.
    pub fn claimExit(self: *Table, id: Id) bool {
        if (!self.isLive(id)) return false;
        const slot = &self.slots[id.slot];
        if (slot.exit_sent) return false;
        slot.exit_sent = true;
        return true;
    }

    /// close starts: the terminal leaves the table.
    pub fn remove(self: *Table, id: Id) error{NotFound}!void {
        if (!self.isLive(id)) return error.NotFound;
        self.slots[id.slot].state = .closing;
    }

    /// close returns: the slot is free again.
    pub fn release(self: *Table, id: Id) void {
        std.debug.assert(self.matches(id, &.{.closing}));
        self.slots[id.slot].state = .free;
    }

    fn matches(self: Table, id: Id, states: []const SlotState) bool {
        if (id.slot >= max_terminals) return false;
        const slot = self.slots[id.slot];
        return slot.gen == id.gen and std.mem.findScalar(SlotState, states, slot.state) != null;
    }
};

const testing = std.testing;

test "open takes the lowest free slot up to the limit" {
    var table: Table = .{};
    for (0..max_terminals) |index| {
        const id = try table.open();
        try testing.expectEqual(@as(u8, @intCast(index)), id.slot);
    }
    try testing.expect(!table.hasFree());
    try testing.expectError(error.LimitReached, table.open());
}

test "a reused slot never answers to an old id" {
    var table: Table = .{};
    const first = try table.open();
    try table.remove(first);
    table.release(first);
    const second = try table.open();

    try testing.expectEqual(first.slot, second.slot);
    try testing.expect(first.gen != second.gen);
    try testing.expect(!table.isCurrent(first));
    try testing.expect(table.isCurrent(second));
    try testing.expectError(error.NotFound, table.remove(first));
}

test "an ended terminal stays live but is not current" {
    var table: Table = .{};
    const id = try table.open();
    table.markEnded(id);
    try testing.expect(!table.isCurrent(id));
    try testing.expect(table.isLive(id));
    try testing.expectEqual(id, table.liveId(id.slot).?);
}

test "an exit is claimed once per id" {
    var table: Table = .{};
    const id = try table.open();
    try testing.expect(table.claimExit(id));
    try testing.expect(!table.claimExit(id));

    try table.remove(id);
    table.release(id);
    const next = try table.open();
    try testing.expect(!table.claimExit(id));
    try testing.expect(table.claimExit(next));
}

test "a closing terminal is neither current nor live" {
    var table: Table = .{};
    const id = try table.open();
    try table.remove(id);
    try testing.expect(!table.isCurrent(id));
    try testing.expect(!table.isLive(id));
    try testing.expectEqual(@as(?Id, null), table.liveId(id.slot));
    try testing.expect(!table.claimExit(id));
    try testing.expectError(error.NotFound, table.remove(id));
}
