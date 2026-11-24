const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("../core/shared/io.zig");

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

const Controls = struct {
    terminal_ready_path: []const u8,
    reap_ready_path: []const u8,
    release_path: []const u8,
};

/// A unit test waits on a gate for a thread to reach a point, and parks that thread
/// there until the test releases it. The waits use a condition, not a poll. Only test
/// builds park, so the file controls above stay the only hook the E2E tests use.
pub const Gate = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    reached: bool = false,
    released: bool = false,
    arrivals: usize = 0,

    /// Records that the point was reached, and lets the thread go on.
    pub fn mark(self: *Gate) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.reached = true;
        self.changed.broadcast(io_mod.getIo());
    }

    /// Records that the point was reached, and holds the thread until `release`.
    pub fn park(self: *Gate) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.reached = true;
        self.changed.broadcast(io_mod.getIo());
        while (!self.released) self.changed.waitUncancelable(io_mod.getIo(), &self.mutex);
    }

    /// Parks the first thread that arrives, and lets every later one pass.
    pub fn parkFirst(self: *Gate) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.arrivals += 1;
        if (self.arrivals > 1) return;
        self.reached = true;
        self.changed.broadcast(io_mod.getIo());
        while (!self.released) self.changed.waitUncancelable(io_mod.getIo(), &self.mutex);
    }

    /// Waits until the thread has reached the point.
    pub fn awaitReached(self: *Gate) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        while (!self.reached) self.changed.waitUncancelable(io_mod.getIo(), &self.mutex);
    }

    /// Whether the thread has reached the point.
    pub fn hasReached(self: *Gate) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.reached;
    }

    /// Lets a parked thread go on.
    pub fn release(self: *Gate) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.released = true;
        self.changed.broadcast(io_mod.getIo());
    }
};

/// Set by a unit test. `tail_gate` parks the worker's tail (`pauseAfterTerminalWrite`),
/// and `reap_gate` parks a reap before its join (`noteReapBeforeJoin`).
/// `close_detached_gate` parks a close after it leaves the shared table and before it
/// waits for the uses. `close_uses_gate` parks it after the wait and before it frees
/// the session. All are null outside a test.
pub var tail_gate: ?*Gate = null;
pub var reap_gate: ?*Gate = null;
pub var close_detached_gate: ?*Gate = null;
pub var close_uses_gate: ?*Gate = null;

pub fn noteCloseBeforeUseWait() void {
    if (comptime builtin.is_test) {
        if (close_detached_gate) |gate| gate.park();
    }
}

pub fn noteCloseAfterUseWait() void {
    if (comptime builtin.is_test) {
        if (uses_settled) |gate| gate.mark();
        if (uses_passed) |gate| gate.mark();
        if (close_uses_gate) |gate| gate.park();
    }
}

/// Set by a unit test. A close that waits for the uses marks `uses_settled` once it is
/// inside the wait (`noteUsesWaiting`), and marks `uses_passed` when the wait is over
/// (`noteCloseAfterUseWait`). Null outside a test.
pub var uses_settled: ?*Gate = null;
pub var uses_passed: ?*Gate = null;

pub fn noteUsesWaiting() void {
    if (comptime builtin.is_test) {
        if (uses_settled) |gate| gate.mark();
    }
}

/// Set by a unit test. `decision_gate` parks the first prompt that starts deciding its
/// session's turn, before it takes the line lock (`parkFirst`). Null outside a test.
pub var decision_gate: ?*Gate = null;

pub fn noteDecisionCheck() void {
    if (comptime builtin.is_test) {
        if (decision_gate) |gate| gate.parkFirst();
    }
}

/// Set by a unit test. A claim or a reap that waits for a taken turn's join marks
/// `join_settled` once it is inside the wait (`noteJoinWaiting`), and marks it again
/// with `join_passed` when the wait is over (`noteJoinPassed`). A wait that passes
/// while the join is still under way is the bug the test looks for. Null outside a test.
pub var join_settled: ?*Gate = null;
pub var join_passed: ?*Gate = null;

pub fn noteJoinWaiting() void {
    if (comptime builtin.is_test) {
        if (join_settled) |gate| gate.mark();
    }
}

pub fn noteJoinPassed() void {
    if (comptime builtin.is_test) {
        if (join_settled) |gate| gate.mark();
        if (join_passed) |gate| gate.mark();
    }
}

/// Set by a unit test. A member's leave parks after its record has left the audience and before
/// the requests it still owes are answered (`removeMemberLocked`). Null outside a test.
pub var leave_gate: ?*Gate = null;

pub fn noteMemberRemoved() void {
    if (comptime builtin.is_test) {
        if (leave_gate) |gate| gate.park();
    }
}

/// Set by a unit test. A session request parks after its first target decision, before it checks
/// what its connection follows (`requireParsedSessionTarget`). A leave in that window can make the
/// connection the main, and then the decision is read again. Null outside a test.
pub var target_decided_gate: ?*Gate = null;

pub fn noteTargetDecided() void {
    if (comptime builtin.is_test) {
        if (target_decided_gate) |gate| gate.park();
    }
}

/// Set by a unit test. An outbound request's wait marks `outbound_waiting` while it
/// holds the session's lock, just before it waits. An answer the test sends after that
/// mark can only be taken once the wait has released the lock, so the answer always
/// reaches a waiter that is already blocked. Null outside a test.
pub var outbound_waiting: ?*Gate = null;

pub fn noteOutboundWaiting() void {
    if (comptime builtin.is_test) {
        if (outbound_waiting) |gate| gate.mark();
    }
}

/// Set by a unit test. The next worker spawn fails once, as the system does when it
/// refuses a thread, so a test can see what a claim leaves behind when its worker never
/// starts. `takeSpawnFailure` clears it. Only a test build sets it.
pub var fail_next_spawn: bool = false;

/// Whether the next worker spawn fails. The setting is taken, not kept, so one failure
/// never reaches a later spawn. Outside a test build the answer is always no.
pub fn takeSpawnFailure() bool {
    if (comptime !builtin.is_test) return false;
    const fail = fail_next_spawn;
    fail_next_spawn = false;
    return fail;
}

// Only the fx binary's ACP tests set these controls
// (`tests/e2e/acp.test.ts`), so the libfx artifacts leave them out.
pub fn pauseAfterTerminalWrite() void {
    if (comptime builtin.is_test) {
        if (tail_gate) |gate| gate.park();
    }
    if (comptime build_options.libfx) return;
    const control = controls() orelse return;
    writeMarker(control.terminal_ready_path, "terminal_response_written") catch return;
    while (!pathExists(control.release_path)) {
        io_mod.sleep(std.time.ns_per_ms);
    }
}

pub fn noteReapBeforeJoin() void {
    if (comptime builtin.is_test) {
        if (reap_gate) |gate| gate.park();
    }
    if (comptime build_options.libfx) return;
    const control = controls() orelse return;
    writeMarker(control.reap_ready_path, "reap_before_join") catch {};
}

fn controls() ?Controls {
    return controlsFromPaths(
        io_mod.getenv("FX_TEST_ACP_PROMPT_TERMINAL_READY"),
        io_mod.getenv("FX_TEST_ACP_PROMPT_REAP_READY"),
        io_mod.getenv("FX_TEST_ACP_PROMPT_RELEASE"),
    );
}

fn controlsFromPaths(
    terminal_ready_path: ?[]const u8,
    reap_ready_path: ?[]const u8,
    release_path: ?[]const u8,
) ?Controls {
    return .{
        .terminal_ready_path = terminal_ready_path orelse return null,
        .reap_ready_path = reap_ready_path orelse return null,
        .release_path = release_path orelse return null,
    };
}

fn writeMarker(path: []const u8, contents: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .truncate = true,
        .permissions = private_file_permissions,
    });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), contents);
    try file.sync(io_mod.getIo());
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

test "prompt terminal controls require every path" {
    try std.testing.expect(controlsFromPaths("terminal", "reap", null) == null);
    try std.testing.expect(controlsFromPaths("terminal", "reap", "release") != null);
}
