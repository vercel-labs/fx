const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const vercel_protocol = @import("vercel_protocol.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes = 1024 * 1024;
const cooperative_pulse_interval_ms = 50;

pub const Transport = struct {
    context: ?*anyopaque,
    open_fn: *const fn (?*anyopaque, []const u8, []const u8, []const u8, []const u8) anyerror!i32,
    status_fn: *const fn (?*anyopaque, i32, *u16) i32,
    next_fn: *const fn (?*anyopaque, i32, []u8) i32,
    close_fn: *const fn (?*anyopaque, i32) void,
    // Optional logical-completion signal, independent of HTTP EOF or close.
    consumed_fn: ?*const fn (?*anyopaque, i32) void = null,

    fn open(self: Transport, method: []const u8, url: []const u8, headers: []const u8, body: []const u8) !i32 {
        return self.open_fn(self.context, method, url, headers, body);
    }

    fn status(self: Transport, handle: i32, status_out: *u16) i32 {
        return self.status_fn(self.context, handle, status_out);
    }

    fn next(self: Transport, handle: i32, out: []u8) i32 {
        return self.next_fn(self.context, handle, out);
    }

    fn close(self: Transport, handle: i32) void {
        self.close_fn(self.context, handle);
    }

    fn consumed(self: Transport, handle: i32) void {
        if (self.consumed_fn) |notify| notify(self.context, handle);
    }
};

pub const ProviderContext = struct {
    build_fn: *const fn (Allocator, stream_provider.RequestData) anyerror![]u8,
    endpoint: Endpoint,
    transport: Transport,
};

pub const Endpoint = union(enum) {
    fixed: []const u8,
    resolve: *const fn () []const u8,

    fn url(self: Endpoint) []const u8 {
        return switch (self) {
            .fixed => |fixed| fixed,
            .resolve => |resolve| resolve(),
        };
    }
};

pub fn provider(context: *ProviderContext) stream_provider.Provider {
    return .{
        .context = context,
        .stream_fn = stream,
        .build_request_fn = buildRequest,
        .project_replay_fn = vercel_protocol.selectReplayParts,
    };
}

pub fn initContext(
    build_fn: *const fn (Allocator, stream_provider.RequestData) anyerror![]u8,
    endpoint: Endpoint,
    transport: Transport,
) ProviderContext {
    return .{ .build_fn = build_fn, .endpoint = endpoint, .transport = transport };
}

test "host provider selects replay without changing canonical input" {
    const Unused = struct {
        fn build(_: Allocator, _: stream_provider.RequestData) ![]u8 {
            return error.UnexpectedRequest;
        }
        fn open(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !i32 {
            return error.UnexpectedRequest;
        }
        fn status(_: ?*anyopaque, _: i32, _: *u16) i32 {
            return -1;
        }
        fn next(_: ?*anyopaque, _: i32, _: []u8) i32 {
            return -1;
        }
        fn close(_: ?*anyopaque, _: i32) void {}
    };
    const types = @import("../core/shared/types.zig");
    const alloc = std.testing.allocator;
    var context = initContext(Unused.build, .{ .fixed = "https://example.invalid" }, .{
        .context = null,
        .open_fn = Unused.open,
        .status_fn = Unused.status,
        .next_fn = Unused.next,
        .close_fn = Unused.close,
    });
    const adapter = provider(&context);
    const parts = "[{\"type\":\"reasoning\",\"text\":\"retained\"},{\"type\":\"tool-call\",\"toolCallId\":\"read\"},{\"type\":\"text\",\"offset\":0,\"length\":6}]";
    const replay = types.ProviderReplay{
        .source = .{ .provider = .gateway, .model = "fixture-model" },
        .parts_json = parts,
    };
    const calls = [_]types.ToolCall{.{ .id = "read", .name = "read_file", .arguments_json = "{}" }};
    const unchanged = (try adapter.projectReplay(alloc, replay, &calls, true, true)).?;
    try std.testing.expect(unchanged.parts_json.ptr == parts.ptr);

    const selected = (try adapter.projectReplay(alloc, replay, &calls, false, true)).?;
    defer alloc.free(selected.parts_json);
    try std.testing.expectEqualStrings("[{\"type\":\"reasoning\",\"text\":\"retained\"},{\"type\":\"tool-call\",\"toolCallId\":\"read\"}]", selected.parts_json);
    try std.testing.expectEqualStrings(parts, replay.parts_json);
    try std.testing.expect(selected.matches(replay.source));
    try std.testing.expectEqual(@as(?types.ProviderReplay, null), try adapter.projectReplay(alloc, replay, &.{}, false, false));
    try std.testing.expectEqual(@as(?types.ProviderReplay, null), try adapter.projectReplay(alloc, null, &.{}, true, true));
    try std.testing.expectError(error.InvalidProviderState, adapter.projectReplay(alloc, .{
        .source = replay.source,
        .parts_json = "{}",
    }, &.{}, false, true));
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    if (deadlineExpired(request.deadline)) return error.Timeout;
    const context: *ProviderContext = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const payload = request.prepared_request_body orelse
        try context.build_fn(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const auth = if (request.credential.secret()) |credential|
        try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential})
    else
        null;
    defer if (auth) |value| alloc.free(value);

    const Header = struct { name: []const u8, value: []const u8 };
    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(alloc);
    try headers.appendSlice(alloc, &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "HTTP-Referer", .value = "https://github.com/vercel-labs/fx" },
        .{ .name = "X-Title", .value = "fx" },
        .{ .name = "ai-gateway-protocol-version", .value = "0.0.1" },
        .{ .name = "ai-language-model-specification-version", .value = "4" },
        .{ .name = "ai-language-model-id", .value = request.model },
        .{ .name = "ai-language-model-streaming", .value = "true" },
    });
    if (auth) |value| try headers.append(alloc, .{ .name = "authorization", .value = value });
    if (request.credential.tenant()) |team| if (team.len > 0) try headers.append(alloc, .{ .name = "x-vercel-ai-gateway-team", .value = team });
    if (request.session_id) |session_id| if (session_id.len > 0) try headers.appendSlice(alloc, &.{
        .{ .name = "x-session-id", .value = session_id },
        .{ .name = "x-session-affinity", .value = session_id },
    });

    var headers_json: std.Io.Writer.Allocating = .init(alloc);
    defer headers_json.deinit();
    try std.json.Stringify.value(headers.items, .{}, &headers_json.writer);

    const endpoint = context.endpoint.url();
    try request.admission.admit();
    request.delivery.markPossiblySent();
    const handle = try transport.open("POST", endpoint, headers_json.writer.buffered(), payload);
    if (handle < 0) return error.HostStreamFailed;
    defer transport.close(handle);

    var status_code: u16 = 0;
    while (true) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (deadlineExpired(request.deadline)) return error.Timeout;
        const status_result = transport.status(handle, &status_code);
        if (status_result == 1) break;
        if (status_result == -2) return error.Cancelled;
        if (status_result < 0) return error.HostStreamFailed;
        try pulse(request.cooperative_pulse);
    }

    const status: std.http.Status = @enumFromInt(status_code);
    if (status != .ok) return .{ .failed = .{
        .kind = failureKind(status),
        .detail = try readBody(
            alloc,
            transport,
            handle,
            request.cancel_flag,
            request.deadline,
            request.cooperative_pulse,
        ),
        .ownership = .owned,
    } };

    var reader: HostStreamReader = undefined;
    reader.init(
        transport,
        handle,
        request.cancel_flag,
        request.deadline,
        request.cooperative_pulse,
    );
    var events = request.events;
    const completion = gateway_client.consumeGatewaySseStream(
        alloc,
        &reader.interface,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        request.cancel_flag,
        request.content_capture_limit,
        request.gateway_events,
    ) catch |err| switch (err) {
        error.ReadFailed => return if (reader.timed_out)
            error.Timeout
        else if (request.cancel_flag.load(.seq_cst) or reader.aborted)
            error.Cancelled
        else
            error.HostStreamFailed,
        else => return err,
    };
    const types = @import("../core/shared/types.zig");
    if (transport.consumed_fn != null and
        !request.cancel_flag.load(.seq_cst) and
        types.classifyProviderCompletion(completion) == .completed and
        types.authoritativeToolAdmission(completion) == .admitted and
        completion.provider_failure_cause == null)
    {
        transport.consumed(handle);
    }
    return .{ .completed = .{
        .completion = completion,
        .ownership = .owned,
    } };
}

test "host provider signals logical consumption only after valid uncancelled completion" {
    const FakeTransport = struct {
        body: []const u8,
        status_code: u16 = 200,
        offset: usize = 0,
        read_error: ?i32 = null,
        cancel_on_content: bool = false,
        cancel_flag: std.atomic.Value(bool) = .init(false),
        consumed_calls: usize = 0,
        consumed_handle: ?i32 = null,
        consumed_after_close: bool = false,
        eof_calls: usize = 0,
        close_calls: usize = 0,
        content_calls: usize = 0,
        content_calls_at_consumption: usize = 0,

        fn build(_: Allocator, _: stream_provider.RequestData) ![]u8 {
            return error.UnexpectedRequest;
        }
        fn open(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !i32 {
            return 7;
        }
        fn status(raw: ?*anyopaque, _: i32, status_out: *u16) i32 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            status_out.* = self.status_code;
            return 1;
        }
        fn next(raw: ?*anyopaque, _: i32, out: []u8) i32 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const len = @min(out.len, self.body.len - self.offset);
            if (len == 0) {
                if (self.read_error) |err| return err;
                self.eof_calls += 1;
                return 0;
            }
            @memcpy(out[0..len], self.body[self.offset..][0..len]);
            self.offset += len;
            return @intCast(len);
        }
        fn close(raw: ?*anyopaque, _: i32) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.close_calls += 1;
        }
        fn consumed(raw: ?*anyopaque, handle: i32) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.consumed_calls += 1;
            self.consumed_handle = handle;
            self.consumed_after_close = self.close_calls != 0;
            self.content_calls_at_consumption = self.content_calls;
        }
        fn emit(raw: *anyopaque, event: stream_provider.Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (event == .content_delta) {
                self.content_calls += 1;
                if (self.cancel_on_content) self.cancel_flag.store(true, .seq_cst);
            }
        }
        fn admit(_: *anyopaque) !void {}
    };
    const text = "data: {\"type\":\"text-delta\",\"id\":\"t\",\"delta\":\"answer\"}\n\n";
    const stop = "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n";
    const cases = [_]struct {
        body: []const u8,
        status: u16 = 200,
        read_error: ?i32 = null,
        cancel_on_content: bool = false,
        optional_callback: bool = true,
        expected_consumed: bool = false,
        expected_error: ?anyerror = null,
    }{
        .{ .body = text ++ stop, .expected_consumed = true },
        .{ .body = "data: {\"type\":\"tool-call\",\"toolCallId\":\"c\",\"toolName\":\"test_tool\",\"input\":{}}\n\n" ++
            "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\"}}\n\n", .expected_consumed = true },
        .{ .body = text ++ "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"other\"}}\n\n", .expected_consumed = true },
        .{ .body = text ++ stop, .optional_callback = false },
        .{ .body = text },
        .{ .body = "data: [DONE]\n\n" },
        .{ .body = text ++ "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"error\"}}\n\n" },
        .{ .body = text ++ "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"content-filter\"}}\n\n" },
        .{ .body = text ++ "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"length\"}}\n\n" },
        .{ .body = "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\"}}\n\n" },
        .{ .body = text ++ "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"},\"code\":\"gateway_stream_timeout\"}\n\n" },
        .{ .body = "data: {\"type\":\"tool-call\",\"toolCallId\":\"\",\"toolName\":\"test_tool\",\"input\":{}}\n\n" ++
            "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\"}}\n\n" },
        .{ .body = text ++ stop, .cancel_on_content = true },
        .{ .body = "upstream failure", .status = 500 },
        .{ .body = text, .read_error = -1, .expected_error = error.HostStreamFailed },
        .{ .body = "data: {not-json}\n\n", .expected_error = error.InvalidGatewaySseEvent },
    };
    for (cases, 0..) |case, index| {
        var fake: FakeTransport = .{
            .body = case.body,
            .status_code = case.status,
            .read_error = case.read_error,
            .cancel_on_content = case.cancel_on_content,
        };
        errdefer std.debug.print("host consumption case={d} consumed={d} eof={d} closed={d}\n", .{ index, fake.consumed_calls, fake.eof_calls, fake.close_calls });
        var context = initContext(FakeTransport.build, .{ .fixed = "https://example.invalid" }, .{
            .context = &fake,
            .open_fn = FakeTransport.open,
            .status_fn = FakeTransport.status,
            .next_fn = FakeTransport.next,
            .close_fn = FakeTransport.close,
            .consumed_fn = if (case.optional_callback) FakeTransport.consumed else null,
        });
        var delivery: stream_provider.DeliveryCertainty = .init();
        var attempt: stream_provider.AttemptEvidence = .{};
        const result = stream(&context, std.testing.allocator, .{
            .credential = .host_managed,
            .model = "fixture-model",
            .retry_count = 0,
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
            .prepared_request_body = "{}",
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &attempt,
            .events = .{ .context = &fake, .emit_fn = FakeTransport.emit },
            .admission = .{ .context = &fake, .admit_fn = FakeTransport.admit },
            .cancel_flag = &fake.cancel_flag,
        });
        if (case.expected_error) |expected| {
            try std.testing.expectError(expected, result);
        } else {
            var owned = try result;
            defer owned.deinit(std.testing.allocator);
        }
        try std.testing.expectEqual(@as(usize, @intFromBool(case.expected_consumed)), fake.consumed_calls);
        try std.testing.expectEqual(if (case.expected_consumed) @as(?i32, 7) else null, fake.consumed_handle);
        try std.testing.expect(!fake.consumed_after_close);
        try std.testing.expectEqual(@as(usize, 1), fake.close_calls);
        if (case.expected_consumed) {
            try std.testing.expectEqual(fake.content_calls, fake.content_calls_at_consumption);
            try std.testing.expectEqual(@as(usize, 0), fake.eof_calls);
        }
    }
}

fn buildRequest(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.RequestData,
) anyerror![]u8 {
    const context: *ProviderContext = @ptrCast(@alignCast(raw.?));
    return context.build_fn(alloc, request);
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

fn pulse(value: ?stream_provider.CooperativePulse) !void {
    if (value) |callback| try callback.pulse();
}

fn deadlineExpired(deadline: ?std.Io.Clock.Timestamp) bool {
    const value = deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, value);
}

fn readBody(
    alloc: Allocator,
    transport: Transport,
    handle: i32,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    cooperative_pulse: ?stream_provider.CooperativePulse,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (deadlineExpired(deadline)) return error.Timeout;
        const count = transport.next(handle, &chunk);
        if (count == -3) {
            try pulse(cooperative_pulse);
            continue;
        }
        if (count == -2) return error.Cancelled;
        if (count < 0) return error.HostStreamFailed;
        if (count == 0) break;
        const len: usize = @intCast(count);
        if (len > max_error_body_bytes - out.items.len) return error.HostStreamFailed;
        try out.appendSlice(alloc, chunk[0..len]);
    }
    return out.toOwnedSlice(alloc);
}

const HostStreamReader = struct {
    transport: Transport = undefined,
    handle: i32 = -1,
    cancel_flag: *std.atomic.Value(bool) = undefined,
    deadline: ?std.Io.Clock.Timestamp = null,
    cooperative_pulse: ?stream_provider.CooperativePulse = null,
    last_cooperative_pulse: ?std.Io.Clock.Timestamp = null,
    aborted: bool = false,
    timed_out: bool = false,
    buffer: [16 * 1024]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(
        self: *@This(),
        transport: Transport,
        handle: i32,
        cancel_flag: *std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
        cooperative_pulse: ?stream_provider.CooperativePulse,
    ) void {
        self.* = .{
            .transport = transport,
            .handle = handle,
            .cancel_flag = cancel_flag,
            .deadline = deadline,
            .cooperative_pulse = cooperative_pulse,
            .last_cooperative_pulse = if (cooperative_pulse != null)
                std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)
            else
                null,
        };
        self.interface = .{ .vtable = &.{ .stream = streamReader, .readVec = readVec }, .buffer = &self.buffer, .seek = 0, .end = 0 };
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
        if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
        for (data) |dest| if (dest.len > 0) return self.readHost(dest);
        const dest = reader.buffer[reader.end..];
        if (dest.len == 0) return 0;
        const count = try self.readHost(dest);
        reader.end += count;
        return 0;
    }

    fn abortRead(self: *@This()) std.Io.Reader.Error {
        self.aborted = true;
        return error.ReadFailed;
    }

    fn abortDeadline(self: *@This()) std.Io.Reader.Error {
        self.timed_out = true;
        return error.ReadFailed;
    }

    fn pulseAt(self: *@This(), now: std.Io.Clock.Timestamp) !void {
        if (self.cooperative_pulse == null) return;
        self.last_cooperative_pulse = now;
        try pulse(self.cooperative_pulse);
    }

    fn pulseIfDueAt(self: *@This(), now: std.Io.Clock.Timestamp) !void {
        if (self.cooperative_pulse == null) return;
        const last_pulse = self.last_cooperative_pulse orelse return;
        const elapsed_ms = last_pulse.durationTo(now).raw.toMilliseconds();
        if (elapsed_ms < cooperative_pulse_interval_ms) return;
        try self.pulseAt(now);
    }

    fn readHost(self: *@This(), dest: []u8) std.Io.Reader.Error!usize {
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
            if (deadlineExpired(self.deadline)) return self.abortDeadline();
            if (self.cooperative_pulse != null) {
                self.pulseIfDueAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)) catch return error.ReadFailed;
            }
            if (self.cancel_flag.load(.seq_cst)) return self.abortRead();
            const count = self.transport.next(self.handle, dest);
            if (count == -3) {
                if (self.cooperative_pulse != null) {
                    self.pulseAt(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)) catch return error.ReadFailed;
                }
                continue;
            }
            if (count == -2) return self.abortRead();
            if (count < 0) return error.ReadFailed;
            if (count == 0) return error.EndOfStream;
            return @intCast(count);
        }
    }

    fn streamReader(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const count = readVec(reader, &data) catch |err| return err;
        writer.advance(count);
        return count;
    }
};

test "error response bodies are bounded" {
    const FakeTransport = struct {
        body: []const u8,
        offset: usize = 0,

        fn open(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!i32 {
            return 1;
        }

        fn status(_: ?*anyopaque, _: i32, status_out: *u16) i32 {
            status_out.* = 500;
            return 1;
        }

        fn next(raw: ?*anyopaque, _: i32, out: []u8) i32 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const len = @min(out.len, self.body.len - self.offset);
            if (len == 0) return 0;
            @memcpy(out[0..len], self.body[self.offset..][0..len]);
            self.offset += len;
            return @intCast(len);
        }

        fn close(_: ?*anyopaque, _: i32) void {}
    };

    const body = try std.testing.allocator.alloc(u8, max_error_body_bytes + 1);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');
    var fake = FakeTransport{ .body = body };
    const transport = Transport{
        .context = &fake,
        .open_fn = FakeTransport.open,
        .status_fn = FakeTransport.status,
        .next_fn = FakeTransport.next,
        .close_fn = FakeTransport.close,
    };
    var cancel_flag = std.atomic.Value(bool).init(false);

    try std.testing.expectError(
        error.HostStreamFailed,
        readBody(std.testing.allocator, transport, 1, &cancel_flag, null, null),
    );
}

test "host stream reader omits pulse timing state without callback" {
    const FakeTransport = struct {
        fn open(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!i32 {
            return 1;
        }

        fn status(_: ?*anyopaque, _: i32, _: *u16) i32 {
            return 1;
        }

        fn next(_: ?*anyopaque, _: i32, _: []u8) i32 {
            return 0;
        }

        fn close(_: ?*anyopaque, _: i32) void {}
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    var reader: HostStreamReader = undefined;
    reader.init(.{
        .context = null,
        .open_fn = FakeTransport.open,
        .status_fn = FakeTransport.status,
        .next_fn = FakeTransport.next,
        .close_fn = FakeTransport.close,
    }, 1, &cancel_flag, null, null);

    try std.testing.expect(reader.last_cooperative_pulse == null);
}

test "host stream reader stops at its provider deadline" {
    const FakeTransport = struct {
        fn open(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!i32 {
            return 1;
        }
        fn status(_: ?*anyopaque, _: i32, _: *u16) i32 {
            return 0;
        }
        fn next(_: ?*anyopaque, _: i32, _: []u8) i32 {
            return -3;
        }
        fn close(_: ?*anyopaque, _: i32) void {}
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    var reader: HostStreamReader = undefined;
    reader.init(.{
        .context = null,
        .open_fn = FakeTransport.open,
        .status_fn = FakeTransport.status,
        .next_fn = FakeTransport.next,
        .close_fn = FakeTransport.close,
    }, 1, &cancel_flag, std.Io.Clock.Timestamp.now(std.testing.io, .awake), null);
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, reader.readHost(&buffer));
    try std.testing.expect(reader.timed_out);
}

test "host stream reader throttles cooperative pulses" {
    const PulseTrace = struct {
        calls: usize = 0,

        fn run(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    const awake_timestamp = struct {
        fn at(milliseconds: i64) std.Io.Clock.Timestamp {
            return .{
                .clock = .awake,
                .raw = .fromNanoseconds(@as(i96, milliseconds) * std.time.ns_per_ms),
            };
        }
    }.at;

    var trace: PulseTrace = .{};
    var reader: HostStreamReader = .{
        .cooperative_pulse = .{ .ctx = &trace, .run = PulseTrace.run },
        .last_cooperative_pulse = awake_timestamp(100),
    };

    try reader.pulseIfDueAt(awake_timestamp(149));
    try std.testing.expectEqual(@as(usize, 0), trace.calls);
    try reader.pulseIfDueAt(awake_timestamp(150));
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try reader.pulseIfDueAt(awake_timestamp(199));
    try std.testing.expectEqual(@as(usize, 1), trace.calls);
    try reader.pulseIfDueAt(awake_timestamp(200));
    try std.testing.expectEqual(@as(usize, 2), trace.calls);
}
