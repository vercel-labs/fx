const std = @import("std");
const gateway_json = @import("../core/gateway/gateway_json.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const openai_transport = @import("../core/gateway/openai_transport.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const StreamCallback = gateway_client.StreamCallback;
const ToolStartCallback = gateway_client.ToolStartCallback;
const StreamResult = gateway_client.StreamResult;
const DeliveryCertainty = gateway_client.DeliveryCertainty;

pub const user_agent = gateway_client.user_agent;
const max_sse_event_line_bytes: usize = 4 * 1024 * 1024;

pub const StreamRequest = struct {
    api_key: []const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    trace_ctx: debug_trace.TraceContext = .{},
    content_capture_limit: ?usize = null,
    delivery: ?*DeliveryCertainty = null,
    on_tool_input_chunk: ?StreamCallback = null,
    provider_attempt_owner: gateway_client.ProviderAttemptOwner = .transport,
};

const SseEvent = union(enum) {
    data: []const u8,
    done,
    ignored,
    read_failed,
    eof,
};

const SseEventReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    max_line_bytes: usize,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn releaseLine(self: *@This()) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *@This(), alloc: Allocator, reader: anytype) !SseEvent {
        const line = switch (try self.readLine(alloc, reader)) {
            .line => |value| value,
            .read_failed => return .read_failed,
            .eof => return .eof,
        };

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) return .ignored;
        if (trimmed[0] == ':') return .ignored;
        const data_prefix = "data: ";
        if (!std.mem.startsWith(u8, trimmed, data_prefix)) return .ignored;
        const json_text = trimmed[data_prefix.len..];
        if (std.mem.eql(u8, json_text, "[DONE]")) return .done;
        return .{ .data = json_text };
    }

    fn readLine(self: *@This(), alloc: Allocator, reader: anytype) !union(enum) {
        line: []const u8,
        read_failed,
        eof,
    } {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.GatewaySseReadStalled;
                    if (buffered.len > self.max_line_bytes - self.pending_line.items.len) {
                        return error.GatewaySseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return .read_failed,
            } orelse {
                if (self.pending_line.items.len > 0) return .{ .line = self.pending_line.items };
                return .eof;
            };

            if (fragment.len > self.max_line_bytes - self.pending_line.items.len) {
                return error.GatewaySseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return .{ .line = fragment };
            try self.pending_line.appendSlice(alloc, fragment);
            return .{ .line = self.pending_line.items };
        }
    }
};

const StreamedToolCall = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

fn dupeStreamedToolCall(alloc: Allocator, tool: StreamedToolCall) !types.ToolCall {
    const args = if (tool.arguments.items.len == 0) "{}" else tool.arguments.items;
    if (try types.ToolArgumentIntegrity.classifySerialized(alloc, args) == .malformed_json) {
        return error.InvalidGatewayResponse;
    }
    const id = try alloc.dupe(u8, tool.id.items);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, tool.name.items);
    errdefer alloc.free(name);
    const arguments_json = try alloc.dupe(u8, args);
    errdefer alloc.free(arguments_json);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
    };
}

pub fn streamOpenAiCompletion(
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
        .transport => request.retry_count,
    };

    const request_url = selectE2eChatUrl(io_mod.getenv(openai_transport.e2e_openai_chat_url_env), request.chat_url);
    const uri = try std.Uri.parse(request_url);

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer alloc.free(auth_header);

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
                .user_agent = .{ .override = user_agent },
            },
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) catch |err| {
            if (attempt + 1 < retry_count and gateway_client.isRetryableGatewayError(err)) {
                try sleepRetry((attempt + 1) * 150 * std.time.ns_per_ms, cancel_flag);
                continue;
            }
            return err;
        };
        defer req.deinit();

        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        req.transfer_encoding = .{ .content_length = request.payload.len };
        var send_buf: [8192]u8 = undefined;
        var body_writer = req.sendBodyUnflushed(&send_buf) catch return error.WriteFailed;
        body_writer.writer.writeAll(request.payload) catch return error.WriteFailed;
        body_writer.end() catch return error.WriteFailed;
        req.connection.?.flush() catch return error.WriteFailed;
        if (request.delivery) |delivery| delivery.markPossiblySent();

        var response = req.receiveHead(&.{}) catch |err| {
            if (attempt + 1 < retry_count and gateway_client.isRetryableGatewayError(err)) {
                try sleepRetry((attempt + 1) * 150 * std.time.ns_per_ms, cancel_flag);
                continue;
            }
            return err;
        };

        if (response.head.status != .ok) {
            const err_body = try readResponseBody(alloc, &response);
            return .{
                .status = response.head.status,
                .err_body = err_body,
            };
        }

        return consumeOpenAiSseStream(
            alloc,
            &response,
            callback_ctx,
            on_content_chunk,
            on_tool_start,
            request.on_tool_input_chunk,
            cancel_flag,
            request.content_capture_limit,
        );
    }

    return error.ConnectionTimedOut;
}

fn selectE2eChatUrl(override_url: ?[]const u8, default_url: []const u8) []const u8 {
    const override = override_url orelse return default_url;
    if (!gateway_client.isLoopbackHttpUrl(override)) return default_url;
    return override;
}

fn sleepRetry(ns: u64, cancel_flag: *std.atomic.Value(bool)) !void {
    const step = 50 * std.time.ns_per_ms;
    var waited: u64 = 0;
    while (waited < ns) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        io_mod.sleep(step);
        waited += step;
    }
}

fn readResponseBody(alloc: Allocator, response: *std.http.Client.Response) ![]u8 {
    var err_out: std.Io.Writer.Allocating = .init(alloc);
    defer err_out.deinit();
    var err_buf: [4096]u8 = undefined;
    const err_reader = response.reader(&err_buf);
    _ = err_reader.streamRemaining(&err_out.writer) catch {};
    return err_out.toOwnedSlice() catch try alloc.dupe(u8, "");
}

fn consumeOpenAiSseStream(
    alloc: Allocator,
    response: *std.http.Client.Response,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_tool_input_chunk: ?StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !StreamResult {
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(alloc);

    var streamed_tools: std.ArrayList(StreamedToolCall) = .empty;
    defer {
        for (streamed_tools.items) |*tool| tool.deinit(alloc);
        streamed_tools.deinit(alloc);
    }

    var finish_reason: ?types.ProviderFinishReason = null;

    var reader_buffer: [8192]u8 = undefined;
    const reader = response.reader(&reader_buffer);

    var event_reader = SseEventReader{ .max_line_bytes = max_sse_event_line_bytes };
    defer event_reader.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const event = try event_reader.next(alloc, reader);
        defer event_reader.releaseLine();

        switch (event) {
            .data => |json_text| {
                try handleOpenAiChunk(
                    alloc,
                    json_text,
                    &content_buf,
                    &streamed_tools,
                    &finish_reason,
                    callback_ctx,
                    on_content_chunk,
                    on_tool_start,
                    on_tool_input_chunk,
                    content_capture_limit,
                );
            },
            .done => break,
            .ignored => continue,
            .read_failed => {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                return error.ReadFailed;
            },
            .eof => break,
        }
    }

    if (finish_reason == null) {
        if (streamed_tools.items.len > 0) {
            finish_reason = .tool_calls;
        } else if (content_buf.items.len > 0) {
            finish_reason = .stop;
        }
    }

    var completion: types.GatewayCompletion = .{};
    errdefer gateway_json.freeGatewayCompletion(alloc, completion);
    if (content_buf.items.len > 0) {
        completion.content = try alloc.dupe(u8, content_buf.items);
    }
    if (finish_reason) |reason| completion.finish_reason = reason;

    if (streamed_tools.items.len > 0) {
        const buffer = try alloc.alloc(types.ToolCall, streamed_tools.items.len);
        errdefer alloc.free(buffer);
        var count: usize = 0;
        errdefer {
            for (buffer[0..count]) |call| {
                alloc.free(call.id);
                alloc.free(call.name);
                alloc.free(call.arguments_json);
            }
        }
        for (streamed_tools.items) |tool| {
            if (tool.id.items.len == 0 or tool.name.items.len == 0) continue;
            buffer[count] = try dupeStreamedToolCall(alloc, tool);
            count += 1;
        }
        if (count > 0) {
            completion.tool_calls = try alloc.dupe(types.ToolCall, buffer[0..count]);
        }
        alloc.free(buffer);
    }

    normalizeOpenAiToolFinishReason(&completion);

    return .{ .status = .ok, .completion = completion };
}

fn normalizeOpenAiToolFinishReason(completion: *types.GatewayCompletion) void {
    if (completion.tool_calls.len == 0) return;
    if (types.allToolCallsProviderExecuted(completion.tool_calls)) return;
    const reason = completion.finish_reason orelse {
        completion.finish_reason = .tool_calls;
        return;
    };
    switch (reason) {
        .stop, .other => completion.finish_reason = .tool_calls,
        else => {},
    }
}

fn validatedStreamedToolIndex(index_value: std.json.Value) ?usize {
    if (index_value != .integer) return null;
    if (index_value.integer < 0) return null;
    const index = std.math.cast(usize, index_value.integer) orelse return null;
    if (index > openai_transport.max_streamed_tool_index) return null;
    return index;
}

fn handleOpenAiChunk(
    alloc: Allocator,
    json_text: []const u8,
    content_buf: *std.ArrayList(u8),
    streamed_tools: *std.ArrayList(StreamedToolCall),
    finish_reason: *?types.ProviderFinishReason,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_tool_input_chunk: ?StreamCallback,
    content_capture_limit: ?usize,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const choices = parsed.value.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;

    if (choice.object.get("finish_reason")) |reason_value| {
        if (reason_value == .string and reason_value.string.len > 0) {
            finish_reason.* = types.ProviderFinishReason.parse_legacy(reason_value.string);
        }
    }

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("content")) |content_value| {
        if (content_value == .string and content_value.string.len > 0) {
            const retained = if (content_capture_limit) |limit|
                content_value.string[0..@min(content_value.string.len, limit -| content_buf.items.len)]
            else
                content_value.string;
            try content_buf.appendSlice(alloc, retained);
            on_content_chunk(callback_ctx, content_value.string);
        }
    }

    const tool_calls = delta.object.get("tool_calls") orelse return;
    if (tool_calls != .array) return;

    for (tool_calls.array.items) |tool_call| {
        if (tool_call != .object) continue;
        const index_value = tool_call.object.get("index") orelse continue;
        const index = validatedStreamedToolIndex(index_value) orelse return error.InvalidGatewayResponse;
        while (streamed_tools.items.len <= index) {
            try streamed_tools.append(alloc, .{});
        }
        const record = &streamed_tools.items[index];

        if (tool_call.object.get("id")) |id_value| {
            if (id_value == .string and id_value.string.len > 0) {
                record.id.clearRetainingCapacity();
                try record.id.appendSlice(alloc, id_value.string);
            }
        }

        const function = tool_call.object.get("function") orelse continue;
        if (function != .object) continue;

        if (function.object.get("name")) |name_value| {
            if (name_value == .string and name_value.string.len > 0) {
                record.name.clearRetainingCapacity();
                try record.name.appendSlice(alloc, name_value.string);
                if (!record.announced and record.id.items.len > 0) {
                    record.announced = true;
                    if (on_tool_start) |callback| {
                        callback(callback_ctx, record.id.items, record.name.items, null);
                    }
                }
            }
        }

        if (function.object.get("arguments")) |args_value| {
            if (args_value == .string and args_value.string.len > 0) {
                try record.arguments.appendSlice(alloc, args_value.string);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, args_value.string);
            }
        }
    }
}

test "handleOpenAiChunk accumulates streamed tool call fragments" {
    const alloc = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var tools: std.ArrayList(StreamedToolCall) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var finish: ?types.ProviderFinishReason = null;
    var announced: usize = 0;

    const chunk1 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"path"}}]}}]}
    ;
    try handleOpenAiChunk(
        alloc,
        chunk1,
        &content,
        &tools,
        &finish,
        @ptrCast(&announced),
        discardChunk,
        toolStartCounter,
        discardChunk,
        null,
    );

    const chunk2 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":\"/tmp\"}"}}]}}]}
    ;
    try handleOpenAiChunk(
        alloc,
        chunk2,
        &content,
        &tools,
        &finish,
        @ptrCast(&announced),
        discardChunk,
        toolStartCounter,
        discardChunk,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), announced);
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("call_1", tools.items[0].id.items);
    try std.testing.expectEqualStrings("read_file", tools.items[0].name.items);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", tools.items[0].arguments.items);
}

test "normalizeOpenAiToolFinishReason upgrades stop finish to tool_calls" {
    const call = types.ToolCall{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{}",
    };
    var completion = types.GatewayCompletion{
        .finish_reason = .stop,
        .tool_calls = &.{call},
    };
    normalizeOpenAiToolFinishReason(&completion);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(
        types.ProviderCompletionDisposition.completed,
        types.classifyProviderCompletion(completion),
    );
}

test "normalizeOpenAiToolFinishReason preserves provider-executed stop completions" {
    const call = types.ToolCall{
        .id = "search",
        .name = "perplexity_search",
        .arguments_json = "{}",
        .provenance = .provider_executed,
    };
    var completion = types.GatewayCompletion{
        .finish_reason = .stop,
        .tool_calls = &.{call},
    };
    normalizeOpenAiToolFinishReason(&completion);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
}

test "normalizeOpenAiToolFinishReason upgrades stop when mixed with local tools" {
    const calls = [_]types.ToolCall{
        .{
            .id = "search",
            .name = "perplexity_search",
            .arguments_json = "{}",
            .provenance = .provider_executed,
        },
        .{ .id = "call_1", .name = "read_file", .arguments_json = "{}" },
    };
    var completion = types.GatewayCompletion{
        .finish_reason = .stop,
        .tool_calls = calls[0..],
    };
    normalizeOpenAiToolFinishReason(&completion);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

var announced_slot: usize = 0;

fn discardChunk(_: *anyopaque, _: []const u8) void {}

fn toolStartCounter(ctx: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) void {
    const slot: *usize = @ptrCast(@alignCast(ctx));
    slot.* += 1;
}

test "parseGatewayCompletion accepts OpenAI non-stream body" {
    const body =
        \\{"choices":[{"finish_reason":"stop","message":{"content":"hello"}}]}
    ;
    const completion = try gateway_json.parseGatewayCompletion(std.testing.allocator, body);
    defer gateway_json.freeGatewayCompletion(std.testing.allocator, completion);
    try std.testing.expectEqualStrings("hello", completion.content.?);
}
