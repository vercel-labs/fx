//! WebSocket-first transport for the OpenAI Codex Responses endpoint.
//!
//! The wire contract mirrors the Codex CLI and pi clients: the HTTP Responses
//! endpoint is upgraded to a WebSocket (`OpenAI-Beta: responses_websockets`),
//! the request body is sent as one text frame with `"type":"response.create"`
//! prepended, and each received text frame carries one Responses stream event
//! — the same JSON payloads the SSE transport delivers in `data:` lines, so
//! both transports share `responses_protocol.Reducer`.
//!
//! Transport policy, mirrored from the reference clients:
//! - opt-in via `FX_OPENAI_CODEX_TRANSPORT=websocket`;
//! - one process-wide fallback latch: after a WebSocket transport failure the
//!   process stops attempting WebSocket so a broken proxy is paid for once;
//! - a connection is cached per (session, account) and reused across turns;
//!   a busy or mismatched cache entry yields a fresh uncached connection;
//! - a reused connection that fails before any model output is replaced by a
//!   fresh connection once before the caller falls back to SSE;
//! - fallback decisions after model output has been emitted are forbidden —
//!   the caller surfaces the error instead of replaying the request.

const std = @import("std");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const responses_protocol = @import("responses_protocol.zig");
const websocket = @import("websocket.zig");

const Allocator = std.mem.Allocator;

const endpoint = "https://chatgpt.com/backend-api/codex/responses";
const e2e_endpoint_env = "FX_E2E_OPENAI_CODEX_RESPONSES_URL";
const transport_env = "FX_OPENAI_CODEX_TRANSPORT";
const beta_header_value = "responses_websockets=2026-02-06";

const connect_timeout_ms: i64 = 15_000;
const idle_ttl_ms: i64 = 5 * std.time.ms_per_min;
const max_age_ms: i64 = 55 * std.time.ms_per_min;

// Stream limits mirror the SSE transport in openai_codex.zig so switching
// transports never changes what the client accepts.
const max_ws_message_bytes: usize = 32 * 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_provider_state_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;

const stream_limits = responses_protocol.StreamLimits{
    .aggregate_bytes = max_sse_aggregate_bytes,
    .events = max_events,
    .tool_calls = max_tool_calls,
    .tool_identity_bytes = max_tool_identity_bytes,
    .tool_arguments_bytes = max_tool_arguments_bytes,
    .provider_state_bytes = max_provider_state_bytes,
};

pub const TransportMode = enum { sse, websocket };

pub fn transportMode() TransportMode {
    const value = io_mod.getenv(transport_env) orelse return .sse;
    if (std.ascii.eqlIgnoreCase(value, "websocket") or std.ascii.eqlIgnoreCase(value, "ws")) {
        return .websocket;
    }
    return .sse;
}

/// Once a WebSocket attempt fails in a way the caller decided to fall back
/// from, the rest of the process sticks to SSE: a deterministically broken
/// path (proxy, firewall) should cost one failed handshake, not one per turn.
var sse_fallback_active = std.atomic.Value(bool).init(false);

pub fn webSocketAvailable() bool {
    return transportMode() == .websocket and !sse_fallback_active.load(.seq_cst);
}

pub fn armSseFallback(err: anyerror) void {
    sse_fallback_active.store(true, .seq_cst);
    debug_trace.logf(
        "stream",
        "Codex WebSocket transport disabled for this process error={s}",
        .{@errorName(err)},
    );
}

/// Errors that indicate the provider processed (and refused) the request, or
/// that a resource limit fired locally, must not trigger an SSE replay: the
/// replay would repeat the same failure at full request cost.
pub fn errorAllowsSseFallback(err: anyerror) bool {
    return switch (err) {
        error.Cancelled,
        error.OutOfMemory,
        error.OpenAICodexResponseFailed,
        error.OpenAICodexToolCallLimitExceeded,
        error.OpenAICodexToolArgumentsTooLarge,
        error.OpenAICodexResourceLimitExceeded,
        error.ProviderAdmissionMissing,
        error.ProviderAdmissionRepeated,
        => false,
        else => true,
    };
}

pub fn streamViaWebSocket(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    output_emitted: *bool,
) !stream_provider.Result {
    const url = if (io_mod.getenv(e2e_endpoint_env)) |override| url: {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenAICodexEndpoint;
        break :url override;
    } else endpoint;
    return streamViaWebSocketAtUrl(alloc, request, payload, url, output_emitted);
}

pub fn streamViaWebSocketAtUrl(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    url: []const u8,
    output_emitted: *bool,
) !stream_provider.Result {
    output_emitted.* = false;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const account_id = try chatgpt_oauth.extractAccountId(alloc, request.credential.secret);
    defer alloc.free(account_id);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret});
    defer secret.zeroAndFree(alloc, auth_header);

    // One admission covers the whole WebSocket attempt cycle, including the
    // single fresh-connection retry below and the caller's SSE fallback.
    try request.admission.admit();

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const acquired = try acquireConnection(alloc, request, url, auth_header, account_id);
        debug_trace.eventf(
            "stream",
            "codex_ws_connection",
            request.trace_ctx,
            "reused={any} cacheable={any}",
            .{ acquired.reused, acquired.cacheable },
        );
        if (runOnConnection(alloc, request, payload, acquired.conn, output_emitted)) |result| {
            releaseConnection(acquired, true);
            return result;
        } else |err| {
            releaseConnection(acquired, false);
            const retry_with_fresh = acquired.reused and attempt == 0 and
                !output_emitted.* and
                err != error.Cancelled and err != error.OutOfMemory;
            if (retry_with_fresh) {
                debug_trace.eventf(
                    "stream",
                    "codex_ws_reused_connection_replaced",
                    request.trace_ctx,
                    "error={s}",
                    .{@errorName(err)},
                );
                continue;
            }
            return err;
        }
    }
}

// ---------------------------------------------------------------------------
// Connection lifecycle
// ---------------------------------------------------------------------------

const WsConnection = struct {
    arena_state: std.heap.ArenaAllocator,
    client: std.http.Client,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    reader: *std.Io.Reader,
    session_key: ?[]u8,
    created_at_ms: i64,
    last_used_ms: i64,

    fn connectionRef(self: *WsConnection) *std.http.Client.Connection {
        return self.request.connection.?;
    }

    fn netStream(self: *WsConnection) std.Io.net.Stream {
        return self.connectionRef().stream_writer.stream;
    }

    fn destroy(self: *WsConnection) void {
        // Shut the socket down first so releasing the request can never block
        // draining a live stream.
        self.netStream().shutdown(io_mod.getIo(), .both) catch {};
        self.request.deinit();
        self.client.deinit();
        var arena = self.arena_state;
        arena.deinit();
    }

    /// `runBoundedHttpOperation` cleanup contract for late arrivals.
    pub fn deinit(self: *WsConnection, _: Allocator) void {
        self.destroy();
    }
};

const cache_mutex_state = struct {
    var mutex: std.Io.Mutex = .init;
    var entry: ?*WsConnection = null;
    var entry_busy: bool = false;

    fn lock() void {
        mutex.lockUncancelable(io_mod.getIo());
    }

    fn unlock() void {
        mutex.unlock(io_mod.getIo());
    }
};

const Acquired = struct {
    conn: *WsConnection,
    reused: bool,
    cacheable: bool,
};

fn sessionKey(alloc: Allocator, session_id: []const u8, account_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ session_id, account_id });
}

fn acquireConnection(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    url: []const u8,
    auth_header: []const u8,
    account_id: []const u8,
) !Acquired {
    const session_id: ?[]const u8 = if (request.session_id) |sid|
        (if (sid.len > 0) sid else null)
    else
        null;
    const key: ?[]u8 = if (session_id) |sid| try sessionKey(alloc, sid, account_id) else null;
    defer if (key) |value| alloc.free(value);

    if (key) |wanted| {
        var evicted: ?*WsConnection = null;
        var reusable: ?*WsConnection = null;
        {
            cache_mutex_state.lock();
            defer cache_mutex_state.unlock();
            if (cache_mutex_state.entry) |conn| {
                if (!cache_mutex_state.entry_busy) {
                    const now = io_mod.milliTimestamp();
                    const matches = conn.session_key != null and
                        std.mem.eql(u8, conn.session_key.?, wanted);
                    const expired = now - conn.created_at_ms >= max_age_ms or
                        now - conn.last_used_ms >= idle_ttl_ms;
                    if (matches and !expired) {
                        cache_mutex_state.entry_busy = true;
                        reusable = conn;
                    } else {
                        cache_mutex_state.entry = null;
                        evicted = conn;
                    }
                }
                // A busy entry stays untouched; this request uses a one-off
                // connection so concurrent turns never share one socket.
            }
        }
        if (evicted) |conn| conn.destroy();
        if (reusable) |conn| return .{ .conn = conn, .reused = true, .cacheable = true };
    }

    const conn = try connectBounded(alloc, request, url, auth_header, account_id, key);
    return .{ .conn = conn, .reused = false, .cacheable = key != null };
}

fn releaseConnection(acquired: Acquired, keep: bool) void {
    const conn = acquired.conn;
    if (!keep or !acquired.cacheable or conn.session_key == null) {
        removeFromCache(conn);
        conn.destroy();
        return;
    }
    var displaced: ?*WsConnection = null;
    {
        cache_mutex_state.lock();
        defer cache_mutex_state.unlock();
        conn.last_used_ms = io_mod.milliTimestamp();
        if (cache_mutex_state.entry == conn) {
            cache_mutex_state.entry_busy = false;
        } else if (cache_mutex_state.entry == null) {
            cache_mutex_state.entry = conn;
            cache_mutex_state.entry_busy = false;
        } else {
            // Another connection claimed the slot while this one was in
            // flight; the newest one wins and this one is closed.
            displaced = conn;
        }
    }
    if (displaced) |value| value.destroy();
}

fn removeFromCache(conn: *WsConnection) void {
    cache_mutex_state.lock();
    defer cache_mutex_state.unlock();
    if (cache_mutex_state.entry == conn) {
        cache_mutex_state.entry = null;
        cache_mutex_state.entry_busy = false;
    }
}

/// Closes the cached connection, if any. Intended for tests and shutdown.
pub fn closeCachedConnection() void {
    var evicted: ?*WsConnection = null;
    {
        cache_mutex_state.lock();
        defer cache_mutex_state.unlock();
        if (cache_mutex_state.entry) |conn| {
            if (!cache_mutex_state.entry_busy) {
                cache_mutex_state.entry = null;
                evicted = conn;
            }
        }
    }
    if (evicted) |conn| conn.destroy();
}

const ConnectOperation = struct {
    url: []const u8,
    auth_header: []const u8,
    account_id: []const u8,
    session_id: ?[]const u8,
    session_key: ?[]const u8,

    pub fn run(self: *@This()) !*WsConnection {
        return createConnection(
            self.url,
            self.auth_header,
            self.account_id,
            self.session_id,
            self.session_key,
        );
    }
};

fn connectBounded(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    url: []const u8,
    auth_header: []const u8,
    account_id: []const u8,
    session_key: ?[]const u8,
) !*WsConnection {
    var operation = ConnectOperation{
        .url = url,
        .auth_header = auth_header,
        .account_id = account_id,
        .session_id = request.session_id,
        .session_key = session_key,
    };
    return gateway_client.runBoundedHttpOperation(
        *WsConnection,
        alloc,
        request.cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(connect_timeout_ms),
        }),
        &operation,
    );
}

fn createConnection(
    url: []const u8,
    auth_header: []const u8,
    account_id: []const u8,
    session_id: ?[]const u8,
    session_key: ?[]const u8,
) !*WsConnection {
    var boot = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const self = boot.allocator().create(WsConnection) catch |err| {
        boot.deinit();
        return err;
    };
    self.* = undefined;
    self.arena_state = boot;
    initConnection(self, url, auth_header, account_id, session_id, session_key) catch |err| {
        var arena = self.arena_state;
        arena.deinit();
        return err;
    };
    return self;
}

fn initConnection(
    self: *WsConnection,
    url: []const u8,
    auth_header: []const u8,
    account_id: []const u8,
    session_id: ?[]const u8,
    session_key: ?[]const u8,
) !void {
    const arena = self.arena_state.allocator();
    const now = io_mod.milliTimestamp();
    self.created_at_ms = now;
    self.last_used_ms = now;
    self.session_key = if (session_key) |key| try arena.dupe(u8, key) else null;

    // `Request.uri` borrows this memory for the request's lifetime.
    const url_copy = try arena.dupe(u8, url);
    const uri = try std.Uri.parse(url_copy);

    var random_key: [16]u8 = undefined;
    io_mod.getIo().random(&random_key);
    const sec_key = websocket.secKey(random_key);
    const expected_accept = websocket.acceptKey(&sec_key);

    var extra_headers_buf: [8]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "upgrade", .value = "websocket" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "sec-websocket-version", .value = "13" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "sec-websocket-key", .value = &sec_key };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "chatgpt-account-id", .value = account_id };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "originator", .value = "fx" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "OpenAI-Beta", .value = beta_header_value };
    extra_count += 1;
    if (session_id) |sid| if (sid.len > 0) {
        extra_headers_buf[extra_count] = .{ .name = "session-id", .value = sid };
        extra_count += 1;
        extra_headers_buf[extra_count] = .{ .name = "x-client-request-id", .value = sid };
        extra_count += 1;
    };

    self.client = .{ .allocator = arena, .io = io_mod.getIo() };
    errdefer self.client.deinit();
    self.request = try self.client.request(.GET, uri, .{
        .headers = .{
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = gateway_client.user_agent },
            .accept_encoding = .omit,
            .connection = .{ .override = "Upgrade" },
        },
        .extra_headers = extra_headers_buf[0..extra_count],
        .keep_alive = true,
        .redirect_behavior = .unhandled,
    });
    errdefer self.request.deinit();
    try self.request.sendBodiless();
    self.response = try self.request.receiveHead(&.{});
    if (self.response.head.status != .switching_protocols) {
        return error.WebSocketHandshakeRejected;
    }
    try verifyHandshakeHeaders(self.response.head.bytes, &expected_accept);

    const transfer_buffer = try arena.alloc(u8, transfer_buffer_bytes);
    self.reader = self.response.reader(transfer_buffer);
}

fn verifyHandshakeHeaders(head_bytes: []const u8, expected_accept: []const u8) !void {
    var saw_upgrade = false;
    var saw_accept = false;
    var it = std.http.HeaderIterator.init(head_bytes);
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
            if (!std.ascii.eqlIgnoreCase(header.value, "websocket")) {
                return error.WebSocketHandshakeInvalid;
            }
            saw_upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
            if (!std.mem.eql(u8, header.value, expected_accept)) {
                return error.WebSocketHandshakeInvalid;
            }
            saw_accept = true;
        }
    }
    if (!saw_upgrade or !saw_accept) return error.WebSocketHandshakeInvalid;
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

const TrackingSink = struct {
    inner: stream_provider.EventSink,
    emitted: *bool,

    fn emit(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *TrackingSink = @ptrCast(@alignCast(raw));
        self.emitted.* = true;
        self.inner.emit(event);
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        const self: *TrackingSink = @ptrCast(@alignCast(raw));
        self.emitted.* = true;
        self.inner.emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        const self: *TrackingSink = @ptrCast(@alignCast(raw));
        self.emitted.* = true;
        self.inner.emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        const self: *TrackingSink = @ptrCast(@alignCast(raw));
        self.emitted.* = true;
        self.inner.emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        const self: *TrackingSink = @ptrCast(@alignCast(raw));
        self.emitted.* = true;
        self.inner.emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

fn runOnConnection(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
    conn: *WsConnection,
    output_emitted: *bool,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = try gateway_client.spawnHttpCancelWatcher(
        &cancel_watch_done,
        request.cancel_flag,
        conn.netStream(),
    );
    defer {
        cancel_watch_done.store(true, .seq_cst);
        cancel_watcher.join();
    }

    // The SSE body is a complete JSON object; the WebSocket request is the
    // same object with the message type prepended.
    if (payload.len < 2 or payload[0] != '{') return error.InvalidOpenAICodexRequestPayload;
    const ws_payload = try std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"response.create\",{s}",
        .{payload[1..]},
    );
    defer secret.zeroAndFree(alloc, ws_payload);

    request.delivery.markPossiblySent();
    sendFrame(conn, .text, ws_payload) catch |err| return wsIoError(request, err);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var tracking = TrackingSink{ .inner = request.events, .emitted = output_emitted };
    var completion = try consumeWebSocket(alloc, request, conn, &tracking);
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

fn wsIoError(request: stream_provider.ModelRequest, err: anyerror) anyerror {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    return err;
}

fn sendFrame(conn: *WsConnection, opcode: websocket.Opcode, payload: []const u8) !void {
    var mask: [4]u8 = undefined;
    io_mod.getIo().random(&mask);
    const connection = conn.connectionRef();
    try websocket.writeClientFrame(connection.writer(), opcode, payload, mask);
    try connection.flush();
}

fn consumeWebSocket(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    conn: *WsConnection,
    tracking: *TrackingSink,
) !types.ModelCompletion {
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(alloc);
    const callbacks = responses_protocol.StreamCallbacks{
        .context = tracking,
        .on_content = TrackingSink.content,
        .on_tool_start = TrackingSink.toolStart,
        .on_reasoning = TrackingSink.reasoning,
        .on_tool_input = TrackingSink.toolInput,
    };
    while (true) {
        const message = nextTextMessage(alloc, request, conn, &scratch) catch |err|
            return wsIoError(request, err);
        const json_text = message orelse break;
        if (reducer.applyJson(
            alloc,
            json_text,
            callbacks,
            request.cancel_flag,
            request.content_capture_limit,
            stream_limits,
        ) catch |err| return mapReducerError(err)) break;
    }
    return reducer.finish(alloc, request.cancel_flag, stream_limits) catch |err|
        return mapReducerError(err);
}

/// Reads the next complete text message, transparently answering pings and
/// treating a close frame or clean socket end as end-of-stream (`null`).
/// The reducer decides whether an end-of-stream at that point is an error.
fn nextTextMessage(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    conn: *WsConnection,
    scratch: *std.ArrayList(u8),
) !?[]const u8 {
    scratch.clearRetainingCapacity();
    var assembling = false;
    while (true) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const head = websocket.readFrameHead(conn.reader, max_ws_message_bytes) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        switch (head.opcode) {
            .ping => {
                var control: std.ArrayList(u8) = .empty;
                defer control.deinit(alloc);
                try websocket.readPayloadInto(alloc, conn.reader, head, &control);
                try sendFrame(conn, .pong, control.items);
            },
            .pong => {
                var control: std.ArrayList(u8) = .empty;
                defer control.deinit(alloc);
                try websocket.readPayloadInto(alloc, conn.reader, head, &control);
            },
            .close => return null,
            .text, .binary => {
                if (assembling) return error.WebSocketProtocolError;
                try websocket.readPayloadInto(alloc, conn.reader, head, scratch);
                if (head.fin) return scratch.items;
                assembling = true;
            },
            .continuation => {
                if (!assembling) return error.WebSocketProtocolError;
                if (head.len > max_ws_message_bytes - scratch.items.len) {
                    return error.WebSocketFrameTooLarge;
                }
                try websocket.readPayloadInto(alloc, conn.reader, head, scratch);
                if (head.fin) return scratch.items;
            },
            _ => return error.WebSocketProtocolError,
        }
    }
}

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidEvent => error.InvalidOpenAICodexSseEvent,
        error.ResponseFailed => error.OpenAICodexResponseFailed,
        error.StreamIncomplete => error.OpenAICodexStreamIncomplete,
        error.ToolCallLimitExceeded => error.OpenAICodexToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.OpenAICodexToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.OpenAICodexResourceLimitExceeded,
        else => err,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_ws_events = [_][]const u8{
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\"}}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"hello\"}",
    "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4}}}",
};

fn testChatGptJwt(alloc: Allocator) ![]u8 {
    const claims = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-test\"}}";
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(claims.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, claims);
    return std.fmt.allocPrint(alloc, "h.{s}.s", .{encoded});
}

const WsLoopbackMode = enum { serve, reject_handshake };

const WsLoopbackFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    mode: WsLoopbackMode,
    thread: ?std.Thread = null,
    server_open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    accept_count: std.atomic.Value(usize) = .init(0),
    request_count: std.atomic.Value(usize) = .init(0),
    saw_response_create: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn init(mode: WsLoopbackMode) !@This() {
        var fixture: @This() = .{ .server = undefined, .mode = mode };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.server_open) return;
        const zio = self.io();
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            self.wakeAccept();
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

    fn url(self: *@This(), alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{self.port()});
    }

    fn wakeAccept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        var stream = address.connect(zio, .{ .mode = .stream }) catch return;
        stream.close(zio);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst)) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        while (!self.stopping.load(.seq_cst)) {
            var stream = self.server.accept(zio) catch |err| {
                if (self.stopping.load(.seq_cst)) return;
                return err;
            };
            defer stream.close(zio);
            if (self.stopping.load(.seq_cst)) return;
            _ = self.accept_count.fetchAdd(1, .seq_cst);
            self.handleConnection(zio, stream) catch |err| switch (err) {
                error.EndOfStream => continue,
                else => return err,
            };
        }
    }

    fn handleConnection(self: *@This(), zio: std.Io, stream: std.Io.net.Stream) !void {
        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(zio, &read_buffer);
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(zio, &write_buffer);

        var head: [16 * 1024]u8 = undefined;
        var head_len: usize = 0;
        while (head_len < head.len) {
            head[head_len] = reader.interface.takeByte() catch return error.EndOfStream;
            head_len += 1;
            if (std.mem.endsWith(u8, head[0..head_len], "\r\n\r\n")) break;
        } else return error.TestRequestTooLarge;

        if (self.mode == .reject_handshake) {
            try writer.interface.writeAll("HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
            try writer.interface.flush();
            return;
        }

        const key = headerValue(head[0..head_len], "sec-websocket-key") orelse
            return error.TestHandshakeKeyMissing;
        const accept = websocket.acceptKey(key);
        try writer.interface.print(
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "upgrade: websocket\r\n" ++
                "connection: Upgrade\r\n" ++
                "sec-websocket-accept: {s}\r\n\r\n",
            .{accept},
        );
        try writer.interface.flush();

        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(std.heap.page_allocator);
        while (!self.stopping.load(.seq_cst)) {
            scratch.clearRetainingCapacity();
            const frame_head = websocket.readFrameHead(&reader.interface, 1 << 20) catch return error.EndOfStream;
            if (frame_head.opcode == .close) return error.EndOfStream;
            if (frame_head.opcode != .text) return error.TestUnexpectedFrame;
            try websocket.readPayloadInto(std.heap.page_allocator, &reader.interface, frame_head, &scratch);
            if (std.mem.startsWith(u8, scratch.items, "{\"type\":\"response.create\",")) {
                self.saw_response_create.store(true, .seq_cst);
            }
            _ = self.request_count.fetchAdd(1, .seq_cst);
            for (test_ws_events) |event| {
                try writeServerTextFrame(&writer.interface, event);
            }
            try writer.interface.flush();
        }
    }
};

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn writeServerTextFrame(writer: *std.Io.Writer, payload: []const u8) !void {
    std.debug.assert(payload.len <= std.math.maxInt(u16));
    if (payload.len <= 125) {
        try writer.writeAll(&.{ 0x81, @as(u8, @intCast(payload.len)) });
    } else {
        var head: [4]u8 = .{ 0x81, 126, 0, 0 };
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        try writer.writeAll(&head);
    }
    try writer.writeAll(payload);
}

const WsTestHarness = struct {
    content: std.ArrayList(u8) = .empty,
    admissions: usize = 0,

    fn emit(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .content_delta => |chunk| self.content.appendSlice(std.testing.allocator, chunk) catch unreachable,
            else => {},
        }
    }

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.admissions += 1;
    }
};

fn runWsTestRequest(
    alloc: Allocator,
    harness: *WsTestHarness,
    token: []const u8,
    url: []const u8,
    output_emitted: *bool,
) !stream_provider.Result {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    return streamViaWebSocketAtUrl(alloc, .{
        .credential = .{ .secret = token, .source = .chatgpt_subscription },
        .session_id = "sess-ws-test",
        .model = "gpt-test",
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .none,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = harness, .emit_fn = WsTestHarness.emit },
        .admission = .{ .context = harness, .admit_fn = WsTestHarness.admit },
        .cancel_flag = &cancelled,
    }, "{\"model\":\"gpt-test\",\"stream\":true}", url, output_emitted);
}

test "Codex WebSocket transport streams a completion and reuses the connection" {
    const alloc = std.testing.allocator;
    var fixture = try WsLoopbackFixture.init(.serve);
    defer fixture.deinit();
    try fixture.start();
    defer closeCachedConnection();

    const token = try testChatGptJwt(alloc);
    defer alloc.free(token);
    const url = try fixture.url(alloc);
    defer alloc.free(url);

    var harness = WsTestHarness{};
    defer harness.content.deinit(alloc);

    for (0..2) |round| {
        var output_emitted = false;
        var result = try runWsTestRequest(alloc, &harness, token, url, &output_emitted);
        defer result.deinit(alloc);
        try std.testing.expect(output_emitted);
        switch (result) {
            .completed => |completed| {
                try std.testing.expect(completed.completion.content != null);
                try std.testing.expectEqualStrings("hello", completed.completion.content.?);
                try std.testing.expectEqual(@as(?u64, 10), completed.completion.usage.input_tokens);
            },
            else => return error.TestExpectedCompletion,
        }
        try std.testing.expectEqual(round + 1, harness.admissions);
    }

    try std.testing.expectEqualStrings("hellohello", harness.content.items);
    try std.testing.expectEqual(@as(usize, 1), fixture.accept_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.request_count.load(.seq_cst));
    try std.testing.expect(fixture.saw_response_create.load(.seq_cst));
    if (fixture.failure) |err| return err;
}

test "Codex WebSocket handshake rejection is fallback safe" {
    const alloc = std.testing.allocator;
    var fixture = try WsLoopbackFixture.init(.reject_handshake);
    defer fixture.deinit();
    try fixture.start();
    defer closeCachedConnection();

    const token = try testChatGptJwt(alloc);
    defer alloc.free(token);
    const url = try fixture.url(alloc);
    defer alloc.free(url);

    var harness = WsTestHarness{};
    defer harness.content.deinit(alloc);

    var output_emitted = true;
    const result = runWsTestRequest(alloc, &harness, token, url, &output_emitted);
    try std.testing.expectError(error.WebSocketHandshakeRejected, result);
    try std.testing.expect(!output_emitted);
    try std.testing.expect(errorAllowsSseFallback(error.WebSocketHandshakeRejected));
    try std.testing.expectEqual(@as(usize, 1), harness.admissions);
}

test "Codex WebSocket fallback classification blocks provider refusals" {
    try std.testing.expect(!errorAllowsSseFallback(error.OpenAICodexResponseFailed));
    try std.testing.expect(!errorAllowsSseFallback(error.Cancelled));
    try std.testing.expect(!errorAllowsSseFallback(error.OutOfMemory));
    try std.testing.expect(errorAllowsSseFallback(error.WebSocketHandshakeInvalid));
    try std.testing.expect(errorAllowsSseFallback(error.Timeout));
    try std.testing.expect(errorAllowsSseFallback(error.EndOfStream));
}
