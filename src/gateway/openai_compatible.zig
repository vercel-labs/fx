const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 8 * 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

pub const AuthKind = enum {
    bearer,
    modal_proxy,
};

pub const Route = struct {
    id: []const u8,
    wire_model: []const u8,
    endpoint: []const u8,
};

pub const Context = struct {
    provider: model_provider.ProviderId,
    credential_source: types.CredentialSource,
    auth: AuthKind,
    endpoint: []const u8 = "",
    routes: []const Route = &.{},

    fn resolve(self: *const Context, model: []const u8) !struct {
        wire_model: []const u8,
        endpoint: []const u8,
    } {
        if (self.routes.len == 0) {
            try validateModel(model);
            if (self.endpoint.len == 0) return error.OpenAICompatibleEndpointMissing;
            return .{ .wire_model = model, .endpoint = self.endpoint };
        }
        for (self.routes) |route| {
            if (std.mem.eql(u8, model, route.id) or std.mem.eql(u8, model, route.wire_model)) {
                return .{ .wire_model = route.wire_model, .endpoint = route.endpoint };
            }
        }
        return error.OpenAICompatibleModelUnavailable;
    }
};

pub fn provider(context: *const Context) stream_provider.Provider {
    return .{
        .context = @constCast(context),
        .stream_fn = streamCompletion,
    };
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAICompatibleModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAICompatibleModel;
    }
}

pub fn buildRequest(
    alloc: Allocator,
    wire_model: []const u8,
    request: stream_provider.RequestData,
) ![]u8 {
    try validateModel(wire_model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(wire_model, .{}, writer);
    try writer.writeAll(",\"messages\":[");
    var system_text: std.Io.Writer.Allocating = .init(alloc);
    defer system_text.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const content = message.content orelse continue;
        if (content.len == 0) continue;
        if (system_text.written().len > 0) try system_text.writer.writeAll("\n\n");
        try system_text.writer.writeAll(content);
    }
    var wrote_message = false;
    if (system_text.written().len > 0) {
        try writer.writeAll("{\"role\":\"system\",\"content\":");
        try std.json.Stringify.value(system_text.written(), .{}, writer);
        try writer.writeByte('}');
        wrote_message = true;
    }
    for (request.messages, 0..) |message, index| {
        if (message.role == .system) continue;
        if (wrote_message) try writer.writeByte(',');
        try writeMessage(writer, alloc, message, index, request.messages.len, request.verified_images, request.budget);
        wrote_message = true;
    }
    try writer.writeByte(']');

    const tool_count = try writeTools(writer, alloc, request.tools);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
        try writer.writeAll(",\"parallel_tool_calls\":true");
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
    }
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}}");
    return out.toOwnedSlice();
}

fn writeMessage(
    writer: *std.Io.Writer,
    alloc: Allocator,
    message: types.ChatMessage,
    message_index: usize,
    message_count: usize,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    budget: ?stream_provider.BuildBudget,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(@tagName(message.role), .{}, writer);
    switch (message.role) {
        .system => {
            try writer.writeAll(",\"content\":");
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
        },
        .user => {
            const images = if (message_index + 1 == message_count) verified_images else null;
            if (images == null or images.?.len == 0) {
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
            } else {
                try writer.writeAll(",\"content\":[");
                var wrote = false;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote = true;
                };
                for (images.?) |image| {
                    if (wrote) try writer.writeByte(',');
                    try writeImage(writer, image, budget);
                    wrote = true;
                }
                try writer.writeByte(']');
            }
        },
        .assistant => {
            try writer.writeAll(",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            if (message.tool_calls.len > max_tool_calls) return error.OpenAICompatibleToolCallLimitExceeded;
            if (message.tool_calls.len > 0) {
                try writer.writeAll(",\"tool_calls\":[");
                for (message.tool_calls, 0..) |call, index| {
                    if (call.id.len == 0 or call.id.len > max_tool_identity_bytes or
                        call.name.len == 0 or call.name.len > max_tool_identity_bytes)
                    {
                        return error.OpenAICompatibleToolCallLimitExceeded;
                    }
                    if (call.arguments_json.len > max_tool_arguments_bytes) return error.OpenAICompatibleToolArgumentsTooLarge;
                    if (index > 0) try writer.writeByte(',');
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
            try std.json.Stringify.value(message.content orelse "", .{}, writer);
        },
    }
    try writer.writeByte('}');
    _ = alloc;
}

fn writeImage(
    writer: *std.Io.Writer,
    image: image_attachments.VerifiedSnapshot,
    budget: ?stream_provider.BuildBudget,
) !void {
    if (budget) |active| {
        if (active.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    }
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    var offset: usize = 0;
    while (offset < image.bytes.len) {
        if (budget) |active| {
            if (active.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        }
        const end = @min(offset + 3 * 1024, image.bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, image.bytes[offset..end]);
        offset = end;
    }
    try writer.writeAll("\"}}");
}

fn writeTools(writer: *std.Io.Writer, alloc: Allocator, tools: stream_provider.ToolSelection) !usize {
    var scratch: std.Io.Writer.Allocating = .init(alloc);
    defer scratch.deinit();
    try scratch.writer.writeAll(",\"tools\":[");
    var count: usize = 0;
    for (tools.advertised_names) |name| {
        const tool = tools.advertisedFunction(name) orelse continue;
        if (count > 0) try scratch.writer.writeByte(',');
        try writeStaticTool(&scratch.writer, alloc, tool);
        count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try scratch.writer.writeByte(',');
        try writeStaticTool(&scratch.writer, alloc, tool);
        count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try scratch.writer.writeByte(',');
        try scratch.writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(tool.name, .{}, &scratch.writer);
        try scratch.writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, &scratch.writer, tool.description);
        try scratch.writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(tool.input_schema, .{}, &scratch.writer);
        try scratch.writer.writeAll("}}");
        count += 1;
    }
    try scratch.writer.writeByte(']');
    if (count > 0) try writer.writeAll(scratch.written());
    return count;
}

fn writeStaticTool(writer: *std.Io.Writer, alloc: Allocator, tool: model_tool_schema.FunctionSchema) !void {
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(tool.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, tool.description);
    try writer.writeAll(",\"parameters\":");
    try model_tool_schema.writeObjectSchema(alloc, writer, tool.input_schema);
    try writer.writeAll("}}");
}

fn containsName(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, wanted)) return true;
    return false;
}

fn streamCompletion(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    const context: *const Context = @ptrCast(@alignCast(raw.?));
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential.source != context.credential_source) return error.OpenAICompatibleCredentialRequired;
    const route = try context.resolve(request.model);
    const payload = try buildRequest(alloc, route.wire_model, request.data());
    defer alloc.free(payload);
    var result = streamPrepared(alloc, context, route.endpoint, request, payload) catch |err| {
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

    fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: ?[]const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (self.auth_header) |value| .{ .override = value } else .omit,
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamPrepared(
    alloc: Allocator,
    context: *const Context,
    endpoint: []const u8,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    const uri = try std.Uri.parse(endpoint);
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);
    var extra_headers_buf: [3]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    switch (context.auth) {
        .bearer => auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret}),
        .modal_proxy => {
            const token_id = request.credential.account_id orelse return error.ModalProxyTokenIdRequired;
            extra_headers_buf[extra_count] = .{ .name = "Modal-Key", .value = token_id };
            extra_count += 1;
            extra_headers_buf[extra_count] = .{ .name = "Modal-Secret", .value = request.credential.secret };
            extra_count += 1;
        },
    }

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
        .extra_headers = extra_headers_buf[0..extra_count],
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
        connect_deadline = deadline;
    };
    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        if (request.deadline) |deadline|
            try gateway_client.spawnHttpCancelWatcherBounded(&cancel_watch_done, request.cancel_flag, deadline, connection.stream_writer.stream)
        else
            try gateway_client.spawnHttpCancelWatcher(&cancel_watch_done, request.cancel_flag, connection.stream_writer.stream)
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
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "provider error response exceeded the local limit"),
            else => return err,
        };
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .ownership = .owned,
        } };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const completion = try consumeSse(alloc, reader, request);
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }
    return .{ .completed = .{
        .completion = completion,
        .usage = .{ .unavailable = .possibly_billed },
        .ownership = .owned,
    } };
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

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate_bytes = std.math.add(usize, self.aggregate_bytes, line.wire_bytes) catch
                return error.OpenAICompatibleResourceLimitExceeded;
            if (self.aggregate_bytes > max_sse_aggregate_bytes) return error.OpenAICompatibleResourceLimitExceeded;
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

    const Line = struct { bytes: []const u8, wire_bytes: usize };

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenAICompatibleSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) return error.OpenAICompatibleSseEventTooLarge;
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return .{ .bytes = self.pending_line.items, .wire_bytes = self.pending_line.items.len };
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) return error.OpenAICompatibleSseEventTooLarge;
            if (self.pending_line.items.len == 0) return .{ .bytes = fragment, .wire_bytes = fragment.len + 1 };
            try self.pending_line.appendSlice(alloc, fragment);
            return .{ .bytes = self.pending_line.items, .wire_bytes = self.pending_line.items.len + 1 };
        }
    }
};

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    started: bool = false,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

const Reducer = struct {
    content: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ToolAccumulator) = .empty,
    generation_id: ?[]u8 = null,
    finish_reason: ?types.ProviderFinishReason = null,
    usage: types.Usage = .{},
    events_seen: usize = 0,

    fn deinit(self: *Reducer, alloc: Allocator) void {
        self.content.deinit(alloc);
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        if (self.generation_id) |id| alloc.free(id);
    }

    fn ensureTool(self: *Reducer, alloc: Allocator, index: usize) !*ToolAccumulator {
        if (index >= max_tool_calls) return error.OpenAICompatibleToolCallLimitExceeded;
        while (self.tools.items.len <= index) try self.tools.append(alloc, .{});
        return &self.tools.items[index];
    }

    fn apply(self: *Reducer, alloc: Allocator, json_text: []const u8, request: stream_provider.ModelRequest) !void {
        self.events_seen += 1;
        if (self.events_seen > max_sse_events) return error.OpenAICompatibleResourceLimitExceeded;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidOpenAICompatibleSseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidOpenAICompatibleSseEvent;
        const root = parsed.value.object;
        if (root.get("error") != null) return error.OpenAICompatibleResponseFailed;
        if (self.generation_id == null) if (root.get("id")) |id| if (id == .string and id.string.len > 0) {
            self.generation_id = try alloc.dupe(u8, id.string);
        };
        if (root.get("usage")) |usage| {
            if (usage == .object) self.usage = parseUsage(usage.object);
        }
        const choices = root.get("choices") orelse return;
        if (choices != .array) return error.InvalidOpenAICompatibleSseEvent;
        for (choices.array.items) |choice| {
            if (choice != .object) return error.InvalidOpenAICompatibleSseEvent;
            if (choice.object.get("delta")) |delta| {
                if (delta != .object) return error.InvalidOpenAICompatibleSseEvent;
                try self.applyDelta(alloc, delta.object, request);
            }
            if (choice.object.get("finish_reason")) |finish_value| {
                if (finish_value == .string and finish_value.string.len > 0) {
                    self.finish_reason = types.ProviderFinishReason.parse_legacy(finish_value.string) orelse .other;
                }
            }
        }
    }

    fn applyDelta(self: *Reducer, alloc: Allocator, delta: std.json.ObjectMap, request: stream_provider.ModelRequest) !void {
        if (delta.get("content")) |content| if (content == .string and content.string.len > 0) {
            request.events.emit(.{ .content_delta = content.string });
            const limit = request.content_capture_limit orelse std.math.maxInt(usize);
            const remaining = limit -| self.content.items.len;
            try self.content.appendSlice(alloc, content.string[0..@min(remaining, content.string.len)]);
        };
        for ([_][]const u8{ "reasoning_content", "reasoning" }) |key| {
            if (delta.get(key)) |reasoning| if (reasoning == .string and reasoning.string.len > 0) {
                request.events.emit(.{ .reasoning_delta = reasoning.string });
                break;
            };
        }
        const calls = delta.get("tool_calls") orelse return;
        if (calls == .null) return;
        if (calls != .array) return error.InvalidOpenAICompatibleSseEvent;
        for (calls.array.items) |item| {
            if (item != .object) return error.InvalidOpenAICompatibleSseEvent;
            const index_value = item.object.get("index") orelse return error.InvalidOpenAICompatibleSseEvent;
            if (index_value != .integer or index_value.integer < 0) return error.InvalidOpenAICompatibleSseEvent;
            const index = std.math.cast(usize, index_value.integer) orelse return error.InvalidOpenAICompatibleSseEvent;
            const tool = try self.ensureTool(alloc, index);
            if (item.object.get("id")) |id| if (id == .string) {
                if (id.string.len > max_tool_identity_bytes - tool.id.items.len) return error.OpenAICompatibleToolCallLimitExceeded;
                try tool.id.appendSlice(alloc, id.string);
            };
            if (item.object.get("function")) |function| {
                if (function != .object) return error.InvalidOpenAICompatibleSseEvent;
                if (function.object.get("name")) |name| if (name == .string) {
                    if (name.string.len > max_tool_identity_bytes - tool.name.items.len) return error.OpenAICompatibleToolCallLimitExceeded;
                    try tool.name.appendSlice(alloc, name.string);
                };
                if (!tool.started and tool.id.items.len > 0 and tool.name.items.len > 0) {
                    request.events.emit(.{ .tool_started = .{ .id = tool.id.items, .name = tool.name.items } });
                    tool.started = true;
                }
                if (function.object.get("arguments")) |arguments| if (arguments == .string and arguments.string.len > 0) {
                    if (arguments.string.len > max_tool_arguments_bytes - tool.arguments.items.len) return error.OpenAICompatibleToolArgumentsTooLarge;
                    try tool.arguments.appendSlice(alloc, arguments.string);
                    request.events.emit(.{ .tool_input_delta = arguments.string });
                };
            }
        }
    }

    fn finish(self: *Reducer, alloc: Allocator, request: stream_provider.ModelRequest) !types.ModelCompletion {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const owned_tools = try alloc.alloc(types.ToolCall, self.tools.items.len);
        var count: usize = 0;
        errdefer {
            types.freeToolCallSlice(alloc, owned_tools[0..count]);
            if (count < owned_tools.len) alloc.free(owned_tools);
        }
        for (self.tools.items) |*tool| {
            if (tool.id.items.len == 0 or tool.name.items.len == 0) return error.InvalidOpenAICompatibleSseEvent;
            if (!tool.started) request.events.emit(.{ .tool_started = .{ .id = tool.id.items, .name = tool.name.items } });
            const streamed_arguments = if (tool.arguments.items.len == 0) "{}" else tool.arguments.items;
            const argument_integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, streamed_arguments);
            const arguments = if (argument_integrity == .valid) streamed_arguments else "{}";
            owned_tools[count] = .{
                .id = try alloc.dupe(u8, tool.id.items),
                .name = try alloc.dupe(u8, tool.name.items),
                .arguments_json = try alloc.dupe(u8, arguments),
                .argument_integrity = argument_integrity,
            };
            count += 1;
        }
        const content = if (self.content.items.len > 0) try self.content.toOwnedSlice(alloc) else null;
        errdefer if (content) |value| alloc.free(value);
        const generation_id = self.generation_id;
        self.generation_id = null;
        return .{
            .content = content,
            .tool_calls = owned_tools,
            .generation_id = generation_id,
            .finish_reason = self.finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
            .usage = self.usage,
        };
    }
};

fn parseUsage(object: std.json.ObjectMap) types.Usage {
    var usage: types.Usage = .{};
    usage.input_tokens = optionalUnsigned(object.get("prompt_tokens"));
    usage.output_tokens = optionalUnsigned(object.get("completion_tokens"));
    if (object.get("prompt_tokens_details")) |details| if (details == .object) {
        usage.cache_read_tokens = optionalUnsigned(details.object.get("cached_tokens"));
    };
    if (object.get("completion_tokens_details")) |details| if (details == .object) {
        usage.reasoning_tokens = optionalUnsigned(details.object.get("reasoning_tokens"));
    };
    if (usage.reasoning_tokens == null) usage.reasoning_tokens = optionalUnsigned(object.get("reasoning_tokens"));
    return usage;
}

fn optionalUnsigned(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    if (actual != .integer or actual.integer < 0) return null;
    return std.math.cast(u64, actual.integer);
}

fn consumeSse(alloc: Allocator, reader: anytype, request: stream_provider.ModelRequest) !types.ModelCompletion {
    var reducer: Reducer = .{};
    defer reducer.deinit(alloc);
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (request.cooperative_pulse) |pulse| try pulse.pulse();
        try reducer.apply(alloc, json_text, request);
    }
    return reducer.finish(alloc, request);
}

test "OpenAI compatible request serializes messages tools and images" {
    const tool = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read a file",
        .input_schema = .{
            .properties = &.{.{ .name = "path", .json_type = .string }},
            .required = &.{"path"},
            .additional_properties = false,
        },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }} },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
        .{ .role = .user, .content = "Continue." },
    };
    const body = try buildRequest(std.testing.allocator, "served/model", .{
        .model = "alias",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{tool} },
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"served/model\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
}

test "OpenAI compatible reducer maps text reasoning tools and usage" {
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,
        tool_name: std.ArrayList(u8) = .empty,
        tool_input: std.ArrayList(u8) = .empty,

        fn emit(raw: *anyopaque, event: stream_provider.Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .content_delta => |value| self.content.appendSlice(std.testing.allocator, value) catch unreachable,
                .reasoning_delta => |value| self.reasoning.appendSlice(std.testing.allocator, value) catch unreachable,
                .tool_started => |value| self.tool_name.appendSlice(std.testing.allocator, value.name) catch unreachable,
                .tool_input_delta => |value| self.tool_input.appendSlice(std.testing.allocator, value) catch unreachable,
            }
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    defer capture.reasoning.deinit(std.testing.allocator);
    defer capture.tool_name.deinit(std.testing.allocator);
    defer capture.tool_input.deinit(std.testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var reducer: Reducer = .{};
    defer reducer.deinit(std.testing.allocator);
    const request = stream_provider.ModelRequest{
        .credential = .{ .secret = "key" },
        .model = "model",
        .retry_count = 0,
        .messages = &.{},
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &capture, .emit_fn = Capture.emit },
        .cancel_flag = &cancel,
    };
    try reducer.apply(std.testing.allocator, "{\"id\":\"chatcmpl_1\",\"choices\":[{\"delta\":{\"reasoning_content\":\"think\",\"content\":\"hello\",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]},\"finish_reason\":null}]}", request);
    try reducer.apply(std.testing.allocator, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"README.md\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4}}", request);
    const completion = try reducer.finish(std.testing.allocator, request);
    defer {
        if (completion.content) |content| std.testing.allocator.free(@constCast(content));
        if (completion.generation_id) |id| std.testing.allocator.free(@constCast(id));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expectEqualStrings("think", capture.reasoning.items);
    try std.testing.expectEqualStrings("read_file", capture.tool_name.items);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", capture.tool_input.items);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "OpenAI compatible reducer defers malformed tool arguments to agent recovery" {
    const Capture = struct {
        fn emit(_: *anyopaque, _: stream_provider.Event) void {}
    };
    var capture: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var reducer: Reducer = .{};
    defer reducer.deinit(std.testing.allocator);
    const request = stream_provider.ModelRequest{
        .credential = .{ .secret = "key" },
        .model = "model",
        .retry_count = 0,
        .messages = &.{},
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &capture, .emit_fn = Capture.emit },
        .cancel_flag = &cancel,
    };
    try reducer.apply(std.testing.allocator, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]},\"finish_reason\":\"tool_calls\"}]}", request);
    const completion = try reducer.finish(std.testing.allocator, request);
    defer types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));

    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("{}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.malformed_json, completion.tool_calls[0].argument_integrity);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}
