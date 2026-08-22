const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const opencode_session = @import("../core/auth/opencode_session.zig");
const opencode_models = @import("opencode_models.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

const zen_kind: opencode_session.Kind = .zen;
const go_kind: opencode_session.Kind = .go;

pub const zen_agent_stream_provider = stream_provider.Provider{
    .context = @constCast(&zen_kind),
    .build_fn = buildRequest,
    .stream_fn = streamCompletion,
};

pub const go_agent_stream_provider = stream_provider.Provider{
    .context = @constCast(&go_kind),
    .build_fn = buildRequest,
    .stream_fn = streamCompletion,
};

fn kindOf(raw: ?*anyopaque) opencode_session.Kind {
    return opencode_models.kindFromContext(raw);
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidOpenCodeModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenCodeModel;
    }
}

fn buildRequest(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    const kind = kindOf(raw);
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    }
    const model = opencode_models.stripModelPrefix(kind, request.model);
    const family = opencode_models.familyForModel(kind, model);
    return switch (family) {
        .responses => try buildResponsesPayload(alloc, model, request),
        .messages => try buildMessagesPayload(alloc, model, request),
        .chat_completions, .gemini => try buildChatCompletionsPayload(alloc, model, request),
    };
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn writeChatMessages(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    for (messages, 0..) |message, message_index| {
        try writeComma(writer, &first);
        switch (message.role) {
            .system => {
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                try writer.writeAll("{\"role\":\"user\",\"content\":");
                if (verified_images) |images| {
                    if (message_index == messages.len - 1 and images.len > 0) {
                        try writer.writeByte('[');
                        var part_first = true;
                        if (message.content) |content| if (content.len > 0) {
                            try writer.writeAll("{\"type\":\"text\",\"text\":");
                            try std.json.Stringify.value(content, .{}, writer);
                            try writer.writeByte('}');
                            part_first = false;
                        };
                        for (images) |image| {
                            if (!part_first) try writer.writeByte(',');
                            try writeChatImage(writer, alloc, image);
                            part_first = false;
                        }
                        try writer.writeByte(']');
                    } else {
                        try std.json.Stringify.value(message.content orelse "", .{}, writer);
                    }
                } else {
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                }
                try writer.writeByte('}');
            },
            .assistant => {
                try writer.writeAll("{\"role\":\"assistant\"");
                if (message.content) |content| {
                    try writer.writeAll(",\"content\":");
                    try std.json.Stringify.value(content, .{}, writer);
                }
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, i| {
                        if (i != 0) try writer.writeByte(',');
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
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeChatImage(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
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

fn writeOpenAiTools(writer: *std.Io.Writer, alloc: Allocator, serialized_tools: []const u8, selected: []const []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return;

    var count: usize = 0;
    try writer.writeAll(",\"tools\":[");
    for (parsed.value.array.items) |tool| {
        if (try writeOpenAiFunctionTool(writer, tool, count != 0)) count += 1;
    }
    for (selected) |schema_json| {
        var extra = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer extra.deinit();
        if (try writeOpenAiFunctionTool(writer, extra.value, count != 0)) count += 1;
    }
    try writer.writeByte(']');
    if (count == 0) {
        // tools array was written empty; leave it — most providers tolerate [].
    }
}

fn writeOpenAiFunctionTool(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const name = value.object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = value.object.get("inputSchema") orelse value.object.get("parameters") orelse return false;
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

fn buildChatCompletionsPayload(alloc: Allocator, model: []const u8, request: stream_provider.BuildRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"messages\":[");
    try writeChatMessages(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');
    try writeOpenAiTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn buildResponsesPayload(alloc: Allocator, model: []const u8, request: stream_provider.BuildRequest) ![]u8 {
    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true");
    if (instructions.written().len > 0) {
        try writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(instructions.written(), .{}, writer);
    }
    try writer.writeAll(",\"input\":[");
    var first = true;
    for (request.messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => continue,
            .user => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var part_first = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"input_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    part_first = false;
                };
                if (verifiedLastImages(request.verified_images, message_index, request.messages.len)) |images| {
                    for (images) |image| {
                        if (!part_first) try writer.writeByte(',');
                        try writeResponsesImage(writer, alloc, image);
                        part_first = false;
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                if (message.content) |content| if (content.len > 0) {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeAll("}]}");
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
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
    try writer.writeByte(']');
    try writeResponsesTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn verifiedLastImages(
    images: ?[]const image_attachments.VerifiedSnapshot,
    index: usize,
    len: usize,
) ?[]const image_attachments.VerifiedSnapshot {
    if (images == null or index + 1 != len) return null;
    return images;
}

fn writeResponsesImage(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
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

fn writeResponsesTools(writer: *std.Io.Writer, alloc: Allocator, serialized_tools: []const u8, selected: []const []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return;
    var count: usize = 0;
    try writer.writeAll(",\"tools\":[");
    for (parsed.value.array.items) |tool| {
        if (try writeResponsesFunctionTool(writer, tool, count != 0)) count += 1;
    }
    for (selected) |schema_json| {
        var extra = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch continue;
        defer extra.deinit();
        if (try writeResponsesFunctionTool(writer, extra.value, count != 0)) count += 1;
    }
    try writer.writeByte(']');
}

fn writeResponsesFunctionTool(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const name = value.object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = value.object.get("inputSchema") orelse value.object.get("parameters") orelse return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (value.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeByte('}');
    return true;
}

fn buildMessagesPayload(alloc: Allocator, model: []const u8, request: stream_provider.BuildRequest) ![]u8 {
    var system: std.Io.Writer.Allocating = .init(alloc);
    defer system.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (system.written().len > 0) try system.writer.writeAll("\n\n");
        try system.writer.writeAll(text);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"max_tokens\":");
    try writer.print("{d}", .{request.max_output_tokens orelse 16_384});
    if (system.written().len > 0) {
        try writer.writeAll(",\"system\":");
        try std.json.Stringify.value(system.written(), .{}, writer);
    }
    try writer.writeAll(",\"messages\":[");
    var first = true;
    for (request.messages) |message| {
        switch (message.role) {
            .system => continue,
            .user => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
            .assistant => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, i| {
                        if (i != 0) try writer.writeByte(',');
                        try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"input\":");
                        var args = std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{}) catch {
                            try writer.writeAll("{}");
                            try writer.writeByte('}');
                            continue;
                        };
                        defer args.deinit();
                        try std.json.Stringify.value(args.value, .{}, writer);
                        try writer.writeByte('}');
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeAll("}]}");
            },
        }
    }
    try writer.writeByte(']');
    try writeAnthropicTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeAnthropicTools(writer: *std.Io.Writer, alloc: Allocator, serialized_tools: []const u8, selected: []const []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return;
    var count: usize = 0;
    try writer.writeAll(",\"tools\":[");
    for (parsed.value.array.items) |tool| {
        if (try writeAnthropicTool(writer, tool, count != 0)) count += 1;
    }
    for (selected) |schema_json| {
        var extra = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch continue;
        defer extra.deinit();
        if (try writeAnthropicTool(writer, extra.value, count != 0)) count += 1;
    }
    try writer.writeByte(']');
}

fn writeAnthropicTool(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const name = value.object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const schema = value.object.get("inputSchema") orelse value.object.get("parameters") orelse return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (value.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"input_schema\":");
    try std.json.Stringify.value(schema, .{}, writer);
    try writer.writeByte('}');
    return true;
}

fn streamCompletion(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    var result = streamCompletionCore(raw, alloc, request) catch |err| {
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
        if (self.request) |*http_request| http_request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const http_request = self.request.?;
        self.request = null;
        return http_request;
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

fn streamCompletionCore(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const kind = kindOf(raw);
    const expected = opencode_models.requiredSource(kind);
    if (request.credential_source != expected) return error.OpenCodeCredentialRequired;
    try validateModel(request.model);
    const model = opencode_models.stripModelPrefix(kind, request.model);
    const family = opencode_models.familyForModel(kind, model);
    const request_endpoint = try opencode_models.inferenceUrlAlloc(alloc, kind, model, family);
    defer alloc.free(request_endpoint);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth_header);
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [3]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
    extra_count += 1;

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
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
            .ownership = .owned,
        };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const completion = try consumeSse(
        alloc,
        family,
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
        .generation_origin = opencode_models.inferenceBaseUrl(kind),
        .ownership = .owned,
    };
}

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

fn consumeSse(
    alloc: Allocator,
    family: opencode_models.EndpointFamily,
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

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    var aggregate: usize = 0;
    var events: usize = 0;

    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') {
            const raw_line = std.mem.trim(u8, line.items, " \r");
            if (raw_line.len == 0) {
                line.clearRetainingCapacity();
                continue;
            }
            if (std.mem.eql(u8, raw_line, "data: [DONE]")) break;
            if (std.mem.startsWith(u8, raw_line, "data:")) {
                const payload = std.mem.trim(u8, raw_line["data:".len..], " ");
                if (payload.len > 0) {
                    events += 1;
                    if (events > 100_000) return error.OpenCodeStreamTooLarge;
                    aggregate += payload.len;
                    if (aggregate > max_sse_aggregate_bytes) return error.OpenCodeStreamTooLarge;
                    try applySseEvent(
                        alloc,
                        family,
                        payload,
                        &content,
                        &tools,
                        callback_ctx,
                        on_content_chunk,
                        on_tool_start,
                        on_reasoning_chunk,
                        on_tool_input_chunk,
                        content_capture_limit,
                    );
                }
            }
            line.clearRetainingCapacity();
            continue;
        }
        if (line.items.len >= max_sse_line_bytes) return error.OpenCodeStreamTooLarge;
        try line.append(alloc, byte);
    }

    var owned_tools = try alloc.alloc(types.ToolCall, tools.items.len);
    errdefer alloc.free(owned_tools);
    var tool_index: usize = 0;
    errdefer {
        while (tool_index > 0) {
            tool_index -= 1;
            alloc.free(@constCast(owned_tools[tool_index].id));
            alloc.free(@constCast(owned_tools[tool_index].name));
            alloc.free(@constCast(owned_tools[tool_index].arguments_json));
        }
    }
    for (tools.items) |*tool| {
        owned_tools[tool_index] = .{
            .id = try tool.id.toOwnedSlice(alloc),
            .name = try tool.name.toOwnedSlice(alloc),
            .arguments_json = try tool.arguments.toOwnedSlice(alloc),
        };
        tool_index += 1;
    }

    return .{
        .content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null,
        .tool_calls = owned_tools,
        .finish_reason = if (owned_tools.len > 0) .tool_calls else .stop,
    };
}

fn applySseEvent(
    alloc: Allocator,
    family: opencode_models.EndpointFamily,
    payload: []const u8,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    content_capture_limit: ?usize,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const object = parsed.value.object;

    switch (family) {
        .chat_completions, .gemini => try applyChatEvent(alloc, object, content, tools, callback_ctx, on_content_chunk, on_tool_start, on_tool_input_chunk, content_capture_limit),
        .responses => try applyResponsesEvent(alloc, object, content, tools, callback_ctx, on_content_chunk, on_tool_start, on_reasoning_chunk, on_tool_input_chunk, content_capture_limit),
        .messages => try applyMessagesEvent(alloc, object, content, tools, callback_ctx, on_content_chunk, on_tool_start, on_tool_input_chunk, content_capture_limit),
    }
}

fn appendCaptured(alloc: Allocator, dest: *std.ArrayList(u8), text: []const u8, limit: ?usize) !void {
    if (text.len == 0) return;
    if (limit) |max| {
        if (dest.items.len >= max) return;
        const remain = max - dest.items.len;
        try dest.appendSlice(alloc, text[0..@min(text.len, remain)]);
        return;
    }
    try dest.appendSlice(alloc, text);
}

fn applyChatEvent(
    alloc: Allocator,
    object: std.json.ObjectMap,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    content_capture_limit: ?usize,
) !void {
    const choices = object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;
    const delta = choice.object.get("delta") orelse choice.object.get("message") orelse return;
    if (delta != .object) return;
    if (delta.object.get("content")) |value| if (value == .string and value.string.len > 0) {
        on_content_chunk(callback_ctx, value.string);
        try appendCaptured(alloc, content, value.string, content_capture_limit);
    };
    const tool_calls = delta.object.get("tool_calls") orelse return;
    if (tool_calls != .array) return;
    for (tool_calls.array.items) |item| {
        if (item != .object) continue;
        const index_value = item.object.get("index");
        const index: usize = if (index_value != null and index_value.? == .integer)
            @intCast(@max(index_value.?.integer, 0))
        else
            tools.items.len;
        while (tools.items.len <= index) {
            if (tools.items.len >= max_tool_calls) return error.OpenCodeToolCallLimitExceeded;
            try tools.append(alloc, .{});
        }
        const tool = &tools.items[index];
        if (item.object.get("id")) |id| if (id == .string and id.string.len > 0 and tool.id.items.len == 0) {
            if (id.string.len > max_tool_identity_bytes) return error.OpenCodeToolCallLimitExceeded;
            try tool.id.appendSlice(alloc, id.string);
        };
        if (item.object.get("function")) |function| if (function == .object) {
            if (function.object.get("name")) |name| if (name == .string and name.string.len > 0 and tool.name.items.len == 0) {
                if (name.string.len > max_tool_identity_bytes) return error.OpenCodeToolCallLimitExceeded;
                try tool.name.appendSlice(alloc, name.string);
            };
            if (function.object.get("arguments")) |arguments| if (arguments == .string and arguments.string.len > 0) {
                if (tool.arguments.items.len + arguments.string.len > max_tool_arguments_bytes)
                    return error.OpenCodeToolCallLimitExceeded;
                try tool.arguments.appendSlice(alloc, arguments.string);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, arguments.string);
            };
        };
        if (!tool.announced and tool.id.items.len > 0 and tool.name.items.len > 0) {
            if (on_tool_start) |callback| callback(callback_ctx, tool.id.items, tool.name.items, null);
            tool.announced = true;
        }
    }
}

fn applyResponsesEvent(
    alloc: Allocator,
    object: std.json.ObjectMap,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    content_capture_limit: ?usize,
) !void {
    const typ = if (object.get("type")) |value| if (value == .string) value.string else "" else "";
    if (std.mem.eql(u8, typ, "response.output_text.delta") or std.mem.eql(u8, typ, "response.text.delta")) {
        const delta = object.get("delta") orelse return;
        if (delta == .string and delta.string.len > 0) {
            on_content_chunk(callback_ctx, delta.string);
            try appendCaptured(alloc, content, delta.string, content_capture_limit);
        }
        return;
    }
    if (std.mem.eql(u8, typ, "response.reasoning.delta") or std.mem.eql(u8, typ, "response.reasoning_summary_text.delta")) {
        const delta = object.get("delta") orelse return;
        if (delta == .string and delta.string.len > 0) {
            if (on_reasoning_chunk) |callback| callback(callback_ctx, delta.string);
        }
        return;
    }
    if (std.mem.eql(u8, typ, "response.output_item.added")) {
        const item = object.get("item") orelse return;
        if (item != .object) return;
        const item_type = if (item.object.get("type")) |value| if (value == .string) value.string else "" else "";
        if (!std.mem.eql(u8, item_type, "function_call")) return;
        if (tools.items.len >= max_tool_calls) return error.OpenCodeToolCallLimitExceeded;
        var tool = ToolAccumulator{};
        if (item.object.get("call_id") orelse item.object.get("id")) |id| if (id == .string) {
            try tool.id.appendSlice(alloc, id.string);
        };
        if (item.object.get("name")) |name| if (name == .string) {
            try tool.name.appendSlice(alloc, name.string);
        };
        if (tool.id.items.len > 0 and tool.name.items.len > 0) {
            if (on_tool_start) |callback| callback(callback_ctx, tool.id.items, tool.name.items, null);
            tool.announced = true;
        }
        try tools.append(alloc, tool);
        return;
    }
    if (std.mem.eql(u8, typ, "response.function_call_arguments.delta")) {
        const delta = object.get("delta") orelse return;
        if (delta != .string or delta.string.len == 0 or tools.items.len == 0) return;
        const tool = &tools.items[tools.items.len - 1];
        if (tool.arguments.items.len + delta.string.len > max_tool_arguments_bytes)
            return error.OpenCodeToolCallLimitExceeded;
        try tool.arguments.appendSlice(alloc, delta.string);
        if (on_tool_input_chunk) |callback| callback(callback_ctx, delta.string);
    }
}

fn applyMessagesEvent(
    alloc: Allocator,
    object: std.json.ObjectMap,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    content_capture_limit: ?usize,
) !void {
    const typ = if (object.get("type")) |value| if (value == .string) value.string else "" else "";
    if (std.mem.eql(u8, typ, "content_block_delta")) {
        const delta = object.get("delta") orelse return;
        if (delta != .object) return;
        if (delta.object.get("text")) |text| if (text == .string and text.string.len > 0) {
            on_content_chunk(callback_ctx, text.string);
            try appendCaptured(alloc, content, text.string, content_capture_limit);
        };
        if (delta.object.get("partial_json")) |partial| if (partial == .string and partial.string.len > 0 and tools.items.len > 0) {
            const tool = &tools.items[tools.items.len - 1];
            try tool.arguments.appendSlice(alloc, partial.string);
            if (on_tool_input_chunk) |callback| callback(callback_ctx, partial.string);
        };
        return;
    }
    if (std.mem.eql(u8, typ, "content_block_start")) {
        const block = object.get("content_block") orelse return;
        if (block != .object) return;
        const block_type = if (block.object.get("type")) |value| if (value == .string) value.string else "" else "";
        if (!std.mem.eql(u8, block_type, "tool_use")) return;
        if (tools.items.len >= max_tool_calls) return error.OpenCodeToolCallLimitExceeded;
        var tool = ToolAccumulator{};
        if (block.object.get("id")) |id| if (id == .string) try tool.id.appendSlice(alloc, id.string);
        if (block.object.get("name")) |name| if (name == .string) try tool.name.appendSlice(alloc, name.string);
        if (tool.id.items.len > 0 and tool.name.items.len > 0) {
            if (on_tool_start) |callback| callback(callback_ctx, tool.id.items, tool.name.items, null);
            tool.announced = true;
        }
        try tools.append(alloc, tool);
    }
}

test "OpenCode chat payload includes stream and tools" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{
        .role = .user,
        .content = "hi",
    }};
    const payload = try buildChatCompletionsPayload(alloc, "kimi-k3", .{
        .model = "kimi-k3",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer alloc.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "kimi-k3") != null);
}
