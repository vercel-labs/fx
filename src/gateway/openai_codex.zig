const std = @import("std");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const endpoint = "https://chatgpt.com/backend-api/codex/responses";
const generation_origin = "https://chatgpt.com/backend-api/codex";
const e2e_endpoint_env = "FX_E2E_OPENAI_CODEX_RESPONSES_URL";
const max_error_body_bytes: usize = 1024 * 1024;
const max_sse_line_bytes: usize = 32 * 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_provider_state_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

const CodexLimits = struct {
    aggregate_bytes: usize = max_sse_aggregate_bytes,
    events: usize = max_sse_events,
    tool_calls: usize = max_tool_calls,
    tool_identity_bytes: usize = max_tool_identity_bytes,
    tool_arguments_bytes: usize = max_tool_arguments_bytes,
    provider_state_bytes: usize = max_provider_state_bytes,
};

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = buildRequest,
    .stream_fn = streamCompletion,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAICodexModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAICodexModel;
    }
}

fn validateReplayMessage(message: types.ChatMessage, limits: CodexLimits) !void {
    if (message.provider_state_json) |state_json| {
        if (state_json.len > limits.provider_state_bytes) return error.OpenAICodexProviderStateTooLarge;
    }
    if (message.tool_calls.len > limits.tool_calls) return error.OpenAICodexToolCallLimitExceeded;
    for (message.tool_calls) |call| {
        if (call.id.len == 0 or call.id.len > limits.tool_identity_bytes or
            call.name.len == 0 or call.name.len > limits.tool_identity_bytes)
        {
            return error.OpenAICodexToolCallLimitExceeded;
        }
        if (call.arguments_json.len > limits.tool_arguments_bytes) {
            return error.OpenAICodexToolArgumentsTooLarge;
        }
    }
}

pub fn buildRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    try validateModel(request.model);
    try types.validateProviderMessageText(request.messages);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }
    if (instructions.written().len == 0) try instructions.writer.writeAll("You are a helpful assistant.");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true,\"instructions\":");
    try std.json.Stringify.value(instructions.written(), .{}, writer);
    try writer.writeAll(",\"input\":[");
    try writeInput(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');

    _ = try writeTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    try writer.writeAll(",\"parallel_tool_calls\":true,\"include\":[\"reasoning.encrypted_content\"]");
    // Codex exposes Fast mode as its priority service tier for supported
    // ChatGPT subscription models.
    if (request.provider_options.fast) try writer.writeAll(",\"service_tier\":\"priority\"");

    try writer.writeAll(",\"text\":{\"verbosity\":\"low\"");
    if (request.response_format) |format| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
        try writer.writeAll(",\"strict\":true}");
    }
    try writer.writeByte('}');

    if (request.provider_options.reasoning) |effort| {
        const label = if (std.mem.eql(u8, effort.label(), "minimal")) "low" else effort.label();
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(label, .{}, writer);
        try writer.writeAll(",\"summary\":\"auto\"}");
    }
    // The ChatGPT Codex endpoint chooses the model's output limit and rejects
    // the public Responses API max_output_tokens parameter.
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeInput(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => continue,
            .user => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_part = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"input_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                };
                if (verified_images) |images| {
                    if (message_index == messages.len - 1) {
                        for (images) |image| {
                            if (!first_part) try writer.writeByte(',');
                            try writeInputImage(writer, alloc, image);
                            first_part = false;
                        }
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                try validateReplayMessage(message, .{});
                if (message.provider_state_json) |state_json| {
                    var state = std.json.parseFromSlice(std.json.Value, alloc, state_json, .{}) catch
                        return error.InvalidOpenAICodexProviderState;
                    defer state.deinit();
                    if (state.value != .array) return error.InvalidOpenAICodexProviderState;
                    for (state.value.array.items) |item| {
                        if (item != .object) return error.InvalidOpenAICodexProviderState;
                        try writeComma(writer, &first);
                        try std.json.Stringify.value(item, .{}, writer);
                    }
                }
                if (message.content) |content| if (content.len > 0) {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeAll(",\"annotations\":[]}]}");
                };
                for (message.tool_calls) |call| {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeByte('}');
                }
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"output\":");
                try text_utils.writeModelSafeTextJson(writer, message.content orelse "");
                try writer.writeByte('}');
            },
        }
    }
}

fn writeInputImage(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}");
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
    if (parsed.value != .array) return error.InvalidToolSchema;

    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();
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
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (value.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeAll(",\"strict\":false}");
    return true;
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    return streamCompletionCore(alloc, request) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
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
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamCompletionCore(alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source != .chatgpt_subscription) {
        return error.CodexSubscriptionCredentialRequired;
    }
    try validateModel(request.model);
    const account_id = try chatgpt_oauth.extractAccountId(alloc, request.api_key);
    defer alloc.free(account_id);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth_header);
    const request_endpoint = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenAICodexEndpoint;
        break :endpoint override;
    } else endpoint;
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [7]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "chatgpt-account-id", .value = account_id };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "originator", .value = "fx" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    if (request.session_id) |session_id| if (session_id.len > 0) {
        extra_headers_buf[extra_count] = .{ .name = "session-id", .value = session_id };
        extra_count += 1;
        extra_headers_buf[extra_count] = .{ .name = "x-client-request-id", .value = session_id };
        extra_count += 1;
    };

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
        .extra_headers = extra_headers_buf[0..extra_count],
    };
    const connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
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
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenAI Codex error response exceeded the local limit"),
            else => return err,
        };
        return .{
            .status = response.head.status,
            .err_body = body,
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
        .{},
    );
    return .{
        .status = .ok,
        .completion = completion,
        .generation_origin = generation_origin,
        .ownership = .owned,
    };
}

const ToolAccumulator = struct {
    output_index: i64,
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

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenAICodexSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenAICodexSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return self.pending_line.items;
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.OpenAICodexSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return fragment;
            try self.pending_line.appendSlice(alloc, fragment);
            return self.pending_line.items;
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
    limits: CodexLimits,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var provider_state: std.Io.Writer.Allocating = .init(alloc);
    defer provider_state.deinit();
    var provider_state_count: usize = 0;
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
    var terminal_seen = false;
    var saw_content_delta = false;
    var event_count: usize = 0;
    var aggregate_bytes: usize = 0;

    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        event_count = try checkedAccumulatedSize(event_count, 1, limits.events);
        aggregate_bytes = try checkedAccumulatedSize(aggregate_bytes, json_text.len, limits.aggregate_bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidOpenAICodexSseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event_type = stringField(parsed.value.object, "type") orelse continue;

        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const item = parsed.value.object.get("item") orelse continue;
            if (item != .object) continue;
            const item_type = stringField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, item_type, "function_call")) {
                const call_id = stringField(item.object, "call_id") orelse continue;
                const name = stringField(item.object, "name") orelse continue;
                if (findTool(tools.items, output_index) == null) {
                    try appendTool(alloc, &tools, output_index, call_id, name, limits);
                    if (on_tool_start) |callback| callback(callback_ctx, call_id, name, null);
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta") or
            std.mem.eql(u8, event_type, "response.refusal.delta"))
        {
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            saw_content_delta = true;
            on_content_chunk(callback_ctx, delta);
            try appendCaptured(alloc, &content, delta, content_capture_limit);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            if (on_reasoning_chunk) |callback| callback(callback_ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
            if (on_reasoning_chunk) |callback| callback(callback_ctx, "\n\n");
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            const index = findTool(tools.items, output_index) orelse continue;
            try appendToolArguments(alloc, &tools.items[index].arguments, delta, limits.tool_arguments_bytes);
            if (on_tool_input_chunk) |callback| callback(callback_ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const arguments = stringField(parsed.value.object, "arguments") orelse continue;
            const index = findTool(tools.items, output_index) orelse continue;
            const previous_len = tools.items[index].arguments.items.len;
            if (std.mem.startsWith(u8, arguments, tools.items[index].arguments.items)) {
                const suffix = arguments[previous_len..];
                try appendToolArguments(alloc, &tools.items[index].arguments, suffix, limits.tool_arguments_bytes);
                if (suffix.len > 0) if (on_tool_input_chunk) |callback| callback(callback_ctx, suffix);
            } else {
                tools.items[index].arguments.clearRetainingCapacity();
                try appendToolArguments(alloc, &tools.items[index].arguments, arguments, limits.tool_arguments_bytes);
            }
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const item = parsed.value.object.get("item") orelse continue;
            if (item != .object) continue;
            const item_type = stringField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, item_type, "function_call")) {
                if (findTool(tools.items, output_index)) |index| {
                    if (stringField(item.object, "arguments")) |arguments| {
                        if (tools.items[index].arguments.items.len == 0) {
                            try appendToolArguments(alloc, &tools.items[index].arguments, arguments, limits.tool_arguments_bytes);
                        }
                    }
                }
            } else if (std.mem.eql(u8, item_type, "reasoning") and
                stringField(item.object, "encrypted_content") != null)
            {
                var encoded: std.Io.Writer.Allocating = .init(alloc);
                defer encoded.deinit();
                try std.json.Stringify.value(item, .{}, &encoded.writer);
                const framed_size = try checkedAccumulatedSize(encoded.written().len, 2, limits.provider_state_bytes);
                _ = try checkedAccumulatedSize(provider_state.written().len, framed_size, limits.provider_state_bytes);
                if (provider_state_count == 0) {
                    try provider_state.writer.writeByte('[');
                } else {
                    try provider_state.writer.writeByte(',');
                }
                try provider_state.writer.writeAll(encoded.written());
                provider_state_count += 1;
            } else if (std.mem.eql(u8, item_type, "message") and !saw_content_delta) {
                if (item.object.get("content")) |parts| if (parts == .array) {
                    for (parts.array.items) |part| {
                        if (part != .object) continue;
                        const text = stringField(part.object, "text") orelse stringField(part.object, "refusal") orelse continue;
                        on_content_chunk(callback_ctx, text);
                        try appendCaptured(alloc, &content, text, content_capture_limit);
                    }
                };
            }
        } else if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.done") or
            std.mem.eql(u8, event_type, "response.incomplete"))
        {
            const response_value = parsed.value.object.get("response") orelse continue;
            if (response_value != .object) continue;
            terminal_seen = true;
            const status = stringField(response_value.object, "status");
            finish_reason = finishReason(status, response_value.object, tools.items.len > 0);
            usage = parseUsage(response_value.object);
            if (stringField(response_value.object, "id")) |id| {
                generation_id = try alloc.dupe(u8, id);
            }
            break;
        } else if (std.mem.eql(u8, event_type, "response.failed") or
            std.mem.eql(u8, event_type, "error"))
        {
            return error.OpenAICodexResponseFailed;
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!terminal_seen) return error.OpenAICodexStreamIncomplete;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_provider_state = if (provider_state_count > 0) state: {
        try provider_state.writer.writeByte(']');
        break :state try provider_state.toOwnedSlice();
    } else null;
    errdefer if (owned_provider_state) |value| alloc.free(value);
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
        .provider_state_json = owned_provider_state,
        .finish_reason = finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
        .usage = usage,
    };
}

fn appendTool(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    output_index: i64,
    call_id: []const u8,
    name: []const u8,
    limits: CodexLimits,
) !void {
    if (tools.items.len >= limits.tool_calls or call_id.len == 0 or call_id.len > limits.tool_identity_bytes or
        name.len == 0 or name.len > limits.tool_identity_bytes)
    {
        return error.OpenAICodexToolCallLimitExceeded;
    }
    const id = try alloc.dupe(u8, call_id);
    errdefer alloc.free(id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try tools.append(alloc, .{
        .output_index = output_index,
        .id = id,
        .name = owned_name,
    });
}

fn appendToolArguments(
    alloc: Allocator,
    arguments: *std.ArrayList(u8),
    delta: []const u8,
    maximum: usize,
) !void {
    _ = checkedAccumulatedSize(arguments.items.len, delta.len, maximum) catch
        return error.OpenAICodexToolArgumentsTooLarge;
    try arguments.appendSlice(alloc, delta);
}

fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.OpenAICodexResourceLimitExceeded;
    if (next > maximum) return error.OpenAICodexResourceLimitExceeded;
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

fn findTool(tools: []const ToolAccumulator, output_index: i64) ?usize {
    for (tools, 0..) |tool, index| if (tool.output_index == output_index) return index;
    return null;
}

fn finishReason(
    status: ?[]const u8,
    response: std.json.ObjectMap,
    has_tools: bool,
) types.ProviderFinishReason {
    const value = status orelse return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, value, "completed")) return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, value, "incomplete")) {
        if (response.get("incomplete_details")) |details| if (details == .object) {
            if (stringField(details.object, "reason")) |reason| {
                if (std.mem.eql(u8, reason, "max_output_tokens")) return .length;
                if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
            }
        };
        return .provider_error;
    }
    if (std.mem.eql(u8, value, "failed") or std.mem.eql(u8, value, "cancelled")) return .provider_error;
    return if (has_tools) .tool_calls else .other;
}

fn parseUsage(response: std.json.ObjectMap) types.Usage {
    const value = response.get("usage") orelse return .{};
    if (value != .object) return .{};
    return .{
        .input_tokens = unsignedField(value.object, "input_tokens"),
        .output_tokens = unsignedField(value.object, "output_tokens"),
    };
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

test "OpenAI Codex request uses Responses input and converts AI SDK tool schemas" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
            .provider_state_json = "[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}]",
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "gpt-5.4",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high"), .fast = true },
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"Be concise.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"encrypted_content\":\"opaque\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":{\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\":\"priority\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\"") == null);
}

test "OpenAI Codex request normalizes unsafe tool output to a string" {
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call_1", .name = "run_command", .arguments_json = "{}" }} },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "run_command", .content = "bad\xff" },
    };
    const body = try buildOpenAICodexReplay(&messages);
    defer std.testing.allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const output = parsed.value.object.get("input").?.array.items[1].object.get("output").?;
    try std.testing.expect(output == .string);
    try std.testing.expectEqualStrings(
        "binary or non-utf8 tool output omitted (4 bytes)",
        output.string,
    );
}

test "OpenAI Codex request rejects unsafe user text locally" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "bad\xff" }};
    try expectOpenAICodexReplayError(error.InvalidProviderMessageText, &messages);
}

fn makeSizedProviderState(alloc: Allocator, size: usize) ![]u8 {
    const prefix = "[{\"type\":\"reasoning\",\"encrypted_content\":\"";
    const suffix = "\"}]";
    if (size < prefix.len + suffix.len) return error.TestProviderStateSizeTooSmall;
    const state = try alloc.alloc(u8, size);
    @memcpy(state[0..prefix.len], prefix);
    @memset(state[prefix.len .. size - suffix.len], 'x');
    @memcpy(state[size - suffix.len ..], suffix);
    return state;
}

fn makeSizedToolArguments(alloc: Allocator, size: usize) ![]u8 {
    const prefix = "{\"value\":\"";
    const suffix = "\"}";
    if (size < prefix.len + suffix.len) return error.TestToolArgumentsSizeTooSmall;
    const arguments = try alloc.alloc(u8, size);
    @memcpy(arguments[0..prefix.len], prefix);
    @memset(arguments[prefix.len .. size - suffix.len], 'x');
    @memcpy(arguments[size - suffix.len ..], suffix);
    return arguments;
}

fn buildOpenAICodexReplay(messages: []const types.ChatMessage) ![]u8 {
    return agent_stream_provider.build(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .serialized_tools = "[]",
        .messages = messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
}

fn expectOpenAICodexReplaySuccess(messages: []const types.ChatMessage) !void {
    const body = try buildOpenAICodexReplay(messages);
    std.testing.allocator.free(body);
}

fn expectOpenAICodexReplayError(expected: anyerror, messages: []const types.ChatMessage) !void {
    const result = buildOpenAICodexReplay(messages);
    if (result) |body| {
        std.testing.allocator.free(body);
        return error.TestExpectedOpenAICodexReplayError;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

test "OpenAI Codex replay provider state accepts the limit and rejects one byte beyond" {
    {
        const provider_state = try makeSizedProviderState(std.testing.allocator, max_provider_state_bytes);
        defer std.testing.allocator.free(provider_state);
        const messages = [_]types.ChatMessage{.{
            .role = .assistant,
            .provider_state_json = provider_state,
        }};
        try expectOpenAICodexReplaySuccess(&messages);
    }
    {
        const provider_state = try makeSizedProviderState(std.testing.allocator, max_provider_state_bytes + 1);
        defer std.testing.allocator.free(provider_state);
        const messages = [_]types.ChatMessage{.{
            .role = .assistant,
            .provider_state_json = provider_state,
        }};
        try expectOpenAICodexReplayError(error.OpenAICodexProviderStateTooLarge, &messages);
    }
}

test "OpenAI Codex replay tool count accepts the limit and rejects one call beyond" {
    var calls: [max_tool_calls + 1]types.ToolCall = undefined;
    for (&calls) |*call| call.* = .{ .id = "call", .name = "read_file", .arguments_json = "{}" };
    var message: types.ChatMessage = .{ .role = .assistant, .tool_calls = calls[0..max_tool_calls] };
    try expectOpenAICodexReplaySuccess(&.{message});
    message.tool_calls = &calls;
    try expectOpenAICodexReplayError(error.OpenAICodexToolCallLimitExceeded, &.{message});
}

test "OpenAI Codex replay tool identities accept the limit and reject one byte beyond" {
    const identity = try std.testing.allocator.alloc(u8, max_tool_identity_bytes + 1);
    defer std.testing.allocator.free(identity);
    @memset(identity, 'i');
    var call: types.ToolCall = .{ .id = identity[0..max_tool_identity_bytes], .name = "read", .arguments_json = "{}" };
    var message: types.ChatMessage = .{ .role = .assistant, .tool_calls = &.{call} };
    try expectOpenAICodexReplaySuccess(&.{message});
    call.id = identity;
    message.tool_calls = &.{call};
    try expectOpenAICodexReplayError(error.OpenAICodexToolCallLimitExceeded, &.{message});

    call = .{ .id = "call", .name = identity[0..max_tool_identity_bytes], .arguments_json = "{}" };
    message.tool_calls = &.{call};
    try expectOpenAICodexReplaySuccess(&.{message});
    call.name = identity;
    message.tool_calls = &.{call};
    try expectOpenAICodexReplayError(error.OpenAICodexToolCallLimitExceeded, &.{message});
}

test "OpenAI Codex replay tool arguments accept the limit and reject one byte beyond" {
    {
        const arguments = try makeSizedToolArguments(std.testing.allocator, max_tool_arguments_bytes);
        defer std.testing.allocator.free(arguments);
        const calls = [_]types.ToolCall{.{ .id = "call", .name = "read", .arguments_json = arguments }};
        const messages = [_]types.ChatMessage{.{ .role = .assistant, .tool_calls = &calls }};
        try expectOpenAICodexReplaySuccess(&messages);
    }
    {
        const arguments = try makeSizedToolArguments(std.testing.allocator, max_tool_arguments_bytes + 1);
        defer std.testing.allocator.free(arguments);
        const calls = [_]types.ToolCall{.{ .id = "call", .name = "read", .arguments_json = arguments }};
        const messages = [_]types.ChatMessage{.{ .role = .assistant, .tool_calls = &calls }};
        try expectOpenAICodexReplayError(error.OpenAICodexToolArgumentsTooLarge, &messages);
    }
}

test "OpenAI Codex standard requests omit the priority service tier" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\"") == null);
}

test "OpenAI Codex serializes each verified image directly once" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
        .verified_images = &images,
    });
    defer std.testing.allocator.free(body);

    const marker = "\"type\":\"input_image\"";
    const first = std.mem.find(u8, body, marker) orelse return error.TestExpectedImage;
    try std.testing.expect(std.mem.findPos(u8, body, first + marker.len, marker) == null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
}

test "OpenAI Codex rejects a wrong-origin credential before network I/O" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.CodexSubscriptionCredentialRequired,
        agent_stream_provider.stream(std.testing.allocator, .{
            .api_key = "gateway-key",
            .credential_source = .ai_gateway_api_key,
            .team = null,
            .model = "gpt-5.6-sol",
            .retry_count = 1,
            .chat_url = "",
            .payload = "{}",
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &evidence,
            .callback_ctx = @ptrCast(&callback_context),
            .on_content_chunk = struct {
                fn ignore(_: *anyopaque, _: []const u8) void {}
            }.ignore,
            .on_tool_start = null,
            .on_reasoning_chunk = null,
            .cancel_flag = &cancelled,
        }),
    );
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

test "OpenAI Codex SSE maps text reasoning tools and usage" {
    const sse_text =
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"reasoning\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"delta\":\"thinking\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"opaque\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"message\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":2,\"delta\":\"{\\\"path\\\":\\\"README.md\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4}}}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,
        saw_read_file: bool = false,

        fn contentChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn reasoningChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reasoning.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.saw_read_file = std.mem.eql(u8, name, "read_file");
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
        .{},
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
        if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expectEqualStrings("thinking", capture.reasoning.items);
    try std.testing.expect(capture.saw_read_file);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expect(completion.provider_state_json != null);
    try std.testing.expect(std.mem.find(u8, completion.provider_state_json.?, "\"encrypted_content\":\"opaque\"") != null);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

fn consumeOpenAICodexTestSse(sse_text: []const u8, limits: CodexLimits) !types.GatewayCompletion {
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    return consumeSse(
        std.testing.allocator,
        &reader,
        &callback_context,
        struct {
            fn ignore(_: *anyopaque, _: []const u8) void {}
        }.ignore,
        null,
        null,
        null,
        &cancelled,
        null,
        limits,
    );
}

fn freeOpenAICodexTestCompletion(completion: types.GatewayCompletion) void {
    if (completion.content) |value| std.testing.allocator.free(@constCast(value));
    types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
    if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
}

fn expectOpenAICodexSseError(expected: anyerror, sse_text: []const u8, limits: CodexLimits) !void {
    const result = consumeOpenAICodexTestSse(sse_text, limits);
    if (result) |completion| {
        freeOpenAICodexTestCompletion(completion);
        return error.TestExpectedOpenAICodexSseError;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

test "OpenAI Codex checked stream sizes accept the bound and reject overflow" {
    try std.testing.expectEqual(@as(usize, 7), try checkedAccumulatedSize(6, 1, 7));
    try std.testing.expectError(
        error.OpenAICodexResourceLimitExceeded,
        checkedAccumulatedSize(std.math.maxInt(usize), 1, std.math.maxInt(usize)),
    );
}

test "OpenAI Codex rejects cumulative event and byte limits" {
    const terminal_json = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}";
    const terminal_event = "data: " ++ terminal_json ++ "\n\n";
    const completion = try consumeOpenAICodexTestSse(
        terminal_event,
        .{ .events = 1, .aggregate_bytes = terminal_json.len },
    );
    defer freeOpenAICodexTestCompletion(completion);

    const event = "data: {\"type\":\"response.reasoning_summary_part.done\"}\n\n";
    try expectOpenAICodexSseError(
        error.OpenAICodexResourceLimitExceeded,
        event ++ event,
        .{ .events = 1 },
    );
    try expectOpenAICodexSseError(
        error.OpenAICodexResourceLimitExceeded,
        terminal_event,
        .{ .aggregate_bytes = terminal_json.len - 1 },
    );
}

test "OpenAI Codex rejects oversized streamed tool identities" {
    try expectOpenAICodexSseError(
        error.OpenAICodexToolCallLimitExceeded,
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call\",\"name\":\"ok\"}}\n\n",
        .{ .tool_identity_bytes = 3 },
    );
    try expectOpenAICodexSseError(
        error.OpenAICodexToolCallLimitExceeded,
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"ok\",\"name\":\"read\"}}\n\n",
        .{ .tool_identity_bytes = 3 },
    );
}

test "OpenAI Codex bounds every streamed argument representation and cleans staged state" {
    const prefix =
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"read\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}}\n\n";
    const cases = [_][]const u8{
        prefix ++ "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"four\"}\n\n",
        prefix ++ "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":\"four\"}\n\n",
        prefix ++ "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"arguments\":\"four\"}}\n\n",
    };
    for (cases) |sse_text| {
        try expectOpenAICodexSseError(
            error.OpenAICodexToolArgumentsTooLarge,
            sse_text,
            .{ .tool_arguments_bytes = 3 },
        );
    }
}

test "OpenAI Codex rejects oversized encrypted provider state" {
    try expectOpenAICodexSseError(
        error.OpenAICodexResourceLimitExceeded,
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}}\n\n",
        .{ .provider_state_bytes = 16 },
    );
}

test "OpenAI Codex provider state accepts the exact framed limit" {
    const expected_state = "[{\"type\":\"reasoning\",\"encrypted_content\":\"a\"},{\"type\":\"reasoning\",\"encrypted_content\":\"b\"}]";
    const sse_text =
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"encrypted_content\":\"a\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"encrypted_content\":\"b\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    const completion = try consumeOpenAICodexTestSse(
        sse_text,
        .{ .provider_state_bytes = expected_state.len },
    );
    defer freeOpenAICodexTestCompletion(completion);
    try std.testing.expectEqualStrings(expected_state, completion.provider_state_json.?);
    try expectOpenAICodexSseError(
        error.OpenAICodexResourceLimitExceeded,
        sse_text,
        .{ .provider_state_bytes = expected_state.len - 1 },
    );
}

test "OpenAI Codex rejects a 129th streamed tool call" {
    var stream: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stream.deinit();
    for (0..129) |index| {
        try stream.writer.print(
            "data: {{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{{\"type\":\"function_call\",\"call_id\":\"call_{d}\",\"name\":\"read_file\"}}}}\n\n",
            .{ index, index },
        );
    }
    try stream.writer.writeAll("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n");

    const result = consumeOpenAICodexTestSse(stream.written(), .{});
    if (result) |completion| {
        freeOpenAICodexTestCompletion(completion);
        return error.TestExpectedToolCallLimit;
    } else |err| {
        try std.testing.expectEqual(error.OpenAICodexToolCallLimitExceeded, err);
    }
}
