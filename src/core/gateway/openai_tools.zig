const std = @import("std");

const Allocator = std.mem.Allocator;

/// Converts a Gateway function-tool JSON envelope into OpenAI Chat Completions tools.
pub fn convertGatewayToolsJson(alloc: Allocator, gateway_tools_json_opt: ?[]const u8) ![]u8 {
    const gateway_tools_json = gateway_tools_json_opt orelse return alloc.dupe(u8, "[]");
    const trimmed = std.mem.trim(u8, gateway_tools_json, " \n\r\t");
    if (trimmed.len == 0) return alloc.dupe(u8, "[]");
    if (trimmed[0] != '[') return error.InvalidToolArguments;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolArguments;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    var first = true;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const tool_type = tool.object.get("type") orelse continue;
        if (tool_type != .string) continue;
        if (std.mem.eql(u8, tool_type.string, "provider")) continue;
        if (!std.mem.eql(u8, tool_type.string, "function")) continue;

        const name = tool.object.get("name") orelse continue;
        if (name != .string) continue;
        const description = tool.object.get("description");
        const input_schema = tool.object.get("inputSchema") orelse continue;

        if (!first) try out.writer.writeByte(',');
        first = false;

        try out.writer.writeAll("{\"type\":\"function\",\"function\":{");
        try out.writer.writeAll("\"name\":");
        try std.json.Stringify.value(name.string, .{}, &out.writer);
        try out.writer.writeAll(",\"description\":");
        if (description) |desc| {
            if (desc == .string) {
                try std.json.Stringify.value(desc.string, .{}, &out.writer);
            } else {
                try out.writer.writeAll("\"\"");
            }
        } else {
            try out.writer.writeAll("\"\"");
        }
        try out.writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(input_schema, .{}, &out.writer);
        try out.writer.writeAll("}}");
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

/// Converts a Gateway function-tool JSON envelope into flat Responses API tools.
pub fn convertGatewayToolsToResponsesJson(alloc: Allocator, gateway_tools_json: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, gateway_tools_json, " \n\r\t");
    if (trimmed.len == 0) return alloc.dupe(u8, "[]");
    if (trimmed[0] != '[') return error.InvalidToolArguments;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolArguments;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    var first = true;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const tool_type = tool.object.get("type") orelse continue;
        if (tool_type != .string) continue;
        if (std.mem.eql(u8, tool_type.string, "provider")) continue;
        if (!std.mem.eql(u8, tool_type.string, "function")) continue;

        const name = tool.object.get("name") orelse continue;
        if (name != .string) continue;
        const description = tool.object.get("description");
        const input_schema = tool.object.get("inputSchema") orelse continue;

        if (!first) try out.writer.writeByte(',');
        first = false;

        try out.writer.writeAll("{\"type\":\"function\",\"name\":");
        try std.json.Stringify.value(name.string, .{}, &out.writer);
        try out.writer.writeAll(",\"description\":");
        if (description) |desc| {
            if (desc == .string) {
                try std.json.Stringify.value(desc.string, .{}, &out.writer);
            } else {
                try out.writer.writeAll("\"\"");
            }
        } else {
            try out.writer.writeAll("\"\"");
        }
        try out.writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(input_schema, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

test "convertGatewayToolsJson maps function envelope to OpenAI tools" {
    const alloc = std.testing.allocator;
    const gateway =
        \\[{"type":"function","name":"read_file","description":"Read a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}}]
    ;
    const openai = try convertGatewayToolsJson(alloc, gateway);
    defer alloc.free(openai);
    try std.testing.expect(std.mem.find(u8, openai, "\"parameters\"") != null);
    try std.testing.expect(std.mem.find(u8, openai, "inputSchema") == null);
    try std.testing.expect(std.mem.find(u8, openai, "read_file") != null);
}

test "convertGatewayToolsJson drops provider-executed tools" {
    const alloc = std.testing.allocator;
    const gateway =
        \\[{"type":"provider","id":"gateway.perplexity_search","name":"perplexity_search"},{"type":"function","name":"read_file","description":"Read","inputSchema":{"type":"object"}}]
    ;
    const openai = try convertGatewayToolsJson(alloc, gateway);
    defer alloc.free(openai);
    try std.testing.expect(std.mem.find(u8, openai, "perplexity_search") == null);
    try std.testing.expect(std.mem.find(u8, openai, "read_file") != null);
}
