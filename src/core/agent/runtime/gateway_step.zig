const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const types = @import("../../shared/types.zig");
const session_usage = @import("../../session/session_usage.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const io_mod = @import("../../shared/io.zig");
const runtime_telemetry = @import("telemetry.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const TraceContext = debug_trace.TraceContext;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;
pub const AttemptEvidence = agent_stream_provider.AttemptEvidence;

pub const StreamResult = agent_stream_provider.Result;

const InvocationAdmission = struct {
    usage: ?*session_usage.Usage,
    attempt_evidence: *AttemptEvidence,
    trace_ctx: TraceContext,
    model: []const u8,
    caller_admission: agent_stream_provider.Admission,
    observation: ?session_usage.InvocationObservation = null,

    fn admit(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.observation != null) return error.ProviderAdmissionRepeated;
        self.observation = try session_usage.InvocationObservation.begin(self.usage);
        if (self.caller_admission.admit_fn != null) {
            try self.caller_admission.admit();
        }
        self.attempt_evidence.provider_admitted = true;
        debug_trace.eventf(
            "agent",
            "provider_admitted",
            self.trace_ctx,
            "model={s}",
            .{self.model},
        );
    }
};

pub fn streamModelCompletion(
    provider: agent_stream_provider.Provider,
    alloc: Allocator,
    request_value: agent_stream_provider.ModelRequest,
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,
) !StreamResult {
    if (request_value.cancel_flag.load(.seq_cst)) {
        return agent_stream_provider.failResult(error.Cancelled);
    }
    const started_at_ms = io_mod.milliTimestamp();
    var admission = InvocationAdmission{
        .usage = usage,
        .attempt_evidence = request_value.attempt_evidence,
        .trace_ctx = request_value.trace_ctx,
        .model = request_value.model,
        .caller_admission = request_value.admission,
    };
    var request = request_value;
    request.admission = .{ .context = &admission, .admit_fn = InvocationAdmission.admit };
    var result = provider.stream(alloc, request) catch |err| {
        runtime_telemetry.recordGatewayCallMetric(request.model, started_at_ms, 0, 0, 0, 0, request.trace_ctx.turn_id, request.trace_ctx.step_id, request.trace_ctx.subagent_id, @errorName(err), "");
        if (admission.observation) |observation| try observation.fail(
            if (request.delivery.load() == .possibly_sent) .ambiguous_delivery else .unbilled,
        );
        return err;
    };
    errdefer result.deinit(alloc);
    const observation = admission.observation orelse
        return agent_stream_provider.failResult(error.ProviderAdmissionMissing);

    recordProviderResultMetric(request.model, started_at_ms, result, request.trace_ctx);
    switch (result) {
        .failed => try observation.fail(.unbilled),
        .completed => |completed| {
            try observation.complete(
                usage_allocator,
                completed.completion,
                completed.usage,
            );
            if (comptime @import("builtin").os.tag != .wasi) {
                if (std.meta.activeTag(completed.usage) == .deferred) if (usage) |ledger| {
                    if (request.credential.secret()) |credential| {
                        ledger.startDeferredReconciliation(
                            usage_allocator,
                            completed.usage.deferred,
                            credential,
                        );
                    } else if (request.credential.credentialSource() == .host_managed) {
                        ledger.startHostManagedDeferredReconciliation(
                            usage_allocator,
                            completed.usage.deferred,
                        );
                    }
                };
            }
        },
    }
    return result;
}

fn recordProviderResultMetric(
    model: []const u8,
    started_at_ms: i64,
    result: agent_stream_provider.Result,
    trace_ctx: TraceContext,
) void {
    const completion: types.ModelCompletion = switch (result) {
        .completed => |value| value.completion,
        .failed => .{},
    };
    const failure = switch (result) {
        .completed => null,
        .failed => |value| value,
    };
    var response_bytes: u64 = 0;
    if (completion.content) |content| response_bytes += content.len;
    if (completion.provider_state_json) |state| response_bytes += state.len;
    for (completion.tool_calls) |call| {
        response_bytes += call.id.len + call.name.len + call.arguments_json.len;
        if (call.provider_result) |pr| response_bytes += pr.len;
    }
    if (failure) |value| {
        if (value.detail) |detail| response_bytes += detail.len;
    }
    const truncated_bytes: u32 = @intCast(@min(response_bytes, std.math.maxInt(u32)));
    const input_tokens = clampTokenCount(completion.usage.input_tokens);
    const output_tokens = clampTokenCount(completion.usage.output_tokens);
    const terminal_stop_reason = if (completion.finish_reason) |reason| reason.label() else "";

    runtime_telemetry.recordGatewayCallMetricWithDiagnostics(
        model,
        started_at_ms,
        if (failure) |value| failureMetricCode(value.kind) else 200,
        truncated_bytes,
        input_tokens,
        output_tokens,
        trace_ctx.turn_id,
        trace_ctx.step_id,
        trace_ctx.subagent_id,
        "",
        terminal_stop_reason,
        .{
            .schema = if (failure) |value| value.diagnostics.schema orelse "" else "",
            .request_shape = if (failure) |value| value.diagnostics.request_shape orelse "" else "",
        },
    );
}

fn failureMetricCode(kind: agent_stream_provider.FailureKind) u16 {
    return switch (kind) {
        .invalid_request => 400,
        .unauthorized => 401,
        .forbidden => 403,
        .request_too_large => 413,
        .rate_limited => 429,
        .server_error => 500,
        .bad_gateway => 502,
        .unavailable => 503,
        .gateway_timeout => 504,
        .provider_error => 520,
    };
}

fn clampTokenCount(value: ?u64) u32 {
    const t = value orelse return 0;
    return @intCast(@min(t, std.math.maxInt(u32)));
}

pub const VisionToolMode = agent_stream_provider.VisionMode;

pub fn recordSelectedDynamicTool(
    alloc: Allocator,
    names: *std.ArrayList([]const u8),
    tools: *std.ArrayList(agent_stream_provider.DynamicFunctionTool),
    execution: ToolExecutionResult,
) !void {
    const name = execution.selected_dynamic_tool_name orelse return;
    const schema_json = execution.selected_dynamic_tool_schema_json orelse return;
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    const schema = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        schema_json,
        .{},
    );
    if (schema != .object) return error.InvalidToolSchema;
    const schema_name = schema.object.get("name") orelse return error.InvalidToolSchema;
    const description = schema.object.get("description") orelse return error.InvalidToolSchema;
    const input_schema = schema.object.get("inputSchema") orelse return error.InvalidToolSchema;
    if (schema_name != .string or description != .string or input_schema != .object or
        !std.mem.eql(u8, schema_name.string, name))
    {
        return error.InvalidToolSchema;
    }
    try names.append(alloc, name);
    try tools.append(alloc, .{
        .name = name,
        .description = description.string,
        .input_schema = input_schema,
    });
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

test "provider preflight failure does not reserve usage" {
    const Callbacks = struct {
        fn event(_: *anyopaque, _: agent_stream_provider.Event) void {}
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var callback_ctx: u8 = 0;
    const result = streamModelCompletion(
        agent_stream_provider.unavailable_provider,
        alloc,
        .{
            .credential = .{ .direct = .{ .secret_bytes = "test-key" } },
            .model = "test/model",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &callback_ctx, .emit_fn = Callbacks.event },
            .cancel_flag = &cancel_flag,
        },
        &usage,
        alloc,
    );
    if (result) |_| return error.TestExpectedGatewayFailure else |_| {}

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 0), snapshot.settled_through_sequence);
}

test "caller admission publishes before provider attempt is admitted" {
    const CallerAdmission = struct {
        calls: usize = 0,
        attempt_evidence: *AttemptEvidence,

        fn admit(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(!self.attempt_evidence.provider_admitted);
            self.calls += 1;
        }
    };
    const Provider = struct {
        opens: usize = 0,

        fn stream(
            raw: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) anyerror!agent_stream_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try request.admission.admit();
            self.opens += 1;
            return .{ .completed = .{ .completion = .{ .finish_reason = .stop } } };
        }
    };
    const Callbacks = struct {
        fn event(_: *anyopaque, _: agent_stream_provider.Event) void {}
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var caller_admission = CallerAdmission{ .attempt_evidence = &attempt_evidence };
    var provider: Provider = .{};
    var callback_ctx: u8 = 0;

    var result = try streamModelCompletion(
        .{ .context = &provider, .stream_fn = Provider.stream },
        alloc,
        .{
            .credential = .{ .direct = .{ .secret_bytes = "test-key" } },
            .model = "test/model",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &callback_ctx, .emit_fn = Callbacks.event },
            .admission = .{ .context = &caller_admission, .admit_fn = CallerAdmission.admit },
            .cancel_flag = &cancel_flag,
        },
        &usage,
        alloc,
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), caller_admission.calls);
    try std.testing.expectEqual(@as(usize, 1), provider.opens);
    try std.testing.expect(attempt_evidence.provider_admitted);
}

test "caller admission failure settles usage and prevents request open" {
    const CallerAdmission = struct {
        calls: usize = 0,

        fn admit(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return error.InFlightPublicationFailed;
        }
    };
    const Provider = struct {
        opens: usize = 0,

        fn stream(
            raw: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) anyerror!agent_stream_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try request.admission.admit();
            self.opens += 1;
            return .{ .completed = .{ .completion = .{ .finish_reason = .stop } } };
        }
    };
    const Callbacks = struct {
        fn event(_: *anyopaque, _: agent_stream_provider.Event) void {}
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var caller_admission: CallerAdmission = .{};
    var provider: Provider = .{};
    var callback_ctx: u8 = 0;

    try std.testing.expectError(
        error.InFlightPublicationFailed,
        streamModelCompletion(
            .{ .context = &provider, .stream_fn = Provider.stream },
            alloc,
            .{
                .credential = .{ .direct = .{ .secret_bytes = "test-key" } },
                .model = "test/model",
                .retry_count = 1,
                .messages = &.{},
                .tool_choice = .auto,
                .provider_options = .{},
                .trace_ctx = .{},
                .content_capture_limit = null,
                .delivery = &delivery,
                .attempt_evidence = &attempt_evidence,
                .events = .{ .context = &callback_ctx, .emit_fn = Callbacks.event },
                .admission = .{ .context = &caller_admission, .admit_fn = CallerAdmission.admit },
                .cancel_flag = &cancel_flag,
            },
            &usage,
            alloc,
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), caller_admission.calls);
    try std.testing.expectEqual(@as(usize, 0), provider.opens);
    try std.testing.expect(!attempt_evidence.provider_admitted);
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
            request: agent_stream_provider.ModelRequest,
        ) anyerror!agent_stream_provider.Result {
            try request.admission.admit();
            request.delivery.markPossiblySent();
            return error.ConnectionResetByPeer;
        }
    };
    const Callbacks = struct {
        fn event(_: *anyopaque, _: agent_stream_provider.Event) void {}
    };

    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var callback_ctx: u8 = 0;

    const result = streamModelCompletion(
        .{ .stream_fn = Gateway.stream },
        alloc,
        .{
            .credential = .{ .direct = .{ .secret_bytes = "test-key" } },
            .model = "test/model",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &callback_ctx, .emit_fn = Callbacks.event },
            .cancel_flag = &cancel_flag,
        },
        &usage,
        alloc,
    );
    if (result) |_| return error.TestExpectedGatewayFailure else |_| {}

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.incomplete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "provider-local exact usage reaches session accounting" {
    const LocalProvider = struct {
        calls: usize = 0,

        fn stream(
            raw: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) anyerror!agent_stream_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            try request.admission.admit();
            request.delivery.markPossiblySent();
            return .{ .completed = .{
                .completion = .{
                    .generation_id = "resp_provider_local",
                    .billing = .{
                        .created_at_ms = 1,
                        .model = "codex/gpt-test",
                        .total_cost = 0,
                        .input_tokens = 3,
                        .output_tokens = 1,
                        .cache_read_tokens = 0,
                        .cache_write_tokens = 0,
                        .reasoning_tokens = null,
                        .billable_web_search_calls = 0,
                    },
                    .finish_reason = .stop,
                    .usage = .{ .input_tokens = 3, .output_tokens = 1 },
                },
                .usage = .{ .exact = .codex },
            } };
        }
    };
    const Callbacks = struct {
        fn event(_: *anyopaque, _: agent_stream_provider.Event) void {}
    };

    const alloc = std.testing.allocator;
    var local_provider: LocalProvider = .{};
    const provider = agent_stream_provider.Provider{
        .context = &local_provider,
        .stream_fn = LocalProvider.stream,
    };
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var callback_ctx: u8 = 0;

    var delivery = DeliveryCertainty.init();
    var attempt_evidence: AttemptEvidence = .{};
    var result = try streamModelCompletion(
        provider,
        alloc,
        .{
            .credential = .{ .direct = .{
                .secret_bytes = "subscription-token",
                .source = .chatgpt_subscription,
                .account_id = "acct_test",
            } },
            .session_id = "session-test",
            .model = "gpt-test",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &callback_ctx, .emit_fn = Callbacks.event },
            .cancel_flag = &cancel_flag,
            .provider_attempt_owner = .agent,
        },
        &usage,
        alloc,
    );
    defer result.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(result) == .completed);

    try std.testing.expectEqual(@as(usize, 1), local_provider.calls);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(session_usage.Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 2), snapshot.next_sequence);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
    try std.testing.expectEqual(@as(u64, 3), snapshot.input_tokens);
    try std.testing.expectEqual(@as(u64, 1), snapshot.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1), snapshot.request_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.models.len);
    try std.testing.expectEqualStrings("codex/gpt-test", snapshot.models[0].model);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.publication_backlog.len);
}
