const std = @import("std");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");

const Allocator = std.mem.Allocator;
const default_base_url = "https://api.anthropic.com";
pub const base_url_env = "FX_ANTHROPIC_BASE_URL";
pub const anthropic_version = "2023-06-01";
const default_max_tokens: u32 = 8192;
const max_thinking_budget_tokens: u32 = 32_000;
const min_thinking_budget_tokens: u32 = 1024;
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;
pub const e2e_endpoint_env = "FX_E2E_ANTHROPIC_URL";

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
};

pub fn resolveBaseUrl() []const u8 {
    const raw = io_mod.getenv(base_url_env) orelse return default_base_url;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_base_url;
    return trimmed;
}

fn messagesUrl(alloc: Allocator) ![]u8 {
    const base = std.mem.trimEnd(u8, resolveBaseUrl(), "/");
    if (std.mem.endsWith(u8, base, "/v1/messages")) return alloc.dupe(u8, base);
    return std.fmt.allocPrint(alloc, "{s}/v1/messages", .{base});
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidAnthropicModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidAnthropicModel;
    }
}

pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var system: std.Io.Writer.Allocating = .init(alloc);
    defer system.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (system.written().len > 0) try system.writer.writeAll("\n\n");
        try system.writer.writeAll(text);
    }

    const max_tokens: u32 = request.max_output_tokens orelse default_max_tokens;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.print(",\"max_tokens\":{d}", .{max_tokens});
    if (system.written().len > 0) {
        try writer.writeAll(",\"system\":");
        try std.json.Stringify.value(system.written(), .{}, writer);
    }
    try writer.writeAll(",\"stream\":true,\"messages\":[");
    try writeMessages(writer, request.messages);
    try writer.writeByte(']');
    const tool_count = try writeTools(writer, alloc, request.tools);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try writeToolChoice(writer, request.tool_choice);
    }
    if (request.provider_options.reasoning) |effort| {
        if (effort != .auto) {
            const budget = @min(
                max_thinking_budget_tokens,
                @max(min_thinking_budget_tokens, max_tokens / 2),
            );
            try writer.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{budget});
        }
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeMessages(writer: *std.Io.Writer, messages: []const types.ChatMessage) !void {
    var first = true;
    for (messages) |message| {
        switch (message.role) {
            .system => continue,
            .user => {
                if (message.tool_call_id != null) {
                    try writeComma(writer, &first);
                    try writeToolResult(writer, message);
                    continue;
                }
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                };
                try writer.writeAll("]}");
            },
            .assistant => {
                var wrote_any = false;
                if (message.content) |content| if (content.len > 0) {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote_any = true;
                };
                for (message.tool_calls) |call| {
                    if (call.id.len == 0 or call.id.len > max_tool_identity_bytes or
                        call.name.len == 0 or call.name.len > max_tool_identity_bytes or
                        call.arguments_json.len > max_tool_arguments_bytes)
                    {
                        return error.AnthropicToolCallLimitExceeded;
                    }
                    if (wrote_any) {
                        try writer.writeByte(',');
                    } else {
                        try writeComma(writer, &first);
                        try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
                        wrote_any = true;
                    }
                    try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"input\":");
                    if (call.arguments_json.len > 0) {
                        try writer.writeAll(call.arguments_json);
                    } else {
                        try writer.writeAll("{}");
                    }
                    try writer.writeByte('}');
                }
                if (wrote_any) try writer.writeAll("]}");
            },
            .tool => {
                try writeComma(writer, &first);
                try writeToolResult(writer, message);
            },
        }
    }
}

fn writeToolResult(writer: *std.Io.Writer, message: types.ChatMessage) !void {
    try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
    try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
    try writer.writeAll(",\"content\":");
    try std.json.Stringify.value(message.content orelse "", .{}, writer);
    try writer.writeAll("}]}");
}

fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    tools: stream_provider.ToolSelection,
) !usize {
    var count: usize = 0;
    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();
    try tools_out.writer.writeAll(",\"tools\":[");

    const InputSchema = union(enum) {
        static: model_tool_schema.ObjectSchema,
        dynamic: std.json.Value,
    };

    const S = struct {
        fn writeFunctionTool(
            w: *std.Io.Writer,
            a: Allocator,
            name: []const u8,
            description: []const u8,
            input_schema: InputSchema,
        ) !void {
            if (name.len == 0) return error.InvalidToolSchema;
            try w.writeAll("{\"name\":");
            try std.json.Stringify.value(name, .{}, w);
            if (description.len > 0) {
                try w.writeAll(",\"description\":");
                try std.json.Stringify.value(description, .{}, w);
            }
            try w.writeAll(",\"input_schema\":");
            switch (input_schema) {
                .static => |schema| try model_tool_schema.writeObjectSchema(a, w, schema),
                .dynamic => |schema| try std.json.Stringify.value(schema, .{}, w),
            }
            try w.writeByte('}');
        }
        fn containsName(names: []const []const u8, expected: []const u8) bool {
            for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
            return false;
        }
    };

    for (tools.advertised_names) |name| {
        const tool = tools.advertisedFunction(name) orelse continue;
        if (count > 0) try tools_out.writer.writeByte(',');
        try S.writeFunctionTool(&tools_out.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema });
        count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (S.containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try tools_out.writer.writeByte(',');
        try S.writeFunctionTool(&tools_out.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema });
        count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (S.containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try tools_out.writer.writeByte(',');
        try S.writeFunctionTool(&tools_out.writer, alloc, tool.name, tool.description, .{ .dynamic = tool.input_schema });
        count += 1;
    }
    try tools_out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(tools_out.written());
    return count;
}

fn writeToolChoice(writer: *std.Io.Writer, choice: types.ToolChoice) !void {
    switch (choice) {
        .auto => try writer.writeAll("{\"type\":\"auto\"}"),
        .none => try writer.writeAll("{\"type\":\"none\"}"),
        .required => try writer.writeAll("{\"type\":\"any\"}"),
    }
}

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    var result = streamCompletionCore(alloc, request) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (requestDeadlineExpired(request)) return error.Timeout;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return error.Timeout;
    }
    return result;
}

fn requestDeadlineExpired(request: stream_provider.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    api_key: []const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .omit,
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamCompletionCore(alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential.source) |source| {
        if (source != .anthropic_api_key) {
            return error.AnthropicApiKeyCredentialRequired;
        }
    } else {
        return error.AnthropicApiKeyCredentialRequired;
    }
    try validateModel(request.model);
    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);
    const request_endpoint = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EAnthropicEndpoint;
        break :endpoint override;
    } else try messagesUrl(alloc);
    defer if (io_mod.getenv(e2e_endpoint_env) == null) alloc.free(@constCast(request_endpoint));
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [4]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-api-key", .value = request.credential.secret };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "anthropic-version", .value = anthropic_version };
    extra_count += 1;

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .api_key = request.credential.secret,
        .extra_headers = extra_headers_buf[0..extra_count],
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
            connect_deadline = deadline;
        }
    }
    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        if (request.deadline) |deadline|
            try gateway_client.spawnHttpCancelWatcherBounded(
                &cancel_watch_done,
                request.cancel_flag,
                deadline,
                connection.stream_writer.stream,
            )
        else
            try gateway_client.spawnHttpCancelWatcher(
                &cancel_watch_done,
                request.cancel_flag,
                connection.stream_writer.stream,
            )
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Anthropic error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "Anthropic error response exceeded the local limit");
        } else bounded_body;
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .ownership = .owned,
        } };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    const completion = try consumeSse(
        alloc,
        reader,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        EventBridge.toolInput,
        request.cancel_flag,
        request.content_capture_limit,
    );
    return .{ .completed = .{
        .completion = completion,
        .ownership = .owned,
    } };
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

const ToolAccumulator = struct {
    block_index: i64,
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,

    const Line = struct {
        bytes: []const u8,
        wire_bytes: usize,
    };

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    /// Returns the next `data:` payload, or null at stream end.
    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate_bytes = try checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            );
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (data.len == 0) {
                self.release();
                continue;
            }
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.AnthropicSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.AnthropicSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) {
                    return .{
                        .bytes = self.pending_line.items,
                        .wire_bytes = self.pending_line.items.len,
                    };
                }
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.AnthropicSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) {
                return .{
                    .bytes = fragment,
                    .wire_bytes = fragment.len + 1,
                };
            }
            try self.pending_line.appendSlice(alloc, fragment);
            return .{
                .bytes = self.pending_line.items,
                .wire_bytes = self.pending_line.items.len + 1,
            };
        }
    }
};

fn consumeSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.ModelCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var message_started = false;
    var message_stopped = false;
    var saw_error = false;

    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        _ = try checkedAccumulatedSize(0, 1, max_sse_events);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidAnthropicSseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const event_type = stringField(object, "type") orelse continue;

        if (std.mem.eql(u8, event_type, "message_start")) {
            message_started = true;
            if (object.get("message")) |message| if (message == .object) {
                if (stringField(message.object, "id")) |id| {
                    generation_id = try alloc.dupe(u8, id);
                }
                if (message.object.get("usage")) |usage_value| {
                    if (usage_value == .object) {
                        usage.input_tokens = unsignedField(usage_value.object, "input_tokens");
                    }
                }
            };
        } else if (std.mem.eql(u8, event_type, "content_block_start")) {
            const index = integerField(object, "index") orelse continue;
            const block = object.get("content_block") orelse continue;
            if (block != .object) continue;
            const block_type = stringField(block.object, "type") orelse continue;
            if (std.mem.eql(u8, block_type, "tool_use")) {
                const call_id = stringField(block.object, "id") orelse continue;
                const name = stringField(block.object, "name") orelse continue;
                if (findTool(tools.items, index) == null) {
                    try appendTool(alloc, &tools, index, call_id, name);
                    if (on_tool_start) |callback| callback(callback_ctx, call_id, name, null);
                }
            }
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const index = integerField(object, "index") orelse continue;
            const delta = object.get("delta") orelse continue;
            if (delta != .object) continue;
            const delta_type = stringField(delta.object, "type") orelse continue;
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                const text = stringField(delta.object, "text") orelse continue;
                on_content_chunk(callback_ctx, text);
                try appendCaptured(alloc, &content, text, content_capture_limit);
            } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                const text = stringField(delta.object, "thinking") orelse continue;
                if (on_reasoning_chunk) |callback| callback(callback_ctx, text);
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const partial = stringField(delta.object, "partial_json") orelse continue;
                const tool_index = findTool(tools.items, index) orelse continue;
                try appendToolArguments(alloc, &tools.items[tool_index].arguments, partial);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, partial);
            }
        } else if (std.mem.eql(u8, event_type, "content_block_stop") or
            std.mem.eql(u8, event_type, "ping"))
        {
            // No state to finalize per block; tool arguments accumulate by index.
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            if (object.get("delta")) |delta| if (delta == .object) {
                if (stringField(delta.object, "stop_reason")) |reason| {
                    finish_reason = stopReason(reason, tools.items.len > 0);
                }
            };
            if (object.get("usage")) |usage_value| if (usage_value == .object) {
                usage.output_tokens = unsignedField(usage_value.object, "output_tokens");
            };
        } else if (std.mem.eql(u8, event_type, "message_stop")) {
            message_stopped = true;
            break;
        } else if (std.mem.eql(u8, event_type, "error")) {
            saw_error = true;
            break;
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (saw_error) return error.AnthropicResponseFailed;
    if (!message_started or !message_stopped) return error.AnthropicStreamIncomplete;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = if (tools.items.len > 0)
        try alloc.alloc(types.ToolCall, tools.items.len)
    else
        &.{};
    errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
    var initialized: usize = 0;
    errdefer for (owned_tools[0..initialized]) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
    };
    for (tools.items, 0..) |*tool, index| {
        const arguments = if (tool.arguments.items.len > 0)
            try tool.arguments.toOwnedSlice(alloc)
        else
            try alloc.dupe(u8, "{}");
        tool.arguments = .empty;
        owned_tools[index] = .{
            .id = tool.id,
            .name = tool.name,
            .arguments_json = arguments,
        };
        tool.id = &.{};
        tool.name = &.{};
        initialized += 1;
    }
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .finish_reason = finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
        .usage = usage,
    };
}

fn stopReason(raw: []const u8, has_tools: bool) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "end_turn") or std.mem.eql(u8, raw, "stop_sequence")) {
        return if (has_tools) .tool_calls else .stop;
    }
    if (std.mem.eql(u8, raw, "max_tokens")) return .length;
    if (std.mem.eql(u8, raw, "refusal")) return .content_filter;
    if (std.mem.eql(u8, raw, "pause_turn")) return .other;
    return if (has_tools) .tool_calls else .stop;
}

fn appendTool(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    block_index: i64,
    call_id: []const u8,
    name: []const u8,
) !void {
    if (tools.items.len >= max_tool_calls or call_id.len == 0 or call_id.len > max_tool_identity_bytes or
        name.len == 0 or name.len > max_tool_identity_bytes)
    {
        return error.AnthropicToolCallLimitExceeded;
    }
    const id = try alloc.dupe(u8, call_id);
    errdefer alloc.free(id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try tools.append(alloc, .{
        .block_index = block_index,
        .id = id,
        .name = owned_name,
    });
}

fn appendToolArguments(
    alloc: Allocator,
    arguments: *std.ArrayList(u8),
    delta: []const u8,
) !void {
    _ = checkedAccumulatedSize(arguments.items.len, delta.len, max_tool_arguments_bytes) catch
        return error.AnthropicToolArgumentsTooLarge;
    try arguments.appendSlice(alloc, delta);
}

fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.AnthropicResourceLimitExceeded;
    if (next > maximum) return error.AnthropicResourceLimitExceeded;
    return next;
}

fn appendCaptured(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    limit: ?usize,
) !void {
    const remaining = if (limit) |maximum| maximum -| @min(maximum, content.items.len) else delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn findTool(tools: []const ToolAccumulator, block_index: i64) ?usize {
    for (tools, 0..) |tool, index| if (tool.block_index == block_index) return index;
    return null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = integerField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

test "Anthropic request hoists system text and maps messages and tools" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try buildRequest(std.testing.allocator, .{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{.{ .name = "read_file", .description = "Read" }} },
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 4096,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"claude-sonnet-4-5\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"Be concise.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"read_file\",\"input\":{\"path\":\"README.md\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"tool_result\",\"tool_use_id\":\"call_1\",\"content\":\"contents\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input_schema\":{\"type\":\"object\",\"properties\":{}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":{\"type\":\"auto\"}") != null);
}

test "Anthropic request applies default max tokens and maps tool choice variants" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .tool_choice = .required,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);

    const none_body = try buildRequest(std.testing.allocator, .{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(none_body);
    try std.testing.expect(std.mem.indexOf(u8, none_body, "\"tool_choice\"") == null);
}

test "Anthropic SSE maps text tool arguments stop reason and usage" {
    const sse_text =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":10}}}\n\n" ++
        "event: ping\n" ++
        "data: {\"type\":\"ping\"}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"read_file\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":4}}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        saw_read_file: bool = false,

        fn contentChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.saw_read_file = std.mem.eql(u8, name, "read_file");
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        &capture,
        Capture.contentChunk,
        Capture.toolStart,
        null,
        null,
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
        if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expect(capture.saw_read_file);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), completion.usage.output_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqualStrings("msg_1", completion.generation_id.?);
}

test "Anthropic SSE maps stop reasons and surfaces error events" {
    const cases = [_]struct { raw: []const u8, expected: types.ProviderFinishReason }{
        .{ .raw = "end_turn", .expected = .stop },
        .{ .raw = "stop_sequence", .expected = .stop },
        .{ .raw = "max_tokens", .expected = .length },
        .{ .raw = "refusal", .expected = .content_filter },
        .{ .raw = "pause_turn", .expected = .other },
    };
    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        const sse_text = try std.fmt.bufPrint(
            &buffer,
            "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m\"}}}}\n\n" ++
                "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}}}}\n\n" ++
                "data: {{\"type\":\"message_stop\"}}\n\n",
            .{case.raw},
        );
        var reader: std.Io.Reader = .fixed(sse_text);
        var cancelled = std.atomic.Value(bool).init(false);
        var callback_context: u8 = 0;
        var completion = try consumeSse(
            std.testing.allocator,
            &reader,
            &callback_context,
            ignoreTestChunk,
            null,
            null,
            null,
            &cancelled,
            null,
        );
        defer deinitTestCompletion(&completion);
        try std.testing.expectEqual(case.expected, completion.finish_reason.?);
    }

    const error_stream = "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"overloaded\"}}\n\n";
    var error_reader: std.Io.Reader = .fixed(error_stream);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.AnthropicResponseFailed,
        consumeSse(
            std.testing.allocator,
            &error_reader,
            &callback_context,
            ignoreTestChunk,
            null,
            null,
            null,
            &cancelled,
            null,
        ),
    );

    const truncated_stream = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n\n";
    var truncated_reader: std.Io.Reader = .fixed(truncated_stream);
    try std.testing.expectError(
        error.AnthropicStreamIncomplete,
        consumeSse(
            std.testing.allocator,
            &truncated_reader,
            &callback_context,
            ignoreTestChunk,
            null,
            null,
            null,
            &cancelled,
            null,
        ),
    );
}

fn ignoreTestChunk(_: *anyopaque, _: []const u8) void {}

fn deinitTestCompletion(completion: *types.ModelCompletion) void {
    if (completion.content) |value| std.testing.allocator.free(@constCast(value));
    if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
    types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
    completion.* = .{};
}

test "Anthropic default endpoint composes the Messages path" {
    const stable = try stableAnthropicTestEnviron();
    io_mod.setEnvironMap(stable);
    const url = try messagesUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "Anthropic base URL env resolves custom hosts" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put(base_url_env, "https://proxy.example/anthropic/");
    const stable = try stableAnthropicTestEnviron();
    io_mod.setEnvironMap(&map);
    defer io_mod.setEnvironMap(stable);

    try std.testing.expectEqualStrings("https://proxy.example/anthropic/", resolveBaseUrl());
    const url = try messagesUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://proxy.example/anthropic/v1/messages", url);
}

var stable_anthropic_test_environ: ?*std.process.Environ.Map = null;

fn stableAnthropicTestEnviron() !*const std.process.Environ.Map {
    if (stable_anthropic_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_anthropic_test_environ = map;
    return map;
}
