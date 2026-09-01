const std = @import("std");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const responses_protocol = @import("responses_protocol.zig");
const responses_sse = @import("responses_sse.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    endpoint: []const u8,
    extra_headers: []const std.http.Header = &.{},
    max_error_body_bytes: usize,
    error_limit_message: []const u8,
    connect_timeout_ms: i64 = 30_000,
    stream_limits: responses_sse.Limits,
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
    authorization: []const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.authorization },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

pub fn stream(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    config: Config,
) !stream_provider.Result {
    var result = stream_inner(alloc, request, payload, config) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
        if (deadline_expired(request.deadline)) return stream_provider.failResult(error.Timeout);
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (deadline_expired(request.deadline)) {
        result.deinit(alloc);
        return stream_provider.failResult(error.Timeout);
    }
    return result;
}

fn stream_inner(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    config: Config,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    const uri = try std.Uri.parse(config.endpoint);
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret});
    defer secret.zeroAndFree(alloc, authorization);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = config.extra_headers,
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(config.connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) connect_deadline = deadline;
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
        const detail = reader.allocRemaining(alloc, .limited(config.max_error_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, config.error_limit_message),
            else => return err,
        };
        return .{ .failed = .{
            .kind = failure_kind(response.head.status),
            .detail = detail,
            .ownership = .owned,
        } };
    }

    var transfer: [256 * 1024]u8 = undefined;
    var events = request.events;
    const completion = try responses_sse.consume(alloc, response.reader(&transfer), .{
        .context = &events,
        .on_content = EventBridge.content,
        .on_tool_start = EventBridge.tool_start,
        .on_reasoning = EventBridge.reasoning,
        .on_tool_input = EventBridge.tool_input,
    }, request.cancel_flag, request.content_capture_limit, config.stream_limits);
    return .{ .completed = .{
        .completion = completion,
        .usage = .{ .unavailable = .possibly_billed },
        .ownership = .owned,
    } };
}

fn deadline_expired(deadline: ?std.Io.Clock.Timestamp) bool {
    const value = deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, value);
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, value: []const u8) void {
        sink(raw).emit(.{ .content_delta = value });
    }

    fn reasoning(raw: *anyopaque, value: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = value });
    }

    fn tool_input(raw: *anyopaque, value: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = value });
    }

    fn tool_start(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

fn failure_kind(status: std.http.Status) stream_provider.FailureKind {
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
