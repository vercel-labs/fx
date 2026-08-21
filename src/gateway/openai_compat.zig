const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = buildRequest,
    .stream_fn = streamCompletion,
};

pub fn buildRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try writeJsonString(&out.writer, request.model);
    try out.writer.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeMessage(&out.writer, message);
    }
    try out.writer.writeAll("],\"tools\":");
    if (request.serialized_tools.len == 0) {
        try out.writer.writeAll("[]");
    } else {
        try out.writer.writeAll(request.serialized_tools);
    }
    try out.writer.writeAll(",\"tool_choice\":");
    try writeJsonString(&out.writer, request.tool_choice.label());
    try out.writer.writeAll(",\"stream\":false}");
    return out.toOwnedSlice();
}

fn writeMessage(writer: *std.Io.Writer, message: types.ChatMessage) !void {
    try writer.writeAll("{\"role\":");
    try writeJsonString(writer, @tagName(message.role));

    if (message.content) |content| {
        try writer.writeAll(",\"content\":");
        try writeJsonString(writer, content);
    } else {
        try writer.writeAll(",\"content\":null");
    }

    if (message.tool_call_id) |tool_call_id| {
        try writer.writeAll(",\"tool_call_id\":");
        try writeJsonString(writer, tool_call_id);
    }

    if (message.tool_calls.len > 0) {
        try writer.writeAll(",\"tool_calls\":[");
        for (message.tool_calls, 0..) |call, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            try writeJsonString(writer, call.id);
            try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
            try writeJsonString(writer, call.name);
            try writer.writeAll(",\"arguments\":");
            try writeJsonString(writer, call.arguments_json);
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer alloc.free(auth_header);

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    const response = client.fetch(.{
        .location = .{ .url = request.chat_url },
        .method = .POST,
        .payload = request.payload,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
            .accept_encoding = .omit,
            .user_agent = .{ .override = "fx" },
        },
        .response_writer = &body.writer,
    }) catch |err| {
        return err;
    };

    if (response.status != .ok) {
        return .{
            .status = response.status,
            .err_body = try body.toOwnedSlice(),
            .ownership = .owned,
        };
    }

    const bytes = try body.toOwnedSlice();
    defer alloc.free(bytes);
    var completion = try parseCompletion(alloc, bytes);
    errdefer deinitCompletion(alloc, &completion);

    if (completion.content) |content| {
        request.on_content_chunk(request.callback_ctx, content);
    }
    if (request.on_reasoning_chunk) |callback| {
        if (try parseReasoningContent(alloc, bytes)) |reasoning| {
            defer alloc.free(reasoning);
            callback(request.callback_ctx, reasoning);
        }
    }
    for (completion.tool_calls) |call| {
        if (request.on_tool_start) |callback| callback(request.callback_ctx, call.id, call.name, null);
        if (request.on_tool_input_chunk) |callback| callback(request.callback_ctx, call.arguments_json);
    }

    return .{
        .status = response.status,
        .completion = completion,
        .ownership = .owned,
    };
}

fn parseCompletion(alloc: Allocator, bytes: []const u8) !types.GatewayCompletion {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const root = parsed.value.object;
    const choices = root.get("choices") orelse return error.MalformedResponse;
    if (choices != .array or choices.array.items.len == 0) return error.MalformedResponse;
    const choice = choices.array.items[0];
    if (choice != .object) return error.MalformedResponse;
    const message = choice.object.get("message") orelse return error.MalformedResponse;
    if (message != .object) return error.MalformedResponse;

    var completion = types.GatewayCompletion{};
    errdefer deinitCompletion(alloc, &completion);
    if (message.object.get("content")) |content| {
        if (content == .string) completion.content = try alloc.dupe(u8, content.string);
    }
    if (choice.object.get("finish_reason")) |finish| {
        if (finish == .string) completion.finish_reason = parseFinishReason(finish.string);
    }
    if (root.get("id")) |id| {
        if (id == .string) completion.generation_id = try alloc.dupe(u8, id.string);
    }
    if (root.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |value| completion.usage.input_tokens = jsonU64(value);
            if (usage.object.get("completion_tokens")) |value| completion.usage.output_tokens = jsonU64(value);
        }
    }
    if (message.object.get("tool_calls")) |tool_calls| {
        if (tool_calls != .array) return error.MalformedResponse;
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                alloc.free(@constCast(call.id));
                alloc.free(@constCast(call.name));
                alloc.free(@constCast(call.arguments_json));
            }
            calls.deinit(alloc);
        }
        for (tool_calls.array.items) |item| {
            if (item != .object) return error.MalformedResponse;
            const id = item.object.get("id") orelse return error.MalformedResponse;
            const function = item.object.get("function") orelse return error.MalformedResponse;
            if (id != .string or function != .object) return error.MalformedResponse;
            const name = function.object.get("name") orelse return error.MalformedResponse;
            const arguments = function.object.get("arguments") orelse return error.MalformedResponse;
            if (name != .string or arguments != .string) return error.MalformedResponse;
            try calls.append(alloc, .{
                .id = try alloc.dupe(u8, id.string),
                .name = try alloc.dupe(u8, name.string),
                .arguments_json = try alloc.dupe(u8, arguments.string),
            });
        }
        completion.tool_calls = try calls.toOwnedSlice(alloc);
    }
    return completion;
}

fn parseReasoningContent(alloc: Allocator, bytes: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const choices = parsed.value.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    const choice = choices.array.items[0];
    if (choice != .object) return null;
    const message = choice.object.get("message") orelse return null;
    if (message != .object) return null;
    const value = message.object.get("reasoning_content") orelse message.object.get("reasoning") orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return try alloc.dupe(u8, value.string);
}

fn jsonU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn parseFinishReason(value: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, value, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, value, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "stop")) return .stop;
    return .other;
}

fn deinitCompletion(alloc: Allocator, completion: *types.GatewayCompletion) void {
    if (completion.content) |value| alloc.free(@constCast(value));
    if (completion.generation_id) |value| alloc.free(@constCast(value));
    if (completion.provider_state_json) |value| alloc.free(@constCast(value));
    if (completion.tool_calls.len > 0) {
        for (completion.tool_calls) |call| {
            alloc.free(@constCast(call.id));
            alloc.free(@constCast(call.name));
            alloc.free(@constCast(call.arguments_json));
        }
        alloc.free(@constCast(completion.tool_calls));
    }
    completion.* = .{};
}

test "builds OpenAI-compatible messages and tools" {
    const message = types.ChatMessage{ .role = .user, .content = "hello" };
    const body = try buildRequest(null, std.testing.allocator, .{
        .model = "deepseek-chat",
        .messages = &.{message},
        .serialized_tools = "[{\"type\":\"function\"}]",
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"deepseek-chat\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\":[{\"type\":\"function\"}]") != null);
}

test "parses OpenAI tool calls and usage" {
    const json = "{\"id\":\"chatcmpl-1\",\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\\\\\"path\\\\\\\":\\\\\\\"README.md\\\\\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}";
    var completion = try parseCompletion(std.testing.allocator, json);
    defer deinitCompletion(std.testing.allocator, &completion);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(u64, 10), completion.usage.input_tokens.?);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
}
