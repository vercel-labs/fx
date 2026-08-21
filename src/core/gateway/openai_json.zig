//! Serializes agent requests into the OpenAI chat-completions wire format.
//!
//! This is the request-body sibling of `gateway_json.zig` for custom
//! OpenAI-compatible endpoints. Tools arrive in the AI SDK flat schema
//! (`{"type":"function","name",...,"inputSchema":...}`) and are re-emitted in
//! the nested OpenAI envelope (`{"type":"function","function":{...}}`).

const std = @import("std");
const gateway_json = @import("gateway_json.zig");
const types = @import("../shared/types.zig");

const ChatMessage = types.ChatMessage;

pub const BuildInput = struct {
    model: []const u8,
    /// AI SDK flat tools JSON array, as produced by tool advertisement.
    tools_json: []const u8,
    messages: []const ChatMessage,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32 = null,
};

pub fn buildChatCompletionsBody(alloc: std.mem.Allocator, input: BuildInput) ![]u8 {
    try gateway_json.validateToolMessageHistory(alloc, input.messages);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(input.model, .{}, &out.writer);
    try out.writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    for (input.messages, 0..) |message, i| {
        if (i > 0) try out.writer.writeByte(',');
        try writeChatMessageJson(&out.writer, message);
    }
    try out.writer.writeByte(']');

    const tool_count = try writeTools(alloc, &out.writer, input.tools_json);
    if (tool_count > 0) {
        try out.writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(input.tool_choice.label(), .{}, &out.writer);
    }
    if (input.max_output_tokens) |value| {
        try out.writer.print(",\"max_tokens\":{d}", .{value});
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn writeChatMessageJson(writer: *std.Io.Writer, message: ChatMessage) !void {
    if (message.images.len > 0) return error.ImageInputUnsupported;

    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(gateway_json.roleName(message.role), .{}, writer);
    switch (message.role) {
        .system, .user => {
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
        },
        .assistant => {
            try writer.writeAll(",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else if (message.tool_calls.len == 0) {
                try writer.writeAll("\"\"");
            } else {
                try writer.writeAll("null");
            }
            if (message.tool_calls.len > 0) {
                try writer.writeAll(",\"tool_calls\":[");
                for (message.tool_calls, 0..) |tool_call, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":");
                    try std.json.Stringify.value(tool_call.id, .{}, writer);
                    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try std.json.Stringify.value(tool_call.name, .{}, writer);
                    // OpenAI carries function arguments as a JSON-encoded string.
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(tool_call.arguments_json, .{}, writer);
                    try writer.writeAll("}}");
                }
                try writer.writeByte(']');
            }
        },
        .tool => {
            try writer.writeAll(",\"tool_call_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
        },
    }
    try writer.writeByte('}');
}

/// Re-emits AI SDK flat function tools in the OpenAI nested envelope.
/// Provider-executed tools have no OpenAI equivalent and are skipped.
/// Returns the number of tools written; zero writes no "tools" key at all.
fn writeTools(alloc: std.mem.Allocator, writer: *std.Io.Writer, tools_json: []const u8) !usize {
    if (tools_json.len == 0) return 0;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{}) catch {
        return error.InvalidToolAdvertisement;
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolAdvertisement;

    var written: usize = 0;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) return error.InvalidToolAdvertisement;
        const tool_type = tool.object.get("type") orelse return error.InvalidToolAdvertisement;
        if (tool_type != .string) return error.InvalidToolAdvertisement;
        if (!std.mem.eql(u8, tool_type.string, "function")) continue;
        const name = tool.object.get("name") orelse return error.InvalidToolAdvertisement;
        if (name != .string) return error.InvalidToolAdvertisement;

        try writer.writeAll(if (written == 0) ",\"tools\":[" else ",");
        try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(name.string, .{}, writer);
        if (tool.object.get("description")) |description| {
            if (description == .string) {
                try writer.writeAll(",\"description\":");
                try std.json.Stringify.value(description.string, .{}, writer);
            }
        }
        if (tool.object.get("inputSchema")) |schema| {
            try writer.writeAll(",\"parameters\":");
            try std.json.Stringify.value(schema, .{}, writer);
        }
        try writer.writeAll("}}");
        written += 1;
    }
    if (written > 0) try writer.writeByte(']');
    return written;
}

test "openai body carries model, messages, and translated tools" {
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "be brief" },
        .{ .role = .user, .content = "hi" },
    };
    const tools_json =
        \\[{"type":"function","name":"read_file","description":"Read","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},{"type":"provider","id":"gateway.perplexity_search","name":"perplexity_search","args":{}}]
    ;
    const body = try buildChatCompletionsBody(std.testing.allocator, .{
        .model = "gpt-5.2",
        .tools_json = tools_json,
        .messages = &messages,
        .tool_choice = .auto,
        .max_output_tokens = 4096,
    });
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("gpt-5.2", root.get("model").?.string);
    try std.testing.expect(root.get("stream").?.bool);
    try std.testing.expectEqual(@as(usize, 2), root.get("messages").?.array.items.len);
    const tools = root.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    const function = tools.items[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("read_file", function.get("name").?.string);
    try std.testing.expect(function.get("parameters").?.object.get("properties") != null);
    try std.testing.expectEqualStrings("auto", root.get("tool_choice").?.string);
    try std.testing.expectEqual(@as(i64, 4096), root.get("max_tokens").?.integer);
}

test "openai body round-trips assistant tool calls and tool results" {
    const calls = [_]types.ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"a.txt\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "read a.txt" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try buildChatCompletionsBody(std.testing.allocator, .{
        .model = "llama3.3",
        .tools_json = "[]",
        .messages = &messages,
        .tool_choice = .auto,
    });
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("tools") == null);
    try std.testing.expect(root.get("tool_choice") == null);
    try std.testing.expect(root.get("max_tokens") == null);

    const message_items = root.get("messages").?.array.items;
    const assistant = message_items[1].object;
    try std.testing.expect(assistant.get("content").? == .null);
    const tool_call = assistant.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("call_1", tool_call.get("id").?.string);
    try std.testing.expectEqualStrings(
        "{\"path\":\"a.txt\"}",
        tool_call.get("function").?.object.get("arguments").?.string,
    );
    const tool_result = message_items[2].object;
    try std.testing.expectEqualStrings("tool", tool_result.get("role").?.string);
    try std.testing.expectEqualStrings("call_1", tool_result.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("contents", tool_result.get("content").?.string);
}

test "openai body rejects image attachments" {
    var path_buf = "img.png".*;
    var media_type_buf = "image/png".*;
    const attachment_messages = [_]ChatMessage{.{
        .role = .user,
        .content = "look",
        .images = &[_]types.ImageAttachment{.{
            .path = &path_buf,
            .media_type = &media_type_buf,
        }},
    }};
    try std.testing.expectError(error.ImageInputUnsupported, buildChatCompletionsBody(
        std.testing.allocator,
        .{
            .model = "gpt-5.2",
            .tools_json = "[]",
            .messages = &attachment_messages,
            .tool_choice = .auto,
        },
    ));
}
