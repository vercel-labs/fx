const std = @import("std");
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_result_errors = @import("tool_result_errors.zig");

const Allocator = std.mem.Allocator;

const SearchInput = struct {
    query: []u8,
    prepared: lexical_relevance.PreparedQuery,
    limit: usize,

    fn deinit(self: *SearchInput, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = undefined;
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

    if (query_value.string.len > lexical_relevance.max_query_bytes) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "mcp_search_tools query must not exceed 4096 bytes.",
        ) };
    }

    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);
    const prepared = lexical_relevance.prepare(query) catch |err| switch (err) {
        error.QueryTooLong => unreachable,
        error.TooManyTokens => {
            const message = try ctx.allocator.dupe(
                u8,
                "mcp_search_tools query must not exceed 64 tokens.",
            );
            ctx.allocator.free(query);
            return .{ .failure = message };
        },
    };
    const input = try ctx.allocator.create(SearchInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .query = query, .prepared = prepared, .limit = limit };
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
        &input.prepared,
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
            defer ctx.allocator.free(payload.model_output);
            defer if (payload.notice) |notice| ctx.allocator.free(notice);
            if (payload.notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
            try tool_dispatch.reportSelectedDynamicTool(ctx, input.name, payload.model_output);
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

test "MCP search decoder enforces query byte and token bounds" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };

    const max_query = "a" ** 4096;
    const accepted_json = try std.fmt.allocPrint(alloc, "{{\"query\":\"{s}\"}}", .{max_query});
    defer alloc.free(accepted_json);
    const accepted = try decodeSearch(ctx, accepted_json);
    switch (accepted) {
        .input => |input| input.deinit(alloc),
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
    }

    const too_long_query = "a" ** 4097;
    const too_long_json = try std.fmt.allocPrint(alloc, "{{\"query\":\"{s}\"}}", .{too_long_query});
    defer alloc.free(too_long_json);
    const too_long = try decodeSearch(ctx, too_long_json);
    switch (too_long) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| {
            defer alloc.free(message);
            try std.testing.expect(std.mem.find(u8, message, "4096 bytes") != null);
        },
    }

    var token_query: std.Io.Writer.Allocating = .init(alloc);
    defer token_query.deinit();
    for (0..65) |index| {
        if (index > 0) try token_query.writer.writeByte(' ');
        try token_query.writer.writeAll("token");
    }
    const too_many_tokens_json = try std.fmt.allocPrint(
        alloc,
        "{{\"query\":\"{s}\"}}",
        .{token_query.written()},
    );
    defer alloc.free(too_many_tokens_json);
    const too_many_tokens = try decodeSearch(ctx, too_many_tokens_json);
    switch (too_many_tokens) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| {
            defer alloc.free(message);
            try std.testing.expect(std.mem.find(u8, message, "64 tokens") != null);
        },
    }
}

test "MCP search decoder releases every accepted-input allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const decoded = try decodeSearch(
                .{ .allocator = alloc },
                "{\"query\":\"linear public data\",\"limit\":8}",
            );
            switch (decoded) {
                .input => |input| input.deinit(alloc),
                .failure => |message| alloc.free(message),
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "MCP search decoder releases every rejected-input allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const args_json = "{\"query\":\"" ++ ("token " ** 64) ++ "token\"}";
            const decoded = try decodeSearch(.{ .allocator = alloc }, args_json);
            switch (decoded) {
                .input => |input| input.deinit(alloc),
                .failure => |message| alloc.free(message),
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
