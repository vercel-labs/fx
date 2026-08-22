const std = @import("std");
const js_host_workspace = @import("../../core/hosts/js_host_workspace.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const terminal = @import("terminal.zig");

const Allocator = std.mem.Allocator;

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return failure(ctx.allocator, "browser terminal arguments must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return failure(ctx.allocator, "browser terminal arguments must be an object");
    }
    const action = parsed.value.object.get("action") orelse {
        return failure(ctx.allocator, "browser terminal requires string field \"action\"");
    };
    if (action != .string or !std.mem.eql(u8, action.string, "exec")) {
        return failure(ctx.allocator, "browser terminal action must be \"exec\"");
    }
    const command = parsed.value.object.get("command") orelse {
        return failure(ctx.allocator, "browser terminal requires string field \"command\"");
    };
    if (command != .string) {
        return failure(ctx.allocator, "browser terminal field \"command\" must be a string");
    }
    const expected_field_count: usize = if (parsed.value.object.contains("timeout_ms")) 3 else 2;
    if (parsed.value.object.count() != expected_field_count) {
        return failure(ctx.allocator, "browser terminal accepts only the \"action\", \"command\", and optional \"timeout_ms\" fields");
    }
    if (command.string.len > js_host_workspace.max_command_bytes) {
        return failure(ctx.allocator, "browser terminal field \"command\" exceeds 65536 bytes");
    }
    return terminal.decode(ctx, args_json);
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}
