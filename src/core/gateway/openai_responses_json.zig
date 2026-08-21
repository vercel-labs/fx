const std = @import("std");
const gateway_json = @import("gateway_json.zig");
const openai_tools = @import("openai_tools.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const BuildBudget = gateway_json.BuildBudget;

pub fn buildResponsesBody(
    alloc: Allocator,
    model: []const u8,
    gateway_tools_json: []const u8,
    messages: []const ChatMessage,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
    reasoning_effort: ?types.ReasoningEffort,
    budget: ?BuildBudget,
) ![]u8 {
    if (budget) |active| try active.check();
    try gateway_json.validateToolMessageHistory(alloc, messages);

    const tools_json = try openai_tools.convertGatewayToolsToResponsesJson(alloc, gateway_tools_json);
    defer alloc.free(tools_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, &out.writer);
    try out.writer.writeAll(",\"stream\":true,\"store\":false,\"input\":[");
    var first_input = true;
    for (messages) |message| {
        if (budget) |active| try active.check();
        try writeResponsesInputItems(&out.writer, message, &first_input);
    }
    try out.writer.writeAll("],\"tools\":");
    try out.writer.writeAll(tools_json);
    try out.writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(tool_choice.label(), .{}, &out.writer);
    if (max_output_tokens) |limit| {
        try out.writer.writeAll(",\"max_output_tokens\":");
        try std.json.Stringify.value(limit, .{}, &out.writer);
    }
    if (reasoning_effort) |effort| {
        if (!effort.isDefault()) {
            try out.writer.writeAll(",\"reasoning\":{\"effort\":");
            try std.json.Stringify.value(effort.label(), .{}, &out.writer);
            try out.writer.writeByte('}');
        }
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

pub fn buildRequiredToolResponsesBody(
    alloc: Allocator,
    model: []const u8,
    gateway_tools_json: []const u8,
    messages: []const ChatMessage,
    max_output_tokens: ?u32,
    reasoning_effort: ?types.ReasoningEffort,
    budget: ?BuildBudget,
) ![]u8 {
    if (budget) |active| try active.check();
    try gateway_json.validateToolMessageHistory(alloc, messages);

    const tools_json = try openai_tools.convertGatewayToolsToResponsesJson(alloc, gateway_tools_json);
    defer alloc.free(tools_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, &out.writer);
    try out.writer.writeAll(",\"stream\":true,\"store\":false,\"input\":[");
    var first_input = true;
    for (messages) |message| {
        if (budget) |active| try active.check();
        try writeResponsesInputItems(&out.writer, message, &first_input);
    }
    try out.writer.writeAll("],\"tools\":");
    try out.writer.writeAll(tools_json);
    try out.writer.writeAll(",\"tool_choice\":\"required\"");
    if (max_output_tokens) |limit| {
        try out.writer.writeAll(",\"max_output_tokens\":");
        try std.json.Stringify.value(limit, .{}, &out.writer);
    }
    if (reasoning_effort) |effort| {
        if (!effort.isDefault()) {
            try out.writer.writeAll(",\"reasoning\":{\"effort\":");
            try std.json.Stringify.value(effort.label(), .{}, &out.writer);
            try out.writer.writeByte('}');
        }
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (first.*) {
        first.* = false;
    } else {
        try writer.writeByte(',');
    }
}

fn writeResponsesInputItems(writer: *std.Io.Writer, message: ChatMessage, first: *bool) !void {
    switch (message.role) {
        .system, .user => {
            if (message.images.len != 0) return error.VisionUnavailable;
            try writeComma(writer, first);
            try writer.writeAll("{\"type\":\"message\",\"role\":");
            try std.json.Stringify.value(gateway_json.roleName(message.role), .{}, writer);
            try writer.writeAll(",\"content\":[");
            if (message.content) |content| {
                try writer.writeAll("{\"type\":\"input_text\",\"text\":");
                try std.json.Stringify.value(content, .{}, writer);
                try writer.writeAll("}]");
            } else {
                try writer.writeAll("{\"type\":\"input_text\",\"text\":\"\"}]");
            }
            try writer.writeByte('}');
        },
        .assistant => {
            if (message.content) |content| {
                try writeComma(writer, first);
                try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[");
                try writer.writeAll("{\"type\":\"output_text\",\"text\":");
                try std.json.Stringify.value(content, .{}, writer);
                try writer.writeAll("}]");
                try writer.writeByte('}');
            }
            for (message.tool_calls) |call| {
                try writeComma(writer, first);
                try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                try std.json.Stringify.value(call.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(call.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(call.arguments_json, .{}, writer);
                try writer.writeByte('}');
            }
        },
        .tool => {
            const call_id = message.tool_call_id orelse return error.InvalidGatewayHistory;
            try writeComma(writer, first);
            try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try std.json.Stringify.value(call_id, .{}, writer);
            try writer.writeAll(",\"output\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
            try writer.writeByte('}');
        },
    }
}

test "buildResponsesBody emits Responses request with flat tools" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "hello" },
    };
    const tools =
        \\[{"type":"function","name":"read_file","description":"Read","inputSchema":{"type":"object"}}]
    ;
    const body = try buildResponsesBody(alloc, "gpt-5", tools, &messages, .auto, null, null, null);
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"input\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"function\":") == null);
}

test "buildResponsesBody maps tool history to function_call items" {
    const alloc = std.testing.allocator;
    const assistant_calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"/tmp\"}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "read" },
        .{ .role = .assistant, .tool_calls = assistant_calls[0..] },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "file contents" },
    };
    const body = try buildResponsesBody(alloc, "gpt-5", "[]", &messages, .auto, null, null, null);
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "file contents") != null);
}

test "buildResponsesBody commas separate assistant text and parallel tool calls" {
    const alloc = std.testing.allocator;
    const assistant_calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"/tmp\"}" },
        .{ .id = "call_2", .name = "list_files", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "read and list" },
        .{
            .role = .assistant,
            .content = "I'll inspect the repo.",
            .tool_calls = assistant_calls[0..],
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
        .{ .role = .tool, .tool_call_id = "call_2", .tool_name = "list_files", .content = "listing" },
    };
    const body = try buildResponsesBody(alloc, "gpt-5", "[]", &messages, .auto, null, null, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("input").?.array;
    try std.testing.expectEqual(@as(usize, 6), input.items.len);
    try std.testing.expectEqualStrings("message", input.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call", input.items[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call", input.items[3].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call_output", input.items[4].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call_output", input.items[5].object.get("type").?.string);
}

test "buildResponsesBody rejects vision attachments" {
    const alloc = std.testing.allocator;
    const image = types.ImageAttachment{
        .path = @constCast("photo.png"),
        .media_type = @constCast("image/png"),
    };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "look", .images = &.{image} },
    };
    try std.testing.expectError(
        error.VisionUnavailable,
        buildResponsesBody(alloc, "gpt-5", "[]", &messages, .auto, null, null, null),
    );
}
