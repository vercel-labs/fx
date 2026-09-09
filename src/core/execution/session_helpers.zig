const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const process_tree = @import("process_tree.zig");
const scope_memory = @import("scope_memory.zig");

const Allocator = std.mem.Allocator;
const retirement_ms = 5_000;
const cooperative_ms = 700;
const poll_ms = 20;

pub const CleanupOutcome = enum { clean, incomplete };

const Supervisor = enum { running, dead, retry, unavailable };
const RetirementAction = enum { observe, cooperate, kill_supervisor, takeover, incomplete };

fn retirementAction(supervisor: Supervisor, started: ?i64, deadline: i64, now: i64) RetirementAction {
    if (supervisor == .unavailable) return .incomplete;
    const start = started orelse return .observe;
    if (now >= deadline) return .incomplete;
    if (supervisor == .dead) return .takeover;
    if (supervisor == .retry or now - start < cooperative_ms) return .cooperate;
    return .kill_supervisor;
}

fn cleanupOutcome(complete: bool, prior_incomplete: bool) CleanupOutcome {
    return if (complete and !prior_incomplete) .clean else .incomplete;
}

fn awakeMillis() i64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(io_mod.getIo()).nanoseconds, std.time.ns_per_ms));
}

fn pause() void {
    io_mod.sleep(poll_ms * std.time.ns_per_ms);
}

fn closeChildStreams(child: *std.process.Child) void {
    inline for (.{ "stdin", "stdout", "stderr" }) |field| {
        if (@field(child, field)) |file| file.close(io_mod.getIo());
        @field(child, field) = null;
    }
}

const Retained = struct { child: std.process.Child, control: std.Io.File };

/// A reserved worker or the monitor, never both, owns this record. The Tracker
/// owns only scanner scratch: all membership stays in this one shared mapping.
const Scope = struct {
    mapping: scope_memory.Mapping,
    tracker: process_tree.Tracker,
    retained: ?Retained = null,
    started: ?i64 = null,
    deadline: i64 = 0,
    kill_sent: bool = false,
    wait_unavailable: bool = false,
    reason: ?Reason = null,

    const Reason = enum {
        control_shutdown,
        supervisor_wait,
        supervisor_signal,
        membership_invalid,
        root_unpublished,
        membership_incomplete,
        refresh_failed,
        signal_incomplete,
        deadline,
    };

    fn create(alloc: Allocator) !*Scope {
        const scope = try alloc.create(Scope);
        errdefer alloc.destroy(scope);
        var mapping = try scope_memory.Mapping.create();
        errdefer mapping.deinit();
        const tracker = try process_tree.Tracker.initShared(alloc, mapping.state);
        scope.* = .{ .mapping = mapping, .tracker = tracker };
        return scope;
    }

    fn destroy(self: *Scope, alloc: Allocator) void {
        if (self.retained) |*retained| {
            closeChildStreams(&retained.child);
            retained.control.close(io_mod.getIo());
        }
        self.tracker.deinit();
        self.mapping.deinit();
        alloc.destroy(self);
    }

    fn note(self: *Scope, reason: Reason) void {
        if (self.reason != null) return;
        self.reason = reason;
        debug_trace.logf("core", "session helper cleanup incomplete root={any} reason={s}", .{ self.mapping.state.rootPid(), @tagName(reason) });
    }

    fn outcome(self: *const Scope) CleanupOutcome {
        return cleanupOutcome(self.mapping.state.isComplete(), self.reason != null);
    }

    fn pollChild(self: *Scope, child: *std.process.Child) Supervisor {
        const pid = child.id orelse {
            // A collector can consume the exit before handing us this child.
            closeChildStreams(child);
            return .dead;
        };
        if (self.wait_unavailable) return .unavailable;
        var status: c_int = 0;
        const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (result == 0) return .running;
        if (result == pid) {
            const bits: u32 = @bitCast(status);
            if (!std.c.W.IFEXITED(bits) and !std.c.W.IFSIGNALED(bits)) return .retry;
            child.id = null;
            closeChildStreams(child);
            return .dead;
        }
        if (std.posix.errno(result) == .INTR) return .retry;
        // ECHILD is not proof of death. Do not signal this PID or become a
        // writer if some other waiter violated the exclusive wait authority.
        self.wait_unavailable = true;
        self.note(.supervisor_wait);
        return .unavailable;
    }

    fn signalSupervisor(self: *Scope, child: *const std.process.Child, signal: std.posix.SIG) void {
        const pid = child.id orelse return;
        std.debug.assert(!self.wait_unavailable);
        // The sole waiter still owns this unreaped child PID, so it cannot be
        // recycled between waitpid(WNOHANG) and this individual signal.
        std.posix.kill(pid, signal) catch |err| {
            if (err != error.ProcessNotFound) self.note(.supervisor_signal);
        };
    }

    fn request(self: *Scope, child: *std.process.Child, control: std.Io.File, started: i64) void {
        if (self.started != null) {
            self.deadline = @min(self.deadline, started + retirement_ms);
            return;
        }
        self.started = started;
        self.deadline = started + retirement_ms;
        // Borrow the descriptor. In particular retireBorrowed must not close
        // the caller's fd, even when shutdown succeeds or cleanup times out.
        const result = std.c.shutdown(control.handle, std.c.SHUT.RDWR);
        if (result != 0 and std.posix.errno(result) != .NOTCONN) self.note(.control_shutdown);
        if (self.pollChild(child) == .running) self.signalSupervisor(child, std.posix.SIG.CONT);
    }

    fn observeSupervisor(self: *Scope, child: *std.process.Child, control: std.Io.File) Supervisor {
        const state = self.pollChild(child);
        const now = awakeMillis();
        if (state == .dead and self.started == null) self.request(child, control, now);
        if (retirementAction(state, self.started, self.deadline, now) == .kill_supervisor and !self.kill_sent) {
            self.signalSupervisor(child, std.posix.SIG.KILL);
            self.kill_sent = true;
        }
        return state;
    }

    fn settle(self: *Scope, child: *std.process.Child, supervisor: Supervisor) ?CleanupOutcome {
        switch (retirementAction(supervisor, self.started, self.deadline, awakeMillis())) {
            .observe, .cooperate, .kill_supervisor => return null,
            .incomplete => {
                // Even if earlier scans exhausted the common budget, request
                // the final signal only for a freshly verified owned child.
                if (supervisor == .running and !self.kill_sent) {
                    self.signalSupervisor(child, std.posix.SIG.KILL);
                    self.kill_sent = true;
                }
                self.note(if (supervisor == .unavailable) .supervisor_wait else .deadline);
                return .incomplete;
            },
            .takeover => {},
        }
        std.debug.assert(child.id == null);
        self.mapping.state.validate() catch {
            self.note(.membership_invalid);
            return .incomplete;
        };
        const root = self.mapping.state.rootPid() orelse {
            self.note(.root_unpublished);
            return .incomplete;
        };
        // Only confirmed supervisor death permits this write. refresh follows
        // recorded living members too; never scan all children of the fx PID.
        self.tracker.refresh(root) catch |err| {
            if (self.reason == null) debug_trace.logf("core", "session helper takeover refresh failed root={d} err={s}", .{ root, @errorName(err) });
            self.note(.refresh_failed);
        };
        if (!self.mapping.state.isComplete()) self.note(.membership_incomplete);
        if (awakeMillis() >= self.deadline) {
            self.note(.deadline);
            return .incomplete;
        }
        const live = self.tracker.scanLiveness();
        if (live == .empty) return self.outcome();
        const delivery = self.tracker.signalAllChecked(std.posix.SIG.KILL);
        if (delivery.incomplete) self.note(.signal_incomplete);
        // An incomplete ledger can never report empty, even after its known
        // targets die. Continue after delivery to catch later forks and verify
        // termination; zero delivery under uncertainty is incomplete, not clean.
        if (live == .incomplete and delivery.delivered == 0) {
            self.note(.membership_incomplete);
            return .incomplete;
        }
        return null;
    }

    fn retireBorrowed(self: *Scope, child: *std.process.Child, control: std.Io.File) CleanupOutcome {
        self.request(child, control, awakeMillis());
        defer closeChildStreams(child);
        while (true) {
            const state = self.observeSupervisor(child, control);
            if (self.settle(child, state)) |result| return result;
            pause();
        }
    }
};

/// Callers provide a thread-safe allocator, keep this Owner at a stable address
/// after reserve, and quiesce all workers before clear. Only the monitor touches
/// retained records; the mutex protects admission and ownership transfers, not
/// process work. clear permanently stops admission and joins that one monitor.
pub const Owner = struct {
    const capacity = 32;
    const Slot = union(enum) { empty, preparing, reserved: *Scope, retained: *Scope };

    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    slots: [capacity]Slot = @splat(.empty),
    monitor: ?std.Thread = null,
    monitor_starting: bool = false,
    closing_at: ?i64 = null,
    cleared: bool = false,
    cleanup: CleanupOutcome = .clean,

    pub fn init(alloc: Allocator) Owner {
        return .{ .alloc = alloc };
    }

    fn reserve(self: *Owner) !usize {
        if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.ScopeMappingUnsupported;
        return self.reserveWith(spawnMonitor);
    }

    fn spawnMonitor(self: *Owner) !std.Thread {
        return std.Thread.spawn(.{ .allocator = self.alloc }, monitorMain, .{self});
    }

    fn reserveWith(self: *Owner, comptime spawn_monitor: anytype) !usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const index = blk: {
            if (self.closing_at != null) {
                self.mutex.unlock(io);
                return error.SessionHelperOwnerClosed;
            }
            for (&self.slots, 0..) |*slot, index| {
                if (slot.* != .empty) continue;
                slot.* = .preparing;
                break :blk index;
            }
            self.mutex.unlock(io);
            return error.SessionHelperCapacityExceeded;
        };
        self.mutex.unlock(io);
        errdefer {
            self.mutex.lockUncancelable(io);
            self.slots[index] = .empty;
            self.mutex.unlock(io);
        }
        const scope = try Scope.create(self.alloc);
        errdefer scope.destroy(self.alloc);
        // Spawn before execution, not under the entry's completion mutex. A
        // failed spawn leaves no reservation or child; a later call may retry.
        try self.ensureMonitor(spawn_monitor);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.slots[index] = .{ .reserved = scope };
        return index;
    }

    fn ensureMonitor(self: *Owner, comptime spawn_monitor: anytype) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        while (self.monitor_starting) self.changed.waitUncancelable(io, &self.mutex);
        if (self.monitor != null) {
            self.mutex.unlock(io);
            return;
        }
        self.monitor_starting = true;
        self.mutex.unlock(io);
        const thread = spawn_monitor(self) catch |err| {
            self.mutex.lockUncancelable(io);
            self.monitor_starting = false;
            self.changed.broadcast(io);
            self.mutex.unlock(io);
            return err;
        };
        self.mutex.lockUncancelable(io);
        self.monitor = thread;
        self.monitor_starting = false;
        self.changed.broadcast(io);
        self.mutex.unlock(io);
    }

    fn reservedScope(self: *Owner, index: usize) *Scope {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.slots[index].reserved;
    }

    fn release(self: *Owner, index: usize) void {
        const scope = self.reservedScope(index);
        scope.destroy(self.alloc);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.slots[index] = .empty;
    }

    fn recordOutcome(self: *Owner, outcome: CleanupOutcome) void {
        if (outcome == .clean) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.cleanup = .incomplete;
    }

    fn retain(self: *Owner, index: usize, retained: Retained) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        std.debug.assert(self.monitor != null and self.closing_at == null);
        const scope = self.slots[index].reserved;
        scope.retained = retained;
        self.slots[index] = .{ .retained = scope };
        self.changed.broadcast(io_mod.getIo());
    }

    fn monitorMain(self: *Owner) void {
        const io = io_mod.getIo();
        while (true) {
            var scopes: [capacity]?*Scope = @splat(null);
            self.mutex.lockUncancelable(io);
            while (self.closing_at == null) {
                const active = for (self.slots) |slot| {
                    if (slot == .retained) break true;
                } else false;
                if (active) break;
                self.changed.waitUncancelable(io, &self.mutex);
            }
            const closing = self.closing_at;
            for (self.slots, 0..) |slot, index| {
                if (slot == .retained) scopes[index] = slot.retained;
            }
            self.mutex.unlock(io);
            var states: [capacity]Supervisor = @splat(.retry);
            var count: usize = 0;
            // Request every scope and poll/escalate every supervisor before
            // doing any membership scans. No per-slot blocking retirement.
            for (scopes, 0..) |maybe_scope, index| {
                const scope = maybe_scope orelse continue;
                count += 1;
                const retained = &scope.retained.?;
                if (closing) |started| scope.request(&retained.child, retained.control, started);
                states[index] = scope.observeSupervisor(&retained.child, retained.control);
            }
            if (closing != null and count == 0) return;
            for (scopes, 0..) |maybe_scope, index| {
                const scope = maybe_scope orelse continue;
                if (scope.settle(&scope.retained.?.child, states[index])) |outcome| {
                    self.recordOutcome(outcome);
                    // The slot remains unavailable through destruction. The
                    // monitor is its only consumer; clear touches no records.
                    scope.destroy(self.alloc);
                    self.mutex.lockUncancelable(io);
                    self.slots[index] = .empty;
                    self.mutex.unlock(io);
                    count -= 1;
                }
            }
            if (closing != null and count == 0) return;
            pause();
        }
    }

    pub fn clear(self: *Owner) CleanupOutcome {
        if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return .clean;
        const io = io_mod.getIo();
        const started = awakeMillis();
        self.mutex.lockUncancelable(io);
        // Workers must have released or transferred every reservation first.
        std.debug.assert(!self.monitor_starting);
        for (self.slots) |slot| std.debug.assert(slot != .preparing and slot != .reserved);
        if (self.closing_at != null) {
            while (!self.cleared) self.changed.waitUncancelable(io, &self.mutex);
            const result = self.cleanup;
            self.mutex.unlock(io);
            return result;
        }
        self.closing_at = started;
        self.changed.broadcast(io);
        const thread = self.monitor;
        self.mutex.unlock(io);
        if (thread) |value| value.join();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.monitor = null;
        self.cleared = true;
        self.changed.broadcast(io);
        return self.cleanup;
    }
};

/// A command worker owns the lease until terminal publication. finish(true)
/// runs under the cancellation lock; finish(false) must run outside that lock.
pub const Lease = struct {
    owner: *Owner,
    slot: ?usize = null,
    pending: ?Retained = null,

    pub fn reserve(self: *Lease) !void {
        std.debug.assert(self.slot == null and self.pending == null);
        self.slot = try self.owner.reserve();
    }

    fn release(self: *Lease) void {
        std.debug.assert(self.pending == null);
        self.owner.release(self.slot.?);
        self.slot = null;
    }

    /// Borrows the slot's sole mapping until release or finish.
    pub fn mapping(self: *Lease) *scope_memory.Mapping {
        return &self.owner.reservedScope(self.slot.?).mapping;
    }

    pub fn retain(self: *Lease, child: std.process.Child, control: std.Io.File) void {
        std.debug.assert(self.slot != null and self.pending == null);
        self.pending = .{ .child = child, .control = control };
    }

    /// Borrows control without closing it. Consumes the child's wait/stdio
    /// resources on reaping; the caller still releases the reservation. A
    /// deadline can leave child.id non-null: no unbounded wait is hidden here.
    pub fn retireBorrowed(self: *Lease, child: *std.process.Child, control: std.Io.File) CleanupOutcome {
        std.debug.assert(self.pending == null);
        const result = self.owner.reservedScope(self.slot.?).retireBorrowed(child, control);
        self.owner.recordOutcome(result);
        return result;
    }

    /// Includes uncertainty recorded by an earlier borrowed retirement. The
    /// worker consumes this outcome before publishing the command snapshot.
    pub fn finish(self: *Lease, keep: bool) CleanupOutcome {
        const slot = self.slot orelse return .clean;
        var result: CleanupOutcome = if (self.owner.reservedScope(slot).reason != null) .incomplete else .clean;
        if (self.pending) |*pending| {
            if (keep) {
                self.owner.retain(slot, pending.*);
                self.pending = null;
                self.slot = null;
                return .clean;
            }
            result = self.owner.reservedScope(slot).retireBorrowed(&pending.child, pending.control);
            self.owner.recordOutcome(result);
            pending.control.close(io_mod.getIo());
            self.pending = null;
        }
        self.release();
        return result;
    }
};

/// A private, bidirectional supervisor channel. Only fd 0 is inherited by the
/// supervisor; the launched shell receives a different stdin pipe.
pub fn openControlPair() ![2]std.Io.File {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0)
        return error.SessionHelperChannelFailed;
    errdefer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    for (fds) |fd| {
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) == -1)
            return error.SessionHelperChannelFailed;
    }
    return .{
        .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

test "session helper retirement policy requires death before takeover and shares deadline" {
    try std.testing.expectEqual(RetirementAction.observe, retirementAction(.running, null, 0, 100));
    try std.testing.expectEqual(RetirementAction.cooperate, retirementAction(.running, 100, 5100, 799));
    try std.testing.expectEqual(RetirementAction.kill_supervisor, retirementAction(.running, 100, 5100, 800));
    try std.testing.expectEqual(RetirementAction.takeover, retirementAction(.dead, 100, 5100, 800));
    try std.testing.expectEqual(RetirementAction.cooperate, retirementAction(.retry, 100, 5100, 800));
    try std.testing.expectEqual(RetirementAction.incomplete, retirementAction(.unavailable, null, 0, 0));
    for (0..Owner.capacity) |_| {
        try std.testing.expectEqual(RetirementAction.incomplete, retirementAction(.running, 100, 5100, 5100));
        try std.testing.expectEqual(RetirementAction.incomplete, retirementAction(.dead, 100, 5100, 5100));
    }
}

test "session helper reservations own one mapping and one lazy monitor" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    try std.testing.expect(owner.monitor == null);
    var leases: [Owner.capacity]Lease = undefined;
    for (&leases) |*lease| {
        lease.* = .{ .owner = &owner };
        try lease.reserve();
        const scope = owner.reservedScope(lease.slot.?);
        try std.testing.expect(scope.tracker.shared.? == lease.mapping().state);
        try std.testing.expectEqual(@as(usize, 0), scope.tracker.processes.capacity);
    }
    try std.testing.expect(owner.monitor != null);
    var overflow = Lease{ .owner = &owner };
    try std.testing.expectError(error.SessionHelperCapacityExceeded, overflow.reserve());
    try std.testing.expect(overflow.slot == null);
    const first = leases[0].slot;
    leases[0].release();
    try leases[0].reserve();
    try std.testing.expectEqual(first, leases[0].slot);
    for (&leases) |*lease| try std.testing.expectEqual(CleanupOutcome.clean, lease.finish(false));
    try std.testing.expectEqual(CleanupOutcome.clean, owner.clear());
    try std.testing.expect(owner.monitor == null);
    try std.testing.expectError(error.SessionHelperOwnerClosed, overflow.reserve());
}

test "session helper partial reservation allocation failure leaves no monitor or slot" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owner = Owner.init(failing.allocator());
    var lease = Lease{ .owner = &owner };
    try std.testing.expectError(error.OutOfMemory, lease.reserve());
    try std.testing.expectEqual(CleanupOutcome.clean, lease.finish(false));
    try std.testing.expectEqual(CleanupOutcome.clean, lease.finish(true));
    try std.testing.expect(lease.slot == null and owner.monitor == null);
    for (owner.slots) |slot| try std.testing.expect(slot == .empty);
    try std.testing.expectEqual(CleanupOutcome.clean, owner.clear());
}

fn testSpawn(argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

fn testReap(child: *std.process.Child) !void {
    const pid = child.id orelse return;
    const deadline = awakeMillis() + 1500;
    while (awakeMillis() < deadline) {
        var status: c_int = 0;
        const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (result == pid) {
            child.id = null;
            closeChildStreams(child);
            return;
        }
        if (result < 0 and std.posix.errno(result) != .INTR) return error.TestWaitFailed;
        pause();
    }
    return error.TestReapDeadline;
}

fn testDispose(child: *std.process.Child) void {
    if (child.id) |pid| {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        // A killed fixture child that outlives the reap deadline stays a
        // zombie of the test process; it cannot turn a failed test green.
        testReap(child) catch {};
    }
    closeChildStreams(child);
}

fn testOwnerEmpty(owner: *Owner) bool {
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    for (owner.slots) |slot| if (slot != .empty) return false;
    return true;
}

fn testWaitOwnerEmpty(owner: *Owner) !void {
    const deadline = awakeMillis() + retirement_ms + 1000;
    while (awakeMillis() < deadline) {
        if (testOwnerEmpty(owner)) return;
        pause();
    }
    return error.TestMonitorDeadline;
}

fn testReadPid(file: std.Io.File) !std.posix.pid_t {
    var buffer: [32]u8 = undefined;
    var length: usize = 0;
    const deadline = awakeMillis() + 1500;
    while (awakeMillis() < deadline and length < buffer.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, poll_ms) <= 0) continue;
        const count = std.c.read(file.handle, buffer[length..].ptr, buffer.len - length);
        if (count <= 0) return error.TestPidReadFailed;
        length += @intCast(count);
        if (std.mem.findScalar(u8, buffer[0..length], '\n')) |end| {
            return std.fmt.parseInt(std.posix.pid_t, buffer[0..end], 10);
        }
    }
    return error.TestPidReadDeadline;
}

test "session helper owner borrowed retirement preserves control and handles collected child" {
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    var lease = Lease{ .owner = &owner };
    try lease.reserve();
    defer _ = lease.finish(false);
    const pair = try openControlPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    var helper = try testSpawn(&.{ "/bin/sleep", "30" });
    defer testDispose(&helper);
    try owner.reservedScope(lease.slot.?).tracker.refresh(helper.id.?);
    const duplicate = std.c.fcntl(pair[0].handle, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (duplicate < 0) return error.TestDupFailed;
    var collected = std.mem.zeroes(std.process.Child);
    collected.stdin = .{ .handle = duplicate, .flags = .{ .nonblocking = false } };
    const outcome = lease.retireBorrowed(&collected, pair[0]);
    if (outcome == .incomplete) {
        // Native inspection may be unavailable even when all committed targets
        // die. Descriptor/target lifetime must still work, without false clean.
        try std.testing.expectEqual(Scope.Reason.refresh_failed, owner.reservedScope(lease.slot.?).reason.?);
        try std.testing.expect(!lease.mapping().state.isComplete());
    }
    try std.testing.expect(collected.id == null and collected.stdin == null);
    try std.testing.expect(std.c.fcntl(pair[0].handle, std.c.F.GETFD) >= 0);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(duplicate, std.c.F.GETFD));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), std.c.recv(pair[1].handle, &byte, 1, std.posix.MSG.DONTWAIT));
    try testReap(&helper);
    const repeated = lease.retireBorrowed(&collected, pair[0]);
    if (outcome == .incomplete) try std.testing.expectEqual(CleanupOutcome.incomplete, repeated);
}

test "session helper owner sticky incomplete still terminates committed members" {
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    var lease = Lease{ .owner = &owner };
    try lease.reserve();
    defer _ = lease.finish(false);
    const pair = try openControlPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    var helper = try testSpawn(&.{ "/bin/sleep", "30" });
    defer testDispose(&helper);
    const scope = owner.reservedScope(lease.slot.?);
    try scope.tracker.refresh(helper.id.?);
    @atomicStore(u32, &lease.mapping().state.scanning, 1, .release);
    var collected = std.mem.zeroes(std.process.Child);
    try std.testing.expectEqual(CleanupOutcome.incomplete, lease.retireBorrowed(&collected, pair[0]));
    try testReap(&helper);
    try std.testing.expect(!lease.mapping().state.isComplete());
    lease.release();
    try std.testing.expectEqual(CleanupOutcome.incomplete, owner.clear());
}

test "session helper owner clear resumes and escalates stopped supervisors in one budget" {
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    var pids: [8]std.posix.pid_t = undefined;
    for (&pids) |*pid| {
        var lease = Lease{ .owner = &owner };
        try lease.reserve();
        defer _ = lease.finish(false);
        const pair = try openControlPair();
        defer pair[1].close(io_mod.getIo());
        var child = testSpawn(&.{ "/bin/sleep", "30" }) catch |err| {
            pair[0].close(io_mod.getIo());
            return err;
        };
        lease.retain(child, pair[0]);
        pid.* = child.id.?;
        try std.testing.expectEqual(child.id, lease.pending.?.child.id);
        try owner.reservedScope(lease.slot.?).tracker.refresh(child.id.?);
        try std.posix.kill(child.id.?, std.posix.SIG.STOP);
        try std.testing.expectEqual(CleanupOutcome.clean, lease.finish(true));
        child.id = null;
    }
    const started = awakeMillis();
    _ = owner.clear();
    const elapsed = awakeMillis() - started;
    try std.testing.expect(elapsed >= cooperative_ms);
    try std.testing.expect(elapsed < 2500);
    for (pids) |pid| {
        var status: c_int = 0;
        try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(pid, &status, std.c.W.NOHANG));
        try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(@as(c_int, -1)));
    }
    try std.testing.expect(testOwnerEmpty(&owner));
    try std.testing.expect(owner.monitor == null);
}

test "session helper owner monitor takes over late descendants without touching sentinel" {
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    var sentinel = try testSpawn(&.{ "/bin/sleep", "30" });
    defer testDispose(&sentinel);
    var lease = Lease{ .owner = &owner };
    try lease.reserve();
    defer _ = lease.finish(false);
    var root = try testSpawn(&.{ "/bin/sh", "-c", "read gate; sleep 30 & printf '%s\\n' \"$!\"; wait" });
    defer testDispose(&root);
    try owner.reservedScope(lease.slot.?).tracker.refresh(root.id.?);
    const pair = try openControlPair();
    defer pair[1].close(io_mod.getIo());
    var supervisor = testSpawn(&.{ "/bin/sleep", "30" }) catch |err| {
        pair[0].close(io_mod.getIo());
        return err;
    };
    const supervisor_pid = supervisor.id.?;
    lease.retain(supervisor, pair[0]);
    try std.testing.expectEqual(CleanupOutcome.clean, lease.finish(true));
    supervisor.id = null;
    try root.stdin.?.writeStreamingAll(io_mod.getIo(), "launch\n");
    const late_pid = try testReadPid(root.stdout.?);
    try std.testing.expect(try process_tree.processIsAlive(std.testing.allocator, late_pid));
    try std.posix.kill(supervisor_pid, std.posix.SIG.KILL);
    try testWaitOwnerEmpty(&owner);
    try std.testing.expect(!try process_tree.processIsAlive(std.testing.allocator, late_pid));
    try testReap(&root);
    try std.testing.expect(try process_tree.processIsAlive(std.testing.allocator, sentinel.id.?));
    // Empty retained slots do not terminate the monitor or lose wait ownership
    // for a later command. Admission can reuse the retired slot immediately.
    try lease.reserve();
    lease.release();
    _ = owner.clear();
}

test "session helper owner rejected handoff retires without affecting another lease" {
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    var untouched = Lease{ .owner = &owner };
    try untouched.reserve();
    defer _ = untouched.finish(false);
    const original = untouched.mapping().state;
    var lease = Lease{ .owner = &owner };
    try lease.reserve();
    defer _ = lease.finish(false);
    const pair = try openControlPair();
    defer pair[1].close(io_mod.getIo());
    var child = testSpawn(&.{ "/bin/sleep", "30" }) catch |err| {
        pair[0].close(io_mod.getIo());
        return err;
    };
    lease.retain(child, pair[0]);
    try owner.reservedScope(lease.slot.?).tracker.refresh(child.id.?);
    _ = lease.finish(false);
    child.id = null;
    try std.testing.expect(lease.slot == null and lease.pending == null);
    try std.testing.expect(untouched.mapping().state == original);
    try std.testing.expect(original.rootPid() == null);
    untouched.release();
    _ = owner.clear();
}

test "session helper owner clean accounting requires complete membership without earlier failure" {
    try std.testing.expectEqual(CleanupOutcome.clean, cleanupOutcome(true, false));
    try std.testing.expectEqual(CleanupOutcome.incomplete, cleanupOutcome(false, false));
    try std.testing.expectEqual(CleanupOutcome.incomplete, cleanupOutcome(true, true));
    try std.testing.expectEqual(CleanupOutcome.incomplete, cleanupOutcome(false, true));
}

test "session helper owner failed monitor spawn rolls back mapping and permits retry" {
    const Failed = struct {
        fn spawn(_: *Owner) error{SystemResources}!std.Thread {
            return error.SystemResources;
        }
    };
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    try std.testing.expectError(error.SystemResources, owner.reserveWith(Failed.spawn));
    try std.testing.expect(owner.monitor == null and !owner.monitor_starting);
    try std.testing.expect(testOwnerEmpty(&owner));
    var lease = Lease{ .owner = &owner };
    try lease.reserve();
    lease.release();
    try std.testing.expectEqual(CleanupOutcome.clean, owner.clear());
}

test "session helper owner missing root and lost wait authority are incomplete not takeover" {
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    var lease = Lease{ .owner = &owner };
    try lease.reserve();
    defer _ = lease.finish(false);
    const pair = try openControlPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    var collected = std.mem.zeroes(std.process.Child);
    try std.testing.expectEqual(CleanupOutcome.incomplete, lease.retireBorrowed(&collected, pair[0]));
    try std.testing.expectEqual(Scope.Reason.root_unpublished, owner.reservedScope(lease.slot.?).reason.?);
    lease.release();

    try lease.reserve();
    var not_a_child = std.mem.zeroes(std.process.Child);
    // waitpid on ourselves fails with ECHILD. No signal or membership write
    // is authorized by that failure, even though this PID is certainly alive.
    not_a_child.id = std.c.getpid();
    try std.testing.expectEqual(CleanupOutcome.incomplete, lease.retireBorrowed(&not_a_child, pair[0]));
    try std.testing.expectEqual(Scope.Reason.supervisor_wait, owner.reservedScope(lease.slot.?).reason.?);
    try std.testing.expectEqual(std.c.getpid(), not_a_child.id.?);
    try std.testing.expectEqual(@as(u32, 0), lease.mapping().state.committed);
    try std.testing.expectEqual(@as(u32, 0), lease.mapping().state.scanning);
    lease.release();
    try std.testing.expectEqual(CleanupOutcome.incomplete, owner.clear());
}

test "session helper owner concurrent admission and quiescent clear join one monitor" {
    const Worker = struct {
        fn run(owner: *Owner, start: *std.atomic.Value(bool), failed: *std.atomic.Value(bool)) void {
            while (!start.load(.acquire)) pause();
            for (0..8) |_| {
                var lease = Lease{ .owner = owner };
                lease.reserve() catch {
                    failed.store(true, .release);
                    return;
                };
                lease.release();
            }
        }

        fn clear(owner: *Owner, result: *CleanupOutcome) void {
            result.* = owner.clear();
        }
    };
    var owner = Owner.init(std.testing.allocator);
    defer _ = owner.clear();
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, Worker.run, .{ &owner, &start, &failed });
        spawned += 1;
    }
    start.store(true, .release);
    for (threads) |thread| thread.join();
    spawned = 0;
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(testOwnerEmpty(&owner));
    try std.testing.expect(owner.monitor != null);
    var concurrent_result: CleanupOutcome = undefined;
    const clearer = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, Worker.clear, .{ &owner, &concurrent_result });
    const result = owner.clear();
    clearer.join();
    try std.testing.expectEqual(CleanupOutcome.clean, result);
    try std.testing.expectEqual(result, concurrent_result);
    try std.testing.expect(owner.monitor == null);
}
