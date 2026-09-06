const std = @import("std");
const context_limits = @import("../config/context_limits.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const McpTool = @import("catalog_state.zig").McpTool;
const Allocator = std.mem.Allocator;
const encodeScalarAlloc = model_context_encoding.scalarAlloc;

pub fn project(alloc: Allocator, tool: McpTool, server_instructions: ?[]const u8, limits: context_limits.Values) !tool_mcp_runtime.ToolSchemaResult {
    const instruction_limit = limits.mcp_server_instructions_bytes;
    const observed = if (server_instructions) |value| value.len else 0;
    const instructions = if (server_instructions) |value| value[0..context_limits.lineSafePrefixLength(value, instruction_limit.effectiveBytes())] else null;
    const truncated = if (instructions) |value| value.len < observed else false;
    const schema = try buildToolSchemaJsonWithLimitMarker(alloc, tool, instructions, truncated, observed, instruction_limit);
    var schema_owned = true;
    errdefer if (schema_owned) alloc.free(schema);
    const limit = limits.mcp_selected_schema_bytes;
    if (schema.len > limit.effectiveBytes()) {
        const schema_bytes = schema.len;
        alloc.free(schema);
        schema_owned = false;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll("{\"context_limit_rejection\":{\"name\":\"mcp_selected_schema_bytes\",\"tool\":");
        try model_context_encoding.writeJsonScalar(alloc, &out.writer, tool.prefixed_name);
        try out.writer.print(",\"action\":\"rejected\",\"observed_bytes\":{d},\"effective_bytes\":{d},\"source\":\"{s}\",\"override\":\"--context-limit mcp_selected_schema_bytes=BYTES|off\"}}}}", .{ schema_bytes, limit.effectiveBytes(), limit.source.label() });
        const output = try out.toOwnedSlice();
        errdefer alloc.free(output);
        return .{ .rejected = .{ .model_output = output, .notice = try renderSchemaNotice(alloc, tool.prefixed_name, "rejected", schema_bytes, limit, "mcp_selected_schema_bytes") } };
    }
    return .{ .selected = .{ .model_output = schema, .notice = if (truncated) try renderSchemaNotice(alloc, tool.prefixed_name, "instructions truncated", observed, instruction_limit, "mcp_server_instructions_bytes") else null } };
}

fn buildToolSchemaJsonWithLimitMarker(
    alloc: Allocator,
    tool: McpTool,
    instructions: ?[]const u8,
    instructions_truncated: bool,
    instruction_observed_bytes: usize,
    limit: context_limits.Resolved,
) ![]u8 {
    const encoded_description = try encodeScalarAlloc(alloc, tool.description);
    defer alloc.free(encoded_description);
    const encoded_instructions = if (instructions) |text| try encodeScalarAlloc(alloc, text) else null;
    defer if (encoded_instructions) |text| alloc.free(text);
    const merged_description = if (instructions != null)
        if (instructions_truncated)
            try std.fmt.allocPrint(
                alloc,
                "{s}\n\nServer instructions: {s}\n<context_limit name=\"mcp_server_instructions_bytes\" action=\"truncated\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" override=\"--context-limit mcp_server_instructions_bytes=BYTES|off\" />",
                .{ encoded_description, encoded_instructions.?, instruction_observed_bytes, limit.effectiveBytes(), limit.source.label() },
            )
        else
            try std.fmt.allocPrint(alloc, "{s}\n\nServer instructions: {s}", .{ encoded_description, encoded_instructions.? })
    else
        try alloc.dupe(u8, encoded_description);
    defer alloc.free(merged_description);
    return model_tool_schema.dynamicFunctionSchemaJsonAlloc(
        alloc,
        tool.prefixed_name,
        merged_description,
        tool.input_schema_json,
    );
}

fn renderSchemaNotice(
    alloc: Allocator,
    tool_name: []const u8,
    action: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
    limit_name: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("[context] MCP schema \"");
    try model_context_encoding.writeScalar(&out.writer, tool_name);
    try out.writer.print(
        "\" {s}: observed={d} bytes effective={d} bytes source={s}; override with --context-limit {s}=BYTES|off",
        .{ action, observed_bytes, limit.effectiveBytes(), limit.source.label(), limit_name },
    );
    return try out.toOwnedSlice();
}
