const std = @import("std");
const gateway_json = @import("../core/gateway/gateway_json.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const openai_transport = @import("../core/gateway/openai_transport.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const StreamCallback = gateway_client.StreamCallback;
const ToolStartCallback = gateway_client.ToolStartCallback;
const StreamResult = gateway_client.StreamResult;
const DeliveryCertainty = gateway_client.DeliveryCertainty;

pub const user_agent = gateway_client.user_agent;
const max_sse_event_line_bytes: usize = 4 * 1024 * 1024;

pub const StreamRequest = struct {
    api_key: []const u8,
    model: []const u8,
    retry_count: usize,
    responses_url: []const u8,
    payload: []const u8,
    trace_ctx: debug_trace.TraceContext = .{},
    content_capture_limit: ?usize = null,
    delivery: ?*DeliveryCertainty = null,
    on_tool_input_chunk: ?StreamCallback = null,
    provider_attempt_owner: gateway_client.ProviderAttemptOwner = .transport,
};

const TypedSseEvent = struct {
    event_type: ?[]const u8 = null,
    data: ?[]const u8 = null,
};

const TypedSseEventReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    event_type_buf: std.ArrayList(u8) = .empty,
    data_buf: std.ArrayList(u8) = .empty,
    max_line_bytes: usize,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.pending_line.deinit(alloc);
        self.event_type_buf.deinit(alloc);
        self.data_buf.deinit(alloc);
    }

    fn resetEvent(self: *@This()) void {
        self.event_type_buf.clearRetainingCapacity();
        self.data_buf.clearRetainingCapacity();
    }

    fn releaseLine(self: *@This()) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn storeEventType(self: *@This(), alloc: Allocator, value: []const u8) !void {
        self.event_type_buf.clearRetainingCapacity();
        try self.event_type_buf.appendSlice(alloc, value);
    }

    fn storeData(self: *@This(), alloc: Allocator, value: []const u8) !void {
        self.data_buf.clearRetainingCapacity();
        try self.data_buf.appendSlice(alloc, value);
    }

    fn currentEvent(self: *const @This()) ?TypedSseEvent {
        if (self.event_type_buf.items.len == 0 and self.data_buf.items.len == 0) return null;
        return .{
            .event_type = if (self.event_type_buf.items.len > 0) self.event_type_buf.items else null,
            .data = if (self.data_buf.items.len > 0) self.data_buf.items else null,
        };
    }

    fn finishEvent(self: *@This(), alloc: Allocator) !?TypedSseEvent {
        const event = self.currentEvent() orelse return null;
        var owned: TypedSseEvent = .{};
        if (event.event_type) |value| owned.event_type = try alloc.dupe(u8, value);
        if (event.data) |value| owned.data = try alloc.dupe(u8, value);
        self.resetEvent();
        return owned;
    }

    fn next(self: *@This(), alloc: Allocator, reader: anytype) !?TypedSseEvent {
        while (true) {
            const line = switch (try self.readLine(alloc, reader)) {
                .line => |value| value,
                .read_failed => return error.ReadFailed,
                .eof => return try self.finishEvent(alloc),
            };

            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) {
                if (try self.finishEvent(alloc)) |event| return event;
                continue;
            }
            if (trimmed[0] == ':') continue;

            const event_prefix = "event: ";
            if (std.mem.startsWith(u8, trimmed, event_prefix)) {
                try self.storeEventType(alloc, trimmed[event_prefix.len..]);
                self.releaseLine();
                continue;
            }

            const data_prefix = "data: ";
            if (std.mem.startsWith(u8, trimmed, data_prefix)) {
                try self.storeData(alloc, trimmed[data_prefix.len..]);
                self.releaseLine();
                continue;
            }
        }
    }

    fn readLine(self: *@This(), alloc: Allocator, reader: anytype) !union(enum) {
        line: []const u8,
        read_failed,
        eof,
    } {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.GatewaySseReadStalled;
                    if (buffered.len > self.max_line_bytes - self.pending_line.items.len) {
                        return error.GatewaySseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return .read_failed,
            } orelse {
                if (self.pending_line.items.len > 0) return .{ .line = self.pending_line.items };
                return .eof;
            };

            if (fragment.len > self.max_line_bytes - self.pending_line.items.len) {
                return error.GatewaySseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return .{ .line = fragment };
            try self.pending_line.appendSlice(alloc, fragment);
            return .{ .line = self.pending_line.items };
        }
    }
};

const StreamedToolCall = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

fn dupeStreamedToolCall(alloc: Allocator, tool: StreamedToolCall) !types.ToolCall {
    const args = if (tool.arguments.items.len == 0) "{}" else tool.arguments.items;
    if (try types.ToolArgumentIntegrity.classifySerialized(alloc, args) == .malformed_json) {
        return error.InvalidGatewayResponse;
    }
    const id = try alloc.dupe(u8, tool.id.items);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, tool.name.items);
    errdefer alloc.free(name);
    const arguments_json = try alloc.dupe(u8, args);
    errdefer alloc.free(arguments_json);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
    };
}

pub fn streamOpenAiResponsesCompletion(
    alloc: Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const retry_count = switch (request.provider_attempt_owner) {
        .agent => 1,
        .transport => request.retry_count,
    };

    const request_url = selectE2eResponsesUrl(
        io_mod.getenv(openai_transport.e2e_openai_responses_url_env),
        request.responses_url,
    );
    const uri = try std.Uri.parse(request_url);

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer alloc.free(auth_header);

    var attempt: usize = 0;
    while (attempt < retry_count) : (attempt += 1) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        var req = client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = user_agent },
            },
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) catch |err| {
            if (attempt + 1 < retry_count and gateway_client.isRetryableGatewayError(err)) {
                try sleepRetry((attempt + 1) * 150 * std.time.ns_per_ms, cancel_flag);
                continue;
            }
            return err;
        };
        defer req.deinit();

        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        req.transfer_encoding = .{ .content_length = request.payload.len };
        var send_buf: [8192]u8 = undefined;
        var body_writer = req.sendBodyUnflushed(&send_buf) catch return error.WriteFailed;
        body_writer.writer.writeAll(request.payload) catch return error.WriteFailed;
        body_writer.end() catch return error.WriteFailed;
        req.connection.?.flush() catch return error.WriteFailed;
        if (request.delivery) |delivery| delivery.markPossiblySent();

        var response = req.receiveHead(&.{}) catch |err| {
            if (attempt + 1 < retry_count and gateway_client.isRetryableGatewayError(err)) {
                try sleepRetry((attempt + 1) * 150 * std.time.ns_per_ms, cancel_flag);
                continue;
            }
            return err;
        };

        if (response.head.status != .ok) {
            const err_body = try readResponseBody(alloc, &response);
            return .{
                .status = response.head.status,
                .err_body = err_body,
            };
        }

        return consumeResponsesSseStream(
            alloc,
            &response,
            callback_ctx,
            on_content_chunk,
            on_tool_start,
            request.on_tool_input_chunk,
            cancel_flag,
            request.content_capture_limit,
        );
    }

    return error.ConnectionTimedOut;
}

fn selectE2eResponsesUrl(override_url: ?[]const u8, default_url: []const u8) []const u8 {
    const override = override_url orelse return default_url;
    if (!gateway_client.isLoopbackHttpUrl(override)) return default_url;
    return override;
}

fn sleepRetry(ns: u64, cancel_flag: *std.atomic.Value(bool)) !void {
    const step = 50 * std.time.ns_per_ms;
    var waited: u64 = 0;
    while (waited < ns) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        io_mod.sleep(step);
        waited += step;
    }
}

fn readResponseBody(alloc: Allocator, response: *std.http.Client.Response) ![]u8 {
    var err_out: std.Io.Writer.Allocating = .init(alloc);
    defer err_out.deinit();
    var err_buf: [4096]u8 = undefined;
    const err_reader = response.reader(&err_buf);
    _ = err_reader.streamRemaining(&err_out.writer) catch {};
    return err_out.toOwnedSlice() catch try alloc.dupe(u8, "");
}

fn consumeResponsesSseStream(
    alloc: Allocator,
    response: *std.http.Client.Response,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_tool_input_chunk: ?StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !StreamResult {
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(alloc);

    var streamed_tools: std.ArrayList(StreamedToolCall) = .empty;
    defer {
        for (streamed_tools.items) |*tool| tool.deinit(alloc);
        streamed_tools.deinit(alloc);
    }

    var finish_reason: ?types.ProviderFinishReason = null;

    var reader_buffer: [8192]u8 = undefined;
    const reader = response.reader(&reader_buffer);

    var event_reader = TypedSseEventReader{ .max_line_bytes = max_sse_event_line_bytes };
    defer event_reader.deinit(alloc);

    while (try event_reader.next(alloc, reader)) |event| {
        defer {
            if (event.event_type) |value| alloc.free(value);
            if (event.data) |value| alloc.free(value);
        }
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (event.data == null) continue;
        try handleResponsesEvent(
            alloc,
            event.event_type,
            event.data.?,
            &content_buf,
            &streamed_tools,
            &finish_reason,
            callback_ctx,
            on_content_chunk,
            on_tool_start,
            on_tool_input_chunk,
            content_capture_limit,
        );
    }

    if (finish_reason == null) {
        if (streamed_tools.items.len > 0) {
            finish_reason = .tool_calls;
        } else if (content_buf.items.len > 0) {
            finish_reason = .stop;
        }
    }

    var completion: types.GatewayCompletion = .{};
    errdefer gateway_json.freeGatewayCompletion(alloc, completion);
    if (content_buf.items.len > 0) {
        completion.content = try alloc.dupe(u8, content_buf.items);
    }
    if (finish_reason) |reason| completion.finish_reason = reason;

    if (streamed_tools.items.len > 0) {
        const buffer = try alloc.alloc(types.ToolCall, streamed_tools.items.len);
        errdefer alloc.free(buffer);
        var count: usize = 0;
        errdefer {
            for (buffer[0..count]) |call| {
                alloc.free(call.id);
                alloc.free(call.name);
                alloc.free(call.arguments_json);
            }
        }
        for (streamed_tools.items) |tool| {
            if (tool.id.items.len == 0 or tool.name.items.len == 0) continue;
            buffer[count] = try dupeStreamedToolCall(alloc, tool);
            count += 1;
        }
        if (count > 0) {
            completion.tool_calls = try alloc.dupe(types.ToolCall, buffer[0..count]);
        }
        alloc.free(buffer);
    }

    return .{ .status = .ok, .completion = completion };
}

fn eventTypeFromPayload(event_type: ?[]const u8, parsed: std.json.Value) []const u8 {
    if (parsed == .object) {
        if (parsed.object.get("type")) |type_value| {
            if (type_value == .string and type_value.string.len > 0) return type_value.string;
        }
    }
    if (event_type) |value| return value;
    return "";
}

fn ensureToolIndex(
    alloc: Allocator,
    streamed_tools: *std.ArrayList(StreamedToolCall),
    output_index: usize,
) !*StreamedToolCall {
    if (output_index > openai_transport.max_streamed_tool_index) return error.InvalidGatewayResponse;
    while (streamed_tools.items.len <= output_index) {
        try streamed_tools.append(alloc, .{});
    }
    return &streamed_tools.items[output_index];
}

fn validatedStreamedToolIndex(index_value: std.json.Value) ?usize {
    if (index_value != .integer) return null;
    if (index_value.integer < 0) return null;
    const index = std.math.cast(usize, index_value.integer) orelse return null;
    if (index > openai_transport.max_streamed_tool_index) return null;
    return index;
}

fn announceToolIfReady(
    record: *StreamedToolCall,
    callback_ctx: *anyopaque,
    on_tool_start: ?ToolStartCallback,
) void {
    if (record.announced or record.id.items.len == 0 or record.name.items.len == 0) return;
    record.announced = true;
    if (on_tool_start) |callback| {
        callback(callback_ctx, record.id.items, record.name.items, null);
    }
}

fn handleResponsesEvent(
    alloc: Allocator,
    event_type: ?[]const u8,
    json_text: []const u8,
    content_buf: *std.ArrayList(u8),
    streamed_tools: *std.ArrayList(StreamedToolCall),
    finish_reason: *?types.ProviderFinishReason,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_tool_input_chunk: ?StreamCallback,
    content_capture_limit: ?usize,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const event_name = eventTypeFromPayload(event_type, parsed.value);
    if (event_name.len == 0) return;

    if (std.mem.eql(u8, event_name, "response.output_text.delta")) {
        const delta_value = parsed.value.object.get("delta") orelse return;
        if (delta_value != .string or delta_value.string.len == 0) return;
        const retained = if (content_capture_limit) |limit|
            delta_value.string[0..@min(delta_value.string.len, limit -| content_buf.items.len)]
        else
            delta_value.string;
        try content_buf.appendSlice(alloc, retained);
        on_content_chunk(callback_ctx, delta_value.string);
        return;
    }

    if (std.mem.eql(u8, event_name, "response.output_item.added") or
        std.mem.eql(u8, event_name, "response.output_item.done"))
    {
        const item = parsed.value.object.get("item") orelse return;
        if (item != .object) return;
        const item_type = item.object.get("type") orelse return;
        if (item_type != .string or !std.mem.eql(u8, item_type.string, "function_call")) return;
        const output_index_value = parsed.value.object.get("output_index") orelse return;
        const output_index = validatedStreamedToolIndex(output_index_value) orelse return error.InvalidGatewayResponse;
        const record = try ensureToolIndex(alloc, streamed_tools, output_index);
        if (item.object.get("call_id")) |call_id| {
            if (call_id == .string and call_id.string.len > 0) {
                record.id.clearRetainingCapacity();
                try record.id.appendSlice(alloc, call_id.string);
            }
        }
        if (item.object.get("name")) |name| {
            if (name == .string and name.string.len > 0) {
                record.name.clearRetainingCapacity();
                try record.name.appendSlice(alloc, name.string);
            }
        }
        if (item.object.get("arguments")) |args| {
            if (args == .string and args.string.len > 0) {
                record.arguments.clearRetainingCapacity();
                try record.arguments.appendSlice(alloc, args.string);
            }
        }
        announceToolIfReady(record, callback_ctx, on_tool_start);
        return;
    }

    if (std.mem.eql(u8, event_name, "response.function_call_arguments.delta")) {
        const output_index_value = parsed.value.object.get("output_index") orelse return;
        const output_index = validatedStreamedToolIndex(output_index_value) orelse return error.InvalidGatewayResponse;
        const delta_value = parsed.value.object.get("delta") orelse return;
        if (delta_value != .string or delta_value.string.len == 0) return;
        const record = try ensureToolIndex(alloc, streamed_tools, output_index);
        try record.arguments.appendSlice(alloc, delta_value.string);
        if (on_tool_input_chunk) |callback| callback(callback_ctx, delta_value.string);
        return;
    }

    if (std.mem.eql(u8, event_name, "response.function_call_arguments.done")) {
        const output_index_value = parsed.value.object.get("output_index") orelse return;
        const output_index = validatedStreamedToolIndex(output_index_value) orelse return error.InvalidGatewayResponse;
        const record = try ensureToolIndex(alloc, streamed_tools, output_index);
        if (parsed.value.object.get("name")) |name| {
            if (name == .string and name.string.len > 0) {
                record.name.clearRetainingCapacity();
                try record.name.appendSlice(alloc, name.string);
            }
        }
        if (parsed.value.object.get("arguments")) |args| {
            if (args == .string) {
                record.arguments.clearRetainingCapacity();
                try record.arguments.appendSlice(alloc, args.string);
            }
        }
        announceToolIfReady(record, callback_ctx, on_tool_start);
        return;
    }

    if (std.mem.eql(u8, event_name, "response.completed")) {
        finish_reason.* = .stop;
        if (streamed_tools.items.len > 0) finish_reason.* = .tool_calls;
        return;
    }

    if (std.mem.eql(u8, event_name, "response.incomplete")) {
        finish_reason.* = .length;
        return;
    }

    if (std.mem.eql(u8, event_name, "response.failed") or std.mem.eql(u8, event_name, "error")) {
        finish_reason.* = .provider_error;
    }
}

test "handleResponsesEvent accumulates text and tool call fragments" {
    const alloc = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var tools: std.ArrayList(StreamedToolCall) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var finish: ?types.ProviderFinishReason = null;
    var announced: usize = 0;

    try handleResponsesEvent(
        alloc,
        "response.output_text.delta",
        "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}",
        &content,
        &tools,
        &finish,
        @ptrCast(&announced),
        discardChunk,
        toolStartCounter,
        discardChunk,
        null,
    );
    try handleResponsesEvent(
        alloc,
        "response.output_item.added",
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read_file","arguments":""}}
    ,
        &content,
        &tools,
        &finish,
        @ptrCast(&announced),
        discardChunk,
        toolStartCounter,
        discardChunk,
        null,
    );
    try handleResponsesEvent(
        alloc,
        "response.output_item.done",
        \\{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"/tmp\"}"}}
    ,
        &content,
        &tools,
        &finish,
        @ptrCast(&announced),
        discardChunk,
        toolStartCounter,
        discardChunk,
        null,
    );
    try handleResponsesEvent(
        alloc,
        "response.function_call_arguments.delta",
        "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"path\"}",
        &content,
        &tools,
        &finish,
        @ptrCast(&announced),
        discardChunk,
        toolStartCounter,
        discardChunk,
        null,
    );
    try handleResponsesEvent(
        alloc,
        "response.function_call_arguments.done",
        \\{"type":"response.function_call_arguments.done","output_index":0,"name":"read_file","arguments":"{\"path\":\"/tmp\"}"}
    ,
        &content,
        &tools,
        &finish,
        @ptrCast(&announced),
        discardChunk,
        toolStartCounter,
        discardChunk,
        null,
    );

    try std.testing.expectEqualStrings("hello", content.items);
    try std.testing.expectEqual(@as(usize, 1), announced);
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("call_1", tools.items[0].id.items);
    try std.testing.expectEqualStrings("read_file", tools.items[0].name.items);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", tools.items[0].arguments.items);
}

fn discardChunk(_: *anyopaque, _: []const u8) void {}

fn toolStartCounter(ctx: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) void {
    const slot: *usize = @ptrCast(@alignCast(ctx));
    slot.* += 1;
}

test "TypedSseEventReader preserves large data payloads across events" {
    const alloc = std.testing.allocator;
    const large_delta = try alloc.alloc(u8, 9000);
    defer alloc.free(large_delta);
    @memset(large_delta, 'a');
    const data_line = try std.fmt.allocPrint(
        alloc,
        "data: {{\"type\":\"response.output_text.delta\",\"delta\":\"{s}\"}}",
        .{large_delta},
    );
    defer alloc.free(data_line);

    const LineReader = struct {
        lines: []const []const u8,
        index: usize = 0,

        pub fn takeDelimiter(self: *@This(), delimiter: u8) error{ StreamTooLong, ReadFailed }!?[]const u8 {
            _ = delimiter;
            if (self.index >= self.lines.len) return null;
            const line = self.lines[self.index];
            self.index += 1;
            return line;
        }

        pub fn buffered(_: *@This()) []const u8 {
            return "";
        }

        pub fn tossBuffered(_: *@This()) void {}
    };

    const lines = [_][]const u8{
        "event: response.output_text.delta",
        data_line,
        "",
        "event: response.completed",
        "data: {\"type\":\"response.completed\"}",
        "",
    };
    var reader = LineReader{ .lines = lines[0..] };
    var event_reader = TypedSseEventReader{ .max_line_bytes = max_sse_event_line_bytes };
    defer event_reader.deinit(alloc);

    const first = (try event_reader.next(alloc, &reader)).?;
    defer {
        if (first.event_type) |value| alloc.free(value);
        if (first.data) |value| alloc.free(value);
    }
    try std.testing.expectEqualStrings("response.output_text.delta", first.event_type.?);
    try std.testing.expect(first.data.?.len > large_delta.len);

    const second = (try event_reader.next(alloc, &reader)).?;
    defer {
        if (second.event_type) |value| alloc.free(value);
        if (second.data) |value| alloc.free(value);
    }
    try std.testing.expectEqualStrings("response.completed", second.event_type.?);
    try std.testing.expect(std.mem.indexOf(u8, second.data.?, "response.completed") != null);
}

test "TypedSseEventReader clears pending_line after StreamTooLong chunks" {
    const alloc = std.testing.allocator;
    const large_delta = try alloc.alloc(u8, 9000);
    defer alloc.free(large_delta);
    @memset(large_delta, 'a');
    const payload = try std.fmt.allocPrint(
        alloc,
        "data: {{\"type\":\"response.output_text.delta\",\"delta\":\"{s}\"}}",
        .{large_delta},
    );
    defer alloc.free(payload);

    const OverflowReader = struct {
        phase: u8 = 0,
        payload: []const u8,

        pub fn takeDelimiter(self: *@This(), delimiter: u8) error{ StreamTooLong, ReadFailed }!?[]const u8 {
            _ = delimiter;
            self.phase += 1;
            return switch (self.phase) {
                1 => "event: response.output_text.delta",
                2 => error.StreamTooLong,
                3 => null,
                4 => "",
                5 => "event: response.completed",
                6 => "data: {\"type\":\"response.completed\"}",
                7 => "",
                else => null,
            };
        }

        pub fn buffered(self: *@This()) []const u8 {
            return self.payload;
        }

        pub fn tossBuffered(_: *@This()) void {}
    };

    var reader = OverflowReader{ .payload = payload };
    var event_reader = TypedSseEventReader{ .max_line_bytes = max_sse_event_line_bytes };
    defer event_reader.deinit(alloc);

    const first = (try event_reader.next(alloc, &reader)).?;
    defer {
        if (first.event_type) |value| alloc.free(value);
        if (first.data) |value| alloc.free(value);
    }
    try std.testing.expectEqualStrings("response.output_text.delta", first.event_type.?);
    try std.testing.expect(first.data.?.len > large_delta.len);

    const second = (try event_reader.next(alloc, &reader)).?;
    defer {
        if (second.event_type) |value| alloc.free(value);
        if (second.data) |value| alloc.free(value);
    }
    try std.testing.expectEqualStrings("response.completed", second.event_type.?);
}
