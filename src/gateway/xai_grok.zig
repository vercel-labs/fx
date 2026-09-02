const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const grok_session = @import("../core/auth/grok_session.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const responses_protocol = @import("responses_protocol.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");

const Allocator = std.mem.Allocator;
const endpoint = "https://cli-chat-proxy.grok.com/v1/responses";
// The proxy gates this as Grok wire compatibility; fx identifies itself separately below.
const proxy_compatibility_version = "1.0.6";
const e2e_endpoint_env = "FX_E2E_XAI_GROK_RESPONSES_URL";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_provider_state_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
    .build_request_fn = buildRequestForProvider,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidXaiGrokModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidXaiGrokModel;
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
    try writeResponsesInput(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');

    const tool_count = try responses_protocol.writeTools(writer, alloc, request.tools);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
        try writer.writeAll(",\"parallel_tool_calls\":true");
    }
    try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    try writer.writeAll(",\"text\":{\"verbosity\":\"low\"");
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}");
    }
    try writer.writeByte('}');

    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeAll(",\"summary\":\"auto\"}");
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn buildRequestForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.RequestData,
) anyerror![]u8 {
    return buildRequest(alloc, request);
}

fn writeResponsesInput(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    return responses_protocol.writeInput(writer, alloc, messages, images, .{
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    }) catch |err| switch (err) {
        error.ProviderStateTooLarge => error.XaiGrokProviderStateTooLarge,
        error.InvalidProviderState => error.InvalidXaiGrokProviderState,
        error.ToolCallLimitExceeded => error.XaiGrokToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.XaiGrokToolArgumentsTooLarge,
        else => err,
    };
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (request.credential.credentialSource() != .grok_subscription and
        request.credential.credentialSource() != .host_managed)
    {
        return stream_provider.failResult(error.GrokSubscriptionCredentialRequired);
    }
    if (request.credential.credentialSource() != .host_managed) {
        const account_id = request.credential.accountId() orelse
            return stream_provider.failResult(error.GrokSubscriptionAccountRequired);
        if (!grok_session.validAccountId(account_id)) {
            return stream_provider.failResult(error.InvalidGrokSubscriptionAccount);
        }
    }
    try validateModel(request.model);
    const payload = request.prepared_request_body orelse
        try buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    var result = streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
        if (requestDeadlineExpired(request)) return stream_provider.failResult(error.Timeout);
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return stream_provider.failResult(error.Timeout);
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
    auth_header: ?[]const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        var headers: std.http.Client.Request.Headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = gateway_client.user_agent },
        };
        if (self.auth_header) |authorization| {
            headers.authorization = .{ .override = authorization };
        }
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = headers,
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

const RequestAuthHeaders = struct {
    authorization: ?[]u8 = null,
    account_id: ?[]const u8 = null,
    include_subscription_headers: bool = false,

    fn deinit(self: *RequestAuthHeaders, alloc: Allocator) void {
        if (self.authorization) |value| secret.zeroAndFree(alloc, value);
        self.* = .{};
    }
};

fn requestAuthHeaders(alloc: Allocator, auth: stream_provider.CredentialLease) !RequestAuthHeaders {
    return switch (auth) {
        .host_managed => .{},
        .direct => |direct| .{
            .authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{direct.secret_bytes}),
            .account_id = direct.account_id,
            .include_subscription_headers = true,
        },
    };
}

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    var auth_headers = try requestAuthHeaders(alloc, request.credential);
    defer auth_headers.deinit(alloc);
    const request_endpoint = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) {
            return stream_provider.failResult(error.InvalidE2EXaiGrokEndpoint);
        }
        break :endpoint override;
    } else endpoint;
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [8]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    if (auth_headers.include_subscription_headers) {
        extra_headers_buf[extra_count] = .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" };
        extra_count += 1;
        extra_headers_buf[extra_count] = .{ .name = "x-authenticateresponse", .value = "authenticate-response" };
        extra_count += 1;
    }
    extra_headers_buf[extra_count] = .{ .name = "x-grok-client-version", .value = proxy_compatibility_version };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-grok-client-identifier", .value = "fx" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-grok-model-override", .value = request.model };
    extra_count += 1;
    if (auth_headers.account_id) |account_id| {
        extra_headers_buf[extra_count] = .{ .name = "x-grok-user-id", .value = account_id };
        extra_count += 1;
    }
    if (request.session_id) |session_id| if (session_id.len > 0) {
        extra_headers_buf[extra_count] = .{ .name = "x-grok-conv-id", .value = session_id };
        extra_count += 1;
    };

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_headers.authorization,
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
            error.StreamTooLong => try alloc.dupe(u8, "xAI Grok error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "xAI Grok error response exceeded the local limit");
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
    var completion = try consumeSse(
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
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }
    const usage_outcome: stream_provider.UsageOutcome = usage: {
        if (completion.generation_id == null) {
            break :usage .{ .unavailable = .possibly_billed };
        }
        completion.billing = try responses_protocol.buildSubscriptionBilling(
            alloc,
            .grok,
            request.model,
            @max(io_mod.milliTimestamp(), 0),
            completion.usage,
        ) orelse break :usage .{ .unavailable = .possibly_billed };
        break :usage .{ .exact = .grok };
    };
    return .{ .completed = .{
        .completion = completion,
        .usage = usage_outcome,
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
            self.aggregate_bytes = responses_protocol.checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            ) catch return error.XaiGrokResourceLimitExceeded;
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
                    if (buffered.len == 0) return error.XaiGrokSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.XaiGrokSseEventTooLarge;
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
                return error.XaiGrokSseEventTooLarge;
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
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    const callbacks = responses_protocol.StreamCallbacks{
        .context = callback_ctx,
        .on_content = on_content_chunk,
        .on_tool_start = on_tool_start,
        .on_reasoning = on_reasoning_chunk,
        .on_tool_input = on_tool_input_chunk,
    };
    const stream_limits = responses_protocol.StreamLimits{
        .aggregate_bytes = max_sse_aggregate_bytes,
        .count_json_bytes = false,
        .events = max_sse_events,
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    };
    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (reducer.applyJson(
            alloc,
            json_text,
            callbacks,
            cancel_flag,
            content_capture_limit,
            stream_limits,
        ) catch |err| return mapReducerError(err)) break;
    }
    return reducer.finish(alloc, cancel_flag, stream_limits) catch |err|
        return mapReducerError(err);
}

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidEvent => error.InvalidXaiGrokSseEvent,
        error.ResponseFailed => error.XaiGrokResponseFailed,
        error.StreamIncomplete => error.XaiGrokStreamIncomplete,
        error.ToolCallLimitExceeded => error.XaiGrokToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.XaiGrokToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.XaiGrokResourceLimitExceeded,
        else => err,
    };
}

test "xAI Grok request uses Responses input and converts AI SDK tool schemas" {
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read",
        .input_schema = .{},
    };
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
    const body = try buildRequest(std.testing.allocator, .{
        .model = "grok-4.20",
        .messages = &messages,
        .tools = .{ .additional_functions = &.{read_file_schema} },
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high"), .fast = true },
        .max_output_tokens = 4096,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"grok-4.20\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"Be concise.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"encrypted_content\":\"opaque\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\",\"properties\":{}}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":{\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\":4096") != null);
}

test "xAI Grok standard requests omit the priority service tier" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "grok-4.20",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"parallel_tool_calls\"") == null);
}

test "xAI Grok serializes each verified image directly once" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "grok-4.20",
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

test "xAI Grok rejects wrong-origin and invalid-account credentials before network I/O" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.GrokSubscriptionCredentialRequired,
        agent_stream_provider.stream(std.testing.allocator, testModelRequest(
            "gateway-key",
            .ai_gateway_api_key,
            null,
            &delivery,
            &evidence,
            &cancelled,
            &callback_context,
        )),
    );
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
    try std.testing.expectError(
        error.GrokSubscriptionAccountRequired,
        agent_stream_provider.stream(std.testing.allocator, testModelRequest(
            "grok-token",
            .grok_subscription,
            null,
            &delivery,
            &evidence,
            &cancelled,
            &callback_context,
        )),
    );
    try std.testing.expectError(
        error.InvalidGrokSubscriptionAccount,
        agent_stream_provider.stream(std.testing.allocator, testModelRequest(
            "grok-token",
            .grok_subscription,
            "acct\r\ninjected",
            &delivery,
            &evidence,
            &cancelled,
            &callback_context,
        )),
    );
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

fn testModelRequest(
    secret_value: []const u8,
    source: types.CredentialSource,
    account_id: ?[]const u8,
    delivery: *stream_provider.DeliveryCertainty,
    evidence: *stream_provider.AttemptEvidence,
    cancelled: *std.atomic.Value(bool),
    callback_context: *u8,
) stream_provider.ModelRequest {
    return .{
        .credential = .{ .direct = .{
            .secret_bytes = secret_value,
            .source = source,
            .account_id = account_id,
        } },
        .model = "grok-4.20",
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .none,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = delivery,
        .attempt_evidence = evidence,
        .events = .{ .context = callback_context, .emit_fn = ignoreTestEvent },
        .admission = .{ .context = callback_context, .admit_fn = admitTestRequest },
        .cancel_flag = cancelled,
    };
}

test "xAI Grok SSE maps text reasoning tools and usage" {
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

const TestResponseMode = enum {
    slow_head,
    stalled_sse,
    error_body_exact,
    error_body_excess,
};

const TestResponseFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    mode: TestResponseMode,
    thread: ?std.Thread = null,
    server_open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    reached_stage: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn init(mode: TestResponseMode) !@This() {
        var fixture: @This() = .{
            .server = undefined,
            .mode = mode,
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
        self.stopping.store(true, .seq_cst);
        const zio = self.io();
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
        self.server_open = false;
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and
                (err == error.SocketNotListening or err == error.BrokenPipe or err == error.ConnectionResetByPeer))
            {
                return;
            }
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        var stream = try self.server.accept(zio);
        defer stream.close(zio);
        try readTestRequest(zio, stream);
        switch (self.mode) {
            .slow_head => {},
            .stalled_sse => try writeTestBytes(
                zio,
                stream,
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/event-stream\r\n" ++
                    "Connection: close\r\n\r\n" ++
                    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n",
            ),
            .error_body_exact => {
                try writeTestErrorResponse(zio, stream, max_error_body_bytes);
                self.reached_stage.store(true, .seq_cst);
                return;
            },
            .error_body_excess => {
                try writeTestErrorResponse(zio, stream, max_error_body_bytes + 1);
                self.reached_stage.store(true, .seq_cst);
                return;
            },
        }
        self.reached_stage.store(true, .seq_cst);
        while (!self.stopping.load(.seq_cst)) {
            var sleep_io: std.Io.Threaded = .init_single_threaded;
            sleep_io.io().sleep(.fromMilliseconds(5), .real) catch {};
        }
    }
};

fn readTestRequest(zio: std.Io, stream: std.Io.net.Stream) !void {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(zio, &socket_buffer);
    var request: [16 * 1024]u8 = undefined;
    var header_len: usize = 0;
    while (header_len < request.len) {
        request[header_len] = try reader.interface.takeByte();
        header_len += 1;
        if (!std.mem.endsWith(u8, request[0..header_len], "\r\n\r\n")) continue;
        const headers = request[0 .. header_len - 4];
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            const prefix = "content-length:";
            if (line.len < prefix.len or !std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) continue;
            const length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " \t"), 10);
            try reader.interface.discardAll(length);
            return;
        }
        return;
    }
    return error.TestRequestTooLarge;
}

fn writeTestBytes(zio: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(zio, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeTestErrorResponse(zio: std.Io, stream: std.Io.net.Stream, body_bytes: usize) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var writer = stream.writer(zio, &buffer);
    try writer.interface.print(
        "HTTP/1.1 429 Too Many Requests\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body_bytes},
    );
    try writer.interface.splatByteAll('e', body_bytes);
    try writer.interface.flush();
}

var stable_xai_test_environ: ?*std.process.Environ.Map = null;

fn stableXaiTestEnviron() !*const std.process.Environ.Map {
    if (stable_xai_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_xai_test_environ = map;
    return map;
}

const XaiTestEnvironment = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, responses_url: []const u8) !*@This() {
        _ = try stableXaiTestEnviron();
        const self = try alloc.create(@This());
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put(e2e_endpoint_env, responses_url);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *@This()) void {
        if (stable_xai_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn runXaiTestStream(deadline: ?std.Io.Clock.Timestamp) !stream_provider.Result {
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    var request = testModelRequest(
        "grok-test-token",
        .grok_subscription,
        "acct_grok_test",
        &delivery,
        &evidence,
        &cancelled,
        &callback_context,
    );
    request.content_capture_limit = 1024;
    request.deadline = deadline;
    return agent_stream_provider.stream(std.testing.allocator, request);
}

test "xAI Grok request deadline closes slow headers and stalled SSE" {
    inline for (.{ TestResponseMode.slow_head, TestResponseMode.stalled_sse }) |mode| {
        var fixture = try TestResponseFixture.init(mode);
        defer fixture.deinit();
        try fixture.start();
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "http://127.0.0.1:{d}/responses",
            .{fixture.port()},
        );
        defer std.testing.allocator.free(url);
        const environment = try XaiTestEnvironment.install(std.testing.allocator, url);
        defer environment.deinit();

        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(50),
        });
        const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        const result = runXaiTestStream(deadline);
        const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
        fixture.deinit();

        try std.testing.expectError(error.Timeout, result);
        if (fixture.failure) |err| return err;
        try std.testing.expect(fixture.reached_stage.load(.seq_cst));
        try std.testing.expect(elapsed_ms < 1000);
        try std.testing.expect(fixture.thread == null);
    }
}

fn ignoreTestChunk(_: *anyopaque, _: []const u8) void {}
fn ignoreTestEvent(_: *anyopaque, _: stream_provider.Event) void {}
fn admitTestRequest(_: *anyopaque) !void {}

test "host-managed Grok request auth omits bearer and subscription headers" {
    var headers = try requestAuthHeaders(std.testing.allocator, .host_managed);
    defer headers.deinit(std.testing.allocator);

    try std.testing.expect(headers.authorization == null);
    try std.testing.expect(headers.account_id == null);
    try std.testing.expect(!headers.include_subscription_headers);
}

test "xAI Grok error-body reader accepts the exact bound and replaces one beyond" {
    inline for (.{ TestResponseMode.error_body_exact, TestResponseMode.error_body_excess }) |mode| {
        var fixture = try TestResponseFixture.init(mode);
        defer fixture.deinit();
        try fixture.start();
        const url = try std.fmt.allocPrint(
            std.testing.allocator,
            "http://127.0.0.1:{d}/responses",
            .{fixture.port()},
        );
        defer std.testing.allocator.free(url);
        const environment = try XaiTestEnvironment.install(std.testing.allocator, url);
        defer environment.deinit();

        var result = try runXaiTestStream(null);
        defer result.deinit(std.testing.allocator);
        fixture.deinit();
        if (fixture.failure) |err| return err;
        try std.testing.expectEqual(stream_provider.FailureKind.rate_limited, result.failed.kind);
        if (mode == .error_body_exact) {
            try std.testing.expectEqual(max_error_body_bytes, result.failed.detail.?.len);
        } else {
            try std.testing.expectEqualStrings(
                "xAI Grok error response exceeded the local limit",
                result.failed.detail.?,
            );
        }
    }
}

fn deinitTestCompletion(completion: *types.ModelCompletion) void {
    if (completion.content) |value| std.testing.allocator.free(@constCast(value));
    if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
    types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
    completion.* = .{};
}

fn consumeTestSse(bytes: []const u8) !types.ModelCompletion {
    var reader: std.Io.Reader = .fixed(bytes);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    return consumeSse(
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
}

fn expectTestSseError(expected: anyerror, bytes: []const u8) !void {
    var completion = consumeTestSse(bytes) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer deinitTestCompletion(&completion);
    return error.TestExpectedResourceLimit;
}

fn buildEventCountSse(alloc: Allocator, event_count: usize) ![]u8 {
    const terminal_json = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}";
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (1..event_count) |_| try out.writer.writeAll("data: {}\n\n");
    try out.writer.writeAll("data: ");
    try out.writer.writeAll(terminal_json);
    try out.writer.writeAll("\n\n");
    return out.toOwnedSlice();
}

fn buildIgnoredAggregateSse(alloc: Allocator, wire_bytes: usize) ![]u8 {
    const mixed_ignored_and_data = ": keepalive\n\nretry: 1000\ndata: {}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n";
    if (wire_bytes < mixed_ignored_and_data.len + terminal.len) return error.NoSpaceLeft;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(mixed_ignored_and_data);
    var remaining = wire_bytes - mixed_ignored_and_data.len - terminal.len;
    while (remaining > 0) {
        const line_wire_bytes = @min(remaining, max_sse_line_bytes + 1);
        if (line_wire_bytes > 1) {
            try out.writer.writeByte(':');
            try out.writer.splatByteAll('a', line_wire_bytes - 2);
        }
        try out.writer.writeByte('\n');
        remaining -= line_wire_bytes;
    }
    try out.writer.writeAll(terminal);
    return out.toOwnedSlice();
}

fn buildToolArgumentsSse(alloc: Allocator, argument_bytes: usize) ![]u8 {
    const chunk_count: usize = 8;
    const delta_prefix = "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"";
    const delta_suffix = "\"}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0," ++
            "\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"terminal\"}}\n\n",
    );
    const bytes_per_chunk = argument_bytes / chunk_count;
    var remainder = argument_bytes % chunk_count;
    for (0..chunk_count) |_| {
        const extra: usize = if (remainder > 0) 1 else 0;
        remainder -|= extra;
        try out.writer.writeAll(delta_prefix);
        try out.writer.splatByteAll('a', bytes_per_chunk + extra);
        try out.writer.writeAll(delta_suffix);
    }
    try out.writer.writeAll(terminal);
    return out.toOwnedSlice();
}

fn buildProviderStateSse(alloc: Allocator, provider_state_bytes: usize) ![]u8 {
    const item_count: usize = 8;
    const event_prefix = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":";
    const item_prefix = "{\"id\":\"rs\",\"type\":\"reasoning\",\"encrypted_content\":\"";
    const item_suffix = "\"}";
    const event_suffix = "}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    const framing_bytes = 2 + (item_count - 1) + item_count * (item_prefix.len + item_suffix.len);
    const content_bytes = provider_state_bytes - framing_bytes;
    const bytes_per_item = content_bytes / item_count;
    var remainder = content_bytes % item_count;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (0..item_count) |_| {
        const extra: usize = if (remainder > 0) 1 else 0;
        remainder -|= extra;
        try out.writer.writeAll(event_prefix);
        try out.writer.writeAll(item_prefix);
        try out.writer.splatByteAll('a', bytes_per_item + extra);
        try out.writer.writeAll(item_suffix);
        try out.writer.writeAll(event_suffix);
    }
    try out.writer.writeAll(terminal);
    return out.toOwnedSlice();
}

test "xAI Grok SSE reader accepts the exact line bound and rejects one beyond" {
    inline for (.{ max_sse_line_bytes, max_sse_line_bytes + 1 }) |line_bytes| {
        const bytes = try std.testing.allocator.alloc(u8, line_bytes + 1);
        defer std.testing.allocator.free(bytes);
        @memcpy(bytes[0.."data: ".len], "data: ");
        @memset(bytes["data: ".len..line_bytes], 'a');
        bytes[line_bytes] = '\n';
        var reader: std.Io.Reader = .fixed(bytes);
        var sse: SseReader = .{};
        defer sse.deinit(std.testing.allocator);
        if (line_bytes == max_sse_line_bytes) {
            const value = (try sse.next(std.testing.allocator, &reader)).?;
            try std.testing.expectEqual(max_sse_line_bytes - "data: ".len, value.len);
        } else {
            try std.testing.expectError(
                error.XaiGrokSseEventTooLarge,
                sse.next(std.testing.allocator, &reader),
            );
        }
    }
}

test "xAI Grok SSE reducer enforces event and ignored-wire aggregate bounds" {
    const exact_events = try buildEventCountSse(std.testing.allocator, max_sse_events);
    defer std.testing.allocator.free(exact_events);
    var exact_event_completion = try consumeTestSse(exact_events);
    deinitTestCompletion(&exact_event_completion);

    const excess_events = try buildEventCountSse(std.testing.allocator, max_sse_events + 1);
    defer std.testing.allocator.free(excess_events);
    try expectTestSseError(error.XaiGrokResourceLimitExceeded, excess_events);

    const exact_aggregate = try buildIgnoredAggregateSse(std.testing.allocator, max_sse_aggregate_bytes);
    defer std.testing.allocator.free(exact_aggregate);
    try std.testing.expectEqual(max_sse_aggregate_bytes, exact_aggregate.len);
    var exact_aggregate_completion = try consumeTestSse(exact_aggregate);
    deinitTestCompletion(&exact_aggregate_completion);

    const excess_aggregate = try buildIgnoredAggregateSse(std.testing.allocator, max_sse_aggregate_bytes + 1);
    defer std.testing.allocator.free(excess_aggregate);
    try std.testing.expectEqual(max_sse_aggregate_bytes + 1, excess_aggregate.len);
    try expectTestSseError(error.XaiGrokResourceLimitExceeded, excess_aggregate);
}

test "xAI Grok SSE reducer cleans up bounded tool arguments and provider state" {
    const exact_arguments = try buildToolArgumentsSse(std.testing.allocator, max_tool_arguments_bytes);
    defer std.testing.allocator.free(exact_arguments);
    var argument_completion = try consumeTestSse(exact_arguments);
    defer deinitTestCompletion(&argument_completion);
    try std.testing.expectEqual(@as(usize, 1), argument_completion.tool_calls.len);
    try std.testing.expectEqual(max_tool_arguments_bytes, argument_completion.tool_calls[0].arguments_json.len);

    const excess_arguments = try buildToolArgumentsSse(std.testing.allocator, max_tool_arguments_bytes + 1);
    defer std.testing.allocator.free(excess_arguments);
    try expectTestSseError(error.XaiGrokToolArgumentsTooLarge, excess_arguments);

    const exact_state = try buildProviderStateSse(std.testing.allocator, max_provider_state_bytes);
    defer std.testing.allocator.free(exact_state);
    var state_completion = try consumeTestSse(exact_state);
    defer deinitTestCompletion(&state_completion);
    try std.testing.expectEqual(max_provider_state_bytes, state_completion.provider_state_json.?.len);

    const excess_state = try buildProviderStateSse(std.testing.allocator, max_provider_state_bytes + 1);
    defer std.testing.allocator.free(excess_state);
    try expectTestSseError(error.XaiGrokResourceLimitExceeded, excess_state);
}
