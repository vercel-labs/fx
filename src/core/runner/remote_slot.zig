//! The process's remote state: the destination that launch uses (U10), the one
//! setup in flight (U3), and the decline mark for each session and turn (U4).
//! One owner holds it behind one `std.Io.Mutex`. The mutex covers only reads and
//! changes of this state. A REST call, a prompt and the locked write run between
//! `begin` and `end`, outside the mutex, so no slot call waits on them.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const setup = @import("setup.zig");

/// How often a waiter checks its cancel flag while another setup runs (R2.4).
pub const wait_poll_ms: i64 = 50;

/// The remote destination that launch uses.
pub const Destination = struct {
    team_id: []const u8,
    team_slug: []const u8,
    project_id: []const u8,
    project_name: []const u8,
    user_id: []const u8,
};

/// The SHA-256 of a login token, the runner's `--token-sha256`. The token itself is never kept.
pub const TokenHash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// The login that the user check (R5) passed: its token's hash and the user it signs in (R145).
/// Placement passes this hash to the runner (V1), so a login that changes later is refused there.
const CheckedLogin = struct {
    token_hash: TokenHash,
    user_id: []u8,
};

pub const Begin = enum { owner, wait };

pub const WaitResult = enum { finished, canceled };

pub const RecordError = std.mem.Allocator.Error || error{NoActiveTurn};

const Entry = struct {
    turn_id: u64,
    mark: setup.Mark,
};

pub const Slot = struct {
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    /// Signalled when the running setup ends.
    flight_ended: std.Io.Condition = .init,
    flight_running: bool = false,
    /// Owns the strings of `destination`. Replaced by each `setDestination`.
    destination_arena: ?std.heap.ArenaAllocator = null,
    destination: ?Destination = null,
    /// The login that passed the user check. Its user id is owned by `alloc`.
    checked_login: ?CheckedLogin = null,
    /// Keys are owned by `alloc`.
    marks: std.array_hash_map.String(Entry) = .empty,

    pub fn create(alloc: std.mem.Allocator) std.mem.Allocator.Error!*Slot {
        const slot = try alloc.create(Slot);
        slot.* = .{ .alloc = alloc };
        return slot;
    }

    pub fn destroy(self: *Slot) void {
        const alloc = self.alloc;
        if (self.checked_login) |checked| alloc.free(checked.user_id);
        for (self.marks.keys()) |key| alloc.free(key);
        self.marks.deinit(alloc);
        if (self.destination_arena) |*arena| arena.deinit();
        alloc.destroy(self);
    }

    /// Copies `destination` into the slot (U10). The copy is made before the
    /// mutex is taken, and the strings it replaces are freed under the mutex.
    pub fn setDestination(self: *Slot, destination: Destination) std.mem.Allocator.Error!void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer arena.deinit();
        const copy = try copyInto(arena.allocator(), destination);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.destination_arena) |*old| old.deinit();
        self.destination_arena = arena;
        self.destination = copy;
    }

    /// A copy of the destination in `arena`, or null when none is set (U10).
    /// The copy stays valid after a later `setDestination`.
    pub fn currentDestination(self: *Slot, arena: std.mem.Allocator) std.mem.Allocator.Error!?Destination {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const current = self.destination orelse return null;
        return try copyInto(arena, current);
    }

    /// Keeps the login that passed the user check (R5): its token's hash and its user id. The copy is
    /// made before the mutex is taken, and the copy it replaces is freed under the mutex.
    pub fn storeChecked(self: *Slot, token_hash: TokenHash, user_id: []const u8) std.mem.Allocator.Error!void {
        const copy = try self.alloc.dupe(u8, user_id);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.checked_login) |old| self.alloc.free(old.user_id);
        self.checked_login = .{ .token_hash = token_hash, .user_id = copy };
    }

    /// The checked user id, in `arena`, when `token_hash` is the checked login's token.
    pub fn checkedUser(self: *Slot, token_hash: TokenHash, arena: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const checked = self.checked_login orelse return null;
        if (!std.mem.eql(u8, &checked.token_hash, &token_hash)) return null;
        return try arena.dupe(u8, checked.user_id);
    }

    /// The hash of the checked login, when that login belongs to `user_id`. Placement passes it to
    /// the runner, so the placement never reads the login again (V1).
    pub fn checkedHashFor(self: *Slot, user_id: []const u8) ?TokenHash {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const checked = self.checked_login orelse return null;
        if (!std.mem.eql(u8, checked.user_id, user_id)) return null;
        return checked.token_hash;
    }

    /// The first call gets `owner` and runs the setup. Every other call gets
    /// `wait` (U3). The owner calls `end` on every path.
    pub fn begin(self: *Slot) Begin {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.flight_running) return .wait;
        self.flight_running = true;
        return .owner;
    }

    /// Ends the setup that `begin` gave the owner, on success or failure, and
    /// wakes every waiter. A woken waiter calls `begin` again and may become the
    /// owner.
    pub fn end(self: *Slot) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.flight_running = false;
        self.flight_ended.broadcast(io_mod.getIo());
    }

    /// Waits until the running setup ends (`finished`) or `cancel` is set
    /// (`canceled`). The cancel flag is checked at least every `wait_poll_ms`.
    pub fn wait(self: *Slot, cancel: *const std.atomic.Value(bool)) WaitResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const poll: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(wait_poll_ms), .clock = .awake } };
        while (self.flight_running) {
            if (cancel.load(.acquire)) return .canceled;
            self.flight_ended.waitTimeout(io, &self.mutex, poll) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return .canceled,
            };
        }
        return .finished;
    }

    /// The mark `session_key` holds for `turn_id` (U4). A null key is a call that
    /// has no session key, such as a sub-agent call (U2): it reads no mark. Turn 0
    /// means no active turn: it reads the mark and never clears it. A mark from
    /// another turn of the session is cleared and reads as none, so the new turn
    /// asks again.
    pub fn markFor(self: *Slot, session_key: ?[]const u8, turn_id: u64) setup.Mark {
        const session = session_key orelse return .none;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = self.marks.getPtr(session) orelse return .none;
        if (turn_id == 0 or entry.turn_id == turn_id) return entry.mark;
        self.removeMarkLocked(session);
        return .none;
    }

    /// Records the mark that a declined or unanswered setup leaves for
    /// `session_key` in `turn_id`. `none` clears it. A null key is a no-op (U2).
    /// A mark belongs to a turn, so turn 0 is refused.
    pub fn recordMark(self: *Slot, session_key: ?[]const u8, turn_id: u64, mark: setup.Mark) RecordError!void {
        const session = session_key orelse return;
        if (turn_id == 0) return error.NoActiveTurn;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (mark == .none) return self.removeMarkLocked(session);
        if (self.marks.getPtr(session)) |entry| {
            entry.* = .{ .turn_id = turn_id, .mark = mark };
            return;
        }
        const key = try self.alloc.dupe(u8, session);
        errdefer self.alloc.free(key);
        try self.marks.put(self.alloc, key, .{ .turn_id = turn_id, .mark = mark });
    }

    /// Removes the mark that `session_key` holds, when that session ends, so the marks of ended
    /// sessions do not build up in a long process. A null key is a no-op (U2).
    pub fn forgetSession(self: *Slot, session_key: ?[]const u8) void {
        const session = session_key orelse return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.removeMarkLocked(session);
    }

    fn removeMarkLocked(self: *Slot, session: []const u8) void {
        const removed = self.marks.fetchSwapRemove(session) orelse return;
        self.alloc.free(removed.key);
    }
};

/// Copies every string of `destination` into `alloc`, which must be an arena.
fn copyInto(alloc: std.mem.Allocator, destination: Destination) std.mem.Allocator.Error!Destination {
    return .{
        .team_id = try alloc.dupe(u8, destination.team_id),
        .team_slug = try alloc.dupe(u8, destination.team_slug),
        .project_id = try alloc.dupe(u8, destination.project_id),
        .project_name = try alloc.dupe(u8, destination.project_name),
        .user_id = try alloc.dupe(u8, destination.user_id),
    };
}

const testing = std.testing;

const first_destination: Destination = .{
    .team_id = "team_1",
    .team_slug = "acme",
    .project_id = "prj_1",
    .project_name = "repo",
    .user_id = "usr_1",
};

const second_destination: Destination = .{
    .team_id = "team_2",
    .team_slug = "other",
    .project_id = "prj_2",
    .project_name = "api",
    .user_id = "usr_2",
};

const Flight = struct {
    slot: *Slot,
    dest: Destination,
    owner_began: std.Io.Event = .unset,
    waiter_began: std.Io.Event = .unset,
    release_owner: std.Io.Event = .unset,
    owner_begin: Begin = .wait,
    waiter_begin: Begin = .owner,
    waiter_result: WaitResult = .canceled,
    waiter_saw_destination: bool = false,
    failure: ?anyerror = null,
    cancel: std.atomic.Value(bool) = .init(false),

    fn owner(self: *Flight) void {
        const io = io_mod.getIo();
        self.owner_begin = self.slot.begin();
        self.owner_began.set(io);
        self.release_owner.waitUncancelable(io);
        if (self.owner_begin == .owner) self.slot.setDestination(self.dest) catch |err| {
            self.failure = err;
        };
        self.slot.end();
    }

    fn waiter(self: *Flight) void {
        const io = io_mod.getIo();
        self.waiter_begin = self.slot.begin();
        self.waiter_began.set(io);
        self.waiter_result = self.slot.wait(&self.cancel);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const seen = self.slot.currentDestination(arena.allocator()) catch |err| {
            self.failure = err;
            return;
        };
        self.waiter_saw_destination = if (seen) |copy| std.mem.eql(u8, copy.team_id, self.dest.team_id) else false;
    }
};

test "U10: the destination is copied in and out, and a new one replaces it" {
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expect((try slot.currentDestination(arena.allocator())) == null);
    try slot.setDestination(first_destination);
    const first = (try slot.currentDestination(arena.allocator())).?;
    try testing.expectEqualStrings("team_1", first.team_id);
    try testing.expectEqualStrings("repo", first.project_name);
    try slot.setDestination(second_destination);
    const second = (try slot.currentDestination(arena.allocator())).?;
    try testing.expectEqualStrings("prj_2", second.project_id);
    try testing.expectEqualStrings("team_1", first.team_id);
}

test "U3: two threads give one owner and one waiter, and the waiter sees the destination the owner wrote" {
    const io = io_mod.getIo();
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();
    var flight: Flight = .{ .slot = slot, .dest = first_destination };

    const owner_thread = try std.Thread.spawn(.{}, Flight.owner, .{&flight});
    flight.owner_began.waitUncancelable(io);
    const waiter_thread = try std.Thread.spawn(.{}, Flight.waiter, .{&flight});
    flight.waiter_began.waitUncancelable(io);
    flight.release_owner.set(io);
    owner_thread.join();
    waiter_thread.join();

    try testing.expect(flight.failure == null);
    try testing.expectEqual(Begin.owner, flight.owner_begin);
    try testing.expectEqual(Begin.wait, flight.waiter_begin);
    try testing.expectEqual(WaitResult.finished, flight.waiter_result);
    try testing.expect(flight.waiter_saw_destination);
}

test "U3: a cancel while a setup runs makes the waiter canceled, and the setup keeps running" {
    const io = io_mod.getIo();
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();
    try testing.expectEqual(Begin.owner, slot.begin());

    const Canceled = struct {
        slot: *Slot,
        started: std.Io.Event = .unset,
        cancel: std.atomic.Value(bool) = .init(false),
        result: WaitResult = .finished,

        fn run(self: *@This()) void {
            self.started.set(io_mod.getIo());
            self.result = self.slot.wait(&self.cancel);
        }
    };
    var waiter: Canceled = .{ .slot = slot };
    const waiter_thread = try std.Thread.spawn(.{}, Canceled.run, .{&waiter});
    waiter.started.waitUncancelable(io);
    waiter.cancel.store(true, .release);
    waiter_thread.join();

    try testing.expectEqual(WaitResult.canceled, waiter.result);
    try testing.expectEqual(Begin.wait, slot.begin());
    slot.end();
}

test "U3: an owner's failure wakes the waiter, which becomes the next owner" {
    const io = io_mod.getIo();
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();
    try testing.expectEqual(Begin.owner, slot.begin());

    const Successor = struct {
        slot: *Slot,
        began: std.Io.Event = .unset,
        first: Begin = .owner,
        result: WaitResult = .canceled,
        second: Begin = .wait,
        cancel: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.first = self.slot.begin();
            self.began.set(io_mod.getIo());
            self.result = self.slot.wait(&self.cancel);
            self.second = self.slot.begin();
            if (self.second == .owner) self.slot.end();
        }
    };
    var successor: Successor = .{ .slot = slot };
    const thread = try std.Thread.spawn(.{}, Successor.run, .{&successor});
    successor.began.waitUncancelable(io);
    slot.end();
    thread.join();

    try testing.expectEqual(Begin.wait, successor.first);
    try testing.expectEqual(WaitResult.finished, successor.result);
    try testing.expectEqual(Begin.owner, successor.second);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try slot.currentDestination(arena.allocator())) == null);
}

test "U4: the mark is kept per session and turn: a new turn clears it, and another session is unaffected" {
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();

    try slot.recordMark("session-a", 5, .declined);
    try slot.recordMark("session-b", 5, .no_answer);
    try testing.expectEqual(setup.Mark.declined, slot.markFor("session-a", 5));
    try testing.expectEqual(setup.Mark.none, slot.markFor("session-c", 5));
    try testing.expectEqual(setup.Mark.none, slot.markFor("session-a", 6));
    try testing.expectEqual(setup.Mark.none, slot.markFor("session-a", 5));
    try testing.expectEqual(setup.Mark.no_answer, slot.markFor("session-b", 5));
}

test "U4: a turn id of 0 never clears a mark, and a mark cannot be recorded without a turn" {
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();

    try slot.recordMark("session-a", 5, .declined);
    try testing.expectEqual(setup.Mark.declined, slot.markFor("session-a", 0));
    try testing.expectEqual(setup.Mark.declined, slot.markFor("session-a", 5));
    try testing.expectError(error.NoActiveTurn, slot.recordMark("session-a", 0, .no_answer));
    try testing.expectEqual(setup.Mark.declined, slot.markFor("session-a", 5));
    try slot.recordMark("session-a", 5, .none);
    try testing.expectEqual(setup.Mark.none, slot.markFor("session-a", 5));
}

test "U4: a session that ends takes its own mark with it, and no other session's" {
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();

    try slot.recordMark("session-a", 5, .declined);
    try slot.recordMark("session-b", 5, .no_answer);
    slot.forgetSession("session-a");
    try testing.expectEqual(setup.Mark.none, slot.markFor("session-a", 5));
    try testing.expectEqual(setup.Mark.no_answer, slot.markFor("session-b", 5));
    slot.forgetSession(null);
    slot.forgetSession("session-never-seen");
    try testing.expectEqual(setup.Mark.no_answer, slot.markFor("session-b", 5));
}

test "U2: a call without a session key never touches the mark" {
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();
    try slot.recordMark("session-a", 5, .declined);

    try testing.expectEqual(setup.Mark.none, slot.markFor(null, 5));
    try testing.expectEqual(setup.Mark.none, slot.markFor(null, 6));
    try slot.recordMark(null, 5, .no_answer);
    try slot.recordMark(null, 0, .no_answer);
    try slot.recordMark(null, 5, .none);
    try testing.expectEqual(setup.Mark.declined, slot.markFor("session-a", 5));
}

const OwnerWork = struct {
    slot: *Slot,
    working: std.Io.Event = .unset,
    release: std.Io.Event = .unset,

    /// The setup's own work (a REST call, a prompt or the write) runs between the
    /// `working` signal and `end`, outside the mutex.
    fn run(self: *OwnerWork) void {
        const io = io_mod.getIo();
        _ = self.slot.begin();
        self.working.set(io);
        self.release.waitUncancelable(io);
        self.slot.end();
    }
};

const Reader = struct {
    slot: *Slot,
    done: std.Io.Event = .unset,
    mark: setup.Mark = .none,
    begin: Begin = .owner,

    fn run(self: *Reader) void {
        self.begin = self.slot.begin();
        self.mark = self.slot.markFor("session-a", 5);
        self.done.set(io_mod.getIo());
    }
};

test "R1.5: the mutex is free while a setup's own work runs" {
    const io = io_mod.getIo();
    const slot = try Slot.create(testing.allocator);
    defer slot.destroy();
    try slot.recordMark("session-a", 5, .declined);

    var owner: OwnerWork = .{ .slot = slot };
    const owner_thread = try std.Thread.spawn(.{}, OwnerWork.run, .{&owner});
    owner.working.waitUncancelable(io);

    var reader: Reader = .{ .slot = slot };
    const reader_thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    const reader_done = reader.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    owner.release.set(io);
    owner_thread.join();
    reader_thread.join();

    try reader_done;
    try testing.expectEqual(Begin.wait, reader.begin);
    try testing.expectEqual(setup.Mark.declined, reader.mark);
}
