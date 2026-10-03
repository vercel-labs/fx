const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

pub const max_frame_bytes: usize = 4 * 1024 * 1024;
pub const max_message_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{
    WebSocketUpgradeRejected,
    WebSocketConnectTimeout,
    WebSocketAcceptInvalid,
    WebSocketProtocolViolation,
    WebSocketUnexpectedBinary,
    WebSocketMessageTooLarge,
    WebSocketInvalidUtf8,
    WebSocketPolicyClosed,
    WebSocketClosedBeforeCompletion,
};

pub const EventHandler = *const fn (context: *anyopaque, json: []const u8) anyerror!bool;

const default_connect_timeout_ms: i64 = 30_000;
const default_event_idle_timeout_ms: i64 = 30_000;
const connect_timeout_env = "FX_CODEX_WEBSOCKET_CONNECT_TIMEOUT_MS";
const event_idle_timeout_env = "FX_CODEX_WEBSOCKET_EVENT_IDLE_TIMEOUT_MS";

pub const ConnectArgs = struct {
    endpoint: []const u8,
    authorization: []const u8,
    account_id: []const u8,
    session_id: ?[]const u8,
    deadline: ?std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
    delivery: *gateway_client.DeliveryCertainty,
    upgrade_status: ?*?std.http.Status = null,
};

pub const StreamArgs = struct {
    endpoint: []const u8,
    authorization: []const u8,
    account_id: []const u8,
    session_id: ?[]const u8,
    payload: []const u8,
    deadline: ?std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
    delivery: *gateway_client.DeliveryCertainty,
};

pub const Request = StreamArgs;

pub const Connection = struct {
    alloc: Allocator,
    client: std.http.Client,
    request: std.http.Client.Request,
    opened_at_ms: i64,
    close_sent: bool = false,
    watcher_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    timeout_fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_progress_ms: std.atomic.Value(i64),
    watcher: ?std.Thread = null,

    fn socket(self: *Connection) !*std.http.Client.Connection {
        return self.request.connection orelse error.WebSocketConnectionMissing;
    }

    fn startWatcher(self: *Connection, cancel_flag: *std.atomic.Value(bool), deadline: ?std.Io.Clock.Timestamp, idle_timeout_ms: i64) !void {
        if (idle_timeout_ms <= 0) return error.InvalidOpenAICodexTransport;
        self.watcher_done.store(false, .seq_cst);
        self.timeout_fired.store(false, .seq_cst);
        self.last_progress_ms.store(io_mod.milliTimestamp(), .seq_cst);
        const http_connection = try self.socket();
        self.watcher = try spawnConnectionWatcher(
            &self.watcher_done,
            cancel_flag,
            deadline,
            &self.timeout_fired,
            &self.last_progress_ms,
            idle_timeout_ms,
            http_connection.stream_writer.stream,
        );
    }

    fn stopWatcher(self: *Connection) void {
        self.watcher_done.store(true, .seq_cst);
        if (self.watcher) |thread| thread.join();
        self.watcher = null;
    }
};

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

const OpenWebSocketOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    authorization: []const u8,
    headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.GET, self.uri, .{
            .headers = .{
                .authorization = .{ .override = self.authorization },
                .connection = .{ .override = "Upgrade" },
                .accept_encoding = .omit,
            },
            .extra_headers = self.headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn positiveTimeoutFromEnv(name: []const u8, fallback: i64) !i64 {
    const value = io_mod.getenv(name) orelse return fallback;
    const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidOpenAICodexTransport;
    if (parsed <= 0) return error.InvalidOpenAICodexTransport;
    return parsed;
}

fn connectTimeoutMs() !i64 {
    return positiveTimeoutFromEnv(connect_timeout_env, default_connect_timeout_ms);
}

fn eventIdleTimeoutMs() !i64 {
    return positiveTimeoutFromEnv(event_idle_timeout_env, default_event_idle_timeout_ms);
}

pub fn connect(alloc: Allocator, args: ConnectArgs) !*Connection {
    return connect_with_timeout(alloc, args, try connectTimeoutMs());
}

fn connect_with_timeout(alloc: Allocator, args: ConnectArgs, connect_timeout_ms: i64) !*Connection {
    if (args.upgrade_status) |status| status.* = null;
    if (args.cancel_flag.load(.seq_cst)) return error.Cancelled;
    // Validate every setting before opening a socket or spawning a watcher.
    _ = try eventIdleTimeoutMs();
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    const caller_owns_deadline = if (args.deadline) |deadline|
        !std.Io.Clock.Timestamp.compare(deadline, .gt, connect_deadline)
    else
        false;
    if (caller_owns_deadline) connect_deadline = args.deadline.?;
    const uri = try std.Uri.parse(args.endpoint);
    var nonce: [16]u8 = undefined;
    try io_mod.getIo().randomSecure(&nonce);
    var key_buffer: [std.base64.standard.Encoder.calcSize(nonce.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_buffer, &nonce);
    var accept_buffer: [std.base64.standard.Encoder.calcSize(std.crypto.hash.Sha1.digest_length)]u8 = undefined;
    const expected_accept = websocketAccept(&key_buffer, &accept_buffer);

    var extra_headers: [7]std.http.Header = undefined;
    var count: usize = 0;
    extra_headers[count] = .{ .name = "chatgpt-account-id", .value = args.account_id };
    count += 1;
    extra_headers[count] = .{ .name = "originator", .value = "fx" };
    count += 1;
    extra_headers[count] = .{ .name = "OpenAI-Beta", .value = "responses_websockets=2026-02-06" };
    count += 1;
    extra_headers[count] = .{ .name = "Upgrade", .value = "websocket" };
    count += 1;
    extra_headers[count] = .{ .name = "Sec-WebSocket-Version", .value = "13" };
    count += 1;
    extra_headers[count] = .{ .name = "Sec-WebSocket-Key", .value = &key_buffer };
    count += 1;
    if (args.session_id) |session_id| if (session_id.len > 0) {
        extra_headers[count] = .{ .name = "session-id", .value = session_id };
        count += 1;
    };

    const connection = try alloc.create(Connection);
    connection.* = undefined;
    connection.alloc = alloc;
    connection.client = .{ .allocator = alloc, .io = io_mod.getIo() };
    var initialized = false;
    errdefer {
        if (initialized) {
            abort(connection, alloc);
        } else {
            connection.client.deinit();
            alloc.destroy(connection);
        }
    }
    var open_operation = OpenWebSocketOperation{
        .client = &connection.client,
        .uri = uri,
        .authorization = args.authorization,
        .headers = extra_headers[0..count],
    };
    const timeout_error: anyerror = if (caller_owns_deadline) error.Timeout else error.WebSocketConnectTimeout;
    var opened = gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        args.cancel_flag,
        connect_deadline,
        &open_operation,
    ) catch |err| {
        if (args.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (err == error.Timeout or err == error.ConnectionSetupTimedOut) return timeout_error;
        return err;
    };
    errdefer opened.deinit(alloc);
    connection.request = opened.take();
    connection.opened_at_ms = io_mod.milliTimestamp();
    connection.close_sent = false;
    connection.watcher_done = std.atomic.Value(bool).init(true);
    connection.timeout_fired = std.atomic.Value(bool).init(false);
    connection.last_progress_ms = std.atomic.Value(i64).init(connection.opened_at_ms);
    connection.watcher = null;
    initialized = true;
    try connection.startWatcher(args.cancel_flag, connect_deadline, connect_timeout_ms);
    defer connection.stopWatcher();

    connection.request.sendBodiless() catch |err| {
        if (args.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (connection.timeout_fired.load(.seq_cst)) return timeout_error;
        return err;
    };
    const response = connection.request.receiveHead(&.{}) catch |err| {
        if (args.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (connection.timeout_fired.load(.seq_cst)) return timeout_error;
        return err;
    };
    if (args.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (connection.timeout_fired.load(.seq_cst) or
        !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, connect_deadline))
        return timeout_error;
    if (response.head.status != .switching_protocols) {
        if (args.upgrade_status) |status| status.* = response.head.status;
        return error.WebSocketUpgradeRejected;
    }
    if (!hasTokenHeader(response.head, "upgrade", "websocket") or
        !hasTokenHeader(response.head, "connection", "upgrade") or
        !hasHeader(response.head, "sec-websocket-accept", expected_accept))
    {
        return error.WebSocketAcceptInvalid;
    }
    _ = try connection.socket();
    return connection;
}

fn operationError(connection: *Connection, cancel_flag: *std.atomic.Value(bool), err: anyerror) anyerror {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (connection.timeout_fired.load(.seq_cst)) return error.Timeout;
    return err;
}

pub fn ping(
    connection: *Connection,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    _: *gateway_client.DeliveryCertainty,
) !void {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const health_deadline = bounded_deadline(deadline, 2_000);
    if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, health_deadline))
        return error.Timeout;
    try connection.startWatcher(cancel_flag, health_deadline, 2_000);
    defer connection.stopWatcher();
    const socket = try connection.socket();
    const writer = socket.writer();
    var nonce: [16]u8 = undefined;
    try io_mod.getIo().randomSecure(&nonce);
    writeFrame(writer, .ping, &nonce) catch |err| return operationError(connection, cancel_flag, err);
    socket.flush() catch |err| return operationError(connection, cancel_flag, err);
    while (true) {
        const frame = readFrame(connection.alloc, connection.request.reader.in) catch |err| return operationError(connection, cancel_flag, err);
        defer connection.alloc.free(frame.payload);
        switch (frame.opcode) {
            .pong => {
                if (!std.mem.eql(u8, frame.payload, &nonce)) continue;
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                if (connection.timeout_fired.load(.seq_cst) or
                    !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, health_deadline))
                    return error.Timeout;
                return;
            },
            .ping => {
                writeFrame(writer, .pong, frame.payload) catch |err| return operationError(connection, cancel_flag, err);
                socket.flush() catch |err| return operationError(connection, cancel_flag, err);
            },
            .close => return peer_close(connection, cancel_flag, frame.payload),
            .binary => return error.WebSocketUnexpectedBinary,
            else => return error.WebSocketProtocolViolation,
        }
    }
}

pub fn streamOn(
    connection: *Connection,
    alloc: Allocator,
    request: StreamArgs,
    context: *anyopaque,
    on_event: EventHandler,
) !void {
    return stream_on_with_idle_timeout(connection, alloc, request, context, on_event, try eventIdleTimeoutMs());
}

fn stream_on_with_idle_timeout(
    connection: *Connection,
    alloc: Allocator,
    request: StreamArgs,
    context: *anyopaque,
    on_event: EventHandler,
    idle_timeout_ms: i64,
) !void {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    try connection.startWatcher(request.cancel_flag, request.deadline, idle_timeout_ms);
    defer connection.stopWatcher();
    const socket = try connection.socket();
    const reader = connection.request.reader.in;
    const writer = socket.writer();
    request.delivery.markPossiblySent();
    writeFrame(writer, .text, request.payload) catch |err| return operationError(connection, request.cancel_flag, err);
    socket.flush() catch |err| return operationError(connection, request.cancel_flag, err);
    connection.last_progress_ms.store(io_mod.milliTimestamp(), .seq_cst);

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(alloc);
    var fragmented_opcode: ?Opcode = null;
    while (true) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const frame = readFrame(alloc, reader) catch |err| return operationError(connection, request.cancel_flag, err);
        defer alloc.free(frame.payload);
        switch (frame.opcode) {
            .ping => {
                writeFrame(writer, .pong, frame.payload) catch |err| return operationError(connection, request.cancel_flag, err);
                socket.flush() catch |err| return operationError(connection, request.cancel_flag, err);
            },
            .pong => {},
            .close => return peer_close(connection, request.cancel_flag, frame.payload),
            .binary => return error.WebSocketUnexpectedBinary,
            .continuation => {
                connection.last_progress_ms.store(io_mod.milliTimestamp(), .seq_cst);
                if (fragmented_opcode == null) return error.WebSocketProtocolViolation;
                try appendMessage(&message, alloc, frame.payload);
                if (!frame.fin) continue;
                const opcode = fragmented_opcode.?;
                fragmented_opcode = null;
                if (opcode != .text) return error.WebSocketUnexpectedBinary;
                if (try dispatchTextMessage(context, on_event, message.items)) {
                    return;
                }
                message.clearRetainingCapacity();
            },
            .text => {
                connection.last_progress_ms.store(io_mod.milliTimestamp(), .seq_cst);
                if (fragmented_opcode != null) return error.WebSocketProtocolViolation;
                try appendMessage(&message, alloc, frame.payload);
                if (!frame.fin) {
                    fragmented_opcode = .text;
                    continue;
                }
                if (try dispatchTextMessage(context, on_event, message.items)) {
                    return;
                }
                message.clearRetainingCapacity();
            },
        }
    }
}

/// Destroys an owned socket without performing any graceful-close I/O.
pub fn abort(connection: *Connection, alloc: Allocator) void {
    connection.stopWatcher();
    if (connection.request.connection) |http_connection| http_connection.closing = true;
    connection.request.deinit();
    connection.client.deinit();
    alloc.destroy(connection);
}

fn bounded_deadline(caller: ?std.Io.Clock.Timestamp, timeout_ms: i64) std.Io.Clock.Timestamp {
    const own = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
    if (caller) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, own)) return deadline;
    }
    return own;
}

fn peer_close(connection: *Connection, cancel_flag: *std.atomic.Value(bool), payload: []const u8) anyerror {
    const code = validateClosePayload(payload) catch |err| return err;
    if (!connection.close_sent) {
        const socket = connection.socket() catch |err| return err;
        writeFrame(socket.writer(), .close, payload) catch |err| return operationError(connection, cancel_flag, err);
        connection.close_sent = true;
        socket.flush() catch |err| return operationError(connection, cancel_flag, err);
    }
    return closeError(code);
}

fn closeChecked(
    connection: *Connection,
    alloc: Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) !void {
    connection.stopWatcher();
    defer abort(connection, alloc);
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const close_deadline = bounded_deadline(deadline, 1_000);
    if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, close_deadline))
        return error.Timeout;
    if (!connection.close_sent) {
        try connection.startWatcher(cancel_flag, close_deadline, 1_000);
        defer connection.stopWatcher();
        const http_connection = try connection.socket();
        try closeAfterCompletion(
            alloc,
            connection.request.reader.in,
            http_connection.writer(),
            http_connection,
            cancel_flag,
            &connection.timeout_fired,
            &connection.close_sent,
        );
    }
}

pub fn close(connection: *Connection, alloc: Allocator) void {
    var cancelled = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(1_000),
    });
    closeChecked(connection, alloc, &cancelled, deadline) catch {};
}

/// Opens one socket, sends one request, and consumes one terminal response.
pub fn stream(
    alloc: Allocator,
    request: Request,
    context: *anyopaque,
    on_event: EventHandler,
) !void {
    const connection = try connect(alloc, .{
        .endpoint = request.endpoint,
        .authorization = request.authorization,
        .account_id = request.account_id,
        .session_id = request.session_id,
        .deadline = request.deadline,
        .cancel_flag = request.cancel_flag,
        .delivery = request.delivery,
    });
    var owned = true;
    defer if (owned) abort(connection, alloc);
    try streamOn(connection, alloc, request, context, on_event);
    owned = false;
    closeChecked(connection, alloc, request.cancel_flag, request.deadline) catch {};
}

const Opcode = enum(u4) { continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 };
const Frame = struct { fin: bool, opcode: Opcode, payload: []u8 };

fn websocketAccept(key: []const u8, output: []u8) []const u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hash.final(&digest);
    _ = std.base64.standard.Encoder.encode(output, &digest);
    return output;
}

fn hasHeader(head: std.http.Client.Response.Head, name: []const u8, expected: []const u8) bool {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, expected)) return true;
    }
    return false;
}

fn hasTokenHeader(head: std.http.Client.Response.Head, name: []const u8, token: []const u8) bool {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        var tokens = std.mem.splitScalar(u8, header.value, ',');
        while (tokens.next()) |candidate| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, candidate, " \t"), token)) return true;
    }
    return false;
}

fn appendMessage(message: *std.ArrayList(u8), alloc: Allocator, payload: []const u8) !void {
    if (payload.len > max_message_bytes -| message.items.len) return error.WebSocketMessageTooLarge;
    try message.appendSlice(alloc, payload);
}

fn dispatchTextMessage(context: *anyopaque, on_event: EventHandler, message: []const u8) !bool {
    if (!std.unicode.utf8ValidateSlice(message)) return error.WebSocketInvalidUtf8;
    return on_event(context, message);
}

fn closeAfterCompletion(
    alloc: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    connection: anytype,
    cancel_flag: *std.atomic.Value(bool),
    timeout_fired: *std.atomic.Value(bool),
    close_sent: *bool,
) !void {
    try writeFrame(writer, .close, &.{ 0x03, 0xe8 });
    close_sent.* = true;
    try connection.flush();
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const frame = readFrame(alloc, reader) catch |err| {
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            if (timeout_fired.load(.seq_cst)) return error.Timeout;
            return err;
        };
        defer alloc.free(frame.payload);
        switch (frame.opcode) {
            .close => {
                _ = try validateClosePayload(frame.payload);
                return;
            },
            .ping => {
                try writeFrame(writer, .pong, frame.payload);
                try connection.flush();
            },
            else => {},
        }
    }
}

fn closeError(code: ?u16) anyerror {
    if (code == 1008) return error.WebSocketPolicyClosed;
    return error.WebSocketClosedBeforeCompletion;
}

fn validateClosePayload(payload: []const u8) !?u16 {
    if (payload.len == 1) return error.WebSocketProtocolViolation;
    if (payload.len < 2) return null;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (code < 1000 or code >= 5000 or code == 1004 or code == 1005 or code == 1006 or (code >= 1015 and code < 3000)) {
        return error.WebSocketProtocolViolation;
    }
    if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.WebSocketInvalidUtf8;
    return code;
}

const ConnectionWatcher = struct {
    fn run(
        done: *std.atomic.Value(bool),
        cancel_flag: *std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
        timeout_fired: *std.atomic.Value(bool),
        last_progress_ms: *std.atomic.Value(i64),
        event_idle_timeout_ms: i64,
        socket: std.Io.net.Stream,
    ) void {
        while (!done.load(.seq_cst)) {
            if (cancel_flag.load(.seq_cst)) {
                socket.shutdown(io_mod.getIo(), .both) catch {};
                return;
            }
            if (deadline) |limit| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (!std.Io.Clock.Timestamp.compare(now, .lt, limit)) {
                    timeout_fired.store(true, .seq_cst);
                    socket.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
            }
            const elapsed_ms = io_mod.milliTimestamp() - last_progress_ms.load(.seq_cst);
            if (elapsed_ms >= event_idle_timeout_ms) {
                timeout_fired.store(true, .seq_cst);
                socket.shutdown(io_mod.getIo(), .both) catch {};
                return;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }
};

fn spawnConnectionWatcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    timeout_fired: *std.atomic.Value(bool),
    last_progress_ms: *std.atomic.Value(i64),
    event_idle_timeout_ms: i64,
    socket: std.Io.net.Stream,
) !std.Thread {
    return std.Thread.spawn(.{}, ConnectionWatcher.run, .{
        done,
        cancel_flag,
        deadline,
        timeout_fired,
        last_progress_ms,
        event_idle_timeout_ms,
        socket,
    });
}

fn writeFrame(writer: *std.Io.Writer, opcode: Opcode, payload: []const u8) !void {
    if (payload.len > max_message_bytes) return error.WebSocketMessageTooLarge;
    var mask: [4]u8 = undefined;
    try io_mod.getIo().randomSecure(&mask);
    try writer.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
    if (payload.len < 126) {
        try writer.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= std.math.maxInt(u16)) {
        try writer.writeByte(0x80 | 126);
        try writer.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try writer.writeByte(0x80 | 127);
        try writer.writeInt(u64, @intCast(payload.len), .big);
    }
    try writer.writeAll(&mask);
    var chunk: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const length = @min(chunk.len, payload.len - offset);
        for (payload[offset..][0..length], 0..) |byte, index| chunk[index] = byte ^ mask[(offset + index) % mask.len];
        try writer.writeAll(chunk[0..length]);
        offset += length;
    }
}

fn readFrame(alloc: Allocator, reader: *std.Io.Reader) !Frame {
    const first = try reader.takeByte();
    const second = try reader.takeByte();
    if (second & 0x80 != 0 or first & 0x70 != 0) return error.WebSocketProtocolViolation;
    const fin = first & 0x80 != 0;
    const opcode = std.enums.fromInt(Opcode, first & 0x0f) orelse return error.WebSocketProtocolViolation;
    var length: u64 = second & 0x7f;
    if (length == 126) {
        length = try reader.takeInt(u16, .big);
        if (length < 126) return error.WebSocketProtocolViolation;
    } else if (length == 127) {
        length = try reader.takeInt(u64, .big);
        if (length <= std.math.maxInt(u16) or length & (@as(u64, 1) << 63) != 0) return error.WebSocketProtocolViolation;
    }
    if (length > max_frame_bytes) return error.WebSocketMessageTooLarge;
    if (@intFromEnum(opcode) >= @intFromEnum(Opcode.close) and (!fin or length > 125)) return error.WebSocketProtocolViolation;
    const payload = try alloc.alloc(u8, @intCast(length));
    errdefer alloc.free(payload);
    try reader.readSliceAll(payload);
    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

test "WebSocket accept matches RFC 6455" {
    var output: [28]u8 = undefined;
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", websocketAccept("dGhlIHNhbXBsZSBub25jZQ==", &output));
}

test "WebSocket fragment aggregation limits message size" {
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(std.testing.allocator);
    try appendMessage(&message, std.testing.allocator, "hello");
    try std.testing.expectEqualStrings("hello", message.items);
}

test "WebSocket extended 127-byte frame keeps the following frame aligned" {
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try encoded.writer.writeAll(&.{ 0x81, 126, 0, 127 });
    try encoded.writer.splatByteAll('a', 127);
    try encoded.writer.writeAll(&.{ 0x81, 2, 'o', 'k' });

    var reader = std.Io.Reader.fixed(encoded.written());
    const first = try readFrame(std.testing.allocator, &reader);
    defer std.testing.allocator.free(first.payload);
    try std.testing.expectEqual(Opcode.text, first.opcode);
    try std.testing.expectEqual(@as(usize, 127), first.payload.len);

    const second = try readFrame(std.testing.allocator, &reader);
    defer std.testing.allocator.free(second.payload);
    try std.testing.expectEqual(Opcode.text, second.opcode);
    try std.testing.expectEqualStrings("ok", second.payload);
}

test "WebSocket text messages reject malformed UTF-8 before event dispatch" {
    const Handler = struct {
        fn handle(_: *anyopaque, _: []const u8) !bool {
            return false;
        }
    };
    var context: u8 = 0;
    try std.testing.expectError(
        error.WebSocketInvalidUtf8,
        dispatchTextMessage(@ptrCast(&context), Handler.handle, &.{ 0xc3, 0x28 }),
    );
}

test "WebSocket close payload rejects reserved codes and malformed UTF-8 reasons" {
    try std.testing.expectError(error.WebSocketProtocolViolation, validateClosePayload(&.{ 0x03, 0xed }));
    try std.testing.expectError(error.WebSocketInvalidUtf8, validateClosePayload(&.{ 0x03, 0xe8, 0xc3, 0x28 }));
    try std.testing.expectEqual(@as(?u16, 1000), try validateClosePayload(&.{ 0x03, 0xe8, 'o', 'k' }));
    try std.testing.expectEqual(error.WebSocketPolicyClosed, closeError(1008));
    try std.testing.expectEqual(error.WebSocketClosedBeforeCompletion, closeError(1000));
}

test "WebSocket RFC rejects nonminimal lengths and reserved close codes" {
    const frames = [_][]const u8{
        &.{ 0x81, 126, 0, 1, 'x' },
        &.{ 0x81, 127, 0, 0, 0, 0, 0, 0, 0, 1, 'x' },
    };
    for (frames) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        const result = readFrame(std.testing.allocator, &reader);
        if (result) |frame| {
            std.testing.allocator.free(frame.payload);
            return error.TestExpectedProtocolViolation;
        } else |err| try std.testing.expectEqual(error.WebSocketProtocolViolation, err);
    }
    for ([_]u16{ 1016, 1100, 2000, 2999 }) |code| {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        try std.testing.expectError(error.WebSocketProtocolViolation, validateClosePayload(&payload));
    }
}

test "WebSocket RFC close answers ping and ignores trailing data" {
    var input: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer input.deinit();
    try writeServerFrame(&input.writer, .ping, "hi");
    try writeServerFrame(&input.writer, .text, "trailing");
    try writeServerFrame(&input.writer, .pong, "unrelated");
    try writeServerFrame(&input.writer, .close, &.{ 0x03, 0xe8 });
    var reader = std.Io.Reader.fixed(input.written());
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const Socket = struct {
        writer: *std.Io.Writer,
        fn flush(self: @This()) !void {
            try self.writer.flush();
        }
    };
    var cancelled = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    var close_sent = false;
    try closeAfterCompletion(std.testing.allocator, &reader, &output.writer, Socket{ .writer = &output.writer }, &cancelled, &timed_out, &close_sent);
    const pong = output.written()[8..];
    try std.testing.expectEqual(@as(u8, 0x8a), pong[0]);
    try std.testing.expectEqual(@as(u8, 0x82), pong[1]);
    try std.testing.expectEqual(@as(u8, 'h'), pong[6] ^ pong[2]);
    try std.testing.expectEqual(@as(u8, 'i'), pong[7] ^ pong[3]);
}

test "WebSocket RFC health ping has its own short deadline" {
    var fixture = try LoopbackWebSocketFixture.init(.hang_after_upgrade);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const connection = try connect(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    });
    defer abort(connection, std.testing.allocator);
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(3_000),
    });
    try std.testing.expectError(error.Timeout, ping(connection, &cancelled, deadline, &delivery));
    try std.testing.expect(started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() < 2_800);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

const StalledWriteFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    upgraded: std.atomic.Value(bool) = .init(false),
    write_received: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    reset_after_write: bool = false,

    fn init() !@This() {
        var fixture: @This() = .{ .server = undefined };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn endpoint(self: *@This(), buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/responses", .{self.server.socket.address.getPort()});
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(self.io(), .both) catch {};
            self.wake_accept();
            thread.join();
            self.thread = null;
        }
        self.server.deinit(self.io());
    }

    fn wake_accept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.server.socket.address.getPort()) };
        var wake_stream = address.connect(zio, .{ .mode = .stream }) catch return;
        wake_stream.close(zio);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (!self.stopping.load(.seq_cst)) self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        var client_stream = try self.server.accept(zio);
        defer client_stream.close(zio);
        if (self.stopping.load(.seq_cst)) return;
        const receive_buffer: c_int = 1024;
        std.posix.setsockopt(client_stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&receive_buffer)) catch {};

        var socket_buffer: [4096]u8 = undefined;
        var reader = client_stream.reader(zio, &socket_buffer);
        var request: [16 * 1024]u8 = undefined;
        var request_len: usize = 0;
        while (request_len < request.len) {
            request[request_len] = try reader.interface.takeByte();
            request_len += 1;
            if (std.mem.endsWith(u8, request[0..request_len], "\r\n\r\n")) break;
        } else return error.TestRequestTooLarge;
        const key = headerValue(request[0 .. request_len - 4], "sec-websocket-key") orelse return error.TestMissingWebSocketKey;
        var accept_buffer: [28]u8 = undefined;
        const accept = websocketAccept(key, &accept_buffer);
        var write_buffer: [4096]u8 = undefined;
        var writer = client_stream.writer(zio, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
        try writer.interface.flush();
        self.upgraded.store(true, .seq_cst);
        _ = try reader.interface.takeByte();
        self.write_received.store(true, .seq_cst);
        if (self.reset_after_write) {
            const reset_on_close: std.posix.linger = .{ .onoff = 1, .linger = 0 };
            try std.posix.setsockopt(client_stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&reset_on_close));
            return;
        }
        while (!self.stopping.load(.seq_cst)) {
            var sleep_io: std.Io.Threaded = .init_single_threaded;
            sleep_io.io().sleep(.fromMilliseconds(1), .real) catch {};
        }
    }
};
const LoopbackMode = enum {
    never_accept,
    hang_after_upgrade,
    hold_after_request,
    withhold_upgrade,
    pause_upgrade,
    reset_after_upgrade,
    reset_after_progress,
    complete_then_hang_close,
    binary_then_close,
    ping_then_complete,
    keepalive_only,
    health_pong,
    reusable,
    oversized_frame,
};

const LoopbackWebSocketFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    mode: LoopbackMode,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    allow_upgrade: std.atomic.Value(bool) = .init(false),
    pong_received: std.atomic.Value(bool) = .init(false),
    upgraded: std.atomic.Value(bool) = .init(false),
    upgrade_received: std.atomic.Value(bool) = .init(false),
    generation_received: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    reusable_peers: [16]ReusablePeer = @splat(.{}),
    reusable_peer_count: usize = 0,
    accepted_connections: std.atomic.Value(usize) = .init(0),

    const ReusablePeer = struct {
        owner: *LoopbackWebSocketFixture = undefined,
        stream: ?std.Io.net.Stream = null,
        thread: ?std.Thread = null,
        index: usize = 0,
        requests: std.atomic.Value(usize) = .init(0),
        pings: std.atomic.Value(usize) = .init(0),
        closed: std.atomic.Value(bool) = .init(false),
        finished: bool = false,
        socket_mutex: std.Io.Mutex = .init,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.runFallible() catch |err| {
                if (!self.owner.stopping.load(.seq_cst) and err != error.EndOfStream)
                    self.failure = err;
            };
        }

        fn runFallible(self: *@This()) !void {
            var backend: std.Io.Threaded = .init_single_threaded;
            const zio = backend.io();
            const client_stream = self.stream.?;
            defer {
                self.socket_mutex.lockUncancelable(zio);
                client_stream.close(zio);
                self.finished = true;
                self.socket_mutex.unlock(zio);
            }
            var read_buffer: [4096]u8 = undefined;
            var reader = client_stream.reader(zio, &read_buffer);
            var request: [16 * 1024]u8 = undefined;
            var request_len: usize = 0;
            while (request_len < request.len) {
                request[request_len] = try reader.interface.takeByte();
                request_len += 1;
                if (std.mem.endsWith(u8, request[0..request_len], "\r\n\r\n")) break;
            } else return error.TestRequestTooLarge;
            const key = headerValue(request[0 .. request_len - 4], "sec-websocket-key") orelse return error.TestMissingWebSocketKey;
            var accept_buffer: [28]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var writer = client_stream.writer(zio, &write_buffer);
            try writer.interface.print(
                "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
                .{websocketAccept(key, &accept_buffer)},
            );
            _ = self.owner.accepted_connections.fetchAdd(1, .seq_cst);
            try writer.interface.flush();
            var payload_buffer: [4096]u8 = undefined;
            while (!self.owner.stopping.load(.seq_cst)) {
                const frame = try read_test_client_frame(&reader.interface, &payload_buffer);
                switch (frame.opcode) {
                    .ping => {
                        _ = self.pings.fetchAdd(1, .seq_cst);
                        try writeServerFrame(&writer.interface, .pong, frame.payload);
                    },
                    .text => {
                        const number = self.requests.fetchAdd(1, .seq_cst) + 1;
                        var event_buffer: [256]u8 = undefined;
                        try writeServerFrame(&writer.interface, .text, try std.fmt.bufPrint(
                            &event_buffer,
                            "{{\"type\":\"response.output_text.delta\",\"delta\":\"output-{d}-{d}\"}}",
                            .{ self.index + 1, number },
                        ));
                        try writeServerFrame(&writer.interface, .text, try std.fmt.bufPrint(
                            &event_buffer,
                            "{{\"type\":\"response.completed\",\"response\":{{\"id\":\"pool-{d}-{d}\",\"status\":\"completed\"}}}}",
                            .{ self.index + 1, number },
                        ));
                    },
                    .close => {
                        try writeServerFrame(&writer.interface, .close, frame.payload);
                        try writer.interface.flush();
                        self.closed.store(true, .seq_cst);
                        return;
                    },
                    else => return error.TestUnexpectedClientFrame,
                }
                try writer.interface.flush();
            }
        }
    };

    fn init(mode: LoopbackMode) !@This() {
        var fixture: @This() = .{ .server = undefined, .mode = mode };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn endpoint(self: *@This(), buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/responses", .{self.server.socket.address.getPort()});
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(self.io(), .both) catch {};
            // Darwin listener shutdown does not release a blocked accept.
            self.wake_accept();
            thread.join();
            self.thread = null;
        }
        for (self.reusable_peers[0..self.reusable_peer_count]) |*peer| {
            peer.socket_mutex.lockUncancelable(self.io());
            if (!peer.finished)
                if (peer.stream) |client_stream| client_stream.shutdown(self.io(), .both) catch {};
            peer.socket_mutex.unlock(self.io());
            if (peer.thread) |thread| thread.join();
        }
        self.server.deinit(self.io());
    }

    fn wake_accept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.server.socket.address.getPort()) };
        var wake_stream = address.connect(zio, .{ .mode = .stream }) catch return;
        wake_stream.close(zio);
    }

    fn hold(self: *@This()) void {
        while (!self.stopping.load(.seq_cst)) {
            self.io().sleep(.fromMilliseconds(1), .real) catch {};
        }
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (!self.stopping.load(.seq_cst)) self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        if (self.mode == .never_accept) return self.hold();
        if (self.mode == .reusable) {
            while (!self.stopping.load(.seq_cst)) {
                const client_stream = try self.server.accept(self.io());
                if (self.stopping.load(.seq_cst)) {
                    client_stream.close(self.io());
                    return;
                }
                if (self.reusable_peer_count == self.reusable_peers.len) {
                    client_stream.close(self.io());
                    return error.TestTooManyConnections;
                }
                const peer = &self.reusable_peers[self.reusable_peer_count];
                peer.owner = self;
                peer.index = self.reusable_peer_count;
                peer.stream = client_stream;
                peer.thread = std.Thread.spawn(.{}, ReusablePeer.run, .{peer}) catch |err| {
                    client_stream.close(self.io());
                    peer.stream = null;
                    return err;
                };
                self.reusable_peer_count += 1;
            }
            return;
        }
        const zio = self.io();
        var client_stream = try self.server.accept(zio);
        defer client_stream.close(zio);
        if (self.stopping.load(.seq_cst)) return;

        var socket_buffer: [4096]u8 = undefined;
        var reader = client_stream.reader(zio, &socket_buffer);
        var request: [16 * 1024]u8 = undefined;
        var request_len: usize = 0;
        while (request_len < request.len) {
            request[request_len] = try reader.interface.takeByte();
            request_len += 1;
            if (std.mem.endsWith(u8, request[0..request_len], "\r\n\r\n")) break;
        } else return error.TestRequestTooLarge;
        self.upgrade_received.store(true, .seq_cst);
        if (self.mode == .withhold_upgrade) {
            // Release the peer even before the fix so a regression cannot hang.
            self.io().sleep(.fromMilliseconds(400), .real) catch {};
            return;
        }
        if (self.mode == .pause_upgrade) {
            while (!self.allow_upgrade.load(.seq_cst)) {
                if (self.stopping.load(.seq_cst)) return;
                self.io().sleep(.fromMilliseconds(1), .real) catch {};
            }
        }
        const key = headerValue(request[0 .. request_len - 4], "sec-websocket-key") orelse return error.TestMissingWebSocketKey;
        var accept_buffer: [28]u8 = undefined;
        const accept = websocketAccept(key, &accept_buffer);
        var write_buffer: [4096]u8 = undefined;
        var writer = client_stream.writer(zio, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: WebSocket\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
        try writer.interface.flush();
        self.upgraded.store(true, .seq_cst);

        if (self.mode == .reset_after_upgrade) {
            const reset_on_close: std.posix.linger = .{ .onoff = 1, .linger = 0 };
            try std.posix.setsockopt(
                client_stream.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.LINGER,
                std.mem.asBytes(&reset_on_close),
            );
            return;
        }
        if (self.mode == .hang_after_upgrade) return self.hold();
        if (self.mode == .health_pong) {
            var payload_buffer: [125]u8 = undefined;
            const payload = try read_test_control(&reader.interface, .ping, &payload_buffer);
            try writeServerFrame(&writer.interface, .pong, "unrelated");
            try writeServerFrame(&writer.interface, .ping, "hi");
            try writeServerFrame(&writer.interface, .pong, payload);
            try writer.interface.flush();
            const pong = try read_test_control(&reader.interface, .pong, &payload_buffer);
            if (!std.mem.eql(u8, pong, "hi")) return error.TestWrongPong;
            self.pong_received.store(true, .seq_cst);
            return self.hold();
        }

        try discardClientFrame(&reader.interface);
        self.generation_received.store(true, .seq_cst);
        switch (self.mode) {
            .reset_after_progress => {
                try writeServerFrame(&writer.interface, .text, "{\"type\":\"response.output_text.delta\",\"delta\":\"reset-partial\"}");
                try writeServerFrame(&writer.interface, .ping, "reset-proof");
                try writer.interface.flush();
                var pong_buffer: [125]u8 = undefined;
                const pong = try read_test_control(&reader.interface, .pong, &pong_buffer);
                if (!std.mem.eql(u8, pong, "reset-proof")) return error.TestWrongPong;
                self.pong_received.store(true, .seq_cst);
                const reset_on_close: std.posix.linger = .{ .onoff = 1, .linger = 0 };
                try std.posix.setsockopt(client_stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&reset_on_close));
            },
            .hold_after_request => {
                try writeServerFrame(&writer.interface, .text, "{\"type\":\"response.output_text.delta\",\"delta\":\"outer-deadline-partial\"}");
                try writer.interface.flush();
                self.hold();
            },
            .keepalive_only => {
                while (!self.stopping.load(.seq_cst)) {
                    try writeServerFrame(&writer.interface, .pong, "keepalive");
                    try writer.interface.flush();
                    self.io().sleep(.fromMilliseconds(10), .real) catch {};
                }
            },
            .complete_then_hang_close => {
                try writeServerFrame(&writer.interface, .text, "{\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}");
                try writeServerFrame(&writer.interface, .text, "{\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}");
                try writer.interface.flush();
                self.hold();
            },
            .binary_then_close => {
                try writeServerFrame(&writer.interface, .binary, &.{0});
                try writer.interface.flush();
            },
            .ping_then_complete, .pause_upgrade => {
                try writeServerFrame(&writer.interface, .ping, "hi");
                try writeServerFrame(&writer.interface, .text, "{\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}");
                try writeServerFrame(&writer.interface, .text, "{\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}");
                try writeServerFrame(&writer.interface, .close, &.{ 0x03, 0xe8 });
                try writer.interface.flush();
                try discardClientFrame(&reader.interface);
            },
            .oversized_frame => {
                try writer.interface.writeAll(&.{ 0x81, 127 });
                try writer.interface.writeInt(u64, max_frame_bytes + 1, .big);
                try writer.interface.flush();
            },
            else => unreachable,
        }
    }
};

fn writeServerFrame(writer: *std.Io.Writer, opcode: Opcode, payload: []const u8) !void {
    try writer.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
    if (payload.len < 126) {
        try writer.writeByte(@intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        try writer.writeByte(126);
        try writer.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try writer.writeByte(127);
        try writer.writeInt(u64, @intCast(payload.len), .big);
    }
    try writer.writeAll(payload);
}

fn discardClientFrame(reader: *std.Io.Reader) !void {
    _ = try reader.takeByte();
    const second = try reader.takeByte();
    if (second & 0x80 == 0) return error.WebSocketProtocolViolation;
    var length: u64 = second & 0x7f;
    if (length == 126) length = try reader.takeInt(u16, .big) else if (length == 127) length = try reader.takeInt(u64, .big);
    var mask: [4]u8 = undefined;
    try reader.readSliceAll(&mask);
    var discarded: [4096]u8 = undefined;
    var remaining = length;
    while (remaining > 0) {
        const chunk_len: usize = @intCast(@min(remaining, discarded.len));
        try reader.readSliceAll(discarded[0..chunk_len]);
        remaining -= chunk_len;
    }
}

fn read_test_client_frame(reader: *std.Io.Reader, buffer: []u8) !struct { opcode: Opcode, payload: []const u8 } {
    const first = try reader.takeByte();
    if (first & 0xf0 != 0x80) return error.TestUnexpectedClientFrame;
    const opcode = std.enums.fromInt(Opcode, first & 0x0f) orelse return error.TestUnexpectedClientFrame;
    const second = try reader.takeByte();
    if (second & 0x80 == 0) return error.TestUnexpectedClientFrame;
    var length: u64 = second & 0x7f;
    if (length == 126) length = try reader.takeInt(u16, .big) else if (length == 127) length = try reader.takeInt(u64, .big);
    if (length > buffer.len) return error.TestRequestTooLarge;
    var mask: [4]u8 = undefined;
    try reader.readSliceAll(&mask);
    const payload = buffer[0..@intCast(length)];
    try reader.readSliceAll(payload);
    for (payload, 0..) |*byte, index| byte.* ^= mask[index % mask.len];
    return .{ .opcode = opcode, .payload = payload };
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

test "WebSocket cancellation interrupts a backpressured response.create write" {
    var fixture = try StalledWriteFixture.init();
    defer fixture.deinit();
    try fixture.start();

    var endpoint_buffer: [128]u8 = undefined;
    const payload = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const Canceller = struct {
        fn run(server: *StalledWriteFixture, flag: *std.atomic.Value(bool)) void {
            while (!server.write_received.load(.seq_cst)) {
                var sleep_io: std.Io.Threaded = .init_single_threaded;
                sleep_io.io().sleep(.fromMilliseconds(1), .real) catch {};
            }
            flag.store(true, .seq_cst);
        }
    };
    const canceller = try std.Thread.spawn(.{}, Canceller.run, .{ &fixture, &cancelled });
    defer canceller.join();
    const result = stream(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = payload,
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, @ptrCast(&cancelled), struct {
        fn ignore(_: *anyopaque, _: []const u8) !bool {
            return false;
        }
    }.ignore);
    try std.testing.expectError(error.Cancelled, result);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.possibly_sent, delivery.load());
    if (fixture.failure) |err| return err;
}

test "WebSocket request deadline bounds a withheld upgrade" {
    var fixture = try LoopbackWebSocketFixture.init(.withhold_upgrade);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = connect(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(100),
        }),
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    });
    if (result) |connection| close(connection, std.testing.allocator) else |_| {}
    try std.testing.expectError(error.Timeout, result);
    try std.testing.expect(started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() < 350);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

test "WebSocket connect timeout bounds a withheld upgrade" {
    var fixture = try LoopbackWebSocketFixture.init(.withhold_upgrade);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = connect_with_timeout(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, 100);
    if (result) |connection| close(connection, std.testing.allocator) else |_| {}
    try std.testing.expectError(error.WebSocketConnectTimeout, result);
    try std.testing.expect(started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() < 350);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

test "WebSocket cancellation interrupts a withheld upgrade" {
    var fixture = try LoopbackWebSocketFixture.init(.withhold_upgrade);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const Canceller = struct {
        fn run(server: *LoopbackWebSocketFixture, flag: *std.atomic.Value(bool)) void {
            while (!server.upgrade_received.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const canceller = try std.Thread.spawn(.{}, Canceller.run, .{ &fixture, &cancelled });
    defer canceller.join();
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = connect(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    });
    if (result) |connection| close(connection, std.testing.allocator) else |_| {}
    try std.testing.expectError(error.Cancelled, result);
    try std.testing.expect(started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() < 350);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

test "WebSocket cancellation interrupts a stalled connect" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const Canceller = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const canceller = try std.Thread.spawn(.{}, Canceller.run, .{&cancelled});
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = stream(std.testing.allocator, .{
        .endpoint = "http://192.0.2.1:9/responses",
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = "{}",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, @ptrCast(&cancelled), struct {
        fn ignore(_: *anyopaque, _: []const u8) !bool {
            return false;
        }
    }.ignore);
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
    canceller.join();
    if (result) |_| {
        return error.TestExpectedError;
    } else |err| {
        if (err == error.Cancelled) {
            try std.testing.expect(elapsed_ms < 2_000);
            try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.definitely_unsent, delivery.load());
            return;
        }
        if (elapsed_ms >= 5) return err;
    }

    var fixture = try LoopbackWebSocketFixture.init(.never_accept);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    cancelled.store(false, .seq_cst);
    delivery = gateway_client.DeliveryCertainty.init();
    const fallback_canceller = try std.Thread.spawn(.{}, Canceller.run, .{&cancelled});
    const fallback_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const fallback_result = stream(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = "{}",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, @ptrCast(&cancelled), struct {
        fn ignore(_: *anyopaque, _: []const u8) !bool {
            return false;
        }
    }.ignore);
    const fallback_elapsed_ms = fallback_started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
    fallback_canceller.join();
    try std.testing.expectError(error.Cancelled, fallback_result);
    try std.testing.expect(fallback_elapsed_ms < 2_000);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.definitely_unsent, delivery.load());
    if (fixture.failure) |err| return err;
}

test "WebSocket accepted completion survives cancellation during close" {
    var fixture = try LoopbackWebSocketFixture.init(.complete_then_hang_close);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const Canceller = struct {
        fn run(server: *LoopbackWebSocketFixture, flag: *std.atomic.Value(bool)) void {
            while (!server.upgraded.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
            io_mod.sleep(50 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const canceller = try std.Thread.spawn(.{}, Canceller.run, .{ &fixture, &cancelled });
    defer canceller.join();
    const result = stream(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = "{}",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, @ptrCast(&cancelled), struct {
        fn completed(_: *anyopaque, json: []const u8) !bool {
            return std.mem.find(u8, json, "\"response.completed\"") != null;
        }
    }.completed);
    try result;
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.possibly_sent, delivery.load());
    if (fixture.failure) |err| return err;
}

test "WebSocket peer reset after upgrade leaves delivery possibly sent" {
    var fixture = try LoopbackWebSocketFixture.init(.reset_after_upgrade);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    const payload = try std.testing.allocator.alloc(u8, 4 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const result = stream(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = payload,
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, @ptrCast(&cancelled), struct {
        fn ignore(_: *anyopaque, _: []const u8) !bool {
            return false;
        }
    }.ignore);
    if (result) |_| return error.TestExpectedError else |err| try std.testing.expect(err != error.Cancelled);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.possibly_sent, delivery.load());
    if (fixture.failure) |err| return err;
}

test "WebSocket rejects unexpected binary frames" {
    var fixture = try LoopbackWebSocketFixture.init(.binary_then_close);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const result = stream(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = "{}",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, @ptrCast(&cancelled), struct {
        fn ignore(_: *anyopaque, _: []const u8) !bool {
            return false;
        }
    }.ignore);
    try std.testing.expectError(error.WebSocketUnexpectedBinary, result);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.possibly_sent, delivery.load());
    if (fixture.failure) |err| return err;
}

test "WebSocket answers ping then completes" {
    var fixture = try LoopbackWebSocketFixture.init(.ping_then_complete);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    var completed = false;
    try stream(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = "{}",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, @ptrCast(&completed), struct {
        fn handle(context: *anyopaque, json: []const u8) !bool {
            const done: *bool = @ptrCast(@alignCast(context));
            if (std.mem.find(u8, json, "\"response.completed\"") != null) {
                done.* = true;
                return true;
            }
            return false;
        }
    }.handle);
    try std.testing.expect(completed);
    if (fixture.failure) |err| return err;
}

test "WebSocket rejects inbound frames over max_frame_bytes" {
    var fixture = try LoopbackWebSocketFixture.init(.oversized_frame);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const result = stream(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = "{}",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, @ptrCast(&cancelled), struct {
        fn ignore(_: *anyopaque, _: []const u8) !bool {
            return false;
        }
    }.ignore);
    try std.testing.expectError(error.WebSocketMessageTooLarge, result);
    if (fixture.failure) |err| return err;
}

test "WebSocket appendMessage rejects a 64 MiB overflow" {
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(std.testing.allocator);
    const payload = try std.testing.allocator.alloc(u8, max_message_bytes);
    defer std.testing.allocator.free(payload);
    try appendMessage(&message, std.testing.allocator, payload);
    try std.testing.expectError(error.WebSocketMessageTooLarge, appendMessage(&message, std.testing.allocator, "x"));
}

test "WebSocket writeFrame rejects payloads over max_message_bytes" {
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    const payload = try std.testing.allocator.alloc(u8, max_message_bytes + 1);
    defer std.testing.allocator.free(payload);
    try std.testing.expectError(error.WebSocketMessageTooLarge, writeFrame(&encoded.writer, .text, payload));
}

fn wait_for_test_flag(flag: *std.atomic.Value(bool)) !void {
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(2_000),
    });
    while (!flag.load(.seq_cst)) {
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, deadline))
            return error.TestBarrierTimedOut;
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn test_complete_event(raw: *anyopaque, json: []const u8) !bool {
    const output: *bool = @ptrCast(@alignCast(raw));
    if (std.mem.find(u8, json, "\"delta\":\"ok\"") != null) output.* = true;
    return std.mem.find(u8, json, "\"response.completed\"") != null;
}

fn exercise_pool_checkout(checkout: @import("codex_websocket_session.zig").Checkout, args: @import("codex_websocket_session.zig").AcquireArgs, output: *bool) !void {
    try streamOn(checkout.connection, std.testing.allocator, .{
        .endpoint = args.endpoint,
        .authorization = args.authorization,
        .account_id = args.account_id,
        .session_id = args.session_id,
        .payload = "{}",
        .deadline = args.deadline,
        .cancel_flag = args.cancel_flag,
        .delivery = args.delivery,
    }, output, test_complete_event);
}

const pool_test_shape = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length;

fn pool_test_args(endpoint: []const u8, session_id: []const u8, cancelled: *std.atomic.Value(bool), delivery: *gateway_client.DeliveryCertainty) @import("codex_websocket_session.zig").AcquireArgs {
    return .{
        .session_id = session_id,
        .account_id = "pool-account",
        .model = "pool-model",
        .endpoint = endpoint,
        .authorization = "Bearer pool-token",
        .deadline = null,
        .cancel_flag = cancelled,
        .delivery = delivery,
    };
}

fn complete_reusable_pool_checkout(checkout: @import("codex_websocket_session.zig").Checkout, args: @import("codex_websocket_session.zig").AcquireArgs, peer: usize, request: usize, baseline: []const u8) !void {
    const Completion = struct {
        expected_output: []const u8,
        expected_id: []const u8,
        output_received: bool = false,
        completed: bool = false,

        fn event(raw: *anyopaque, json: []const u8) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
            defer parsed.deinit();
            const event_type = parsed.value.object.get("type").?.string;
            if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
                try std.testing.expectEqualStrings(self.expected_output, parsed.value.object.get("delta").?.string);
                self.output_received = true;
            } else if (std.mem.eql(u8, event_type, "response.completed")) {
                const response = parsed.value.object.get("response").?.object;
                try std.testing.expectEqualStrings(self.expected_id, response.get("id").?.string);
                try std.testing.expectEqualStrings("completed", response.get("status").?.string);
                self.completed = true;
                return true;
            }
            return false;
        }
    };
    var output_buffer: [64]u8 = undefined;
    var id_buffer: [64]u8 = undefined;
    var completion = Completion{
        .expected_output = try std.fmt.bufPrint(&output_buffer, "output-{d}-{d}", .{ peer, request }),
        .expected_id = try std.fmt.bufPrint(&id_buffer, "pool-{d}-{d}", .{ peer, request }),
    };
    try streamOn(checkout.connection, std.testing.allocator, .{
        .endpoint = args.endpoint,
        .authorization = args.authorization,
        .account_id = args.account_id,
        .session_id = args.session_id,
        .payload = "{\"type\":\"response.create\",\"response\":{\"input\":[]}}",
        .deadline = args.deadline,
        .cancel_flag = args.cancel_flag,
        .delivery = args.delivery,
    }, &completion, Completion.event);
    try std.testing.expect(completion.output_received);
    try std.testing.expect(completion.completed);
    @import("codex_websocket_session.zig").recordCompletion(checkout, completion.expected_id, baseline, baseline, pool_test_shape);
}

test "WebSocket pool global saturation completes a temporary stream without disturbing busy histories" {
    const session = @import("codex_websocket_session.zig");
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const previous_environment = io_mod.environMap();
    defer io_mod.setEnvironMap(previous_environment orelse &stable_websocket_test_environ);
    try environment.put("FX_CODEX_WEBSOCKET_MAX_SLOTS", "2");
    try environment.put("FX_CODEX_WEBSOCKET_MAX_LANES", "4");
    io_mod.setEnvironMap(&environment);
    var fixture = try LoopbackWebSocketFixture.init(.reusable);
    defer fixture.deinit();
    session.shutdown();
    defer session.shutdown();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try fixture.endpoint(&endpoint_buffer);
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const args_a = pool_test_args(endpoint, "saturated-a", &cancelled, &delivery);
    const args_b = pool_test_args(endpoint, "saturated-b", &cancelled, &delivery);
    var a: ?session.Checkout = try session.acquire(std.testing.allocator, args_a);
    defer if (a) |owned| session.release(owned, .failed);
    var b: ?session.Checkout = try session.acquire(std.testing.allocator, args_b);
    defer if (b) |owned| session.release(owned, .failed);
    try complete_reusable_pool_checkout(a.?, args_a, 1, 1, "alpha");
    try complete_reusable_pool_checkout(b.?, args_b, 2, 1, "beta");
    const borrowed_a = session.continuation(a.?, "alpha,next-a", pool_test_shape).?;
    const borrowed_b = session.continuation(b.?, "beta,next-b", pool_test_shape).?;

    const temporary_args = pool_test_args(endpoint, "saturated-temporary", &cancelled, &delivery);
    var temporary: ?session.Checkout = try session.acquire(std.testing.allocator, temporary_args);
    defer if (temporary) |owned| session.release(owned, .failed);
    try std.testing.expect(!temporary.?.retained);
    try std.testing.expect(temporary.?.slot == null);
    try complete_reusable_pool_checkout(temporary.?, temporary_args, 3, 1, "temporary");
    try std.testing.expect(session.continuation(temporary.?, "temporary,next", pool_test_shape) == null);
    session.release(temporary.?, .completed);
    temporary = null;
    try wait_for_test_flag(&fixture.reusable_peers[2].closed);
    try std.testing.expect(a.?.slot.?.connection.? == a.?.connection);
    try std.testing.expect(b.?.slot.?.connection.? == b.?.connection);
    try std.testing.expect(a.?.slot.?.busy and b.?.slot.?.busy);
    try std.testing.expectEqualStrings("pool-1-1", borrowed_a.previous_response_id);
    try std.testing.expectEqualStrings("next-a", borrowed_a.delta_input);
    try std.testing.expectEqualStrings("pool-2-1", borrowed_b.previous_response_id);
    try std.testing.expectEqualStrings("next-b", borrowed_b.delta_input);

    session.shutdown();
    try std.testing.expect(a.?.slot.?.retired and b.?.slot.?.retired);
    var fresh: ?session.Checkout = try session.acquire(std.testing.allocator, args_a);
    defer if (fresh) |owned| session.release(owned, .failed);
    try complete_reusable_pool_checkout(fresh.?, args_a, 4, 1, "fresh");
    session.release(a.?, .completed);
    a = null;
    try std.testing.expectEqualStrings("pool-2-1", borrowed_b.previous_response_id);
    try std.testing.expectEqualStrings("pool-4-1", session.continuation(fresh.?, "fresh,next", pool_test_shape).?.previous_response_id);
    session.release(fresh.?, .completed);
    fresh = null;
    session.release(b.?, .completed);
    b = null;
    const reused = try session.acquire(std.testing.allocator, args_a);
    defer session.release(reused, .failed);
    try std.testing.expect(reused.reused);
    try std.testing.expectEqualStrings("pool-4-1", session.continuation(reused, "fresh,next", pool_test_shape).?.previous_response_id);
    try complete_reusable_pool_checkout(reused, args_a, 4, 2, "fresh,next");
    try std.testing.expectEqual(@as(usize, 4), fixture.accepted_connections.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reusable_peers[3].pings.load(.seq_cst));
}

test "WebSocket pool idle LRU eviction and identity churn preserve busy socket ownership" {
    const session = @import("codex_websocket_session.zig");
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const previous_environment = io_mod.environMap();
    defer io_mod.setEnvironMap(previous_environment orelse &stable_websocket_test_environ);
    try environment.put("FX_CODEX_WEBSOCKET_MAX_SLOTS", "3");
    io_mod.setEnvironMap(&environment);
    var fixture = try LoopbackWebSocketFixture.init(.reusable);
    defer fixture.deinit();
    session.shutdown();
    defer session.shutdown();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try fixture.endpoint(&endpoint_buffer);
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const args_a = pool_test_args(endpoint, "lru-busy", &cancelled, &delivery);
    const args_b = pool_test_args(endpoint, "lru-oldest-idle", &cancelled, &delivery);
    const args_c = pool_test_args(endpoint, "lru-recent-idle", &cancelled, &delivery);
    const a = try session.acquire(std.testing.allocator, args_a);
    defer session.release(a, .failed);
    try complete_reusable_pool_checkout(a, args_a, 1, 1, "busy");
    const borrowed_a = session.continuation(a, "busy,next", pool_test_shape).?;
    var b: ?session.Checkout = try session.acquire(std.testing.allocator, args_b);
    defer if (b) |owned| session.release(owned, .failed);
    try complete_reusable_pool_checkout(b.?, args_b, 2, 1, "oldest");
    var c: ?session.Checkout = try session.acquire(std.testing.allocator, args_c);
    defer if (c) |owned| session.release(owned, .failed);
    try complete_reusable_pool_checkout(c.?, args_c, 3, 1, "recent");
    const recent_connection = c.?.connection;
    // Supplied release timestamps establish LRU order without scheduler sleeps.
    const now = io_mod.milliTimestamp();
    const idle_b = b.?.slot.?;
    session.release(b.?, .completed);
    b = null;
    idle_b.last_used_at_ms = now - 30;
    const idle_c = c.?.slot.?;
    session.release(c.?, .completed);
    c = null;
    idle_c.last_used_at_ms = now - 20;
    a.slot.?.last_used_at_ms = now - 40;

    var churn_args = pool_test_args(endpoint, "lru-new-identity", &cancelled, &delivery);
    var churn: ?session.Checkout = try session.acquire(std.testing.allocator, churn_args);
    defer if (churn) |owned| session.release(owned, .failed);
    try wait_for_test_flag(&fixture.reusable_peers[1].closed);
    try std.testing.expect(!fixture.reusable_peers[0].closed.load(.seq_cst));
    try std.testing.expect(!fixture.reusable_peers[2].closed.load(.seq_cst));
    try std.testing.expect(session.continuation(churn.?, "oldest,next", pool_test_shape) == null);
    try complete_reusable_pool_checkout(churn.?, churn_args, 4, 1, "identity");
    c = try session.acquire(std.testing.allocator, args_c);
    try std.testing.expect(c.?.reused);
    try std.testing.expect(c.?.connection == recent_connection);
    const borrowed_c = session.continuation(c.?, "recent,next", pool_test_shape).?;
    try std.testing.expectEqualStrings("pool-3-1", borrowed_c.previous_response_id);
    try complete_reusable_pool_checkout(c.?, args_c, 3, 2, "recent,next");

    const identities = [_]struct { authorization: []const u8, model: []const u8, account: []const u8, session_id: []const u8 }{
        .{ .authorization = "Bearer rotated-token", .model = "pool-model", .account = "pool-account", .session_id = "lru-new-identity" },
        .{ .authorization = "Bearer rotated-token", .model = "rotated-model", .account = "pool-account", .session_id = "lru-new-identity" },
        .{ .authorization = "Bearer rotated-token", .model = "rotated-model", .account = "rotated-account", .session_id = "lru-new-identity" },
        .{ .authorization = "Bearer rotated-token", .model = "rotated-model", .account = "rotated-account", .session_id = "rotated-session" },
    };
    for (identities, 0..) |identity, index| {
        session.release(churn.?, .completed);
        churn = null;
        churn_args.authorization = identity.authorization;
        churn_args.model = identity.model;
        churn_args.account_id = identity.account;
        churn_args.session_id = identity.session_id;
        churn = try session.acquire(std.testing.allocator, churn_args);
        try std.testing.expect(!churn.?.reused);
        try std.testing.expect(session.continuation(churn.?, "identity,next", pool_test_shape) == null);
        try complete_reusable_pool_checkout(churn.?, churn_args, 5 + index, 1, "identity");
        try std.testing.expectEqualStrings("pool-1-1", borrowed_a.previous_response_id);
        try std.testing.expectEqualStrings("pool-3-2", session.continuation(c.?, "recent,next,again", pool_test_shape).?.previous_response_id);
        try std.testing.expect(a.slot.?.busy and c.?.slot.?.busy);
    }
    try std.testing.expectEqual(@as(usize, 8), fixture.accepted_connections.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reusable_peers[2].pings.load(.seq_cst));
    try complete_reusable_pool_checkout(a, args_a, 1, 2, "busy,next");
}

test "WebSocket pool forced rejection recovery opens a fresh socket despite an alternative idle lane" {
    const session = @import("codex_websocket_session.zig");
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const previous_environment = io_mod.environMap();
    defer io_mod.setEnvironMap(previous_environment orelse &stable_websocket_test_environ);
    try environment.put("FX_CODEX_WEBSOCKET_MAX_SLOTS", "2");
    try environment.put("FX_CODEX_WEBSOCKET_MAX_LANES", "2");
    io_mod.setEnvironMap(&environment);
    var fixture = try LoopbackWebSocketFixture.init(.reusable);
    defer fixture.deinit();
    session.shutdown();
    defer session.shutdown();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try fixture.endpoint(&endpoint_buffer);
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    var args = pool_test_args(endpoint, "forced-recovery", &cancelled, &delivery);
    var rejected: ?session.Checkout = try session.acquire(std.testing.allocator, args);
    defer if (rejected) |owned| session.release(owned, .failed);
    var alternative: ?session.Checkout = try session.acquire(std.testing.allocator, args);
    defer if (alternative) |owned| session.release(owned, .failed);
    try complete_reusable_pool_checkout(rejected.?, args, 1, 1, "rejected");
    try complete_reusable_pool_checkout(alternative.?, args, 2, 1, "alternative");
    session.release(alternative.?, .completed);
    alternative = null;
    session.release(rejected.?, .failed);
    rejected = null;
    args.force_fresh_connection = true;
    args.continuation_input = "alternative,next";
    args.continuation_shape = pool_test_shape;
    var recovery: ?session.Checkout = try session.acquire(std.testing.allocator, args);
    defer if (recovery) |owned| session.release(owned, .failed);
    try std.testing.expect(!recovery.?.reused);
    try std.testing.expect(session.continuation(recovery.?, "alternative,next", pool_test_shape) == null);
    try wait_for_test_flag(&fixture.reusable_peers[1].closed);
    try std.testing.expectEqual(@as(usize, 0), fixture.reusable_peers[1].pings.load(.seq_cst));
    try complete_reusable_pool_checkout(recovery.?, args, 3, 1, "recovered");
    session.release(recovery.?, .completed);
    recovery = null;
    args.force_fresh_connection = false;
    args.continuation_input = "recovered,next";
    const next = try session.acquire(std.testing.allocator, args);
    defer session.release(next, .failed);
    try std.testing.expect(next.reused);
    try std.testing.expectEqualStrings("pool-3-1", session.continuation(next, "recovered,next", pool_test_shape).?.previous_response_id);
    try complete_reusable_pool_checkout(next, args, 3, 2, "recovered,next");
    try std.testing.expectEqual(@as(usize, 3), fixture.accepted_connections.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reusable_peers[2].pings.load(.seq_cst));
}

test "WebSocket pool retires a paused connect without touching the new pool" {
    const session = @import("codex_websocket_session.zig");
    session.shutdown();
    defer session.shutdown();
    var fixture = try LoopbackWebSocketFixture.init(.pause_upgrade);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const args = session.AcquireArgs{
        .session_id = "paused-connect",
        .account_id = "test",
        .model = "test",
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    };
    const Worker = struct {
        args: session.AcquireArgs,
        checkout: ?session.Checkout = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.checkout = session.acquire(std.testing.allocator, self.args) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var worker = Worker{ .args = args };
    var thread: ?std.Thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer if (thread) |owned| {
        cancelled.store(true, .seq_cst);
        fixture.allow_upgrade.store(true, .seq_cst);
        owned.join();
        if (worker.checkout) |checkout| session.release(checkout, .failed);
    };
    try wait_for_test_flag(&fixture.upgrade_received);
    session.shutdown();

    var fresh_fixture = try LoopbackWebSocketFixture.init(.ping_then_complete);
    defer fresh_fixture.deinit();
    try fresh_fixture.start();
    var fresh_endpoint: [128]u8 = undefined;
    var fresh_args = args;
    fresh_args.endpoint = try fresh_fixture.endpoint(&fresh_endpoint);
    const fresh = try session.acquire(std.testing.allocator, fresh_args);
    defer session.release(fresh, .failed);
    fixture.allow_upgrade.store(true, .seq_cst);
    thread.?.join();
    thread = null;
    if (worker.failure) |err| return err;
    const old = worker.checkout.?;
    defer session.release(old, .failed);
    try std.testing.expect(!old.retained);
    try std.testing.expect(old.slot.?.retired);
    try std.testing.expect(old.slot.?.lane_id != fresh.slot.?.lane_id);
    var old_output = false;
    try exercise_pool_checkout(old, args, &old_output);
    var fresh_output = false;
    try exercise_pool_checkout(fresh, fresh_args, &fresh_output);
    try std.testing.expect(old_output);
    try std.testing.expect(fresh_output);
    try std.testing.expect(fresh.slot.?.busy);
}

test "WebSocket pool preserves a live stream and borrowed history through shutdown" {
    const session = @import("codex_websocket_session.zig");
    session.shutdown();
    defer session.shutdown();
    var fixture = try LoopbackWebSocketFixture.init(.hang_after_upgrade);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const args = session.AcquireArgs{
        .session_id = "live-stream",
        .account_id = "test",
        .model = "test",
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    };
    const old = try session.acquire(std.testing.allocator, args);
    const shape = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length;
    session.recordCompletion(old, "old-response", "first", "first", shape);
    const borrowed = session.continuation(old, "first,second", shape).?;
    const Worker = struct {
        checkout: session.Checkout,
        args: session.AcquireArgs,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            var output = false;
            exercise_pool_checkout(self.checkout, self.args, &output) catch |err| {
                self.failure = err;
            };
            session.release(self.checkout, .failed);
        }
    };
    var worker = Worker{ .checkout = old, .args = args };
    var thread: ?std.Thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer if (thread) |owned| {
        cancelled.store(true, .seq_cst);
        owned.join();
    };
    const barrier_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(2_000),
    });
    while (delivery.load() == .definitely_unsent) {
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, barrier_deadline))
            return error.TestBarrierTimedOut;
        io_mod.sleep(std.time.ns_per_ms);
    }
    session.shutdown();
    session.shutdown();
    var fresh_fixture = try LoopbackWebSocketFixture.init(.ping_then_complete);
    defer fresh_fixture.deinit();
    try fresh_fixture.start();
    var fresh_endpoint: [128]u8 = undefined;
    var fresh_cancelled = std.atomic.Value(bool).init(false);
    var fresh_delivery = gateway_client.DeliveryCertainty.init();
    var fresh_args = args;
    fresh_args.endpoint = try fresh_fixture.endpoint(&fresh_endpoint);
    fresh_args.cancel_flag = &fresh_cancelled;
    fresh_args.delivery = &fresh_delivery;
    const fresh = try session.acquire(std.testing.allocator, fresh_args);
    defer session.release(fresh, .failed);
    session.recordCompletion(fresh, "fresh-response", "new", "new", shape);
    try std.testing.expectEqualStrings("old-response", borrowed.previous_response_id);
    try std.testing.expectEqualStrings("second", borrowed.delta_input);
    cancelled.store(true, .seq_cst);
    thread.?.join();
    thread = null;
    try std.testing.expectEqual(error.Cancelled, worker.failure.?);
    try std.testing.expect(fresh.slot.?.busy);
    try std.testing.expectEqualStrings("fresh-response", session.continuation(fresh, "new,next", shape).?.previous_response_id);
    var output = false;
    try exercise_pool_checkout(fresh, fresh_args, &output);
    try std.testing.expect(output);
}

fn read_test_control(reader: *std.Io.Reader, opcode: Opcode, buffer: *[125]u8) ![]const u8 {
    if (try reader.takeByte() != (0x80 | @as(u8, @intFromEnum(opcode)))) return error.TestUnexpectedControl;
    const length_byte = try reader.takeByte();
    if (length_byte & 0x80 == 0 or length_byte & 0x7f > 125) return error.TestUnexpectedControl;
    const length: usize = length_byte & 0x7f;
    var mask: [4]u8 = undefined;
    try reader.readSliceAll(&mask);
    const payload = buffer[0..length];
    try reader.readSliceAll(payload);
    for (payload, 0..) |*byte, index| byte.* ^= mask[index % mask.len];
    return payload;
}

test "WebSocket health requires matching pong and answers incoming ping" {
    var fixture = try LoopbackWebSocketFixture.init(.health_pong);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const connection = try connect(std.testing.allocator, .{
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    });
    defer abort(connection, std.testing.allocator);
    try ping(connection, &cancelled, null, &delivery);
    try wait_for_test_flag(&fixture.pong_received);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.definitely_unsent, delivery.load());
}

test "WebSocket control keepalives do not extend model event idle deadline" {
    var fixture = try LoopbackWebSocketFixture.init(.keepalive_only);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const endpoint = try fixture.endpoint(&endpoint_buffer);
    const connection = try connect(std.testing.allocator, .{
        .endpoint = endpoint,
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    });
    defer abort(connection, std.testing.allocator);
    var output = false;
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const result = stream_on_with_idle_timeout(connection, std.testing.allocator, .{
        .endpoint = endpoint,
        .authorization = "Bearer test",
        .account_id = "test",
        .session_id = null,
        .payload = "{}",
        .deadline = bounded_deadline(null, 1_000),
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    }, &output, test_complete_event, 100);
    try std.testing.expectError(error.Timeout, result);
    try std.testing.expect(started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() < 500);
    try std.testing.expect(!output);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.possibly_sent, delivery.load());
}

test "WebSocket malformed frame headers fail before payload dispatch" {
    const frames = [_][]const u8{
        &.{ 0x81, 0x80 },
        &.{ 0xc1, 0 },
        &.{ 0x83, 0 },
        &.{ 0x09, 0 },
        &.{ 0x89, 126, 0, 126 },
        &.{ 0x81, 127, 0x80, 0, 0, 0, 0, 0, 0, 0 },
    };
    for (frames) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        try std.testing.expectError(error.WebSocketProtocolViolation, readFrame(std.testing.allocator, &reader));
    }
    for ([_]u16{ 3000, 4999 }) |code| {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        try std.testing.expectEqual(@as(?u16, code), try validateClosePayload(&payload));
    }
}

var stable_websocket_test_environ = std.process.Environ.Map.init(std.heap.page_allocator);

test "WebSocket outer provider deadline preserves ambiguous delivery without retry evidence" {
    const provider = @import("openai_codex.zig");
    const stream_provider = @import("../core/agent/stream_provider.zig");
    const Consumer = struct {
        fn emit(raw: *anyopaque, event: stream_provider.Event) void {
            const partial: *bool = @ptrCast(@alignCast(raw));
            if (event == .content_delta) partial.* = std.mem.eql(u8, event.content_delta, "outer-deadline-partial");
        }

        fn admit(raw: *anyopaque) !void {
            const evidence: *stream_provider.AttemptEvidence = @ptrCast(@alignCast(raw));
            evidence.provider_admitted = true;
        }
    };
    const session = @import("codex_websocket_session.zig");
    session.shutdown();
    defer session.shutdown();
    var fixture = try LoopbackWebSocketFixture.init(.hold_after_request);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    const test_endpoint = try fixture.endpoint(&endpoint_buffer);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const previous_environment = io_mod.environMap();
    defer io_mod.setEnvironMap(previous_environment orelse &stable_websocket_test_environ);
    try environment.put("FX_CODEX_TRANSPORT", "websocket");
    try environment.put("FX_E2E_OPENAI_CODEX_RESPONSES_URL", test_endpoint);
    io_mod.setEnvironMap(&environment);

    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var partial = false;
    // Fake timers cannot expire the outer deadline while native socket I/O is blocked.
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(500),
    });
    const result = provider.agent_stream_provider.stream(std.testing.allocator, .{
        .credential = .{ .direct = .{
            .secret_bytes = "websocket-deadline-test",
            .source = .chatgpt_subscription,
            .account_id = "websocket-account",
        } },
        .session_id = "outer-deadline",
        .model = "gpt-5.4",
        .retry_count = 1,
        .messages = &.{.{ .role = .user, .content = "Hold this generation." }},
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &partial, .emit_fn = Consumer.emit },
        .admission = .{ .context = &evidence, .admit_fn = Consumer.admit },
        .cancel_flag = &cancelled,
    });
    if (result) |completion| {
        var owned = completion;
        owned.deinit(std.testing.allocator);
        return error.ExpectedTimeout;
    } else |err| try std.testing.expectEqual(error.Timeout, err);
    try std.testing.expect(fixture.generation_received.load(.seq_cst));
    try std.testing.expect(partial);
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.possibly_sent, delivery.load());
    try std.testing.expect(evidence.network_failure == null);
}

test "WebSocket provider write failure preserves ambiguous delivery and permits a fresh request" {
    const provider = @import("openai_codex.zig");
    const session = @import("codex_websocket_session.zig");
    const stream_provider = @import("../core/agent/stream_provider.zig");
    const Consumer = struct {
        fn emit(_: *anyopaque, _: stream_provider.Event) void {}

        fn admit(raw: *anyopaque) !void {
            const evidence: *stream_provider.AttemptEvidence = @ptrCast(@alignCast(raw));
            evidence.provider_admitted = true;
        }
    };
    session.shutdown();
    defer session.shutdown();
    var fixture = try StalledWriteFixture.init();
    fixture.reset_after_write = true;
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const previous_environment = io_mod.environMap();
    defer io_mod.setEnvironMap(previous_environment orelse &stable_websocket_test_environ);
    try environment.put("FX_CODEX_TRANSPORT", "websocket");
    try environment.put("FX_E2E_OPENAI_CODEX_RESPONSES_URL", try fixture.endpoint(&endpoint_buffer));
    io_mod.setEnvironMap(&environment);
    // Exceed kernel buffering so the reset follows delivery but interrupts writing.
    const content = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(content);
    @memset(content, 'x');
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var sink_context: u8 = 0;
    var request: stream_provider.ModelRequest = .{
        .credential = .{ .direct = .{
            .secret_bytes = "websocket-write-test",
            .source = .chatgpt_subscription,
            .account_id = "websocket-account",
        } },
        .session_id = "write-failure",
        .model = "gpt-5.4",
        .retry_count = 1,
        .messages = &.{.{ .role = .user, .content = content }},
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        // A native safety deadline bounds a broken regression's socket I/O.
        .deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(5_000),
        }),
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &sink_context, .emit_fn = Consumer.emit },
        .admission = .{ .context = &evidence, .admit_fn = Consumer.admit },
        .cancel_flag = &cancelled,
    };
    const failed = provider.agent_stream_provider.stream(std.testing.allocator, request);
    if (failed) |completion| {
        var owned = completion;
        owned.deinit(std.testing.allocator);
        return error.ExpectedWriteFailure;
    } else |err| try std.testing.expectEqual(error.WriteFailed, err);
    try std.testing.expect(fixture.write_received.load(.seq_cst));
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.possibly_sent, delivery.load());
    try std.testing.expect(evidence.network_failure == null);

    var fresh = try LoopbackWebSocketFixture.init(.ping_then_complete);
    defer fresh.deinit();
    try fresh.start();
    var fresh_endpoint: [128]u8 = undefined;
    try environment.put("FX_E2E_OPENAI_CODEX_RESPONSES_URL", try fresh.endpoint(&fresh_endpoint));
    request.messages = &.{.{ .role = .user, .content = "Complete a new independent generation." }};
    delivery = .init();
    evidence = .{};
    var result = try provider.agent_stream_provider.stream(std.testing.allocator, request);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqualStrings("ok", result.completed.completion.content orelse return error.ExpectedContent);
    try std.testing.expect(evidence.network_failure == null);
}

test "WebSocket provider read reset preserves partial output without retry evidence" {
    const provider = @import("openai_codex.zig");
    const session = @import("codex_websocket_session.zig");
    const stream_provider = @import("../core/agent/stream_provider.zig");
    const Consumer = struct {
        fn emit(raw: *anyopaque, event: stream_provider.Event) void {
            const partial: *bool = @ptrCast(@alignCast(raw));
            if (event == .content_delta) partial.* = std.mem.eql(u8, event.content_delta, "reset-partial");
        }

        fn admit(raw: *anyopaque) !void {
            const evidence: *stream_provider.AttemptEvidence = @ptrCast(@alignCast(raw));
            evidence.provider_admitted = true;
        }
    };
    session.shutdown();
    defer session.shutdown();
    var fixture = try LoopbackWebSocketFixture.init(.reset_after_progress);
    defer fixture.deinit();
    try fixture.start();
    var endpoint_buffer: [128]u8 = undefined;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const previous_environment = io_mod.environMap();
    defer io_mod.setEnvironMap(previous_environment orelse &stable_websocket_test_environ);
    try environment.put("FX_CODEX_TRANSPORT", "websocket");
    try environment.put("FX_E2E_OPENAI_CODEX_RESPONSES_URL", try fixture.endpoint(&endpoint_buffer));
    io_mod.setEnvironMap(&environment);
    var partial = false;
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var request: stream_provider.ModelRequest = .{
        .credential = .{ .direct = .{
            .secret_bytes = "websocket-read-test",
            .source = .chatgpt_subscription,
            .account_id = "websocket-account",
        } },
        .session_id = "read-reset",
        .model = "gpt-5.4",
        .retry_count = 1,
        .messages = &.{.{ .role = .user, .content = "Keep partial output from this generation." }},
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        // A native safety deadline bounds a broken regression's socket I/O.
        .deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(5_000),
        }),
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &partial, .emit_fn = Consumer.emit },
        .admission = .{ .context = &evidence, .admit_fn = Consumer.admit },
        .cancel_flag = &cancelled,
    };
    const failed = provider.agent_stream_provider.stream(std.testing.allocator, request);
    if (failed) |completion| {
        var owned = completion;
        owned.deinit(std.testing.allocator);
        return error.ExpectedReadFailure;
    } else |err| try std.testing.expectEqual(error.ReadFailed, err);
    try std.testing.expect(partial);
    try std.testing.expect(fixture.generation_received.load(.seq_cst));
    try std.testing.expect(fixture.pong_received.load(.seq_cst));
    try std.testing.expectEqual(gateway_client.DeliveryCertainty.State.possibly_sent, delivery.load());
    try std.testing.expect(evidence.network_failure == null);

    var fresh = try LoopbackWebSocketFixture.init(.ping_then_complete);
    defer fresh.deinit();
    try fresh.start();
    var fresh_endpoint: [128]u8 = undefined;
    try environment.put("FX_E2E_OPENAI_CODEX_RESPONSES_URL", try fresh.endpoint(&fresh_endpoint));
    request.messages = &.{.{ .role = .user, .content = "Complete a new independent generation." }};
    delivery = .init();
    evidence = .{};
    var result = try provider.agent_stream_provider.stream(std.testing.allocator, request);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqualStrings("ok", result.completed.completion.content orelse return error.ExpectedContent);
    try std.testing.expect(evidence.network_failure == null);
}
