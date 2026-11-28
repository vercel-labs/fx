//! The host fx gives the hooks engine on native builds: real processes, the
//! clock, and debug trace lines.

const std = @import("std");
const hooks = @import("../../hooks/hooks.zig");
const process = @import("process.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");

/// Fills `hooks.Host` with fx's process runner, clock, and trace lines.
pub const NativeHost = struct {
    /// The environment hooks start from; null means fx's own. Tests set it.
    base_env: ?*const std.process.Environ.Map = null,

    pub fn host(self: *NativeHost) hooks.Host {
        return .{
            .ctx = self,
            .run_process = runProcess,
            .now_ms = nowMs,
            .trace = trace,
        };
    }

    fn runProcess(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        request: hooks.host.ProcessRequest,
    ) std.mem.Allocator.Error!hooks.host.ProcessResult {
        const self: *NativeHost = @ptrCast(@alignCast(ctx));
        return process.run(alloc, io_mod.getIo(), self.base_env, request);
    }

    fn nowMs(ctx: *anyopaque) u64 {
        _ = ctx;
        return @intCast(@max(io_mod.milliTimestamp(), 0));
    }

    fn trace(ctx: *anyopaque, line: []const u8) void {
        _ = ctx;
        debug_trace.logf("hooks", "{s}", .{line});
    }
};
