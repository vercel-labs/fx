const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const opencode_session = @import("../core/auth/opencode_session.zig");
const opencode_models = @import("opencode_models.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const endpoint_zen = "https://opencode.ai/zen/v1/chat/completions";
const generation_origin_zen = "https://opencode.ai/zen/v1";
const endpoint_go = "https://opencode.ai/zen/go/v1/chat/completions";
const generation_origin_go = "https://opencode.ai/zen/go/v1";
const go_model_prefix = "go/";
const e2e_endpoint_env = "FX_E2E_OPENCODE_CHAT_URL";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

const Route = struct {
    endpoint: []const u8,
    generation_origin: []const u8,
    wire_model: []const u8,
};

fn route(model: []const u8) Route {
    if (std.mem.startsWith(u8, model, go_model_prefix)) {
        return .{
            .endpoint = endpoint_go,
            .generation_origin = generation_origin_go,
            .wire_model = model[go_model_prefix.len..],
        };
    }
    return .{
        .endpoint = endpoint_zen,
        .generation_origin = generation_origin_zen,
        .wire_model = model,
    };
}

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = buildRequest,
    .stream_fn = streamCompletion,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidOpenCodeModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenCodeModel;
    }
    const wire_model = route(model).wire_model;
    if (wire_model.len == 0) return error.InvalidOpenCodeModel;
    if (!opencode_models.supportsChatCompletionsModel(model)) return error.UnsupportedOpenCodeModelProtocol;
}

fn buildRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    const wire_model = route(request.model).wire_model;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(wire_model, .{}, writer);
    try writer.writeAll(",\"messages\":[");
    try writeMessages(writer, alloc, request.messages, request.verified_images);
    try writer.writeAll("],\"stream\":true,\"stream_options\":{\"include_usage\":true}");

    const tool_count = try writeTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
        try writer.writeAll(",\"parallel_tool_calls\":true");
    }

    if (request.response_format) |format| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }

    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeMessages(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    var last_user_index: ?usize = null;
    for (messages, 0..) |message, index| {
        if (message.role == .user) last_user_index = index;
    }
    for (messages, 0..) |message, index| {
        const has_images = verified_images != null and verified_images.?.len > 0 and
            message.role == .user and index == last_user_index;
        const has_content = message.content != null and message.content.?.len > 0;
        if (!has_content and !has_images and message.role != .assistant) continue;
        if (first) {
            first = false;
        } else {
            try writer.writeByte(',');
        }
        switch (message.role) {
            .system => {
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                if (has_images) {
                    try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                    try writer.writeByte('}');
                    for (verified_images.?) |image| {
                        try writer.writeAll(",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                        try writer.writeAll(image.media_type);
                        try writer.writeAll(";base64,");
                        try writeBase64(writer, alloc, image.bytes);
                        try writer.writeAll("\"}}");
                    }
                    try writer.writeAll("]}");
                } else {
                    try writer.writeAll("{\"role\":\"user\",\"content\":");
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                    try writer.writeByte('}');
                }
            },
            .assistant => {
                try writer.writeAll("{\"role\":\"assistant\"");
                if (has_content) {
                    try writer.writeAll(",\"content\":");
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                } else if (message.tool_calls.len == 0) {
                    try writer.writeAll(",\"content\":\"\"");
                } else {
                    try writer.writeAll(",\"content\":null");
                }
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    var tool_first = true;
                    for (message.tool_calls) |call| {
                        if (call.id.len == 0 or call.id.len > max_tool_identity_bytes or
                            call.name.len == 0 or call.name.len > max_tool_identity_bytes or
                            call.arguments_json.len > max_tool_arguments_bytes)
                        {
                            return error.InvalidOpenCodeToolCall;
                        }
                        if (tool_first) {
                            tool_first = false;
                        } else {
                            try writer.writeByte(',');
                        }
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
                try writer.writeByte('}');
            },
            .tool => {
                const tool_call_id = message.tool_call_id orelse return error.InvalidOpenCodeToolCall;
                if (tool_call_id.len == 0 or tool_call_id.len > max_tool_identity_bytes) {
                    return error.InvalidOpenCodeToolCall;
                }
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(tool_call_id, .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeBase64(writer: *std.Io.Writer, alloc: Allocator, bytes: []const u8) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    try writer.writeAll(encoded);
}

fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    serialized_tools: []const u8,
    selected_dynamic_schemas: []const []const u8,
) !usize {
    var count: usize = 0;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    defer parsed.deinit();
    if (parsed.value == .null) return 0;

    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();
    if (parsed.value != .array) return error.InvalidToolSchema;
    try tools_out.writer.writeAll(",\"tools\":[");
    for (parsed.value.array.items) |tool| {
        if (try writeFunctionTool(&tools_out.writer, tool, count != 0)) count += 1;
    }
    for (selected_dynamic_schemas) |schema_json| {
        var selected = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolSchema,
        };
        defer selected.deinit();
        if (try writeFunctionTool(&tools_out.writer, selected.value, count != 0)) count += 1;
    }
    try tools_out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(tools_out.written());
    return count;
}

fn writeFunctionTool(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const kind = value.object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return false;
    const name = value.object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = value.object.get("inputSchema") orelse value.object.get("parameters") orelse return false;
    if (parameters != .object) return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (value.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeAll("}}");
    return true;
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
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

fn requestDeadlineExpired(request: stream_provider.Request) bool {
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
    auth_header: []const u8,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = &[_]std.http.Header{
                .{ .name = "accept", .value = "text/event-stream" },
            },
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamCompletionCore(alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source != .opencode_api_key) {
        return error.OpenCodeApiKeyCredentialRequired;
    }
    try validateModel(request.model);
    if (!opencode_session.validApiKey(request.api_key)) return error.OpenCodeApiKeyCredentialRequired;
    const open_route = route(request.model);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth_header);
    const request_endpoint = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenCodeEndpoint;
        break :endpoint override;
    } else open_route.endpoint;
    const uri = try std.Uri.parse(request_endpoint);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
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

    http_request.transfer_encoding = .{ .content_length = request.payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(request.payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenCode error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "OpenCode error response exceeded the local limit");
        } else bounded_body;
        return .{
            .status = response.head.status,
            .err_body = body,
            .retry_disposition = if (response.head.status == .too_many_requests and isUsageLimitError(body))
                .terminal
            else
                .status_default,
            .ownership = .owned,
        };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const completion = try consumeSse(
        alloc,
        reader,
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.on_reasoning_chunk,
        request.on_tool_input_chunk,
        request.cancel_flag,
        request.content_capture_limit,
    );
    return .{
        .status = .ok,
        .completion = completion,
        .generation_origin = open_route.generation_origin,
        .ownership = .owned,
    };
}

fn isUsageLimitError(detail: []const u8) bool {
    return std.mem.find(u8, detail, "GoUsageLimitError") != null or
        std.mem.find(u8, detail, "FreeUsageLimitError") != null;
}

const ChatToolAccumulator = struct {
    index: i64,
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,
    started: bool = false,

    fn deinit(self: *ChatToolAccumulator, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,
    saw_done: bool = false,

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
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.saw_done = true;
                return null;
            }
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenCodeSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenCodeSseEventTooLarge;
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
                return error.OpenCodeSseEventTooLarge;
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
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ChatToolAccumulator) = .empty;
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
    var event_count: usize = 0;
    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        event_count = try checkedAccumulatedSize(event_count, 1, max_sse_events);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidOpenCodeSseEvent,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (parsed.value.object.get("error") != null) return error.OpenCodeResponseFailed;
        if (generation_id == null) {
            if (stringField(parsed.value.object, "id")) |id| {
                if (id.len > 0 and id.len <= max_tool_identity_bytes) {
                    generation_id = try alloc.dupe(u8, id);
                }
            }
        }
        if (parsed.value.object.get("usage")) |usage_value| {
            usage = parseUsageValue(usage_value);
        }
        const choices = parsed.value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;

        if (choice.object.get("delta")) |delta_value| {
            if (delta_value == .object) {
                if (stringField(delta_value.object, "content")) |delta| {
                    if (delta.len > 0) {
                        on_content_chunk(callback_ctx, delta);
                        try appendCaptured(alloc, &content, delta, content_capture_limit);
                    }
                }
                if (on_reasoning_chunk) |callback| {
                    if (stringField(delta_value.object, "reasoning_content")) |delta| {
                        if (delta.len > 0) callback(callback_ctx, delta);
                    } else if (stringField(delta_value.object, "reasoning")) |delta| {
                        if (delta.len > 0) callback(callback_ctx, delta);
                    }
                }
                if (delta_value.object.get("tool_calls")) |tool_calls_value| {
                    if (tool_calls_value == .array) {
                        for (tool_calls_value.array.items) |call_value| {
                            if (call_value != .object) continue;
                            const index = integerField(call_value.object, "index") orelse continue;
                            var accumulator_index: ?usize = findChatTool(tools.items, index);
                            if (accumulator_index == null) {
                                if (tools.items.len >= max_tool_calls) return error.OpenCodeResourceLimitExceeded;
                                var id: []u8 = try alloc.dupe(u8, "");
                                errdefer alloc.free(id);
                                var name: []u8 = try alloc.dupe(u8, "");
                                errdefer alloc.free(name);
                                if (stringField(call_value.object, "id")) |call_id| {
                                    if (call_id.len > 0 and call_id.len <= max_tool_identity_bytes) {
                                        const replacement = try alloc.dupe(u8, call_id);
                                        alloc.free(id);
                                        id = replacement;
                                    }
                                }
                                if (nestedStringField(call_value.object, "function", "name")) |function_name| {
                                    if (function_name.len > 0 and function_name.len <= max_tool_identity_bytes) {
                                        const replacement = try alloc.dupe(u8, function_name);
                                        alloc.free(name);
                                        name = replacement;
                                    }
                                }
                                try tools.append(alloc, .{
                                    .index = index,
                                    .id = id,
                                    .name = name,
                                });
                                accumulator_index = tools.items.len - 1;
                            } else {
                                const tool = &tools.items[accumulator_index.?];
                                if (tool.id.len == 0) {
                                    if (stringField(call_value.object, "id")) |call_id| {
                                        if (call_id.len > 0 and call_id.len <= max_tool_identity_bytes) {
                                            const replacement = try alloc.dupe(u8, call_id);
                                            alloc.free(tool.id);
                                            tool.id = replacement;
                                        }
                                    }
                                }
                                if (tool.name.len == 0) {
                                    if (nestedStringField(call_value.object, "function", "name")) |function_name| {
                                        if (function_name.len > 0 and function_name.len <= max_tool_identity_bytes) {
                                            const replacement = try alloc.dupe(u8, function_name);
                                            alloc.free(tool.name);
                                            tool.name = replacement;
                                        }
                                    }
                                }
                            }
                            const tool = &tools.items[accumulator_index.?];
                            if (!tool.started and tool.id.len > 0 and tool.name.len > 0) {
                                if (on_tool_start) |callback| callback(callback_ctx, tool.id, tool.name, null);
                                tool.started = true;
                            }
                            if (nestedStringField(call_value.object, "function", "arguments")) |arguments_delta| {
                                if (arguments_delta.len > 0) {
                                    try appendToolArguments(alloc, &tools.items[accumulator_index.?].arguments, arguments_delta);
                                    if (on_tool_input_chunk) |callback| callback(callback_ctx, arguments_delta);
                                }
                            }
                        }
                    }
                }
            }
        }
        if (choice.object.get("finish_reason")) |finish_value| {
            if (finish_value == .string) {
                finish_reason = mapFinishReason(finish_value.string, tools.items.len > 0);
            }
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    // The SseReader consumes the [DONE] sentinel and reports it through
    // `saw_done`; reaching the end of the stream without it means the server
    // closed early.
    if (!sse.saw_done or finish_reason == null) return error.OpenCodeStreamIncomplete;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = if (tools.items.len > 0)
        try alloc.alloc(types.ToolCall, tools.items.len)
    else
        &.{};
    var initialized_tools: usize = 0;
    errdefer {
        for (owned_tools[0..initialized_tools]) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(@constCast(call.arguments_json));
        }
        if (owned_tools.len > 0) alloc.free(owned_tools);
    }
    for (tools.items, 0..) |*tool, index| {
        if (tool.id.len == 0 or tool.name.len == 0) return error.InvalidOpenCodeSseEvent;
        owned_tools[index] = try dupeToolCall(alloc, tool);
        initialized_tools += 1;
    }
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .finish_reason = finish_reason.?,
        .usage = usage,
    };
}

fn mapFinishReason(raw: []const u8, has_tools: bool) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length") or std.mem.eql(u8, raw, "max_tokens")) return .length;
    if (std.mem.eql(u8, raw, "tool_calls") or std.mem.eql(u8, raw, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    return if (has_tools) .tool_calls else .other;
}

fn dupeToolCall(alloc: Allocator, tool: *const ChatToolAccumulator) !types.ToolCall {
    const id = try alloc.dupe(u8, tool.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, tool.name);
    errdefer alloc.free(name);
    const arguments = try alloc.dupe(u8, tool.arguments.items);
    return .{ .id = id, .name = name, .arguments_json = arguments };
}

fn parseUsageValue(value: std.json.Value) types.Usage {
    if (value != .object) return .{};
    return .{
        .input_tokens = unsignedField(value.object, "prompt_tokens"),
        .output_tokens = unsignedField(value.object, "completion_tokens"),
    };
}

fn findChatTool(tools: []ChatToolAccumulator, index: i64) ?usize {
    for (tools, 0..) |*tool, position| {
        if (tool.index == index) return position;
    }
    return null;
}

fn appendCaptured(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    capture_limit: ?usize,
) !void {
    if (capture_limit) |limit| {
        if (content.items.len >= limit) return;
        const remaining = limit - content.items.len;
        const bounded = if (delta.len > remaining) delta[0..remaining] else delta;
        try content.appendSlice(alloc, bounded);
        return;
    }
    try content.appendSlice(alloc, delta);
}

fn appendToolArguments(alloc: Allocator, arguments: *std.ArrayList(u8), delta: []const u8) !void {
    const projected = try checkedAccumulatedSize(arguments.items.len, delta.len, max_tool_arguments_bytes);
    _ = projected;
    try arguments.appendSlice(alloc, delta);
}

fn checkedAccumulatedSize(current: usize, incoming: usize, limit: usize) !usize {
    const total = std.math.add(usize, current, incoming) catch return error.OpenCodeResourceLimitExceeded;
    if (total > limit) return error.OpenCodeResourceLimitExceeded;
    return total;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn nestedStringField(object: std.json.ObjectMap, container_key: []const u8, key: []const u8) ?[]const u8 {
    const container = object.get(container_key) orelse return null;
    if (container != .object) return null;
    return stringField(container.object, key);
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    if (value.integer < 0) return null;
    return @intCast(value.integer);
}

test "route separates zen and go endpoints by model prefix" {
    const zen = route("kimi-k3");
    try std.testing.expectEqualStrings(endpoint_zen, zen.endpoint);
    try std.testing.expectEqualStrings("kimi-k3", zen.wire_model);
    const go = route("go/kimi-k3");
    try std.testing.expectEqualStrings(endpoint_go, go.endpoint);
    try std.testing.expectEqualStrings("kimi-k3", go.wire_model);
    try std.testing.expectEqualStrings("", route("go/").wire_model);
}

test "OpenCode usage-limit error types disable transient retries" {
    try std.testing.expect(isUsageLimitError(
        "{\"error\":{\"type\":\"GoUsageLimitError\"}}",
    ));
    try std.testing.expect(isUsageLimitError(
        "{\"error\":{\"type\":\"FreeUsageLimitError\"}}",
    ));
    try std.testing.expect(!isUsageLimitError(
        "{\"error\":{\"type\":\"RateLimitError\"}}",
    ));
}

test "buildRequest emits chat-completions wire for text conversation" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "be brief" },
        .{ .role = .user, .content = "hello" },
        .{ .role = .assistant, .content = "hi" },
        .{ .role = .user, .content = "bye" },
    };
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "go/kimi-k3",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "{\"model\":\"kimi-k3\",\"messages\":["));
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"system\",\"content\":\"be brief\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"user\",\"content\":\"bye\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true,\"stream_options\":{\"include_usage\":true}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\":") == null);
}

test "buildRequest serializes assistant tool calls and tool results" {
    const calls = [_]types.ToolCall{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "read it" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "contents" },
    };
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "glm-5",
        .serialized_tools = "null",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"contents\"") != null);
}

test "buildRequest converts registry tools into nested OpenAI function form" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "question" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "kimi-k3",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, ",\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"auto\",\"parallel_tool_calls\":true") != null);
}

test "buildRequest rejects empty wire model and oversized model ids" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    const base = stream_provider.BuildRequest{
        .model = "go/",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    };
    try std.testing.expectError(error.InvalidOpenCodeModel, agent_stream_provider.build(std.testing.allocator, base));
    try std.testing.expectError(error.UnsupportedOpenCodeModelProtocol, agent_stream_provider.build(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    }));
    var oversized: [257]u8 = undefined;
    @memset(&oversized, 'a');
    try std.testing.expectError(error.InvalidOpenCodeModel, agent_stream_provider.build(std.testing.allocator, .{
        .model = &oversized,
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    }));
}

test "OpenCode SSE maps text reasoning tool deltas finish reason and usage" {
    const sse_text =
        "data: {\"id\":\"gen_1\",\"choices\":[{\"delta\":{\"content\":\"hello\",\"reasoning_content\":\"thinking\",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]},\"finish_reason\":\"unexpected_tool_finish\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,
        saw_tool: bool = false,

        fn contentChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn reasoningChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reasoning.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.saw_tool = std.mem.eql(u8, id, "call_1") and std.mem.eql(u8, name, "read_file");
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    defer capture.reasoning.deinit(std.testing.allocator);
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        &capture,
        Capture.contentChunk,
        Capture.toolStart,
        Capture.reasoningChunk,
        null,
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expectEqualStrings("thinking", capture.reasoning.items);
    try std.testing.expect(capture.saw_tool);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), completion.usage.output_tokens);
}

fn ignoreTestChunk(_: *anyopaque, _: []const u8) void {}

test "OpenCode SSE requires both finish reason and done sentinel" {
    const sse_text =
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    try std.testing.expectError(error.OpenCodeStreamIncomplete, consumeSse(
        std.testing.allocator,
        &reader,
        &callback_ctx,
        ignoreTestChunk,
        null,
        null,
        null,
        &cancelled,
        null,
    ));
}

fn runSseAllocationFailureCase(alloc: Allocator) !void {
    const sse_text =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;
    const completion = try consumeSse(
        alloc,
        &reader,
        &callback_ctx,
        ignoreTestChunk,
        null,
        null,
        null,
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |value| alloc.free(@constCast(value));
        if (completion.generation_id) |value| alloc.free(@constCast(value));
        types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
}

test "OpenCode SSE delayed tool identity is allocation-failure safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runSseAllocationFailureCase,
        .{},
    );
}
