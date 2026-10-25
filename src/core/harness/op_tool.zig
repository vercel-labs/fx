//! `tool`: calls one tool of the node, through the node's own admission and
//! permissions, exactly as if its model had called it. `tools`: the names.
const std = @import("std");
const protocol = @import("protocol.zig");
const services_mod = @import("services.zig");

pub const tool = struct {
    pub const name = "tool";
    pub const Args = struct {
        name: []const u8,
        args: std.json.Value = .null,
    };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const arguments: std.json.Value = if (args.args == .null) .{ .object = .empty } else args.args;
        if (arguments != .object) return call.fail(.bad_request, "tool arguments must be keyword arguments", .{});
        var json: std.Io.Writer.Allocating = .init(call.arena);
        try std.json.Stringify.value(arguments, .{}, &json.writer);
        return callTool(call, args.name, json.written());
    }
};

pub const tools = struct {
    pub const name = "tools";
    pub const Args = struct {};

    pub fn handle(call: *protocol.Call, _: Args) !protocol.Reply {
        const services = call.lease.services orelse return unavailable(call);
        return call.ok(try services.toolNames(call.arena));
    }
};

pub fn unavailable(call: *protocol.Call) !protocol.Reply {
    return call.fail(.unavailable, "this command runs outside an agent turn, so the host has no tools, agents or model to offer it", .{});
}

/// Runs `tool_name` for the calling node and maps its outcome to a reply:
/// the value `{status, output}` when it ran, a typed error otherwise.
pub fn callTool(call: *protocol.Call, tool_name: []const u8, arguments_json: []const u8) !protocol.Reply {
    const services = call.lease.services orelse return unavailable(call);
    if (call.lease.cancelled()) return error.Cancelled;
    const call_id = (try call.lease.nextCallId(call.arena)) orelse
        return call.fail(.refused, "this command already made its limit of harness requests", .{});
    const caller = try call.lease.describeCaller(call.arena, call.peer_pid);
    const outcome = try services.callTool(call.arena, .{ .call_id = call_id, .name = tool_name, .arguments_json = arguments_json, .caller = caller });
    return switch (outcome.status) {
        .success, .failure => call.ok(.{ .status = @tagName(outcome.status), .output = outcome.output }),
        .denied => .{ .failure = .{ .kind = .permission_denied, .message = try call.arena.print("permission to run {s} was denied", .{tool_name}), .output = outcome.output } },
        .refused => .{ .failure = .{ .kind = .refused, .message = outcome.output } },
        .cancelled => error.Cancelled,
    };
}

test "a status maps to a tool reply kind" {
    try std.testing.expect(@hasField(services_mod.ToolOutcome, "status"));
}
