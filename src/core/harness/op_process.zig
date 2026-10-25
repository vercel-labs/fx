//! `process`: a command's top-level Python announcing itself, which is how
//! the host knows exactly that a command ran Python, whatever started it.
//! `hello`: what this host offers the calling process.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const protocol = @import("protocol.zig");

pub const process = struct {
    pub const name = "process";
    pub const Args = struct {
        pid: i64,
        ppid: i64 = 0,
        executable: []const u8 = "",
        argv: []const []const u8 = &.{},
        cwd: []const u8 = "",
        version: []const u8 = "",
    };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const count = call.lease.processes.fetchAdd(1, .monotonic) + 1;
        const argv = std.mem.join(call.arena, " ", args.argv) catch "";
        debug_trace.logf("harness", "python ran node={s} call={s} pid={d} ppid={d} version={s} executable={s} cwd={s} argv={s} count={d}", .{
            call.lease.node_id,
            call.lease.parent_call_id,
            args.pid,
            args.ppid,
            args.version,
            args.executable,
            args.cwd,
            debug_trace.preview(argv, 200),
            count,
        });
        return .none;
    }
};

pub const hello = struct {
    pub const name = "hello";
    pub const Args = struct {};

    pub fn handle(call: *protocol.Call, _: Args) !protocol.Reply {
        return call.ok(.{
            .version = protocol.version,
            .node = call.lease.node_id,
            .ops = @import("ops.zig").names,
            .tools = call.lease.services != null,
            .kernels = call.lease.kernel != null,
            .processes = call.lease.processes.load(.monotonic),
        });
    }
};
