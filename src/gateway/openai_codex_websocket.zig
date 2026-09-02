//! Codex-specific WebSocket adapter.
//!
//! This module owns connection reuse, continuation, event reduction, and the
//! WebSocket request lifecycle. The base provider supplies only the shared
//! Responses request serializers and connection credentials.

const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const responses_protocol = @import("responses_protocol.zig");
const websocket_transport = @import("websocket_transport.zig");
const codex_websocket_session = @import("codex_websocket_session.zig");

const Allocator = std.mem.Allocator;

pub const ConnectionConfig = struct {
    endpoint: []const u8,
    authorization: []const u8,
    account_id: []const u8,
};

pub const Serializer = struct {
    build_input: *const fn (
        alloc: Allocator,
        messages: []const types.ChatMessage,
        images: ?[]const image_attachments.VerifiedSnapshot,
    ) anyerror![]u8,
    build_request: *const fn (
        alloc: Allocator,
        request: stream_provider.RequestData,
        input: []const u8,
        previous_response_id: ?[]const u8,
    ) anyerror![]u8,
    build_durable_input: *const fn (
        alloc: Allocator,
        messages: []const types.ChatMessage,
    ) anyerror![]u8,
};

pub fn shutdown() void {
    codex_websocket_session.shutdown();
}

pub fn stream(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    config: ConnectionConfig,
    serializer: Serializer,
    stream_limits: responses_protocol.StreamLimits,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    const full_input = try serializer.build_input(alloc, request.messages, request.verified_images);
    defer alloc.free(full_input);
    const shape_payload = try serializer.build_request(alloc, request.data(), "", null);
    defer alloc.free(shape_payload);
    var shape: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(shape_payload, &shape, .{});

    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var bridge = WebSocketBridge{
        .alloc = alloc,
        .reducer = &reducer,
        .events = request.events,
        .cancel_flag = request.cancel_flag,
        .content_capture_limit = request.content_capture_limit,
        .stream_limits = stream_limits,
    };
    try request.admission.admit();

    var continuation_recovery_attempted = false;
    while (true) {
        const checkout = try codex_websocket_session.acquire(alloc, .{
            .session_id = request.session_id,
            .account_id = config.account_id,
            .model = request.model,
            .endpoint = config.endpoint,
            .authorization = config.authorization,
            .deadline = request.deadline,
            .cancel_flag = request.cancel_flag,
            .delivery = request.delivery,
            .continuation_input = if (continuation_recovery_attempted) null else full_input,
            .continuation_shape = if (continuation_recovery_attempted) null else shape,
        });
        debug_trace.eventf("codex.ws", "turn", request.trace_ctx, "lane={d} retained={d} reused={d} handshake_ms={d} health={d} auth=chatgpt_subscription", .{
            checkout.slot orelse std.math.maxInt(usize),
            @as(u8, @intFromBool(checkout.retained)),
            @as(u8, @intFromBool(checkout.reused)),
            checkout.handshake_ms,
            checkout.health_failures,
        });
        const continued = if (continuation_recovery_attempted)
            null
        else
            codex_websocket_session.continuation(checkout.slot, full_input, shape);
        const payload = try serializer.build_request(
            alloc,
            request.data(),
            if (continued) |value| value.delta_input else full_input,
            if (continued) |value| value.previous_response_id else null,
        );
        defer alloc.free(payload);
        debug_trace.eventf("codex.ws", "continuation", request.trace_ctx, "used={d} delta_bytes={d} recovery={d}", .{
            @as(u8, @intFromBool(continued != null)),
            if (continued) |value| value.delta_input.len else full_input.len,
            @as(u8, @intFromBool(continuation_recovery_attempted)),
        });
        websocket_transport.streamOn(checkout.connection, alloc, .{
            .endpoint = config.endpoint,
            .authorization = config.authorization,
            .account_id = config.account_id,
            .session_id = request.session_id,
            .payload = payload,
            .deadline = request.deadline,
            .cancel_flag = request.cancel_flag,
            .delivery = request.delivery,
        }, &bridge, WebSocketBridge.event) catch |err| {
            codex_websocket_session.release(checkout, .failed);
            if (err == error.PreviousResponseNotFound and continued != null and !continuation_recovery_attempted) {
                continuation_recovery_attempted = true;
                reducer.deinit(alloc);
                reducer = responses_protocol.Reducer.init(alloc);
                continue;
            }
            debug_trace.eventf("codex.ws", "poison", request.trace_ctx, "reason={s} close={d}", .{ failureReason(err), @as(u16, 0) });
            return err;
        };
        const completion = reducer.finish(alloc, request.cancel_flag, bridge.stream_limits) catch |err| {
            codex_websocket_session.release(checkout, .failed);
            debug_trace.eventf("codex.ws", "poison", request.trace_ctx, "reason=protocol close={d}", .{@as(u16, 0)});
            return mapReducerError(err);
        };
        recordContinuation(alloc, checkout.slot, request, completion, full_input, shape, serializer);
        codex_websocket_session.release(checkout, .completed);
        return .{ .completed = .{
            .completion = completion,
            .usage = .{ .unavailable = .possibly_billed },
            .ownership = .owned,
        } };
    }
}

fn recordContinuation(
    alloc: Allocator,
    slot: ?usize,
    request: stream_provider.ModelRequest,
    completion: types.ModelCompletion,
    full_input: []const u8,
    shape: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    serializer: Serializer,
) void {
    const response_id = completion.generation_id orelse return;
    const response_message = [_]types.ChatMessage{.{
        .role = .assistant,
        .content = completion.content,
        .tool_calls = completion.tool_calls,
        .provider_state_json = completion.provider_state_json,
    }};
    const response_input = serializer.build_input(alloc, &response_message, null) catch return;
    defer alloc.free(response_input);
    const baseline = buildContinuationBaseline(alloc, full_input, response_input) catch return;
    defer alloc.free(baseline);
    const durable_full_input = serializer.build_durable_input(alloc, request.messages) catch return;
    defer alloc.free(durable_full_input);
    const durable_response_input = serializer.build_durable_input(alloc, &response_message) catch return;
    defer alloc.free(durable_response_input);
    const durable_baseline = buildContinuationBaseline(alloc, durable_full_input, durable_response_input) catch return;
    defer alloc.free(durable_baseline);
    codex_websocket_session.recordCompletion(
        slot,
        response_id,
        baseline,
        durable_baseline,
        shape,
    );
}

fn buildContinuationBaseline(
    alloc: Allocator,
    full_input: []const u8,
    response_input: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(full_input);
    if (response_input.len > 0) {
        if (out.written().len > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(response_input);
    }
    return out.toOwnedSlice();
}

fn failureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.Cancelled => "cancel",
        error.Timeout => "timeout",
        error.WebSocketPolicyClosed => "policy",
        error.WebSocketUnexpectedBinary => "binary",
        error.WebSocketProtocolViolation, error.WebSocketInvalidUtf8 => "protocol",
        error.WebSocketUpgradeRejected, error.WebSocketAcceptInvalid => "auth",
        else => "close",
    };
}

const WebSocketBridge = struct {
    alloc: Allocator,
    reducer: *responses_protocol.Reducer,
    events: stream_provider.EventSink,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
    stream_limits: responses_protocol.StreamLimits,

    fn event(raw: *anyopaque, json_text: []const u8) !bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.reducer.applyJson(
            self.alloc,
            json_text,
            .{
                .context = &self.events,
                .on_content = EventBridge.content,
                .on_tool_start = EventBridge.toolStart,
                .on_reasoning = EventBridge.reasoning,
                .on_tool_input = EventBridge.toolInput,
            },
            self.cancel_flag,
            self.content_capture_limit,
            self.stream_limits,
        ) catch |err| return mapReducerError(err);
    }
};

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

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidEvent => error.InvalidOpenAICodexSseEvent,
        error.PreviousResponseNotFound => error.PreviousResponseNotFound,
        error.ResponseFailed => error.OpenAICodexResponseFailed,
        error.StreamIncomplete => error.OpenAICodexStreamIncomplete,
        error.ToolCallLimitExceeded => error.OpenAICodexToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.OpenAICodexToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.OpenAICodexResourceLimitExceeded,
        else => err,
    };
}
