const std = @import("std");
const host_target = @import("../hosts/target.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const legacy_sse = @import("legacy_sse.zig");
const mcp_auth = @import("mcp_auth.zig");
const mcp_contract = @import("mcp_contract.zig");
const operation_control = @import("operation_control.zig");
const streamable_http = @import("streamable_http.zig");

const Allocator = std.mem.Allocator;
const request_poll_ns: u64 = 5 * std.time.ns_per_ms;
const cancellation_timeout_ms: i64 = 100;

pub const protocol_version = "2024-11-05";

pub const Control = struct {
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,
    precommit: ?*mcp_contract.TransportPrecommit = null,

    pub fn cancellation(self: Control) operation_control.CancellationSources {
        return .{
            .caller = self.cancel_flag,
            .runtime = self.lifecycle_cancel_flag,
        };
    }
};

pub fn validateInitializeResponse(alloc: Allocator, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return error.McpInvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidResult;
    const result = parsed.value.object.get("result") orelse
        return error.McpNoResult;
    if (result != .object) return error.McpInvalidResult;
    const selected = result.object.get("protocolVersion") orelse
        return error.McpUnsupportedProtocolVersion;
    if (selected != .string or
        !std.mem.eql(u8, selected.string, protocol_version))
    {
        return error.McpUnsupportedProtocolVersion;
    }
}

const ConnectionState = enum {
    starting,
    running,
    stopping,
    failed,
    stopped,
};

pub const ReaderFinishReason = enum {
    closed,
    authentication_required,
};

const Pending = struct {
    response: ?[]u8 = null,
    failure: ?anyerror = null,
};

pub const Client = struct {
    owner_allocator: Allocator,
    shared_allocator: Allocator,
    discovery_url: []const u8,
    static_headers: []const mcp_contract.McpHttpHeader,
    reader_thread: ?std.Thread = null,
    state_mutex: std.Io.Mutex = .init,
    auth_mutex: std.Io.Mutex = .init,
    state: ConnectionState = .starting,
    stop_flag: std.atomic.Value(bool) = .init(false),
    endpoint: ?[]u8 = null,
    startup_failure: ?anyerror = null,
    reader_failure: ?anyerror = null,
    auth_challenge: ?[]u8 = null,
    pending: std.AutoHashMap(u64, *Pending),
    max_event_bytes: std.atomic.Value(usize),
    notification_sink: ?mcp_contract.NotificationSink = null,
    notification_callback_active: bool = false,

    pub fn create(
        owner_allocator: Allocator,
        shared_allocator: Allocator,
        discovery_url: []const u8,
        static_headers: []const mcp_contract.McpHttpHeader,
        initial_max_event_bytes: usize,
        control: Control,
        auth_challenge_out: *?[]u8,
    ) !*Client {
        if (comptime host_target.is_wasm) return error.McpTransportUnavailable;
        auth_challenge_out.* = null;
        try streamable_http.validateEndpoint(discovery_url);
        try streamable_http.validateStaticHeaders(static_headers);
        if (initial_max_event_bytes == 0) return error.InvalidResponseLimit;

        const self = try owner_allocator.create(Client);
        self.* = .{
            .owner_allocator = owner_allocator,
            .shared_allocator = shared_allocator,
            .discovery_url = discovery_url,
            .static_headers = static_headers,
            .pending = std.AutoHashMap(u64, *Pending).init(shared_allocator),
            .max_event_bytes = .init(initial_max_event_bytes),
        };
        errdefer self.destroyOwned();
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        errdefer self.shutdownAndJoin();
        self.waitUntilReady(control) catch |err| {
            if (err == error.McpAuthenticationRequired) {
                auth_challenge_out.* = try self.copyAuthChallenge(owner_allocator);
            }
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.shutdownAndJoin();
        self.destroyOwned();
    }

    fn destroyOwned(self: *Client) void {
        if (self.endpoint) |value| self.shared_allocator.free(value);
        if (self.auth_challenge) |value| self.shared_allocator.free(value);
        self.pending.deinit();
        const owner_allocator = self.owner_allocator;
        owner_allocator.destroy(self);
    }

    pub fn request(
        self: *Client,
        alloc: Allocator,
        request_id: u64,
        body: []const u8,
        max_frame_bytes: usize,
        options: Control,
    ) ![]u8 {
        if (max_frame_bytes == 0) return error.InvalidResponseLimit;
        if (options.cancellation().cancelled()) return error.Cancelled;
        _ = self.max_event_bytes.fetchMax(max_frame_bytes, .monotonic);

        var pending = Pending{};
        try self.registerPending(request_id, &pending);
        var registered = true;
        defer if (registered) self.removePending(request_id, &pending);

        var committed = std.atomic.Value(bool).init(false);
        postMessageBounded(
            alloc,
            self,
            body,
            options.deadline,
            options.cancellation(),
            &committed,
            options.precommit,
        ) catch |err| {
            self.removePending(request_id, &pending);
            registered = false;
            if (committed.load(.acquire) and
                (err == error.Cancelled or err == error.McpRequestTimedOut))
            {
                self.sendCancellation(alloc, request_id, @errorName(err));
            }
            return err;
        };

        while (true) {
            var response: ?[]u8 = null;
            var failure: ?anyerror = null;
            var cancelled = false;
            var timed_out = false;

            self.state_mutex.lockUncancelable(io_mod.getIo());
            if (pending.response) |frame| {
                response = frame;
                pending.response = null;
                _ = self.pending.remove(request_id);
                registered = false;
            } else if (pending.failure) |err| {
                failure = err;
                _ = self.pending.remove(request_id);
                registered = false;
            } else {
                cancelled = options.cancellation().cancelled();
                timed_out = deadlineExpired(options.deadline);
                if (cancelled or timed_out) {
                    _ = self.pending.remove(request_id);
                    registered = false;
                }
            }
            self.state_mutex.unlock(io_mod.getIo());

            if (response) |frame| {
                defer self.shared_allocator.free(frame);
                if (frame.len > max_frame_bytes) return error.McpResponseFrameTooLarge;
                return alloc.dupe(u8, frame);
            }
            if (failure) |err| return err;
            if (cancelled or timed_out) {
                if (committed.load(.acquire)) {
                    self.sendCancellation(
                        alloc,
                        request_id,
                        if (cancelled) "Cancelled" else "McpRequestTimedOut",
                    );
                }
                return if (cancelled) error.Cancelled else error.McpRequestTimedOut;
            }
            io_mod.sleep(request_poll_ns);
        }
    }

    pub fn sendNotification(
        self: *Client,
        alloc: Allocator,
        body: []const u8,
        control: Control,
    ) !void {
        if (!self.isRunning()) return error.McpConnectionClosed;
        var committed = std.atomic.Value(bool).init(false);
        try postMessageBounded(
            alloc,
            self,
            body,
            control.deadline,
            control.cancellation(),
            &committed,
            control.precommit,
        );
    }

    pub fn copyAuthChallenge(self: *Client, alloc: Allocator) !?[]u8 {
        self.auth_mutex.lockUncancelable(io_mod.getIo());
        defer self.auth_mutex.unlock(io_mod.getIo());
        return if (self.auth_challenge) |value| try alloc.dupe(u8, value) else null;
    }

    pub fn setNotificationSink(
        self: *Client,
        sink: mcp_contract.NotificationSink,
    ) !void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (self.state != .running) return error.McpConnectionClosed;
        if (self.notification_sink != null) return error.McpNotificationSinkExists;
        self.notification_sink = sink;
    }

    pub fn clearNotificationSink(self: *Client) void {
        while (true) {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            self.notification_sink = null;
            const drained = !self.notification_callback_active;
            self.state_mutex.unlock(io_mod.getIo());
            if (drained) return;
            io_mod.sleep(request_poll_ns);
        }
    }

    pub fn readerFinishReason(self: *Client) ?ReaderFinishReason {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return switch (self.state) {
            .starting, .running, .stopping => null,
            .stopped => .closed,
            .failed => if (self.reader_failure) |failure|
                if (failure == error.McpAuthenticationRequired)
                    .authentication_required
                else
                    .closed
            else
                .closed,
        };
    }

    fn rememberAuthChallenge(self: *Client, value: ?[]const u8) !void {
        const replacement = if (value) |header|
            try self.shared_allocator.dupe(u8, header)
        else
            null;
        self.auth_mutex.lockUncancelable(io_mod.getIo());
        defer self.auth_mutex.unlock(io_mod.getIo());
        if (self.auth_challenge) |previous| self.shared_allocator.free(previous);
        self.auth_challenge = replacement;
    }

    fn waitUntilReady(self: *Client, control: Control) !void {
        while (true) {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            const state = self.state;
            const failure = self.startup_failure;
            self.state_mutex.unlock(io_mod.getIo());
            switch (state) {
                .running => return,
                .failed, .stopped => return failure orelse error.McpConnectionClosed,
                .starting, .stopping => {},
            }
            if (control.cancellation().cancelled()) return error.Cancelled;
            if (deadlineExpired(control.deadline)) return error.McpRequestTimedOut;
            io_mod.sleep(request_poll_ns);
        }
    }

    fn isRunning(self: *Client) bool {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        return self.state == .running;
    }

    fn registerPending(
        self: *Client,
        request_id: u64,
        pending: *Pending,
    ) !void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (self.state != .running) return error.McpConnectionClosed;
        if (self.pending.contains(request_id)) return error.McpDuplicateRequestId;
        try self.pending.put(request_id, pending);
    }

    fn removePending(
        self: *Client,
        request_id: u64,
        pending: *Pending,
    ) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (self.pending.get(request_id) == pending) {
            _ = self.pending.remove(request_id);
        }
        if (pending.response) |frame| {
            self.shared_allocator.free(frame);
            pending.response = null;
        }
    }

    fn sendCancellation(
        self: *Client,
        alloc: Allocator,
        request_id: u64,
        reason: []const u8,
    ) void {
        const body = buildCancellation(alloc, request_id, reason) catch |err| {
            debug_trace.logf(
                "mcp",
                "failed to build HTTP+SSE cancellation request_id={d} err={s}",
                .{ request_id, @errorName(err) },
            );
            return;
        };
        defer alloc.free(body);
        const deadline = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)
            .addDuration(.{
            .clock = .awake,
            .raw = .fromMilliseconds(cancellation_timeout_ms),
        });
        self.sendNotification(
            alloc,
            body,
            .{ .deadline = deadline },
        ) catch |err| {
            debug_trace.logf(
                "mcp",
                "failed to send HTTP+SSE cancellation request_id={d} err={s}",
                .{ request_id, @errorName(err) },
            );
        };
    }

    fn shutdownAndJoin(self: *Client) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        if (self.state != .stopped and self.state != .failed) {
            self.state = .stopping;
        }
        self.failPendingLocked(error.McpConnectionClosed);
        self.state_mutex.unlock(io_mod.getIo());
        self.stop_flag.store(true, .release);
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
    }

    fn failPendingLocked(self: *Client, failure: anyerror) void {
        var it = self.pending.valueIterator();
        while (it.next()) |pending| {
            if (pending.*.failure == null and pending.*.response == null) {
                pending.*.failure = failure;
            }
        }
    }

    fn readerMain(self: *Client) void {
        const ReadOperation = struct {
            client: *Client,

            fn run(operation: @This()) anyerror!void {
                try operation.client.readConnection();
            }
        };
        const Event = union(enum) {
            read: anyerror!void,
            stop: anyerror!void,
        };
        var select_buffer: [2]Event = undefined;
        var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
        select.concurrent(.stop, waitForStop, .{&self.stop_flag}) catch |err| {
            self.finishReader(err);
            return;
        };
        select.concurrent(.read, ReadOperation.run, .{ReadOperation{
            .client = self,
        }}) catch |err| {
            select.cancelDiscard();
            self.finishReader(err);
            return;
        };

        const event = select.await() catch |err| {
            select.cancelDiscard();
            self.finishReader(err);
            return;
        };
        switch (event) {
            .stop => |result| {
                result catch |err| {
                    select.cancelDiscard();
                    self.finishReader(err);
                    return;
                };
                select.cancelDiscard();
                self.finishReader(null);
            },
            .read => |result| {
                select.cancelDiscard();
                result catch |err| {
                    self.finishReader(err);
                    return;
                };
                self.finishReader(error.McpConnectionClosed);
            },
        }
    }

    fn readConnection(self: *Client) !void {
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(self.shared_allocator);
        try headers.append(self.shared_allocator, .{
            .name = "Accept",
            .value = "text/event-stream",
        });
        for (self.static_headers) |header| {
            try headers.append(self.shared_allocator, .{
                .name = header.name,
                .value = header.value,
            });
        }

        const uri = std.Uri.parse(self.discovery_url) catch
            return error.InvalidEndpoint;
        var http_client: std.http.Client = .{
            .allocator = self.shared_allocator,
            .io = io_mod.getIo(),
        };
        defer http_client.deinit();
        var http_request = try http_client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{ .accept_encoding = .omit },
            .extra_headers = headers.items,
        });
        defer http_request.deinit();
        try http_request.sendBodiless();
        var response = try http_request.receiveHead(&.{});
        if (response.head.status.class() == .redirect) return error.RedirectNotAllowed;
        const authenticate = try mcp_auth.collectAuthenticateHeader(
            self.shared_allocator,
            response.head,
        );
        defer if (authenticate) |value| self.shared_allocator.free(value);
        if (response.head.status == .unauthorized or
            (response.head.status == .forbidden and authenticate != null))
        {
            try self.rememberAuthChallenge(authenticate);
            return error.McpAuthenticationRequired;
        }
        if (response.head.status != .ok) return error.UnexpectedHttpStatus;
        if (response.head.content_encoding != .identity) {
            return error.UnsupportedContentEncoding;
        }
        const content_type = response.head.content_type orelse
            return error.MissingContentType;
        if (!isEventStream(content_type)) return error.UnsupportedContentType;

        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var parser = legacy_sse.Parser.init(
            self.shared_allocator,
            0,
            self.max_event_bytes.load(.monotonic),
            0,
        );
        defer parser.deinit();
        var events: std.ArrayList(legacy_sse.Event) = .empty;
        defer {
            for (events.items) |*event| event.deinit(self.shared_allocator);
            events.deinit(self.shared_allocator);
        }

        while (true) {
            parser.setMaxEventBytes(self.max_event_bytes.load(.monotonic));
            if (reader.buffered().len == 0) {
                reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        try parser.finish();
                        return error.McpConnectionClosed;
                    },
                    error.ReadFailed => return error.ReadFailed,
                };
            }
            const chunk = reader.buffered();
            if (chunk.len == 0) continue;
            const chunk_len = if (std.mem.findAny(u8, chunk, "\r\n")) |index|
                index + 1
            else
                chunk.len;
            try parser.feed(chunk[0..chunk_len], &events);
            reader.toss(chunk_len);
            for (events.items) |*event| {
                try self.handleEvent(event);
            }
            for (events.items) |*event| event.deinit(self.shared_allocator);
            events.clearRetainingCapacity();
        }
    }

    fn handleEvent(self: *Client, event: *const legacy_sse.Event) !void {
        const kind = event.kind orelse "message";
        if (std.mem.eql(u8, kind, "endpoint")) {
            const endpoint = try resolveMessageEndpoint(
                self.shared_allocator,
                self.discovery_url,
                event.data,
            );
            errdefer self.shared_allocator.free(endpoint);
            self.state_mutex.lockUncancelable(io_mod.getIo());
            defer self.state_mutex.unlock(io_mod.getIo());
            if (self.endpoint != null or self.state != .starting) {
                return error.InvalidSseEndpointEvent;
            }
            self.endpoint = endpoint;
            self.state = .running;
            return;
        }
        if (!std.mem.eql(u8, kind, "message")) return;
        try self.dispatchMessage(event.data);
    }

    fn dispatchMessage(self: *Client, data: []const u8) !void {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.shared_allocator,
            data,
            .{},
        ) catch return error.McpInvalidJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.McpInvalidJson;
        const jsonrpc = parsed.value.object.get("jsonrpc") orelse
            return error.McpInvalidJson;
        if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
            return error.McpInvalidJson;
        }
        const id_value = parsed.value.object.get("id") orelse {
            if (self.acquireNotificationSink()) |sink| {
                sink.callback(sink.context, parsed.value);
                self.releaseNotificationSink();
            }
            return;
        };
        if (id_value != .integer or id_value.integer < 0) {
            return error.UnsupportedServerRequest;
        }
        if (!parsed.value.object.contains("result") and
            !parsed.value.object.contains("error"))
        {
            return error.UnsupportedServerRequest;
        }
        const request_id: u64 = @intCast(id_value.integer);

        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        const pending = self.pending.get(request_id) orelse {
            debug_trace.logf(
                "mcp",
                "ignored late HTTP+SSE response request_id={d}",
                .{request_id},
            );
            return;
        };
        if (pending.response != null or pending.failure != null) return;
        if (data.len > self.max_event_bytes.load(.monotonic)) {
            pending.failure = error.McpResponseFrameTooLarge;
            return;
        }
        pending.response = self.shared_allocator.dupe(u8, data) catch |err| {
            pending.failure = err;
            return;
        };
    }

    fn acquireNotificationSink(self: *Client) ?mcp_contract.NotificationSink {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        const sink = self.notification_sink orelse return null;
        if (self.notification_callback_active) return null;
        self.notification_callback_active = true;
        return sink;
    }

    fn releaseNotificationSink(self: *Client) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        self.notification_callback_active = false;
    }

    fn finishReader(self: *Client, failure: ?anyerror) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        defer self.state_mutex.unlock(io_mod.getIo());
        if (failure) |err| {
            if (self.state == .starting) self.startup_failure = err;
            self.reader_failure = err;
            self.state = .failed;
            self.failPendingLocked(err);
        } else {
            self.reader_failure = null;
            self.state = .stopped;
            self.failPendingLocked(error.McpConnectionClosed);
        }
    }
};

fn postMessageBounded(
    alloc: Allocator,
    client: *Client,
    body: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancellation: operation_control.CancellationSources,
    committed: *std.atomic.Value(bool),
    precommit: ?*mcp_contract.TransportPrecommit,
) !void {
    if (cancellation.cancelled()) return error.Cancelled;
    if (deadlineExpired(deadline)) return error.McpRequestTimedOut;

    const Operation = struct {
        alloc: Allocator,
        client: *Client,
        body: []const u8,
        committed: *std.atomic.Value(bool),
        precommit: ?*mcp_contract.TransportPrecommit,

        fn run(self: @This()) anyerror!void {
            try postMessageCore(
                self.alloc,
                self.client,
                self.body,
                self.committed,
                self.precommit,
            );
        }
    };
    const Event = union(enum) {
        post: anyerror!void,
        deadline: anyerror!void,
        cancelled: anyerror!void,
    };
    var select_buffer: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.deadline, waitForDeadline, .{deadline}) catch |err|
        return err;
    select.concurrent(.cancelled, waitForCancellation, .{cancellation}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.post, Operation.run, .{Operation{
        .alloc = alloc,
        .client = client,
        .body = body,
        .committed = committed,
        .precommit = precommit,
    }}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    const event = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    switch (event) {
        .post => |result| {
            select.cancelDiscard();
            if (cancellation.cancelled()) return error.Cancelled;
            if (deadlineExpired(deadline)) return error.McpRequestTimedOut;
            return result;
        },
        .cancelled => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            return error.Cancelled;
        },
        .deadline => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            if (cancellation.cancelled()) return error.Cancelled;
            return error.McpRequestTimedOut;
        },
    }
}

fn postMessageCore(
    alloc: Allocator,
    client: *Client,
    body: []const u8,
    committed: *std.atomic.Value(bool),
    precommit: ?*mcp_contract.TransportPrecommit,
) !void {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    try headers.append(alloc, .{
        .name = "Accept",
        .value = "application/json, text/event-stream",
    });
    for (client.static_headers) |header| {
        try headers.append(alloc, .{ .name = header.name, .value = header.value });
    }

    const uri = std.Uri.parse(client.endpoint.?) catch return error.InvalidEndpoint;
    var http_client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer http_client.deinit();
    var request = try http_client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = headers.items,
    });
    defer request.deinit();
    defer if (precommit) |guard| guard.release();
    if (precommit) |guard| try guard.acquire();
    try request.sendBodyComplete(@constCast(body));
    committed.store(true, .release);
    if (precommit) |guard| guard.release();
    var response = try request.receiveHead(&.{});
    if (response.head.status.class() == .redirect) return error.RedirectNotAllowed;
    const authenticate = try mcp_auth.collectAuthenticateHeader(
        alloc,
        response.head,
    );
    defer if (authenticate) |value| alloc.free(value);
    if (response.head.status == .unauthorized or
        (response.head.status == .forbidden and authenticate != null))
    {
        try client.rememberAuthChallenge(authenticate);
        return error.McpAuthenticationRequired;
    }
    if (response.head.status != .accepted) return error.UnexpectedHttpStatus;
}

fn resolveMessageEndpoint(
    alloc: Allocator,
    discovery_url: []const u8,
    endpoint_event: []const u8,
) ![]u8 {
    if (endpoint_event.len == 0 or endpoint_event.len > 8192) {
        return error.InvalidSseEndpointEvent;
    }
    const base = std.Uri.parse(discovery_url) catch return error.InvalidEndpoint;
    const extra_capacity = std.math.add(usize, endpoint_event.len, discovery_url.len) catch
        return error.InvalidSseEndpointEvent;
    var resolve_buffer = try alloc.alloc(u8, extra_capacity + 32);
    defer alloc.free(resolve_buffer);
    @memcpy(resolve_buffer[0..endpoint_event.len], endpoint_event);
    var unused = resolve_buffer;
    const resolved = base.resolveInPlace(endpoint_event.len, &unused) catch
        return error.InvalidSseEndpointEvent;
    if (!sameOrigin(base, resolved)) return error.CrossOriginSseEndpoint;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try resolved.format(&out.writer);
    const rendered = try out.toOwnedSlice();
    errdefer alloc.free(rendered);
    try streamable_http.validateEndpoint(rendered);
    return rendered;
}

fn sameOrigin(left: std.Uri, right: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(left.scheme, right.scheme)) return false;
    var left_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var right_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const left_host = (left.host orelse return false).toRaw(&left_host_buffer) catch
        return false;
    const right_host = (right.host orelse return false).toRaw(&right_host_buffer) catch
        return false;
    if (!std.ascii.eqlIgnoreCase(left_host, right_host)) return false;
    return effectivePort(left) == effectivePort(right);
}

fn effectivePort(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return null;
}

fn isEventStream(content_type: []const u8) bool {
    const separator = std.mem.findScalar(u8, content_type, ';') orelse
        content_type.len;
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, content_type[0..separator], " \t"),
        "text/event-stream",
    );
}

fn buildCancellation(
    alloc: Allocator,
    request_id: u64,
    reason: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":",
    );
    try out.writer.print("{d}", .{request_id});
    try out.writer.writeAll(",\"reason\":");
    try std.json.Stringify.value(reason, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn deadlineExpired(deadline: std.Io.Clock.Timestamp) bool {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

fn waitForStop(stop_flag: *std.atomic.Value(bool)) anyerror!void {
    while (!stop_flag.load(.acquire)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForCancellation(cancellation: operation_control.CancellationSources) anyerror!void {
    while (!cancellation.cancelled()) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

test "HTTP+SSE endpoint resolution stays same-origin" {
    const alloc = std.testing.allocator;
    const relative = try resolveMessageEndpoint(
        alloc,
        "https://example.test/events/sse",
        "../messages?session=one",
    );
    defer alloc.free(relative);
    try std.testing.expectEqualStrings(
        "https://example.test/messages?session=one",
        relative,
    );

    const absolute = try resolveMessageEndpoint(
        alloc,
        "http://127.0.0.1:4321/sse",
        "http://127.0.0.1:4321/messages",
    );
    defer alloc.free(absolute);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:4321/messages",
        absolute,
    );

    try std.testing.expectError(
        error.CrossOriginSseEndpoint,
        resolveMessageEndpoint(
            alloc,
            "https://example.test/sse",
            "https://other.test/messages",
        ),
    );
}

test "HTTP+SSE failed startup cleanup releases a discovered endpoint" {
    const allocator = std.testing.allocator;
    const client = try allocator.create(Client);
    client.* = .{
        .owner_allocator = allocator,
        .shared_allocator = allocator,
        .discovery_url = "https://example.test/sse",
        .static_headers = &.{},
        .endpoint = try allocator.dupe(u8, "https://example.test/messages"),
        .pending = std.AutoHashMap(u64, *Pending).init(allocator),
        .max_event_bytes = .init(1024),
    };

    client.destroyOwned();
}

test "HTTP+SSE cancellation payload is exact and escaped" {
    const body = try buildCancellation(
        std.testing.allocator,
        17,
        "user \"cancel\"",
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":17,\"reason\":\"user \\\"cancel\\\"\"}}",
        body,
    );
}

test "HTTP+SSE initialize response requires the 2024 protocol version" {
    const alloc = std.testing.allocator;
    try validateInitializeResponse(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}",
    );
    try std.testing.expectError(
        error.McpUnsupportedProtocolVersion,
        validateInitializeResponse(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        ),
    );
    try std.testing.expectError(
        error.McpUnsupportedProtocolVersion,
        validateInitializeResponse(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-03-26\"}}",
        ),
    );
}
