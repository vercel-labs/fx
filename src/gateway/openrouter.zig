const std = @import("std");
const chat_completions = @import("chat_completions_protocol.zig");
const gateway_client = @import("client.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

const endpoint = "https://openrouter.ai/api/v1/chat/completions";
const e2e_endpoint_env = "FX_E2E_OPENROUTER_CHAT_URL";

/// OpenRouter ranks calling applications by these attribution headers.
const referer_header = "https://github.com/vercel-labs/fx";
const title_header = "fx";

const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidOpenRouterModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenRouterModel;
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

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true");
    // Ask for the token counts and credit cost on the final chunk so usage can
    // be reported exactly instead of deferred to a follow-up lookup.
    try writer.writeAll(",\"usage\":{\"include\":true}");

    try writer.writeAll(",\"messages\":[");
    chat_completions.writeMessages(
        writer,
        alloc,
        request.messages,
        request.verified_images,
        .{
            .tool_calls = max_tool_calls,
            .tool_identity_bytes = max_tool_identity_bytes,
            .tool_arguments_bytes = max_tool_arguments_bytes,
        },
    ) catch |err| return mapSerializeError(err);
    try writer.writeByte(']');

    const tool_count = chat_completions.writeTools(writer, alloc, request.tools) catch |err|
        return mapSerializeError(err);
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(switch (request.tool_choice) {
            .auto => "auto",
            .none => "none",
            .required => "required",
        }, .{}, writer);
        if (request.provider_options.parallel_tool_calls) |parallel| {
            try writer.writeAll(",\"parallel_tool_calls\":");
            try writer.writeAll(if (parallel) "true" else "false");
        }
    }

    if (request.provider_options.reasoning) |effort| {
        if (effort.gatewayValue()) |value| {
            try writer.writeAll(",\"reasoning\":{\"effort\":");
            try std.json.Stringify.value(value, .{}, writer);
            try writer.writeByte('}');
        }
    }
    if (request.max_output_tokens) |limit| {
        try writer.print(",\"max_tokens\":{d}", .{limit});
    }
    if (request.response_format) |format| {
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        if (format.description.len > 0) {
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(format.description, .{}, writer);
        }
        try writer.writeAll(",\"strict\":true,\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll("}}");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn mapSerializeError(err: anyerror) anyerror {
    return switch (err) {
        error.ToolCallLimitExceeded => error.OpenRouterToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.OpenRouterToolArgumentsTooLarge,
        error.InvalidToolSchema => error.InvalidOpenRouterToolSchema,
        else => err,
    };
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential.source != .openrouter_api_key) {
        return error.OpenRouterApiKeyRequired;
    }
    if (request.credential.secret.len == 0) return error.OpenRouterApiKeyRequired;
    try validateModel(request.model);

    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);

    var result = streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (requestDeadlineExpired(request)) return error.Timeout;
        request.attempt_evidence.network_failure =
            gateway_client.networkFailureEvidence(err, request.delivery.load());
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

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret});
    defer secret.zeroAndFree(alloc, auth_header);

    const request_endpoint = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenRouterEndpoint;
        break :endpoint override;
    } else endpoint;
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [4]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "HTTP-Referer", .value = referer_header };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "X-Title", .value = title_header };
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
        return failureResult(alloc, &response);
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    const reduced = try consumeSse(
        alloc,
        reader,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        EventBridge.toolInput,
        request.cancel_flag,
        request.content_capture_limit,
        request.model,
    );
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = reduced.completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }

    // OpenRouter reports token counts and credit cost inline on the terminal
    // chunk, so usage is exact and needs no deferred reconciliation.
    const usage_outcome: stream_provider.UsageOutcome = if (reduced.completion.billing != null)
        .{ .exact = .openrouter }
    else
        .{ .unavailable = .possibly_billed };

    return .{ .completed = .{
        .completion = reduced.completion,
        .usage = usage_outcome,
        .ownership = .owned,
    } };
}

/// Reads a bounded error body and maps the status onto the neutral failure
/// contract. The detail string explains the OpenRouter-specific conditions a
/// user is most likely to hit, especially on the free tier.
fn failureResult(alloc: Allocator, response: *std.http.Client.Response) !stream_provider.Result {
    // Read the headers before the body: consuming the body may reuse the
    // buffer the parsed head points into.
    const status = response.head.status;
    const retry_after = retryAfterSeconds(response);

    var transfer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => try alloc.dupe(u8, "OpenRouter error response exceeded the local limit"),
        else => return err,
    };
    const body = if (bounded_body.len > max_error_body_bytes) body: {
        alloc.free(bounded_body);
        break :body try alloc.dupe(u8, "OpenRouter error response exceeded the local limit");
    } else bounded_body;
    errdefer alloc.free(body);

    const detail = if (statusGuidance(status)) |guidance| detail: {
        const combined = try std.fmt.allocPrint(alloc, "{s} ({s})", .{ guidance, body });
        alloc.free(body);
        break :detail combined;
    } else body;

    return .{ .failed = .{
        .kind = failureKind(status),
        .detail = detail,
        .retry_after_seconds = retry_after,
        .ownership = .owned,
    } };
}

/// Plain-language guidance for the statuses whose OpenRouter meaning is not
/// obvious from the code alone.
///
/// `FailureKind` has no payment-required variant, so a 402 is reported as
/// `forbidden` (correctly non-retryable) and would otherwise surface as
/// "HTTP 403". The guidance names the real upstream status so the message
/// cannot mislead.
fn statusGuidance(status: std.http.Status) ?[]const u8 {
    return switch (status) {
        .payment_required => "OpenRouter returned 402: credit balance is negative; " ++
            "add credits. This blocks free models too",
        .too_many_requests => "OpenRouter rate limit reached. Free models allow " ++
            "20 requests per minute and 50 per day, raised to 1000 per day once " ++
            "you have purchased at least 10 credits",
        .service_unavailable => "No OpenRouter provider currently satisfies the " ++
            "routing requirements for this model",
        else => null,
    };
}

fn retryAfterSeconds(response: *std.http.Client.Response) ?u64 {
    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) continue;
        const trimmed = std.mem.trim(u8, header.value, " \t");
        return std.fmt.parseInt(u64, trimmed, 10) catch null;
    }
    return null;
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
        // A negative credit balance is an authorization problem, not a
        // malformed request; surfacing it as `forbidden` keeps the agent from
        // retrying a request that cannot succeed until credits are added.
        .payment_required, .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

/// Frames the response body into SSE `data:` payloads.
///
/// OpenRouter injects `: OPENROUTER PROCESSING` comment lines as keep-alives
/// during long provider waits. They are valid SSE framing but invalid JSON, so
/// they are dropped here rather than reaching the reducer.
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
            self.aggregate_bytes = chat_completions.checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            ) catch return error.OpenRouterResourceLimitExceeded;
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (trimmed.len == 0 or chat_completions.isCommentLine(trimmed)) {
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
                    if (buffered.len == 0) return error.OpenRouterSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenRouterSseEventTooLarge;
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
                return error.OpenRouterSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) {
                return .{ .bytes = fragment, .wire_bytes = fragment.len + 1 };
            }
            try self.pending_line.appendSlice(alloc, fragment);
            return .{
                .bytes = self.pending_line.items,
                .wire_bytes = self.pending_line.items.len + 1,
            };
        }
    }
};

const ReducedStream = struct {
    completion: types.ModelCompletion,
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
    requested_model: []const u8,
) !ReducedStream {
    var reducer = chat_completions.Reducer.init();
    defer reducer.deinit(alloc);
    var sse: SseReader = .{};
    defer sse.deinit(alloc);

    const callbacks = chat_completions.StreamCallbacks{
        .context = callback_ctx,
        .on_content = on_content_chunk,
        .on_tool_start = on_tool_start,
        .on_reasoning = on_reasoning_chunk,
        .on_tool_input = on_tool_input_chunk,
    };
    const stream_limits = chat_completions.StreamLimits{
        .aggregate_bytes = max_sse_aggregate_bytes,
        .count_json_bytes = false,
        .events = max_sse_events,
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
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

    var completion = reducer.finish(alloc, cancel_flag) catch |err| return mapReducerError(err);
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }
    // `billing.model` must be owned by the completion, but the reducer's copy
    // dies with the reducer, so duplicate it here.
    if (reducer.billing(@max(io_mod.milliTimestamp(), 0), requested_model)) |billing| {
        var owned_billing = billing;
        owned_billing.model = try alloc.dupe(u8, billing.model);
        completion.billing = owned_billing;
    }
    return .{ .completion = completion };
}

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidEvent => error.InvalidOpenRouterSseEvent,
        error.ResponseFailed => error.OpenRouterResponseFailed,
        error.StreamIncomplete => error.OpenRouterStreamIncomplete,
        error.InvalidToolCall => error.InvalidOpenRouterToolCall,
        error.ToolCallLimitExceeded => error.OpenRouterToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.OpenRouterToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.OpenRouterResourceLimitExceeded,
        else => err,
    };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");

fn ignoreTestEvent(_: *anyopaque, _: stream_provider.Event) void {}
fn admitTestRequest(_: *anyopaque) !void {}

fn testModelRequest(
    secret_value: []const u8,
    source: ?types.CredentialSource,
    delivery: *stream_provider.DeliveryCertainty,
    evidence: *stream_provider.AttemptEvidence,
    cancelled: *std.atomic.Value(bool),
    callback_context: *u8,
) stream_provider.ModelRequest {
    return .{
        .credential = .{ .secret = secret_value, .source = source },
        .model = "z-ai/glm-5.2:free",
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

test "OpenRouter rejects wrong-origin credentials before any network I/O" {
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence = stream_provider.AttemptEvidence{};
    var cancelled = std.atomic.Value(bool).init(false);
    var context: u8 = 0;

    // A Gateway or subscription credential must never be spent on OpenRouter.
    for ([_]?types.CredentialSource{
        .ai_gateway_api_key,
        .chatgpt_subscription,
        .grok_subscription,
        null,
    }) |source| {
        const request = testModelRequest("key", source, &delivery, &evidence, &cancelled, &context);
        try testing.expectError(
            error.OpenRouterApiKeyRequired,
            streamCompletion(null, testing.allocator, request),
        );
    }

    // The right origin with an empty secret is still refused.
    const empty = testModelRequest("", .openrouter_api_key, &delivery, &evidence, &cancelled, &context);
    try testing.expectError(
        error.OpenRouterApiKeyRequired,
        streamCompletion(null, testing.allocator, empty),
    );

    try testing.expectEqual(
        stream_provider.DeliveryCertainty.State.definitely_unsent,
        delivery.load(),
    );
}

test "OpenRouter rejects malformed model identifiers" {
    for ([_][]const u8{ "", "has space", "has\ttab" }) |model| {
        try testing.expectError(error.InvalidOpenRouterModel, validateModel(model));
    }
    try validateModel("z-ai/glm-5.2:free");
    try validateModel("anthropic/claude-opus-4.8");
}

test "OpenRouter request serializes messages tools reasoning and output limit" {
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read a file.",
        .input_schema = .{
            .properties = &.{.{ .name = "path", .json_type = .string }},
            .required = &.{"path"},
        },
    };
    const advertised = [_]model_tool_schema.FunctionSchema{read_file_schema};
    const names = [_][]const u8{"read_file"};
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be brief." },
        .{ .role = .user, .content = "Read README.md" },
    };

    const payload = try buildRequest(testing.allocator, .{
        .model = "z-ai/glm-5.2:free",
        .messages = &messages,
        .tools = .{ .advertised_names = &names, .advertised_functions = &advertised },
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
        .max_output_tokens = 4096,
    });
    defer testing.allocator.free(payload);

    // The payload must be valid JSON with the OpenRouter/OpenAI chat shape.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try testing.expectEqualStrings("z-ai/glm-5.2:free", root.get("model").?.string);
    try testing.expect(root.get("stream").?.bool);
    try testing.expect(root.get("usage").?.object.get("include").?.bool);
    try testing.expectEqual(@as(i64, 4096), root.get("max_tokens").?.integer);
    try testing.expectEqualStrings("auto", root.get("tool_choice").?.string);
    try testing.expectEqualStrings("high", root.get("reasoning").?.object.get("effort").?.string);

    const sent = root.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 2), sent.len);
    try testing.expectEqualStrings("system", sent[0].object.get("role").?.string);
    try testing.expectEqualStrings("user", sent[1].object.get("role").?.string);

    const tools = root.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("function", tools[0].object.get("type").?.string);
    try testing.expectEqualStrings(
        "read_file",
        tools[0].object.get("function").?.object.get("name").?.string,
    );
}

test "OpenRouter omits tool_choice when no tools are advertised" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const payload = try buildRequest(testing.allocator, .{
        .model = "z-ai/glm-5.2:free",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("tools") == null);
    try testing.expect(parsed.value.object.get("tool_choice") == null);
    try testing.expect(parsed.value.object.get("reasoning") == null);
    try testing.expect(parsed.value.object.get("max_tokens") == null);
}

test "OpenRouter maps HTTP status onto the neutral failure contract" {
    try testing.expectEqual(stream_provider.FailureKind.unauthorized, failureKind(.unauthorized));
    // A negative balance blocks even free models, so it must not be retried as
    // a transient fault.
    try testing.expectEqual(stream_provider.FailureKind.forbidden, failureKind(.payment_required));
    try testing.expectEqual(stream_provider.FailureKind.rate_limited, failureKind(.too_many_requests));
    try testing.expectEqual(stream_provider.FailureKind.unavailable, failureKind(.service_unavailable));
    try testing.expectEqual(stream_provider.FailureKind.invalid_request, failureKind(.bad_request));

    // The statuses a free-tier user actually hits carry actionable guidance.
    try testing.expect(std.mem.indexOf(u8, statusGuidance(.payment_required).?, "402") != null);
    try testing.expect(std.mem.indexOf(u8, statusGuidance(.too_many_requests).?, "50 per day") != null);
    try testing.expect(statusGuidance(.service_unavailable) != null);
    try testing.expect(statusGuidance(.ok) == null);
}

test "OpenRouter SSE stream survives keep-alive comments and reports exact usage" {
    const sse_text =
        ": OPENROUTER PROCESSING\n\n" ++
        "data: {\"id\":\"gen-abc\",\"model\":\"z-ai/glm-5.2:free\",\"choices\":[{\"delta\":{\"content\":\"he\"}}]}\n\n" ++
        ": OPENROUTER PROCESSING\n\n" ++
        "data: {\"id\":\"gen-abc\",\"choices\":[{\"delta\":{\"content\":\"llo\"}}]}\n\n" ++
        "data: {\"id\":\"gen-abc\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]," ++
        "\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"cost\":0}}\n\n" ++
        "data: [DONE]\n\n";

    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);

    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        fn onContent(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(testing.allocator, chunk) catch {};
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(testing.allocator);

    const reduced = try consumeSse(
        testing.allocator,
        &reader,
        &capture,
        Capture.onContent,
        null,
        null,
        null,
        &cancelled,
        null,
        "z-ai/glm-5.2:free",
    );
    defer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = reduced.completion,
            .ownership = .owned,
        } };
        owned.deinit(testing.allocator);
    }

    try testing.expectEqualStrings("hello", capture.content.items);
    try testing.expectEqualStrings("hello", reduced.completion.content.?);
    try testing.expectEqualStrings("gen-abc", reduced.completion.generation_id.?);
    try testing.expectEqual(types.ProviderFinishReason.stop, reduced.completion.finish_reason.?);
    try testing.expectEqual(@as(u64, 12), reduced.completion.usage.input_tokens.?);
    // A reported cost (even zero, for a free model) yields exact billing.
    try testing.expectEqualStrings("z-ai/glm-5.2:free", reduced.completion.billing.?.model);
    try testing.expectEqual(@as(f64, 0), reduced.completion.billing.?.total_cost);
}

test "OpenRouter surfaces a mid-stream error delivered over HTTP 200" {
    const sse_text =
        "data: {\"id\":\"gen-1\",\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n" ++
        "data: {\"id\":\"gen-1\",\"error\":{\"code\":429,\"message\":\"Rate limit exceeded\"}," ++
        "\"choices\":[{\"delta\":{\"content\":\"\"},\"finish_reason\":\"error\"}]}\n\n";

    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Sink = struct {
        fn onContent(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;

    try testing.expectError(error.OpenRouterResponseFailed, consumeSse(
        testing.allocator,
        &reader,
        &context,
        Sink.onContent,
        null,
        null,
        null,
        &cancelled,
        null,
        "z-ai/glm-5.2:free",
    ));
}

test "OpenRouter rejects a stream that never reaches a terminal event" {
    const sse_text = "data: {\"id\":\"gen-1\",\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Sink = struct {
        fn onContent(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;

    try testing.expectError(error.OpenRouterStreamIncomplete, consumeSse(
        testing.allocator,
        &reader,
        &context,
        Sink.onContent,
        null,
        null,
        null,
        &cancelled,
        null,
        "z-ai/glm-5.2:free",
    ));
}

test "OpenRouter refuses a non-loopback e2e endpoint override" {
    // The override exists only for local fixtures; it must never be able to
    // redirect live traffic to an arbitrary host.
    try testing.expect(!gateway_client.isLoopbackHttpUrl("https://evil.example/api/v1/chat/completions"));
    try testing.expect(gateway_client.isLoopbackHttpUrl("http://127.0.0.1:8080/api/v1/chat/completions"));
}
