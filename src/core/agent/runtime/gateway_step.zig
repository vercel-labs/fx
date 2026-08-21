const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const types = @import("../../shared/types.zig");
const session_usage = @import("../../session/session_usage.zig");
const message = @import("../../shared/message.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const io_mod = @import("../../shared/io.zig");
const runtime_telemetry = @import("telemetry.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const TraceContext = debug_trace.TraceContext;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;
pub const AttemptEvidence = agent_stream_provider.AttemptEvidence;

pub const StreamResult = struct {
    status: std.http.Status,
    completion: types.GatewayCompletion = .{},
    err_body: ?[]u8 = null,
    retry_after_seconds: ?u64 = null,
};

const CollectedTerminal = union(enum) {
    none,
    finish,
    failure: struct {
        category: agent_stream_provider.StreamFailure.Category,
        retry_after_seconds: ?u64,
    },
    cancelled,
};

const AdapterEventCollector = struct {
    alloc: Allocator,
    usage: ?*session_usage.Usage,
    attempt_evidence: *AttemptEvidence,
    content_capture_limit: ?usize,
    callback_ctx: *anyopaque,
    on_content_chunk: agent_stream_provider.StreamCallback,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?agent_stream_provider.StreamCallback,
    on_tool_input_chunk: ?agent_stream_provider.StreamCallback,
    content: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(types.ToolCall) = .empty,
    completion: types.GatewayCompletion = .{},
    generation_origin: ?[]u8 = null,
    failure_detail: ?[]u8 = null,
    failure_diagnostic_summary: ?[]u8 = null,
    failure_request_shape: ?[]u8 = null,
    usage_observation: ?session_usage.GatewayObservation = null,
    terminal: CollectedTerminal = .none,

    fn deinit(self: *AdapterEventCollector) void {
        self.content.deinit(self.alloc);
        for (self.tool_calls.items) |call| types.freeToolCall(self.alloc, call);
        self.tool_calls.deinit(self.alloc);
        if (self.completion.content) |content| self.alloc.free(@constCast(content));
        if (self.completion.generation_id) |id| self.alloc.free(@constCast(id));
        if (self.completion.billing) |billing| self.alloc.free(@constCast(billing.model));
        if (self.completion.provider_failure_detail) |detail| self.alloc.free(@constCast(detail));
        if (self.generation_origin) |origin| self.alloc.free(origin);
        if (self.failure_detail) |detail| self.alloc.free(detail);
        if (self.failure_diagnostic_summary) |summary| self.alloc.free(summary);
        if (self.failure_request_shape) |shape| self.alloc.free(shape);
    }

    fn emit(raw: *anyopaque, event: agent_stream_provider.StreamEvent) anyerror!void {
        const self: *AdapterEventCollector = @ptrCast(@alignCast(raw));
        switch (event) {
            .provider_admitted => {
                self.usage_observation = try session_usage.GatewayObservation.begin(self.usage);
                self.attempt_evidence.provider_admitted = true;
            },
            .text_delta => |chunk| {
                const retained = if (self.content_capture_limit) |limit|
                    chunk[0..@min(chunk.len, limit -| self.content.items.len)]
                else
                    chunk;
                try self.content.appendSlice(self.alloc, retained);
                self.on_content_chunk(self.callback_ctx, chunk);
            },
            .reasoning_delta => |chunk| if (self.on_reasoning_chunk) |callback| {
                callback(self.callback_ctx, chunk);
            },
            .tool_input_started => |started| if (self.on_tool_start) |callback| {
                callback(self.callback_ctx, started.id, started.name, started.label);
            },
            .tool_input_delta => |chunk| if (self.on_tool_input_chunk) |callback| {
                callback(self.callback_ctx, chunk);
            },
            .fx_tool_call, .provider_tool_started => |call| {
                const source = [_]types.ToolCall{call};
                const copied = try dupeGatewayToolCalls(self.alloc, &source);
                errdefer types.freeToolCallSlice(self.alloc, copied);
                try self.tool_calls.append(self.alloc, copied[0]);
                self.alloc.free(copied);
            },
            .provider_tool_result => |result| {
                for (self.tool_calls.items) |*call| {
                    if (!std.mem.eql(u8, call.id, result.call_id)) continue;
                    if (call.provenance != .provider_executed or call.provider_result != null) {
                        return error.ProviderToolStateDesynchronized;
                    }
                    call.provider_result = try self.alloc.dupe(u8, result.result);
                    break;
                } else return error.ProviderToolStateDesynchronized;
            },
            .usage => |usage| {
                self.completion.usage = usage.tokens;
                if (usage.billing) |billing| {
                    const model = try self.alloc.dupe(u8, billing.model_id);
                    if (self.completion.billing) |previous| self.alloc.free(@constCast(previous.model));
                    self.completion.billing = .{
                        .created_at_ms = billing.created_at_ms,
                        .model = model,
                        .total_cost = billing.total_cost,
                        .input_tokens = billing.input_tokens,
                        .output_tokens = billing.output_tokens,
                        .cache_read_tokens = billing.cache_read_tokens,
                        .cache_write_tokens = billing.cache_write_tokens,
                        .reasoning_tokens = billing.reasoning_tokens,
                        .billable_web_search_calls = billing.billable_web_search_calls,
                    };
                }
            },
            .finish => |finish| {
                self.terminal = .finish;
                self.completion.finish_reason = finish.reason;
                self.completion.generation_metadata_invalid = finish.generation_metadata_invalid;
                self.completion.delivery_ambiguous = finish.delivery_ambiguous;
                self.completion.provider_result_identity_failure = finish.provider_result_identity_failure;
                if (finish.generation_reference) |reference| {
                    self.completion.generation_id = try self.alloc.dupe(u8, reference.id);
                    if (reference.lookup_scope) |scope| {
                        self.generation_origin = try self.alloc.dupe(u8, scope);
                    }
                }
                if (finish.provider_failure_detail) |detail| {
                    self.completion.provider_failure_detail = try self.alloc.dupe(u8, detail);
                }
            },
            .failure => |failure| {
                if (failure.category == .ambiguous_delivery) self.completion.delivery_ambiguous = true;
                self.terminal = .{ .failure = .{
                    .category = failure.category,
                    .retry_after_seconds = failure.retry_after_seconds,
                } };
                if (failure.detail) |detail| self.failure_detail = try self.alloc.dupe(u8, detail);
                if (failure.diagnostic) |diagnostic| {
                    self.failure_diagnostic_summary = try self.alloc.dupe(u8, diagnostic.summary);
                    if (diagnostic.request_shape) |shape| {
                        self.failure_request_shape = try self.alloc.dupe(u8, shape);
                    }
                }
            },
            .cancelled => self.terminal = .cancelled,
        }
    }

    fn takeCompletion(self: *AdapterEventCollector) !types.GatewayCompletion {
        if (self.content.items.len > 0) self.completion.content = try self.content.toOwnedSlice(self.alloc);
        self.completion.tool_calls = try self.tool_calls.toOwnedSlice(self.alloc);
        const completion = self.completion;
        self.completion = .{};
        return completion;
    }

    fn takeUsageObservation(self: *AdapterEventCollector) ?session_usage.GatewayObservation {
        const observation = self.usage_observation;
        self.usage_observation = null;
        return observation;
    }
};

/// Temporary G11 bridge from neutral terminal events to the unchanged agent
/// loop and session-usage contracts.
const LegacyGatewayCompatibilityBridge = struct {
    status: std.http.Status,
    err_body: ?[]const u8 = null,
    retry_after_seconds: ?u64 = null,
    generation_origin: []const u8 = "",
    reconcile_generation_usage: bool = false,
    failure_diagnostic_summary: ?[]const u8 = null,
    failure_request_shape: ?[]const u8 = null,
    cancelled: bool = false,

    fn fromCollector(collector: *const AdapterEventCollector) error{MissingTerminalEvent}!LegacyGatewayCompatibilityBridge {
        return switch (collector.terminal) {
            .none => error.MissingTerminalEvent,
            .finish => .{
                .status = .ok,
                .generation_origin = collector.generation_origin orelse "",
                .reconcile_generation_usage = collector.completion.generation_id != null,
            },
            .failure => |failure| .{
                .status = statusForFailure(failure.category),
                .err_body = collector.failure_detail,
                .retry_after_seconds = failure.retry_after_seconds,
                .failure_diagnostic_summary = collector.failure_diagnostic_summary,
                .failure_request_shape = collector.failure_request_shape,
            },
            .cancelled => .{ .status = .request_timeout, .cancelled = true },
        };
    }

    fn statusForFailure(category: agent_stream_provider.StreamFailure.Category) std.http.Status {
        return switch (category) {
            .authentication => .unauthorized,
            .authorization => .forbidden,
            .configuration => .bad_request,
            .invalid_content => .unprocessable_entity,
            .request_too_large => .payload_too_large,
            .rate_limited => .too_many_requests,
            .provider_internal => .internal_server_error,
            .upstream_failure, .protocol => .bad_gateway,
            .unavailable, .transport, .ambiguous_delivery => .service_unavailable,
            .timeout => .gateway_timeout,
            .other => .internal_server_error,
        };
    }

    fn failedDeliveryOutcome(
        collector: *const AdapterEventCollector,
        delivery: *const DeliveryCertainty,
    ) session_usage.DeliveryOutcome {
        if (collector.terminal == .failure and collector.terminal.failure.category == .ambiguous_delivery) {
            return .ambiguous_delivery;
        }
        return if (delivery.load() == .possibly_sent) .ambiguous_delivery else .unbilled;
    }
};

pub fn streamModelRequest(
    adapter: agent_stream_provider.ProviderAdapter,
    alloc: Allocator,
    credential: []const u8,
    tenant: ?[]const u8,
    session_id: ?[]const u8,
    model: []const u8,
    retry_count: usize,
    endpoint: []const u8,
    model_request: agent_stream_provider.ModelRequest,
    cooperative_pulse: ?agent_stream_provider.CooperativePulse,
    delivery: *DeliveryCertainty,
    attempt_evidence: *AttemptEvidence,
    callback_ctx: *anyopaque,
    on_content_chunk: agent_stream_provider.StreamCallback,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?agent_stream_provider.StreamCallback,
    on_tool_input_chunk: ?agent_stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,
    trace_ctx: TraceContext,
    content_capture_limit: ?usize,
    provider_attempt_owner: agent_stream_provider.ProviderAttemptOwner,
) !StreamResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const started_at_ms = io_mod.milliTimestamp();
    var collector = AdapterEventCollector{
        .alloc = alloc,
        .usage = usage,
        .attempt_evidence = attempt_evidence,
        .content_capture_limit = content_capture_limit,
        .callback_ctx = callback_ctx,
        .on_content_chunk = on_content_chunk,
        .on_tool_start = on_tool_start,
        .on_reasoning_chunk = on_reasoning_chunk,
        .on_tool_input_chunk = on_tool_input_chunk,
    };
    defer collector.deinit();
    var event_state = agent_stream_provider.EventState.init(alloc);
    defer event_state.deinit();
    var sink_error: ?anyerror = null;
    adapter.stream(alloc, .{
        .model_request = model_request,
        .credential = credential,
        .tenant = tenant,
        .session_id = session_id,
        .model_id = model,
        .retry_count = retry_count,
        .endpoint = endpoint,
        .trace_ctx = trace_ctx,
        .content_capture_limit = content_capture_limit,
        .cooperative_pulse = cooperative_pulse,
        .delivery = delivery,
        .attempt_evidence = attempt_evidence,
        .cancel_flag = cancel_flag,
        .provider_attempt_owner = provider_attempt_owner,
    }, .{
        .context = &collector,
        .state = &event_state,
        .sink_error = &sink_error,
        .emit_fn = AdapterEventCollector.emit,
    }) catch |err| {
        runtime_telemetry.recordGatewayCallMetric(model, started_at_ms, 0, 0, 0, 0, trace_ctx.turn_id, trace_ctx.step_id, trace_ctx.subagent_id, @errorName(err), "");
        if (collector.takeUsageObservation()) |observation| {
            try observation.fail(LegacyGatewayCompatibilityBridge.failedDeliveryOutcome(&collector, delivery));
        }
        return err;
    };

    const legacy = try LegacyGatewayCompatibilityBridge.fromCollector(&collector);
    if (legacy.cancelled) {
        runtime_telemetry.recordGatewayCallMetric(model, started_at_ms, 0, 0, 0, 0, trace_ctx.turn_id, trace_ctx.step_id, trace_ctx.subagent_id, "Cancelled", "");
        if (collector.takeUsageObservation()) |observation| {
            try observation.fail(if (delivery.load() == .possibly_sent)
                .ambiguous_delivery
            else
                .unbilled);
        }
        return error.Cancelled;
    }

    var completion = try collector.takeCompletion();
    errdefer deinitCollectedCompletion(alloc, completion);
    recordGatewayResultMetric(
        model,
        started_at_ms,
        legacy.status,
        completion,
        legacy.err_body,
        legacy.failure_diagnostic_summary,
        legacy.failure_request_shape,
        trace_ctx,
    );
    if (collector.takeUsageObservation()) |observation| {
        try observation.complete(
            usage_allocator,
            legacy.status,
            completion,
            legacy.generation_origin,
            tenant,
        );
    }
    if (legacy.reconcile_generation_usage) {
        if (usage) |ledger| ledger.startReconciliation(usage_allocator, credential);
    }
    if (completion.billing) |billing| {
        alloc.free(@constCast(billing.model));
        completion.billing = null;
    }

    const err_body = if (legacy.err_body) |body| try alloc.dupe(u8, body) else null;
    return .{
        .status = legacy.status,
        .completion = completion,
        .err_body = err_body,
        .retry_after_seconds = legacy.retry_after_seconds,
    };
}

fn deinitCollectedCompletion(alloc: Allocator, completion: types.GatewayCompletion) void {
    if (completion.content) |content| alloc.free(@constCast(content));
    if (completion.generation_id) |id| alloc.free(@constCast(id));
    if (completion.billing) |billing| alloc.free(@constCast(billing.model));
    types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
}

pub fn streamGatewayCompletion(
    provider: agent_stream_provider.Provider,
    alloc: Allocator,
    api_key: []const u8,
    team: ?[]const u8,
    session_id: ?[]const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    cooperative_pulse: ?agent_stream_provider.CooperativePulse,
    delivery: *DeliveryCertainty,
    attempt_evidence: *AttemptEvidence,
    callback_ctx: *anyopaque,
    on_content_chunk: agent_stream_provider.StreamCallback,
    on_tool_start: ?agent_stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?agent_stream_provider.StreamCallback,
    on_tool_input_chunk: ?agent_stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,
    trace_ctx: TraceContext,
    content_capture_limit: ?usize,
    provider_attempt_owner: agent_stream_provider.ProviderAttemptOwner,
) !StreamResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const started_at_ms = io_mod.milliTimestamp();
    const usage_observation = try session_usage.GatewayObservation.begin(usage);
    attempt_evidence.provider_admitted = true;
    var result = provider.stream(alloc, .{
        .api_key = api_key,
        .team = team,
        .session_id = session_id,
        .model = model,
        .retry_count = retry_count,
        .chat_url = chat_url,
        .payload = payload,
        .trace_ctx = trace_ctx,
        .content_capture_limit = content_capture_limit,
        .delivery = delivery,
        .attempt_evidence = attempt_evidence,
        .on_reasoning_chunk = on_reasoning_chunk,
        .on_tool_input_chunk = on_tool_input_chunk,
        .cooperative_pulse = cooperative_pulse,
        .provider_attempt_owner = provider_attempt_owner,
        .callback_ctx = callback_ctx,
        .on_content_chunk = on_content_chunk,
        .on_tool_start = on_tool_start,
        .cancel_flag = cancel_flag,
    }) catch |err| {
        runtime_telemetry.recordGatewayCallMetric(model, started_at_ms, 0, 0, 0, 0, trace_ctx.turn_id, trace_ctx.step_id, trace_ctx.subagent_id, @errorName(err), "");
        try usage_observation.fail(if (delivery.load() == .possibly_sent)
            .ambiguous_delivery
        else
            .unbilled);
        return err;
    };
    defer result.deinit(alloc);

    recordGatewayResultMetric(
        model,
        started_at_ms,
        result.status,
        result.completion,
        result.err_body,
        result.failure_schema,
        result.failure_request_shape,
        trace_ctx,
    );
    try usage_observation.complete(
        usage_allocator,
        result.status,
        result.completion,
        result.generation_origin,
        team,
    );
    if (comptime @import("builtin").os.tag != .wasi) {
        if (result.reconcile_generation_usage) {
            if (usage) |ledger| {
                ledger.startReconciliation(usage_allocator, api_key);
            }
        }
    }

    if (result.ownership == .borrowed) {
        return .{
            .status = result.status,
            .completion = result.completion,
            .err_body = result.err_body,
            .retry_after_seconds = result.retry_after_seconds,
        };
    }

    const tool_calls = try dupeGatewayToolCalls(alloc, result.completion.tool_calls);
    errdefer message.freeToolCalls(alloc, tool_calls);
    const content = if (result.completion.content) |content_text| try alloc.dupe(u8, content_text) else null;
    errdefer if (content) |owned| alloc.free(owned);
    const generation_id = if (result.completion.generation_id) |id| try alloc.dupe(u8, id) else null;
    errdefer if (generation_id) |owned| alloc.free(owned);
    const provider_failure_detail = if (result.completion.provider_failure_detail) |detail| try alloc.dupe(u8, detail) else null;
    errdefer if (provider_failure_detail) |owned| alloc.free(owned);
    const err_body = if (result.err_body) |body| try alloc.dupe(u8, body) else null;
    errdefer if (err_body) |owned| alloc.free(owned);

    const status = result.status;
    const finish_reason = result.completion.finish_reason;
    const completion_usage = result.completion.usage;
    const delivery_ambiguous = result.completion.delivery_ambiguous;
    const generation_metadata_invalid = result.completion.generation_metadata_invalid;
    const provider_result_identity_failure = result.completion.provider_result_identity_failure;
    const retry_after_seconds = result.retry_after_seconds;
    return .{
        .status = status,
        .completion = .{
            .content = content,
            .tool_calls = tool_calls,
            .generation_id = generation_id,
            .generation_metadata_invalid = generation_metadata_invalid,
            .delivery_ambiguous = delivery_ambiguous,
            .provider_result_identity_failure = provider_result_identity_failure,
            .provider_failure_detail = provider_failure_detail,
            .finish_reason = finish_reason,
            .usage = completion_usage,
        },
        .err_body = err_body,
        .retry_after_seconds = retry_after_seconds,
    };
}

fn recordGatewayResultMetric(
    model: []const u8,
    started_at_ms: i64,
    status: std.http.Status,
    completion: types.GatewayCompletion,
    err_body: ?[]const u8,
    failure_schema: ?[]const u8,
    failure_request_shape: ?[]const u8,
    trace_ctx: TraceContext,
) void {
    var response_bytes: u64 = 0;
    if (completion.content) |content| response_bytes += content.len;
    for (completion.tool_calls) |call| {
        response_bytes += call.id.len + call.name.len + call.arguments_json.len;
        if (call.provider_result) |pr| response_bytes += pr.len;
    }
    if (err_body) |body| response_bytes += body.len;
    const truncated_bytes: u32 = @intCast(@min(response_bytes, std.math.maxInt(u32)));
    const input_tokens = clampTokenCount(completion.usage.input_tokens);
    const output_tokens = clampTokenCount(completion.usage.output_tokens);
    const terminal_stop_reason = if (status == .ok)
        if (completion.finish_reason) |reason| reason.label() else "missing_provider_finish"
    else
        "";

    runtime_telemetry.recordGatewayCallMetricWithDiagnostics(
        model,
        started_at_ms,
        @intFromEnum(status),
        truncated_bytes,
        input_tokens,
        output_tokens,
        trace_ctx.turn_id,
        trace_ctx.step_id,
        trace_ctx.subagent_id,
        "",
        terminal_stop_reason,
        .{
            .schema = failure_schema orelse "",
            .request_shape = failure_request_shape orelse "",
        },
    );
}

fn clampTokenCount(value: ?u64) u32 {
    const t = value orelse return 0;
    return @intCast(@min(t, std.math.maxInt(u32)));
}

fn dupeGatewayToolCalls(alloc: Allocator, source: anytype) ![]types.ToolCall {
    if (source.len == 0) return &.{};
    const copy = try alloc.alloc(types.ToolCall, source.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            alloc.free(copy[i].id);
            alloc.free(copy[i].name);
            alloc.free(copy[i].arguments_json);
            if (copy[i].provisional_id) |provisional_id| alloc.free(provisional_id);
            if (copy[i].provider_result) |provider_result| alloc.free(provider_result);
        }
    }

    for (source, 0..) |call, i| {
        const id = try alloc.dupe(u8, call.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, call.name);
        errdefer alloc.free(name);
        const arguments_json = try alloc.dupe(u8, call.arguments_json);
        errdefer alloc.free(arguments_json);
        const provisional_id = if (call.provisional_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (provisional_id) |value| alloc.free(value);
        const provider_result = if (call.provider_result) |result| try alloc.dupe(u8, result) else null;
        errdefer if (provider_result) |result| alloc.free(result);
        copy[i] = .{
            .id = id,
            .name = name,
            .arguments_json = arguments_json,
            .argument_integrity = call.argument_integrity,
            .provisional_id = provisional_id,
            .provider_result = provider_result,
            .final_identity = call.final_identity,
            .provenance = call.provenance,
        };
        copied += 1;
    }
    return copy;
}

test "dupeGatewayToolCalls preserves argument integrity for shared agent admission" {
    const source = [_]types.ToolCall{.{
        .id = "call_1",
        .name = "ask_user_question",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};

    const copy = try dupeGatewayToolCalls(std.testing.allocator, &source);
    defer types.freeToolCallSlice(std.testing.allocator, copy);

    try std.testing.expectEqual(types.ToolArgumentIntegrity.malformed_json, copy[0].argument_integrity);
}

test "neutral adapter events materialize owned completion state" {
    const Fake = struct {
        fn stream(
            _: *const agent_stream_provider.ProviderAdapter,
            _: Allocator,
            _: agent_stream_provider.AdapterRequest,
            events: agent_stream_provider.EventSink,
        ) anyerror!void {
            try events.emit(.provider_admitted);
            var generation = [_]u8{ 'g', 'e', 'n', '_', 's', 'a', 'f', 'e' };
            const local_call = types.ToolCall{
                .id = "local_1",
                .name = "read_file",
                .arguments_json = "{}",
            };
            const provider_call = types.ToolCall{
                .id = "provider_1",
                .name = "perplexity_search",
                .arguments_json = "{}",
                .provenance = .provider_executed,
            };
            try events.emit(.{ .text_delta = "hello" });
            try events.emit(.{ .fx_tool_call = local_call });
            try events.emit(.{ .provider_tool_started = provider_call });
            try events.emit(.{ .provider_tool_result = .{
                .call_id = provider_call.id,
                .result = "{\"results\":[]}",
            } });
            try events.emit(.{ .usage = .{ .tokens = .{ .input_tokens = 3, .output_tokens = 5 } } });
            try events.emit(.{ .finish = .{
                .reason = .tool_calls,
                .generation_reference = .{ .id = &generation },
            } });
            @memset(&generation, 'x');
        }
    };
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    const result = try streamModelRequest(
        .{ .stream_fn = Fake.stream },
        std.testing.allocator,
        "credential",
        null,
        null,
        "test/model",
        1,
        "https://example.invalid",
        .{
            .model = "test/model",
            .serialized_tools = "[]",
            .messages = &.{},
            .tool_choice = .none,
            .capabilities = .{},
        },
        null,
        &delivery,
        &attempt_evidence,
        &callback_ctx,
        Callbacks.content,
        null,
        null,
        null,
        &cancel_flag,
        null,
        std.testing.allocator,
        .{},
        null,
        .agent,
    );
    defer deinitCollectedCompletion(std.testing.allocator, result.completion);
    defer if (result.err_body) |body| std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("hello", result.completion.content.?);
    try std.testing.expectEqual(@as(usize, 2), result.completion.tool_calls.len);
    try std.testing.expectEqual(types.ToolExecutionProvenance.fx_local, result.completion.tool_calls[0].provenance);
    try std.testing.expectEqual(types.ToolExecutionProvenance.provider_executed, result.completion.tool_calls[1].provenance);
    try std.testing.expectEqualStrings("{\"results\":[]}", result.completion.tool_calls[1].provider_result.?);
    try std.testing.expectEqual(@as(?u64, 3), result.completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 5), result.completion.usage.output_tokens);
    try std.testing.expectEqualStrings("gen_safe", result.completion.generation_id.?);
}

test "non-http adapter failure drives legacy gateway compatibility bridge" {
    const Fake = struct {
        fn stream(
            _: *const agent_stream_provider.ProviderAdapter,
            _: Allocator,
            _: agent_stream_provider.AdapterRequest,
            events: agent_stream_provider.EventSink,
        ) anyerror!void {
            try events.emit(.{ .failure = .{
                .category = .rate_limited,
                .detail = "retry later",
                .retry_after_seconds = 9,
            } });
        }
    };
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    const result = try streamModelRequest(
        .{ .stream_fn = Fake.stream },
        alloc,
        "credential",
        null,
        null,
        "test/model",
        1,
        "provider:endpoint",
        .{
            .model = "test/model",
            .serialized_tools = "[]",
            .messages = &.{},
            .tool_choice = .none,
            .capabilities = .{},
        },
        null,
        &delivery,
        &attempt_evidence,
        &callback_ctx,
        Callbacks.content,
        null,
        null,
        null,
        &cancel_flag,
        &usage,
        alloc,
        .{},
        null,
        .agent,
    );
    defer deinitCollectedCompletion(std.testing.allocator, result.completion);
    defer if (result.err_body) |body| std.testing.allocator.free(body);

    try std.testing.expectEqual(std.http.Status.too_many_requests, result.status);
    try std.testing.expectEqualStrings("retry later", result.err_body.?);
    try std.testing.expectEqual(@as(?u64, 9), result.retry_after_seconds);
    try std.testing.expect(!attempt_evidence.provider_admitted);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 1), snapshot.next_sequence);
    try std.testing.expectEqual(@as(u64, 0), snapshot.settled_through_sequence);
}

test "usage reservation failure stops before adapter network effects" {
    const Fake = struct {
        network_effects: usize = 0,

        fn stream(
            adapter: *const agent_stream_provider.ProviderAdapter,
            _: Allocator,
            _: agent_stream_provider.AdapterRequest,
            events: agent_stream_provider.EventSink,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(adapter.context.?));
            try events.emit(.provider_admitted);
            self.network_effects += 1;
            try events.emit(.{ .finish = .{ .reason = .stop } });
        }
    };
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var held: std.ArrayList(session_usage.GatewayObservation) = .empty;
    defer held.deinit(alloc);
    while (true) {
        const observation = session_usage.GatewayObservation.begin(&usage) catch |err| {
            try std.testing.expectEqual(error.UsageCapacityExceeded, err);
            break;
        };
        try held.append(alloc, observation);
    }

    var fake: Fake = .{};
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    try std.testing.expectError(
        error.UsageCapacityExceeded,
        streamModelRequest(
            .{ .context = &fake, .stream_fn = Fake.stream },
            alloc,
            "credential",
            null,
            null,
            "test/model",
            1,
            "provider:endpoint",
            .{
                .model = "test/model",
                .serialized_tools = "[]",
                .messages = &.{},
                .tool_choice = .none,
                .capabilities = .{},
            },
            null,
            &delivery,
            &attempt_evidence,
            &callback_ctx,
            Callbacks.content,
            null,
            null,
            null,
            &cancel_flag,
            &usage,
            alloc,
            .{},
            null,
            .agent,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.network_effects);
    try std.testing.expect(!attempt_evidence.provider_admitted);
    try std.testing.expectEqual(agent_stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
    for (held.items) |observation| try observation.fail(.unbilled);
}

pub const VisionToolMode = agent_stream_provider.VisionMode;

pub fn recordSelectedDynamicTool(
    alloc: Allocator,
    names: *std.ArrayList([]const u8),
    schemas: *std.ArrayList([]const u8),
    execution: ToolExecutionResult,
) !void {
    const name = execution.selected_dynamic_tool_name orelse return;
    const schema = execution.selected_dynamic_tool_schema_json orelse return;
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(alloc, name);
    try schemas.append(alloc, schema);
}

pub fn gatewayHttpErrorDetail(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
    model: []const u8,
    capabilities: model_capabilities.Capabilities,
) ![]const u8 {
    if (@intFromEnum(status) != 413) return detail;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (detail.len > 0) try out.writer.print("{s}\n\n", .{detail});
    try out.writer.print("prompt_too_long=true\nmodel={s}\n", .{model});
    if (capabilities.context_window) |context_window| {
        try out.writer.print("context_window_tokens={d}\n", .{context_window});
    }
    if (capabilities.max_output_tokens) |max_output_tokens| {
        try out.writer.print("max_output_tokens={d}\n", .{max_output_tokens});
    }
    try out.writer.writeAll("Provider rejected the prompt as too large. Latest local tool evidence remains in session history/result handles; no local tool actions were replayed.");
    return out.toOwnedSlice();
}

test "gateway 413 detail reports selected model and only known limits" {
    const alloc = std.testing.allocator;
    const known = try gatewayHttpErrorDetail(
        alloc,
        .payload_too_large,
        "provider detail",
        "provider/large-model",
        .{ .context_window = 1_000_000, .max_output_tokens = 128_000 },
    );
    defer alloc.free(@constCast(known));

    try std.testing.expect(std.mem.find(u8, known, "provider detail") != null);
    try std.testing.expect(std.mem.find(u8, known, "model=provider/large-model") != null);
    try std.testing.expect(std.mem.find(u8, known, "context_window_tokens=1000000") != null);
    try std.testing.expect(std.mem.find(u8, known, "max_output_tokens=128000") != null);
    try std.testing.expect(std.mem.find(u8, known, "input_tokens=") == null);

    const unknown = try gatewayHttpErrorDetail(
        alloc,
        .payload_too_large,
        "",
        "provider/private-model",
        .{},
    );
    defer alloc.free(@constCast(unknown));
    try std.testing.expect(std.mem.find(u8, unknown, "model=provider/private-model") != null);
    try std.testing.expect(std.mem.find(u8, unknown, "context_window_tokens=") == null);
    try std.testing.expect(std.mem.find(u8, unknown, "max_output_tokens=") == null);
}

test "pre-send gateway failure settles usage as unbilled" {
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    const result = streamGatewayCompletion(
        agent_stream_provider.unavailable_provider,
        alloc,
        "test-key",
        null,
        null,
        "test/model",
        1,
        "not a valid URL",
        "{}",
        null,
        &delivery,
        &attempt_evidence,
        &callback_ctx,
        Callbacks.content,
        null,
        null,
        null,
        &cancel_flag,
        &usage,
        alloc,
        .{},
        null,
        .agent,
    );
    if (result) |_| return error.TestExpectedGatewayFailure else |_| {}

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "possibly sent gateway failure marks billing incomplete" {
    const Gateway = struct {
        fn stream(
            _: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.Request,
        ) anyerror!agent_stream_provider.Result {
            request.delivery.markPossiblySent();
            return error.ConnectionResetByPeer;
        }
    };
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var callback_ctx: u8 = 0;

    const result = streamGatewayCompletion(
        .{ .stream_fn = Gateway.stream },
        alloc,
        "test-key",
        null,
        null,
        "test/model",
        1,
        "https://example.test/chat",
        "{}",
        null,
        &delivery,
        &attempt_evidence,
        &callback_ctx,
        Callbacks.content,
        null,
        null,
        null,
        &cancel_flag,
        &usage,
        alloc,
        .{},
        null,
        .agent,
    );
    if (result) |_| return error.TestExpectedGatewayFailure else |_| {}

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.incomplete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}
