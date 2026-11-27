const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

/// Awaits the running background restore task's `Future` in tests without polling.
pub fn awaitRunning(restore: anytype) void {
    if (comptime !builtin.is_test) @compileError("restore_test_controls is test-only");
    const task = switch (restore.state) {
        .running => |t| t,
        .idle, .queued => return,
    };
    if (task.future) |*future| {
        future.await(io_mod.getIo());
        task.future = null;
    }
}
