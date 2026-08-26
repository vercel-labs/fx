const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");

const Allocator = std.mem.Allocator;

pub const openpaths_base_url = "https://openpaths.io/v1";
pub const openrouter_base_url = "https://openrouter.ai/api/v1";
const openpaths_chat_url = openpaths_base_url ++ "/chat/completions";
const openrouter_chat_url = openrouter_base_url ++ "/chat/completions";
const e2e_endpoint_env = "FX_E2E_OPENPATHS_CHAT_URL";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_catalog_models: usize = 512;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = buildRequest,
    .stream_fn = streamCompletion,
};

fn acceptsSource(source: ?types.CredentialSource) bool {
    return source == .openpaths_api_key or source == .openrouter_api_key;
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_id_bytes) return error.InvalidOpenPathsModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenPathsModel;
    }
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

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"messages\":[");
    try writeMessages(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');
    _ = try writeTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);

    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    if (request.response_format) |format| {
        var schema = std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{}) catch
            return error.InvalidStructuredResponseSchema;
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
        try writer.writeAll(",\"strict\":false}}");
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
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => {
                const text = message.content orelse continue;
                if (text.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(text, .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                try writeComma(writer, &first);
                const is_last = message_index == messages.len - 1;
                const images: []const image_attachments.VerifiedSnapshot =
                    if (verified_images) |value| if (is_last) value else &.{} else &.{};
                if (images.len == 0) {
                    try writer.writeAll("{\"role\":\"user\",\"content\":");
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                    try writer.writeByte('}');
                } else {
                    try writer.writeAll("{\"role\":\"user\",\"content\":[");
                    var first_part = true;
                    if (message.content) |content| if (content.len > 0) {
                        try writer.writeAll("{\"type\":\"text\",\"text\":");
                        try std.json.Stringify.value(content, .{}, writer);
                        try writer.writeByte('}');
                        first_part = false;
                    };
                    for (images) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeImagePart(writer, alloc, image);
                        first_part = false;
                    }
                    try writer.writeAll("]}");
                }
            },
            .assistant => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, call_index| {
                        if (call_index != 0) try writer.writeByte(',');
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
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeImagePart(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}");
}

fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    serialized_tools: []const u8,
    selected_dynamic_schemas: []const []const u8,
) !usize {
    var count: usize = 0;
    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();

    if (serialized_tools.len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolSchema,
        };
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidToolSchema;
        for (parsed.value.array.items) |tool| {
            if (try writeFunctionTool(&tools_out.writer, tool, count != 0)) count += 1;
        }
    }
    for (selected_dynamic_schemas) |schema_json| {
        var selected = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolSchema,
        };
        defer selected.deinit();
        if (try writeFunctionTool(&tools_out.writer, selected.value, count != 0)) count += 1;
    }
    if (count > 0) {
        try writer.writeAll(",\"tools\":[");
        try writer.writeAll(tools_out.written());
        try writer.writeByte(']');
    }
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

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
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

fn chatEndpoint(source: ?types.CredentialSource) ![]const u8 {
    if (io_mod.getenv(e2e_endpoint_env)) |override| {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenPathsEndpoint;
        return override;
    }
    return switch (source orelse return error.OpenPathsCredentialRequired) {
        .openpaths_api_key => openpaths_chat_url,
        .openrouter_api_key => openrouter_chat_url,
        else => error.OpenPathsCredentialRequired,
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

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamCompletionCore(alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!acceptsSource(request.credential_source)) return error.OpenPathsCredentialRequired;
    try validateModel(request.model);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth_header);
    const endpoint = try chatEndpoint(request.credential_source);
    const uri = try std.Uri.parse(endpoint);

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
            error.StreamTooLong => try alloc.dupe(u8, "OpenPaths error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "OpenPaths error response exceeded the local limit");
        } else bounded_body;
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
    );
    return .{
        .status = .ok,
        .completion = completion,
        .ownership = .owned,
    };
}

const ToolAccumulator = struct {
    index: i64,
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    started: bool = false,
    arguments: std.ArrayList(u8) = .empty,
    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        if (self.id) |id| alloc.free(id);
        if (self.name) |name| alloc.free(name);
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
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenPathsSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenPathsSseEventTooLarge;
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
                return error.OpenPathsSseEventTooLarge;
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
    var saw_activity = false;
    var event_count: usize = 0;

    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        event_count = try checkedAccumulatedSize(event_count, 1, max_sse_events);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (parsed.value.object.contains("error")) return error.OpenPathsStreamFailed;

        if (generation_id == null) {
            if (stringField(parsed.value.object, "id")) |id| generation_id = try alloc.dupe(u8, id);
        }
        if (parseUsage(parsed.value.object)) |value| usage = value;

        const choices = parsed.value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;

        if (choice.object.get("delta")) |delta| {
            if (delta == .object) try consumeDelta(
                alloc,
                delta.object,
                callback_ctx,
                on_content_chunk,
                on_tool_start,
                on_reasoning_chunk,
                on_tool_input_chunk,
                content_capture_limit,
                &content,
                &tools,
                &saw_activity,
            );
        }

        if (choice.object.get("finish_reason")) |reason_value| {
            if (reason_value == .string) {
                finish_reason = mapFinishReason(reason_value.string);
            }
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (finish_reason == null and !saw_activity) return error.OpenPathsStreamIncomplete;
    if (finish_reason == null) finish_reason = .stop;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = blk: {
        var completed: std.ArrayList(types.ToolCall) = .empty;
        errdefer completed.deinit(alloc);
        for (tools.items) |*tool| {
            const id = tool.id orelse continue;
            const name = tool.name orelse continue;
            const arguments = if (tool.arguments.items.len > 0)
                try tool.arguments.toOwnedSlice(alloc)
            else
                try alloc.dupe(u8, "{}");
            tool.arguments = .empty;
            try completed.append(alloc, .{
                .id = id,
                .name = name,
                .arguments_json = arguments,
            });
            tool.id = null;
            tool.name = null;
        }
        break :blk try completed.toOwnedSlice(alloc);
    };
    errdefer types.freeToolCallSlice(alloc, owned_tools);
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .finish_reason = finish_reason.?,
        .usage = usage,
    };
}

fn consumeDelta(
    alloc: Allocator,
    delta: std.json.ObjectMap,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    content_capture_limit: ?usize,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    saw_activity: *bool,
) !void {
    if (delta.get("content")) |value| {
        if (value == .string and value.string.len > 0) {
            saw_activity.* = true;
            on_content_chunk(callback_ctx, value.string);
            try appendCaptured(alloc, content, value.string, content_capture_limit);
        }
    }
    if (delta.get("reasoning")) |value| {
        if (value == .string and value.string.len > 0) {
            if (on_reasoning_chunk) |callback| callback(callback_ctx, value.string);
        }
    }
    if (delta.get("reasoning_content")) |value| {
        if (value == .string and value.string.len > 0) {
            if (on_reasoning_chunk) |callback| callback(callback_ctx, value.string);
        }
    }
    const tool_calls = delta.get("tool_calls") orelse return;
    if (tool_calls != .array) return;
    for (tool_calls.array.items) |entry| {
        if (entry != .object) continue;
        const index = integerField(entry.object, "index") orelse 0;
        var slot: ?*ToolAccumulator = findTool(tools.items, index);
        if (slot == null) {
            if (tools.items.len >= max_tool_calls) return error.OpenPathsToolCallLimitExceeded;
            try tools.append(alloc, .{ .index = index });
            slot = &tools.items[tools.items.len - 1];
        }
        const tool = slot.?;
        if (entry.object.get("id")) |id_value| {
            if (id_value == .string and id_value.string.len > 0 and tool.id == null) {
                tool.id = try alloc.dupe(u8, id_value.string);
            }
        }
        if (entry.object.get("function")) |function| {
            if (function != .object) continue;
            if (function.object.get("name")) |name_value| {
                if (name_value == .string and name_value.string.len > 0 and tool.name == null) {
                    if (name_value.string.len > max_tool_identity_bytes) {
                        return error.OpenPathsToolCallLimitExceeded;
                    }
                    tool.name = try alloc.dupe(u8, name_value.string);
                }
            }
            if (function.object.get("arguments")) |arguments| {
                if (arguments == .string and arguments.string.len > 0) {
                    try appendToolArguments(alloc, &tool.arguments, arguments.string);
                    saw_activity.* = true;
                    if (on_tool_input_chunk) |callback| callback(callback_ctx, arguments.string);
                }
            }
        }
        if (tool.id != null and tool.name != null and !tool.started) {
            tool.started = true;
            if (on_tool_start) |callback| callback(callback_ctx, tool.id.?, tool.name.?, null);
        }
    }
}
pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = "/v1/models",
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

// ---------------------------------------------------------------------------
// Model catalog: OpenAI-compatible GET /models returning {"data":[{"id":...}]}
// ---------------------------------------------------------------------------

fn mapFinishReason(reason: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length") or std.mem.eql(u8, reason, "max_tokens")) return .length;
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) {
        return .tool_calls;
    }
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    return .other;
}

fn parseUsage(object: std.json.ObjectMap) ?types.Usage {
    const value = object.get("usage") orelse return null;
    if (value != .object) return null;
    const input = unsignedField(value.object, "prompt_tokens");
    const output = unsignedField(value.object, "completion_tokens");
    if (input == null and output == null) return null;
    return .{ .input_tokens = input, .output_tokens = output };
}

fn appendToolArguments(
    alloc: Allocator,
    arguments: *std.ArrayList(u8),
    delta: []const u8,
) !void {
    _ = checkedAccumulatedSize(arguments.items.len, delta.len, max_tool_arguments_bytes) catch
        return error.OpenPathsToolArgumentsTooLarge;
    try arguments.appendSlice(alloc, delta);
}

fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.OpenPathsResourceLimitExceeded;
    if (next > maximum) return error.OpenPathsResourceLimitExceeded;
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

fn findTool(tools: []ToolAccumulator, index: i64) ?*ToolAccumulator {
    for (tools) |*tool| if (tool.index == index) return tool;
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

// ---------------------------------------------------------------------------
// Model catalog: OpenAI-compatible GET /models returning {"data":[{"id":...}]}
// ---------------------------------------------------------------------------

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    if (!acceptsSource(input.access.credentialSource())) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };

    const source = input.access.credentialSource().?;
    const request_url = modelsUrl(alloc, source) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var response = fetchCatalogResponse(alloc, request_url, credential, cancel_flag, deadline) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .{ .failure = .{ .category = .cancellation } };
        return .{ .failure = .{ .category = .transport, .retryable = true } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

const CatalogFetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *CatalogFetchResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const CatalogFetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,

    pub fn run(self: *@This()) !CatalogFetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OpenPathsModelCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_catalog_bytes) return error.OpenPathsModelCatalogTooLarge;
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn fetchCatalogResponse(
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !CatalogFetchResponse {
    var operation = CatalogFetchOperation{
        .alloc = alloc,
        .url = url,
        .credential = credential,
    };
    return gateway_client.runBoundedHttpOperation(
        CatalogFetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

fn modelsUrl(alloc: Allocator, source: types.CredentialSource) ![]const u8 {
    if (io_mod.getenv(e2e_endpoint_env)) |_| {
        // The e2e chat override only covers POST /chat/completions; catalogs stay live.
        return switch (source) {
            .openpaths_api_key => std.fmt.allocPrint(alloc, "{s}/models", .{openpaths_base_url}),
            else => std.fmt.allocPrint(alloc, "{s}/models", .{openrouter_base_url}),
        };
    }
    return switch (source) {
        .openpaths_api_key => std.fmt.allocPrint(alloc, "{s}/models", .{openpaths_base_url}),
        else => std.fmt.allocPrint(alloc, "{s}/models", .{openrouter_base_url}),
    };
}

fn parseCatalog(
    alloc: Allocator,
    body: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenPathsModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenPathsModelCatalog;
    if (data != .array) return error.InvalidOpenPathsModelCatalog;
    if (data.array.items.len > max_catalog_models) return error.InvalidOpenPathsModelCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |value| {
        if (value != .object) continue;
        const raw_id = stringField(value.object, "id") orelse continue;
        if (raw_id.len == 0 or raw_id.len > max_model_id_bytes) continue;
        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
        });
    }
    return catalog;
}

test "chat completions request uses OpenAI wire shape" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .content = "Opening it.",
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "openpaths/stealth/ox-alpha",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 4096,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"openpaths/stealth/ox-alpha\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"system\",\"content\":\"Be concise.\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function\",\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\"") == null);
}

test "chat completions request serializes reasoning effort and images" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "deepseek-v4-flash-vision-exp",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("low") },
        .verified_images = &images,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"image_url\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
}

test "chat completions SSE stream yields deltas tool calls and usage" {
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        tool_inputs: std.ArrayList(u8) = .empty,

        fn append(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch {};
        }

        fn appendToolInput(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_inputs.appendSlice(std.testing.allocator, chunk) catch {};
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    defer capture.tool_inputs.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);

    const wire =
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hel\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_9\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\":\\\"x\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(wire);

    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        @ptrCast(&capture),
        Capture.append,
        null,
        null,
        Capture.appendToolInput,
        &cancelled,
        null,
    );

    try std.testing.expectEqualStrings("Hello", capture.content.items);
    try std.testing.expectEqual(completion.finish_reason, types.ProviderFinishReason.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_9", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", capture.tool_inputs.items);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), completion.usage.output_tokens);
    try std.testing.expectEqualStrings("chatcmpl-1", completion.generation_id.?);
    if (completion.content) |content| std.testing.allocator.free(@constCast(content));
    types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    if (completion.generation_id) |id| std.testing.allocator.free(id);
}
