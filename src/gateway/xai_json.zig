const std = @import("std");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const default_chat_path = "/v1/chat/completions";
pub const default_chat_url = "https://api.x.ai/v1/chat/completions";

pub fn wireModelId(model: []const u8) []const u8 {
    const prefix = "xai/";
    if (std.mem.startsWith(u8, model, prefix)) return model[prefix.len..];
    return model;
}

pub fn catalogModelId(alloc: Allocator, wire_id: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, wire_id, "xai/")) return alloc.dupe(u8, wire_id);
    return std.fmt.allocPrint(alloc, "xai/{s}", .{wire_id});
}

pub fn isXaiChatUrl(url: []const u8) bool {
    return std.mem.eql(u8, url, default_chat_url) or
        std.mem.endsWith(u8, url, default_chat_path);
}

pub fn buildChatCompletionsBody(
    alloc: Allocator,
    model: []const u8,
    tools_json: []const u8,
    messages: []const types.ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(wireModelId(model), .{}, writer);
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    for (messages, 0..) |message, i| {
        if (i > 0) try writer.writeByte(',');
        try writeMessage(writer, message);
    }
    try writer.writeAll("],\"tools\":");
    try writeOpenAiTools(alloc, writer, tools_json);
    try writer.writeAll(",\"tool_choice\":");
    try writeToolChoice(writer, tool_choice);
    if (options.reasoning) |reasoning| {
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(reasoning.label(), .{}, writer);
    }
    if (options.parallel_tool_calls) |parallel| {
        try writer.writeAll(",\"parallel_tool_calls\":");
        try writer.writeAll(if (parallel) "true" else "false");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeToolChoice(writer: *std.Io.Writer, tool_choice: types.ToolChoice) !void {
    switch (tool_choice) {
        .auto => try writer.writeAll("\"auto\""),
        .none => try writer.writeAll("\"none\""),
    }
}

fn writeMessage(writer: *std.Io.Writer, message: types.ChatMessage) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(gatewayRoleName(message.role), .{}, writer);
    if (message.role == .tool) {
        const call_id = message.tool_call_id orelse return error.InvalidGatewayHistory;
        try writer.writeAll(",\"tool_call_id\":");
        try std.json.Stringify.value(call_id, .{}, writer);
    }
    if (message.tool_calls.len > 0) {
        try writer.writeAll(",\"tool_calls\":[");
        for (message.tool_calls, 0..) |call, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            try std.json.Stringify.value(call.id, .{}, writer);
            try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.value(call.name, .{}, writer);
            try writer.writeAll(",\"arguments\":");
            try std.json.Stringify.value(call.arguments_json, .{}, writer);
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
    }
    try writer.writeAll(",\"content\":");
    if (message.content) |content| {
        try std.json.Stringify.value(content, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn gatewayRoleName(role: types.ChatRole) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn writeOpenAiTools(alloc: Allocator, writer: *std.Io.Writer, tools_json: []const u8) !void {
    if (tools_json.len == 0) {
        try writer.writeAll("[]");
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{}) catch {
        try writer.writeAll(tools_json);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        try writer.writeAll(tools_json);
        return;
    }

    try writer.writeByte('[');
    var first = true;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writeOpenAiTool(writer, item.object);
    }
    try writer.writeByte(']');
}

fn writeOpenAiTool(writer: *std.Io.Writer, object: std.json.ObjectMap) !void {
    const name = objectString(object, "name") orelse return error.InvalidGatewayRequestBody;
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    if (objectString(object, "description")) |description| {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description, .{}, writer);
    }
    try writer.writeAll(",\"parameters\":");
    if (object.get("inputSchema")) |schema| {
        try std.json.Stringify.value(schema, .{}, writer);
    } else if (object.get("parameters")) |schema| {
        try std.json.Stringify.value(schema, .{}, writer);
    } else {
        try writer.writeAll("{\"type\":\"object\",\"properties\":{}}");
    }
    try writer.writeAll("}}");
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub const StreamDelta = struct {
    content: ?[]u8 = null,
    finish_reason: ?[]u8 = null,
    tool_call_index: ?usize = null,
    tool_call_id: ?[]u8 = null,
    tool_call_name: ?[]u8 = null,
    tool_call_arguments: ?[]u8 = null,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,

    pub fn deinit(self: *StreamDelta, alloc: Allocator) void {
        if (self.content) |value| alloc.free(value);
        if (self.finish_reason) |value| alloc.free(value);
        if (self.tool_call_id) |value| alloc.free(value);
        if (self.tool_call_name) |value| alloc.free(value);
        if (self.tool_call_arguments) |value| alloc.free(value);
        self.* = .{};
    }
};

pub fn parseSseDataLine(bytes: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    const prefix = "data:";
    const payload = if (std.mem.startsWith(u8, trimmed, prefix))
        std.mem.trim(u8, trimmed[prefix.len..], " \t")
    else
        trimmed;
    if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) return null;
    return payload;
}

pub fn parseChatCompletionsDelta(alloc: Allocator, json_bytes: []const u8) !StreamDelta {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch
        return error.InvalidXaiStreamEvent;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidXaiStreamEvent;
    const root = parsed.value.object;
    var delta = StreamDelta{};
    errdefer delta.deinit(alloc);

    if (root.get("usage")) |usage_val| {
        if (usage_val == .object) {
            delta.input_tokens = jsonU64(usage_val.object.get("prompt_tokens"));
            delta.output_tokens = jsonU64(usage_val.object.get("completion_tokens"));
        }
    }

    const choices = root.get("choices") orelse return delta;
    if (choices != .array or choices.array.items.len == 0) return delta;
    const choice = choices.array.items[0];
    if (choice != .object) return error.InvalidXaiStreamEvent;
    if (objectString(choice.object, "finish_reason")) |reason| {
        delta.finish_reason = try alloc.dupe(u8, reason);
    }
    const delta_val = choice.object.get("delta") orelse return delta;
    if (delta_val != .object) return delta;
    if (objectString(delta_val.object, "content")) |content| {
        if (content.len > 0) delta.content = try alloc.dupe(u8, content);
    }
    if (delta_val.object.get("tool_calls")) |calls| {
        if (calls == .array and calls.array.items.len > 0 and calls.array.items[0] == .object) {
            const call = calls.array.items[0].object;
            if (call.get("index")) |index| {
                if (index == .integer and index.integer >= 0) {
                    delta.tool_call_index = @intCast(index.integer);
                }
            }
            if (objectString(call, "id")) |id| delta.tool_call_id = try alloc.dupe(u8, id);
            if (call.get("function")) |function| {
                if (function == .object) {
                    if (objectString(function.object, "name")) |name|
                        delta.tool_call_name = try alloc.dupe(u8, name);
                    if (objectString(function.object, "arguments")) |arguments|
                        delta.tool_call_arguments = try alloc.dupe(u8, arguments);
                }
            }
        }
    }
    return delta;
}

fn jsonU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

test "wire model id strips the xai prefix" {
    try std.testing.expectEqualStrings("grok-4.6", wireModelId("xai/grok-4.6"));
    try std.testing.expectEqualStrings("grok-4.6", wireModelId("grok-4.6"));
}

test "catalog model id adds the xai prefix" {
    const prefixed = try catalogModelId(std.testing.allocator, "grok-4.6");
    defer std.testing.allocator.free(prefixed);
    try std.testing.expectEqualStrings("xai/grok-4.6", prefixed);
}

test "chat completions body uses openai messages and strips the model prefix" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "hello" },
    };
    const body = try buildChatCompletionsBody(
        std.testing.allocator,
        "xai/grok-4.6",
        "[]",
        &messages,
        .{},
        .auto,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"grok-4.6\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"xai/grok-4.6\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"content\":\"hello\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"prompt\"") == null);
}

test "chat completions body converts AI SDK tools to openai functions" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "read it" },
    };
    const tools =
        \\[{"type":"function","name":"read_file","description":"Read","inputSchema":{"type":"object","properties":{}}}]
    ;
    const body = try buildChatCompletionsBody(
        std.testing.allocator,
        "xai/grok-4.6",
        tools,
        &messages,
        .{ .parallel_tool_calls = true },
        .auto,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"inputSchema\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"parallel_tool_calls\":true") != null);
}

test "chat completions body maps assistant tool calls and tool results" {
    const calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .content = null, .tool_calls = &calls },
        .{ .role = .tool, .content = "ok", .tool_call_id = "call_1", .tool_name = "read_file" },
    };
    const body = try buildChatCompletionsBody(
        std.testing.allocator,
        "grok-4.6",
        "[]",
        &messages,
        .{},
        .auto,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"") != null);
}

test "parse chat completions content delta" {
    const json =
        \\{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
    ;
    var delta = try parseChatCompletionsDelta(std.testing.allocator, json);
    defer delta.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello", delta.content.?);
    try std.testing.expect(delta.finish_reason == null);
}

test "parse chat completions tool call delta" {
    const json =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{"}}]}}]}
    ;
    var delta = try parseChatCompletionsDelta(std.testing.allocator, json);
    defer delta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?usize, 0), delta.tool_call_index);
    try std.testing.expectEqualStrings("call_1", delta.tool_call_id.?);
    try std.testing.expectEqualStrings("read_file", delta.tool_call_name.?);
    try std.testing.expectEqualStrings("{", delta.tool_call_arguments.?);
}

test "parse sse data line ignores done sentinels" {
    try std.testing.expectEqualStrings("{\"a\":1}", parseSseDataLine("data: {\"a\":1}").?);
    try std.testing.expect(parseSseDataLine("data: [DONE]") == null);
    try std.testing.expect(parseSseDataLine("") == null);
}
