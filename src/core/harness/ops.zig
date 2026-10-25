//! The op registry. Each op is a struct with `name`, `Args` (the typed
//! arguments; unknown fields are refused) and
//! `fn handle(call: *protocol.Call, args: Args) !protocol.Reply`. A new op,
//! such as `fs.read` or `store.set`, is a new handler file plus one line in
//! `all`; the dispatcher below never changes.
const std = @import("std");
const protocol = @import("protocol.zig");

pub const all = .{
    @import("op_process.zig").process,
    @import("op_process.zig").hello,
    @import("op_tool.zig").tool,
    @import("op_tool.zig").tools,
    @import("op_agent.zig").agent,
    @import("op_completion.zig").completion,
    @import("op_kernel.zig").run,
    @import("op_kernel.zig").status,
    @import("op_kernel.zig").stop,
    @import("op_kernel.zig").restart,
    @import("op_kernel.zig").list,
};

/// The names every op answers to, for `hello`.
pub const names = blk: {
    var list: [all.len][]const u8 = undefined;
    for (all, 0..) |Op, index| list[index] = Op.name;
    const final = list;
    break :blk &final;
};

pub fn dispatch(call: *protocol.Call, op: []const u8, args: std.json.Value) !protocol.Reply {
    inline for (all) |Op| {
        if (std.mem.eql(u8, op, Op.name)) {
            const parsed = protocol.parseArgs(Op.Args, call.arena, args) catch |err| {
                if (err == error.OutOfMemory) return err;
                return call.fail(.bad_request, "invalid arguments for {s}: {s}", .{ Op.name, @errorName(err) });
            };
            return Op.handle(call, parsed);
        }
    }
    return call.fail(.unknown_op, "the proto-fx host has no op named {s}", .{op});
}

test "every op name is unique" {
    for (names, 0..) |name, index| {
        for (names[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, name, other));
    }
}
