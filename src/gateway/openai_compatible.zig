const std = @import("std");
const openai_json = @import("../core/gateway/openai_json.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const secret = @import("../core/auth/secret.zig");
const openai_client = @import("openai_client.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes: usize = 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;
const default_base_url = "https://api.openai.com/v1";
pub const base_url_env = "FX_OPENAI_BASE_URL";
pub const e2e_endpoint_env = "FX_E2E_OPENAI_CHAT_URL";

pub const agent_stream_provider = stream_provider.Provider{
    .context = null,
    .stream_fn = streamCompletion,
};

pub fn resolveBaseUrl() []const u8 {
    const raw = io_mod.getenv(base_url_env) orelse return default_base_url;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_base_url;
    return trimmed;
}

fn chatUrl(alloc: Allocator) ![]u8 {
    const base = std.mem.trimEnd(u8, resolveBaseUrl(), "/");
    if (std.mem.endsWith(u8, base, "/chat/completions")) return alloc.dupe(u8, base);
    return std.fmt.allocPrint(alloc, "{s}/chat/completions", .{base});
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 1024) return error.InvalidOpenAiModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAiModel;
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
    return openai_json.buildChatCompletionsBody(
        alloc,
        request.model,
        null,
        request.messages,
        request.tool_choice,
        request.max_output_tokens,
        if (request.budget) |budget|
            .{ .deadline = budget.deadline, .cancel_flag = budget.cancel_flag }
        else
            null,
    );
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
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

fn requestDeadlineExpired(request: stream_provider.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*req| req.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const req = self.request.?;
        self.request = null;
        return req;
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
            .extra_headers = &.{
                .{ .name = "accept", .value = "text/event-stream" },
            },
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamCompletionCore(alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential.source) |source| {
        if (source != .stored_key) return error.OpenAiCompatibleCredentialRequired;
    } else {
        return error.OpenAiCompatibleCredentialRequired;
    }
    try validateModel(request.model);
    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);
    const request_endpoint = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenAiEndpoint;
        break :endpoint override;
    } else try chatUrl(alloc);
    defer if (io_mod.getenv(e2e_endpoint_env) == null) alloc.free(@constCast(request_endpoint));
    const uri = try std.Uri.parse(request_endpoint);

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret});
    defer secret.zeroAndFree(alloc, @constCast(auth_header));

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
            error.StreamTooLong => try alloc.dupe(u8, "OpenAI-compatible error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "OpenAI-compatible error response exceeded the local limit");
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
    const completion = try openai_client.consumeOpenAiSse(
        alloc,
        reader,
        &events,
        request.cancel_flag,
        request.content_capture_limit,
    );
    return .{ .completed = .{
        .completion = completion,
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
