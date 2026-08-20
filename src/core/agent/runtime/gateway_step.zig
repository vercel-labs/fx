const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const route_snapshot = @import("../../gateway/route_snapshot.zig");
const types = @import("../../shared/types.zig");
const session_usage = @import("../../session/session_usage.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_descriptor = @import("../../tooling/tool_descriptor.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const io_mod = @import("../../shared/io.zig");
const runtime_telemetry = @import("telemetry.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const TraceContext = debug_trace.TraceContext;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;
pub const AttemptEvidence = agent_stream_provider.AttemptEvidence;

pub const StreamFailureFacts = struct {
    category: agent_stream_provider.StreamFailure.Category,
    retryable: bool,
    delivery_ambiguous: bool,
    retry_after_seconds: ?u64,
    transport_cause: ?agent_stream_provider.StreamFailure.TransportCause,
};

pub const StreamResult = struct {
    completion: types.ModelCompletion = .{},
    failure: ?Failure = null,

    pub const Failure = struct {
        category: agent_stream_provider.StreamFailure.Category,
        response_status: u16 = 0,
        retryable: bool,
        delivery_ambiguous: bool,
        detail: ?[]u8 = null,
        retry_after_seconds: ?u64 = null,
        transport_cause: ?agent_stream_provider.StreamFailure.TransportCause = null,
        diagnostic_summary: ?[]u8 = null,
        tool_descriptor: ?[]u8 = null,
        request_shape: ?[]u8 = null,

        pub fn deinit(self: *Failure, alloc: Allocator) void {
            if (self.detail) |value| alloc.free(value);
            if (self.diagnostic_summary) |value| alloc.free(value);
            if (self.tool_descriptor) |value| alloc.free(value);
            if (self.request_shape) |value| alloc.free(value);
            self.* = undefined;
        }
    };

    pub fn succeeded(self: StreamResult) bool {
        return self.failure == null;
    }

    /// Transfers the owned completion into the caller's lifetime. The caller
    /// must eventually release it with `deinitCollectedCompletion` or an arena
    /// reset that owns every nested allocation.
    pub fn takeCompletion(self: *StreamResult) types.ModelCompletion {
        const completion = self.completion;
        self.completion = .{};
        return completion;
    }

    pub fn deinit(self: *StreamResult, alloc: Allocator) void {
        deinitCollectedCompletion(alloc, self.completion);
        if (self.failure) |*failure| failure.deinit(alloc);
        self.* = undefined;
    }
};

const CollectedTerminal = union(enum) {
    none,
    finish,
    failure: struct {
        category: agent_stream_provider.StreamFailure.Category,
        response_status: u16,
        retryable: bool,
        delivery_ambiguous: bool,
        retry_after_seconds: ?u64,
        transport_cause: ?agent_stream_provider.StreamFailure.TransportCause,
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
    completion: types.ModelCompletion = .{},
    generation_origin: ?[]u8 = null,
    failure_detail: ?[]u8 = null,
    failure_diagnostic_summary: ?[]u8 = null,
    failure_tool_descriptor: ?[]u8 = null,
    failure_request_shape: ?[]u8 = null,
    usage_observation: ?session_usage.ModelInvocationObservation = null,
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
        if (self.failure_tool_descriptor) |descriptor| self.alloc.free(descriptor);
        if (self.failure_request_shape) |shape| self.alloc.free(shape);
    }

    fn emit(raw: *anyopaque, event: agent_stream_provider.StreamEvent) anyerror!void {
        const self: *AdapterEventCollector = @ptrCast(@alignCast(raw));
        switch (event) {
            .provider_admitted => {
                self.usage_observation = try session_usage.ModelInvocationObservation.begin(self.usage);
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
                const delivery_ambiguous = failure.delivery_ambiguous or
                    failure.category == .ambiguous_delivery;
                self.completion.delivery_ambiguous = delivery_ambiguous;
                self.terminal = .{ .failure = .{
                    .category = failure.category,
                    .response_status = failure.response_status,
                    .retryable = failure.retryable,
                    .delivery_ambiguous = delivery_ambiguous,
                    .retry_after_seconds = failure.retry_after_seconds,
                    .transport_cause = failure.transport_cause,
                } };
                if (failure.detail) |detail| self.failure_detail = try self.alloc.dupe(u8, detail);
                if (failure.diagnostic) |diagnostic| {
                    self.failure_diagnostic_summary = try self.alloc.dupe(u8, diagnostic.summary);
                    if (diagnostic.tool_descriptor) |descriptor| {
                        self.failure_tool_descriptor = try self.alloc.dupe(u8, descriptor);
                    }
                    if (diagnostic.request_shape) |shape| {
                        self.failure_request_shape = try self.alloc.dupe(u8, shape);
                    }
                }
            },
            .cancelled => self.terminal = .cancelled,
        }
    }

    fn takeCompletion(self: *AdapterEventCollector) !types.ModelCompletion {
        if (self.content.items.len > 0) self.completion.content = try self.content.toOwnedSlice(self.alloc);
        self.completion.tool_calls = try self.tool_calls.toOwnedSlice(self.alloc);
        const completion = self.completion;
        self.completion = .{};
        return completion;
    }

    fn takeUsageObservation(self: *AdapterEventCollector) ?session_usage.ModelInvocationObservation {
        const observation = self.usage_observation;
        self.usage_observation = null;
        return observation;
    }

    fn takeFailure(self: *AdapterEventCollector) StreamResult.Failure {
        const terminal = switch (self.terminal) {
            .failure => |failure| failure,
            else => unreachable,
        };
        const failure = StreamResult.Failure{
            .category = terminal.category,
            .response_status = terminal.response_status,
            .retryable = terminal.retryable,
            .delivery_ambiguous = terminal.delivery_ambiguous,
            .detail = self.failure_detail,
            .retry_after_seconds = terminal.retry_after_seconds,
            .transport_cause = terminal.transport_cause,
            .diagnostic_summary = self.failure_diagnostic_summary,
            .tool_descriptor = self.failure_tool_descriptor,
            .request_shape = self.failure_request_shape,
        };
        self.failure_detail = null;
        self.failure_diagnostic_summary = null;
        self.failure_tool_descriptor = null;
        self.failure_request_shape = null;
        return failure;
    }

    fn failureFacts(self: *const AdapterEventCollector) ?StreamFailureFacts {
        const failure = switch (self.terminal) {
            .failure => |value| value,
            .none, .finish, .cancelled => return null,
        };
        return .{
            .category = failure.category,
            .retryable = failure.retryable,
            .delivery_ambiguous = failure.delivery_ambiguous,
            .retry_after_seconds = failure.retry_after_seconds,
            .transport_cause = failure.transport_cause,
        };
    }
};

pub fn streamModelRequest(
    adapter: agent_stream_provider.ProviderAdapter,
    alloc: Allocator,
    route: *const route_snapshot.RouteSnapshot,
    credential: []const u8,
    tenant: ?[]const u8,
    session_id: ?[]const u8,
    model: []const u8,
    retry_count: usize,
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
    serialized_request_limit_bytes: ?usize,
    content_capture_limit: ?usize,
    failure_facts: ?*?StreamFailureFacts,
    provider_attempt_owner: agent_stream_provider.ProviderAttemptOwner,
) !StreamResult {
    if (failure_facts) |output| output.* = null;
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
        .serialized_request_limit_bytes = serialized_request_limit_bytes,
        .route = route,
        .credential = credential,
        .tenant = tenant,
        .session_id = session_id,
        .model_id = model,
        .retry_count = retry_count,
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
        if (failure_facts) |output| output.* = collector.failureFacts();
        runtime_telemetry.recordModelCallMetric(model, started_at_ms, 0, 0, 0, trace_ctx.turn_id, trace_ctx.step_id, trace_ctx.subagent_id, @errorName(err), "");
        if (collector.takeUsageObservation()) |observation| {
            try observation.fail(failedDeliveryOutcome(&collector, delivery));
        }
        return err;
    };

    switch (collector.terminal) {
        .none => return error.MissingTerminalEvent,
        .cancelled => {
            runtime_telemetry.recordModelCallMetric(model, started_at_ms, 0, 0, 0, trace_ctx.turn_id, trace_ctx.step_id, trace_ctx.subagent_id, "Cancelled", "");
            if (collector.takeUsageObservation()) |observation| {
                try observation.fail(failedDeliveryOutcome(&collector, delivery));
            }
            return error.Cancelled;
        },
        .finish, .failure => {},
    }

    const delivery_outcome = failedDeliveryOutcome(&collector, delivery);
    var completion = try collector.takeCompletion();
    errdefer deinitCollectedCompletion(alloc, completion);
    if (collector.terminal == .failure) {
        var failure = collector.takeFailure();
        errdefer failure.deinit(alloc);
        recordModelResultMetric(
            model,
            started_at_ms,
            false,
            completion,
            failure.detail,
            failure.response_status,
            failure.tool_descriptor,
            failure.request_shape,
            trace_ctx,
        );
        if (collector.takeUsageObservation()) |observation| {
            try observation.fail(delivery_outcome);
        }
        return .{ .completion = completion, .failure = failure };
    }
    recordModelResultMetric(
        model,
        started_at_ms,
        true,
        completion,
        null,
        0,
        null,
        null,
        trace_ctx,
    );
    if (collector.takeUsageObservation()) |observation| {
        try observation.complete(
            usage_allocator,
            completion,
            route.connection_id,
            collector.generation_origin,
        );
    }
    if (comptime @import("builtin").os.tag != .wasi) {
        if (completion.generation_id != null) {
            if (usage) |ledger| ledger.startReconciliation(usage_allocator);
        }
    }
    if (completion.billing) |billing| {
        alloc.free(@constCast(billing.model));
        completion.billing = null;
    }

    return .{ .completion = completion };
}

fn failedDeliveryOutcome(
    collector: *const AdapterEventCollector,
    delivery: *const DeliveryCertainty,
) session_usage.DeliveryOutcome {
    if (collector.completion.delivery_ambiguous) return .ambiguous_delivery;
    return if (delivery.load() == .possibly_sent) .ambiguous_delivery else .unbilled;
}

fn deinitCollectedCompletion(alloc: Allocator, completion: types.ModelCompletion) void {
    if (completion.content) |content| alloc.free(@constCast(content));
    if (completion.generation_id) |id| alloc.free(@constCast(id));
    if (completion.billing) |billing| alloc.free(@constCast(billing.model));
    types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
}

fn recordModelResultMetric(
    model: []const u8,
    started_at_ms: i64,
    succeeded: bool,
    completion: types.ModelCompletion,
    err_body: ?[]const u8,
    response_status: u16,
    failure_tool_descriptor: ?[]const u8,
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
    const terminal_stop_reason = if (succeeded)
        if (completion.finish_reason) |reason| reason.label() else "missing_provider_finish"
    else
        "";

    runtime_telemetry.recordModelCallMetricWithDiagnostics(
        model,
        started_at_ms,
        response_status,
        truncated_bytes,
        input_tokens,
        output_tokens,
        trace_ctx.turn_id,
        trace_ctx.step_id,
        trace_ctx.subagent_id,
        "",
        terminal_stop_reason,
        .{
            .tool_descriptor = failure_tool_descriptor orelse "",
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

fn testingRoute(endpoint: []const u8) route_snapshot.RouteSnapshot {
    return .{
        .connection_id = @constCast("test"),
        .adapter_kind = @constCast("test"),
        .endpoint = @constCast(endpoint),
        .protocol = @constCast("test"),
        .credential_ref = @constCast("test_ref"),
        .primary_model_id = @constCast("test/model"),
        .permission_review_model_id = null,
        .vision_model_id = null,
        .subagent_model_id = @constCast("test/model"),
        .capabilities = .{},
        .capability_source = .configured,
        .selected_fast_mode = false,
        .fast_model_suffix = null,
    };
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

test "taken completion survives source result destruction" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
        .provider_result = "tool result",
    }};
    const content = try alloc.dupe(u8, "assistant source");
    const tool_calls = dupeGatewayToolCalls(alloc, &calls) catch |err| {
        alloc.free(content);
        return err;
    };
    var source = StreamResult{ .completion = .{
        .content = content,
        .tool_calls = tool_calls,
        .finish_reason = .tool_calls,
    } };
    const retained = source.takeCompletion();
    defer deinitCollectedCompletion(alloc, retained);

    source.deinit(alloc);

    try std.testing.expectEqualStrings("assistant source", retained.content.?);
    try std.testing.expectEqualStrings("call_1", retained.tool_calls[0].id);
    try std.testing.expectEqualStrings("tool result", retained.tool_calls[0].provider_result.?);
}

test "neutral adapter events materialize owned completion state" {
    const Fake = struct {
        fn stream(
            _: *const agent_stream_provider.ProviderAdapter,
            alloc: Allocator,
            _: agent_stream_provider.AdapterRequest,
            events: agent_stream_provider.EventSink,
        ) anyerror!void {
            const lookup_scope = try alloc.dupe(u8, "https://example.invalid/generation");
            defer alloc.free(lookup_scope);
            try events.emit(.provider_admitted);
            var generation = [_]u8{ 'r', 'e', 'q', 'u', 'e', 's', 't', '-', '4', '2' };
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
                .generation_reference = .{
                    .id = &generation,
                    .lookup_scope = lookup_scope,
                },
            } });
            @memset(&generation, 'x');
            @memset(lookup_scope, 'x');
        }
    };
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    var route = testingRoute("https://example.invalid");
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(std.testing.allocator);
    var result = try streamModelRequest(
        .{ .kind = "test", .supported_protocol = "test", .stream_fn = Fake.stream },
        std.testing.allocator,
        &route,
        "credential",
        null,
        null,
        "test/model",
        1,
        .{
            .tools = &.{},
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
        std.testing.allocator,
        .{},
        null,
        null,
        null,
        .agent,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", result.completion.content.?);
    try std.testing.expectEqual(@as(usize, 2), result.completion.tool_calls.len);
    try std.testing.expectEqual(types.ToolExecutionProvenance.fx_local, result.completion.tool_calls[0].provenance);
    try std.testing.expectEqual(types.ToolExecutionProvenance.provider_executed, result.completion.tool_calls[1].provenance);
    try std.testing.expectEqualStrings("{\"results\":[]}", result.completion.tool_calls[1].provider_result.?);
    try std.testing.expectEqual(@as(?u64, 3), result.completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 5), result.completion.usage.output_tokens);
    try std.testing.expectEqualStrings("request-42", result.completion.generation_id.?);
    var usage_snapshot = try usage.snapshot(std.testing.allocator);
    defer usage_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(session_usage.Availability.pending, usage_snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), usage_snapshot.pending.len);
    try std.testing.expectEqualStrings("request-42", usage_snapshot.pending[0].id);
    try std.testing.expectEqualStrings(
        "https://example.invalid/generation",
        usage_snapshot.pending[0].lookup_scope.?,
    );
}

test "normalized adapter failure retains semantic recovery facts" {
    const Fake = struct {
        fn stream(
            _: *const agent_stream_provider.ProviderAdapter,
            _: Allocator,
            _: agent_stream_provider.AdapterRequest,
            events: agent_stream_provider.EventSink,
        ) anyerror!void {
            try events.emit(.provider_admitted);
            try events.emit(.{ .failure = .{
                .category = .rate_limited,
                .retryable = true,
                .detail = "retry later",
                .retry_after_seconds = 9,
            } });
        }
    };
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    var route = testingRoute("provider:endpoint");
    var result = try streamModelRequest(
        .{ .kind = "test", .supported_protocol = "test", .stream_fn = Fake.stream },
        std.testing.allocator,
        &route,
        "credential",
        null,
        null,
        "test/model",
        1,
        .{
            .tools = &.{},
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
        null,
        null,
        .agent,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(agent_stream_provider.StreamFailure.Category.rate_limited, result.failure.?.category);
    try std.testing.expectEqualStrings("retry later", result.failure.?.detail.?);
    try std.testing.expectEqual(@as(?u64, 9), result.failure.?.retry_after_seconds);
    try std.testing.expect(result.failure.?.retryable);
}

test "normalized delivery-ambiguous failure keeps usage incomplete" {
    const Fake = struct {
        fn stream(
            _: *const agent_stream_provider.ProviderAdapter,
            _: Allocator,
            _: agent_stream_provider.AdapterRequest,
            events: agent_stream_provider.EventSink,
        ) anyerror!void {
            try events.emit(.provider_admitted);
            try events.emit(.{ .failure = .{
                .category = .provider_internal,
                .delivery_ambiguous = true,
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
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    var route = testingRoute("provider:endpoint");
    const result = try streamModelRequest(
        .{ .kind = "test", .supported_protocol = "test", .stream_fn = Fake.stream },
        alloc,
        &route,
        "credential",
        null,
        null,
        "test/model",
        1,
        .{
            .tools = &.{},
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
        null,
        null,
        .agent,
    );
    var owned_result = result;
    defer owned_result.deinit(alloc);

    try std.testing.expect(owned_result.failure.?.delivery_ambiguous);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.incomplete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
}

test "ambiguous-delivery category implies ambiguous delivery evidence" {
    const Fake = struct {
        fn stream(
            _: *const agent_stream_provider.ProviderAdapter,
            _: Allocator,
            _: agent_stream_provider.AdapterRequest,
            events: agent_stream_provider.EventSink,
        ) anyerror!void {
            try events.emit(.{ .failure = .{ .category = .ambiguous_delivery } });
        }
    };
    const Callbacks = struct {
        fn content(_: *anyopaque, _: []const u8) void {}
    };

    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    var route = testingRoute("provider:endpoint");
    var result = try streamModelRequest(
        .{ .kind = "test", .supported_protocol = "test", .stream_fn = Fake.stream },
        alloc,
        &route,
        "credential",
        null,
        null,
        "test/model",
        1,
        .{ .tools = &.{}, .messages = &.{}, .tool_choice = .none, .capabilities = .{} },
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
        alloc,
        .{},
        null,
        null,
        null,
        .agent,
    );
    defer result.deinit(alloc);
    try std.testing.expect(result.failure.?.delivery_ambiguous);
    try std.testing.expect(result.completion.delivery_ambiguous);
}

pub const VisionToolMode = agent_stream_provider.VisionMode;

pub fn recordSelectedDynamicTool(
    alloc: Allocator,
    names: *std.ArrayList([]const u8),
    descriptors: *std.ArrayList(tool_descriptor.Descriptor),
    execution: ToolExecutionResult,
) !void {
    const descriptor = execution.selected_dynamic_tool orelse return;
    try descriptor.validate();
    for (descriptors.items) |existing| {
        if (std.mem.eql(u8, existing.name, descriptor.name)) return;
    }
    try names.append(alloc, descriptor.name);
    try descriptors.append(alloc, descriptor);
}

pub fn providerFailureDetail(
    alloc: Allocator,
    category: agent_stream_provider.StreamFailure.Category,
    detail: []const u8,
    model: []const u8,
    capabilities: model_capabilities.Capabilities,
) ![]const u8 {
    if (category != .request_too_large) {
        return detail;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (detail.len > 0) {
        try out.writer.print("{s}\n\n", .{detail});
    }
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

test "request-too-large detail reports selected model and only known limits" {
    const alloc = std.testing.allocator;
    const known = try providerFailureDetail(
        alloc,
        .request_too_large,
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

    const unknown = try providerFailureDetail(
        alloc,
        .request_too_large,
        "",
        "provider/private-model",
        .{},
    );
    defer alloc.free(@constCast(unknown));
    try std.testing.expect(std.mem.find(u8, unknown, "model=provider/private-model") != null);
    try std.testing.expect(std.mem.find(u8, unknown, "context_window_tokens=") == null);
    try std.testing.expect(std.mem.find(u8, unknown, "max_output_tokens=") == null);
}
