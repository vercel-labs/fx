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

pub fn streamGatewayCompletion(
    provider: agent_stream_provider.Provider,
    alloc: Allocator,
    api_key: []const u8,
    credential_source: ?types.CredentialSource,
    account_id: ?[]const u8,
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
        .credential_source = credential_source,
        .account_id = account_id,
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
                if (credential_source == .chatgpt_subscription or credential_source == .grok_subscription) {
                    ledger.clearReconciliationCredential();
                } else {
                    ledger.startReconciliation(usage_allocator, api_key);
                }
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
    const provider_state_json = if (result.completion.provider_state_json) |state| try alloc.dupe(u8, state) else null;
    errdefer if (provider_state_json) |owned| alloc.free(owned);
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
            .provider_state_json = provider_state_json,
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
    if (completion.provider_state_json) |state| response_bytes += state.len;
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
