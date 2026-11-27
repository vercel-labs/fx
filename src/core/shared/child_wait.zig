const std = @import("std");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

const poll_interval_ms = 10;

/// Waits until `child` exits or `deadline` passes. On timeout it returns
/// `error.Timeout` and leaves the child running: the caller stops it with
/// `killAndReap`.
pub fn waitWithDeadline(
    child: *std.process.Child,
    deadline: std.Io.Clock.Timestamp,
) !std.process.Child.Term {
    const io = io_mod.getIo();
    while (true) {
        if (try reapExited(child)) |term| return term;

        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) return error.Timeout;
        // std has no timed wait for a child, and every caller caps the wait at a few seconds.
        try std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake);
    }
}

/// Kills a child that is still running and reaps it, so no owned process
/// outlives the caller. `Child.kill` sends SIGTERM and then waits without a
/// bound, so a child that ignores SIGTERM would block forever. SIGKILL cannot
/// be ignored, so the blocking wait below returns.
pub fn killAndReap(child: *std.process.Child, label: []const u8) void {
    const pid = child.id orelse return;
    std.posix.kill(pid, std.posix.SIG.KILL) catch |err| switch (err) {
        // ESRCH: no such process, so nothing is left to kill and waitpid returns at once.
        error.ProcessNotFound => {},
        // Any other failure could leave the wait blocked forever, so the child is not waited for.
        else => {
            debug_trace.logf("process", "{s} child kill failed pid={d} err={s}", .{ label, pid, @errorName(err) });
            return;
        },
    };
    var status: c_int = undefined;
    while (true) switch (std.posix.errno(std.c.waitpid(pid, &status, 0))) {
        .INTR => continue,
        else => break,
    };
    child.id = null;
}

fn reapExited(child: *std.process.Child) !?std.process.Child.Term {
    const pid = child.id orelse return error.WaitFailed;
    var status: c_int = undefined;
    const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (waited == 0) return null;
    if (waited != pid) return error.WaitFailed;

    child.id = null;
    return termFromStatus(status);
}

fn termFromStatus(status: c_int) std.process.Child.Term {
    const raw_status: u32 = @bitCast(status);
    return if (std.c.W.IFEXITED(raw_status))
        .{ .exited = std.c.W.EXITSTATUS(raw_status) }
    else if (std.c.W.IFSIGNALED(raw_status))
        .{ .signal = std.c.W.TERMSIG(raw_status) }
    else if (std.c.W.IFSTOPPED(raw_status))
        .{ .stopped = std.c.W.STOPSIG(raw_status) }
    else
        .{ .unknown = raw_status };
}

test "killAndReap stops a child that ignores SIGTERM" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "trap '' TERM; exec sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killAndReap(&child, "test child");

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(100),
    });
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(error.Timeout, waitWithDeadline(&child, deadline));
    killAndReap(&child, "test child");
    const elapsed_ms = io_mod.milliTimestamp() - started_ms;
    try std.testing.expect(elapsed_ms < 2000);
    try std.testing.expect(child.id == null);
}

test "waitWithDeadline times out a slow child" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "5" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killAndReap(&child, "test child");

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(100),
    });
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(error.Timeout, waitWithDeadline(&child, deadline));
    const elapsed_ms = io_mod.milliTimestamp() - started_ms;
    try std.testing.expect(elapsed_ms < 1000);
}

test "waitWithDeadline returns the exit status of a finished child" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{"true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killAndReap(&child, "test child");

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromSeconds(5),
    });
    const term = try waitWithDeadline(&child, deadline);
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}
