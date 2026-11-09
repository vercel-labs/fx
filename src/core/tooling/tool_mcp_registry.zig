const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const result_store = @import("../session/result_store.zig");

const Allocator = std.mem.Allocator;

pub const Resolution = union(enum) {
    registered: tool_dispatch.Tool,
    not_selected,
    unsupported,
};

pub fn resolve(
    advertised_dynamic_tool_names: []const []const u8,
    runtime: tool_mcp_runtime.RuntimeCapabilities,
    name: []const u8,
) Resolution {
    if (runtime.context != null and
        !tool_mcp_runtime.isAdvertisedDynamicToolName(
            advertised_dynamic_tool_names,
            name,
        ))
    {
        return .not_selected;
    }
    if (!tool_mcp_runtime.isAdvertisedDynamicToolName(
        advertised_dynamic_tool_names,
        name,
    ) or runtime.context == null or runtime.call_tool == null) {
        return .unsupported;
    }
    return .{ .registered = dynamicTool(name) };
}

const DynamicInput = struct {
    arguments_json: []u8,
};

fn dynamicTool(name: []const u8) tool_dispatch.Tool {
    return .{
        .name = name,
        .description = "Selected dynamic MCP tool.",
        .model_schema = .{
            .name = name,
            .description = "Selected dynamic MCP tool.",
        },
        .executor_kind = .mcp_select_tool,
        .activity_kind = .command,
        .decode = decode,
        .call = call,
        .reads_only_fn = readsOnly,
        .irreversible_fn = isIrreversible,
    };
}

fn decode(
    ctx: tool_dispatch.DispatchContext,
    arguments_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(DynamicInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .arguments_json = try ctx.allocator.dupe(u8, arguments_json),
    };
    return .{ .input = .{
        .ptr = input,
        .deinit_fn = deinitInput,
    } };
}

fn deinitInput(raw_input: *anyopaque, alloc: Allocator) void {
    const input: *DynamicInput = @ptrCast(@alignCast(raw_input));
    alloc.free(input.arguments_json);
    alloc.destroy(input);
}

fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime_context = ctx.mcp_ctx orelse return unsupported(ctx);
    const call_tool = ctx.mcp_call_tool orelse return unsupported(ctx);
    const input = erased.as(DynamicInput);
    var output = call_tool(
        runtime_context,
        ctx.allocator,
        ctx.tool_call_name,
        input.arguments_json,
        resultBytes(ctx),
        ctx.mcp_call_options,
    ) catch |err| {
        if (ctx.mcp_execution_error_sink) |sink| sink.* = err;
        return .{ .failure = try ctx.allocator.dupe(u8, "") };
    } orelse return unsupported(ctx);
    const status = output.status;
    if (ctx.mcp_call_status_sink) |sink| sink.* = status;
    const images = output.takeImages();
    const body = @constCast(output.takeModelOutput(ctx.allocator));
    if (images.len > 0) return .{ .rich = .{ .text = body, .images = images, .is_error = status != .success } };
    return switch (status) {
        .success => .{ .success = body },
        .tool_failure, .protocol_failure, .input_required => .{ .failure = body },
    };
}

/// How large an MCP result may come back. Where fx keeps results behind a
/// handle, that store keeps it whole and the model sees a preview; only
/// without one is it cut to the model's limit here.
fn resultBytes(ctx: tool_dispatch.DispatchContext) usize {
    if (ctx.session_child_capability != null or ctx.tool_result_dir != null) return result_store.stored_text_max_bytes;
    return ctx.max_tool_result_bytes;
}

fn unsupported(
    ctx: tool_dispatch.DispatchContext,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.print(
        "Unsupported tool: {s}",
        .{ctx.tool_call_name},
    ) };
}

fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "dynamic MCP resolution preserves selected and unselected states" {
    var fixture: u8 = 0;
    const advertised = [_][]const u8{"mcp_fs_read"};
    const runtime = tool_mcp_runtime.RuntimeCapabilities{
        .context = @ptrCast(&fixture),
        .call_tool = callFixture,
    };

    try std.testing.expect(resolve(&advertised, runtime, "mcp_other") == .not_selected);
    try std.testing.expect(resolve(&advertised, .{}, "mcp_fs_read") == .unsupported);
    try std.testing.expect(resolve(&advertised, runtime, "mcp_fs_read") == .registered);
}

test "dynamic MCP descriptor executes through registered dispatch" {
    var fixture: u8 = 0;
    const advertised = [_][]const u8{"mcp_fs_read"};
    const runtime = tool_mcp_runtime.RuntimeCapabilities{
        .context = @ptrCast(&fixture),
        .call_tool = callFixture,
    };
    const tool = switch (resolve(&advertised, runtime, "mcp_fs_read")) {
        .registered => |registered| registered,
        else => return error.TestUnexpectedResult,
    };
    const tools = [_]tool_dispatch.Tool{tool};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    var execution_error: ?anyerror = null;
    const result = try tool_dispatch.dispatchAuthorizedToolCall(.{
        .allocator = std.testing.allocator,
        .tool_call_name = "mcp_fs_read",
        .mcp_ctx = @ptrCast(&fixture),
        .mcp_call_tool = callFixture,
        .mcp_execution_error_sink = &execution_error,
    }, registry, .{
        .id = "dynamic-test",
        .name = "mcp_fs_read",
        .arguments_json = "{\"path\":\"README.md\"}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(execution_error == null);
    try std.testing.expectEqualStrings("mcp ok", result.body);
}

fn callFixture(
    _: *anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    _: usize,
    _: tool_mcp_runtime.CallOptions,
) anyerror!?tool_mcp_runtime.CallResult {
    return .{ .model_output = try alloc.dupe(u8, "mcp ok") };
}

test "an MCP result may be as large as the result store keeps where fx stores results" {
    var seen: usize = 0;
    const advertised = [_][]const u8{"mcp_fs_read"};
    const runtime = tool_mcp_runtime.RuntimeCapabilities{ .context = @ptrCast(&seen), .call_tool = callRecordingBytes };
    const tool = switch (resolve(&advertised, runtime, "mcp_fs_read")) {
        .registered => |registered| registered,
        else => return error.TestUnexpectedResult,
    };
    const tools = [_]tool_dispatch.Tool{tool};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const Case = struct { dir: ?[]const u8, want: usize };
    for ([_]Case{ .{ .dir = null, .want = 4096 }, .{ .dir = "/nonexistent-tool-results", .want = result_store.stored_text_max_bytes } }) |case| {
        const result = try tool_dispatch.dispatchAuthorizedToolCall(.{
            .allocator = std.testing.allocator,
            .tool_call_name = "mcp_fs_read",
            .mcp_ctx = @ptrCast(&seen),
            .mcp_call_tool = callRecordingBytes,
            .max_tool_result_bytes = 4096,
            .tool_result_dir = case.dir,
        }, registry, .{ .id = "bytes-test", .name = "mcp_fs_read", .arguments_json = "{}" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.want, seen);
    }
}

fn callRecordingBytes(
    raw: *anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    max_bytes: usize,
    _: tool_mcp_runtime.CallOptions,
) anyerror!?tool_mcp_runtime.CallResult {
    const seen: *usize = @ptrCast(@alignCast(raw));
    seen.* = max_bytes;
    return .{ .model_output = try alloc.dupe(u8, "mcp ok") };
}
