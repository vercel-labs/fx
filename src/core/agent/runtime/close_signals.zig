//! SIGHUP and SIGTERM close fx. `handler` only wakes the closer thread,
//! which saves the model request in flight outside signal context, so the
//! next launch resumes it without a question (`RequestRecovery.closeActive`,
//! `tests/tla/recovery/Resume.tla` NoQuestionAfterCleanClose). The thread then
//! writes the host's terminal restore, if any, and re-raises the signal with
//! its default action, so fx still ends by that signal.

const std = @import("std");
const debug_trace = @import("../../shared/debug_trace.zig");
const request_recovery = @import("request_recovery.zig");

var close_pipe: [2]std.posix.fd_t = .{ -1, -1 };
var close_signal: std.atomic.Value(i32) = .init(0);
var restore_bytes: []const u8 = "";
var started = false;

/// Install for SIGHUP and SIGTERM once `start` returned true. Must remain
/// async-signal-safe: one atomic exchange and one `write(2)`.
pub fn handler(sig: std.posix.SIG) callconv(.c) void {
    if (close_signal.cmpxchgStrong(0, @intCast(@backingInt(sig)), .seq_cst, .seq_cst) != null) return;
    const byte = [1]u8{1};
    _ = std.c.write(close_pipe[1], &byte, 1);
}

/// Starts the closer thread once per process. `restore` is written to stdout
/// before fx re-raises: the TUI's terminal reset, or nothing for ACP. It must
/// outlive the process, such as a comptime string. False when the thread
/// cannot run; the caller then keeps a handler of its own.
pub fn start(restore: []const u8) bool {
    if (started) return true;
    // Close-on-exec, so the commands and servers fx starts do not inherit it.
    close_pipe = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return false;
    restore_bytes = restore;
    const thread = std.Thread.spawn(.{}, closerMain, .{}) catch |err| {
        debug_trace.logf("app", "closer unavailable err={s}", .{@errorName(err)});
        _ = std.c.close(close_pipe[0]);
        _ = std.c.close(close_pipe[1]);
        close_pipe = .{ -1, -1 };
        return false;
    };
    thread.detach();
    started = true;
    return true;
}

fn closerMain() void {
    var byte: [1]u8 = undefined;
    while (true) {
        const read = std.c.read(close_pipe[0], &byte, 1);
        if (read == 1) break;
        if (read < 0 and std.posix.errno(read) == .INTR) continue;
        return;
    }
    const signal_number = close_signal.load(.seq_cst);
    const saved = request_recovery.RequestRecovery.closeActive();
    debug_trace.logf("app", "event=closing signal={d} record_saved={}", .{ signal_number, saved });
    if (restore_bytes.len > 0) _ = std.c.write(std.posix.STDOUT_FILENO, restore_bytes.ptr, restore_bytes.len);
    const sig: std.posix.SIG = @fromBackingInt(@intCast(signal_number));
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &default_action, null);
    _ = std.c.raise(sig);
}
