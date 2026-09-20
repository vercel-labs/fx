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
const chat_completions = @import("chat_completions.zig");
const definitions = @import("../core/config/configured_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const model_provider = @import("../core/config/model_provider.zig");

const Allocator = std.mem.Allocator;
const e2e_endpoint_env = "FX_E2E_CONFIGURED_RESPONSES_URL";
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

/// Bundle for `openai-responses` configured providers. Catalog and permission
/// review are shared with the chat-completions adapter; only the agent stream
/// speaks the Responses wire protocol. Every callback borrows the immutable
/// definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    const shared = chat_completions.bundle(definition);
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = responses_protocol.selectReplayParts },
        .model_catalog = shared.model_catalog,
        .cli_model_catalog = shared.cli_model_catalog,
        .permission_reviewer = shared.permission_reviewer,
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidConfiguredResponsesModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidConfiguredResponsesModel;
    }
}

pub fn buildRequestForDefinition(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: stream_provider.RequestData,
) ![]u8 {
    try request.validatePrompt();
    try validateModel(request.model);
    const budget: image_attachments.CaptureBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        .{};
    try budget.check();
    const identity = bound_identity(definition);
    const projected = try types.projectProviderReplay(alloc, request.messages, .{ .provider = identity, .model = request.model });
    defer if (projected) |messages| alloc.free(messages);
    if (projected != null) debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});

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
        try writer.writeAll(",\"parallel_tool_calls\":true");
    }
    // Encrypted reasoning replay keeps multi-turn agentic loops coherent on
    // Responses endpoints such as Meta's Model API.
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

fn build(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) ![]u8 {
    const definition = definition_at(raw);
    const identity = bound_identity(definition);
    for (request.messages) |message| if (message.provider_replay) |replay| {
        if (!replay.matches(.{ .provider = identity, .model = request.model })) {
            debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});
            break;
        }
    };
    return buildRequestForDefinition(alloc, definition, request);
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
        error.ProviderStateTooLarge => error.ConfiguredResponsesProviderStateTooLarge,
        error.InvalidProviderState => error.InvalidConfiguredResponsesProviderState,
        error.ToolCallLimitExceeded => error.ConfiguredResponsesToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.ConfiguredResponsesToolArgumentsTooLarge,
        else => err,
    };
}

fn validateCredential(definition: *const definitions.Definition, request: stream_provider.ModelRequest) !?[]const u8 {
    const source = request.credential.credentialSource();
    if (source != .configured and source != .host_managed) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer => if (token == null) return error.MissingConfiguredProviderCredential,
    }
    return token;
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    _ = try validateCredential(definition, request);
    try validateModel(request.model);
    const payload = request.prepared_request_body orelse
        try buildRequestForDefinition(alloc, definition, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    var result = streamPrepared(alloc, definition, request, payload) catch |err| {
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

pub fn streamPrepared(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    const token = try validateCredential(definition, request);
    const url = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) {
            return stream_provider.failResult(error.InvalidE2EConfiguredResponsesEndpoint);
        }
        break :endpoint try alloc.dupe(u8, override);
    } else try definition.responses_url(alloc);
    defer alloc.free(url);
    const authorization = if (token) |value| try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}) else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    const uri = try std.Uri.parse(url);

    var extra_headers_buf: [2]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    if (request.session_id) |session_id| if (session_id.len > 0) {
        extra_headers_buf[extra_count] = .{ .name = "session-id", .value = session_id };
        extra_count += 1;
    };

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = gateway_client.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
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
    var opened = try gateway_client.openBoundedPost(
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch: gateway_client.CancelWatch = .{};
    defer cancel_watch.stop();
    if (http_request.connection) |connection|
        try cancel_watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);
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
        var detail = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Configured Responses error response exceeded the local limit"),
            else => return err,
        };
        errdefer alloc.free(detail);
        if (token) |value| {
            const redacted = try redact_error_detail(alloc, detail, value);
            alloc.free(detail);
            detail = redacted;
        }
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = detail,
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
        .{},
    );
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }
    return .{
        .completed = .{
            .completion = completion,
            // Third-party Responses endpoints bill outside fx; usage stays
            // unavailable but marked as possibly billed.
            .usage = .{ .unavailable = .possibly_billed },
            .ownership = .owned,
        },
    };
}

fn redact_error_detail(alloc: Allocator, raw: []const u8, credential: []const u8) Allocator.Error![]u8 {
    if (credential.len == 0) return alloc.dupe(u8, raw);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = raw;
    while (std.mem.find(u8, rest, credential)) |index| {
        try out.appendSlice(alloc, rest[0..index]);
        try out.appendSlice(alloc, "[redacted]");
        rest = rest[index + credential.len ..];
    }
    try out.appendSlice(alloc, rest);
    return out.toOwnedSlice(alloc);
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

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8, arguments_json: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label, .arguments_json = arguments_json } });
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
    limits: ResponsesLimits,
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

const ResponsesLimits = struct {
    aggregate_bytes: usize = max_sse_aggregate_bytes,
    events: usize = max_sse_events,
    tool_calls: usize = max_tool_calls,
    tool_identity_bytes: usize = max_tool_identity_bytes,
    tool_arguments_bytes: usize = max_tool_arguments_bytes,
    provider_state_bytes: usize = max_provider_state_bytes,
};

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.EventTooLarge => error.ConfiguredResponsesSseEventTooLarge,
        error.InvalidEvent => error.InvalidConfiguredResponsesSseEvent,
        error.StreamIncomplete => error.ConfiguredResponsesStreamIncomplete,
        error.ToolCallLimitExceeded => error.ConfiguredResponsesToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.ConfiguredResponsesToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.ConfiguredResponsesResourceLimitExceeded,
        else => err,
    };
}

fn test_registry(alloc: Allocator, json: []const u8) !definitions.Registry {
    return definitions.Registry.parse_json(alloc, json);
}

test "responses bundle builds a Responses request with encrypted reasoning continuity" {
    const alloc = std.testing.allocator;
    var registry = try test_registry(alloc,
        \\{"spark":{"protocol":"openai-responses","base_url":"https://api.meta.ai/v1","auth":{"type":"bearer","env":"MODEL_API_KEY"},"model_metadata":{"muse-spark-1.3":{"context_window":1048576,"max_output_tokens":131072,"supports_tool_use":true,"supports_vision":true}}}}
    );
    defer registry.deinit(alloc);
    const definition = registry.get("spark").?;
    try std.testing.expect(definition.protocol == .@"openai-responses");
    const url = try definition.responses_url(alloc);
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://api.meta.ai/v1/responses", url);

    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "Be concise." }};
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Read it." }};
    const body = try buildRequestForDefinition(alloc, definition, .{
        .model = "muse-spark-1.3",
        .instructions = &instructions,
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
        .max_output_tokens = 4096,
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"muse-spark-1.3\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"Be concise.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"summary\":\"auto\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\":4096") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"input\":[") != null);
}

test "responses bundle binds replay to endpoint authority" {
    const alloc = std.testing.allocator;
    var registry = try test_registry(alloc,
        \\{"spark":{"protocol":"openai-responses","base_url":"https://api.meta.ai/v1","auth":{"type":"bearer","env":"MODEL_API_KEY"}}}
    );
    defer registry.deinit(alloc);
    var changed_registry = try test_registry(alloc,
        \\{"spark":{"protocol":"openai-responses","base_url":"https://example.com/v1","auth":{"type":"bearer","env":"MODEL_API_KEY"}}}
    );
    defer changed_registry.deinit(alloc);
    const definition = registry.get("spark").?;
    const adapter = bundle(definition).agent_stream.?;
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = bundle(definition).model_catalog.?.provider_id, .model = "model" },
        .parts_json = "[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}]",
    };
    const selected = (try adapter.projectReplay(alloc, replay, &.{}, false, true)).?;
    try std.testing.expect(selected.parts_json.ptr == replay.parts_json.ptr);
    const other = bundle(changed_registry.get("spark").?).agent_stream.?;
    const messages = [_]types.ChatMessage{.{ .role = .assistant, .content = "answer", .provider_replay = replay }};
    const request: stream_provider.RequestData = .{
        .model = "model",
        .instructions = &.{},
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const matching = try adapter.build_request_fn.?(adapter.context, alloc, request);
    defer alloc.free(matching);
    try std.testing.expect(std.mem.find(u8, matching, "\"encrypted_content\":\"opaque\"") != null);
    const stripped = try other.build_request_fn.?(other.context, alloc, request);
    defer alloc.free(stripped);
    try std.testing.expect(std.mem.find(u8, stripped, "\"encrypted_content\":\"opaque\"") == null);
}

test "responses bundle rejects invalid models" {
    const alloc = std.testing.allocator;
    var registry = try test_registry(alloc,
        \\{"spark":{"protocol":"openai-responses","base_url":"https://api.meta.ai/v1","auth":{"type":"bearer","env":"MODEL_API_KEY"}}}
    );
    defer registry.deinit(alloc);
    const definition = registry.get("spark").?;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    try std.testing.expectError(error.InvalidConfiguredResponsesModel, buildRequestForDefinition(alloc, definition, .{
        .model = "",
        .instructions = &.{},
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    }));
}
