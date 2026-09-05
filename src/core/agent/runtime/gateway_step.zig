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
    // Only the owned result escapes. HTTP and parser scratch is released after
    // every attempt, including transport failure and cancellation.
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    const request_alloc = scratch.allocator();
    var result = provider.stream(request_alloc, request) catch |err| {
        runtime_telemetry.recordGatewayCallMetric(request.model, started_at_ms, 0, 0, 0, 0, request.trace_ctx.turn_id, request.trace_ctx.step_id, request.trace_ctx.subagent_id, @errorName(err), "");
        if (admission.observation) |observation| try observation.fail(
            if (request.delivery.load() == .possibly_sent) .ambiguous_delivery else .unbilled,
        );
        return err;
    };
    defer result.deinit(request_alloc);
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
    return switch (result) {
        .completed => |value| if (value.ownership == .borrowed) result else try result.dupe(alloc),
        .failed => |value| if (value.ownership == .borrowed) result else try result.dupe(alloc),
    };
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

test "gateway request scratch is released across success failure cancellation and retries" {
    const Fake = struct {
        mode: usize = 0,

        fn stream(raw: ?*anyopaque, alloc: Allocator, request: agent_stream_provider.ModelRequest) !StreamResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try request.admission.admit();
            const payload = try alloc.alloc(u8, 64 * 1024);
            defer alloc.free(payload);
            @memset(payload, 'x');
            const content = try alloc.dupe(u8, "owned response");
            if (self.mode == 1 or self.mode == 2) {
                defer alloc.free(content);
                return if (self.mode == 1) error.ConnectionResetByPeer else error.Cancelled;
            }
            if (self.mode == 3) return .{ .failed = .{ .kind = .server_error, .detail = content, .ownership = .owned } };
            return .{ .completed = .{ .completion = .{ .content = content }, .ownership = .owned } };
        }

        fn emit(_: *anyopaque, _: agent_stream_provider.Event) void {}
    };
    var turn = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer turn.deinit();
    var fake: Fake = .{};
    var cancel: std.atomic.Value(bool) = .init(false);
    for (0..1000) |attempt| {
        fake.mode = attempt % 4;
        var delivery = DeliveryCertainty.init();
        var evidence: AttemptEvidence = .{};
        const result = streamModelCompletion(.{ .context = &fake, .stream_fn = Fake.stream }, turn.allocator(), .{
            .credential = .{ .direct = .{ .secret_bytes = "fixture-key", .source = .ai_gateway_api_key } },
            .model = "fixture-model",
            .retry_count = 1,
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &evidence,
            .events = .{ .context = &fake, .emit_fn = Fake.emit },
            .cancel_flag = &cancel,
            .provider_attempt_owner = .agent,
        }, null, std.testing.allocator);
        if (fake.mode == 1) {
            try std.testing.expectError(error.ConnectionResetByPeer, result);
        } else if (fake.mode == 2) {
            try std.testing.expectError(error.Cancelled, result);
        } else {
            var owned = try result;
            defer owned.deinit(turn.allocator());
            const content = switch (owned) {
                .completed => |completed| completed.completion.content.?,
                .failed => |failure| failure.detail.?,
            };
            try std.testing.expectEqualStrings("owned response", content);
        }
        try std.testing.expect(turn.queryCapacity() < 128 * 1024);
    }
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

pub fn projectToolImageMessages(alloc: Allocator, messages: []const types.ChatMessage, supports_images: bool, text_limit: usize) ![]const types.ChatMessage {
    if (supports_images) return messages;
    const has_images = for (messages) |message| {
        if (message.tool_result_memory) |memory| if (memory.tool_images.len > 0 or memory.tool_image_handle != null) break true;
    } else false;
    if (!has_images) return messages;
    const projected = try alloc.dupe(types.ChatMessage, messages);
    for (projected) |*message| {
        if (message.tool_result_memory) |*memory| {
            if (memory.tool_images.len == 0 and memory.tool_image_handle == null) continue;
            memory.tool_images = &.{};
            const notice = "[Tool images were retained but not sent because this model does not support image input.]\n";
            const content = message.content orelse "";
            const keep = @import("../../config/context_limits.zig").utf8PrefixLength(content, text_limit -| notice.len);
            memory.truncated = memory.truncated or keep < content.len;
            message.content = try std.mem.concat(alloc, u8, &.{ notice[0..@min(notice.len, text_limit)], content[0..keep] });
        }
    }
    return projected;
}

pub fn snapshotDynamicTools(alloc: Allocator, deps: *const @import("deps.zig").AgentRuntimeDeps, selected: *std.ArrayList(agent_stream_provider.DynamicFunctionTool)) ![]const agent_stream_provider.DynamicFunctionTool {
    var offered: std.ArrayList(agent_stream_provider.DynamicFunctionTool) = .empty;
    errdefer offered.deinit(alloc);
    const count = selected.items.len;
    for (0..count) |index| {
        const tool = selected.items[index];
        if (tool.mcp_binding) |binding| {
            const snapshot = deps.snapshot_mcp_definition orelse continue;
            switch (try snapshot(deps.ctx, alloc, tool.name, binding)) {
                .current => {},
                .unavailable => continue,
                .updated => |definition| {
                    if (!std.mem.eql(u8, definition.name, tool.name) or definition.mcp_binding == null) return error.InvalidToolSchema;
                    try recordSelectedDynamicTool(alloc, selected, definition);
                    try offered.append(alloc, selected.items[index]);
                    continue;
                },
            }
        }
        try offered.append(alloc, tool);
    }
    return offered.toOwnedSlice(alloc);
}

pub fn recordSelectedDynamicTools(alloc: Allocator, tools: *std.ArrayList(agent_stream_provider.DynamicFunctionTool), execution: ToolExecutionResult) !void {
    for (execution.retired_dynamic_tool_names) |name| {
        for (tools.items, 0..) |tool, index| {
            if (std.mem.eql(u8, name, tool.name)) {
                _ = tools.orderedRemove(index);
                break;
            }
        }
    }
    for (execution.selected_dynamic_tools) |selected| try recordSelectedDynamicTool(alloc, tools, selected);
}

fn recordSelectedDynamicTool(alloc: Allocator, tools: *std.ArrayList(agent_stream_provider.DynamicFunctionTool), selected: @import("../../tooling/tool_mcp_runtime.zig").SelectedTool) !void {
    const name = selected.name;
    const schema_json = selected.schema_json;
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
    for (tools.items) |*existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            existing.description = description.string;
            existing.input_schema = input_schema;
            existing.mcp_binding = selected.mcp_binding;
            return;
        }
    }
    try tools.append(alloc, .{ .name = name, .description = description.string, .input_schema = input_schema, .mcp_binding = selected.mcp_binding });
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

test "selected MCP schemas replace old definitions without duplicate names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tools: std.ArrayList(agent_stream_provider.DynamicFunctionTool) = .empty;
    try recordSelectedDynamicTools(alloc, &tools, .{
        .model_output = "selected",
        .selected_dynamic_tools = &.{
            .{ .name = "mcp_fixture_lookup", .schema_json =
            \\{"name":"mcp_fixture_lookup","description":"Lookup","inputSchema":{"type":"object","properties":{"old_value":{"type":"string"}}}}
            },
            .{ .name = "mcp_fixture_other", .schema_json =
            \\{"name":"mcp_fixture_other","description":"Other","inputSchema":{"type":"object"}}
            },
        },
    });
    try recordSelectedDynamicTools(alloc, &tools, .{
        .model_output = "selected",
        .selected_dynamic_tools = &.{.{ .name = "mcp_fixture_lookup", .schema_json =
        \\{"name":"mcp_fixture_lookup","description":"Updated lookup","inputSchema":{"type":"object","properties":{"new_value":{"type":"string"}}}}
        }},
    });
    try std.testing.expectEqual(@as(usize, 2), tools.items.len);
    try std.testing.expectEqualStrings("Updated lookup", tools.items[0].description);
    const properties = tools.items[0].input_schema.object.get("properties").?.object;
    try std.testing.expect(properties.contains("new_value"));
    try std.testing.expect(!properties.contains("old_value"));
}
