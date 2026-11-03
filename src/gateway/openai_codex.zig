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
const model_provider = @import("../core/config/model_provider.zig");
const model_compatibility = @import("../core/config/model_compatibility.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const configured_request = @import("configured_request.zig");
const codex_session = @import("openai_codex_session.zig");
const codex_websocket = @import("openai_codex_websocket.zig");
const codex_compression = @import("openai_codex_compression.zig");

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
const websocket_idle_reuse_ms: i64 = 30_000;
const websocket_first_event_timeout_ms: i64 = 300_000;

const CodexLimits = struct {
    aggregate_bytes: usize = max_sse_aggregate_bytes,
    events: usize = max_sse_events,
    tool_calls: usize = max_tool_calls,
    tool_identity_bytes: usize = max_tool_identity_bytes,
    tool_arguments_bytes: usize = max_tool_arguments_bytes,
    provider_state_bytes: usize = max_provider_state_bytes,
};

pub const TransportState = codex_session.TransportState;

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

/// What a Responses endpoint other than ChatGPT's Codex one needs changed.
pub const BuildOptions = struct {
    /// The replay authority: Codex, or a configured provider's bound identity.
    provider: model_provider.ProviderId = .codex,
    /// Codex's `text.verbosity`, which other endpoints may refuse.
    verbosity: bool = true,
    /// The public API's `max_output_tokens`, which Codex rejects.
    max_output_tokens: bool = false,
};

pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    return buildRequestWith(alloc, request, .{});
}

/// The Responses body for `request`. Caller owns it.
pub fn buildRequestWith(
    alloc: Allocator,
    request: stream_provider.RequestData,
    options: BuildOptions,
) ![]u8 {
    try request.validatePrompt();
    try validateModel(request.model);
    const budget: image_attachments.CaptureBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        .{};
    try budget.check();
    const projected = try types.projectProviderReplay(alloc, request.messages, .{ .provider = options.provider, .model = request.model });
    defer if (projected) |messages| alloc.free(messages);
    const compatibility: ?*const model_compatibility.Compatibility = if (request.provider_options.model_metadata) |metadata| &metadata.compat else null;
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
    try writer.writeAll(",\"store\":false,\"stream\":true");
    // The Codex CLI keys its prompt cache by conversation, so requests in one
    // session reach the server that holds their prefix (D133).
    if (request.session_id) |session_id| if (session_id.len > 0) {
        try writer.writeAll(",\"prompt_cache_key\":");
        try std.json.Stringify.value(session_id, .{}, writer);
    };
    try writer.writeAll(",\"instructions\":");
    try std.json.Stringify.value(instructions.written(), .{}, writer);
    try writer.writeAll(",\"input\":[");
    try writeResponsesInput(writer, std.heap.c_allocator, projected orelse request.messages, request.verified_images, budget, compatibility);
    try writer.writeByte(']');

    _ = try responses_protocol.writeTools(writer, alloc, request.tools);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    try writer.writeAll(",\"parallel_tool_calls\":true,\"include\":[\"reasoning.encrypted_content\"]");
    // Codex exposes Fast mode as its priority service tier for supported
    // ChatGPT subscription models.
    if (request.provider_options.fast) try writer.writeAll(",\"service_tier\":\"priority\"");

    try writer.writeAll(",\"text\":{");
    if (options.verbosity) try writer.writeAll("\"verbosity\":\"low\"");
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        if (options.verbosity) try writer.writeByte(',');
        try writer.writeAll("\"format\":{\"type\":\"json_schema\",\"name\":");
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
    if (options.max_output_tokens) if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
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
    compatibility: ?*const model_compatibility.Compatibility,
) !void {
    return responses_protocol.writeInputWith(writer, alloc, messages, images, .{
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    }, budget, .{ .compatibility = compatibility }) catch |err| switch (err) {
        error.ProviderStateTooLarge => error.OpenAICodexProviderStateTooLarge,
        error.InvalidProviderState => error.InvalidOpenAICodexProviderState,
        error.ToolCallLimitExceeded => error.OpenAICodexToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.OpenAICodexToolArgumentsTooLarge,
        else => err,
    };
}

fn streamCompletion(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    const transport_state: ?*TransportState = if (raw) |context|
        @ptrCast(@alignCast(context))
    else
        null;
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (!acceptsCredential(request.credential)) {
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
        .transport_state = transport_state,
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
    transport_state: ?*TransportState = null,

    pub fn run(self: *@This()) !stream_provider.Result {
        return streamPreparedWithState(self.alloc, self.request, self.payload, self.transport_state);
    }
};

/// True for the credentials a Codex request may use: a ChatGPT subscription,
/// or a host that authorizes the request itself.
pub fn acceptsCredential(lease: stream_provider.CredentialLease) bool {
    const source = lease.credentialSource() orelse return false;
    return source == .chatgpt_subscription or source == .host_managed;
}

/// The Responses endpoint, or a loopback test endpoint from the environment.
/// Borrowed; static or environment-owned.
pub fn responsesEndpoint() error{InvalidE2EOpenAICodexEndpoint}![]const u8 {
    const override = io_mod.getenv(e2e_endpoint_env) orelse return endpoint;
    if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenAICodexEndpoint;
    return override;
}

fn requestEndpoint(alloc: Allocator, request: stream_provider.ModelRequest) ![]u8 {
    // E2E overrides remain authoritative and are always loopback-validated.
    if (io_mod.getenv(e2e_endpoint_env) != null) return alloc.dupe(u8, try responsesEndpoint());
    if (request.provider_options.model_metadata) |metadata| if (metadata.base_url) |base| {
        if (base.len > 0) {
            if (std.mem.endsWith(u8, base, "/responses") or std.mem.endsWith(u8, base, "/codex/responses")) {
                return alloc.dupe(u8, base);
            }
            return alloc.print("{s}/codex/responses", .{std.mem.trimEnd(u8, base, "/")});
        }
    };
    return alloc.dupe(u8, endpoint);
}

fn resolveMetadataHeaders(alloc: Allocator, request: stream_provider.ModelRequest) !configured_request.Headers {
    const metadata = request.provider_options.model_metadata orelse return .{};
    if (metadata.headers.len == 0) return .{};
    const selected = try alloc.alloc(configured_provider.Header, metadata.headers.len);
    defer alloc.free(selected);
    @memcpy(selected, metadata.headers);
    return configured_request.resolveHeaderValues(alloc, selected);
}

pub const max_extra_headers = 6;

/// Writes the Codex headers other than authorization and content type into
/// `buf` and returns the used prefix. Values are borrowed from the arguments.
pub fn extraHeaders(
    buf: *[max_extra_headers]std.http.Header,
    account_id: ?[]const u8,
    session_id: ?[]const u8,
) []std.http.Header {
    var count: usize = 0;
    if (account_id) |value| {
        buf[count] = .{ .name = "chatgpt-account-id", .value = value };
        count += 1;
    }
    buf[count] = .{ .name = "originator", .value = "fx" };
    count += 1;
    buf[count] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
    count += 1;
    buf[count] = .{ .name = "accept", .value = "text/event-stream" };
    count += 1;
    if (session_id) |value| if (value.len > 0) {
        buf[count] = .{ .name = "session-id", .value = value };
        count += 1;
        buf[count] = .{ .name = "x-client-request-id", .value = value };
        count += 1;
    };
    return buf[0..count];
}

pub const RequestAuthHeaders = struct {
    authorization: ?[]u8 = null,
    account_id: ?[]u8 = null,

    pub fn deinit(self: *RequestAuthHeaders, alloc: Allocator) void {
        if (self.authorization) |value| secret.zeroAndFree(alloc, value);
        if (self.account_id) |value| alloc.free(value);
        self.* = .{};
    }
};

/// Authorization for a direct ChatGPT credential; empty for a host-managed one,
/// whose host adds its own. The caller owns the result.
pub fn requestAuthHeaders(alloc: Allocator, auth: stream_provider.CredentialLease) !RequestAuthHeaders {
    return switch (auth) {
        .host_managed => .{},
        .direct => |direct| blk: {
            const authorization = try alloc.print("Bearer {s}", .{direct.secret_bytes});
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

fn websocketUrl(alloc: Allocator, http_url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, http_url, "https://")) {
        const out = try alloc.alloc(u8, http_url.len - 2);
        @memcpy(out[0..6], "wss://");
        @memcpy(out[6..], http_url[8..]);
        return out;
    }
    if (std.mem.startsWith(u8, http_url, "http://")) {
        const out = try alloc.alloc(u8, http_url.len - 2);
        @memcpy(out[0..5], "ws://");
        @memcpy(out[5..], http_url[7..]);
        return out;
    }
    return error.InvalidOpenAICodexEndpoint;
}

fn websocketHeaders(
    buf: []std.http.Header,
    authorization: ?[]const u8,
    account_id: ?[]const u8,
    session_id: ?[]const u8,
    models_etag: ?[]const u8,
    turn_state: ?[]const u8,
    routing_hint: []const u8,
) []std.http.Header {
    var count: usize = 0;
    if (authorization) |value| {
        buf[count] = .{ .name = "Authorization", .value = value };
        count += 1;
    }
    if (account_id) |value| {
        buf[count] = .{ .name = "chatgpt-account-id", .value = value };
        count += 1;
    }
    buf[count] = .{ .name = "originator", .value = "pi" };
    count += 1;
    buf[count] = .{ .name = "OpenAI-Beta", .value = "responses_websockets=2026-02-06" };
    count += 1;
    buf[count] = .{ .name = "version", .value = "0.159.0" };
    count += 1;
    if (routing_hint.len > 0) {
        buf[count] = .{ .name = "x-codex-routing-hint", .value = routing_hint };
        count += 1;
    }
    if (session_id) |value| if (value.len > 0) {
        buf[count] = .{ .name = "session-id", .value = value };
        count += 1;
        buf[count] = .{ .name = "conversation-id", .value = value };
        count += 1;
        buf[count] = .{ .name = "x-client-request-id", .value = value };
        count += 1;
    };
    if (models_etag) |value| {
        buf[count] = .{ .name = "x-models-etag", .value = value };
        count += 1;
    }
    if (turn_state) |value| {
        buf[count] = .{ .name = "x-codex-turn-state", .value = value };
        count += 1;
    }
    return buf[0..count];
}

const WebsocketRelay = struct {
    sink: *stream_provider.EventSink,
    emitted: bool = false,
};

fn relayContent(raw: *anyopaque, chunk: []const u8) void {
    const relay: *WebsocketRelay = @ptrCast(@alignCast(raw));
    relay.emitted = true;
    relay.sink.emit(.{ .content_delta = chunk });
}

fn relayReasoning(raw: *anyopaque, chunk: []const u8) void {
    const relay: *WebsocketRelay = @ptrCast(@alignCast(raw));
    relay.emitted = true;
    relay.sink.emit(.{ .reasoning_delta = chunk });
}

fn relayToolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8, args: ?[]const u8) void {
    const relay: *WebsocketRelay = @ptrCast(@alignCast(raw));
    relay.emitted = true;
    relay.sink.emit(.{ .tool_started = .{ .id = id, .name = name, .label = label, .arguments_json = args } });
}

fn relayToolInput(raw: *anyopaque, delta: stream_provider.ToolInputDelta) void {
    const relay: *WebsocketRelay = @ptrCast(@alignCast(raw));
    relay.emitted = true;
    relay.sink.emit(.{ .tool_input_delta = delta });
}

fn codexEventType(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const type_value = value.object.get("type") orelse return null;
    return if (type_value == .string) type_value.string else null;
}

fn codexResponseId(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const response = value.object.get("response") orelse return null;
    if (response != .object) return null;
    const id = response.object.get("id") orelse return null;
    return if (id == .string and id.string.len > 0) id.string else null;
}

fn codexErrorCode(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("code")) |code| if (code == .string) return code.string;
    const response = value.object.get("response") orelse return null;
    if (response != .object) return null;
    const failure = response.object.get("error") orelse return null;
    if (failure != .object) return null;
    const code = failure.object.get("code") orelse return null;
    return if (code == .string) code.string else null;
}

fn codexErrorMessage(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("message")) |message| if (message == .string) return message.string;
    if (value.object.get("error")) |failure| if (failure == .object) {
        if (failure.object.get("message")) |message| if (message == .string) return message.string;
    };
    if (value.object.get("response")) |response| if (response == .object) {
        if (response.object.get("error")) |failure| if (failure == .object) {
            if (failure.object.get("message")) |message| if (message == .string) return message.string;
        };
    };
    return null;
}

fn isStalePreviousResponse(code: ?[]const u8, message: ?[]const u8) bool {
    if (code) |value| {
        if (std.mem.eql(u8, value, "previous_response_not_found") or
            std.mem.eql(u8, value, "codex_previous_response_stale")) return true;
    }
    const detail = message orelse return false;
    return std.ascii.findIgnoreCasePos(detail, 0, "previous response") != null and
        (std.ascii.findIgnoreCasePos(detail, 0, "not found") != null or
            std.ascii.findIgnoreCasePos(detail, 0, "invalid") != null or
            std.ascii.findIgnoreCasePos(detail, 0, "expired") != null or
            std.ascii.findIgnoreCasePos(detail, 0, "stale") != null or
            std.ascii.findIgnoreCasePos(detail, 0, "unsupported") != null);
}

fn terminalResponseItems(alloc: Allocator, value: std.json.Value) !?[]u8 {
    if (value != .object) return null;
    const response = value.object.get("response") orelse return null;
    if (response != .object) return null;
    const output = response.object.get("output") orelse return null;
    if (output != .array) return null;
    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    try std.json.Stringify.value(output, .{}, &writer.writer);
    return try writer.toOwnedSlice();
}

fn resetCodexSocket(
    alloc: Allocator,
    state: *TransportState,
    request: stream_provider.ModelRequest,
    auth: RequestAuthHeaders,
    request_endpoint: []const u8,
) !void {
    const ws_url = try websocketUrl(alloc, request_endpoint);
    defer alloc.free(ws_url);
    if (try state.get(
        request.session_id,
        request.model,
        auth.account_id orelse "",
        ws_url,
        auth.authorization orelse "",
    )) |session| {
        session.resetAppend();
        if (session.connection) |*connection| connection.deinit();
        session.connection = null;
    }
}

fn streamCodexWebSocket(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    state: *TransportState,
    auth: RequestAuthHeaders,
    request_endpoint: []const u8,
) !stream_provider.Result {
    const ws_url = try websocketUrl(alloc, request_endpoint);
    defer alloc.free(ws_url);
    const session = (try state.get(
        request.session_id,
        request.model,
        auth.account_id orelse "",
        ws_url,
        auth.authorization orelse "",
    )) orelse return error.CodexWebSocketFailure;
    if (session.active) return error.CodexWebSocketFailure;
    session.active = true;
    defer session.active = false;

    if (session.connection) |*connection| {
        if (!connection.isHealthyForReuse(io_mod.monotonicMilliTimestamp(), websocket_idle_reuse_ms)) {
            connection.deinit();
            session.connection = null;
            session.resetAppend();
        }
    }
    if (session.connection == null) {
        var metadata_headers = try resolveMetadataHeaders(alloc, request);
        defer metadata_headers.deinit(alloc);
        var headers_buf: [64]std.http.Header = undefined;
        var routing_hint_buf: [2048]u8 = undefined;
        const routing_hint = if (request.provider_options.fast)
            std.fmt.bufPrint(&routing_hint_buf, "model={s};tier=priority", .{request.model}) catch ""
        else
            std.fmt.bufPrint(&routing_hint_buf, "model={s}", .{request.model}) catch "";
        const default_headers = websocketHeaders(
            headers_buf[0..],
            auth.authorization,
            auth.account_id,
            request.session_id,
            session.models_etag,
            session.turn_state,
            routing_hint,
        );
        const headers = try configured_request.mergeHeaders(alloc, default_headers, metadata_headers.items);
        defer alloc.free(headers);
        // The connection outlives this request and is reused by later turns;
        // construct it in the session so std.http.Connection.client points at
        // the persistent HTTP client, not a copied request-local value.
        session.connection = codex_websocket.Client.init(session.alloc, session.endpoint, headers);
        errdefer {
            if (session.connection) |*connection| connection.deinit();
            session.connection = null;
        }
        const connection = &session.connection.?;
        try connection.connect(request.cancel_flag, connect_timeout_ms);
        if (connection.handshakeHeader("x-models-etag")) |etag| {
            session.models_etag = session.replaceOptional(session.models_etag, etag);
        }
        if (connection.handshakeHeader("x-codex-turn-state")) |turn_state| {
            session.turn_state = session.replaceOptional(session.turn_state, turn_state);
        }
    }
    const connection = &session.connection.?;
    var websocket_request: std.Io.Writer.Allocating = .init(alloc);
    defer websocket_request.deinit();
    try websocket_request.writer.writeAll("{\"type\":\"response.create\"");
    var full_payload: ?[]u8 = null;
    defer if (full_payload) |planned| alloc.free(planned);
    var chained = try buildCodexChainedPayload(
        alloc,
        payload,
        session,
        request.provider_options.model_metadata != null and
            request.provider_options.model_metadata.?.compat.supports_configuration_update == true,
        &full_payload,
    );
    defer alloc.free(chained);
    if (chained.len >= 2 and chained[0] == '{' and chained[chained.len - 1] == '}') {
        try websocket_request.writer.writeByte(',');
        try websocket_request.writer.writeAll(chained[1 .. chained.len - 1]);
    } else return error.CodexWebSocketEvent;
    try websocket_request.writer.writeByte('}');
    request.delivery.markPossiblySent();
    try connection.sendText(websocket_request.written());

    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sink = request.events;
    var relay = WebsocketRelay{ .sink = &sink };
    const callbacks = responses_protocol.StreamCallbacks{
        .context = @ptrCast(&relay),
        .on_content = relayContent,
        .on_tool_start = relayToolStart,
        .on_reasoning = relayReasoning,
        .on_tool_input = relayToolInput,
    };
    const limits = responses_protocol.StreamLimits{
        .aggregate_bytes = max_sse_aggregate_bytes,
        .events = max_sse_events,
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    };
    var active_response_id: ?[]const u8 = null;
    var last_sequence: ?i64 = null;
    var terminal_frame: ?[]u8 = null;
    defer if (terminal_frame) |frame| alloc.free(frame);
    while (true) {
        const frame = connection.receive(alloc, websocket_first_event_timeout_ms, request.cancel_flag) catch |err| {
            if (relay.emitted and err != error.Cancelled) return error.CodexWebSocketPartialFailure;
            return switch (err) {
                error.Cancelled => error.Cancelled,
                error.Timeout => error.CodexWebSocketTimeout,
                else => error.CodexWebSocketFailure,
            };
        } orelse if (relay.emitted) return error.CodexWebSocketPartialFailure else return error.CodexWebSocketTimeout;
        defer alloc.free(frame);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, frame, .{}) catch return error.CodexWebSocketEvent;
        defer parsed.deinit();
        const event_type = codexEventType(parsed.value) orelse continue;
        const frame_id = codexResponseId(parsed.value);
        if (frame_id) |id| {
            if (active_response_id == null) {
                if (session.last_response_id) |prior| if (std.mem.eql(u8, prior, id)) continue;
                active_response_id = id;
            } else if (!std.mem.eql(u8, active_response_id.?, id)) {
                if (relay.emitted) return error.CodexWebSocketPartialFailure;
                return error.CodexWebSocketFailure;
            }
        }
        if (parsed.value.object.get("sequence_number")) |sequence| {
            if (sequence == .integer) {
                if (sequence.integer < 0) return error.CodexWebSocketEvent;
                if (last_sequence) |previous| if (sequence.integer < previous) {
                    if (relay.emitted) return error.CodexWebSocketPartialFailure;
                    return error.CodexWebSocketFailure;
                };
                last_sequence = sequence.integer;
            }
        }
        if (std.mem.eql(u8, event_type, "error") or std.mem.eql(u8, event_type, "response.failed")) {
            if (isStalePreviousResponse(codexErrorCode(parsed.value), codexErrorMessage(parsed.value))) {
                if (relay.emitted) return error.CodexWebSocketPartialFailure;
                return error.CodexStalePreviousResponse;
            }
        }
        const done = reducer.applyJson(alloc, frame, callbacks, request.cancel_flag, request.content_capture_limit, limits) catch |err| {
            if (relay.emitted) return error.CodexWebSocketPartialFailure;
            return mapReducerError(err);
        };
        if (done) {
            terminal_frame = try alloc.dupe(u8, frame);
            break;
        }
    }
    const completion = reducer.finish(alloc, request.cancel_flag, limits) catch |err| {
        if (relay.emitted) return error.CodexWebSocketPartialFailure;
        return mapReducerError(err);
    };
    errdefer {
        var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
        owned.deinit(alloc);
    }
    if (active_response_id) |response_id| {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, terminal_frame orelse "{}", .{}) catch null;
        if (parsed) |*value| {
            defer value.deinit();
            const items = terminalResponseItems(alloc, value.value) catch null;
            if (items) |response_items| {
                defer alloc.free(response_items);
                session.setRequest(full_payload orelse payload) catch session.resetAppend();
                session.setResponse(response_id, response_items) catch session.resetAppend();
            } else session.resetAppend();
        } else session.resetAppend();
    } else session.resetAppend();
    return .{ .completed = .{ .completion = completion, .ownership = .owned } };
}

fn jsonValuesEqual(alloc: Allocator, left: std.json.Value, right: std.json.Value) !bool {
    var left_writer: std.Io.Writer.Allocating = .init(alloc);
    defer left_writer.deinit();
    var right_writer: std.Io.Writer.Allocating = .init(alloc);
    defer right_writer.deinit();
    try std.json.Stringify.value(left, .{}, &left_writer.writer);
    try std.json.Stringify.value(right, .{}, &right_writer.writer);
    return std.mem.eql(u8, left_writer.written(), right_writer.written());
}

fn buildCodexChainedPayload(
    alloc: Allocator,
    payload: []const u8,
    session: *codex_session.SessionState,
    supports_configuration_update: bool,
    full_payload_out: *?[]u8,
) ![]u8 {
    var current = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch {
        full_payload_out.* = try alloc.dupe(u8, payload);
        return alloc.dupe(u8, payload);
    };
    defer current.deinit();
    if (current.value != .object) {
        full_payload_out.* = try alloc.dupe(u8, payload);
        return alloc.dupe(u8, payload);
    }

    if (supports_configuration_update) {
        if (current.value.object.getPtr("input")) |input| {
            if (input.* == .array) {
                var requested_effort: ?[]const u8 = null;
                if (current.value.object.getPtr("reasoning")) |reasoning| {
                    if (reasoning.* == .object) {
                        if (reasoning.object.get("effort")) |effort| {
                            if (effort == .string) requested_effort = effort.string;
                        }
                    }
                }
                if (try session.planEffort(current.arena.allocator(), &input.array, requested_effort)) |baseline| {
                    if (current.value.object.getPtr("reasoning")) |reasoning| {
                        if (reasoning.* == .object) {
                            try reasoning.object.put(current.arena.allocator(), "effort", .{ .string = baseline });
                        }
                    }
                }
            }
        }
    }

    var full_writer: std.Io.Writer.Allocating = .init(alloc);
    defer full_writer.deinit();
    try std.json.Stringify.value(current.value, .{}, &full_writer.writer);
    const full_payload = try full_writer.toOwnedSlice();
    full_payload_out.* = full_payload;
    errdefer {
        alloc.free(full_payload);
        full_payload_out.* = null;
    }

    if (!session.can_append or session.last_response_id == null or session.last_request_json == null) {
        return alloc.dupe(u8, full_payload);
    }
    var previous = std.json.parseFromSlice(std.json.Value, alloc, session.last_request_json.?, .{}) catch return alloc.dupe(u8, full_payload);
    defer previous.deinit();
    if (previous.value != .object) return alloc.dupe(u8, full_payload);
    const current_input = current.value.object.get("input") orelse return alloc.dupe(u8, full_payload);
    const previous_input = previous.value.object.get("input") orelse return alloc.dupe(u8, full_payload);
    if (current_input != .array or previous_input != .array) return alloc.dupe(u8, full_payload);
    if (current_input.array.items.len < previous_input.array.items.len) return alloc.dupe(u8, full_payload);
    for (previous_input.array.items, 0..) |item, index| {
        if (!try jsonValuesEqual(alloc, item, current_input.array.items[index])) return alloc.dupe(u8, full_payload);
    }
    const delta = current_input.array.items[previous_input.array.items.len..];
    if (delta.len == 0) return alloc.dupe(u8, full_payload);
    current.value.object.put(alloc, "previous_response_id", .{ .string = session.last_response_id.? }) catch return error.OutOfMemory;
    var delta_array: std.json.Array = .init(alloc);
    for (delta) |item| try delta_array.append(item);
    current.value.object.put(alloc, "input", .{ .array = delta_array }) catch return error.OutOfMemory;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(current.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn streamCodexSse(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    request_endpoint: []const u8,
    admit_request: bool,
) !stream_provider.Result {
    // The official Codex service advertises zstd request bodies. The loopback
    // endpoint is deliberately left plain so local fixtures remain simple and
    // can inspect the JSON directly.
    const compress = std.mem.eql(u8, request_endpoint, endpoint);
    var compressed: ?[]u8 = null;
    defer if (compressed) |body| alloc.free(body);
    if (compress) {
        const encoded = try codex_compression.encode(alloc, payload);
        if (encoded.len < payload.len) compressed = encoded else alloc.free(encoded);
    }
    if (admit_request) try request.admission.admit();
    return streamCodexSseAttempt(
        alloc,
        request,
        compressed orelse payload,
        request_endpoint,
        compressed != null,
    ) catch |err| switch (err) {
        // Some deployments proxy the official endpoint without zstd request
        // decoding. Retry exactly once with the same JSON and no encoding.
        error.CodexCompressedRequestRejected => streamCodexSseAttempt(
            alloc,
            request,
            payload,
            request_endpoint,
            false,
        ),
        else => return err,
    };
}

fn streamCodexSseAttempt(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    request_endpoint: []const u8,
    compressed: bool,
) !stream_provider.Result {
    var auth_headers = try requestAuthHeaders(alloc, request.credential);
    defer auth_headers.deinit(alloc);
    const uri = try std.Uri.parse(request_endpoint);
    var metadata_headers = try resolveMetadataHeaders(alloc, request);
    defer metadata_headers.deinit(alloc);
    var default_headers_buf: [max_extra_headers + 1]std.http.Header = undefined;
    var default_headers = extraHeaders(default_headers_buf[0..max_extra_headers], auth_headers.account_id, request.session_id);
    if (compressed) {
        default_headers_buf[default_headers.len] = .{ .name = "content-encoding", .value = "zstd" };
        default_headers = default_headers_buf[0 .. default_headers.len + 1];
    }
    const extra_headers = try configured_request.mergeHeaders(alloc, default_headers, metadata_headers.items);
    defer alloc.free(extra_headers);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = gateway_client.PostOperation{ .client = &client, .uri = uri, .authorization = auth_headers.authorization, .extra_headers = extra_headers };
    const connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(connect_timeout_ms) });
    var opened = try gateway_client.openBoundedPost(alloc, request.cancel_flag, connect_deadline, &open_operation);
    var http_request = opened.take();
    defer http_request.deinit();
    var watch: gateway_client.ConnectionWatch = .init(.{ .patient = true, .stall_timeout_ms = gateway_client.ConnectionWatch.bodyStallTimeoutMs(request.deadline) });
    defer watch.stop();
    if (http_request.connection) |connection| try watch.start(request.cancel_flag, null, connection.stream_writer.stream);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (watch.armHead()) |err| return err;
    var response = http_request.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenAI Codex error response exceeded the local limit"),
            else => return err,
        };
        if (compressed and (response.head.status == .bad_request or response.head.status == .unsupported_media_type)) {
            alloc.free(body);
            return error.CodexCompressedRequestRejected;
        }
        return .{ .failed = .{ .kind = gateway_client.httpFailureKind(alloc, .fromHttpStatus(response.head.status), body), .detail = body, .ownership = .owned } };
    }
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var result = completeFromStream(alloc, request, response.reader(&transfer_buffer), watch.progress()) catch |err| return watch.failure(err);
    if (watch.finish()) |err| {
        result.deinit(alloc);
        return err;
    }
    return result;
}

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    return streamPreparedWithState(alloc, request, payload, null);
}

fn streamPreparedWithState(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    transport_state: ?*TransportState,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    var auth_headers = try requestAuthHeaders(alloc, request.credential);
    defer auth_headers.deinit(alloc);
    const request_endpoint = requestEndpoint(alloc, request) catch |err| return stream_provider.failResult(err);
    defer alloc.free(request_endpoint);
    if (transport_state != null and request.session_id != null and request.provider_options.prefer_websockets != false) {
        // Admission is owned by this attempt across WebSocket connection,
        // stale-chain retry, and any pre-visible SSE replay.
        try request.admission.admit();
        return streamCodexWebSocket(alloc, request, payload, transport_state.?, auth_headers, request_endpoint) catch |err| switch (err) {
            error.CodexStalePreviousResponse => blk: {
                // The server may expire a response chain independently of the
                // session. Clear only the append baseline and retry once with
                // the full context on a fresh socket.
                if (transport_state) |state| try resetCodexSocket(alloc, state, request, auth_headers, request_endpoint);
                break :blk streamCodexWebSocket(alloc, request, payload, transport_state.?, auth_headers, request_endpoint) catch |retry_err| retry_err;
            },
            error.CodexWebSocketFailure,
            error.CodexWebSocketEvent,
            error.CodexWebSocketTimeout,
            error.ConnectionClosed,
            error.HandshakeFailed,
            error.ProtocolViolation,
            error.WriteFailed,
            error.ReadFailed,
            => blk: {
                // A socket can fail before the first event. Replaying over
                // SSE is the safe fallback; consumeSse emits the same contract.
                if (transport_state) |state| resetCodexSocket(alloc, state, request, auth_headers, request_endpoint) catch {};
                break :blk streamCodexSse(alloc, request, payload, request_endpoint, false);
            },
            else => |other| return other,
        };
    }

    return streamCodexSse(alloc, request, payload, request_endpoint, true);
}

/// Parses one successful Codex event stream into a completion with its
/// subscription usage. The result owns the completion.
pub fn completeFromStream(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    reader: *std.Io.Reader,
    progress: ?sse_stream.Progress,
) !stream_provider.Result {
    var events = request.events;
    const completion = try consumeSse(
        alloc,
        reader,
        &events,
        stream_provider.EventSink.onContentChunk,
        stream_provider.EventSink.onToolStart,
        stream_provider.EventSink.onReasoningChunk,
        stream_provider.EventSink.onToolInputChunk,
        request.cancel_flag,
        request.content_capture_limit,
        .{},
        progress,
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
        .ownership = .owned,
    } };
}

fn consumeSse(
    alloc: Allocator,
    reader: *std.Io.Reader,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.ToolInputCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
    limits: CodexLimits,
    progress: ?sse_stream.Progress,
) !types.ModelCompletion {
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sse: sse_stream.Reader = .{ .max_event_bytes = max_sse_line_bytes, .progress = progress };
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

test "OpenAI Codex websocket URL conversion preserves authority" {
    const plain = try websocketUrl(std.testing.allocator, "http://127.0.0.1:1234/native/codex/responses");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("ws://127.0.0.1:1234/native/codex/responses", plain);
    const tls = try websocketUrl(std.testing.allocator, "https://chatgpt.com/backend-api/codex/responses");
    defer std.testing.allocator.free(tls);
    try std.testing.expectEqualStrings("wss://chatgpt.com/backend-api/codex/responses", tls);
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

test "OpenAI Codex keys its prompt cache by session" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const keyed = try buildRequest(std.testing.allocator, .{
        .session_id = "session-7",
        .model = "gpt-5.6-sol",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(keyed);
    try std.testing.expect(std.mem.find(u8, keyed, "\"stream\":true,\"prompt_cache_key\":\"session-7\",\"instructions\":") != null);

    const unkeyed = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(unkeyed);
    try std.testing.expect(std.mem.find(u8, unkeyed, "prompt_cache_key") == null);
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
        /// A chunk that could not be kept; the test reports it.
        append_error: ?std.mem.Allocator.Error = null,

        fn contentChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch |err| {
                self.append_error = err;
            };
        }
        fn reasoningChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reasoning.appendSlice(std.testing.allocator, chunk) catch |err| {
                self.append_error = err;
            };
        }
        fn toolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8, _: ?[]const u8) void {
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
        null,
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
        if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
    }
    if (capture.append_error) |err| return err;
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
        null,
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

const stream_fuzz = @import("stream_fuzz_testing.zig");

fn fuzzResponsesChunkedStream(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reasoning: stream_fuzz.Text = .{};
    try reasoning.generate(arena, smith, "", "", false);
    var content: stream_fuzz.Text = .{};
    try content.generate(arena, smith, "", "", false);
    const with_tool = smith.boolWeighted(1, 1);
    var arguments: stream_fuzz.Text = .{};
    try arguments.generate(arena, smith, "{\"path\":\"", "\"}", true);

    // Each output item has its own index. Its closing `output_item.done`
    // event is optional, and when sent it repeats the complete text.
    var wire_buffer: std.Io.Writer.Allocating = .init(arena);
    const wire = &wire_buffer.writer;
    var index: usize = 0;
    if (reasoning.text.items.len > 0) {
        try wire.print("data: {{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{{\"type\":\"reasoning\"}}}}\n\n", .{index});
        for (try reasoning.pieces(arena)) |piece| {
            try wire.print("data: {{\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":{d},\"delta\":{f}}}\n\n", .{ index, std.json.fmt(piece, .{}) });
        }
        if (smith.boolWeighted(1, 1)) {
            try wire.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"opaque\"}}}}\n\n", .{index});
        }
        index += 1;
    }
    if (content.text.items.len > 0) {
        try wire.print("data: {{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{{\"type\":\"message\"}}}}\n\n", .{index});
        for (try content.pieces(arena)) |piece| {
            if (smith.boolWeighted(1, 7)) try wire.writeAll(": ping\n\n");
            try wire.print("data: {{\"type\":\"response.output_text.delta\",\"output_index\":{d},\"delta\":{f}}}\n\n", .{ index, std.json.fmt(piece, .{}) });
        }
        if (smith.boolWeighted(1, 1)) {
            try wire.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":{f}}}]}}}}\n\n", .{ index, std.json.fmt(content.text.items, .{}) });
        }
        index += 1;
    }
    if (with_tool) {
        try wire.print("data: {{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\"}}}}\n\n", .{index});
        for (try arguments.pieces(arena)) |piece| {
            try wire.print("data: {{\"type\":\"response.function_call_arguments.delta\",\"output_index\":{d},\"delta\":{f}}}\n\n", .{ index, std.json.fmt(piece, .{}) });
        }
        if (smith.boolWeighted(1, 1)) {
            try wire.print("data: {{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":{f}}}}}\n\n", .{ index, std.json.fmt(arguments.text.items, .{}) });
        }
    }
    try wire.writeAll("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4}}}\n\n");

    const read_buffer = try stream_fuzz.readBuffer(arena, smith);
    var fixed = std.Io.Reader.fixed(wire_buffer.written());
    var source = fixed.limited(.unlimited, read_buffer);
    var deltas: stream_fuzz.Deltas = .{ .alloc = arena };
    var cancelled = std.atomic.Value(bool).init(false);
    const completion = try consumeSse(std.testing.allocator, &source.interface, &deltas, stream_fuzz.Deltas.onContent, null, stream_fuzz.Deltas.onReasoning, null, &cancelled, null, .{}, null);
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
        if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
    }

    try std.testing.expectEqualStrings(content.text.items, completion.content orelse "");
    try deltas.expectEqual(content.text.items, reasoning.text.items);
    try stream_fuzz.expectToolCall(completion.tool_calls, with_tool, "call_1", arguments.text.items);
}

test "Responses streams give the same result however they are cut into events and reads" {
    try std.testing.fuzz({}, fuzzResponsesChunkedStream, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").responses_stream.*),
    });
}
