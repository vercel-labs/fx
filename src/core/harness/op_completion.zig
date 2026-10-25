//! `completion`: one reply from the node's model connection, with no tools.
const std = @import("std");
const protocol = @import("protocol.zig");
const op_tool = @import("op_tool.zig");
const op_agent = @import("op_agent.zig");

/// Longest reply text a completion returns.
const max_reply_bytes: usize = 256 * 1024;

pub const completion = struct {
    pub const name = "completion";
    pub const Args = struct {
        prompt: []const u8,
        schema: ?std.json.Value = null,
        model: ?[]const u8 = null,
        system: ?[]const u8 = null,
    };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const services = call.lease.services orelse return op_tool.unavailable(call);
        if (args.prompt.len == 0) return call.fail(.bad_request, "completion needs a prompt", .{});
        if (call.lease.cancelled()) return error.Cancelled;
        if ((try call.lease.nextCallId(call.arena)) == null) return call.fail(.refused, "this command already made its limit of harness requests", .{});
        const prompt = try op_agent.withSchema(call.arena, args.prompt, args.schema);
        const outcome = try services.complete(call.arena, .{
            .prompt = prompt,
            .system = args.system orelse "You answer one request from a program. Reply with the answer only.",
            .model = args.model,
            .max_bytes = max_reply_bytes,
        });
        return switch (outcome) {
            .text => |text| call.ok(.{ .text = text }),
            .failed => |detail| call.fail(.tool_failed, "the model gave no usable reply: {s}", .{detail}),
        };
    }
};
