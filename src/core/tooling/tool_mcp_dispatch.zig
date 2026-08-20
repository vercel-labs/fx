const std = @import("std");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_result_errors = @import("tool_result_errors.zig");

const Allocator = std.mem.Allocator;

const SearchInput = struct {
    query: []u8,
    limit: usize,

    fn deinit(self: *SearchInput, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = .{ .query = &.{}, .limit = 0 };
    }
};

const SelectInput = struct {
    name: []u8,

    fn deinit(self: *SelectInput, alloc: Allocator) void {
        alloc.free(self.name);
        self.* = .{ .name = &.{} };
    }
};

pub fn decodeSearch(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "Invalid mcp_search_tools arguments.") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "Invalid mcp_search_tools arguments.") };
    }
    const query_value = parsed.value.object.get("query") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "mcp_search_tools requires a string query.") };
    };
    if (query_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "mcp_search_tools requires a string query.") };
    }

    const raw_limit = if (parsed.value.object.get("limit")) |value|
        if (value == .integer) value.integer else 0
    else
        0;
    const limit = if (raw_limit <= 0)
        0
    else
        std.math.cast(usize, raw_limit) orelse std.math.maxInt(usize);

    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);
    const input = try ctx.allocator.create(SearchInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .query = query, .limit = limit };
    return .{ .input = .{ .ptr = input, .deinit_fn = searchInputDeinit } };
}

pub fn decodeSelect(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "Invalid mcp_select_tool arguments.") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "Invalid mcp_select_tool arguments.") };
    }
    const name_value = parsed.value.object.get("name") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "mcp_select_tool requires an exact dynamic tool name.") };
    };
    if (name_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "mcp_select_tool requires an exact dynamic tool name.") };
    }

    const name = try ctx.allocator.dupe(u8, name_value.string);
    errdefer ctx.allocator.free(name);
    const input = try ctx.allocator.create(SelectInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .name = name };
    return .{ .input = .{ .ptr = input, .deinit_fn = selectInputDeinit } };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn callSearch(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime_context = ctx.mcp_ctx orelse return semanticFailure(
        ctx,
        "No MCP runtime is available.",
    );
    const search_tools = ctx.mcp_search_tools orelse return semanticFailure(
        ctx,
        "No MCP runtime is available.",
    );
    const input = erased.as(SearchInput);
    const result = search_tools(
        runtime_context,
        ctx.allocator,
        input.query,
        input.limit,
        ctx.mcp_permission_rules,
        ctx.context_limits,
        ctx.mcp_access,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try tool_result_errors.formatToolExecutionErrorJson(
            ctx.allocator,
            "mcp_search_tools",
            err,
        ) };
    };
    if (result.notice) |notice| {
        defer ctx.allocator.free(notice);
        try tool_dispatch.reportContextNotice(ctx, notice);
    }
    return .{ .success = result.model_output };
}

pub fn callSelect(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime_context = ctx.mcp_ctx orelse return semanticFailure(
        ctx,
        "No MCP runtime is available.",
    );
    const tool_schema = ctx.mcp_tool_schema orelse return semanticFailure(
        ctx,
        "No MCP runtime is available.",
    );
    const input = erased.as(SelectInput);
    const schema_result = (tool_schema(
        runtime_context,
        ctx.allocator,
        input.name,
        ctx.mcp_permission_rules,
        ctx.context_limits,
        ctx.mcp_access,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try tool_result_errors.formatToolExecutionErrorJson(
            ctx.allocator,
            "mcp_select_tool",
            err,
        ) };
    }) orelse {
        return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "Dynamic MCP tool not found or not allowed: {s}",
            .{input.name},
        ) };
    };
    switch (schema_result) {
        .rejected => |payload| {
            if (payload.notice) |notice| {
                defer ctx.allocator.free(notice);
                try tool_dispatch.reportContextNotice(ctx, notice);
            }
            return .{ .failure = payload.model_output };
        },
        .selected => |payload| {
            defer ctx.allocator.free(payload.name);
            defer ctx.allocator.free(payload.description);
            defer ctx.allocator.free(payload.input_schema_json);
            defer if (payload.notice) |notice| ctx.allocator.free(notice);
            if (payload.notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
            try tool_dispatch.reportSelectedDynamicTool(
                ctx,
                payload.name,
                payload.description,
                payload.input_schema_json,
            );
        },
    }
    var success: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer success.deinit();
    success.writer.writeAll("Selected dynamic MCP tool `") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&success.writer, input.name) catch return error.OutOfMemory;
    success.writer.writeAll("`. Its executable schema will be available on the next model step; call `") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&success.writer, input.name) catch return error.OutOfMemory;
    success.writer.writeAll("` with arguments matching the selected schema.") catch return error.OutOfMemory;
    return .{ .success = success.toOwnedSlice() catch return error.OutOfMemory };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn searchInputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *SearchInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn selectInputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *SelectInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn semanticFailure(
    ctx: tool_dispatch.DispatchContext,
    message: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(u8, message) };
}
