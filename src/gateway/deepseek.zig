const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const responses_protocol = @import("responses_protocol.zig");
const sse_stream = @import("sse.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");

const Allocator = std.mem.Allocator;
const endpoint = "https://api.deepseek.com/responses";
const e2e_endpoint_env = "FX_E2E_DEEPSEEK_RESPONSES_URL";
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
    .project_replay_fn = responses_protocol.selectReplayParts,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidDeepSeekModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidDeepSeekModel;
    }
}

pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    try request.validatePrompt();
    try validateModel(request.model);
    const budget: image_attachments.CaptureBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        .{};
    try budget.check();
    const projected = try types.projectProviderReplay(alloc, request.messages, .{ .provider = .deepseek, .model = request.model });
    defer if (projected) |messages| alloc.free(messages);
    if (projected != null) debug_trace.logf("gateway", "provider_replay_omitted provider=deepseek reason=source_mismatch", .{});

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.instructions) |instruction| {
        const text = instruction.content.?;
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
    try writeResponsesInput(writer, std.heap.c_allocator, projected orelse request.messages, request.verified_images, budget);
    try writer.writeByte(']');

    const tool_count = try responses_protocol.writeTools(writer, alloc, request.tools);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    }
    // DeepSeek ignores unsupported OpenAI fields and never returns encrypted
    // reasoning; the plaintext chain of thought arrives on
    // response.reasoning_text.delta events and reasoning items are replayed
    // verbatim when a request carries tools.
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }
    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeByte('}');
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
    budget: image_attachments.CaptureBudget,
) !void {
    return responses_protocol.writeInput(writer, alloc, messages, images, .{
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    }, budget) catch |err| switch (err) {
        error.ProviderStateTooLarge => error.DeepSeekProviderStateTooLarge,
        error.InvalidProviderState => error.InvalidDeepSeekProviderState,
        error.ToolCallLimitExceeded => error.DeepSeekToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.DeepSeekToolArgumentsTooLarge,
        else => err,
    };
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (request.credential.credentialSource() != .deepseek_api_key and
        request.credential.credentialSource() != .host_managed)
    {
        return stream_provider.failResult(error.DeepSeekApiKeyCredentialRequired);
    }
    if (request.credential.credentialSource() != .host_managed) {
        const direct = request.credential.direct;
        if (direct.secret_bytes.len == 0) {
            return stream_provider.failResult(error.DeepSeekApiKeyCredentialRequired);
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
            return stream_provider.failResult(error.InvalidE2EDeepSeekEndpoint);
        }
        break :endpoint override;
    } else endpoint;
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [4]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;

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
            error.StreamTooLong => try alloc.dupe(u8, "DeepSeek error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "DeepSeek error response exceeded the local limit");
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

fn consumeSse(
    alloc: Allocator,
    reader: *std.Io.Reader,
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
    var sse: sse_stream.Reader = .{ .max_event_bytes = max_sse_line_bytes, .max_total_bytes = max_sse_aggregate_bytes };
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
    while (sse.next(alloc, reader, cancel_flag) catch |err| return mapReducerError(err)) |json_text| {
        if (std.mem.eql(u8, json_text, "[DONE]")) break;
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
        error.EventTooLarge => error.DeepSeekSseEventTooLarge,
        error.StreamTooLarge => error.DeepSeekResourceLimitExceeded,
        error.InvalidEvent => error.InvalidDeepSeekSseEvent,
        error.StreamIncomplete => error.DeepSeekStreamIncomplete,
        error.ToolCallLimitExceeded => error.DeepSeekToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.DeepSeekToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.DeepSeekResourceLimitExceeded,
        else => err,
    };
}

test "DeepSeek request uses Responses input and converts AI SDK tool schemas" {
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read",
        .input_schema = .{},
    };
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "Be concise." }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
            .provider_replay = .{ .source = .{ .provider = .deepseek, .model = "deepseek-v4-flash" }, .parts_json = "[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"Let me read it.\"}],\"summary\":[],\"encrypted_content\":\"rs-1\"}]" },
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try buildRequest(std.testing.allocator, .{
        .model = "deepseek-v4-flash",
        .instructions = &instructions,
        .messages = &messages,
        .tools = .{ .additional_functions = &.{read_file_schema} },
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
        .max_output_tokens = 4096,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"deepseek-v4-flash\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"Be concise.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"reasoning\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_text\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\",\"properties\":{}}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":{\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\":4096") != null);
    // DeepSeek never receives OpenAI encrypted-reasoning include or service
    // tier fields: reasoning is plaintext on its own delta events.
    try std.testing.expect(std.mem.find(u8, body, "\"include\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"parallel_tool_calls\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"verbosity\"") == null);
}

test "DeepSeek standard requests omit tool choice and reasoning when unset" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "deepseek-v4-flash",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"include\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"parallel_tool_calls\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"verbosity\"") == null);
}

test "DeepSeek serializes each verified image directly once" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "deepseek-v4-flash-vision-exp",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
        .verified_images = &images,
    });
    defer std.testing.allocator.free(body);

    const marker = "\"type\":\"input_image\"";
    const start = std.mem.indexOf(u8, body, marker).?;
    try std.testing.expect(std.mem.indexOfPos(u8, body, start + marker.len, marker) == null);
    try std.testing.expect(std.mem.find(u8, body, "\"detail\":\"auto\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
}

test "DeepSeek rejects a wrong-origin credential before network I/O" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.DeepSeekApiKeyCredentialRequired,
        agent_stream_provider.stream(std.testing.allocator, .{
            .credential = .{ .direct = .{ .secret_bytes = "gateway-key", .source = .ai_gateway_api_key } },
            .model = "deepseek-v4-flash",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .none,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &evidence,
            .events = .{ .context = &callback_context, .emit_fn = struct {
                fn ignore(_: *anyopaque, _: stream_provider.Event) void {}
            }.ignore },
            .cancel_flag = &cancelled,
        }),
    );
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

test "DeepSeek rejects an empty direct credential before network I/O" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.DeepSeekApiKeyCredentialRequired,
        agent_stream_provider.stream(std.testing.allocator, .{
            .credential = .{ .direct = .{ .secret_bytes = "", .source = .deepseek_api_key } },
            .model = "deepseek-v4-flash",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .none,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &evidence,
            .events = .{ .context = &callback_context, .emit_fn = struct {
                fn ignore(_: *anyopaque, _: stream_provider.Event) void {}
            }.ignore },
            .cancel_flag = &cancelled,
        }),
    );
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

test "host-managed DeepSeek request auth omits the bearer header" {
    var headers = try requestAuthHeaders(std.testing.allocator, .host_managed);
    defer headers.deinit(std.testing.allocator);

    try std.testing.expect(headers.authorization == null);
}

test "DeepSeek SSE maps plaintext reasoning tools and usage" {
    // Mirrors the live event sequence from api.deepseek.com: reasoning text
    // deltas arrive plaintext, every data payload carries a sequence_number,
    // and the stream ends with response.completed carrying the response object.
    const sse_text =
        "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"resp_smoke\",\"status\":\"in_progress\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"sequence_number\":1,\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"status\":\"in_progress\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_text.delta\",\"sequence_number\":2,\"output_index\":0,\"delta\":\"Let me \"}\n\n" ++
        "data: {\"type\":\"response.reasoning_text.delta\",\"sequence_number\":3,\"output_index\":0,\"delta\":\"read it.\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"sequence_number\":4,\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"status\":\"completed\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"Let me read it.\"}],\"summary\":[],\"encrypted_content\":\"resp_smoke-0\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"sequence_number\":5,\"output_index\":1,\"item\":{\"type\":\"message\",\"status\":\"in_progress\",\"phase\":\"final_answer\",\"role\":\"assistant\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":6,\"output_index\":1,\"delta\":\"hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"sequence_number\":7,\"output_index\":1,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"status\":\"completed\",\"phase\":\"commentary\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"annotations\":[],\"text\":\"hello\"}]}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"sequence_number\":8,\"output_index\":2,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"status\":\"in_progress\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"sequence_number\":9,\"output_index\":2,\"delta\":\"{\\\"path\\\":\\\"README.md\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"sequence_number\":10,\"response\":{\"id\":\"resp_smoke\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"output_tokens_details\":{\"reasoning_tokens\":3}}}}\n\n";
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
        if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
        if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expectEqualStrings("Let me read it.", capture.reasoning.items);
    try std.testing.expect(capture.saw_read_file);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), completion.usage.reasoning_tokens);
    try std.testing.expectEqualStrings("resp_smoke", completion.generation_id.?);
    // DeepSeek marks reasoning output items with a placeholder encrypted
    // content string, so the provider state keeps the full plaintext item
    // verbatim for thinking-mode tool-loop pass-back.
    try std.testing.expect(completion.provider_state_json != null);
    try std.testing.expect(std.mem.find(u8, completion.provider_state_json.?, "\"reasoning_text\"") != null);
    try std.testing.expect(std.mem.find(u8, completion.provider_state_json.?, "\"Let me read it.\"") != null);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

fn consumeDeepSeekTestSse(sse_text: []const u8) !types.ModelCompletion {
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
    );
}

fn freeDeepSeekTestCompletion(completion: types.ModelCompletion) void {
    if (completion.content) |value| std.testing.allocator.free(@constCast(value));
    types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
    if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
}

test "DeepSeek SSE completes without a DONE marker and tolerates reasoning-free turns" {
    const terminal_json = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":2,\"output_tokens_details\":{\"reasoning_tokens\":0}}}}";
    const completion = try consumeDeepSeekTestSse("data: " ++ terminal_json ++ "\n\n");
    defer freeDeepSeekTestCompletion(completion);

    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 5), completion.usage.input_tokens);
    try std.testing.expect(completion.generation_id == null);
}
