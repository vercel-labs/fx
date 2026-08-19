const std = @import("std");
const secret = @import("../core/auth/secret.zig");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const StreamCallback = agent_stream_provider.StreamCallback;
const ToolStartCallback = agent_stream_provider.ToolStartCallback;
pub const StreamResult = gateway_client.StreamResult;
pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;

const transfer_buffer_bytes: usize = 256 * 1024;

pub const StreamRequest = struct {
    api_key: []const u8,
    account_id: ?[]const u8 = null,
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

pub fn buildResponsesBody(
    alloc: Allocator,
    request: agent_stream_provider.BuildRequest,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, &out.writer);
    try out.writer.writeAll(",\"stream\":true,\"store\":false");

    var instructions: std.ArrayList(u8) = .empty;
    defer instructions.deinit(alloc);
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const content = message.content orelse continue;
        if (content.len == 0) continue;
        if (instructions.items.len > 0) try instructions.append(alloc, '\n');
        try instructions.appendSlice(alloc, content);
    }
    if (instructions.items.len > 0) {
        try out.writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(instructions.items, .{}, &out.writer);
    }

    try out.writer.writeAll(",\"input\":[");
    var wrote_input = false;
    for (request.messages) |message| {
        if (message.role == .system) continue;
        if (wrote_input) try out.writer.writeByte(',');
        wrote_input = true;
        try writeInputItem(&out.writer, message);
    }
    try out.writer.writeAll("],\"tools\":");
    try writeResponsesToolsJson(alloc, &out.writer, request.serialized_tools);
    try out.writer.writeAll(",\"tool_choice\":");
    try writeToolChoice(&out.writer, request.tool_choice);
    if (request.max_output_tokens) |value| {
        try out.writer.print(",\"max_output_tokens\":{d}", .{value});
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeToolChoice(writer: *std.Io.Writer, choice: types.ToolChoice) !void {
    try std.json.Stringify.value(choice.label(), .{}, writer);
}

fn writeInputItem(writer: *std.Io.Writer, message: types.ChatMessage) !void {
    switch (message.role) {
        .system => unreachable,
        .user => {
            try writer.writeAll("{\"role\":\"user\",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            try writer.writeByte('}');
        },
        .assistant => {
            if (message.tool_calls.len > 0) {
                for (message.tool_calls, 0..) |call, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeByte('}');
                }
                return;
            }
            try writer.writeAll("{\"role\":\"assistant\",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            try writer.writeByte('}');
        },
        .tool => {
            try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
            try writer.writeAll(",\"output\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
            try writer.writeByte('}');
        },
    }
}

fn writeResponsesToolsJson(alloc: Allocator, writer: *std.Io.Writer, serialized_tools: []const u8) !void {
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
        try writer.writeAll("{\"type\":\"function\",\"name\":");
        try std.json.Stringify.value(converted.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(converted.description, .{}, writer);
        try writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(converted.parameters, .{}, writer);
        try writer.writeByte('}');
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

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    started: bool = false,
    output_index: ?usize = null,

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
    on_reasoning_chunk: ?StreamCallback = null,
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
    var event_type: []const u8 = "";
    var line_start: usize = 0;
    while (line_start < sse_bytes.len) {
        const line_end = std.mem.findScalarPos(u8, sse_bytes, line_start, '\n') orelse sse_bytes.len;
        const raw_line = sse_bytes[line_start..line_end];
        line_start = if (line_end < sse_bytes.len) line_end + 1 else sse_bytes.len;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) {
            event_type = "";
            continue;
        }
        if (line[0] == ':') continue;
        if (std.mem.startsWith(u8, line, "event:")) {
            event_type = std.mem.trim(u8, line["event:".len..], " ");
            continue;
        }
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const json_text = std.mem.trimStart(u8, line["data:".len..], " ");
        if (json_text.len == 0 or std.mem.eql(u8, json_text, "[DONE]")) continue;
        try consumeSseJson(
            alloc,
            json_text,
            event_type,
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
    event_type: []const u8,
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
    const typed = if (root.get("type")) |value|
        if (value == .string) value.string else event_type
    else
        event_type;

    if (root.get("response")) |response_value| {
        if (response_value == .object) {
            if (response_value.object.get("usage")) |usage_value| {
                applyUsage(usage, usage_value);
            }
            if (response_value.object.get("status")) |status_value| {
                if (status_value == .string) {
                    if (std.mem.eql(u8, status_value.string, "completed")) {
                        if (finish_reason.* == null) finish_reason.* = .stop;
                    } else if (std.mem.eql(u8, status_value.string, "incomplete")) {
                        finish_reason.* = .length;
                    } else if (std.mem.eql(u8, status_value.string, "failed")) {
                        finish_reason.* = .other;
                    }
                }
            }
        }
    }
    if (root.get("usage")) |usage_value| applyUsage(usage, usage_value);

    if (std.mem.eql(u8, typed, "response.output_text.delta") or
        std.mem.eql(u8, typed, "response.text.delta"))
    {
        try appendTextDelta(alloc, content, stringField(root, "delta"), content_capture_limit, callbacks.on_content_chunk, callbacks.ctx);
        return;
    }
    if (std.mem.eql(u8, typed, "response.reasoning_summary_text.delta") or
        std.mem.eql(u8, typed, "response.reasoning.delta"))
    {
        if (callbacks.on_reasoning_chunk) |callback| {
            if (stringField(root, "delta")) |delta| callback(callbacks.ctx, delta);
        }
        return;
    }
    if (std.mem.eql(u8, typed, "response.output_item.added")) {
        try consumeOutputItemAdded(alloc, root, tools, callbacks);
        return;
    }
    if (std.mem.eql(u8, typed, "response.function_call_arguments.delta")) {
        try consumeFunctionArgumentsDelta(alloc, root, tools, callbacks);
        return;
    }
    if (std.mem.eql(u8, typed, "response.completed")) {
        if (finish_reason.* == null) finish_reason.* = if (hasTools(tools)) .tool_calls else .stop;
        return;
    }
    if (std.mem.eql(u8, typed, "response.failed") or std.mem.eql(u8, typed, "error")) {
        finish_reason.* = .other;
    }
}

fn consumeOutputItemAdded(
    alloc: Allocator,
    root: std.json.ObjectMap,
    tools: *std.ArrayList(ToolAccumulator),
    callbacks: ParseCallbacks,
) !void {
    const item = root.get("item") orelse return;
    if (item != .object) return;
    const item_type = stringField(item.object, "type") orelse return;
    if (!std.mem.eql(u8, item_type, "function_call")) return;
    const output_index = jsonIndex(root.get("output_index"));
    try tools.append(alloc, .{});
    const acc = &tools.items[tools.items.len - 1];
    acc.output_index = output_index;
    if (stringField(item.object, "call_id") orelse stringField(item.object, "id")) |id| {
        try acc.id.appendSlice(alloc, id);
    }
    if (stringField(item.object, "name")) |name| {
        try acc.name.appendSlice(alloc, name);
        acc.started = true;
        if (callbacks.on_tool_start) |callback| {
            callback(callbacks.ctx, acc.id.items, acc.name.items, null);
        }
    }
    if (stringField(item.object, "arguments")) |arguments| {
        if (arguments.len > 0) {
            try acc.arguments.appendSlice(alloc, arguments);
            if (callbacks.on_tool_input_chunk) |callback| callback(callbacks.ctx, arguments);
        }
    }
}

fn consumeFunctionArgumentsDelta(
    alloc: Allocator,
    root: std.json.ObjectMap,
    tools: *std.ArrayList(ToolAccumulator),
    callbacks: ParseCallbacks,
) !void {
    const delta = stringField(root, "delta") orelse return;
    if (delta.len == 0) return;
    const output_index = jsonIndex(root.get("output_index"));
    const acc = findTool(tools, output_index) orelse blk: {
        try tools.append(alloc, .{ .output_index = output_index });
        break :blk &tools.items[tools.items.len - 1];
    };
    try acc.arguments.appendSlice(alloc, delta);
    if (callbacks.on_tool_input_chunk) |callback| callback(callbacks.ctx, delta);
}

fn findTool(tools: *std.ArrayList(ToolAccumulator), output_index: ?usize) ?*ToolAccumulator {
    if (output_index) |index| {
        for (tools.items) |*acc| {
            if (acc.output_index == index) return acc;
        }
    }
    if (tools.items.len == 0) return null;
    return &tools.items[tools.items.len - 1];
}

fn hasTools(tools: *const std.ArrayList(ToolAccumulator)) bool {
    return tools.items.len > 0;
}

fn appendTextDelta(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    delta: ?[]const u8,
    content_capture_limit: ?usize,
    on_content_chunk: ?StreamCallback,
    ctx: *anyopaque,
) !void {
    const text = delta orelse return;
    if (text.len == 0) return;
    const retained = if (content_capture_limit) |limit|
        text[0..@min(text.len, limit -| content.items.len)]
    else
        text;
    try content.appendSlice(alloc, retained);
    if (on_content_chunk) |callback| callback(ctx, text);
}

fn applyUsage(usage: *types.Usage, value: std.json.Value) void {
    if (value != .object) return;
    if (tokenTotal(value, "input_tokens") orelse tokenTotal(value, "prompt_tokens")) |count| {
        usage.input_tokens = count;
    }
    if (tokenTotal(value, "output_tokens") orelse tokenTotal(value, "completion_tokens")) |count| {
        usage.output_tokens = count;
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
    var reason = finish_reason;
    if (tool_calls.len > 0 and (reason == null or reason == .stop)) reason = .tool_calls;
    return .{
        .content = content_text,
        .tool_calls = tool_calls,
        .finish_reason = reason,
        .usage = usage,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonIndex(value: ?std.json.Value) ?usize {
    const index = value orelse return null;
    return switch (index) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
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

pub fn streamResponses(
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

    var extra_headers_buf: [4]std.http.Header = undefined;
    var extra_len: usize = 0;
    extra_headers_buf[extra_len] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
    extra_len += 1;
    extra_headers_buf[extra_len] = .{ .name = "originator", .value = "fx" };
    extra_len += 1;
    if (request.account_id) |account_id| {
        extra_headers_buf[extra_len] = .{ .name = "ChatGPT-Account-ID", .value = account_id };
        extra_len += 1;
    }

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
            .extra_headers = extra_headers_buf[0..extra_len],
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
            .on_reasoning_chunk = request.on_reasoning_chunk,
        });
        return .{
            .status = .ok,
            .completion = completion,
        };
    }
    return error.ReadFailed;
}

test "responses builder emits input tools and no gateway prompt field" {
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
    const body = try buildResponsesBody(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 128,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.6-sol\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"be brief\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"inputSchema\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"prompt\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "text-delta") == null);
    try std.testing.expect(std.mem.find(u8, body, "chat/completions") == null);
}

test "responses parser streams content tool calls and usage" {
    const Capture = struct {
        chunks: std.ArrayList(u8) = .empty,
        tool_name: ?[]const u8 = null,

        fn onContent(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.chunks.appendSlice(std.testing.allocator, chunk) catch {};
        }

        fn onToolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_name = std.testing.allocator.dupe(u8, name) catch null;
        }
    };
    var capture: Capture = .{};
    defer capture.chunks.deinit(std.testing.allocator);
    defer if (capture.tool_name) |name| std.testing.allocator.free(name);

    const sse =
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n" ++
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\" world\"}\n\n" ++
        "event: response.output_item.added\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"\"}}\n\n" ++
        "event: response.function_call_arguments.delta\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"path\\\":\\\"a\\\"}\"}\n\n" ++
        "event: response.completed\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":9,\"output_tokens\":4}}}\n\n";
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
    try std.testing.expectEqualStrings("read_file", capture.tool_name.?);
}

test "responses parser accepts data-only events without event lines" {
    const sse =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n";
    const completion = try parseSseBytes(std.testing.allocator, sse, null, .{
        .ctx = undefined,
    });
    defer if (completion.content) |content| std.testing.allocator.free(@constCast(content));
    try std.testing.expectEqualStrings("ok", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
}
