const std = @import("std");
const gateway_json = @import("gateway_json.zig");
const io_mod = @import("../shared/io.zig");
const openai_tools = @import("openai_tools.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const BuildBudget = gateway_json.BuildBudget;

pub fn buildChatCompletionsBody(
    alloc: Allocator,
    model: []const u8,
    gateway_tools_json: []const u8,
    messages: []const ChatMessage,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
    budget: ?BuildBudget,
) ![]u8 {
    if (budget) |active| try active.check();
    try gateway_json.validateToolMessageHistory(alloc, messages);

    const tools_json = try openai_tools.convertGatewayToolsJson(alloc, gateway_tools_json);
    defer alloc.free(tools_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, &out.writer);
    try out.writer.writeAll(",\"stream\":true,\"messages\":[");
    for (messages, 0..) |message, index| {
        if (budget) |active| try active.check();
        if (index > 0) try out.writer.writeByte(',');
        try writeOpenAiMessage(&out.writer, message);
    }
    try out.writer.writeAll("],\"tools\":");
    try out.writer.writeAll(tools_json);
    try out.writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(tool_choice.label(), .{}, &out.writer);
    if (max_output_tokens) |limit| {
        try out.writer.writeAll(",\"max_tokens\":");
        try std.json.Stringify.value(limit, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

pub fn buildRequiredToolChatCompletionsBody(
    alloc: Allocator,
    model: []const u8,
    gateway_tools_json: []const u8,
    messages: []const ChatMessage,
    max_output_tokens: ?u32,
    budget: ?BuildBudget,
) ![]u8 {
    if (budget) |active| try active.check();
    try gateway_json.validateToolMessageHistory(alloc, messages);

    const tools_json = try openai_tools.convertGatewayToolsJson(alloc, gateway_tools_json);
    defer alloc.free(tools_json);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, &out.writer);
    try out.writer.writeAll(",\"stream\":true,\"messages\":[");
    for (messages, 0..) |message, index| {
        if (budget) |active| try active.check();
        if (index > 0) try out.writer.writeByte(',');
        try writeOpenAiMessage(&out.writer, message);
    }
    try out.writer.writeAll("],\"tools\":");
    try out.writer.writeAll(tools_json);
    try out.writer.writeAll(",\"tool_choice\":\"required\"");
    if (max_output_tokens) |limit| {
        try out.writer.writeAll(",\"max_tokens\":");
        try std.json.Stringify.value(limit, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn writeOpenAiMessage(writer: *std.Io.Writer, message: ChatMessage) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(gateway_json.roleName(message.role), .{}, writer);

    switch (message.role) {
        .system, .user => {
            if (message.images.len != 0) return error.VisionUnavailable;
            try writer.writeAll(",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
        },
        .assistant => {
            if (message.content) |content| {
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(content, .{}, writer);
            }
            if (message.tool_calls.len > 0) {
                try writer.writeAll(",\"tool_calls\":[");
                for (message.tool_calls, 0..) |call, index| {
                    if (index > 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"type\":\"function\",\"function\":{");
                    try writer.writeAll("\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeAll("}}");
                }
                try writer.writeByte(']');
            }
        },
        .tool => {
            try writer.writeAll(",\"tool_call_id\":");
            if (message.tool_call_id) |tool_call_id| {
                try std.json.Stringify.value(tool_call_id, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
            try writer.writeAll(",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
        },
    }
    try writer.writeByte('}');
}

test "buildChatCompletionsBody emits OpenAI chat request" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "hello" },
    };
    const tools =
        \\[{"type":"function","name":"read_file","description":"Read","inputSchema":{"type":"object"}}]
    ;
    const body = try buildChatCompletionsBody(alloc, "gpt-4o", tools, &messages, .auto, null, null);
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"messages\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"prompt\"") == null);
}

test "buildChatCompletionsBody rejects vision attachments" {
    const alloc = std.testing.allocator;
    const image = types.ImageAttachment{
        .path = @constCast("photo.png"),
        .media_type = @constCast("image/png"),
    };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "look", .images = &.{image} },
    };
    const tools = "[]";
    try std.testing.expectError(
        error.VisionUnavailable,
        buildChatCompletionsBody(alloc, "gpt-4o", tools, &messages, .auto, null, null),
    );
}
