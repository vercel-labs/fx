//! `agent`: a subagent below the calling node. It is the node's own
//! `subagent` tool, so the spawn policy, depth limit, tree budget, slot
//! lending and permission ceiling all apply, and a node at the depth limit,
//! which has no `subagent` tool, is refused.
const std = @import("std");
const protocol = @import("protocol.zig");
const op_tool = @import("op_tool.zig");

pub const agent = struct {
    pub const name = "agent";
    pub const Args = struct {
        prompt: []const u8,
        schema: ?std.json.Value = null,
        model: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        if (args.prompt.len == 0) return call.fail(.bad_request, "agent needs a prompt", .{});
        const prompt = try withSchema(call.arena, args.prompt, args.schema);
        var json: std.Io.Writer.Allocating = .init(call.arena);
        if (args.name) |agent_name| {
            try std.json.Stringify.value(.{ .action = "message", .agent = agent_name, .message = prompt, .model = args.model }, .{ .emit_null_optional_fields = false }, &json.writer);
        } else {
            try std.json.Stringify.value(.{ .action = "run", .task = prompt, .model = args.model }, .{ .emit_null_optional_fields = false }, &json.writer);
        }
        const reply = try op_tool.callTool(call, "subagent", json.written());
        const value = switch (reply) {
            .value => |value| value,
            else => return reply,
        };
        return decode(call, value);
    }
};

/// Appends the instruction to answer in JSON matching `schema`.
pub fn withSchema(arena: std.mem.Allocator, prompt: []const u8, schema: ?std.json.Value) ![]const u8 {
    const value = schema orelse return prompt;
    var json: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{}, &json.writer);
    return arena.print("{s}\n\nReply with only one JSON value that matches this JSON schema, with no prose and no code fence:\n{s}", .{ prompt, json.written() });
}

/// Turns the subagent tool's `{status, output}` into `{text}`, or an error.
fn decode(call: *protocol.Call, value: []const u8) !protocol.Reply {
    const Ran = struct { status: []const u8, output: []const u8 };
    const ran = std.json.parseFromSliceLeaky(Ran, call.arena, value, .{}) catch
        return call.fail(.internal, "the subagent tool answered in an unexpected form", .{});
    const Body = struct { ok: bool = false, result: ?[]const u8 = null, error_code: ?[]const u8 = null, pending: bool = false };
    const body = std.json.parseFromSliceLeaky(Body, call.arena, ran.output, .{ .ignore_unknown_fields = true }) catch {
        if (std.mem.eql(u8, ran.status, "success")) return call.ok(.{ .text = ran.output });
        return .{ .failure = .{ .kind = .refused, .message = ran.output } };
    };
    if (!body.ok) {
        const code = body.error_code orelse "subagent_failed";
        return .{ .failure = .{ .kind = .refused, .message = try call.arena.print("the subagent did not run: {s}", .{code}), .output = body.result } };
    }
    if (body.pending) return call.fail(.tool_failed, "the subagent is still running and its result will reach the agent later", .{});
    return call.ok(.{ .text = body.result orelse "" });
}

test "a schema becomes an instruction to reply in JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("hi", try withSchema(arena, "hi", null));
    const with = try withSchema(arena, "hi", .{ .string = "x" });
    try std.testing.expect(std.mem.endsWith(u8, with, "\n\"x\""));
}
