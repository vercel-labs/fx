const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const legacy_sse = @import("legacy_sse.zig");
const mcp_auth = @import("mcp_auth.zig");
const mcp_contract = @import("mcp_contract.zig");
const operation_control = @import("operation_control.zig");
const streamable_http = @import("streamable_http.zig");

const Allocator = std.mem.Allocator;
const max_sse_events: usize = 1024;
const close_timeout_ms: i64 = 250;

pub const Version = enum {
    v2025_11_25,
    v2025_06_18,
    v2025_03_26,

    pub fn string(self: Version) []const u8 {
        return switch (self) {
            .v2025_11_25 => "2025-11-25",
            .v2025_06_18 => "2025-06-18",
            .v2025_03_26 => "2025-03-26",
        };
    }

    pub fn sendsProtocolHeader(self: Version) bool {
        return self != .v2025_03_26;
    }

    pub fn allowsPollingClose(self: Version) bool {
        return self == .v2025_11_25;
    }
};

pub const supported_versions = [_]Version{
    .v2025_11_25,
    .v2025_06_18,
    .v2025_03_26,
};
pub const preferred_version = supported_versions[0];

fn parseVersion(value: []const u8) ?Version {
    inline for (supported_versions) |version| {
        if (std.mem.eql(u8, value, version.string())) return version;
    }
    return null;
}

pub const Control = struct {
    deadline: std.Io.Clock.Timestamp,
    deadline_gate: ?*operation_control.DeadlineGate = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,

    pub fn cancellation(self: Control) operation_control.CancellationSources {
        return .{
            .caller = self.cancel_flag,
            .runtime = self.lifecycle_cancel_flag,
        };
    }
};

pub const ServerRequestSink = mcp_contract.ServerRequestSink;
pub const ResponseObserver = mcp_contract.ResponseObserver;

pub const Initialized = struct {
    client: *Client,
    response_body: []u8,

    pub fn deinitResponse(self: *Initialized, alloc: Allocator) void {
        alloc.free(self.response_body);
        self.response_body = undefined;
    }
};

pub const InitializeOptions = struct {
    url: []const u8,
    static_headers: []const mcp_contract.McpHttpHeader,
    request_body: []const u8,
    request_id: u64,
    max_response_bytes: usize,
    max_event_bytes: usize,
    control: Control,
    auth_challenge: ?*?[]u8 = null,
};

pub const RequestOptions = struct {
    request_id: u64,
    request_body: []const u8,
    max_response_bytes: usize,
    max_event_bytes: usize,
    progress: ?mcp_contract.ProgressSink = null,
    response_observer: ?ResponseObserver = null,
    server_requests: ?ServerRequestSink = null,
    notifications: ?mcp_contract.NotificationSink = null,
    control: Control,
    committed: ?*std.atomic.Value(bool) = null,
    precommit: ?*mcp_contract.TransportPrecommit = null,
};

pub const Client = struct {
    owner_allocator: Allocator,
    url: []const u8,
    static_headers: []const mcp_contract.McpHttpHeader,
    version: Version,
    session_id: ?[]u8,
    stopping: std.atomic.Value(bool) = .init(false),
    lifecycle_mutex: std.Io.Mutex = .init,
    lifecycle_cond: std.Io.Condition = .init,
    active_users: usize = 0,
    retiring: bool = false,
    session_retired: std.atomic.Value(bool) = .init(false),
    auth_mutex: std.Io.Mutex = .init,
    auth_challenge: ?[]u8 = null,

    pub fn deinit(self: *Client) void {
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        self.retiring = true;
        self.stopping.store(true, .release);
        while (self.active_users != 0) {
            self.lifecycle_cond.waitUncancelable(io_mod.getIo(), &self.lifecycle_mutex);
        }
        self.lifecycle_mutex.unlock(io_mod.getIo());
        self.terminateSession();
        if (self.session_id) |value| self.owner_allocator.free(value);
        if (self.auth_challenge) |value| self.owner_allocator.free(value);
        const alloc = self.owner_allocator;
        alloc.destroy(self);
    }

    pub fn acquireUse(self: *Client) bool {
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        defer self.lifecycle_mutex.unlock(io_mod.getIo());
        if (self.retiring or self.stopping.load(.acquire)) return false;
        self.active_users += 1;
        return true;
    }

    pub fn releaseUse(self: *Client) void {
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        std.debug.assert(self.active_users > 0);
        self.active_users -= 1;
        if (self.active_users == 0) self.lifecycle_cond.broadcast(io_mod.getIo());
        self.lifecycle_mutex.unlock(io_mod.getIo());
    }

    /// Stops new work and records that the server rejected this session id.
    /// The id stays owned by the client because requests already in flight are
    /// still sending it as a header, so only `deinit` may free it: it drains
    /// `active_users` and runs after the subscription listener is joined.
    pub fn retireExpiredSession(self: *Client) void {
        self.session_retired.store(true, .release);
        self.stopping.store(true, .release);
    }

    pub fn request(self: *Client, alloc: Allocator, options: RequestOptions) ![]u8 {
        if (self.stopping.load(.acquire)) return error.McpConnectionClosed;
        var response = try runBounded(alloc, .{
            .method = .POST,
            .url = self.url,
            .static_headers = self.static_headers,
            .version = self.version,
            .session_id = self.session_id,
            .request_body = options.request_body,
            .request_id = options.request_id,
            .max_response_bytes = options.max_response_bytes,
            .max_event_bytes = options.max_event_bytes,
            .progress = options.progress,
            .response_observer = options.response_observer,
            .server_requests = options.server_requests,
            .notifications = options.notifications,
            .control = options.control,
            .committed = options.committed,
            .precommit = options.precommit,
            .auth_client = self,
        });
        defer response.deinit(alloc);
        if (response.authentication_rejected) {
            try self.rememberAuthChallenge(response.www_authenticate);
            return error.McpAuthenticationRequired;
        }
        return alloc.dupe(u8, response.body);
    }

    pub fn sendNotification(
        self: *Client,
        alloc: Allocator,
        body: []const u8,
        control: Control,
    ) !void {
        if (self.stopping.load(.acquire)) return error.McpConnectionClosed;
        var response = try runBounded(alloc, .{
            .method = .POST,
            .url = self.url,
            .static_headers = self.static_headers,
            .version = self.version,
            .session_id = self.session_id,
            .request_body = body,
            .expected_notification = true,
            .max_response_bytes = 1,
            .max_event_bytes = 1,
            .control = control,
            .auth_client = self,
        });
        defer response.deinit(alloc);
        if (response.authentication_rejected) {
            try self.rememberAuthChallenge(response.www_authenticate);
            return error.McpAuthenticationRequired;
        }
    }

    pub fn listenNotifications(
        self: *Client,
        alloc: Allocator,
        max_event_bytes: usize,
        notifications: mcp_contract.NotificationSink,
        control: Control,
    ) !void {
        if (self.stopping.load(.acquire)) return error.McpConnectionClosed;
        var response = try runBounded(alloc, .{
            .method = .GET,
            .url = self.url,
            .static_headers = self.static_headers,
            .version = self.version,
            .session_id = self.session_id,
            .max_response_bytes = 1,
            .max_event_bytes = max_event_bytes,
            .notifications = notifications,
            .control = control,
            .auth_client = self,
        });
        response.deinit(alloc);
    }

    pub fn copyAuthChallenge(self: *Client, alloc: Allocator) !?[]u8 {
        self.auth_mutex.lockUncancelable(io_mod.getIo());
        defer self.auth_mutex.unlock(io_mod.getIo());
        return if (self.auth_challenge) |value| try alloc.dupe(u8, value) else null;
    }

    fn rememberAuthChallenge(self: *Client, value: ?[]const u8) !void {
        const replacement = if (value) |header|
            try self.owner_allocator.dupe(u8, header)
        else
            null;
        self.auth_mutex.lockUncancelable(io_mod.getIo());
        defer self.auth_mutex.unlock(io_mod.getIo());
        if (self.auth_challenge) |previous| self.owner_allocator.free(previous);
        self.auth_challenge = replacement;
    }

    /// Whether teardown should still send the session DELETE. Split out so a
    /// test can assert both directions; `terminateSession` swallows every
    /// transport error, so the skip is otherwise unobservable.
    fn shouldTerminateSession(self: *const Client) bool {
        if (self.session_id == null) return false;
        // The server answered 404 for this session id, so a DELETE would very
        // likely 404 as well. Skip it rather than spend a request.
        return !self.session_retired.load(.acquire);
    }

    fn terminateSession(self: *Client) void {
        if (!self.shouldTerminateSession()) return;
        const deadline = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)
            .addDuration(.{
            .clock = .awake,
            .raw = .fromMilliseconds(close_timeout_ms),
        });
        var response = runBounded(self.owner_allocator, .{
            .method = .DELETE,
            .url = self.url,
            .static_headers = self.static_headers,
            .version = self.version,
            .session_id = self.session_id,
            .max_response_bytes = 1,
            .max_event_bytes = 1,
            .control = .{ .deadline = deadline },
        }) catch |err| {
            debug_trace.logf(
                "mcp",
                "legacy HTTP session cleanup failed version={s} err={s}",
                .{ self.version.string(), @errorName(err) },
            );
            return;
        };
        response.deinit(self.owner_allocator);
    }
};

pub fn initialize(alloc: Allocator, options: InitializeOptions) !Initialized {
    try streamable_http.validateEndpoint(options.url);
    var response = try runBounded(alloc, .{
        .method = .POST,
        .url = options.url,
        .static_headers = options.static_headers,
        .request_body = options.request_body,
        .request_id = options.request_id,
        .capture_session = true,
        .max_response_bytes = options.max_response_bytes,
        .max_event_bytes = options.max_event_bytes,
        .control = options.control,
    });
    errdefer response.deinit(alloc);
    try transferInitializeAuthChallenge(options.auth_challenge, &response);

    const version = try initializedVersion(alloc, response.body);
    if (response.session_id) |session_id| {
        try validateSessionId(session_id);
    }

    const client = try alloc.create(Client);
    errdefer alloc.destroy(client);
    client.* = .{
        .owner_allocator = alloc,
        .url = options.url,
        .static_headers = options.static_headers,
        .version = version,
        .session_id = response.session_id,
    };
    response.session_id = null;
    const body = response.body;
    response.body = &.{};
    response.deinit(alloc);
    return .{
        .client = client,
        .response_body = body,
    };
}

fn transferInitializeAuthChallenge(
    out: ?*?[]u8,
    response: *OperationResponse,
) !void {
    if (!response.authentication_rejected) return;
    if (out) |destination| {
        destination.* = response.www_authenticate;
        response.www_authenticate = null;
    }
    return error.McpAuthenticationRequired;
}

pub fn validateSessionId(value: []const u8) !void {
    if (value.len == 0 or value.len > 1024) return error.InvalidMcpSessionId;
    for (value) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidMcpSessionId;
    }
}

fn initializedVersion(alloc: Allocator, body: []const u8) !Version {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return error.McpInvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidResult;
    const result = parsed.value.object.get("result") orelse
        return error.McpNoResult;
    if (result != .object) return error.McpInvalidResult;
    const protocol_version = result.object.get("protocolVersion") orelse
        return error.McpUnsupportedProtocolVersion;
    if (protocol_version != .string) return error.McpUnsupportedProtocolVersion;
    return parseVersion(protocol_version.string) orelse
        error.McpUnsupportedProtocolVersion;
}

const OperationOptions = struct {
    method: std.http.Method,
    url: []const u8,
    static_headers: []const mcp_contract.McpHttpHeader,
    version: ?Version = null,
    session_id: ?[]const u8 = null,
    last_event_id: ?[]const u8 = null,
    request_body: []const u8 = "",
    request_id: ?u64 = null,
    capture_session: bool = false,
    expected_notification: bool = false,
    max_response_bytes: usize,
    max_event_bytes: usize,
    progress: ?mcp_contract.ProgressSink = null,
    response_observer: ?ResponseObserver = null,
    server_requests: ?ServerRequestSink = null,
    notifications: ?mcp_contract.NotificationSink = null,
    control: Control,
    committed: ?*std.atomic.Value(bool) = null,
    precommit: ?*mcp_contract.TransportPrecommit = null,
    auth_client: ?*Client = null,
};

const OperationResponse = struct {
    body: []u8,
    session_id: ?[]u8 = null,
    authentication_rejected: bool = false,
    www_authenticate: ?[]u8 = null,

    fn deinit(self: *OperationResponse, alloc: Allocator) void {
        if (self.body.len > 0) alloc.free(self.body);
        if (self.session_id) |value| alloc.free(value);
        if (self.www_authenticate) |value| alloc.free(value);
        self.* = undefined;
    }
};

fn runBounded(alloc: Allocator, options: OperationOptions) !OperationResponse {
    try streamable_http.validateEndpoint(options.url);
    try streamable_http.validateStaticHeaders(options.static_headers);
    if (options.max_response_bytes == 0 or options.max_event_bytes == 0) {
        return error.InvalidResponseLimit;
    }
    if (options.session_id) |session_id| try validateSessionId(session_id);

    const cancellation = options.control.cancellation();
    if (cancellation.cancelled()) return error.Cancelled;
    if (controlExpired(options.control)) {
        return error.McpRequestTimedOut;
    }

    const Operation = struct {
        alloc: Allocator,
        options: OperationOptions,

        fn run(self: @This()) anyerror!OperationResponse {
            return runCore(self.alloc, self.options);
        }
    };
    const Event = union(enum) {
        request: anyerror!OperationResponse,
        cancelled: anyerror!void,
        deadline: anyerror!void,
    };
    const Cleanup = struct {
        fn drain(result_alloc: Allocator, select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .request => |result| {
                    var response = result catch continue;
                    response.deinit(result_alloc);
                },
                .cancelled, .deadline => {},
            };
        }
    };

    var select_buffer: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.cancelled, waitForCancellation, .{cancellation}) catch |err|
        return err;
    select.concurrent(.deadline, waitForControlDeadline, .{options.control}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.request, Operation.run, .{Operation{
        .alloc = alloc,
        .options = options,
    }}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    switch (event) {
        .request => |result| {
            Cleanup.drain(alloc, &select);
            if (cancellation.cancelled()) {
                var response = result catch return error.Cancelled;
                response.deinit(alloc);
                return error.Cancelled;
            }
            return result;
        },
        .cancelled => |result| {
            result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            return error.Cancelled;
        },
        .deadline => |result| {
            result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            if (cancellation.cancelled()) return error.Cancelled;
            return error.McpRequestTimedOut;
        },
    }
}

fn runCore(alloc: Allocator, options: OperationOptions) !OperationResponse {
    return switch (options.method) {
        .POST => postCore(alloc, options),
        .GET => notificationGetCore(alloc, options),
        .DELETE => deleteCore(alloc, options),
        else => error.UnsupportedHttpMethod,
    };
}

fn notificationGetCore(alloc: Allocator, options: OperationOptions) !OperationResponse {
    const sink = options.notifications orelse return error.MissingNotificationSink;
    var last_event_id: ?[]u8 = null;
    defer if (last_event_id) |value| alloc.free(value);

    while (true) {
        var next_options = options;
        next_options.last_event_id = last_event_id;
        const resumed = try notificationGetOnceCore(alloc, next_options, sink);
        if (last_event_id) |value| alloc.free(value);
        last_event_id = resumed.last_event_id;
        if (resumed.retry_ms > 0) {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            if (controlExpired(options.control)) {
                return error.McpRequestTimedOut;
            }
            const delay_deadline = now.addDuration(.{
                .clock = .awake,
                .raw = .fromMilliseconds(resumed.retry_ms),
            });
            const deadline = controlDeadline(options.control);
            const wake = if (std.Io.Clock.Timestamp.compare(
                delay_deadline,
                .lt,
                deadline,
            )) delay_deadline else deadline;
            try wake.wait(io_mod.getIo());
        }
    }
}

const NotificationResume = struct {
    last_event_id: ?[]u8,
    retry_ms: u32,
};

fn notificationGetOnceCore(
    alloc: Allocator,
    options: OperationOptions,
    sink: mcp_contract.NotificationSink,
) !NotificationResume {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try appendHeaders(alloc, &headers, options, false);

    const uri = std.Uri.parse(options.url) catch return error.InvalidEndpoint;
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = headers.items,
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    if (response.head.status.class() == .redirect) return error.RedirectNotAllowed;
    if (try authenticationRejection(alloc, response.head)) |rejection_value| {
        var rejection = rejection_value;
        defer rejection.deinit(alloc);
        if (options.auth_client) |auth_client| {
            try auth_client.rememberAuthChallenge(rejection.www_authenticate);
        }
        return error.McpAuthenticationRequired;
    }
    if (response.head.status == .method_not_allowed) {
        return error.McpNotificationListenerUnsupported;
    }
    if (response.head.status == .not_found and options.session_id != null) {
        return error.McpSessionExpired;
    }
    if (response.head.status != .ok) return error.UnexpectedHttpStatus;
    if (response.head.content_encoding != .identity) {
        return error.UnsupportedContentEncoding;
    }
    const content_type = response.head.content_type orelse
        return error.MissingContentType;
    if (parseMediaType(content_type) != .sse) return error.UnsupportedContentType;

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const result = try readNotificationStream(
        alloc,
        reader,
        options.max_event_bytes,
        sink,
    );
    request.connection.?.closing = true;
    return result;
}

fn readNotificationStream(
    alloc: Allocator,
    reader: *std.Io.Reader,
    max_event_bytes: usize,
    sink: mcp_contract.NotificationSink,
) !NotificationResume {
    var parser = legacy_sse.Parser.init(alloc, 0, max_event_bytes, 0);
    defer parser.deinit();
    var events: std.ArrayList(legacy_sse.Event) = .empty;
    defer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }
    var last_event_id: ?[]u8 = null;
    errdefer if (last_event_id) |value| alloc.free(value);
    var retry_ms: u32 = 0;

    while (true) {
        if (reader.buffered().len == 0) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    try parser.finish();
                    return .{
                        .last_event_id = last_event_id,
                        .retry_ms = retry_ms,
                    };
                },
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const chunk = reader.buffered();
        if (chunk.len == 0) continue;
        const chunk_len = if (std.mem.indexOfAny(u8, chunk, "\r\n")) |index|
            index + 1
        else
            chunk.len;
        try parser.feed(chunk[0..chunk_len], &events);
        reader.toss(chunk_len);
        for (events.items) |*event| {
            if (event.id) |id| try replaceEventId(alloc, &last_event_id, id);
            if (event.retry_ms) |value| retry_ms = value;
            if (event.data.len > 0) try routeNotification(alloc, event.data, sink);
        }
        for (events.items) |*event| event.deinit(alloc);
        events.clearRetainingCapacity();
    }
}

fn routeNotification(
    alloc: Allocator,
    data: []const u8,
    sink: mcp_contract.NotificationSink,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch
        return error.InvalidSseEvent;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSseEvent;
    const jsonrpc = parsed.value.object.get("jsonrpc") orelse
        return error.InvalidSseEvent;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidSseEvent;
    }
    if (parsed.value.object.contains("id")) return;
    const method = parsed.value.object.get("method") orelse
        return error.InvalidSseEvent;
    if (method != .string) return error.InvalidSseEvent;
    sink.callback(sink.context, parsed.value);
}

fn postCore(alloc: Allocator, options: OperationOptions) !OperationResponse {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try appendHeaders(alloc, &headers, options, true);

    const uri = std.Uri.parse(options.url) catch return error.InvalidEndpoint;
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var request = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = headers.items,
    });
    defer request.deinit();
    defer if (options.precommit) |precommit| precommit.release();
    if (options.precommit) |precommit| try precommit.acquire();
    try request.sendBodyComplete(@constCast(options.request_body));
    if (options.committed) |committed| committed.store(true, .release);
    if (options.precommit) |precommit| precommit.release();

    var response = request.receiveHead(&.{}) catch |err| switch (err) {
        error.HttpContentEncodingUnsupported => return error.UnsupportedContentEncoding,
        else => |e| return e,
    };
    if (response.head.status.class() == .redirect) return error.RedirectNotAllowed;
    if (try authenticationRejection(alloc, response.head)) |rejection| {
        return rejection;
    }
    if (options.expected_notification) {
        if (response.head.status != .accepted) return error.UnexpectedHttpStatus;
        return .{ .body = &.{} };
    }
    if (response.head.status == .not_found and options.session_id != null) {
        return error.McpSessionExpired;
    }
    if (response.head.status != .ok) return error.UnexpectedHttpStatus;
    if (response.head.content_encoding != .identity) {
        return error.UnsupportedContentEncoding;
    }

    const session_id = if (options.capture_session)
        if (findHeaderValue(response.head, "mcp-session-id")) |value|
            try alloc.dupe(u8, value)
        else
            null
    else
        null;
    errdefer if (session_id) |value| alloc.free(value);

    const request_id = options.request_id orelse return error.MissingRequestId;
    const content_type = response.head.content_type orelse
        return error.MissingContentType;
    const media_type = parseMediaType(content_type) orelse
        return error.UnsupportedContentType;
    if (media_type == .sse) {
        // Legacy POST streams may remain open after this request's final
        // response or fail while routing an interleaved event. Never let
        // Request.deinit drain the long-lived stream on either path.
        request.connection.?.closing = true;
    }
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = switch (media_type) {
        .json => try readJsonResponse(
            alloc,
            reader,
            request_id,
            options.max_response_bytes,
        ),
        .sse => try readSseWithResumption(
            alloc,
            reader,
            options,
            request_id,
        ),
    };
    errdefer alloc.free(body);
    if (options.response_observer) |observer| {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{
            .parse_numbers = false,
        }) catch return error.McpInvalidJson;
        defer parsed.deinit();
        try observer.callback(observer.context, alloc, parsed.value);
    }
    return .{ .body = body, .session_id = session_id };
}

fn authenticationRejection(
    alloc: Allocator,
    head: std.http.Client.Response.Head,
) !?OperationResponse {
    const authenticate = try mcp_auth.collectAuthenticateHeader(alloc, head);
    defer if (authenticate) |value| alloc.free(value);
    if (head.status != .unauthorized and
        (head.status != .forbidden or authenticate == null))
    {
        return null;
    }
    return .{
        .body = &.{},
        .authentication_rejected = true,
        .www_authenticate = if (authenticate) |value|
            try alloc.dupe(u8, value)
        else
            null,
    };
}

fn resumeOnceCore(
    alloc: Allocator,
    options: OperationOptions,
    request_id: u64,
    last_event_id: []const u8,
) !StreamResult {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    var resume_options = options;
    resume_options.last_event_id = last_event_id;
    try appendHeaders(alloc, &headers, resume_options, false);

    const uri = std.Uri.parse(options.url) catch return error.InvalidEndpoint;
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = headers.items,
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = request.receiveHead(&.{}) catch |err| switch (err) {
        error.HttpContentEncodingUnsupported => return error.UnsupportedContentEncoding,
        else => |e| return e,
    };
    if (response.head.status.class() == .redirect) return error.RedirectNotAllowed;
    if (try authenticationRejection(alloc, response.head)) |rejection_value| {
        var rejection = rejection_value;
        defer rejection.deinit(alloc);
        if (options.auth_client) |auth_client| {
            try auth_client.rememberAuthChallenge(rejection.www_authenticate);
        }
        return error.McpAuthenticationRequired;
    }
    if (response.head.status == .not_found and options.session_id != null) {
        return error.McpSessionExpired;
    }
    if (response.head.status != .ok) return error.UnexpectedHttpStatus;
    if (response.head.content_encoding != .identity) {
        return error.UnsupportedContentEncoding;
    }
    const content_type = response.head.content_type orelse
        return error.MissingContentType;
    if (parseMediaType(content_type) != .sse) return error.UnsupportedContentType;

    // Resumption GET streams may remain open after delivering this request's
    // final response or fail while routing an interleaved event.
    request.connection.?.closing = true;
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const result = try readSseStream(alloc, reader, options, request_id);
    return result;
}

fn deleteCore(alloc: Allocator, options: OperationOptions) !OperationResponse {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try appendHeaders(alloc, &headers, options, false);

    const uri = std.Uri.parse(options.url) catch return error.InvalidEndpoint;
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var request = try client.request(.DELETE, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = headers.items,
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    if (response.head.status.class() == .redirect) return error.RedirectNotAllowed;
    switch (response.head.status) {
        .ok, .no_content, .method_not_allowed => {},
        else => return error.UnexpectedHttpStatus,
    }
    return .{ .body = &.{} };
}

fn appendHeaders(
    alloc: Allocator,
    headers: *std.ArrayList(std.http.Header),
    options: OperationOptions,
    accepts_json: bool,
) !void {
    try headers.append(alloc, .{
        .name = "Accept",
        .value = if (accepts_json)
            "application/json, text/event-stream"
        else
            "text/event-stream",
    });
    if (options.version) |version| {
        if (version.sendsProtocolHeader()) {
            try headers.append(alloc, .{
                .name = "MCP-Protocol-Version",
                .value = version.string(),
            });
        }
    }
    if (options.session_id) |session_id| {
        try headers.append(alloc, .{
            .name = "MCP-Session-Id",
            .value = session_id,
        });
    }
    if (options.last_event_id) |last_event_id| {
        try streamable_http.validateHeaderValue(last_event_id);
        try headers.append(alloc, .{
            .name = "Last-Event-ID",
            .value = last_event_id,
        });
    }
    for (options.static_headers) |header| {
        try headers.append(alloc, .{ .name = header.name, .value = header.value });
    }
}

const MediaType = enum { json, sse };

fn parseMediaType(value: []const u8) ?MediaType {
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..separator], " \t");
    if (std.ascii.eqlIgnoreCase(media_type, "application/json")) return .json;
    if (std.ascii.eqlIgnoreCase(media_type, "text/event-stream")) return .sse;
    return null;
}

fn readJsonResponse(
    alloc: Allocator,
    reader: *std.Io.Reader,
    request_id: u64,
    max_response_bytes: usize,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const read_len = try reader.readSliceShort(&chunk);
        if (read_len > max_response_bytes -| body.items.len) {
            return error.ResponseTooLarge;
        }
        try body.appendSlice(alloc, chunk[0..read_len]);
        if (read_len < chunk.len) break;
    }
    const owned = try body.toOwnedSlice(alloc);
    errdefer alloc.free(owned);
    try validateFinalResponse(alloc, owned, request_id);
    return owned;
}

const StreamResult = union(enum) {
    final: []u8,
    resumable: struct {
        last_event_id: []u8,
        retry_ms: u32,
    },
};

fn readSseWithResumption(
    alloc: Allocator,
    initial_reader: *std.Io.Reader,
    options: OperationOptions,
    request_id: u64,
) ![]u8 {
    var stream = try readSseStream(alloc, initial_reader, options, request_id);
    while (true) switch (stream) {
        .final => |body| return body,
        .resumable => |resume_state| {
            if (resume_state.retry_ms > 0) {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (controlExpired(options.control)) {
                    alloc.free(resume_state.last_event_id);
                    return error.McpRequestTimedOut;
                }
                const delay_deadline = now.addDuration(.{
                    .clock = .awake,
                    .raw = .fromMilliseconds(resume_state.retry_ms),
                });
                const deadline = controlDeadline(options.control);
                const wake = if (std.Io.Clock.Timestamp.compare(
                    delay_deadline,
                    .lt,
                    deadline,
                )) delay_deadline else deadline;
                wake.wait(io_mod.getIo()) catch |err| {
                    alloc.free(resume_state.last_event_id);
                    return err;
                };
            }
            const last_event_id = resume_state.last_event_id;
            stream = resumeOnceCore(
                alloc,
                options,
                request_id,
                last_event_id,
            ) catch |err| {
                alloc.free(last_event_id);
                return err;
            };
            alloc.free(last_event_id);
        },
    };
}

fn readSseStream(
    alloc: Allocator,
    reader: *std.Io.Reader,
    options: OperationOptions,
    request_id: u64,
) !StreamResult {
    var parser = legacy_sse.Parser.init(
        alloc,
        options.max_response_bytes,
        options.max_event_bytes,
        max_sse_events,
    );
    defer parser.deinit();
    var events: std.ArrayList(legacy_sse.Event) = .empty;
    defer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }
    var last_event_id: ?[]u8 = null;
    defer if (last_event_id) |value| alloc.free(value);
    var retry_ms: u32 = 0;
    var saw_polling_priming = false;

    while (true) {
        if (reader.buffered().len == 0) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    try parser.finish();
                    const version = options.version orelse
                        return error.MissingLegacyVersion;
                    if (closeIsResumable(
                        version,
                        last_event_id,
                        saw_polling_priming,
                    )) {
                        const owned_id = try alloc.dupe(
                            u8,
                            last_event_id orelse "",
                        );
                        return .{ .resumable = .{
                            .last_event_id = owned_id,
                            .retry_ms = retry_ms,
                        } };
                    }
                    return error.MissingFinalResponse;
                },
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const chunk = reader.buffered();
        if (chunk.len == 0) continue;
        const chunk_len = if (std.mem.indexOfAny(u8, chunk, "\r\n")) |index|
            index + 1
        else
            chunk.len;
        try parser.feed(chunk[0..chunk_len], &events);
        reader.toss(chunk_len);
        for (events.items) |*event| {
            if (event.id) |id| {
                try replaceEventId(alloc, &last_event_id, id);
                if (id.len == 0 and event.data.len == 0) {
                    saw_polling_priming = true;
                }
            }
            if (event.retry_ms) |value| retry_ms = value;
            switch (try classifyEvent(
                alloc,
                event.data,
                request_id,
                options.progress,
            )) {
                .notification => if (options.notifications) |sink| {
                    try routeNotification(alloc, event.data, sink);
                },
                .progress, .empty => {},
                .server_request => {
                    const sink = options.server_requests orelse return error.UnsupportedServerRequest;
                    if (sink.prepare_callback) |prepare| {
                        try prepare(sink.context, alloc, event.data);
                    }
                    try sink.callback(sink.context, alloc, event.data);
                },
                .final => {
                    try validateFinalResponse(alloc, event.data, request_id);
                    return .{ .final = try alloc.dupe(u8, event.data) };
                },
            }
        }
        for (events.items) |*event| event.deinit(alloc);
        events.clearRetainingCapacity();
    }
}

fn replaceEventId(
    alloc: Allocator,
    target: *?[]u8,
    value: []const u8,
) !void {
    const replacement = try alloc.dupe(u8, value);
    if (target.*) |old| alloc.free(old);
    target.* = replacement;
}

fn closeIsResumable(
    version: Version,
    last_event_id: ?[]const u8,
    saw_polling_priming: bool,
) bool {
    if (last_event_id) |value| {
        if (value.len > 0) return true;
    }
    return version.allowsPollingClose() and saw_polling_priming;
}

const EventOutcome = enum { empty, notification, progress, server_request, final };

fn classifyEvent(
    alloc: Allocator,
    data: []const u8,
    request_id: u64,
    progress_sink: ?mcp_contract.ProgressSink,
) !EventOutcome {
    if (data.len == 0) return .empty;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch
        return error.InvalidSseEvent;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSseEvent;
    const jsonrpc = parsed.value.object.get("jsonrpc") orelse
        return error.InvalidSseEvent;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidSseEvent;
    }

    if (parsed.value.object.get("id")) |id_value| {
        if (parsed.value.object.get("method")) |method| {
            if (method != .string or method.string.len == 0) return error.InvalidSseEvent;
            return .server_request;
        }
        if (id_value != .integer or id_value.integer < 0 or
            @as(u64, @intCast(id_value.integer)) != request_id)
        {
            return error.MismatchedResponseId;
        }
        if (parsed.value.object.contains("result") or
            parsed.value.object.contains("error"))
        {
            return .final;
        }
        return error.UnsupportedServerRequest;
    }

    const method = parsed.value.object.get("method") orelse
        return error.InvalidSseEvent;
    if (method != .string) return error.InvalidSseEvent;
    if (!std.mem.eql(u8, method.string, "notifications/progress")) {
        return .notification;
    }
    const params = parsed.value.object.get("params") orelse return .notification;
    if (params != .object) return .notification;
    const token = params.object.get("progressToken") orelse return .notification;
    if (token != .integer or token.integer < 0 or
        @as(u64, @intCast(token.integer)) != request_id)
    {
        return .notification;
    }
    const progress_value = params.object.get("progress") orelse
        return .notification;
    const progress = jsonNumberAsF64(progress_value) orelse return .notification;
    const total = if (params.object.get("total")) |value|
        jsonNumberAsF64(value)
    else
        null;
    const message = if (params.object.get("message")) |value|
        if (value == .string) value.string else null
    else
        null;
    if (progress_sink) |sink| {
        sink.callback(sink.context, .{
            .progress = progress,
            .total = total,
            .message = message,
        });
    }
    return .progress;
}

fn validateFinalResponse(
    alloc: Allocator,
    body: []const u8,
    request_id: u64,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return error.McpInvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidJson;
    const jsonrpc = parsed.value.object.get("jsonrpc") orelse
        return error.McpInvalidJson;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.McpInvalidJson;
    }
    const id = parsed.value.object.get("id") orelse return error.McpInvalidJson;
    if (id != .integer or id.integer < 0 or
        @as(u64, @intCast(id.integer)) != request_id)
    {
        return error.MismatchedResponseId;
    }
    if (!parsed.value.object.contains("result") and
        !parsed.value.object.contains("error"))
    {
        return error.McpInvalidJson;
    }
}

fn jsonNumberAsF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

fn findHeaderValue(
    head: std.http.Client.Response.Head,
    name: []const u8,
) ?[]const u8 {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return std.mem.trim(u8, header.value, " \t\r\n");
        }
    }
    return null;
}

fn waitForCancellation(cancellation: operation_control.CancellationSources) anyerror!void {
    while (!cancellation.cancelled()) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

fn waitForControlDeadline(control: Control) anyerror!void {
    if (control.deadline_gate == null) return waitForDeadline(control.deadline);
    while (!controlExpired(control)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn controlExpired(control: Control) bool {
    const gate = control.deadline_gate orelse {
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        return !std.Io.Clock.Timestamp.compare(now, .lt, control.deadline);
    };
    return gate.expired(awakeMilliseconds());
}

fn controlDeadline(control: Control) std.Io.Clock.Timestamp {
    const gate = control.deadline_gate orelse return control.deadline;
    return .{
        .clock = .awake,
        .raw = std.Io.Timestamp.fromNanoseconds(
            @as(i96, gate.currentDeadlineMs()) * std.time.ns_per_ms,
        ),
    };
}

fn awakeMilliseconds() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const value = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, value) orelse if (value < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

test "legacy Streamable HTTP version policy is explicit" {
    const cases = [_]struct {
        raw: []const u8,
        version: Version,
        sends_header: bool,
        polling_close: bool,
    }{
        .{
            .raw = "2025-11-25",
            .version = .v2025_11_25,
            .sends_header = true,
            .polling_close = true,
        },
        .{
            .raw = "2025-06-18",
            .version = .v2025_06_18,
            .sends_header = true,
            .polling_close = false,
        },
        .{
            .raw = "2025-03-26",
            .version = .v2025_03_26,
            .sends_header = false,
            .polling_close = false,
        },
    };
    try std.testing.expectEqual(cases.len, supported_versions.len);
    try std.testing.expectEqual(supported_versions[0], preferred_version);
    for (cases, 0..) |case, index| {
        const version = parseVersion(case.raw).?;
        try std.testing.expectEqual(case.version, version);
        try std.testing.expectEqual(case.version, supported_versions[index]);
        try std.testing.expectEqual(case.sends_header, version.sendsProtocolHeader());
        try std.testing.expectEqual(case.polling_close, version.allowsPollingClose());
    }
    try std.testing.expect(parseVersion("2024-11-05") == null);
    try std.testing.expect(parseVersion("2026-07-28") == null);
}

test "legacy Streamable HTTP polling close is scoped to 2025-11-25" {
    inline for ([_]Version{
        .v2025_11_25,
        .v2025_06_18,
        .v2025_03_26,
    }) |version| {
        try std.testing.expect(closeIsResumable(version, "event-1", false));
    }
    try std.testing.expect(closeIsResumable(.v2025_11_25, "", true));
    try std.testing.expect(!closeIsResumable(.v2025_06_18, "", true));
    try std.testing.expect(!closeIsResumable(.v2025_03_26, "", true));
    try std.testing.expect(!closeIsResumable(.v2025_11_25, null, false));
}

test "legacy Streamable HTTP initialization selects only committed versions" {
    try std.testing.expectEqual(
        Version.v2025_06_18,
        try initializedVersion(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\"}}",
        ),
    );
    try std.testing.expectError(
        error.McpUnsupportedProtocolVersion,
        initializedVersion(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}",
        ),
    );
}

test "legacy Streamable HTTP validates protocol session IDs" {
    try validateSessionId("session-123");
    try std.testing.expectError(error.InvalidMcpSessionId, validateSessionId(""));
    try std.testing.expectError(
        error.InvalidMcpSessionId,
        validateSessionId("contains space"),
    );
    try std.testing.expectError(
        error.InvalidMcpSessionId,
        validateSessionId("contains\nnewline"),
    );
}

test "legacy Streamable HTTP preserves initialize authentication challenge" {
    const alloc = std.testing.allocator;
    var challenge: ?[]u8 = null;
    defer if (challenge) |value| alloc.free(value);
    var response = OperationResponse{
        .body = &.{},
        .authentication_rejected = true,
        .www_authenticate = try alloc.dupe(
            u8,
            "Bearer scope=\"tools.call\"",
        ),
    };
    defer response.deinit(alloc);

    try std.testing.expectError(
        error.McpAuthenticationRequired,
        transferInitializeAuthChallenge(&challenge, &response),
    );
    try std.testing.expectEqualStrings(
        "Bearer scope=\"tools.call\"",
        challenge.?,
    );
    try std.testing.expect(response.www_authenticate == null);
}

test "legacy Streamable HTTP classifies final progress and server requests" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(
        EventOutcome.final,
        try classifyEvent(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}",
            7,
            null,
        ),
    );
    try std.testing.expectEqual(
        EventOutcome.notification,
        try classifyEvent(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{}}",
            7,
            null,
        ),
    );
    try std.testing.expectEqual(
        EventOutcome.server_request,
        try classifyEvent(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"roots/list\",\"params\":{}}",
            7,
            null,
        ),
    );
}

fn checkSseEventIdAllocationFailures(alloc: Allocator) !void {
    var event_id: ?[]u8 = null;
    defer if (event_id) |value| alloc.free(value);
    try replaceEventId(alloc, &event_id, "event-1");
    try replaceEventId(alloc, &event_id, "event-2");
}

test "legacy Streamable HTTP replaces event IDs across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSseEventIdAllocationFailures,
        .{},
    );
}

test "legacy Streamable HTTP rejects unsafe resumption header values" {
    const alloc = std.testing.allocator;
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try std.testing.expectError(
        error.InvalidHeaderValue,
        appendHeaders(alloc, &headers, .{
            .method = .GET,
            .url = "",
            .static_headers = &.{},
            .last_event_id = "unsafe\x01id",
            .max_response_bytes = 1,
            .max_event_bytes = 1,
            .control = undefined,
        }, false),
    );
}

fn testClientWithSession(alloc: Allocator, session_id: []const u8) !*Client {
    const client = try alloc.create(Client);
    errdefer alloc.destroy(client);
    client.* = .{
        .owner_allocator = alloc,
        .url = "http://127.0.0.1:1/mcp",
        .static_headers = &.{},
        .version = .v2025_03_26,
        .session_id = try alloc.dupe(u8, session_id),
    };
    return client;
}

test "retiring an expired session keeps the id alive for in-flight requests" {
    const alloc = std.testing.allocator;
    const client = try testClientWithSession(alloc, "session-abc");

    // Stand in for a request that is already past `acquireUse` and is using
    // session_id as an outgoing header.
    try std.testing.expect(client.acquireUse());
    const in_flight = client.session_id.?;

    client.retireExpiredSession();

    try std.testing.expect(client.session_id != null);
    try std.testing.expectEqualStrings("session-abc", in_flight);

    client.releaseUse();
    // deinit drains active_users before freeing, so it owns the free.
    client.deinit();
}

/// Stands in for a request that is already in flight: it holds a use lease and
/// keeps reading `session_id` as an outgoing header would, then releases.
const LeaseProbe = struct {
    client: *Client,
    entered: *std.atomic.Value(bool),
    released: *std.atomic.Value(bool),
    id_stayed_valid: *std.atomic.Value(bool),

    fn run(self: LeaseProbe) void {
        self.entered.store(true, .release);
        var i: usize = 0;
        while (i < 200_000) : (i += 1) {
            const id = self.client.session_id orelse {
                self.id_stayed_valid.store(false, .release);
                break;
            };
            if (!std.mem.eql(u8, id, "session-drain")) {
                self.id_stayed_valid.store(false, .release);
                break;
            }
        }
        self.released.store(true, .release);
        self.client.releaseUse();
    }
};

test "deinit waits for an in-flight lease before it frees the session id" {
    const alloc = std.testing.allocator;
    const client = try testClientWithSession(alloc, "session-drain");

    var entered: std.atomic.Value(bool) = .init(false);
    var released: std.atomic.Value(bool) = .init(false);
    var id_stayed_valid: std.atomic.Value(bool) = .init(true);

    try std.testing.expect(client.acquireUse());
    const probe = try std.Thread.spawn(.{}, LeaseProbe.run, .{LeaseProbe{
        .client = client,
        .entered = &entered,
        .released = &released,
        .id_stayed_valid = &id_stayed_valid,
    }});
    while (!entered.load(.acquire)) {}

    client.retireExpiredSession();
    client.deinit();

    // deinit must not have returned until the probe gave the lease back, and
    // the id it was reading must have stayed valid for that whole window.
    try std.testing.expect(released.load(.acquire));
    try std.testing.expect(id_stayed_valid.load(.acquire));
    probe.join();
}

test "a retired session refuses new leases and skips the delete on teardown" {
    const alloc = std.testing.allocator;
    const client = try testClientWithSession(alloc, "session-xyz");

    // A live session is still deleted on teardown; only retirement skips it.
    try std.testing.expect(client.shouldTerminateSession());

    client.retireExpiredSession();

    try std.testing.expect(!client.acquireUse());
    try std.testing.expect(!client.shouldTerminateSession());
    client.deinit();
}
