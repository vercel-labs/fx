const std = @import("std");
const secret = @import("../core/auth/secret.zig");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_json = @import("../core/gateway/gateway_json.zig");
const gateway_client = @import("client.zig");
const providers_config = @import("../core/providers/config.zig");
const providers_catalog = @import("../core/providers/catalog.zig");

const Allocator = std.mem.Allocator;
const StreamCallback = agent_stream_provider.StreamCallback;
const ToolStartCallback = agent_stream_provider.ToolStartCallback;
pub const StreamResult = gateway_client.StreamResult;
pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;

const max_sse_event_line_bytes: usize = 32 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;

pub const StreamRequest = struct {
    api_key: []const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    trace_ctx: debug_trace.TraceContext = .{},
    content_capture_limit: ?usize = null,
    delivery: ?*DeliveryCertainty = null,
    on_reasoning_chunk: ?StreamCallback = null,
    on_tool_input_chunk: ?StreamCallback = null,
    provider_attempt_owner: agent_stream_provider.ProviderAttemptOwner = .transport,
};

pub fn buildChatCompletionsBody(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, &out.writer);
    try out.writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    for (request.messages, 0..) |message, i| {
        if (i > 0) try out.writer.writeByte(',');
        try writeChatMessage(&out.writer, message);
    }
    try out.writer.writeAll("],\"tools\":");
    try writeOpenAiToolsJson(alloc, &out.writer, request.serialized_tools);
    try out.writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, &out.writer);
    if (request.max_output_tokens) |value| {
        try out.writer.print(",\"max_tokens\":{d}", .{value});
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeChatMessage(writer: *std.Io.Writer, message: types.ChatMessage) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(gateway_json.roleName(message.role), .{}, writer);
    switch (message.role) {
        .system, .user => {
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
            } else {
                try writer.writeAll(",\"content\":null");
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
        },
        .tool => {
            try writer.writeAll(",\"tool_call_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
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

fn writeOpenAiToolsJson(alloc: Allocator, writer: *std.Io.Writer, serialized_tools: []const u8) !void {
    if (serialized_tools.len == 0) {
        try writer.writeAll("[]");
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try writer.writeAll("[]");
            return;
        },
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        try writer.writeAll("[]");
        return;
    }

    try writer.writeByte('[');
    var wrote = false;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const converted = convertToolObject(item.object) orelse continue;
        if (wrote) try writer.writeByte(',');
        wrote = true;
        try writeConvertedTool(writer, converted);
    }
    try writer.writeByte(']');
}

const ConvertedTool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

fn convertToolObject(object: std.json.ObjectMap) ?ConvertedTool {
    if (object.get("function")) |function_value| {
        if (function_value != .object) return null;
        const name_value = function_value.object.get("name") orelse return null;
        if (name_value != .string or name_value.string.len == 0) return null;
        const description = if (function_value.object.get("description")) |value|
            if (value == .string) value.string else ""
        else
            "";
        const parameters = function_value.object.get("parameters") orelse std.json.Value{ .object = .empty };
        return .{
            .name = name_value.string,
            .description = description,
            .parameters = parameters,
        };
    }

    const type_value = object.get("type") orelse return null;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "function")) return null;
    const name_value = object.get("name") orelse return null;
    if (name_value != .string or name_value.string.len == 0) return null;
    const description = if (object.get("description")) |value|
        if (value == .string) value.string else ""
    else
        "";
    const parameters = object.get("inputSchema") orelse object.get("parameters") orelse std.json.Value{ .object = .empty };
    return .{
        .name = name_value.string,
        .description = description,
        .parameters = parameters,
    };
}

fn writeConvertedTool(writer: *std.Io.Writer, tool: ConvertedTool) !void {
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(tool.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(tool.description, .{}, writer);
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(tool.parameters, .{}, writer);
    try writer.writeAll("}}");
}

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    started: bool = false,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = .{};
    }
};

pub const ParseCallbacks = struct {
    ctx: *anyopaque,
    on_content_chunk: ?StreamCallback = null,
    on_tool_start: ?ToolStartCallback = null,
    on_tool_input_chunk: ?StreamCallback = null,
};

pub fn parseSseBytes(
    alloc: Allocator,
    sse_bytes: []const u8,
    content_capture_limit: ?usize,
    callbacks: ParseCallbacks,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }

    var finish_reason: ?types.ProviderFinishReason = null;
    var usage = types.Usage{};
    var line_start: usize = 0;
    while (line_start < sse_bytes.len) {
        const line_end = std.mem.findScalarPos(u8, sse_bytes, line_start, '\n') orelse sse_bytes.len;
        const raw_line = sse_bytes[line_start..line_end];
        line_start = if (line_end < sse_bytes.len) line_end + 1 else sse_bytes.len;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == ':') continue;
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const json_text = std.mem.trimStart(u8, line["data:".len..], " ");
        if (json_text.len == 0) continue;
        if (std.mem.eql(u8, json_text, "[DONE]")) break;
        try consumeSseJson(
            alloc,
            json_text,
            &content,
            &tools,
            &finish_reason,
            &usage,
            content_capture_limit,
            callbacks,
        );
    }

    return finishCompletion(alloc, &content, &tools, finish_reason, usage);
}

fn consumeSseJson(
    alloc: Allocator,
    json_text: []const u8,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    finish_reason: *?types.ProviderFinishReason,
    usage: *types.Usage,
    content_capture_limit: ?usize,
    callbacks: ParseCallbacks,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;

    if (root.get("usage")) |usage_value| {
        if (usage_value == .object) {
            if (tokenTotal(usage_value, "prompt_tokens")) |value| usage.input_tokens = value;
            if (tokenTotal(usage_value, "completion_tokens")) |value| usage.output_tokens = value;
        }
    }

    const choices = root.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;

    if (choice.object.get("finish_reason")) |reason_value| {
        if (reason_value == .string) {
            finish_reason.* = parseFinishReason(reason_value.string);
        }
    }

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("content")) |content_value| {
        if (content_value == .string and content_value.string.len > 0) {
            const retained = if (content_capture_limit) |limit|
                content_value.string[0..@min(content_value.string.len, limit -| content.items.len)]
            else
                content_value.string;
            try content.appendSlice(alloc, retained);
            if (callbacks.on_content_chunk) |callback| callback(callbacks.ctx, content_value.string);
        }
    }

    if (delta.object.get("tool_calls")) |tool_calls_value| {
        if (tool_calls_value == .array) {
            try consumeToolCallDeltas(alloc, tool_calls_value.array.items, tools, callbacks);
        }
    }
}

fn consumeToolCallDeltas(
    alloc: Allocator,
    deltas: []const std.json.Value,
    tools: *std.ArrayList(ToolAccumulator),
    callbacks: ParseCallbacks,
) !void {
    for (deltas) |delta_value| {
        if (delta_value != .object) continue;
        const index = jsonIndex(delta_value.object.get("index")) orelse 0;
        while (tools.items.len <= index) {
            try tools.append(alloc, .{});
        }
        const acc = &tools.items[index];
        if (delta_value.object.get("id")) |id_value| {
            if (id_value == .string and id_value.string.len > 0 and acc.id.items.len == 0) {
                try acc.id.appendSlice(alloc, id_value.string);
            }
        }
        const function_value = delta_value.object.get("function") orelse continue;
        if (function_value != .object) continue;
        if (function_value.object.get("name")) |name_value| {
            if (name_value == .string and name_value.string.len > 0 and acc.name.items.len == 0) {
                try acc.name.appendSlice(alloc, name_value.string);
                if (!acc.started) {
                    acc.started = true;
                    if (callbacks.on_tool_start) |callback| {
                        callback(callbacks.ctx, acc.id.items, acc.name.items, null);
                    }
                }
            }
        }
        if (function_value.object.get("arguments")) |arguments_value| {
            if (arguments_value == .string and arguments_value.string.len > 0) {
                try acc.arguments.appendSlice(alloc, arguments_value.string);
                if (callbacks.on_tool_input_chunk) |callback| {
                    callback(callbacks.ctx, arguments_value.string);
                }
            }
        }
    }
}

fn finishCompletion(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    finish_reason: ?types.ProviderFinishReason,
    usage: types.Usage,
) !types.GatewayCompletion {
    var tool_calls: []types.ToolCall = &.{};
    if (tools.items.len > 0) {
        tool_calls = try alloc.alloc(types.ToolCall, tools.items.len);
        var filled: usize = 0;
        errdefer {
            types.freeToolCallSlice(alloc, tool_calls[0..filled]);
            alloc.free(tool_calls);
        }
        for (tools.items) |*acc| {
            tool_calls[filled] = .{
                .id = try acc.id.toOwnedSlice(alloc),
                .name = try acc.name.toOwnedSlice(alloc),
                .arguments_json = try acc.arguments.toOwnedSlice(alloc),
            };
            filled += 1;
        }
        tools.clearRetainingCapacity();
    }

    const content_text = if (content.items.len == 0) null else try content.toOwnedSlice(alloc);
    return .{
        .content = content_text,
        .tool_calls = tool_calls,
        .finish_reason = finish_reason,
        .usage = usage,
    };
}

fn parseFinishReason(raw: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length")) return .length;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, raw, "tool_calls")) return .tool_calls;
    return .other;
}

fn tokenTotal(usage_value: std.json.Value, key: []const u8) ?u64 {
    const value = usage_value.object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |n| if (n >= 0) @intFromFloat(n) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn jsonIndex(value: ?std.json.Value) ?usize {
    const index = value orelse return null;
    return switch (index) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

pub fn streamChatCompletions(
    alloc: Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const retry_count = switch (request.provider_attempt_owner) {
        .agent => 1,
        .transport => @max(request.retry_count, 1),
    };
    const uri = try std.Uri.parse(request.chat_url);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth_header);

    var attempt: usize = 0;
    while (attempt < retry_count) : (attempt += 1) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        var req = client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) catch |err| {
            if (request.provider_attempt_owner == .transport and attempt + 1 < retry_count) continue;
            return err;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = request.payload.len };
        if (request.delivery) |delivery| delivery.markPossiblySent();
        var send_buf: [8192]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&send_buf);
        try body_writer.writer.writeAll(request.payload);
        try body_writer.end();
        if (req.connection) |conn| try conn.flush();

        var response = try req.receiveHead(&.{});
        if (response.head.status != .ok) {
            var err_out: std.Io.Writer.Allocating = .init(alloc);
            defer err_out.deinit();
            var err_buf: [4096]u8 = undefined;
            const err_reader = response.reader(&err_buf);
            _ = err_reader.streamRemaining(&err_out.writer) catch {};
            const retryable = @intFromEnum(response.head.status) >= 500;
            if (retryable and request.provider_attempt_owner == .transport and attempt + 1 < retry_count) {
                continue;
            }
            return .{
                .status = response.head.status,
                .err_body = err_out.toOwnedSlice() catch null,
            };
        }

        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var sse_bytes: std.Io.Writer.Allocating = .init(alloc);
        defer sse_bytes.deinit();
        _ = reader.streamRemaining(&sse_bytes.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const completion = try parseSseBytes(alloc, sse_bytes.written(), request.content_capture_limit, .{
            .ctx = callback_ctx,
            .on_content_chunk = on_content_chunk,
            .on_tool_start = on_tool_start,
            .on_tool_input_chunk = request.on_tool_input_chunk,
        });
        return .{
            .status = .ok,
            .completion = completion,
        };
    }
    return error.ReadFailed;
}

pub fn fetchModelIds(alloc: Allocator, api_key: []const u8, models_url: []const u8) !std.ArrayList([]u8) {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
    defer secret.zeroAndFree(alloc, auth_header);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = models_url },
        .method = .GET,
        .headers = .{
            .authorization = .{ .override = auth_header },
            .accept_encoding = .omit,
            .user_agent = .{ .override = gateway_client.user_agent },
        },
        .response_writer = &out.writer,
        .redirect_behavior = .unhandled,
    });
    if (result.status != .ok) return error.Unavailable;
    return providers_catalog.parseModelIds(alloc, out.written());
}

test "chat completions builder emits stream tools and openai-shaped messages" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "be brief" },
        .{ .role = .user, .content = "hello" },
        .{
            .role = .assistant,
            .content = null,
            .tool_calls = &.{.{
                .id = "call_1",
                .name = "read_file",
                .arguments_json = "{\"path\":\"README.md\"}",
            }},
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "ok" },
    };
    const body = try buildChatCompletionsBody(std.testing.allocator, .{
        .model = "gpt-4.1",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 128,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-4.1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":128") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"inputSchema\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"prompt\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "text-delta") == null);
}

test "chat completions parser streams content tool calls and usage" {
    const Capture = struct {
        chunks: std.ArrayList(u8) = .empty,
        tool_name: ?[]const u8 = null,

        fn onContent(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.chunks.appendSlice(std.testing.allocator, chunk) catch {};
        }

        fn onToolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_name = name;
        }
    };
    var capture: Capture = .{};
    defer capture.chunks.deinit(std.testing.allocator);

    const sse =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello\"}}]}\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\" world\"}}]}\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":4}}\n" ++
        "data: [DONE]\n";
    const completion = try parseSseBytes(std.testing.allocator, sse, null, .{
        .ctx = @ptrCast(&capture),
        .on_content_chunk = Capture.onContent,
        .on_tool_start = Capture.onToolStart,
    });
    defer {
        if (completion.content) |content| std.testing.allocator.free(@constCast(content));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }

    try std.testing.expectEqualStrings("Hello world", capture.chunks.items);
    try std.testing.expectEqualStrings("Hello world", completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 9), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), completion.usage.output_tokens);
}

test "chat completions parser ignores gateway v3 event types" {
    const sse =
        "data: {\"type\":\"text-delta\",\"delta\":\"should-not-appear\"}\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n" ++
        "data: [DONE]\n";
    const completion = try parseSseBytes(std.testing.allocator, sse, null, .{
        .ctx = undefined,
    });
    defer if (completion.content) |content| std.testing.allocator.free(@constCast(content));
    try std.testing.expectEqualStrings("ok", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
}

const LoopbackCompletionsFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    server_open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    accept_started: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    saw_chat_completions: std.atomic.Value(bool) = .init(false),

    fn init() !@This() {
        var fixture: @This() = .{
            .server = undefined,
        };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.server_open) return;
        const zio = self.io();
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            self.wakeAccept();
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
        self.server_open = false;
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn wakeAccept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        var stream = address.connect(zio, .{ .mode = .stream }) catch return;
        stream.close(zio);
    }

    fn waitForAcceptStart(self: *@This(), timeout_ms: u64) bool {
        var remaining = timeout_ms;
        while (remaining > 0) : (remaining -= 1) {
            if (self.accept_started.load(.seq_cst)) return true;
            var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
            sleep_io_backend.io().sleep(.fromMilliseconds(1), .real) catch {};
        }
        return self.accept_started.load(.seq_cst);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst)) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        self.accept_started.store(true, .seq_cst);
        var stream = self.server.accept(zio) catch |err| {
            if (self.stopping.load(.seq_cst)) return;
            return err;
        };
        defer stream.close(zio);

        var socket_buffer: [4096]u8 = undefined;
        var reader = stream.reader(zio, &socket_buffer);
        var request: [16 * 1024]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < request.len) {
            request[header_len] = reader.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            header_len += 1;
            if (!std.mem.endsWith(u8, request[0..header_len], "\r\n\r\n")) continue;
            if (std.mem.find(u8, request[0..header_len], "/v1/chat/completions") != null) {
                self.saw_chat_completions.store(true, .seq_cst);
            }
            if (loopbackContentLength(request[0 .. header_len - 4])) |content_length| {
                reader.interface.discardAll(content_length) catch {};
            }
            break;
        }

        const body =
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello from chat completions\"}}]}\r\n\r\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":5}}\r\n\r\n" ++
            "data: [DONE]\r\n\r\n";
        const response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" ++ body;
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(zio, &write_buffer);
        try writer.interface.writeAll(response);
        try writer.interface.flush();
    }
};

fn loopbackContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const name = "content-length:";
        if (line.len < name.len or !std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " \t"), 10) catch null;
    }
    return null;
}

test "local fake /v1/chat/completions streams a chat completions reply" {
    var fixture = try LoopbackCompletionsFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(1000));

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(url);

    const Capture = struct {
        chunks: std.ArrayList(u8) = .empty,
        fn onContent(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.chunks.appendSlice(std.testing.allocator, chunk) catch {};
        }
    };
    var capture: Capture = .{};
    defer capture.chunks.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();

    var result = try streamChatCompletions(
        std.testing.allocator,
        .{
            .api_key = "sk-test",
            .model = "gpt-4.1",
            .retry_count = 1,
            .chat_url = url,
            .payload = "{\"model\":\"gpt-4.1\",\"stream\":true,\"messages\":[]}",
            .delivery = &delivery,
        },
        @ptrCast(&capture),
        Capture.onContent,
        null,
        &cancelled,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expectEqualStrings("hello from chat completions", capture.chunks.items);
    try std.testing.expectEqualStrings("hello from chat completions", result.completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, result.completion.finish_reason.?);
    try std.testing.expect(fixture.saw_chat_completions.load(.seq_cst));
    try std.testing.expectEqual(DeliveryCertainty.State.possibly_sent, delivery.load());
    if (fixture.failure) |err| return err;
}

test "join helper used by local completions path keeps v1 prefix" {
    const url = try providers_config.joinChatCompletionsUrl(std.testing.allocator, "http://127.0.0.1:9/v1");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/v1/chat/completions", url);
}
