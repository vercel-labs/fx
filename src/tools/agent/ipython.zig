const std = @import("std");
const kernel = @import("../../core/kernel/runtime.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    code: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.code);
        self.* = .{ .code = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "ipython arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "ipython arguments must be an object") };
    }
    const code_value = parsed.value.object.get("code") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "ipython field \"code\" is required") };
    };
    if (code_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "ipython field \"code\" must be a string") };
    }
    const code = try ctx.allocator.dupe(u8, code_value.string);
    errdefer ctx.allocator.free(code);
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .code = code };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (input.code.len == 0) return try ctx.allocator.dupe(u8, "ipython field \"code\" must not be empty");
    if (input.code.len > kernel.max_code_bytes) {
        return try std.fmt.allocPrint(ctx.allocator, "ipython code exceeds the {d} byte limit", .{kernel.max_code_bytes});
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.ipython_runtime orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "ipython runtime is unavailable") };
    };
    const input = erased.as(Input);
    const root_session_id = ctx.ipython_root_session_id orelse ctx.terminal_owner_session_id orelse "";
    const result = runtime.execute(
        ctx.allocator,
        root_session_id,
        ctx.workspace_root,
        input.code,
        ctx.cancel_flag,
    ) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "ipython failed: {s}", .{@errorName(err)}) };
    };
    defer result.deinit(ctx.allocator);

    var output: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer output.deinit();
    output.writer.writeAll("{\"stdout\":") catch return error.OutOfMemory;
    std.json.Stringify.value(result.stdout, .{}, &output.writer) catch return error.OutOfMemory;
    output.writer.writeAll(",\"stderr\":") catch return error.OutOfMemory;
    std.json.Stringify.value(result.stderr, .{}, &output.writer) catch return error.OutOfMemory;
    output.writer.writeAll(",\"result\":") catch return error.OutOfMemory;
    if (result.result) |value|
        std.json.Stringify.value(value, .{}, &output.writer) catch return error.OutOfMemory
    else
        output.writer.writeAll("null") catch return error.OutOfMemory;
    const status_text = if (result.status == .success) "success" else "error";
    output.writer.print(",\"status\":\"{s}\",\"duration_ms\":{d}}}", .{ status_text, result.duration_ms }) catch return error.OutOfMemory;
    const body = try output.toOwnedSlice();
    return if (result.status == .success) .{ .success = body } else .{ .failure = body };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

test "ipython accepts exactly one code string" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"code\":\"1+1\"}");
    switch (decoded) {
        .failure => return error.TestExpectedEqual,
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqualStrings("1+1", input.as(Input).code);
        },
    }
}
