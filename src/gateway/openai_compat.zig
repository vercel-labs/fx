const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");

const Allocator = std.mem.Allocator;

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = buildRequest,
    .stream_fn = streamCompletion,
};

pub fn fetchCatalog(
    alloc: Allocator,
    chat_url: []const u8,
    access: credentials.CatalogAccess,
) !model_catalog.ProviderResult {
    const models_url = try modelsUrl(alloc, chat_url);
    defer alloc.free(models_url);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var headers: [1]std.http.Header = undefined;
    var header_count: usize = 0;
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| alloc.free(value);
    if (access.authorizationCredential()) |token| {
        auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
        headers[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }
    const response = client.fetch(.{
        .location = .{ .url = models_url },
        .method = .GET,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = headers[0..header_count],
        .response_writer = &body.writer,
    }) catch |err| return err;
    if (response.status != .ok) return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    const bytes = try body.toOwnedSlice();
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = .{ .category = .malformed_response } };
    const data = parsed.value.object.get("data") orelse return .{ .failure = .{ .category = .malformed_response } };
    if (data != .array) return .{ .failure = .{ .category = .malformed_response } };
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (data.array.items) |item| {
        if (item != .object) continue;
        const id = item.object.get("id") orelse continue;
        if (id != .string or id.string.len == 0) continue;
        try entries.append(alloc, .{
            .id = try alloc.dupe(u8, id.string),
            .model_type = try alloc.dupe(u8, "custom"),
        });
    }
    return .{ .catalog = entries };
}

fn modelsUrl(alloc: Allocator, chat_url: []const u8) ![]u8 {
    const marker = "/chat/completions";
    if (std.mem.find(u8, chat_url, marker)) |index| {
        return try std.fmt.allocPrint(alloc, "{s}/models", .{chat_url[0..index]});
    }
    return try std.fmt.allocPrint(alloc, "{s}/models", .{std.mem.trimEnd(u8, chat_url, "/")});
}

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
    try writeOpenAiTools(&out.writer, alloc, request.serialized_tools);
    try out.writer.writeAll(",\"tool_choice\":");
    try writeJsonString(&out.writer, request.tool_choice.label());
    try out.writer.writeAll(",\"stream\":true}");
    return out.toOwnedSlice();
}

fn writeOpenAiTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    serialized_tools: []const u8,
) !void {
    if (serialized_tools.len == 0) {
        try writer.writeAll("[]");
        return;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolSchema;

    try writer.writeByte('[');
    var wrote_tool = false;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) return error.InvalidToolSchema;
        const object = tool.object;
        const type_value = object.get("type") orelse return error.InvalidToolSchema;
        const type_name = if (type_value == .string) type_value.string else return error.InvalidToolSchema;
        if (!std.mem.eql(u8, type_name, "function")) continue;
        if (wrote_tool) try writer.writeByte(',');
        wrote_tool = true;

        const name = object.get("name") orelse return error.InvalidToolSchema;
        const description = object.get("description");
        const parameters = object.get("inputSchema") orelse object.get("parameters") orelse return error.InvalidToolSchema;
        try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(name, .{}, writer);
        if (description) |value| {
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(value, .{}, writer);
        }
        try writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(parameters, .{}, writer);
        try writer.writeAll("}}");
    }
    try writer.writeByte(']');
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

    const uri = try std.Uri.parse(request.chat_url);
    var http_request = try client.request(.POST, uri, .{
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
            .accept_encoding = .omit,
            .user_agent = .{ .override = "fx" },
        },
    });
    defer http_request.deinit();
    try http_request.sendBodyComplete(@constCast(request.payload));
    var response = try http_request.receiveHead(&.{});
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var saw_sse = false;
    if (response.head.status == .ok) {
        var transfer_buffer: [8192]u8 = undefined;
        var response_reader = response.reader(&transfer_buffer);
        while (try response_reader.takeDelimiter('\n')) |line| {
            try body.writer.writeAll(line);
            try body.writer.writeByte('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.startsWith(u8, trimmed, "data:")) {
                const data = std.mem.trimStart(u8, trimmed[5..], " ");
                if (!std.mem.eql(u8, data, "[DONE]")) {
                    saw_sse = true;
                    try emitSseDelta(alloc, data, request);
                }
            }
        }
    } else {
        var error_buffer: [4096]u8 = undefined;
        const error_reader = response.reader(&error_buffer);
        _ = try error_reader.streamRemaining(&body.writer);
    }

    if (response.head.status != .ok) {
        return .{
            .status = response.head.status,
            .err_body = try body.toOwnedSlice(),
            .ownership = .owned,
        };
    }

    const bytes = try body.toOwnedSlice();
    defer alloc.free(bytes);
    var completion = if (saw_sse)
        try parseSseCompletion(alloc, bytes)
    else
        try parseCompletion(alloc, bytes);
    errdefer deinitCompletion(alloc, &completion);

    if (!saw_sse) {
        if (completion.content) |content| {
            request.on_content_chunk(request.callback_ctx, content);
        }
        if (request.on_reasoning_chunk) |callback| {
            if (completion.provider_failure_detail) |reasoning| {
                callback(request.callback_ctx, reasoning);
                alloc.free(@constCast(reasoning));
                completion.provider_failure_detail = null;
            } else if (try parseReasoningContent(alloc, bytes)) |reasoning| {
                defer alloc.free(reasoning);
                callback(request.callback_ctx, reasoning);
            }
        }
        for (completion.tool_calls) |call| {
            if (request.on_tool_start) |callback| callback(request.callback_ctx, call.id, call.name, null);
            if (request.on_tool_input_chunk) |callback| callback(request.callback_ctx, call.arguments_json);
        }
    }

    return .{
        .status = response.head.status,
        .completion = completion,
        .ownership = .owned,
    };
}

fn emitSseDelta(
    alloc: Allocator,
    data: []const u8,
    request: stream_provider.Request,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const choices = parsed.value.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;
    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;
    if (delta.object.get("content")) |content| {
        if (content == .string) request.on_content_chunk(request.callback_ctx, content.string);
    }
    if (delta.object.get("reasoning_content") orelse delta.object.get("reasoning")) |reasoning| {
        if (reasoning == .string) if (request.on_reasoning_chunk) |callback| callback(request.callback_ctx, reasoning.string);
    }
    if (delta.object.get("tool_calls")) |tool_calls| {
        if (tool_calls != .array) return error.MalformedResponse;
        for (tool_calls.array.items) |item| {
            if (item != .object) continue;
            const function = item.object.get("function") orelse continue;
            if (function != .object) continue;
            const id = item.object.get("id");
            const name = function.object.get("name");
            if (id != null and name != null and id.? == .string and name.? == .string) {
                if (request.on_tool_start) |callback| callback(request.callback_ctx, id.?.string, name.?.string, null);
            }
            if (function.object.get("arguments")) |arguments| {
                if (arguments == .string) if (request.on_tool_input_chunk) |callback| callback(request.callback_ctx, arguments.string);
            }
        }
    }
}

const SseToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

fn parseSseCompletion(alloc: Allocator, bytes: []const u8) !types.GatewayCompletion {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var content: std.ArrayList(u8) = .empty;
    var reasoning: std.ArrayList(u8) = .empty;
    var tools: std.ArrayList(SseToolAccumulator) = .empty;
    defer content.deinit(alloc);
    defer reasoning.deinit(alloc);
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var finish_reason: ?types.ProviderFinishReason = null;
    var input_tokens: ?u64 = null;
    var output_tokens: ?u64 = null;
    var generation_id: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trimStart(u8, trimmed[5..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{}) catch return error.MalformedResponse;
        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        if (root.get("id")) |id| {
            if (id == .string) generation_id = id.string;
        }
        if (root.get("usage")) |usage| if (usage == .object) {
            if (usage.object.get("prompt_tokens")) |value| input_tokens = jsonU64(value);
            if (usage.object.get("completion_tokens")) |value| output_tokens = jsonU64(value);
        };
        const choices = root.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;
        if (choice.object.get("finish_reason")) |finish| {
            if (finish == .string and !std.mem.eql(u8, finish.string, "null")) finish_reason = parseFinishReason(finish.string);
        }
        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;
        if (delta.object.get("content")) |value| {
            if (value == .string) try content.appendSlice(alloc, value.string);
        }
        if (delta.object.get("reasoning_content") orelse delta.object.get("reasoning")) |value| {
            if (value == .string) try reasoning.appendSlice(alloc, value.string);
        }
        if (delta.object.get("tool_calls")) |tool_calls| {
            if (tool_calls != .array) return error.MalformedResponse;
            for (tool_calls.array.items) |item| {
                if (item != .object) return error.MalformedResponse;
                const index_value = item.object.get("index") orelse return error.MalformedResponse;
                const index = jsonUsize(index_value) orelse return error.MalformedResponse;
                while (tools.items.len <= index) try tools.append(alloc, .{});
                const tool = &tools.items[index];
                if (item.object.get("id")) |id| {
                    if (id == .string) try tool.id.appendSlice(alloc, id.string);
                }
                const function = item.object.get("function") orelse continue;
                if (function != .object) continue;
                if (function.object.get("name")) |name| {
                    if (name == .string) try tool.name.appendSlice(alloc, name.string);
                }
                if (function.object.get("arguments")) |arguments| {
                    if (arguments == .string) try tool.arguments.appendSlice(alloc, arguments.string);
                }
            }
        }
    }

    var completion = types.GatewayCompletion{
        .content = if (content.items.len > 0) try alloc.dupe(u8, content.items) else null,
        .generation_id = if (generation_id) |id| try alloc.dupe(u8, id) else null,
        .finish_reason = finish_reason,
        .usage = .{ .input_tokens = input_tokens, .output_tokens = output_tokens },
    };
    errdefer deinitCompletion(alloc, &completion);
    if (reasoning.items.len > 0) completion.provider_failure_detail = try alloc.dupe(u8, reasoning.items);
    var calls: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            alloc.free(@constCast(call.id));
            alloc.free(@constCast(call.name));
            alloc.free(@constCast(call.arguments_json));
        }
        calls.deinit(alloc);
    }
    for (tools.items) |tool| {
        if (tool.name.items.len == 0) continue;
        try calls.append(alloc, .{
            .id = try alloc.dupe(u8, tool.id.items),
            .name = try alloc.dupe(u8, tool.name.items),
            .arguments_json = try alloc.dupe(u8, tool.arguments.items),
        });
    }
    completion.tool_calls = try calls.toOwnedSlice(alloc);
    return completion;
}

fn jsonUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
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
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"inputSchema\":{\"type\":\"object\"}},{\"type\":\"provider\",\"id\":\"gateway.search\"}]",
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"deepseek-chat\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"parameters\":{\"type\":\"object\"}}}]") != null);
    try std.testing.expect(std.mem.find(u8, body, "gateway.search") == null);
}

test "parses OpenAI SSE content and finish reason" {
    const sse = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n" ++
        "data: {\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n" ++
        "data: [DONE]\n";
    var completion = try parseSseCompletion(std.testing.allocator, sse);
    defer deinitCompletion(std.testing.allocator, &completion);
    try std.testing.expectEqualStrings("hi", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(u64, 2), completion.usage.input_tokens.?);
}

test "parses OpenAI tool calls and usage" {
    const json = "{\"id\":\"chatcmpl-1\",\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\\\\\"path\\\\\\\":\\\\\\\"README.md\\\\\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}";
    var completion = try parseCompletion(std.testing.allocator, json);
    defer deinitCompletion(std.testing.allocator, &completion);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(u64, 10), completion.usage.input_tokens.?);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
}
