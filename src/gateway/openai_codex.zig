const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
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
const endpoint = "https://chatgpt.com/backend-api/codex/responses";
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
    .stream_fn = streamCompletion,
    .build_request_fn = buildRequestForProvider,
    .project_replay_fn = responses_protocol.selectReplayParts,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAICodexModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAICodexModel;
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
    const projected = try types.projectProviderReplay(alloc, request.messages, .{ .provider = .codex, .model = request.model });
    defer if (projected) |messages| alloc.free(messages);
    if (projected != null) debug_trace.logf("gateway", "provider_replay_omitted provider=codex reason=source_mismatch", .{});

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

    _ = try responses_protocol.writeTools(writer, alloc, request.tools);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    try writer.writeAll(",\"parallel_tool_calls\":true,\"include\":[\"reasoning.encrypted_content\"]");
    // Codex exposes Fast mode as its priority service tier for supported
    // ChatGPT subscription models.
    if (request.provider_options.fast) try writer.writeAll(",\"service_tier\":\"priority\"");

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
        error.ProviderStateTooLarge => error.OpenAICodexProviderStateTooLarge,
        error.InvalidProviderState => error.InvalidOpenAICodexProviderState,
        error.ToolCallLimitExceeded => error.OpenAICodexToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.OpenAICodexToolArgumentsTooLarge,
        else => err,
    };
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (request.credential.credentialSource() != .chatgpt_subscription and
        request.credential.credentialSource() != .host_managed)
    {
        return stream_provider.failResult(error.CodexSubscriptionCredentialRequired);
    }
    try validateModel(request.model);
    const payload = request.prepared_request_body orelse
        try buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    var operation = PreparedStreamOperation{
        .alloc = alloc,
        .request = request,
        .payload = payload,
    };
    return (if (request.deadline) |deadline|
        gateway_client.runBoundedHttpOperation(
            stream_provider.Result,
            alloc,
            request.cancel_flag,
            deadline,
            &operation,
        )
    else
        operation.run()) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
}

const PreparedStreamOperation = struct {
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,

    pub fn run(self: *@This()) !stream_provider.Result {
        return streamPrepared(self.alloc, self.request, self.payload);
    }
};

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
    account_id: ?[]u8 = null,

    fn deinit(self: *RequestAuthHeaders, alloc: Allocator) void {
        if (self.authorization) |value| secret.zeroAndFree(alloc, value);
        if (self.account_id) |value| alloc.free(value);
        self.* = .{};
    }
};

fn requestAuthHeaders(alloc: Allocator, auth: stream_provider.CredentialLease) !RequestAuthHeaders {
    return switch (auth) {
        .host_managed => .{},
        .direct => |direct| blk: {
            const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{direct.secret_bytes});
            errdefer secret.zeroAndFree(alloc, authorization);
            const account_id = if (direct.account_id) |account|
                try alloc.dupe(u8, account)
            else
                try chatgpt_oauth.extractAccountId(alloc, direct.secret_bytes);
            errdefer alloc.free(account_id);
            if (!types.validCredentialAccountId(account_id)) {
                return error.InvalidChatGptSubscriptionAccount;
            }
            break :blk .{
                .authorization = authorization,
                .account_id = account_id,
            };
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
            return stream_provider.failResult(error.InvalidE2EOpenAICodexEndpoint);
        }
        break :endpoint override;
    } else endpoint;
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [7]std.http.Header = undefined;
    var extra_count: usize = 0;
    if (auth_headers.account_id) |account_id| {
        extra_headers_buf[extra_count] = .{ .name = "chatgpt-account-id", .value = account_id };
        extra_count += 1;
    }
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
        .auth_header = auth_headers.authorization,
        .extra_headers = extra_headers_buf[0..extra_count],
    };
    const connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
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
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenAI Codex error response exceeded the local limit"),
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
        .{},
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
            .codex,
            request.model,
            @max(io_mod.milliTimestamp(), 0),
            completion.usage,
        ) orelse break :usage .{ .unavailable = .possibly_billed };
        break :usage .{ .exact = .codex };
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
    limits: CodexLimits,
) !types.ModelCompletion {
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sse: sse_stream.Reader = .{ .max_event_bytes = max_sse_line_bytes };
    defer sse.deinit(alloc);
    const callbacks = responses_protocol.StreamCallbacks{
        .context = callback_ctx,
        .on_content = on_content_chunk,
        .on_tool_start = on_tool_start,
        .on_reasoning = on_reasoning_chunk,
        .on_tool_input = on_tool_input_chunk,
    };
    const stream_limits = responses_protocol.StreamLimits{
        .aggregate_bytes = limits.aggregate_bytes,
        .events = limits.events,
        .tool_calls = limits.tool_calls,
        .tool_identity_bytes = limits.tool_identity_bytes,
        .tool_arguments_bytes = limits.tool_arguments_bytes,
        .provider_state_bytes = limits.provider_state_bytes,
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
        error.EventTooLarge => error.OpenAICodexSseEventTooLarge,
        error.InvalidEvent => error.InvalidOpenAICodexSseEvent,
        error.StreamIncomplete => error.OpenAICodexStreamIncomplete,
        error.ToolCallLimitExceeded => error.OpenAICodexToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.OpenAICodexToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.OpenAICodexResourceLimitExceeded,
        else => err,
    };
}

test "OpenAI Codex request uses Responses input and converts AI SDK tool schemas" {
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
            .provider_replay = .{ .source = .{ .provider = .codex, .model = "gpt-5.4" }, .parts_json = "[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}]" },
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.4",
        .instructions = &instructions,
        .messages = &messages,
        .tools = .{ .additional_functions = &.{read_file_schema} },
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high"), .fast = true },
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.4\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"Be concise.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"encrypted_content\":\"opaque\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\",\"properties\":{}}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":{\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\":\"priority\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\"") == null);
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
    return buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
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
            .provider_replay = .{ .source = .{ .provider = .codex, .model = "gpt-5.6-sol" }, .parts_json = provider_state },
        }};
        try expectOpenAICodexReplaySuccess(&messages);
    }
    {
        const provider_state = try makeSizedProviderState(std.testing.allocator, max_provider_state_bytes + 1);
        defer std.testing.allocator.free(provider_state);
        const messages = [_]types.ChatMessage{.{
            .role = .assistant,
            .provider_replay = .{ .source = .{ .provider = .codex, .model = "gpt-5.6-sol" }, .parts_json = provider_state },
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
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
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
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
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
            .credential = .{ .direct = .{ .secret_bytes = "gateway-key", .source = .ai_gateway_api_key } },
            .model = "gpt-5.6-sol",
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

test "host-managed Codex request auth omits bearer and account headers" {
    var headers = try requestAuthHeaders(std.testing.allocator, .host_managed);
    defer headers.deinit(std.testing.allocator);

    try std.testing.expect(headers.authorization == null);
    try std.testing.expect(headers.account_id == null);
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

fn consumeOpenAICodexTestSse(sse_text: []const u8, limits: CodexLimits) !types.ModelCompletion {
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

fn freeOpenAICodexTestCompletion(completion: types.ModelCompletion) void {
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
    try std.testing.expectEqual(@as(usize, 7), try responses_protocol.checkedAccumulatedSize(6, 1, 7));
    try std.testing.expectError(
        error.ResourceLimitExceeded,
        responses_protocol.checkedAccumulatedSize(std.math.maxInt(usize), 1, std.math.maxInt(usize)),
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
