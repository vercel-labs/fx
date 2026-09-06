const std = @import("std");
const js_host_workspace = @import("../../core/hosts/js_host_workspace.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const Input = struct {
    command: []u8,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.command);
        alloc.destroy(self);
    }
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return failure(ctx.allocator, "browser shell arguments must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return failure(ctx.allocator, "browser shell arguments must be an object");
    }
    const action = parsed.value.object.get("action") orelse {
        return failure(ctx.allocator, "browser shell requires string field action");
    };
    if (action != .string or !std.mem.eql(u8, action.string, "run")) {
        return failure(ctx.allocator, "browser shell action must be run");
    }
    const command = parsed.value.object.get("command") orelse {
        return failure(ctx.allocator, "browser shell requires string field command");
    };
    if (command != .string) {
        return failure(ctx.allocator, "browser shell field command must be a string");
    }
    if (parsed.value.object.count() != 2) {
        return failure(ctx.allocator, "browser shell accepts only action and command");
    }
    if (command.string.len > js_host_workspace.max_command_bytes) {
        return failure(ctx.allocator, "browser shell field command exceeds 65536 bytes");
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .command = try ctx.allocator.dupe(u8, command.string) };
    return .{ .input = .{
        .ptr = input,
        .deinit_fn = inputDeinit,
    } };
}

fn inputDeinit(raw: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(raw));
    input.deinit(alloc);
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const backend = ctx.run_command_backend orelse return .{
        .failure = try ctx.allocator.dupe(u8, "browser shell backend is unavailable"),
    };
    return backend.execute(ctx, .{
        .command = erased.as(Input).command,
        .resolved_cwd = ctx.workspace_root,
        .environment = .workspace_clean,
        .timeout_ms = js_host_workspace.max_timeout_ms,
    });
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

test "browser shell accepts only completion run input" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const decoded = try decode(ctx, "{\"action\":\"run\",\"command\":\"pwd\"}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestUnexpectedResult;
        },
        .input => |input| input.deinit(alloc),
    }
    const rejected = try decode(ctx, "{\"action\":\"wait\",\"session_id\":\"x\"}");
    switch (rejected) {
        .failure => |body| alloc.free(body),
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }
}
