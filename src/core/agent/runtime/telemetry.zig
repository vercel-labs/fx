const std = @import("std");
const model_capabilities = @import("../../config/model_capabilities.zig");
const types = @import("../../shared/types.zig");
const token_estimate = @import("../../shared/token_estimate.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const diagnostics = @import("../../workspace/diagnostics.zig");
const io_mod = @import("../../shared/io.zig");

const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const ReasoningEffort = types.ReasoningEffort;
const ToolCall = types.ToolCall;
const TraceContext = debug_trace.TraceContext;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub const TokenProgressUpdate = enum {
    unchanged,
    changed,
    invalid,
};

const ActiveTokenRequest = struct {
    content_estimator: token_estimate.StreamingEstimator = .{},
    reasoning_estimator: token_estimate.StreamingEstimator = .{},
    tool_input_estimator: token_estimate.StreamingEstimator = .{},

    fn outputEstimate(self: ActiveTokenRequest) u64 {
        return self.content_estimator.estimate() +|
            self.reasoning_estimator.estimate() +|
            self.tool_input_estimator.estimate();
    }
};

pub const GatewayFailureDiagnostics = struct {
    schema: []const u8 = "",
    request_shape: []const u8 = "",
};

pub fn recordGatewayCallMetric(model: []const u8, started_at_ms: i64, status: u16, response_bytes: u32, input_tokens: u32, output_tokens: u32, turn_id: u64, step_id: u64, subagent_id: u64, error_name: []const u8, terminal_stop_reason: []const u8) void {
    recordGatewayCallMetricWithDiagnostics(model, started_at_ms, status, response_bytes, input_tokens, output_tokens, turn_id, step_id, subagent_id, error_name, terminal_stop_reason, .{});
}

pub fn recordGatewayCallMetricWithDiagnostics(
    model: []const u8,
    started_at_ms: i64,
    status: u16,
    response_bytes: u32,
    input_tokens: u32,
    output_tokens: u32,
    turn_id: u64,
    step_id: u64,
    subagent_id: u64,
    error_name: []const u8,
    terminal_stop_reason: []const u8,
    failure_diagnostics: GatewayFailureDiagnostics,
) void {
    const now_ms = io_mod.milliTimestamp();
    const elapsed = if (now_ms > started_at_ms) now_ms - started_at_ms else 0;
    var call: diagnostics.NetworkCall = .{
        .started_at_ms = started_at_ms,
        .duration_ms = @intCast(@min(@as(i64, elapsed), std.math.maxInt(u32))),
        .status = status,
        .response_bytes = response_bytes,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .turn_id = turn_id,
        .step_id = step_id,
        .subagent_id = subagent_id,
    };
    call.setModel(model);
    if (error_name.len > 0) call.setError(error_name);
    if (terminal_stop_reason.len > 0) call.setTerminalStopReason(terminal_stop_reason);
    if (failure_diagnostics.schema.len > 0) call.setGatewaySchemaDiagnostic(failure_diagnostics.schema);
    if (failure_diagnostics.request_shape.len > 0) call.setGatewayRequestShape(failure_diagnostics.request_shape);
    diagnostics.recordNetworkCall(call);
}

pub const TurnSummaryAccumulator = struct {
    turn_started_at_ms: i64,
    thinking_duration_ms: u64 = 0,
    settled_token_progress: types.TurnTokenProgress = .{},
    active_token_request: ?ActiveTokenRequest = null,

    pub fn init(turn_started_at_ms: i64, submitted_prompt: []const u8) TurnSummaryAccumulator {
        var estimator = token_estimate.StreamingEstimator{};
        estimator.consume(submitted_prompt);
        return .{
            .turn_started_at_ms = turn_started_at_ms,
            .settled_token_progress = .{
                .input_tokens = estimator.estimate(),
                .input_exact = submitted_prompt.len == 0,
            },
        };
    }

    pub fn addThinkingWait(self: *TurnSummaryAccumulator, started_at_ms: i64, ended_at_ms: i64) void {
        if (ended_at_ms <= started_at_ms) return;
        self.thinking_duration_ms += @intCast(ended_at_ms - started_at_ms);
    }

    pub fn prepareTokenRequest(self: *TurnSummaryAccumulator) void {
        std.debug.assert(self.active_token_request == null);
        self.active_token_request = .{};
    }

    pub fn consumeReasoning(self: *TurnSummaryAccumulator, text: []const u8) TokenProgressUpdate {
        const active = &(self.active_token_request orelse return .invalid);
        const before = active.reasoning_estimator.estimate();
        active.reasoning_estimator.consume(text);
        return if (active.reasoning_estimator.estimate() == before) .unchanged else .changed;
    }

    pub fn consumeContent(self: *TurnSummaryAccumulator, text: []const u8) TokenProgressUpdate {
        const active = &(self.active_token_request orelse return .invalid);
        const before = active.content_estimator.estimate();
        active.content_estimator.consume(text);
        return if (active.content_estimator.estimate() == before) .unchanged else .changed;
    }

    /// Streamed tool arguments are output tokens the model is producing right
    /// now, so they count toward the live estimate the same way response text
    /// does. Without this a turn that spends its output budget composing one
    /// large tool call reports a frozen count until the provider settles usage.
    pub fn consumeToolInput(self: *TurnSummaryAccumulator, text: []const u8) TokenProgressUpdate {
        const active = &(self.active_token_request orelse return .invalid);
        const before = active.tool_input_estimator.estimate();
        active.tool_input_estimator.consume(text);
        return if (active.tool_input_estimator.estimate() == before) .unchanged else .changed;
    }

    pub fn reconcileTokenRequest(self: *TurnSummaryAccumulator, usage: types.Usage, delivery_ambiguous: bool) TokenProgressUpdate {
        const before = self.tokenProgress();
        const active = self.active_token_request orelse return .invalid;

        const output_tokens = usage.output_tokens orelse active.outputEstimate();
        self.settleOutputTokens(
            output_tokens,
            !delivery_ambiguous and usage.output_tokens != null,
        );
        self.active_token_request = null;
        return if (std.meta.eql(before, self.tokenProgress())) .unchanged else .changed;
    }

    pub fn finishTokenRequestWithoutUsage(self: *TurnSummaryAccumulator, possibly_sent: bool) TokenProgressUpdate {
        const before = self.tokenProgress();
        const active = self.active_token_request orelse return .unchanged;
        self.active_token_request = null;
        const output_tokens = active.outputEstimate();
        if (possibly_sent or output_tokens > 0) self.settleOutputTokens(output_tokens, false);
        return if (std.meta.eql(before, self.tokenProgress())) .unchanged else .changed;
    }

    pub fn tokenProgress(self: *const TurnSummaryAccumulator) types.TurnTokenProgress {
        var progress = self.settled_token_progress;
        if (self.active_token_request) |active| {
            progress.output_tokens +|= active.outputEstimate();
            progress.output_exact = false;
        }
        return progress;
    }

    fn settleOutputTokens(self: *TurnSummaryAccumulator, output_tokens: u64, output_exact: bool) void {
        self.settled_token_progress.output_tokens +|= output_tokens;
        self.settled_token_progress.output_exact = self.settled_token_progress.output_exact and output_exact;
    }

    pub fn finish(self: *const TurnSummaryAccumulator) types.TurnSummary {
        const now_ms = io_mod.milliTimestamp();
        const elapsed = if (now_ms > self.turn_started_at_ms) now_ms - self.turn_started_at_ms else 0;
        return .{
            .started_at_ms = self.turn_started_at_ms,
            .completed_at_ms = now_ms,
            .thinking_duration_ms = self.thinking_duration_ms,
            .turn_duration_ms = @intCast(elapsed),
            .token_progress = self.tokenProgress(),
        };
    }
};

pub const StepLimitTrace = struct {
    ctx: TraceContext,
    step_index: usize,
    step_limit: usize,
    gateway_message_count: usize,
    completed_tool_names: []const []u8,
    last_tool_call_name: []const u8,
    last_tool_call_id: []const u8,
};

pub fn traceStepLimitReached(trace: StepLimitTrace) void {
    if (!debug_trace.isScopeEnabled("agent")) return;

    const completed_names_owned = formatCompletedToolNamesCompact(std.heap.c_allocator, trace.completed_tool_names) catch null;
    defer if (completed_names_owned) |names| std.heap.c_allocator.free(names);
    const completed_tool_names = completed_names_owned orelse "unavailable";

    debug_trace.logf(
        "agent",
        "step limit reached turn_id={d} step_id={d} step_index={d} step_limit={d} gateway_messages={d} completed_tool_count={d} completed_tool_names={s} last_tool_call_name={s} last_tool_call_id={s} outcome_kind=step_limit",
        .{
            trace.ctx.turn_id,
            trace.ctx.step_id,
            trace.step_index,
            trace.step_limit,
            trace.gateway_message_count,
            trace.completed_tool_names.len,
            completed_tool_names,
            trace.last_tool_call_name,
            trace.last_tool_call_id,
        },
    );
    debug_trace.eventf(
        "agent",
        "step_limit_reached",
        trace.ctx,
        "step_index={d} step_limit={d} gateway_messages={d} completed_tool_count={d} completed_tool_names={s} last_tool_call_name={s} last_tool_call_id={s} outcome_kind=step_limit",
        .{
            trace.step_index,
            trace.step_limit,
            trace.gateway_message_count,
            trace.completed_tool_names.len,
            completed_tool_names,
            trace.last_tool_call_name,
            trace.last_tool_call_id,
        },
    );
}

pub fn formatCompletedToolNamesCompact(alloc: Allocator, names: []const []u8) ![]u8 {
    if (names.len == 0) return alloc.dupe(u8, "none");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (names, 0..) |name, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(name);
    }
    return out.toOwnedSlice();
}

pub fn formatHistoryTurnKinds(alloc: Allocator, history: []const HistoryTurn) ![]const u8 {
    if (history.len == 0) return alloc.dupe(u8, "none");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (history, 0..) |turn, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(historyTurnKindName(turn));
    }
    return out.toOwnedSlice();
}

fn historyTurnKindName(turn: HistoryTurn) []const u8 {
    return switch (turn) {
        .compacted_summary => "compacted_summary",
        .assistant => "assistant",
        .interrupted => "interrupted",
    };
}

pub fn formatMessageRoles(alloc: Allocator, messages: []const ChatMessage) ![]const u8 {
    if (messages.len == 0) return alloc.dupe(u8, "none");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (messages, 0..) |chat_message, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(@tagName(chat_message.role));
    }
    return out.toOwnedSlice();
}

pub fn traceReturnedToolCalls(arena: Allocator, ctx: TraceContext, tool_calls: []const ToolCall) !void {
    for (tool_calls) |call| {
        const preview_text = debug_trace.keylessJsonPreview(arena, call.arguments_json) catch "<preview-error>";
        debug_trace.eventf(
            "tool",
            "returned_tool_call",
            ctx,
            "call_id={s} tool_name={s} args_bytes={d} args_preview={s}",
            .{ call.id, call.name, call.arguments_json.len, preview_text },
        );
    }
}

pub fn traceCancelObserved(ctx: TraceContext, active_tool_known: bool) void {
    debug_trace.eventf("interrupt", "cancel_observed", ctx, "active_tool_known={s}", .{if (active_tool_known) "true" else "false"});
}

pub fn traceGatewayProviderOptions(ctx: TraceContext, model: []const u8, fast_mode: bool, effort: ReasoningEffort, provider_opts: model_capabilities.ResolvedProviderOptions) void {
    const reasoning_outcome = if (provider_opts.reasoning != null)
        "selected"
    else if (effort.isDefault())
        "default"
    else
        "unsupported_or_missing";
    const fast_outcome = if (provider_opts.fast)
        "selected"
    else if (!fast_mode)
        "default"
    else
        "unsupported_or_missing";
    debug_trace.eventf(
        "gateway",
        "provider_options",
        ctx,
        "model={s} fast_mode={s} effort={s} reasoning={s} fast={s}",
        .{
            model,
            if (fast_mode) "true" else "false",
            effort.label(),
            reasoning_outcome,
            fast_outcome,
        },
    );
}

pub fn toolExecutionResultKind(result: ToolExecutionResult) []const u8 {
    if (result.status == .failure) return "error";
    if (result.diff_entry != null) return "diff";
    return "model_output";
}

test "gateway call metrics retain provider terminal stop reason" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    recordGatewayCallMetric("test/model", 0, 200, 12, 3, 4, 1, 1, 0, "", "stop");
    recordGatewayCallMetric("test/model", 0, 200, 12, 3, 4, 1, 2, 0, "", "length");
    recordGatewayCallMetric("test/model", 0, 200, 12, 3, 4, 1, 3, 0, "", "missing_provider_finish");

    var calls: [diagnostics.network_ring_capacity]diagnostics.NetworkCall = undefined;
    const count = diagnostics.snapshotNetworkCalls(&calls);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("stop", calls[0].terminalStopReason());
    try std.testing.expectEqualStrings("length", calls[1].terminalStopReason());
    try std.testing.expectEqualStrings("missing_provider_finish", calls[2].terminalStopReason());
}

test "turn token progress counts only the submitted prompt once" {
    var accumulator = TurnSummaryAccumulator.init(0, "open it for me");
    accumulator.prepareTokenRequest();
    _ = accumulator.reconcileTokenRequest(.{
        .input_tokens = 16_000,
        .output_tokens = 5,
    }, true);

    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = 4,
        .output_tokens = 5,
        .input_exact = false,
        .output_exact = false,
    }, accumulator.tokenProgress());
}

test "turn token progress advances while the model composes a tool call" {
    var accumulator = TurnSummaryAccumulator.init(0, "");
    accumulator.prepareTokenRequest();
    _ = accumulator.consumeContent("writing the file now ");
    const before_tool_input = accumulator.tokenProgress().output_tokens;

    try std.testing.expectEqual(TokenProgressUpdate.changed, accumulator.consumeToolInput(
        "{\"path\":\"docs/big.md\",\"content\":\"line one line two line three\"",
    ));
    try std.testing.expect(accumulator.tokenProgress().output_tokens > before_tool_input);

    _ = accumulator.reconcileTokenRequest(.{ .output_tokens = 4_096 }, false);
    try std.testing.expectEqual(@as(u64, 4_096), accumulator.tokenProgress().output_tokens);
    try std.testing.expect(accumulator.tokenProgress().output_exact);
}

test "turn token progress honors aggregate completion ambiguity" {
    var accumulator = TurnSummaryAccumulator.init(0, "abcdefgh");
    accumulator.prepareTokenRequest();
    _ = accumulator.reconcileTokenRequest(.{
        .input_tokens = 100,
        .output_tokens = 20,
    }, true);

    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = 2,
        .output_tokens = 20,
        .input_exact = false,
        .output_exact = false,
    }, accumulator.tokenProgress());
}

test "turn token progress uses exact provider output on unambiguous completion" {
    var accumulator = TurnSummaryAccumulator.init(0, "abcdefgh");
    accumulator.prepareTokenRequest();
    _ = accumulator.reconcileTokenRequest(.{
        .input_tokens = 100,
        .output_tokens = 20,
    }, false);

    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = 2,
        .output_tokens = 20,
        .input_exact = false,
    }, accumulator.tokenProgress());
}

test "turn token progress accumulates output steps while counting submitted input once" {
    var accumulator = TurnSummaryAccumulator.init(0, "submitted prompt");

    accumulator.prepareTokenRequest();
    _ = accumulator.reconcileTokenRequest(.{
        .input_tokens = 10,
        .output_tokens = 5,
    }, false);

    accumulator.prepareTokenRequest();
    _ = accumulator.reconcileTokenRequest(.{
        .input_tokens = 20,
        .output_tokens = 7,
    }, false);

    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = 5,
        .output_tokens = 12,
        .input_exact = false,
    }, accumulator.tokenProgress());
    try std.testing.expectEqual(accumulator.tokenProgress(), accumulator.finish().token_progress);
}

test "turn token progress keeps missing usage and terminal delivery approximate" {
    var accumulator = TurnSummaryAccumulator.init(0, "abcdefgh");
    accumulator.prepareTokenRequest();
    _ = accumulator.consumeReasoning("reasoning");
    _ = accumulator.consumeContent("answer");
    _ = accumulator.reconcileTokenRequest(.{ .input_tokens = 40 }, false);

    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = 2,
        .output_tokens = 5,
        .input_exact = false,
        .output_exact = false,
    }, accumulator.tokenProgress());

    accumulator.prepareTokenRequest();
    _ = accumulator.finishTokenRequestWithoutUsage(true);

    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = 2,
        .output_tokens = 5,
        .input_exact = false,
        .output_exact = false,
    }, accumulator.tokenProgress());
}

test "turn token progress discards a definitely unsent request" {
    var accumulator = TurnSummaryAccumulator.init(0, "abcdefgh");
    accumulator.prepareTokenRequest();
    try std.testing.expect(!accumulator.tokenProgress().output_exact);

    try std.testing.expectEqual(
        TokenProgressUpdate.changed,
        accumulator.finishTokenRequestWithoutUsage(false),
    );
    try std.testing.expectEqual(types.TurnTokenProgress{
        .input_tokens = 2,
        .input_exact = false,
    }, accumulator.tokenProgress());
}
