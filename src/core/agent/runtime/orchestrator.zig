const std = @import("std");
const builtin = @import("builtin");
const agent_steps = @import("../../config/agent_steps.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const model_provider = @import("../../config/model_provider.zig");
const types = @import("../../shared/types.zig");
const worker_runtime = @import("../worker_runtime.zig");
const session_runtime = @import("../../session/session.zig");
const session_codec = @import("../../session/session_codec.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const gateway_error_format = @import("../../shared/gateway_error_format.zig");
const mem_utils = @import("../../shared/mem_utils.zig");
const text_utils = @import("../../shared/text_utils.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const io_mod = @import("../../shared/io.zig");
const host_target = @import("../../hosts/target.zig");
const secret = @import("../../auth/secret.zig");
const credentials = @import("../../auth/credentials.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const tooling_tool_admission = @import("../../tooling/tool_admission.zig");
const hooks = @import("../../hooks/hooks.zig");
const command_contract = @import("../../execution/command_contract.zig");
const command_environment = @import("../../execution/command_environment.zig");
const context_contract = @import("../../workspace/context_contract.zig");
const tool_preparation = @import("../tool_preparation.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const auto_classifier_context = @import("../../permissions/auto_classifier_context.zig");
const ask_user_question = @import("../../../tools/agent/ask_user_question.zig");

const runtime_config = @import("config.zig");
const runtime_finalization = @import("finalization.zig");
const runtime_deps = @import("deps.zig");
const runtime_lifecycle = @import("lifecycle.zig");
const runtime_prompt_context = @import("prompt_context.zig");
const runtime_telemetry = @import("telemetry.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");
const runtime_gateway_step = @import("gateway_step.zig");
const runtime_vision_contracts = @import("vision_contracts.zig");
const image_attachments = @import("../../images/image_attachments.zig");
const runtime_assistant_stream = @import("assistant_stream.zig");
const runtime_tool_presentation = @import("tool_presentation.zig");
const runtime_execution_memory = @import("execution_memory.zig");
const runtime_stop_policy = @import("stop_policy.zig");
const runtime_tool_admission = @import("tool_admission.zig");
const runtime_interruption = @import("interruption.zig");
const runtime_parallel_execution = @import("parallel_execution.zig");
const runtime_tool_batch = @import("tool_batch.zig");
const model_response_recovery = @import("model_response_recovery.zig");

const Allocator = std.mem.Allocator;

const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const ToolCall = types.ToolCall;
const QueuedPrompt = worker_runtime.QueuedPrompt;
const TraceContext = debug_trace.TraceContext;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const CredentialRefreshMode = runtime_deps.CredentialRefreshMode;

const http_error_detail_max_bytes: usize = 4096;
const assistant_prefill_recovery_prompt =
    "Continue from the preceding tool result.";
const repeated_terminal_validation_notice =
    "Repeated terminal validation failures stopped the tool loop. The invalid terminal calls were not executed and produced no terminal effect.";
const repeated_malformed_arguments_notice =
    "Repeated malformed tool arguments stopped the agent loop. The invalid calls were not executed. Continue with a follow-up prompt if needed.";
const Config = runtime_config.Config;
const LifecycleContext = runtime_lifecycle.LifecycleContext;
const PreparedToolCall = runtime_lifecycle.PreparedToolCall;
const TurnFinalizationGuard = runtime_finalization.TurnFinalizationGuard;
const PromptFinishTrace = runtime_finalization.PromptFinishTrace;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

fn terminal_request_schema_advertised(
    alloc: Allocator,
    tools_json: []const u8,
) Allocator.Error!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return false;

    for (parsed.value.array.items) |tool_value| {
        if (tool_value != .object) continue;
        const name = tool_value.object.get("name") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, "terminal")) continue;
        const input_schema = tool_value.object.get("inputSchema") orelse return false;
        if (input_schema != .object) return false;
        const input_type = input_schema.object.get("type") orelse return false;
        if (input_type != .string or !std.mem.eql(u8, input_type.string, "object")) return false;
        const properties = input_schema.object.get("properties") orelse return false;
        if (properties != .object or properties.object.count() != 1) return false;
        const request = properties.object.get("request") orelse return false;
        if (request != .object) return false;
        const alternatives = request.object.get("oneOf") orelse return false;
        if (alternatives != .array or alternatives.array.items.len == 0) return false;
        const required = input_schema.object.get("required") orelse return false;
        if (required != .array or required.array.items.len != 1) return false;
        const required_name = required.array.items[0];
        if (required_name != .string or !std.mem.eql(u8, required_name.string, "request")) return false;
        const additional_properties = input_schema.object.get("additionalProperties") orelse return false;
        return additional_properties == .bool and !additional_properties.bool;
    }
    return false;
}

fn terminal_request_normalization_eligible(
    base_nested_terminal_advertised: bool,
    vision_mode: runtime_gateway_step.VisionToolMode,
) bool {
    return base_nested_terminal_advertised and vision_mode != .required;
}

fn normalized_terminal_request_arguments(
    alloc: Allocator,
    arguments_json: []const u8,
) Allocator.Error!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 1) return null;
    const request = parsed.value.object.get("request") orelse return null;
    if (request != .object) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(request, .{}, &out.writer) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn normalize_terminal_request_tool_calls(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    attempt_eligible: bool,
    source: []const ToolCall,
) Allocator.Error![]const ToolCall {
    if (!attempt_eligible) return source;

    var normalized: ?[]ToolCall = null;
    errdefer if (normalized) |calls| {
        for (calls, source) |call, original| {
            if (call.arguments_json.ptr != original.arguments_json.ptr) {
                alloc.free(@constCast(call.arguments_json));
            }
        }
        alloc.free(calls);
    };

    for (source, 0..) |call, index| {
        if (call.argument_integrity != .valid) continue;
        const tool = registry.lookup(call.name) orelse continue;
        if (tool.executor_kind != .terminal) continue;
        const arguments_json = try normalized_terminal_request_arguments(
            alloc,
            call.arguments_json,
        ) orelse continue;
        if (normalized == null) {
            normalized = alloc.dupe(ToolCall, source) catch |err| {
                alloc.free(arguments_json);
                return err;
            };
        }
        normalized.?[index].arguments_json = arguments_json;
    }
    return normalized orelse source;
}

test "terminal request normalization follows effective attempt advertisement" {
    const nested_tools_json =
        "[{\"type\":\"function\",\"name\":\"terminal\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"request\":{\"oneOf\":[{\"type\":\"object\"}]}},\"required\":[\"request\"],\"additionalProperties\":false}}]";
    const flat_tools_json =
        "[{\"type\":\"function\",\"name\":\"terminal\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"}},\"required\":[\"action\"],\"additionalProperties\":false}}]";

    try std.testing.expect(try terminal_request_schema_advertised(std.testing.allocator, nested_tools_json));
    try std.testing.expect(!try terminal_request_schema_advertised(std.testing.allocator, flat_tools_json));
    try std.testing.expect(!try terminal_request_schema_advertised(std.testing.allocator, "[]"));
    try std.testing.expect(!try terminal_request_schema_advertised(std.testing.allocator, "{"));
    try std.testing.expect(terminal_request_normalization_eligible(true, .unavailable));
    try std.testing.expect(terminal_request_normalization_eligible(true, .optional));
    try std.testing.expect(!terminal_request_normalization_eligible(true, .required));
    try std.testing.expect(!terminal_request_normalization_eligible(false, .unavailable));
}

test "terminal request normalization unwraps only exact eligible native calls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const native_terminal = tool_dispatch.Tool{
        .name = "terminal",
        .description = "terminal",
        .gateway_schema = .{ .name = "terminal", .description = "terminal" },
        .executor_kind = .terminal,
        .decode = undefined,
        .call = undefined,
        .reads_only_fn = undefined,
        .irreversible_fn = undefined,
    };
    var browser_terminal = native_terminal;
    browser_terminal.executor_kind = .run_command;
    const native_tools = [_]tool_dispatch.Tool{native_terminal};
    const browser_tools = [_]tool_dispatch.Tool{browser_terminal};
    const native_registry = tool_dispatch.Registry{ .tools = &native_tools };
    const browser_registry = tool_dispatch.Registry{ .tools = &browser_tools };

    const wrapped = "{\"request\":{\"action\":\"exec\",\"command\":\"printf ok\"}}";
    const calls = [_]ToolCall{
        .{
            .id = "terminal-call",
            .name = "terminal",
            .arguments_json = wrapped,
            .provisional_id = "provisional-terminal",
            .provider_result = "provider-result",
            .provenance = .provider_executed,
        },
        .{
            .id = "other-call",
            .name = "read_file",
            .arguments_json = "{\"path\":\"README.md\"}",
        },
    };
    const normalized = try normalize_terminal_request_tool_calls(
        arena,
        native_registry,
        true,
        &calls,
    );
    try std.testing.expect(normalized.ptr != calls[0..].ptr);
    try std.testing.expectEqualStrings(
        "{\"action\":\"exec\",\"command\":\"printf ok\"}",
        normalized[0].arguments_json,
    );
    try std.testing.expectEqualStrings(calls[0].id, normalized[0].id);
    try std.testing.expectEqualStrings(calls[0].provisional_id.?, normalized[0].provisional_id.?);
    try std.testing.expectEqualStrings(calls[0].provider_result.?, normalized[0].provider_result.?);
    try std.testing.expectEqual(calls[0].provenance, normalized[0].provenance);
    try std.testing.expectEqualStrings(calls[1].arguments_json, normalized[1].arguments_json);

    const ineligible = try normalize_terminal_request_tool_calls(arena, native_registry, false, &calls);
    try std.testing.expectEqual(calls[0..].ptr, ineligible.ptr);
    try std.testing.expectEqual(wrapped.ptr, ineligible[0].arguments_json.ptr);

    const browser = try normalize_terminal_request_tool_calls(arena, browser_registry, true, &calls);
    try std.testing.expectEqual(calls[0..].ptr, browser.ptr);
    try std.testing.expectEqual(wrapped.ptr, browser[0].arguments_json.ptr);

    const non_exact_calls = [_]ToolCall{.{
        .id = "non-exact",
        .name = "terminal",
        .arguments_json = "{\"request\":{\"action\":\"exec\",\"command\":\"true\"},\"extra\":true}",
    }};
    const non_exact = try normalize_terminal_request_tool_calls(arena, native_registry, true, &non_exact_calls);
    try std.testing.expectEqual(non_exact_calls[0..].ptr, non_exact.ptr);

    const malformed_calls = [_]ToolCall{.{
        .id = "malformed",
        .name = "terminal",
        .arguments_json = "{",
        .argument_integrity = .malformed_json,
    }};
    const malformed = try normalize_terminal_request_tool_calls(arena, native_registry, true, &malformed_calls);
    try std.testing.expectEqual(malformed_calls[0..].ptr, malformed.ptr);
}

fn check_terminal_request_normalization_allocation_failures(alloc: Allocator) !void {
    const nested_tools_json =
        "[{\"type\":\"function\",\"name\":\"terminal\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"request\":{\"oneOf\":[{\"type\":\"object\"}]}},\"required\":[\"request\"],\"additionalProperties\":false}}]";
    if (!try terminal_request_schema_advertised(alloc, nested_tools_json)) {
        return error.TestUnexpectedResult;
    }
    const native_terminal = tool_dispatch.Tool{
        .name = "terminal",
        .description = "terminal",
        .gateway_schema = .{ .name = "terminal", .description = "terminal" },
        .executor_kind = .terminal,
        .decode = undefined,
        .call = undefined,
        .reads_only_fn = undefined,
        .irreversible_fn = undefined,
    };
    const tools = [_]tool_dispatch.Tool{native_terminal};
    const registry = tool_dispatch.Registry{ .tools = &tools };
    const source = [_]ToolCall{
        .{ .id = "one", .name = "terminal", .arguments_json = "{\"request\":{\"action\":\"exec\",\"command\":\"true\"}}" },
        .{ .id = "two", .name = "terminal", .arguments_json = "{\"request\":{\"action\":\"start\"}}" },
    };
    const normalized = try normalize_terminal_request_tool_calls(alloc, registry, true, &source);
    if (normalized.ptr == source[0..].ptr) return error.TestUnexpectedResult;
    defer {
        for (normalized, source) |call, original| {
            if (call.arguments_json.ptr != original.arguments_json.ptr) {
                alloc.free(@constCast(call.arguments_json));
            }
        }
        alloc.free(@constCast(normalized));
    }
    try std.testing.expectEqualStrings(
        "{\"action\":\"exec\",\"command\":\"true\"}",
        normalized[0].arguments_json,
    );
    try std.testing.expectEqualStrings(
        "{\"action\":\"start\"}",
        normalized[1].arguments_json,
    );
}

test "terminal request normalization cleans every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_terminal_request_normalization_allocation_failures,
        .{},
    );
}

fn resolveLiveToolAuthority(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    workspace_root: []const u8,
    advertised_dynamic_tool_names: []const []const u8,
    target_override: ?[]const u8,
) !runtime_deps.ResolvedLiveToolAuthority {
    const provider = deps.live_tool_authority orelse unreachable;
    const target = target_override orelse
        try deps.permission_target_for_call(
            deps.ctx,
            arena,
            call,
            advertised_dynamic_tool_names,
        );
    const command_call = try tooling_tool_admission.callUsesCommandAuthority(
        deps.tool_registry,
        arena,
        call,
    );
    const target_kind = if (command_call)
        tool_dispatch.PermissionTargetKind.command_cwd
    else if (deps.tool_registry.lookup(call.name)) |tool|
        tool.permission_target_kind
    else
        .none;
    return provider.resolve(
        arena,
        call,
        workspace_root,
        target,
        target_kind,
    );
}

fn liveAuthorityRejectsExecution(
    resolved: runtime_deps.ResolvedLiveToolAuthority,
) bool {
    return resolved.decision == .deny or
        resolved.decision == .unavailable;
}

fn liveAuthorityUnavailable(
    resolved: runtime_deps.ResolvedLiveToolAuthority,
) bool {
    return resolved.decision == .unavailable;
}

fn rejectPermissionForLiveAuthority(
    outcome: *command_admission.PermissionOutcome,
) void {
    outcome.decision = .policy_denied;
    outcome.denial_reason = .policy_denied;
    outcome.execution_authority = null;
    outcome.feedback = null;
    outcome.human_approval = .none;
}

const PreparationClassifierContext = struct {
    deps: *const AgentRuntimeDeps,
};

fn preparationExecutionStatus(status: runtime_tool_contracts.ToolExecutionStatus) tool_preparation.ToolStatus {
    return switch (status) {
        .success => .success,
        .failure => .failure,
    };
}

fn prepareNoIdempotentTerminal(_: ?*anyopaque, _: Allocator, _: ToolCall) anyerror!?tool_preparation.CallbackTerminal {
    return null;
}

fn prepareValidationTerminal(
    raw_ctx: ?*anyopaque,
    alloc: Allocator,
    call: ToolCall,
) anyerror!?tool_preparation.CallbackTerminal {
    const ctx: *PreparationClassifierContext = @ptrCast(@alignCast(raw_ctx.?));
    const execution = try runtime_tool_admission.registeredToolValidationFailure(
        ctx.deps,
        alloc,
        call,
    ) orelse return null;
    return .{
        .model_output = @constCast(execution.model_output),
        .status = preparationExecutionStatus(execution.status),
    };
}

fn prepareAvailabilityTerminal(
    raw_ctx: ?*anyopaque,
    alloc: Allocator,
    call: ToolCall,
) anyerror!?tool_preparation.CallbackTerminal {
    const ctx: *PreparationClassifierContext = @ptrCast(@alignCast(raw_ctx.?));
    const execution = try runtime_tool_admission.toolAvailabilityFailure(
        ctx.deps,
        alloc,
        call,
    ) orelse return null;
    return .{
        .model_output = @constCast(execution.model_output),
        .status = preparationExecutionStatus(execution.status),
    };
}

fn prepareDeferredDynamicCandidate(
    raw_ctx: ?*anyopaque,
    alloc: Allocator,
    call: ToolCall,
) anyerror!bool {
    const ctx: *PreparationClassifierContext = @ptrCast(@alignCast(raw_ctx.?));
    const validate = ctx.deps.validate_tool_call orelse return false;
    return switch (try validate(ctx.deps.ctx, alloc, call)) {
        .not_registered => false,
        .valid, .failure => true,
    };
}

fn preparedTerminalModelOutput(
    alloc: Allocator,
    call: ToolCall,
    terminal: tool_preparation.Terminal,
) Allocator.Error![]const u8 {
    if (terminal.model_output) |model_output| return model_output;
    return switch (terminal.kind) {
        .unsupported => try std.fmt.allocPrint(
            alloc,
            "Unsupported tool: {s}",
            .{call.name},
        ),
        else => unreachable,
    };
}

noinline fn preparedCandidateClassificationComplete(
    candidate: tool_preparation.Candidate,
) bool {
    return candidate.kind != .legacy_target_resolution;
}

fn preparedFileMutationTargetMatches(
    maybe_preparation: ?*tool_preparation.Result,
    prepared: tooling_tool_admission.PreparedFileMutationCall,
) bool {
    const preparation = maybe_preparation orelse return false;
    return switch (preparation.*) {
        .terminal => false,
        .candidate => |candidate| candidate.kind == .registered and
            candidate.applicable_targets.len == 1 and
            candidate.applicable_targets[0].kind == .file and
            std.mem.eql(
                u8,
                candidate.applicable_targets[0].path,
                prepared.targetPath(),
            ),
    };
}

fn preparedCallApplicableTargetsFresh(
    arena: Allocator,
    deps: *const AgentRuntimeDeps,
    config: Config,
    call: ToolCall,
    maybe_preparation: ?*tool_preparation.Result,
) Allocator.Error!bool {
    const preparation = maybe_preparation orelse return true;
    return switch (preparation.*) {
        .terminal => true,
        .candidate => |*candidate| tool_preparation.ordinaryApplicableTargetsFreshInScope(
            arena,
            call,
            deps.tool_registry,
            config.workspace_root,
            config.access_scope,
            candidate,
        ),
    };
}

fn parallelApplicableTargetsFresh(
    arena: Allocator,
    deps: *const AgentRuntimeDeps,
    config: Config,
    calls: []const ToolCall,
    preparations: []?tool_preparation.Result,
) Allocator.Error!bool {
    for (calls, preparations) |call, *maybe_preparation| {
        if (maybe_preparation.*) |*preparation| {
            if (!try preparedCallApplicableTargetsFresh(
                arena,
                deps,
                config,
                call,
                preparation,
            )) return false;
        }
    }
    return true;
}

fn settleFailedContextGate(
    deps: *const AgentRuntimeDeps,
    provisional_statuses: *runtime_tool_presentation.ProvisionalToolStatuses,
    provisional_alloc: Allocator,
    turn_id: u64,
    calls: []const ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
    original_error: anyerror,
) anyerror {
    var settlement_arena_state = std.heap.ArenaAllocator.init(provisional_alloc);
    defer settlement_arena_state.deinit();
    const settlement_arena = settlement_arena_state.allocator();
    for (calls) |call| {
        _ = provisional_statuses.settleAdmittedCall(
            deps,
            provisional_alloc,
            settlement_arena,
            turn_id,
            call,
            "Failed",
            advertised_dynamic_tool_names,
        ) catch |settlement_error| {
            debug_trace.logf(
                "tool",
                "context gate provisional settlement failed call_id={s} original_err={s} settlement_err={s}",
                .{ call.id, @errorName(original_error), @errorName(settlement_error) },
            );
        };
    }
    return original_error;
}

pub const TestHooks = if (builtin.is_test) struct {
    pub var context_gate_commit: ?*const fn () Allocator.Error!void = null;
} else struct {};

fn commitSelectedContext(
    arena: Allocator,
    stable_prefix: *std.ArrayList(ChatMessage),
    context_delivery_state: *context_contract.DeliveryState,
    selected: *context_contract.ProviderContext,
) Allocator.Error!void {
    if (comptime builtin.is_test) {
        if (TestHooks.context_gate_commit) |hook| try hook();
    }
    if (selected.content != null) try stable_prefix.ensureUnusedCapacity(arena, 1);
    try context_delivery_state.commit(arena, selected);
    if (selected.content) |content| {
        stable_prefix.appendAssumeCapacity(.{
            .role = .system,
            .content = content,
        });
        selected.content = null;
    }
}

fn candidateHasApplicableContextDelta(
    arena: Allocator,
    context_registry: context_contract.Registry,
    config: Config,
    context_delivery_state: *const context_contract.DeliveryState,
    candidate: tool_preparation.Candidate,
) !bool {
    switch (candidate.kind) {
        .advertised_dynamic, .deferred_dynamic, .legacy_target_resolution => return true,
        .registered => if (candidate.applicable_targets.len == 0) return false,
    }

    var selected = try context_registry.selectDefaultApplicableContext(arena, .{
        .workspace_root = config.workspace_root,
        .access_scope = config.access_scope,
        .targets = candidate.applicable_targets,
        .delivered_sources = context_delivery_state.delivered_sources.items,
        .evaluated_endpoints = context_delivery_state.evaluated_endpoints.items,
        .context_limits = config.context_limits,
    });
    defer selected.deinit(arena);
    return selected.content != null;
}

const ParentTurnDeliveryState = struct {
    acknowledgements: []const runtime_deps.ParentTurnDeliveryAck = &.{},
    acknowledged: bool = false,

    /// `possibly_sent` is the delivery-certainty boundary: successful requests
    /// cross it before their first body write, and failures after it are
    /// ambiguous. Acknowledging both prevents duplicate parent context after a
    /// request may have reached the model. Definitely-unsent attempts stay
    /// pending so the next parent turn projects the same deliveries again.
    fn observeGatewayDelivery(
        self: *ParentTurnDeliveryState,
        deps: *const AgentRuntimeDeps,
        arena: Allocator,
        delivery: runtime_gateway_step.DeliveryCertainty.State,
    ) void {
        if (self.acknowledged or
            self.acknowledgements.len == 0 or
            delivery == .definitely_unsent)
        {
            return;
        }
        const acknowledge = deps.acknowledge_parent_turn_context orelse return;
        acknowledge(deps.ctx, arena, self.acknowledgements);
        self.acknowledged = true;
    }
};

fn appendPreparedParentTurnContext(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    messages: *std.ArrayList(ChatMessage),
) !ParentTurnDeliveryState {
    const prepare = deps.prepare_parent_turn_context orelse return .{};
    const prepared = try prepare(deps.ctx, arena) orelse return .{};
    if (prepared.content.len == 0) return .{};
    try messages.ensureUnusedCapacity(arena, 1);
    messages.appendAssumeCapacity(.{
        .role = .system,
        .content = prepared.content,
    });
    return .{ .acknowledgements = prepared.acknowledgements };
}

fn appendNotExecutedToolResult(
    deps: *const AgentRuntimeDeps,
    provisional_statuses: *runtime_tool_presentation.ProvisionalToolStatuses,
    provisional_alloc: Allocator,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
    step_ctx: TraceContext,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
    batch: *runtime_tool_batch.StepBatchState,
    result_kind: []const u8,
) !void {
    _ = try provisional_statuses.settleAdmittedCall(
        deps,
        provisional_alloc,
        arena,
        turn_id,
        call,
        types.deferred_tool_result_output,
        advertised_dynamic_tool_names,
    );
    debug_trace.eventf(
        "tool",
        "execution_result",
        step_ctx,
        "call_id={s} name={s} result_kind={s} model_output_bytes={d}",
        .{ call.id, call.name, result_kind, types.deferred_tool_result_output.len },
    );
    try runtime_tool_batch.appendToolResultContent(
        arena,
        within_turn_suffix,
        completed_tool_names,
        batch,
        call,
        types.deferred_tool_result_output,
        null,
        .{
            .increment_total = false,
            .status = .failure,
        },
    );
}

fn appendContextDeferredToolResult(
    deps: *const AgentRuntimeDeps,
    provisional_statuses: *runtime_tool_presentation.ProvisionalToolStatuses,
    provisional_alloc: Allocator,
    arena: Allocator,
    turn_id: u64,
    call: ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
    step_ctx: TraceContext,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
    batch: *runtime_tool_batch.StepBatchState,
) !void {
    _ = try provisional_statuses.settleDeferredCall(
        deps,
        provisional_alloc,
        arena,
        turn_id,
        call,
        advertised_dynamic_tool_names,
    );
    debug_trace.eventf(
        "tool",
        "execution_result",
        step_ctx,
        "call_id={s} name={s} result_kind=context_deferred model_output_bytes={d}",
        .{ call.id, call.name, types.context_deferred_tool_result_output.len },
    );
    try runtime_tool_batch.appendToolResultContent(
        arena,
        within_turn_suffix,
        completed_tool_names,
        batch,
        call,
        types.context_deferred_tool_result_output,
        null,
        .{
            .increment_total = false,
            .status = .failure,
        },
    );
}

fn providerExecutedResult(call: ToolCall) ?ToolExecutionResult {
    if (call.provenance != .provider_executed) return null;
    const provider_result = call.provider_result orelse return null;
    const provider_status = runtime_execution_memory.classifyProviderExecutedResultStatus(
        provider_result,
    );
    return .{
        .status = if (provider_status == .success) .success else .failure,
        .model_output = provider_result,
    };
}

fn hasToolResult(messages: []const ChatMessage, call_id: []const u8) bool {
    for (messages) |message| {
        if (message.role != .tool) continue;
        const existing = message.tool_call_id orelse continue;
        if (std.mem.eql(u8, existing, call_id)) return true;
    }
    return false;
}

fn appendProviderExecutedToolResult(
    deps: *const AgentRuntimeDeps,
    stream_ctx: *runtime_assistant_stream.StreamChunkContext,
    arena: Allocator,
    config: Config,
    turn_id: u64,
    call: ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
    step_ctx: TraceContext,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
    batch: *runtime_tool_batch.StepBatchState,
) !void {
    const provider_result = call.provider_result orelse
        return error.MalformedProviderResultIdentity;
    const provider_status = runtime_execution_memory.classifyProviderExecutedResultStatus(
        provider_result,
    );
    const execution: ToolExecutionResult = .{
        .status = if (provider_status == .success) .success else .failure,
        .model_output = provider_result,
    };
    const prepared = try runtime_execution_memory.prepareToolModelOutput(
        arena,
        config,
        call,
        execution.model_output,
    );
    const safe_tool_output = prepared.model_output;
    const visible_id = stream_ctx.provisional_statuses.visibleId(call);
    const ProviderVisibleLifecycle = struct {
        call: ToolCall,
        status_started: bool,
    };
    var provider_visible_lifecycle: ?ProviderVisibleLifecycle = null;
    if (visible_id) |id| {
        var visible_call = call;
        visible_call.id = id;
        provider_visible_lifecycle = .{
            .call = visible_call,
            .status_started = true,
        };
    } else if (runtime_tool_presentation.isProviderSearchAlias(call.name)) {
        provider_visible_lifecycle = .{
            .call = call,
            .status_started = try runtime_tool_presentation.startToolVisibleLifecycle(
                deps,
                arena,
                turn_id,
                stream_ctx.provisional_statuses.presentation_group_id,
                call,
                null,
                advertised_dynamic_tool_names,
            ),
        };
    }
    debug_trace.eventf(
        "tool",
        "execution_result",
        step_ctx,
        "call_id={s} name={s} result_kind=provider_executed model_output_bytes={d}",
        .{ call.id, call.name, safe_tool_output.len },
    );
    try runtime_tool_batch.appendToolResultContent(
        arena,
        within_turn_suffix,
        completed_tool_names,
        batch,
        call,
        safe_tool_output,
        prepared.memory,
        .{
            .increment_error = provider_status == .failure,
            .record_completion = provider_status == .success,
            .status = provider_status,
        },
    );
    if (provider_visible_lifecycle) |visible_lifecycle| {
        try runtime_tool_presentation.finishExecutedToolStatus(
            deps,
            arena,
            turn_id,
            visible_lifecycle.call,
            visible_lifecycle.status_started,
            null,
            execution,
            safe_tool_output,
            prepared.memory,
            null,
            advertised_dynamic_tool_names,
        );
    }
}

fn materializeConfirmedProviderTools(
    deps: *const AgentRuntimeDeps,
    stream_ctx: *runtime_assistant_stream.StreamChunkContext,
    arena: Allocator,
    config: Config,
    turn_id: u64,
    completion: types.GatewayCompletion,
    advertised_dynamic_tool_names: []const []const u8,
    step_ctx: TraceContext,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
) !void {
    if (completion.tool_calls.len == 0) return;
    switch (types.authoritativeToolAdmission(completion)) {
        .admitted => {},
        else => return,
    }

    var novel_count: usize = 0;
    for (completion.tool_calls) |call| {
        if (call.provenance == .provider_executed and
            !hasToolResult(within_turn_suffix.items, call.id)) novel_count += 1;
    }
    if (novel_count == 0) return;

    const novel_calls = try arena.alloc(ToolCall, novel_count);
    var novel_index: usize = 0;
    for (completion.tool_calls) |call| {
        if (call.provenance != .provider_executed or
            hasToolResult(within_turn_suffix.items, call.id)) continue;
        novel_calls[novel_index] = call;
        novel_index += 1;
    }
    try runtime_tool_batch.appendAssistantToolCallStep(
        arena,
        within_turn_suffix,
        null,
        novel_calls,
        completion.provider_state_json,
    );
    var batch: runtime_tool_batch.StepBatchState = .{};
    for (novel_calls) |call| {
        try appendProviderExecutedToolResult(
            deps,
            stream_ctx,
            arena,
            config,
            turn_id,
            call,
            advertised_dynamic_tool_names,
            step_ctx,
            within_turn_suffix,
            completed_tool_names,
            &batch,
        );
    }
    debug_trace.eventf(
        "agent",
        "provider_tool_recovery_materialized",
        step_ctx,
        "tool_call_count={d}",
        .{novel_calls.len},
    );
}

const FilteredProviderCalls = struct {
    calls: []const ToolCall,
    removed: usize,
};

fn filterMaterializedProviderCalls(
    arena: Allocator,
    messages: []const ChatMessage,
    calls: []const ToolCall,
) !FilteredProviderCalls {
    var keep_count: usize = 0;
    for (calls) |call| {
        if (call.provenance != .provider_executed or
            !hasToolResult(messages, call.id)) keep_count += 1;
    }
    if (keep_count == calls.len) return .{ .calls = calls, .removed = 0 };
    const filtered = try arena.alloc(ToolCall, keep_count);
    var index: usize = 0;
    for (calls) |call| {
        if (call.provenance == .provider_executed and
            hasToolResult(messages, call.id)) continue;
        filtered[index] = call;
        index += 1;
    }
    return .{ .calls = filtered, .removed = calls.len - keep_count };
}

fn finishPendingParallelCancelled(
    deps: *const AgentRuntimeDeps,
    provisional_statuses: *runtime_tool_presentation.ProvisionalToolStatuses,
    provisional_alloc: Allocator,
    arena: Allocator,
    config: Config,
    turn_id: u64,
    calls: []const ToolCall,
    results: []const ?ToolExecutionResult,
    status_started: []const bool,
    status_terminalized: []const bool,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    for (calls, results, status_started, status_terminalized) |call, result, started, terminalized| {
        if (terminalized) continue;
        if (result) |execution| {
            var prepared = try runtime_execution_memory.prepareToolModelOutput(
                arena,
                config,
                call,
                execution.model_output,
            );
            runtime_execution_memory.applyToolResultMemory(
                &prepared.memory,
                execution.tool_result_memory,
            );
            _ = try provisional_statuses.finishExecutedCall(
                deps,
                provisional_alloc,
                arena,
                turn_id,
                call,
                started,
                null,
                execution,
                prepared.model_output,
                prepared.memory,
                null,
                advertised_dynamic_tool_names,
            );
            continue;
        }
        _ = try provisional_statuses.finishDeniedCall(
            deps,
            provisional_alloc,
            arena,
            turn_id,
            call,
            started,
            null,
            "Cancelled",
            advertised_dynamic_tool_names,
        );
    }
}

fn finishPreparedCallsOnCancellation(
    deps: *const AgentRuntimeDeps,
    provisional_statuses: *runtime_tool_presentation.ProvisionalToolStatuses,
    provisional_alloc: Allocator,
    arena: Allocator,
    config: Config,
    turn_id: u64,
    prepared_calls: []const PreparedToolCall,
    preparations: []const ?tool_preparation.Result,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    std.debug.assert(preparations.len == 0 or preparations.len == prepared_calls.len);

    const calls = try arena.alloc(ToolCall, prepared_calls.len);
    const results = try arena.alloc(?ToolExecutionResult, prepared_calls.len);
    @memset(results, null);
    for (prepared_calls, 0..) |prepared_call, i| {
        const call = prepared_call.call();
        calls[i] = call;
        switch (prepared_call) {
            .blocked => |blocked| {
                if (blocked.model_output) |model_output| {
                    results[i] = .{
                        .status = .failure,
                        .model_output = model_output,
                    };
                }
            },
            .provider_executed => {
                results[i] = providerExecutedResult(call);
            },
            .ready => {
                if (preparations.len == 0) continue;
                const preparation = preparations[i] orelse continue;
                switch (preparation) {
                    .candidate => {},
                    .terminal => |terminal| {
                        results[i] = .{
                            .status = switch (terminal.status) {
                                .success => .success,
                                .failure => .failure,
                            },
                            .model_output = try preparedTerminalModelOutput(
                                arena,
                                call,
                                terminal,
                            ),
                        };
                    },
                }
            },
        }
    }

    const status_started = try arena.alloc(bool, prepared_calls.len);
    @memset(status_started, false);
    const status_terminalized = try arena.alloc(bool, prepared_calls.len);
    @memset(status_terminalized, false);
    try finishPendingParallelCancelled(
        deps,
        provisional_statuses,
        provisional_alloc,
        arena,
        config,
        turn_id,
        calls,
        results,
        status_started,
        status_terminalized,
        advertised_dynamic_tool_names,
    );
}

fn finishPendingCancelledCalls(
    deps: *const AgentRuntimeDeps,
    provisional_statuses: *runtime_tool_presentation.ProvisionalToolStatuses,
    provisional_alloc: Allocator,
    arena: Allocator,
    config: Config,
    turn_id: u64,
    calls: []const ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
) !void {
    for (calls) |call| {
        if (providerExecutedResult(call)) |execution| {
            const prepared = try runtime_execution_memory.prepareToolModelOutput(
                arena,
                config,
                call,
                execution.model_output,
            );
            _ = try provisional_statuses.finishExecutedCall(
                deps,
                provisional_alloc,
                arena,
                turn_id,
                call,
                false,
                null,
                execution,
                prepared.model_output,
                prepared.memory,
                null,
                advertised_dynamic_tool_names,
            );
            continue;
        }
        _ = try provisional_statuses.finishDeniedCall(
            deps,
            provisional_alloc,
            arena,
            turn_id,
            call,
            false,
            null,
            "Cancelled",
            advertised_dynamic_tool_names,
        );
    }
}

pub const CommonStopState = struct {
    retained_candidate: ?[]const u8 = null,
    latest_partial: ?[]const u8 = null,
    dispatched: bool = false,
    terminal_materializing: bool = false,
};

fn semanticAttemptLimit(max_provider_attempts: usize) usize {
    return if (max_provider_attempts == 0) 1 else max_provider_attempts;
}

fn completionContentBytes(completion: types.GatewayCompletion) usize {
    return if (completion.content) |content| content.len else 0;
}

fn streamReplaySafe(
    stream_ctx: *const runtime_assistant_stream.StreamChunkContext,
) bool {
    return stream_ctx.raw_text.items.len == 0 and !stream_ctx.saw_tool_start;
}

const read_failure_tool_recovery_instruction =
    \\<network_recovery>
    \\The previous response stream ended because the network connection was interrupted.
    \\Fx did not execute the incomplete tool call from that stream. Recreate the tool call if it is still needed.
    \\</network_recovery>
;

fn appendReadFailureRecoveryContext(
    alloc: Allocator,
    messages: []const ChatMessage,
    strategy: ?model_response_recovery.Strategy,
    partial_assistant: []const u8,
) ![]const ChatMessage {
    const selected = strategy orelse return messages;
    const projected = try alloc.alloc(ChatMessage, messages.len + 1);
    @memcpy(projected[0..messages.len], messages);
    const instruction = switch (selected) {
        .continue_response => try std.fmt.allocPrint(
            alloc,
            "<network_recovery>\nThe response stream was interrupted. Continue the same response from the exact partial source below. Do not repeat it and do not start a new answer.\n<partial_assistant>\n{s}\n</partial_assistant>\n</network_recovery>",
            .{partial_assistant},
        ),
        .regenerate_tool => read_failure_tool_recovery_instruction,
        .continue_after_confirmed_tool => "<network_recovery>\nThe response stream was interrupted after a confirmed tool result. Continue from the confirmed result without repeating the tool.\n</network_recovery>",
        .reconcile_tool => "<network_recovery>\nThe response stream was interrupted after provider tool activity with an uncertain outcome. Reconcile the existing evidence before proposing any repeat action. Do not blindly replay the tool.\n</network_recovery>",
        .retry_request => "<network_recovery>\nThe provider response was interrupted before any assistant output or tool activity escaped. Re-run the response for the same user request.\n</network_recovery>",
        .pause, .stop => return messages,
    };
    projected[messages.len] = .{
        .role = .system,
        .content = instruction,
    };
    return projected;
}

fn recoveryToolEvidence(
    completion: ?types.GatewayCompletion,
    stream_ctx: *const runtime_assistant_stream.StreamChunkContext,
) model_response_recovery.ToolEvidence {
    if (completion) |value| {
        if (value.tool_calls.len > 0) {
            if (types.allToolCallsProviderExecuted(value.tool_calls)) {
                return switch (types.authoritativeToolAdmission(value)) {
                    .admitted => .confirmed,
                    else => .uncertain,
                };
            }
            return .uncertain;
        }
    }
    if (stream_ctx.saw_provider_tool_start) return .uncertain;
    if (stream_ctx.saw_tool_start) return .proven_unexecuted;
    return .none;
}

noinline fn effectiveRecoveryToolEvidence(
    preserved: model_response_recovery.ToolEvidence,
    completion: ?types.GatewayCompletion,
    stream_ctx: *const runtime_assistant_stream.StreamChunkContext,
) model_response_recovery.ToolEvidence {
    const observed = recoveryToolEvidence(completion, stream_ctx);
    return if (observed == .none) preserved else observed;
}

fn restoredRecoveryCause(
    cause: types.ModelRecoveryCause,
) model_response_recovery.FailureCause {
    return switch (cause) {
        .network_interrupted => .transport_interrupted,
        .response_interrupted => .response_interrupted,
        .provider_unavailable => .provider_unavailable,
        .rate_limited => .rate_limited,
        .system_resumed => .system_resumed,
        .authentication => .authentication,
        .request_limit_reached => .request_limit_reached,
    };
}

fn restoredRecoveryToolEvidence(
    state: session_codec.RecoveryToolState,
) model_response_recovery.ToolEvidence {
    return switch (state) {
        .none => .none,
        .proven_unexecuted => .proven_unexecuted,
        .confirmed => .confirmed,
        .uncertain => .uncertain,
    };
}

fn restoredRecoveryStrategy(
    checkpoint: session_codec.RecoveryCheckpoint,
) ?model_response_recovery.Strategy {
    if (checkpoint.cause == .request_limit_reached) return null;
    return switch (checkpoint.tool_state) {
        .proven_unexecuted => .regenerate_tool,
        .confirmed => .continue_after_confirmed_tool,
        .uncertain => .reconcile_tool,
        .none => if (checkpoint.assistant_source.len > 0)
            .continue_response
        else
            .retry_request,
    };
}

fn restoredConsumedAttempts(
    checkpoint: session_codec.RecoveryCheckpoint,
) usize {
    return @min(
        checkpoint.max_provider_attempts,
        checkpoint.consumed_provider_attempts +|
            @intFromBool(checkpoint.outstanding_reservation),
    );
}

fn recoverySelectionChanged(
    checkpoint: session_codec.RecoveryCheckpoint,
    selected_provider: model_provider.ProviderId,
    selected_model: []const u8,
    selected_fast_mode: bool,
) bool {
    return checkpoint.route_provider != selected_provider or !std.mem.eql(
        u8,
        checkpoint.route_model,
        selected_model,
    ) or checkpoint.requested_fast_mode != selected_fast_mode;
}

fn checkpointCause(
    cause: model_response_recovery.FailureCause,
) types.ModelRecoveryCause {
    return switch (cause) {
        .transport_interrupted => .network_interrupted,
        .response_interrupted => .response_interrupted,
        .provider_unavailable => .provider_unavailable,
        .rate_limited => .rate_limited,
        .system_resumed => .system_resumed,
        .authentication => .authentication,
        .request_limit_reached => .request_limit_reached,
        .content_filter => .provider_unavailable,
    };
}

fn checkpointAction(
    strategy: ?model_response_recovery.Strategy,
) types.ModelRecoveryAction {
    return switch (strategy orelse .retry_request) {
        .retry_request => .retrying_request,
        .continue_response => .continuing_response,
        .regenerate_tool => .regenerating_tool,
        .continue_after_confirmed_tool => .continuing_after_tool,
        .reconcile_tool => .reconciling_tool,
        .pause, .stop => .paused,
    };
}

fn checkpointToolState(
    evidence: model_response_recovery.ToolEvidence,
) session_codec.RecoveryToolState {
    return switch (evidence) {
        .none => .none,
        .proven_unexecuted => .proven_unexecuted,
        .confirmed => .confirmed,
        .uncertain => .uncertain,
    };
}

fn recoveryRequiredAction(
    action: model_response_recovery.RequiredAction,
) types.ModelRecoveryRequiredAction {
    return switch (action) {
        .none => .none,
        .continue_later => .continue_later,
        .inspect_uncertain_tool => .inspect_uncertain_tool,
        .change_request => .change_request,
    };
}

noinline fn pausedRequiredAction(
    evidence: model_response_recovery.ToolEvidence,
) types.ModelRecoveryRequiredAction {
    return if (evidence == .uncertain)
        .inspect_uncertain_tool
    else
        .continue_later;
}

noinline fn recoveryCheckpointAssistantSource(
    arena: Allocator,
    stop_state: *const CommonStopState,
    attempt_source: []const u8,
) ![]const u8 {
    const retained = stop_state.retained_candidate orelse return attempt_source;
    return hooks.prompt.joinVisibleSegments(arena, retained, attempt_source);
}

fn persistRecoveryCheckpoint(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    assistant_source: []const u8,
    route_model: []const u8,
    requested_fast_mode: bool,
    fast_mode: bool,
    attempt_limit: usize,
    consumed_attempts: usize,
    outstanding_reservation: bool,
    cause: model_response_recovery.FailureCause,
    strategy: ?model_response_recovery.Strategy,
    tool_evidence: model_response_recovery.ToolEvidence,
    trace_ctx: TraceContext,
) !void {
    const effect = deps.recovery_checkpoint orelse return;
    const execution = try runtime_execution_memory.buildExecutionMemory(
        arena,
        current_turn_messages,
    );
    try effect.set(deps.ctx, .{
        .turn_id = job.turn_id,
        .user = .{
            .text = @constCast(job.prompt),
            .images = job.images,
        },
        .assistant_source = @constCast(assistant_source),
        .execution = execution,
        .cause = checkpointCause(cause),
        .action = checkpointAction(strategy),
        .tool_state = checkpointToolState(tool_evidence),
        .route_model = @constCast(route_model),
        .route_provider = job.provider,
        .requested_fast_mode = requested_fast_mode,
        .fast_mode = fast_mode,
        .max_provider_attempts = attempt_limit,
        .consumed_provider_attempts = consumed_attempts,
        .outstanding_reservation = outstanding_reservation,
    });
    debug_trace.eventf(
        "agent",
        "recovery_checkpoint_set",
        trace_ctx,
        "provider_attempts={d}/{d} outstanding={s} cause={s} action={s}",
        .{
            consumed_attempts,
            attempt_limit,
            if (outstanding_reservation) "true" else "false",
            @tagName(cause),
            @tagName(strategy orelse .retry_request),
        },
    );
}

fn isRetryableModelStatus(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests,
        .internal_server_error,
        .bad_gateway,
        .service_unavailable,
        .gateway_timeout,
        => true,
        else => false,
    };
}

fn isPostVisionAssistantPrefillRejection(
    status: std.http.Status,
    detail: []const u8,
    messages: []const ChatMessage,
) bool {
    if (status != .bad_request or messages.len == 0) return false;
    const tail = messages[messages.len - 1];
    if (tail.role != .tool or
        !std.mem.eql(u8, tail.tool_name orelse return false, "vision"))
    {
        return false;
    }
    return std.mem.find(u8, detail, "does not support assistant message prefill") != null and
        std.mem.find(u8, detail, "must end with a user message") != null;
}

fn waitForRecoveryDelay(
    cancel_flag: *std.atomic.Value(bool),
    delay_ns: u64,
) bool {
    if (comptime builtin.is_test) return !cancel_flag.load(.seq_cst);
    var remaining = delay_ns;
    const quantum = 25 * std.time.ns_per_ms;
    while (remaining > 0) {
        if (cancel_flag.load(.seq_cst)) return false;
        const current = @min(remaining, quantum);
        io_mod.sleep(current);
        remaining -= current;
    }
    return !cancel_flag.load(.seq_cst);
}

fn recoveryPauseRequested(config: Config) bool {
    const flag = config.recovery_pause_flag orelse return false;
    return flag.load(.seq_cst);
}

fn providerFailureReplaySafe(
    completion: types.GatewayCompletion,
    stream_ctx: *const runtime_assistant_stream.StreamChunkContext,
) bool {
    return completion.finish_reason == .provider_error and
        completionContentBytes(completion) == 0 and
        completion.tool_calls.len == 0 and
        streamReplaySafe(stream_ctx);
}

fn disableFastRouteAfterFailure(
    route_fast_mode: *bool,
    route_model: *[]const u8,
    selected_model: []const u8,
    cause: model_response_recovery.FailureCause,
    replay_safe: bool,
    trace_ctx: TraceContext,
) bool {
    if (!model_response_recovery.shouldDisableFastRoute(
        route_fast_mode.*,
        cause,
        replay_safe,
    )) return false;
    debug_trace.eventf(
        "agent",
        "recovery_fast_fallback",
        trace_ctx,
        "failed_route={s} selected_model={s}",
        .{ route_model.*, selected_model },
    );
    route_fast_mode.* = false;
    route_model.* = selected_model;
    return true;
}

fn routeFailureDetail(completion: types.GatewayCompletion) []const u8 {
    return if (completion.provider_failure_detail) |detail| debug_trace.preview(detail, 240) else "";
}

fn isTerminalProviderExecutedCompletion(completion: types.GatewayCompletion) bool {
    if (completion.finish_reason != .stop) return false;
    const content = completion.content orelse return false;
    return content.len > 0 and types.allToolCallsProviderExecuted(completion.tool_calls);
}

noinline fn pushRouteRecoveryStatus(
    deps: *const AgentRuntimeDeps,
    status: types.RouteRecoveryStatus,
) !void {
    try deps.push_route_recovery_status(deps.ctx, status);
}

noinline fn clearAutoRetryStatusIfNeeded(
    deps: *const AgentRuntimeDeps,
    recovery_active: bool,
) !void {
    if (!recovery_active) return;
    try deps.push_event(deps.ctx, .clear_route_recovery_status);
}

fn pushTerminalAutoRetryStatusIfNeeded(
    deps: *const AgentRuntimeDeps,
    recovery_active: bool,
    semantic_attempt: usize,
    semantic_limit: usize,
    diagnostic: types.ModelFailureDiagnostic,
) !void {
    if (!recovery_active) return;
    try pushRouteRecoveryStatus(deps, .{
        .kind = .terminal_provider_error,
        .failed_attempt = semantic_attempt + 1,
        .attempt_limit = semantic_limit,
        .diagnostic = diagnostic,
    });
}

fn onRequiredVisionStreamToolStart(
    ctx: *anyopaque,
    tool_id: []const u8,
    tool_name: []const u8,
    label_value: ?[]const u8,
) void {
    if (!std.mem.eql(u8, tool_name, "vision")) {
        runtime_assistant_stream.recordStreamToolStart(ctx, tool_name);
        return;
    }
    runtime_assistant_stream.onStreamToolStart(
        ctx,
        tool_id,
        tool_name,
        label_value,
    );
}

fn unsafeNoRetryReason(
    completion: types.GatewayCompletion,
    stream_ctx: *const runtime_assistant_stream.StreamChunkContext,
) types.RouteRecoveryUnsafeReason {
    return if (stream_ctx.saw_tool_start or completion.tool_calls.len > 0)
        .tool_start
    else
        .assistant_output;
}

fn refreshGatewayCredentialForJob(
    deps: *const AgentRuntimeDeps,
    alloc: Allocator,
    job: QueuedPrompt,
    mode: CredentialRefreshMode,
    active_api_key: *[]const u8,
    owned_api_key: *?[]u8,
    trace_ctx: TraceContext,
) !bool {
    const source = job.credential_source orelse return false;
    if (!credentials.sourceRefreshable(source)) return false;
    const refresh = deps.refresh_gateway_credential orelse return false;

    const refreshed = refresh(deps.ctx, alloc, source, mode, job.account_id) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.eventf(
            "gateway",
            "credential_refresh_failed",
            trace_ctx,
            "source={s} mode={s} err={s}",
            .{ @tagName(source), @tagName(mode), @errorName(err) },
        );
        return false;
    } orelse return false;
    const previous_api_key = active_api_key.*;
    if (comptime !host_target.is_wasm) {
        if (deps.usage) |usage| {
            if (source == .chatgpt_subscription or source == .grok_subscription) {
                usage.clearReconciliationCredential();
            } else {
                usage.refreshReconciliationCredential(
                    deps.usage_allocator,
                    previous_api_key,
                    refreshed,
                );
            }
        }
    }
    if (owned_api_key.*) |old| secret.zeroAndFree(alloc, old);
    owned_api_key.* = refreshed;
    active_api_key.* = refreshed;
    debug_trace.eventf(
        "gateway",
        "credential_refreshed",
        trace_ctx,
        "source={s} mode={s}",
        .{ @tagName(source), @tagName(mode) },
    );
    return true;
}

fn pushAutoRetryStatus(
    deps: *const AgentRuntimeDeps,
    failed_attempt: usize,
    attempt_limit: usize,
    cause: model_response_recovery.FailureCause,
    decision: model_response_recovery.Decision,
    diagnostic: types.ModelFailureDiagnostic,
) !void {
    try pushRouteRecoveryStatus(deps, .{
        .kind = .auto_retry,
        .failed_attempt = failed_attempt,
        .attempt_limit = attempt_limit,
        .cause = switch (cause) {
            .transport_interrupted => .network_interrupted,
            .response_interrupted => .response_interrupted,
            .provider_unavailable => .provider_unavailable,
            .rate_limited => .rate_limited,
            .system_resumed => .system_resumed,
            .authentication => .authentication,
            .request_limit_reached => .request_limit_reached,
            .content_filter => null,
        },
        .action = switch (decision.strategy) {
            .retry_request => .retrying_request,
            .continue_response => .continuing_response,
            .regenerate_tool => .regenerating_tool,
            .continue_after_confirmed_tool => .continuing_after_tool,
            .reconcile_tool => .reconciling_tool,
            .pause => .paused,
            .stop => null,
        },
        .delay_seconds = decision.delay_ns / std.time.ns_per_s,
        .diagnostic = diagnostic,
    });
}

fn pushAutoRecoveredStatus(
    deps: *const AgentRuntimeDeps,
    retry_count: usize,
    attempt_limit: usize,
) !void {
    try pushRouteRecoveryStatus(deps, .{
        .kind = .auto_recovered,
        .succeeded_attempt = retry_count + 1,
        .attempt_limit = attempt_limit,
    });
}

fn pushTerminalProviderFailureStatus(
    deps: *const AgentRuntimeDeps,
    attempts: usize,
    attempt_limit: usize,
    completion: types.GatewayCompletion,
    diagnostic: types.ModelFailureDiagnostic,
) !void {
    const reason = completion.finish_reason orelse return;
    if (reason == .content_filter) {
        try pushRouteRecoveryStatus(deps, .{
            .kind = .content_filter,
            .required_action = .change_request,
            .diagnostic = diagnostic,
        });
        return;
    }
    try pushRouteRecoveryStatus(deps, .{
        .kind = .terminal_provider_error,
        .failed_attempt = attempts,
        .attempt_limit = attempt_limit,
        .diagnostic = diagnostic,
    });
}

fn finishRecoveryPaused(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    finish_trace: *PromptFinishTrace,
    cause: model_response_recovery.FailureCause,
    consumed_attempts: usize,
    attempt_limit: usize,
    required_action: types.ModelRecoveryRequiredAction,
    diagnostic: ?types.ModelFailureDiagnostic,
) !void {
    try pushRouteRecoveryStatus(deps, .{
        .kind = .terminal_provider_error,
        .failed_attempt = consumed_attempts,
        .attempt_limit = attempt_limit,
        .cause = checkpointCause(cause),
        .action = .paused,
        .required_action = required_action,
        .diagnostic = diagnostic orelse defaultRecoveryDiagnostic(cause),
    });
    try finalization.finish(.paused, null, null);
    finish_trace.finish("recovery_paused");
}

fn pushUnsafeNoRetryStatus(
    deps: *const AgentRuntimeDeps,
    reason: types.RouteRecoveryUnsafeReason,
    diagnostic: types.ModelFailureDiagnostic,
) !void {
    try pushRouteRecoveryStatus(deps, .{
        .kind = switch (reason) {
            .assistant_output => .unsafe_assistant_output,
            .tool_start => .unsafe_tool_start,
        },
        .diagnostic = diagnostic,
    });
}

fn defaultRecoveryDiagnostic(cause: model_response_recovery.FailureCause) types.ModelFailureDiagnostic {
    if (cause == .content_filter) return types.ModelFailureDiagnostic.init("content_filter");
    return types.ModelFailureDiagnostic.forCause(checkpointCause(cause));
}

fn defaultRecoveryDiagnosticText(cause: model_response_recovery.FailureCause) []const u8 {
    if (cause == .content_filter) return "content_filter";
    return types.ModelFailureDiagnostic.defaultTextForCause(checkpointCause(cause));
}

fn prepareExternalFailureDiagnostic(
    alloc: Allocator,
    raw: []const u8,
    fallback: []const u8,
) !types.ModelFailureDiagnostic {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const owned_source = if (trimmed.len > 0 and !hasDiagnosticIdentifier(trimmed))
        try std.fmt.allocPrint(alloc, "{s}: {s}", .{ fallback, trimmed })
    else
        null;
    defer if (owned_source) |source| alloc.free(source);
    const source = owned_source orelse if (trimmed.len > 0) trimmed else fallback;
    const masked = try text_utils.maskSecrets(alloc, source);
    defer if (masked.ptr != source.ptr) alloc.free(masked);

    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        masked,
        types.ModelFailureDiagnostic.max_bytes,
    );
    defer encoded.deinit(alloc);
    if (encoded.bytes.len == 0) return types.ModelFailureDiagnostic.init(fallback);
    return types.ModelFailureDiagnostic.init(encoded.bytes);
}

fn hasDiagnosticIdentifier(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, ": ")) |separator| {
        if (separator == 0) return false;
        return std.mem.indexOfAny(u8, text[0..separator], " \t\r\n") == null;
    }
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return false;
    }
    return text.len > 0;
}

fn providerCompletionDiagnostic(
    alloc: Allocator,
    completion: types.GatewayCompletion,
    fallback: []const u8,
) !types.ModelFailureDiagnostic {
    return prepareExternalFailureDiagnostic(
        alloc,
        completion.provider_failure_detail orelse "",
        fallback,
    );
}

fn httpFailureDiagnostic(
    alloc: Allocator,
    status: std.http.Status,
    detail: []const u8,
) !types.ModelFailureDiagnostic {
    const formatted = try gateway_error_format.formatHttpRecoveryDiagnostic(alloc, status, detail);
    defer alloc.free(formatted);
    return types.ModelFailureDiagnostic.init(formatted);
}

fn traceRouteFailure(
    step_ctx: TraceContext,
    selected_model: []const u8,
    route_model: []const u8,
    fast_mode: bool,
    semantic_attempt: usize,
    semantic_limit: usize,
    completion: types.GatewayCompletion,
    stream_ctx: *const runtime_assistant_stream.StreamChunkContext,
    retry: bool,
) void {
    const reason = completion.finish_reason orelse return;
    debug_trace.eventf(
        "agent",
        "route_failure",
        step_ctx,
        "selected_model={s} route={s} fast_mode={s} semantic_attempt={d}/{d} http_status=200 finish_reason={s} saw_content={s} saw_tool_start={s} retry={s} detail={s}",
        .{
            selected_model,
            route_model,
            if (fast_mode) "true" else "false",
            semantic_attempt,
            semantic_limit,
            reason.label(),
            if (stream_ctx.saw_visible_text or completionContentBytes(completion) > 0) "true" else "false",
            if (stream_ctx.saw_tool_start) "true" else "false",
            if (retry) "true" else "false",
            routeFailureDetail(completion),
        },
    );
}

pub fn processQueuedPrompt(
    deps: *const AgentRuntimeDeps,
    semantic_presentation: ?runtime_assistant_stream.SemanticPresentationSink,
    lifecycle: LifecycleContext,
    config: Config,
    job: QueuedPrompt,
) !void {
    var effective_job = job;
    if (effective_job.turn_id == 0) {
        effective_job.turn_id = debug_trace.nextTurnId();
    }
    var finalization = TurnFinalizationGuard.init(
        deps,
        effective_job.turn_id,
        lifecycle,
    );

    processQueuedPromptInner(deps, semantic_presentation, lifecycle, config, effective_job, &finalization) catch |err| {
        if (finalization.state == .open) {
            finalization.finish(.failed, null, null) catch |finalization_err| return finalization_err;
        }
        return err;
    };
    if (finalization.state == .open) {
        try finalization.finish(.completed, null, null);
    }
}

fn appendPermissionFeedbackAfterToolResult(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    batch: *runtime_tool_batch.StepBatchState,
    source_tool_call_id: []const u8,
    feedback: []const []const u8,
) !void {
    try runtime_tool_batch.appendPermissionFeedback(
        arena,
        batch,
        source_tool_call_id,
        feedback,
    );
    for (feedback) |text| {
        if (text.len == 0) continue;
        const event = worker_runtime.WorkerEvent{
            .append_user_feedback = try std.heap.c_allocator.dupe(u8, text),
        };
        errdefer worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        try deps.push_event(deps.ctx, event);
    }
}

fn requiresResolvedRequestCapabilities(
    has_images: bool,
    effort: types.ReasoningEffort,
    fast_mode: bool,
    available: model_capabilities.Capabilities,
) bool {
    return has_images or
        (!effort.isDefault() and !model_capabilities.reasoningEffortSupported(available, effort)) or
        (fast_mode and !available.supports_fast_mode);
}

fn request_max_output_tokens(capabilities: model_capabilities.Capabilities) ?u32 {
    const max_output_tokens = capabilities.max_output_tokens orelse return null;
    const context_window = capabilities.context_window orelse return max_output_tokens;
    if (max_output_tokens >= context_window) return null;
    return max_output_tokens;
}

test "request output limit follows capability bounds" {
    const cases = [_]struct {
        capabilities: model_capabilities.Capabilities,
        expected: ?u32,
    }{
        .{ .capabilities = .{}, .expected = null },
        .{ .capabilities = .{ .max_output_tokens = 32_000 }, .expected = 32_000 },
        .{ .capabilities = .{ .context_window = 256_000 }, .expected = null },
        .{ .capabilities = .{ .context_window = 256_000, .max_output_tokens = 32_000 }, .expected = 32_000 },
        .{ .capabilities = .{ .context_window = 1_048_576, .max_output_tokens = 1_048_576 }, .expected = null },
        .{ .capabilities = .{ .context_window = 128_000, .max_output_tokens = 256_000 }, .expected = null },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, request_max_output_tokens(case.capabilities));
    }
}

fn processQueuedPromptInner(
    deps: *const AgentRuntimeDeps,
    semantic_presentation: ?runtime_assistant_stream.SemanticPresentationSink,
    lifecycle: LifecycleContext,
    config: Config,
    job: QueuedPrompt,
    finalization: *TurnFinalizationGuard,
) !void {
    var summary_accumulator = runtime_telemetry.TurnSummaryAccumulator.init(
        io_mod.milliTimestamp(),
        if (config.origin == .root) job.prompt else "",
    );
    const turn_id = job.turn_id;
    var finish_trace = PromptFinishTrace{ .ctx = .{ .turn_id = turn_id, .subagent_id = config.subagent_id } };
    errdefer {
        if (config.cancel_flag.load(.seq_cst)) {
            runtime_telemetry.traceCancelObserved(finish_trace.ctx, false);
            finish_trace.finish("cancelled");
        } else {
            finish_trace.finish("http_error");
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base_nested_terminal_advertised = try terminal_request_schema_advertised(
        arena,
        config.gateway_tools_json,
    );

    var stable_prefix: std.ArrayList(ChatMessage) = .empty;
    defer stable_prefix.deinit(arena);

    var history_messages: std.ArrayList(ChatMessage) = .empty;
    defer history_messages.deinit(arena);

    var within_turn_suffix: std.ArrayList(ChatMessage) = .empty;
    defer within_turn_suffix.deinit(arena);
    if (job.recovery_checkpoint) |checkpoint| {
        try session_runtime.appendExecutionMemoryChatMessages(
            arena,
            &within_turn_suffix,
            checkpoint.execution,
        );
    }

    // The overlay arena is reset for every model step so refreshed env,
    // background snapshots do not accumulate for the whole turn.
    var overlay_arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer overlay_arena_state.deinit();

    var local_grants: std.ArrayList(PermissionGrant) = .empty;
    defer local_grants.deinit(arena);

    var completed_tool_names: std.ArrayList([]u8) = .empty;
    defer completed_tool_names.deinit(arena);
    var interrupted_persisted = false;

    debug_trace.eventf("agent", "prompt_start", finish_trace.ctx, "prompt_bytes={d} model={s}", .{ job.prompt.len, job.model });

    try stable_prefix.append(arena, .{ .role = .system, .content = config.system_prompt });
    if (config.custom_tool_guidance.len > 0) {
        try stable_prefix.append(arena, .{ .role = .system, .content = config.custom_tool_guidance });
    }
    if (config.skills_prompt_section.len > 0) {
        try stable_prefix.append(arena, .{ .role = .system, .content = config.skills_prompt_section });
    }
    if (config.model_prompt_overlay) |overlay| {
        try stable_prefix.append(arena, .{ .role = .system, .content = overlay });
    }
    if (deps.append_static_context) |append_static_context| {
        try append_static_context(deps.ctx, arena, &stable_prefix);
    }
    var request_capabilities = deps.available_model_capabilities(deps.ctx, job.model);
    if (requiresResolvedRequestCapabilities(
        job.images.len > 0 or job.authorized_image_catalog.len > 0,
        config.effort,
        config.fast_mode,
        request_capabilities,
    )) {
        request_capabilities = deps.resolve_model_capabilities(deps.ctx, arena, job.model) catch |err| {
            if (err != error.Cancelled) return err;
            runtime_telemetry.traceCancelObserved(finish_trace.ctx, false);
            var terminal_materializing = false;
            try runtime_interruption.persistInterruptedTurnOnce(
                deps,
                finalization,
                job,
                null,
                null,
                completed_tool_names.items,
                &interrupted_persisted,
                finish_trace.ctx,
                within_turn_suffix.items,
                null,
                &terminal_materializing,
            );
            finish_trace.finish("interrupted");
            return;
        };
    }
    if (config.cancel_flag.load(.seq_cst)) {
        runtime_telemetry.traceCancelObserved(finish_trace.ctx, false);
        var terminal_materializing = false;
        try runtime_interruption.persistInterruptedTurnOnce(
            deps,
            finalization,
            job,
            null,
            null,
            completed_tool_names.items,
            &interrupted_persisted,
            finish_trace.ctx,
            within_turn_suffix.items,
            null,
            &terminal_materializing,
        );
        finish_trace.finish("interrupted");
        return;
    }
    const history_messages_before = stable_prefix.items.len;
    const interrupted_turns = runtime_interruption.countInterruptedHistory(job.history);
    const partial_interrupted_closures = runtime_interruption.countPartialTextInterruptedClosures(job.history);
    const history_turn_kinds = try runtime_telemetry.formatHistoryTurnKinds(arena, job.history);
    debug_trace.eventf(
        "history",
        "projection_start",
        finish_trace.ctx,
        "history_turns={d} gateway_messages_before={d} interrupted_turns={d} history_turn_kinds={s}",
        .{ job.history.len, history_messages_before, interrupted_turns, history_turn_kinds },
    );
    try session_runtime.appendHistoryChatMessagesBudgeted(
        arena,
        &history_messages,
        job.history,
        .{ .max_tokens = runtime_prompt_context.historyContextBudgetTokensForCapabilities(request_capabilities) },
    );
    const projected_roles = try runtime_telemetry.formatMessageRoles(arena, history_messages.items);
    debug_trace.eventf(
        "history",
        "projection_end",
        finish_trace.ctx,
        "history_turns={d} gateway_messages={d} added_gateway_messages={d} interrupted_turns={d} history_turn_kinds={s} projected_message_roles={s} partial_interrupted_closures={d}",
        .{ job.history.len, stable_prefix.items.len + history_messages.items.len, history_messages.items.len, interrupted_turns, history_turn_kinds, projected_roles, partial_interrupted_closures },
    );
    for (job.grants) |grant| {
        try local_grants.append(arena, .{ .tool_name = grant.tool_name, .target_path = grant.target_path });
    }

    const current_user_message: ChatMessage = .{ .role = .user, .content = job.prompt, .images = job.images };

    var stop_state = CommonStopState{};
    processQueuedPromptLoop(
        deps,
        semantic_presentation,
        lifecycle,
        config,
        job,
        request_capabilities,
        base_nested_terminal_advertised,
        finalization,
        arena,
        turn_id,
        &stable_prefix,
        &history_messages,
        &within_turn_suffix,
        &overlay_arena_state,
        &local_grants,
        &completed_tool_names,
        &summary_accumulator,
        &finish_trace,
        &interrupted_persisted,
        current_user_message,
        &stop_state,
    ) catch |err| {
        if (stop_state.retained_candidate != null and
            !stop_state.terminal_materializing and
            finalization.state == .open)
        {
            runtime_finalization.finalizeRetainedCandidateFailure(
                deps,
                finalization,
                arena,
                job,
                within_turn_suffix.items,
                &summary_accumulator,
                &finish_trace,
                stop_state.retained_candidate,
                stop_state.latest_partial,
                &stop_state.terminal_materializing,
            ) catch |secondary_err| return secondary_err;
        } else if (!stop_state.terminal_materializing and
            finalization.state == .open)
        {
            _ = runtime_finalization.finishExecutionOnlyFailureIfNeeded(
                deps,
                finalization,
                arena,
                job,
                within_turn_suffix.items,
                &summary_accumulator,
                &finish_trace,
                &stop_state.terminal_materializing,
                "error",
            ) catch |secondary_err| return secondary_err;
        }
        return err;
    };
}

fn appendAuthorizedVisionAttemptIds(
    alloc: Allocator,
    settled_ids: *std.ArrayList(usize),
    call: ToolCall,
    catalog: []const types.ImageAttachment,
) !bool {
    if (!std.mem.eql(u8, call.name, "vision") or
        call.argument_integrity != .valid or
        call.provenance != .fx_local)
    {
        return false;
    }
    const request = runtime_vision_contracts.parse_vision_request(
        alloc,
        call.arguments_json,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer request.deinit(alloc);
    const image_ids = request.image_ids() orelse return false;
    const authorized = image_attachments.resolve_authorized_images(
        alloc,
        catalog,
        image_ids,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer alloc.free(authorized);

    var missing_count: usize = 0;
    for (image_ids) |image_id| {
        if (!containsImageId(settled_ids.items, image_id)) missing_count += 1;
    }
    try settled_ids.ensureUnusedCapacity(alloc, missing_count);

    for (image_ids) |image_id| {
        if (!containsImageId(settled_ids.items, image_id)) {
            settled_ids.appendAssumeCapacity(image_id);
        }
    }
    return true;
}

fn visionCallUsesPaths(alloc: Allocator, call: ToolCall) !bool {
    const request = runtime_vision_contracts.parse_vision_request(
        alloc,
        call.arguments_json,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer request.deinit(alloc);
    return request.paths() != null;
}

fn containsImageId(image_ids: []const usize, candidate: usize) bool {
    for (image_ids) |image_id| {
        if (image_id == candidate) return true;
    }
    return false;
}

fn buildReviewTurnContext(
    config: Config,
    model: []const u8,
    current_prompt: []const u8,
    root_user_intent_context: []const u8,
    pending_assistant: ChatMessage,
    target_call_id: []const u8,
    auto_permission_phase: permission_auto_classifier.AutoPermissionPhase,
) permission_auto_classifier.ReviewTurnContext {
    const current_root_request = currentRootRequest(
        config,
        current_prompt,
        root_user_intent_context,
    );
    return .{
        .model = model,
        .pending_assistant = pending_assistant,
        .target_call_id = target_call_id,
        .origin = switch (config.origin) {
            .root => .root,
            .subagent => .subagent,
        },
        .current_root_request = current_root_request,
        .auto_permission_phase = auto_permission_phase,
    };
}

fn currentRootRequest(
    config: Config,
    current_prompt: []const u8,
    root_user_intent_context: []const u8,
) []const u8 {
    return if (root_user_intent_context.len > 0)
        if (std.mem.count(u8, root_user_intent_context, "\n") > 1)
            auto_classifier_context.reviewRootUserContext(
                root_user_intent_context,
            ) orelse root_user_intent_context
        else
            auto_classifier_context.currentRootUserRequest(
                root_user_intent_context,
            ) orelse root_user_intent_context
    else if (config.origin == .root)
        current_prompt
    else if (config.current_prompt_is_root_authority)
        current_prompt
    else if (auto_classifier_context.currentRootUserRequest(
        config.root_user_intent_context,
    )) |request|
        request
    else if (config.root_user_messages.len > 0)
        config.root_user_messages[config.root_user_messages.len - 1]
    else
        "";
}

const AutomaticRecoveryDisposition = enum {
    continue_auto_review,
    finish_with_normal_blocker,
};

const max_automatic_denial_response_groups: usize = 4;
const automatic_permission_recovery_fallback =
    "I couldn't continue because the required actions were blocked by automatic safety checks. I need a different approach or explicit direction from you.";

fn automatic_recovery_disposition(messages: []const ChatMessage) AutomaticRecoveryDisposition {
    var blocked_groups: usize = 0;
    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        const assistant = messages[index];
        if (assistant.role != .assistant or assistant.tool_calls.len == 0) continue;
        var group_end = index + 1;
        while (group_end < messages.len and messages[group_end].role != .assistant) {
            group_end += 1;
        }
        if (!responseGroupComplete(messages[index + 1 .. group_end], assistant.tool_calls)) {
            index = group_end -| 1;
            continue;
        }
        var has_auto_denial = false;
        var resets_auto_recovery = false;
        var has_success = false;
        for (messages[index + 1 .. group_end]) |message| {
            if (message.role != .tool) continue;
            if (message.tool_result_status == .success) has_success = true;
            const output = message.content orelse continue;
            const reason = tool_result_errors.toolPermissionDenialReason(output) orelse continue;
            if (reason == .auto_denied)
                has_auto_denial = true
            else
                resets_auto_recovery = true;
        }
        if (has_success or resets_auto_recovery) {
            blocked_groups = 0;
        } else if (has_auto_denial) {
            blocked_groups +|= 1;
        }
        index = group_end -| 1;
    }
    return if (blocked_groups >= max_automatic_denial_response_groups)
        .finish_with_normal_blocker
    else
        .continue_auto_review;
}

fn responseGroupComplete(
    results: []const ChatMessage,
    calls: []const ToolCall,
) bool {
    for (calls) |call| {
        var found = false;
        for (results) |result| {
            if (result.role == .tool and
                result.tool_call_id != null and
                std.mem.eql(u8, result.tool_call_id.?, call.id))
            {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

test "automatic recovery counts completed response groups and resets after success" {
    const denied = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"auto_denied\"}}";
    const blocked_group = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "blocked", .name = "run_command", .arguments_json = "{}" }} },
        .{ .role = .tool, .content = denied, .tool_call_id = "blocked", .tool_result_status = .failure },
    };
    var three_then_current: [7]ChatMessage = undefined;
    @memcpy(three_then_current[0..2], &blocked_group);
    @memcpy(three_then_current[2..4], &blocked_group);
    @memcpy(three_then_current[4..6], &blocked_group);
    three_then_current[6] = .{ .role = .assistant, .tool_calls = &.{.{ .id = "current", .name = "run_command", .arguments_json = "{}" }} };
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(&three_then_current),
    );

    var four_blocked: [8]ChatMessage = undefined;
    @memcpy(four_blocked[0..2], &blocked_group);
    @memcpy(four_blocked[2..4], &blocked_group);
    @memcpy(four_blocked[4..6], &blocked_group);
    @memcpy(four_blocked[6..8], &blocked_group);
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.finish_with_normal_blocker,
        automatic_recovery_disposition(&four_blocked),
    );

    const success = ChatMessage{
        .role = .tool,
        .content = "ok",
        .tool_call_id = "safe",
        .tool_result_status = .success,
    };
    var reset: [10]ChatMessage = undefined;
    @memcpy(reset[0..6], three_then_current[0..6]);
    reset[6] = .{ .role = .assistant, .tool_calls = &.{.{ .id = "safe", .name = "run_command", .arguments_json = "{}" }} };
    reset[7] = success;
    reset[8] = blocked_group[0];
    reset[9] = blocked_group[1];
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(&reset),
    );
}

test "automatic recovery resets after non automatic permission denials" {
    const auto_denied = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"auto_denied\"}}";
    const user_denied = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"user_denied\"}}";
    const policy_denied = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"policy_denied\"}}";
    const permission_required = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"permission_required\"}}";
    for ([_][]const u8{ user_denied, policy_denied, permission_required }) |reset_result| {
        const messages = [_]ChatMessage{
            .{ .role = .assistant, .tool_calls = &.{.{ .id = "auto-1", .name = "run_command", .arguments_json = "{}" }} },
            .{ .role = .tool, .content = auto_denied, .tool_call_id = "auto-1", .tool_result_status = .failure },
            .{ .role = .assistant, .tool_calls = &.{.{ .id = "auto-2", .name = "run_command", .arguments_json = "{}" }} },
            .{ .role = .tool, .content = auto_denied, .tool_call_id = "auto-2", .tool_result_status = .failure },
            .{ .role = .assistant, .tool_calls = &.{.{ .id = "auto-3", .name = "run_command", .arguments_json = "{}" }} },
            .{ .role = .tool, .content = auto_denied, .tool_call_id = "auto-3", .tool_result_status = .failure },
            .{ .role = .assistant, .tool_calls = &.{.{ .id = "reset", .name = "run_command", .arguments_json = "{}" }} },
            .{ .role = .tool, .content = reset_result, .tool_call_id = "reset", .tool_result_status = .failure },
        };

        try std.testing.expectEqual(
            AutomaticRecoveryDisposition.continue_auto_review,
            automatic_recovery_disposition(&messages),
        );
    }
}

test "parallel automatic denials count as one response group" {
    const denied = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"auto_denied\"}}";
    const calls = [_]ToolCall{
        .{ .id = "one", .name = "run_command", .arguments_json = "{}" },
        .{ .id = "two", .name = "run_command", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = denied, .tool_call_id = "one", .tool_result_status = .failure },
        .{ .role = .tool, .content = denied, .tool_call_id = "two", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &calls },
    };
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(&messages),
    );
}

test "a mixed parallel response group resets recovery regardless result order" {
    const denied = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"auto_denied\"}}";
    const calls = [_]ToolCall{
        .{ .id = "safe", .name = "run_command", .arguments_json = "{}" },
        .{ .id = "blocked", .name = "run_command", .arguments_json = "{}" },
    };
    const current = ChatMessage{
        .role = .assistant,
        .tool_calls = &.{.{ .id = "current", .name = "run_command", .arguments_json = "{}" }},
    };
    var success_first: [10]ChatMessage = undefined;
    var denial_first: [10]ChatMessage = undefined;
    for (0..3) |group_index| {
        const start = group_index * 3;
        success_first[start] = .{ .role = .assistant, .tool_calls = &calls };
        success_first[start + 1] = .{ .role = .tool, .content = "ok", .tool_call_id = "safe", .tool_result_status = .success };
        success_first[start + 2] = .{ .role = .tool, .content = denied, .tool_call_id = "blocked", .tool_result_status = .failure };
        denial_first[start] = success_first[start];
        denial_first[start + 1] = success_first[start + 2];
        denial_first[start + 2] = success_first[start + 1];
    }
    success_first[9] = current;
    denial_first[9] = current;
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(&success_first),
    );
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(&denial_first),
    );
}

test "automatic recovery disposition depends only on completed response groups" {
    const denied = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"auto_denied\"}}";
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "one", .name = "run_command", .arguments_json = "{}" }} },
        .{ .role = .tool, .content = denied, .tool_call_id = "one", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "two", .name = "run_command", .arguments_json = "{}" }} },
        .{ .role = .tool, .content = denied, .tool_call_id = "two", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "three", .name = "run_command", .arguments_json = "{}" }} },
        .{ .role = .tool, .content = denied, .tool_call_id = "three", .tool_result_status = .failure },
    };

    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(&.{}),
    );
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(messages[0..2]),
    );
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(messages[0..4]),
    );
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(&messages),
    );

    var with_unrelated_prefix: [10]ChatMessage = undefined;
    with_unrelated_prefix[0] = .{ .role = .user, .content = "unrelated earlier request" };
    with_unrelated_prefix[1] = .{ .role = .assistant, .content = "unrelated earlier response" };
    @memcpy(with_unrelated_prefix[2..8], &messages);
    with_unrelated_prefix[8] = .{ .role = .assistant, .tool_calls = &.{.{ .id = "four", .name = "run_command", .arguments_json = "{}" }} };
    with_unrelated_prefix[9] = .{ .role = .tool, .content = denied, .tool_call_id = "four", .tool_result_status = .failure };
    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.finish_with_normal_blocker,
        automatic_recovery_disposition(&with_unrelated_prefix),
    );
}

test "incomplete parallel response groups do not advance automatic recovery" {
    const denied = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"auto_denied\"}}";
    const parallel_calls = [_]ToolCall{
        .{ .id = "incomplete-1", .name = "run_command", .arguments_json = "{}" },
        .{ .id = "incomplete-2", .name = "run_command", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "one", .name = "run_command", .arguments_json = "{}" }} },
        .{ .role = .tool, .content = denied, .tool_call_id = "one", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "two", .name = "run_command", .arguments_json = "{}" }} },
        .{ .role = .tool, .content = denied, .tool_call_id = "two", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &parallel_calls },
        .{ .role = .tool, .content = denied, .tool_call_id = "incomplete-1", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "current", .name = "run_command", .arguments_json = "{}" }} },
    };

    try std.testing.expectEqual(
        AutomaticRecoveryDisposition.continue_auto_review,
        automatic_recovery_disposition(&messages),
    );
}

fn appendTrustedPermissionFeedback(
    alloc: Allocator,
    feedback: *std.ArrayList([]const u8),
    messages: []const ChatMessage,
) !void {
    for (messages) |message| {
        if (message.role != .user or !message.permission_feedback) continue;
        const content = message.content orelse continue;
        if (content.len > 0) try feedback.append(alloc, content);
    }
}

fn buildToolExecutionRootUserContext(
    alloc: Allocator,
    root_user_context: []const u8,
    within_turn_suffix: []const ChatMessage,
    pending_user_suffix: []const ChatMessage,
) ![]u8 {
    var trusted_permission_feedback: std.ArrayList([]const u8) = .empty;
    defer trusted_permission_feedback.deinit(alloc);
    try appendTrustedPermissionFeedback(alloc, &trusted_permission_feedback, within_turn_suffix);
    try appendTrustedPermissionFeedback(alloc, &trusted_permission_feedback, pending_user_suffix);
    return auto_classifier_context.buildToolExecutionRootUserContext(
        alloc,
        root_user_context,
        trusted_permission_feedback.items,
    );
}

fn actionBoundPermissionResult(
    alloc: Allocator,
    request_id: runtime_tool_admission.PermissionActionId,
    decision: types.ToolPermissionDecision,
    authorized: bool,
) ![]u8 {
    const request_hex = std.fmt.bytesToHex(request_id, .lower);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"permission_request_id\":");
    try std.json.Stringify.value(&request_hex, .{}, &out.writer);
    try out.writer.writeAll(",\"authorized\":");
    try out.writer.writeAll(if (authorized) "true" else "false");
    try out.writer.writeAll(",\"decision\":");
    try std.json.Stringify.value(@tagName(decision), .{}, &out.writer);
    try out.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(
        if (authorized)
            "The exact bound action was approved. Retry only that action unchanged."
        else
            "The exact bound action was not approved. Do not retry it unchanged.",
        .{},
        &out.writer,
    );
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn invalidActionBoundPermissionResult(
    alloc: Allocator,
    message: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"error\":{\"type\":\"permission_request_invalid\",\"message\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn executeActionBoundPermissionRequest(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    recovery: *runtime_tool_admission.TurnPermissionRecovery,
    call: ToolCall,
    review_context: permission_auto_classifier.ReviewTurnContext,
    local_grants: []const PermissionGrant,
    advertised_dynamic_tool_names: []const []const u8,
    workspace_root: []const u8,
    step_ctx: TraceContext,
) !?ToolExecutionResult {
    if (!std.mem.eql(u8, call.name, "ask_user_question")) return null;
    const reference = try ask_user_question.permissionRequestReference(
        arena,
        call.arguments_json,
    );
    const request_id = switch (reference) {
        .none => return null,
        .invalid => return .{
            .status = .failure,
            .model_output = try invalidActionBoundPermissionResult(
                arena,
                "permission_request_id must be the exact 64-character ID from an auto_denied result",
            ),
        },
        .id => |value| value,
    };
    const denied_call = recovery.deniedCall(request_id) orelse return .{
        .status = .failure,
        .model_output = try invalidActionBoundPermissionResult(
            arena,
            "permission_request_id is not pending in this agent turn",
        ),
    };

    var live_authority: ?runtime_tool_contracts.LiveToolAuthority = null;
    var permission_grants = local_grants;
    if (deps.live_tool_authority != null) {
        const resolved = try resolveLiveToolAuthority(
            deps,
            arena,
            denied_call,
            workspace_root,
            advertised_dynamic_tool_names,
            null,
        );
        if (liveAuthorityRejectsExecution(resolved)) return .{
            .status = .failure,
            .model_output = try actionBoundPermissionResult(
                arena,
                request_id,
                if (resolved.decision == .deny)
                    .policy_denied
                else
                    .permission_required,
                false,
            ),
        };
        live_authority = resolved.authority;
        permission_grants = resolved.authority.grants;
    }
    const outcome = runtime_tool_admission.requestToolPermissionTraced(
        deps,
        arena,
        denied_call,
        review_context,
        .ask,
        permission_grants,
        live_authority,
        null,
        advertised_dynamic_tool_names,
        workspace_root,
        step_ctx,
    ) catch |err| switch (err) {
        error.NonInteractivePermissionRequired,
        error.PermissionPromptUnavailable,
        => return .{
            .status = .failure,
            .model_output = try actionBoundPermissionResult(
                arena,
                request_id,
                .permission_required,
                false,
            ),
        },
        else => return err,
    };
    if (outcome.tool_failure) |failure| return .{
        .status = .failure,
        .model_output = failure,
    };
    const authority = outcome.execution_authority;
    const authorized = !outcome.decision.isDenied() and
        authority != null and
        recovery.rememberApproval(
            request_id,
            authority.?,
            outcome.human_approval,
        );
    return .{
        .status = if (authorized or outcome.decision == .deny)
            .success
        else
            .failure,
        .model_output = try actionBoundPermissionResult(
            arena,
            request_id,
            outcome.decision,
            authorized,
        ),
    };
}

fn visionFallbackMode(
    provider: model_provider.ProviderId,
    tool_registered: bool,
) runtime_gateway_step.VisionToolMode {
    if (!model_provider.usesGatewayAuxiliaries(provider) or !tool_registered) {
        return .unavailable;
    }
    return .optional;
}

test "vision fallback is available only through Gateway" {
    try std.testing.expectEqual(
        runtime_gateway_step.VisionToolMode.optional,
        visionFallbackMode(.gateway, true),
    );
    try std.testing.expectEqual(
        runtime_gateway_step.VisionToolMode.unavailable,
        visionFallbackMode(.gateway, false),
    );
    try std.testing.expectEqual(
        runtime_gateway_step.VisionToolMode.unavailable,
        visionFallbackMode(.codex, true),
    );
}

fn processQueuedPromptLoop(
    deps: *const AgentRuntimeDeps,
    semantic_presentation: ?runtime_assistant_stream.SemanticPresentationSink,
    lifecycle: LifecycleContext,
    config: Config,
    job: QueuedPrompt,
    request_capabilities: model_capabilities.Capabilities,
    base_nested_terminal_advertised: bool,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    turn_id: u64,
    stable_prefix_ptr: *std.ArrayList(ChatMessage),
    history_messages_ptr: *std.ArrayList(ChatMessage),
    within_turn_suffix_ptr: *std.ArrayList(ChatMessage),
    overlay_arena_state: *std.heap.ArenaAllocator,
    local_grants_ptr: *std.ArrayList(PermissionGrant),
    completed_tool_names_ptr: *std.ArrayList([]u8),
    summary_accumulator_ptr: *runtime_telemetry.TurnSummaryAccumulator,
    finish_trace_ptr: *PromptFinishTrace,
    interrupted_persisted_ptr: *bool,
    current_user_message: ChatMessage,
    stop_state: *CommonStopState,
) !void {
    var stable_prefix = stable_prefix_ptr.*;
    defer stable_prefix_ptr.* = stable_prefix;
    const history_messages = history_messages_ptr.*;
    var within_turn_suffix = within_turn_suffix_ptr.*;
    defer within_turn_suffix_ptr.* = within_turn_suffix;
    var local_grants = local_grants_ptr.*;
    defer local_grants_ptr.* = local_grants;
    var turn_file_mutation_denials: runtime_tool_admission.TurnFileMutationDenials = .{};
    defer turn_file_mutation_denials.deinit(arena);
    var turn_permission_recovery: runtime_tool_admission.TurnPermissionRecovery = .{};
    defer turn_permission_recovery.deinit(arena);
    var terminal_validation_retry: runtime_tool_admission.TerminalValidationRetryState = .{};
    defer terminal_validation_retry.deinit(arena);
    var malformed_arguments_retry: runtime_tool_admission.MalformedArgumentsRetryState = .{};
    var completed_tool_names = completed_tool_names_ptr.*;
    defer completed_tool_names_ptr.* = completed_tool_names;
    var context_delivery_state: context_contract.DeliveryState = if (deps.context_enabled)
        try context_contract.DeliveryState.initFromSnapshot(arena, job.context_snapshot)
    else
        .{};
    defer context_delivery_state.deinit(arena);
    const root_user_intent_context = switch (config.origin) {
        .subagent => config.root_user_intent_context,
        .root => if (job.root_user_intent_context.len > 0)
            job.root_user_intent_context
        else
            try auto_classifier_context.buildCanonicalRootUserContext(
                arena,
                job.prompt,
                job.history,
            ),
    };
    var active_api_key: []const u8 = job.api_key;
    var owned_refreshed_api_key: ?[]u8 = null;
    defer if (owned_refreshed_api_key) |key| secret.zeroAndFree(std.heap.c_allocator, key);
    var summary_accumulator = summary_accumulator_ptr.*;
    defer summary_accumulator_ptr.* = summary_accumulator;
    var finish_trace = finish_trace_ptr.*;
    defer finish_trace_ptr.* = finish_trace;
    var interrupted_persisted = interrupted_persisted_ptr.*;
    defer interrupted_persisted_ptr.* = interrupted_persisted;
    var silent_tool_steps: usize = 0;
    var continuation_injected = false;
    var last_step_ctx = finish_trace.ctx;
    var current_step_index: usize = 0;
    var last_tool_call_name: []const u8 = "none";
    var last_tool_call_id: []const u8 = "none";
    var last_gateway_message_count: usize = stable_prefix.items.len + history_messages.items.len + 1;
    var selected_dynamic_tool_names: std.ArrayList([]const u8) = .empty;
    var selected_dynamic_tool_schemas: std.ArrayList([]const u8) = .empty;
    const current_user_effective = current_user_message;
    const initial_pending_image_ids = try arena.alloc(usize, job.images.len);
    for (job.images, 0..) |attachment, index| initial_pending_image_ids[index] = attachment.id;
    if (initial_pending_image_ids.len > 0) {
        try image_attachments.validate_image_ids(initial_pending_image_ids);
    }
    var pending_image_ids: []const usize = initial_pending_image_ids;
    var configured_first_tool_choice_pending = true;
    var active_presentation_group_id: ?types.ToolPresentationGroupId = null;
    const restored_attempts = if (job.recovery_checkpoint) |checkpoint|
        restoredConsumedAttempts(checkpoint)
    else
        0;
    const selected_fast_mode = config.fast_mode;
    const selection_changed = if (job.recovery_checkpoint) |checkpoint|
        recoverySelectionChanged(checkpoint, job.provider, job.model, selected_fast_mode)
    else
        false;
    const restored_budget_exhausted = if (job.recovery_checkpoint) |checkpoint|
        !selection_changed and restored_attempts >= checkpoint.max_provider_attempts
    else
        false;
    const semantic_limit = if (selection_changed or restored_budget_exhausted)
        semanticAttemptLimit(config.max_provider_attempts)
    else if (job.recovery_checkpoint) |checkpoint|
        checkpoint.max_provider_attempts
    else
        semanticAttemptLimit(config.max_provider_attempts);
    var route_fast_mode = if (selection_changed)
        selected_fast_mode
    else if (job.recovery_checkpoint) |checkpoint|
        checkpoint.fast_mode
    else
        selected_fast_mode;
    var semantic_attempt: usize = if (selection_changed or restored_budget_exhausted)
        0
    else
        restored_attempts;
    var retry_pacing: model_response_recovery.RetryPacingState = .idle;
    var recovery_strategy: ?model_response_recovery.Strategy = if (job.recovery_checkpoint) |checkpoint|
        restoredRecoveryStrategy(checkpoint)
    else
        null;
    var recovery_cause: model_response_recovery.FailureCause = if (job.recovery_checkpoint) |checkpoint|
        restoredRecoveryCause(checkpoint.cause)
    else
        .transport_interrupted;
    var latest_recovery_diagnostic: ?types.ModelFailureDiagnostic = null;
    var preserved_tool_evidence: model_response_recovery.ToolEvidence = if (job.recovery_checkpoint) |checkpoint|
        restoredRecoveryToolEvidence(checkpoint.tool_state)
    else
        .none;
    var restore_recovery_source = job.recovery_checkpoint != null;
    var step: usize = 0;
    while (agent_steps.allowsStep(config.agent_step_limit, step)) : (step += 1) {
        current_step_index = step + 1;
        const step_ctx: TraceContext = .{ .turn_id = turn_id, .step_id = debug_trace.nextStepId(), .subagent_id = config.subagent_id };
        const presentation_group_id = runtime_tool_presentation.presentationGroupForStep(
            active_presentation_group_id,
            turn_id,
            step_ctx.step_id,
        );
        last_step_ctx = step_ctx;
        if (config.cancel_flag.load(.seq_cst)) {
            runtime_telemetry.traceCancelObserved(step_ctx, false);
            try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, null, null, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
            finish_trace.finish("interrupted");
            return;
        }
        if (automatic_recovery_disposition(within_turn_suffix.items) == .finish_with_normal_blocker) {
            try finish_automatic_permission_recovery(
                deps,
                finalization,
                arena,
                job,
                within_turn_suffix.items,
                &summary_accumulator,
                stop_state,
                &finish_trace,
                step_ctx,
            );
            return;
        }
        const auto_permission_phase: permission_auto_classifier.AutoPermissionPhase =
            .automatic_review;
        _ = overlay_arena_state.reset(.retain_capacity);
        const overlay_arena = overlay_arena_state.allocator();
        var ephemeral_overlay: std.ArrayList(ChatMessage) = .empty;
        if (config.explicit_skills_prompt_section.len > 0) {
            try ephemeral_overlay.append(overlay_arena, .{ .role = .system, .content = config.explicit_skills_prompt_section });
        }
        try deps.append_runtime_context(deps.ctx, overlay_arena, &ephemeral_overlay);
        var parent_turn_delivery = try appendPreparedParentTurnContext(
            deps,
            overlay_arena,
            &ephemeral_overlay,
        );
        var gateway_messages = try runtime_prompt_context.buildGatewayMessages(overlay_arena, stable_prefix.items, ephemeral_overlay.items, history_messages.items, current_user_effective, within_turn_suffix.items);
        last_gateway_message_count = gateway_messages.items.len;
        const history_start_index = stable_prefix.items.len + ephemeral_overlay.items.len;
        const current_user_message_index = history_start_index + history_messages.items.len;

        debug_trace.logf("agent", "step start step={d} limit={d} messages={d}", .{ current_step_index, config.agent_step_limit, gateway_messages.items.len });
        debug_trace.eventf("agent", "step_begin", step_ctx, "step_index={d} step_limit={d} gateway_messages={d}", .{ current_step_index, config.agent_step_limit, gateway_messages.items.len });

        var stream_ctx = runtime_assistant_stream.StreamChunkContext{
            .hooks = deps,
            .flush_assistant_stream_per_content_chunk = deps.flush_assistant_stream_per_content_chunk,
            .semantic_presentation = semantic_presentation,
            .token_progress = &summary_accumulator,
            .turn_id = turn_id,
            .step_id = step_ctx.step_id,
            .provisional_statuses = .{
                .presentation_group_id = presentation_group_id,
            },
        };
        defer stream_ctx.deinit();

        if (restore_recovery_source) {
            const checkpoint = job.recovery_checkpoint.?;
            try stream_ctx.restoreRecoverySource(
                checkpoint.assistant_source,
                job.recovery_source_already_presented,
            );
            stream_ctx.beginRecoveryAttempt();
            restore_recovery_source = false;
        }

        const advertised_dynamic_tool_names = selected_dynamic_tool_names.items;
        var stream_result: runtime_gateway_step.StreamResult = undefined;
        var stream_result_set = false;
        var gateway_model: []const u8 = job.model;
        var successful_request_messages: []const ChatMessage = &.{};
        var successful_source_messages: []const ChatMessage = &.{};
        var successful_gateway_model: []const u8 = "";
        var successful_vision_route: runtime_vision_contracts.VisionRoute = .native_images;
        var successful_vision_mode: runtime_gateway_step.VisionToolMode = .unavailable;
        var reset_stream_for_next_attempt = false;
        var auth_retry_used = false;
        var assistant_prefill_recovery_used = false;
        var skip_next_preflight_refresh = false;
        var recovery_has_unexecuted_tool_start = false;
        var successful_recovery_strategy: ?model_response_recovery.Strategy = null;
        defer {
            if (recovery_has_unexecuted_tool_start) {
                const settlement = if (config.cancel_flag.load(.seq_cst))
                    stream_ctx.provisional_statuses.finishTrackedCancelled(
                        deps,
                        stream_ctx.alloc,
                        arena,
                        turn_id,
                    )
                else
                    stream_ctx.provisional_statuses.finishUnmatchedRecoveryStarts(
                        deps,
                        stream_ctx.alloc,
                        arena,
                        turn_id,
                        &.{},
                    );
                settlement catch |err| {
                    debug_trace.logf(
                        "agent",
                        "failed to settle interrupted tool starts err={s}",
                        .{@errorName(err)},
                    );
                };
            }
        }

        while (true) {
            if (reset_stream_for_next_attempt) {
                stream_ctx.beginRecoveryAttempt();
                reset_stream_for_next_attempt = false;
            }

            gateway_model = job.model;
            if (recoveryPauseRequested(config)) {
                recovery_strategy = .pause;
                try persistRecoveryCheckpoint(
                    deps,
                    arena,
                    job,
                    within_turn_suffix.items,
                    try recoveryCheckpointAssistantSource(
                        arena,
                        stop_state,
                        stream_ctx.raw_text.items,
                    ),
                    gateway_model,
                    selected_fast_mode,
                    route_fast_mode,
                    semantic_limit,
                    semantic_attempt,
                    false,
                    recovery_cause,
                    recovery_strategy,
                    preserved_tool_evidence,
                    step_ctx,
                );
                try finishRecoveryPaused(
                    deps,
                    finalization,
                    &finish_trace,
                    recovery_cause,
                    semantic_attempt,
                    semantic_limit,
                    pausedRequiredAction(preserved_tool_evidence),
                    latest_recovery_diagnostic,
                );
                return;
            }
            if (semantic_attempt >= semantic_limit) {
                recovery_cause = .request_limit_reached;
                recovery_strategy = .pause;
                try persistRecoveryCheckpoint(
                    deps,
                    arena,
                    job,
                    within_turn_suffix.items,
                    try recoveryCheckpointAssistantSource(
                        arena,
                        stop_state,
                        stream_ctx.raw_text.items,
                    ),
                    gateway_model,
                    selected_fast_mode,
                    route_fast_mode,
                    semantic_limit,
                    semantic_attempt,
                    false,
                    recovery_cause,
                    recovery_strategy,
                    preserved_tool_evidence,
                    step_ctx,
                );
                try finishRecoveryPaused(
                    deps,
                    finalization,
                    &finish_trace,
                    recovery_cause,
                    semantic_attempt,
                    semantic_limit,
                    pausedRequiredAction(preserved_tool_evidence),
                    defaultRecoveryDiagnostic(.request_limit_reached),
                );
                return;
            }
            if (skip_next_preflight_refresh) {
                skip_next_preflight_refresh = false;
            } else {
                _ = try refreshGatewayCredentialForJob(
                    deps,
                    std.heap.c_allocator,
                    job,
                    .if_needed,
                    &active_api_key,
                    &owned_refreshed_api_key,
                    step_ctx,
                );
            }
            gateway_messages = try runtime_prompt_context.buildGatewayMessages(
                overlay_arena,
                stable_prefix.items,
                ephemeral_overlay.items,
                history_messages.items,
                current_user_effective,
                within_turn_suffix.items,
            );
            debug_trace.eventf("gateway", "before_payload_build", step_ctx, "model={s} gateway_messages={d}", .{ gateway_model, gateway_messages.items.len });
            var vision_route: runtime_vision_contracts.VisionRoute = .native_images;
            var vision_mode = visionFallbackMode(
                job.provider,
                deps.tool_registry.lookup("vision") != null,
            );
            const recovery_source_messages = try appendReadFailureRecoveryContext(
                overlay_arena,
                gateway_messages.items,
                recovery_strategy,
                try recoveryCheckpointAssistantSource(
                    arena,
                    stop_state,
                    stream_ctx.raw_text.items,
                ),
            );
            const projected_request_messages = blk: {
                if (job.authorized_image_catalog.len == 0 and job.images.len == 0) {
                    break :blk recovery_source_messages;
                }
                if (request_capabilities.supports_vision and request_capabilities.supports_file_input) {
                    break :blk try runtime_vision_contracts.project_native_messages(
                        overlay_arena,
                        recovery_source_messages,
                        current_user_message_index,
                    );
                }
                if (!model_provider.usesGatewayAuxiliaries(job.provider)) {
                    return error.SubscriptionNativeImageUnavailable;
                }
                if (job.authorized_image_catalog.len == 0) {
                    return error.MissingAuthorizedImageCatalog;
                }
                vision_route = .text_only;
                vision_mode = if (pending_image_ids.len > 0) .required else .optional;
                break :blk try runtime_vision_contracts.project_text_only_messages(
                    overlay_arena,
                    recovery_source_messages,
                    current_user_message_index,
                    job.authorized_image_catalog,
                );
            };
            const request_messages = projected_request_messages;
            last_gateway_message_count = request_messages.len;
            const provider_opts = model_capabilities.resolveProviderOptionsForCapabilities(request_capabilities, config.effort, route_fast_mode);
            runtime_telemetry.traceGatewayProviderOptions(step_ctx, gateway_model, route_fast_mode, config.effort, provider_opts);
            const tool_choice: types.ToolChoice = if (recovery_strategy == .reconcile_tool)
                .none
            else if (configured_first_tool_choice_pending and vision_mode != .required)
                config.first_call_tool_choice
            else
                .auto;
            var verified_images: std.ArrayList(image_attachments.VerifiedSnapshot) = .empty;
            if (job.provider != .gateway and job.images.len > 0 and
                request_capabilities.supports_vision and request_capabilities.supports_file_input)
            {
                try verified_images.ensureTotalCapacity(overlay_arena, job.images.len);
                for (job.images) |attachment| {
                    verified_images.appendAssumeCapacity(try image_attachments.loadVerifiedSnapshot(
                        overlay_arena,
                        attachment,
                        .{ .cancel_flag = config.cancel_flag },
                    ));
                }
            }
            const request_payload = deps.agent_stream_provider.build(
                overlay_arena,
                .{
                    .model = gateway_model,
                    .tool_registry = deps.tool_registry,
                    .serialized_tools = config.gateway_tools_json,
                    .messages = request_messages,
                    .tool_choice = tool_choice,
                    .selected_dynamic_tool_schemas = selected_dynamic_tool_schemas.items,
                    .vision_mode = vision_mode,
                    .provider_options = provider_opts,
                    .max_output_tokens = request_max_output_tokens(request_capabilities),
                    .budget = .{ .cancel_flag = config.cancel_flag },
                    .verified_images = if (verified_images.items.len > 0)
                        verified_images.items
                    else
                        null,
                },
            ) catch |err| {
                if (err == error.Cancelled) {
                    runtime_telemetry.traceCancelObserved(step_ctx, false);
                    try clearAutoRetryStatusIfNeeded(deps, recovery_strategy != null);
                    try runtime_interruption.persistInterruptedTurnOnce(
                        deps,
                        finalization,
                        job,
                        null,
                        null,
                        completed_tool_names.items,
                        &interrupted_persisted,
                        step_ctx,
                        within_turn_suffix.items,
                        stop_state.retained_candidate,
                        &stop_state.terminal_materializing,
                    );
                    finish_trace.finish("interrupted");
                    return;
                }
                return err;
            };
            summary_accumulator.prepareTokenRequest();
            runtime_assistant_stream.pushTokenProgressUpdate(&stream_ctx, .changed) catch |progress_err| {
                debug_trace.logf("agent", "token progress publication failed source=gateway_prepare err={s}", .{@errorName(progress_err)});
            };
            debug_trace.eventf("gateway", "after_payload_build", step_ctx, "payload_bytes={d} model={s} gateway_messages={d}", .{ request_payload.len, gateway_model, request_messages.len });
            runtime_telemetry.traceGatewayRequestBuilt(
                step_ctx,
                gateway_model,
                request_payload.len,
                request_messages.len,
                config.gateway_tools_json,
            );
            if (job.provider == .gateway) {
                try persistRecoveryCheckpoint(
                    deps,
                    arena,
                    job,
                    within_turn_suffix.items,
                    stream_ctx.raw_text.items,
                    gateway_model,
                    selected_fast_mode,
                    route_fast_mode,
                    semantic_limit,
                    semantic_attempt,
                    true,
                    recovery_cause,
                    recovery_strategy,
                    effectiveRecoveryToolEvidence(
                        preserved_tool_evidence,
                        null,
                        &stream_ctx,
                    ),
                    step_ctx,
                );
            }

            const gateway_wait_started_ms = io_mod.milliTimestamp();
            var gateway_delivery = runtime_gateway_step.DeliveryCertainty.init();
            var gateway_attempt_evidence: runtime_gateway_step.AttemptEvidence = .{};
            stream_result = runtime_gateway_step.streamGatewayCompletion(
                deps.agent_stream_provider,
                arena,
                active_api_key,
                job.credential_source,
                job.account_id,
                job.gateway_team,
                lifecycle.scope.session_id,
                gateway_model,
                config.gateway_retry_count,
                config.gateway_chat_url,
                request_payload,
                deps.cooperative_transport_pulse,
                &gateway_delivery,
                &gateway_attempt_evidence,
                @ptrCast(&stream_ctx),
                runtime_assistant_stream.onStreamContentChunk,
                if (vision_mode == .required)
                    onRequiredVisionStreamToolStart
                else
                    runtime_assistant_stream.onStreamToolStart,
                runtime_assistant_stream.onStreamReasoningChunk,
                runtime_assistant_stream.onStreamToolInputChunk,
                config.cancel_flag,
                deps.usage,
                deps.usage_allocator,
                step_ctx,
                null,
                .agent,
            ) catch |err| {
                parent_turn_delivery.observeGatewayDelivery(
                    deps,
                    overlay_arena,
                    gateway_delivery.load(),
                );
                runtime_assistant_stream.pushTokenProgressUpdate(&stream_ctx, summary_accumulator.finishTokenRequestWithoutUsage(gateway_delivery.load() == .possibly_sent)) catch |progress_err| {
                    debug_trace.logf("agent", "token progress publication failed source=gateway_error err={s}", .{@errorName(progress_err)});
                };
                const cancel_requested = config.cancel_flag.load(.seq_cst);
                const consumed_attempts = semantic_attempt +
                    @as(usize, @intFromBool(gateway_attempt_evidence.provider_admitted));
                const network_failure = gateway_attempt_evidence.network_failure;
                const failure_cause: model_response_recovery.FailureCause = if (network_failure) |evidence|
                    switch (evidence.cause) {
                        .transport_interrupted => .transport_interrupted,
                        .system_resumed => .system_resumed,
                    }
                else
                    recovery_cause;
                const failure_diagnostic = types.ModelFailureDiagnostic.init(@errorName(err));
                latest_recovery_diagnostic = failure_diagnostic;
                if (recoveryPauseRequested(config)) {
                    try persistRecoveryCheckpoint(
                        deps,
                        arena,
                        job,
                        within_turn_suffix.items,
                        try recoveryCheckpointAssistantSource(
                            arena,
                            stop_state,
                            stream_ctx.raw_text.items,
                        ),
                        gateway_model,
                        selected_fast_mode,
                        route_fast_mode,
                        semantic_limit,
                        consumed_attempts,
                        false,
                        failure_cause,
                        .pause,
                        effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            null,
                            &stream_ctx,
                        ),
                        step_ctx,
                    );
                    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
                    try finishRecoveryPaused(
                        deps,
                        finalization,
                        &finish_trace,
                        failure_cause,
                        consumed_attempts,
                        semantic_limit,
                        pausedRequiredAction(effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            null,
                            &stream_ctx,
                        )),
                        failure_diagnostic,
                    );
                    return;
                }
                var recovery_decision = if (network_failure) |evidence|
                    model_response_recovery.decide(.{
                        .cause = failure_cause,
                        .delivery = switch (evidence.delivery) {
                            .definitely_unsent => .definitely_unsent,
                            .possibly_sent => .possibly_sent,
                        },
                        .attempts = .{ .consumed = consumed_attempts, .limit = semantic_limit },
                        .pacing = retry_pacing,
                        .output = if (stream_ctx.raw_text.items.len > 0) .partial else .none,
                        .tool = effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            null,
                            &stream_ctx,
                        ),
                        .cancelled = cancel_requested,
                    })
                else
                    model_response_recovery.Decision{ .strategy = .stop };
                const replay_safe = network_failure != null and streamReplaySafe(&stream_ctx);
                const reconciliation_tool_violation =
                    recovery_strategy == .reconcile_tool and stream_ctx.saw_tool_start;
                if (reconciliation_tool_violation) {
                    recovery_decision = .{
                        .strategy = .pause,
                        .required_action = .inspect_uncertain_tool,
                    };
                }
                const will_auto_retry = recovery_decision.reserve_provider_attempt;
                debug_trace.eventf(
                    "gateway",
                    "stream_error",
                    step_ctx,
                    "err={s} cancel_requested={s} provider_attempts={d}/{d} saw_content={s} saw_tool_start={s} saw_provider_tool_start={s} recovery={s} replay_safe={s} retry={s}",
                    .{
                        @errorName(err),
                        if (cancel_requested) "true" else "false",
                        consumed_attempts,
                        semantic_limit,
                        if (stream_ctx.saw_visible_text) "true" else "false",
                        if (stream_ctx.saw_tool_start) "true" else "false",
                        if (stream_ctx.saw_provider_tool_start) "true" else "false",
                        @tagName(recovery_decision.strategy),
                        if (replay_safe) "true" else "false",
                        if (will_auto_retry) "true" else "false",
                    },
                );
                if (stop_state.retained_candidate != null) {
                    try copyLatestStopPartial(
                        arena,
                        stop_state,
                        stream_ctx.raw_text.items,
                    );
                }
                try persistRecoveryCheckpoint(
                    deps,
                    arena,
                    job,
                    within_turn_suffix.items,
                    try recoveryCheckpointAssistantSource(
                        arena,
                        stop_state,
                        stream_ctx.raw_text.items,
                    ),
                    gateway_model,
                    selected_fast_mode,
                    route_fast_mode,
                    semantic_limit,
                    consumed_attempts,
                    false,
                    failure_cause,
                    recovery_decision.strategy,
                    effectiveRecoveryToolEvidence(
                        preserved_tool_evidence,
                        null,
                        &stream_ctx,
                    ),
                    step_ctx,
                );
                const auto_retry_status_published = will_auto_retry;
                if (auto_retry_status_published) {
                    try pushAutoRetryStatus(
                        deps,
                        consumed_attempts,
                        semantic_limit,
                        failure_cause,
                        recovery_decision,
                        failure_diagnostic,
                    );
                }
                const delay_completed = !will_auto_retry or waitForRecoveryDelay(
                    config.cancel_flag,
                    recovery_decision.delay_ns,
                );
                if (recoveryPauseRequested(config)) {
                    try persistRecoveryCheckpoint(
                        deps,
                        arena,
                        job,
                        within_turn_suffix.items,
                        try recoveryCheckpointAssistantSource(
                            arena,
                            stop_state,
                            stream_ctx.raw_text.items,
                        ),
                        gateway_model,
                        selected_fast_mode,
                        route_fast_mode,
                        semantic_limit,
                        consumed_attempts,
                        false,
                        failure_cause,
                        .pause,
                        effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            null,
                            &stream_ctx,
                        ),
                        step_ctx,
                    );
                    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
                    try finishRecoveryPaused(
                        deps,
                        finalization,
                        &finish_trace,
                        failure_cause,
                        consumed_attempts,
                        semantic_limit,
                        pausedRequiredAction(effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            null,
                            &stream_ctx,
                        )),
                        failure_diagnostic,
                    );
                    return;
                }
                if (cancel_requested or !delay_completed) {
                    runtime_telemetry.traceCancelObserved(step_ctx, false);
                    try clearAutoRetryStatusIfNeeded(
                        deps,
                        recovery_strategy != null or auto_retry_status_published,
                    );
                    try stream_ctx.provisional_statuses.finishTrackedCancelled(
                        deps,
                        stream_ctx.alloc,
                        arena,
                        turn_id,
                    );
                    try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, stream_ctx.raw_text.items, null, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                    finish_trace.finish("interrupted");
                    return;
                }
                if (will_auto_retry) {
                    preserved_tool_evidence = effectiveRecoveryToolEvidence(
                        preserved_tool_evidence,
                        null,
                        &stream_ctx,
                    );
                    recovery_strategy = recovery_decision.strategy;
                    recovery_cause = failure_cause;
                    retry_pacing = recovery_decision.next_pacing;
                    if (recovery_strategy == .regenerate_tool) {
                        recovery_has_unexecuted_tool_start = true;
                    }
                    semantic_attempt = consumed_attempts;
                    reset_stream_for_next_attempt = true;
                    continue;
                }
                if (recovery_decision.strategy == .pause) {
                    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
                    try finishRecoveryPaused(
                        deps,
                        finalization,
                        &finish_trace,
                        failure_cause,
                        consumed_attempts,
                        semantic_limit,
                        recoveryRequiredAction(recovery_decision.required_action),
                        failure_diagnostic,
                    );
                    return;
                }
                if (network_failure != null) {
                    const exhausted_retryable =
                        stream_ctx.raw_text.items.len == 0 and
                        !stream_ctx.saw_provider_tool_start and
                        semantic_attempt + 1 >= semantic_limit;
                    if (replay_safe or exhausted_retryable) {
                        try pushRouteRecoveryStatus(deps, .{
                            .kind = .terminal_provider_error,
                            .failed_attempt = semantic_attempt + 1,
                            .attempt_limit = semantic_limit,
                            .diagnostic = failure_diagnostic,
                        });
                    } else {
                        try pushUnsafeNoRetryStatus(
                            deps,
                            if (stream_ctx.saw_tool_start)
                                .tool_start
                            else
                                .assistant_output,
                            failure_diagnostic,
                        );
                    }
                } else if (semantic_attempt > 0) {
                    try pushRouteRecoveryStatus(deps, .{
                        .kind = .terminal_provider_error,
                        .failed_attempt = semantic_attempt + 1,
                        .attempt_limit = semantic_limit,
                        .diagnostic = failure_diagnostic,
                    });
                }
                try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
                const failed_assistant_source = stream_ctx.raw_text.items;
                if (stop_state.retained_candidate != null) {
                    try copyLatestStopPartial(
                        arena,
                        stop_state,
                        failed_assistant_source,
                    );
                }
                if (!recovery_has_unexecuted_tool_start and
                    stream_ctx.saw_tool_start and
                    !stream_ctx.saw_provider_tool_start)
                {
                    try stream_ctx.provisional_statuses.finishUnmatchedRecoveryStarts(
                        deps,
                        stream_ctx.alloc,
                        arena,
                        turn_id,
                        &.{},
                    );
                }
                if (std.mem.trim(u8, failed_assistant_source, " \t\r\n").len > 0) {
                    if (stop_state.retained_candidate == null) {
                        try runtime_interruption.persistFailedPartialTurnOnce(
                            deps,
                            finalization,
                            job,
                            failed_assistant_source,
                            &interrupted_persisted,
                            step_ctx,
                            within_turn_suffix.items,
                            &stop_state.terminal_materializing,
                        );
                    }
                }
                return err;
            };
            parent_turn_delivery.observeGatewayDelivery(
                deps,
                overlay_arena,
                gateway_delivery.load(),
            );
            stream_result_set = true;
            if (job.provider != .gateway and
                stream_result.status == .unauthorized and
                !auth_retry_used and
                stream_ctx.raw_text.items.len == 0 and
                !stream_ctx.saw_tool_start and
                stream_result.completion.tool_calls.len == 0)
            {
                if (try refreshGatewayCredentialForJob(
                    deps,
                    std.heap.c_allocator,
                    job,
                    .force,
                    &active_api_key,
                    &owned_refreshed_api_key,
                    step_ctx,
                )) {
                    auth_retry_used = true;
                    var replay_delivery = runtime_gateway_step.DeliveryCertainty.init();
                    var replay_evidence: runtime_gateway_step.AttemptEvidence = .{};
                    stream_result = try runtime_gateway_step.streamGatewayCompletion(
                        deps.agent_stream_provider,
                        arena,
                        active_api_key,
                        job.credential_source,
                        job.account_id,
                        job.gateway_team,
                        lifecycle.scope.session_id,
                        gateway_model,
                        config.gateway_retry_count,
                        config.gateway_chat_url,
                        request_payload,
                        deps.cooperative_transport_pulse,
                        &replay_delivery,
                        &replay_evidence,
                        @ptrCast(&stream_ctx),
                        runtime_assistant_stream.onStreamContentChunk,
                        if (vision_mode == .required)
                            onRequiredVisionStreamToolStart
                        else
                            runtime_assistant_stream.onStreamToolStart,
                        runtime_assistant_stream.onStreamReasoningChunk,
                        runtime_assistant_stream.onStreamToolInputChunk,
                        config.cancel_flag,
                        deps.usage,
                        deps.usage_allocator,
                        step_ctx,
                        null,
                        .agent,
                    );
                    parent_turn_delivery.observeGatewayDelivery(
                        deps,
                        overlay_arena,
                        replay_delivery.load(),
                    );
                    debug_trace.eventf(
                        "auth",
                        "subscription_request_replayed",
                        step_ctx,
                        "payload_bytes={d} semantic_attempt={d}",
                        .{ request_payload.len, semantic_attempt + 1 },
                    );
                }
            }
            stream_result.completion.tool_calls = try normalize_terminal_request_tool_calls(
                arena,
                deps.tool_registry,
                terminal_request_normalization_eligible(
                    base_nested_terminal_advertised,
                    vision_mode,
                ),
                stream_result.completion.tool_calls,
            );
            if (recovery_strategy == .reconcile_tool and
                stream_result.status == .ok and
                (stream_result.completion.tool_calls.len > 0 or
                    stream_ctx.saw_tool_start))
            {
                debug_trace.eventf(
                    "agent",
                    "uncertain_provider_tool_rejected",
                    step_ctx,
                    "tool_call_count={d} tool_choice=none",
                    .{stream_result.completion.tool_calls.len},
                );
                try persistRecoveryCheckpoint(
                    deps,
                    arena,
                    job,
                    within_turn_suffix.items,
                    try recoveryCheckpointAssistantSource(
                        arena,
                        stop_state,
                        stream_ctx.raw_text.items,
                    ),
                    gateway_model,
                    selected_fast_mode,
                    route_fast_mode,
                    semantic_limit,
                    semantic_attempt + 1,
                    false,
                    recovery_cause,
                    .pause,
                    .uncertain,
                    step_ctx,
                );
                try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
                try finishRecoveryPaused(
                    deps,
                    finalization,
                    &finish_trace,
                    recovery_cause,
                    semantic_attempt + 1,
                    semantic_limit,
                    .inspect_uncertain_tool,
                    types.ModelFailureDiagnostic.init("UnexpectedToolCallDuringReconciliation"),
                );
                return;
            }
            const settled_disposition = if (stream_result.status == .ok)
                types.classifyProviderCompletion(stream_result.completion)
            else
                types.ProviderCompletionDisposition.completed;
            if (stream_result.status == .ok and
                (settled_disposition == .interrupted or
                    settled_disposition == .provider_failure))
            {
                try materializeConfirmedProviderTools(
                    deps,
                    &stream_ctx,
                    arena,
                    config,
                    turn_id,
                    stream_result.completion,
                    advertised_dynamic_tool_names,
                    step_ctx,
                    &within_turn_suffix,
                    &completed_tool_names,
                );
            }
            const settled_attempts = semantic_attempt + 1;
            if (job.provider == .gateway or stream_result.status != .unauthorized) {
                try persistRecoveryCheckpoint(
                    deps,
                    arena,
                    job,
                    within_turn_suffix.items,
                    try recoveryCheckpointAssistantSource(
                        arena,
                        stop_state,
                        stream_ctx.raw_text.items,
                    ),
                    gateway_model,
                    selected_fast_mode,
                    route_fast_mode,
                    semantic_limit,
                    settled_attempts,
                    false,
                    recovery_cause,
                    recovery_strategy,
                    effectiveRecoveryToolEvidence(
                        preserved_tool_evidence,
                        stream_result.completion,
                        &stream_ctx,
                    ),
                    step_ctx,
                );
            }
            runtime_assistant_stream.pushTokenProgressUpdate(&stream_ctx, summary_accumulator.reconcileTokenRequest(stream_result.completion.usage, stream_result.completion.delivery_ambiguous)) catch |progress_err| {
                debug_trace.logf("agent", "token progress publication failed source=gateway_usage err={s}", .{@errorName(progress_err)});
            };
            if (stream_result.status == .unauthorized and
                job.provider == .gateway and
                !auth_retry_used and
                semantic_attempt + 1 < semantic_limit)
            {
                if (try refreshGatewayCredentialForJob(
                    deps,
                    std.heap.c_allocator,
                    job,
                    .force,
                    &active_api_key,
                    &owned_refreshed_api_key,
                    step_ctx,
                )) {
                    auth_retry_used = true;
                    if (stream_result.err_body) |body| mem_utils.free(arena, body);
                    stream_result.err_body = null;
                    stream_result_set = false;
                    semantic_attempt += 1;
                    recovery_strategy = .retry_request;
                    recovery_cause = .authentication;
                    retry_pacing = .idle;
                    reset_stream_for_next_attempt = true;
                    skip_next_preflight_refresh = true;
                    continue;
                }
            }
            const gateway_wait_finished_ms = io_mod.milliTimestamp();
            summary_accumulator.addThinkingWait(gateway_wait_started_ms, stream_ctx.first_model_output_at_ms orelse gateway_wait_finished_ms);

            if (!assistant_prefill_recovery_used and
                semantic_attempt + 1 < semantic_limit and
                streamReplaySafe(&stream_ctx) and
                isPostVisionAssistantPrefillRejection(
                    stream_result.status,
                    stream_result.err_body orelse "",
                    request_messages,
                ))
            {
                try within_turn_suffix.append(arena, .{
                    .role = .user,
                    .content = assistant_prefill_recovery_prompt,
                    .cache_policy = .no_cache,
                });
                debug_trace.eventf(
                    "gateway",
                    "assistant_prefill_recovery",
                    step_ctx,
                    "tool_name=vision provider_attempt={d}/{d}",
                    .{ semantic_attempt + 1, semantic_limit },
                );
                if (stream_result.err_body) |body| mem_utils.free(arena, body);
                stream_result.err_body = null;
                stream_result_set = false;
                assistant_prefill_recovery_used = true;
                semantic_attempt += 1;
                retry_pacing = .idle;
                reset_stream_for_next_attempt = true;
                continue;
            }

            if (isRetryableModelStatus(stream_result.status)) {
                const cause: model_response_recovery.FailureCause = if (stream_result.status == .too_many_requests)
                    .rate_limited
                else
                    .provider_unavailable;
                const diagnostic = try httpFailureDiagnostic(
                    arena,
                    stream_result.status,
                    stream_result.err_body orelse "",
                );
                latest_recovery_diagnostic = diagnostic;
                const route_changed = disableFastRouteAfterFailure(
                    &route_fast_mode,
                    &gateway_model,
                    job.model,
                    cause,
                    streamReplaySafe(&stream_ctx),
                    step_ctx,
                );
                const decision = model_response_recovery.decide(.{
                    .cause = cause,
                    .delivery = .possibly_sent,
                    .attempts = .{ .consumed = semantic_attempt + 1, .limit = semantic_limit },
                    .pacing = retry_pacing,
                    .output = if (stream_ctx.raw_text.items.len > 0) .partial else .none,
                    .tool = effectiveRecoveryToolEvidence(
                        preserved_tool_evidence,
                        stream_result.completion,
                        &stream_ctx,
                    ),
                    .retry_after_seconds = stream_result.retry_after_seconds,
                    .cancelled = config.cancel_flag.load(.seq_cst),
                });
                if (decision.strategy == .pause) {
                    try persistRecoveryCheckpoint(
                        deps,
                        arena,
                        job,
                        within_turn_suffix.items,
                        try recoveryCheckpointAssistantSource(
                            arena,
                            stop_state,
                            stream_ctx.raw_text.items,
                        ),
                        gateway_model,
                        selected_fast_mode,
                        route_fast_mode,
                        semantic_limit,
                        semantic_attempt + 1,
                        false,
                        cause,
                        .pause,
                        effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            stream_result.completion,
                            &stream_ctx,
                        ),
                        step_ctx,
                    );
                    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
                    try finishRecoveryPaused(
                        deps,
                        finalization,
                        &finish_trace,
                        cause,
                        semantic_attempt + 1,
                        semantic_limit,
                        recoveryRequiredAction(decision.required_action),
                        diagnostic,
                    );
                    return;
                }
                if (decision.reserve_provider_attempt) {
                    if (route_changed) {
                        try persistRecoveryCheckpoint(
                            deps,
                            arena,
                            job,
                            within_turn_suffix.items,
                            try recoveryCheckpointAssistantSource(
                                arena,
                                stop_state,
                                stream_ctx.raw_text.items,
                            ),
                            gateway_model,
                            selected_fast_mode,
                            route_fast_mode,
                            semantic_limit,
                            semantic_attempt + 1,
                            false,
                            cause,
                            decision.strategy,
                            effectiveRecoveryToolEvidence(
                                preserved_tool_evidence,
                                stream_result.completion,
                                &stream_ctx,
                            ),
                            step_ctx,
                        );
                    }
                    try pushAutoRetryStatus(
                        deps,
                        semantic_attempt + 1,
                        semantic_limit,
                        cause,
                        decision,
                        diagnostic,
                    );
                    if (waitForRecoveryDelay(config.cancel_flag, decision.delay_ns)) {
                        preserved_tool_evidence = effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            stream_result.completion,
                            &stream_ctx,
                        );
                        if (stream_result.err_body) |body| mem_utils.free(arena, body);
                        stream_result.err_body = null;
                        stream_result_set = false;
                        semantic_attempt += 1;
                        recovery_strategy = decision.strategy;
                        recovery_cause = cause;
                        retry_pacing = decision.next_pacing;
                        reset_stream_for_next_attempt = true;
                        continue;
                    }
                    if (config.cancel_flag.load(.seq_cst)) {
                        runtime_telemetry.traceCancelObserved(step_ctx, false);
                        try clearAutoRetryStatusIfNeeded(deps, true);
                        try finishPendingCancelledCalls(
                            deps,
                            &stream_ctx.provisional_statuses,
                            stream_ctx.alloc,
                            arena,
                            config,
                            turn_id,
                            stream_result.completion.tool_calls,
                            advertised_dynamic_tool_names,
                        );
                        try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, stream_ctx.raw_text.items, null, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                        finish_trace.finish("interrupted");
                        return;
                    }
                }
            }

            try runtime_assistant_stream.flushAssistantStream(&stream_ctx);

            const attempt_completion = stream_result.completion;
            const current_partial_assistant = if (stream_ctx.raw_text.items.len > 0)
                stream_ctx.raw_text.items
            else if (attempt_completion.content) |content|
                content
            else
                "";
            const partial_assistant = current_partial_assistant;
            if (stop_state.retained_candidate != null) {
                try copyLatestStopPartial(arena, stop_state, partial_assistant);
            }

            if (config.cancel_flag.load(.seq_cst)) {
                runtime_telemetry.traceCancelObserved(step_ctx, false);
                try clearAutoRetryStatusIfNeeded(deps, recovery_strategy != null);
                try finishPendingCancelledCalls(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    arena,
                    config,
                    turn_id,
                    attempt_completion.tool_calls,
                    advertised_dynamic_tool_names,
                );
                try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, null, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                finish_trace.finish("interrupted");
                return;
            }

            const attempt_disposition = settled_disposition;
            var attempt_failure_diagnostic: ?types.ModelFailureDiagnostic = null;
            if (stream_result.status == .ok and
                (attempt_disposition == .interrupted or
                    attempt_disposition == .provider_failure))
            {
                const finish_reason = attempt_completion.finish_reason;
                const cause: model_response_recovery.FailureCause = if (attempt_disposition == .interrupted)
                    .response_interrupted
                else if (finish_reason.? == .content_filter)
                    .content_filter
                else
                    .provider_unavailable;
                const diagnostic = try providerCompletionDiagnostic(
                    arena,
                    attempt_completion,
                    defaultRecoveryDiagnosticText(cause),
                );
                attempt_failure_diagnostic = diagnostic;
                latest_recovery_diagnostic = diagnostic;
                const decision = model_response_recovery.decide(.{
                    .cause = cause,
                    .delivery = .possibly_sent,
                    .attempts = .{ .consumed = semantic_attempt + 1, .limit = semantic_limit },
                    .pacing = retry_pacing,
                    .output = if (partial_assistant.len > 0) .partial else .none,
                    .tool = effectiveRecoveryToolEvidence(
                        preserved_tool_evidence,
                        attempt_completion,
                        &stream_ctx,
                    ),
                    .cancelled = config.cancel_flag.load(.seq_cst),
                });
                if (attempt_disposition == .provider_failure) {
                    traceRouteFailure(
                        step_ctx,
                        job.model,
                        gateway_model,
                        route_fast_mode,
                        semantic_attempt + 1,
                        semantic_limit,
                        attempt_completion,
                        &stream_ctx,
                        decision.reserve_provider_attempt,
                    );
                }
                const route_changed = disableFastRouteAfterFailure(
                    &route_fast_mode,
                    &gateway_model,
                    job.model,
                    cause,
                    providerFailureReplaySafe(attempt_completion, &stream_ctx),
                    step_ctx,
                );
                if (decision.strategy == .pause) {
                    try persistRecoveryCheckpoint(
                        deps,
                        arena,
                        job,
                        within_turn_suffix.items,
                        try recoveryCheckpointAssistantSource(
                            arena,
                            stop_state,
                            partial_assistant,
                        ),
                        gateway_model,
                        selected_fast_mode,
                        route_fast_mode,
                        semantic_limit,
                        semantic_attempt + 1,
                        false,
                        cause,
                        .pause,
                        effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            attempt_completion,
                            &stream_ctx,
                        ),
                        step_ctx,
                    );
                    try finishRecoveryPaused(
                        deps,
                        finalization,
                        &finish_trace,
                        cause,
                        semantic_attempt + 1,
                        semantic_limit,
                        recoveryRequiredAction(decision.required_action),
                        diagnostic,
                    );
                    return;
                }
                if (decision.reserve_provider_attempt) {
                    if (route_changed) {
                        try persistRecoveryCheckpoint(
                            deps,
                            arena,
                            job,
                            within_turn_suffix.items,
                            try recoveryCheckpointAssistantSource(
                                arena,
                                stop_state,
                                partial_assistant,
                            ),
                            gateway_model,
                            selected_fast_mode,
                            route_fast_mode,
                            semantic_limit,
                            semantic_attempt + 1,
                            false,
                            cause,
                            decision.strategy,
                            effectiveRecoveryToolEvidence(
                                preserved_tool_evidence,
                                attempt_completion,
                                &stream_ctx,
                            ),
                            step_ctx,
                        );
                    }
                    try pushAutoRetryStatus(
                        deps,
                        semantic_attempt + 1,
                        semantic_limit,
                        cause,
                        decision,
                        diagnostic,
                    );
                    if (waitForRecoveryDelay(config.cancel_flag, decision.delay_ns)) {
                        preserved_tool_evidence = effectiveRecoveryToolEvidence(
                            preserved_tool_evidence,
                            attempt_completion,
                            &stream_ctx,
                        );
                        semantic_attempt += 1;
                        recovery_strategy = decision.strategy;
                        recovery_cause = cause;
                        retry_pacing = decision.next_pacing;
                        if (decision.strategy == .regenerate_tool) {
                            recovery_has_unexecuted_tool_start = true;
                        }
                        reset_stream_for_next_attempt = true;
                        continue;
                    }
                    if (config.cancel_flag.load(.seq_cst)) {
                        runtime_telemetry.traceCancelObserved(step_ctx, false);
                        try clearAutoRetryStatusIfNeeded(deps, true);
                        try finishPendingCancelledCalls(
                            deps,
                            &stream_ctx.provisional_statuses,
                            stream_ctx.alloc,
                            arena,
                            config,
                            turn_id,
                            attempt_completion.tool_calls,
                            advertised_dynamic_tool_names,
                        );
                        try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, null, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                        finish_trace.finish("interrupted");
                        return;
                    }
                }
            }
            if (stream_result.status == .ok and attempt_disposition == .provider_failure) {
                const finish_reason = attempt_completion.finish_reason.?;
                const diagnostic = attempt_failure_diagnostic orelse
                    try providerCompletionDiagnostic(arena, attempt_completion, finish_reason.label());
                const replay_safe = providerFailureReplaySafe(attempt_completion, &stream_ctx);
                debug_trace.eventf("agent", "provider_completion_failed", step_ctx, "finish_reason={s} content_bytes={d} tool_call_count={d}", .{
                    finish_reason.label(),
                    completionContentBytes(attempt_completion),
                    attempt_completion.tool_calls.len,
                });
                if (finish_reason == .provider_error) {
                    if (replay_safe) {
                        try pushTerminalProviderFailureStatus(
                            deps,
                            semantic_attempt + 1,
                            semantic_limit,
                            attempt_completion,
                            diagnostic,
                        );
                    } else {
                        try pushUnsafeNoRetryStatus(
                            deps,
                            unsafeNoRetryReason(attempt_completion, &stream_ctx),
                            diagnostic,
                        );
                    }
                }

                if (finish_reason == .content_filter) {
                    try pushTerminalProviderFailureStatus(
                        deps,
                        semantic_attempt + 1,
                        semantic_limit,
                        attempt_completion,
                        diagnostic,
                    );
                    if (deps.request_route_recovery) |recover| {
                        const decision = try recover(deps.ctx, arena, .{
                            .selected_model = job.model,
                            .route_model = gateway_model,
                            .fast_mode = route_fast_mode,
                            .replay_safe = false,
                            .finish_reason = finish_reason,
                            .semantic_attempts = semantic_attempt + 1,
                            .provider_failure_detail = attempt_completion.provider_failure_detail,
                        });
                        debug_trace.eventf("agent", "route_recovery_decision", step_ctx, "decision={s} replay_safe=false", .{@tagName(decision)});
                        switch (decision) {
                            .switch_model, .cancel => {
                                finish_trace.finish("route_recovery_stopped");
                                return error.RouteRecoveryStopped;
                            },
                            .disable_fast => {},
                        }
                    }
                }
                finish_trace.finish(if (finish_reason == .provider_error) "provider_error" else "content_filter");
                return error.ModelError;
            }

            successful_request_messages = request_messages;
            successful_source_messages = recovery_source_messages;
            successful_gateway_model = gateway_model;
            successful_vision_route = vision_route;
            successful_vision_mode = vision_mode;
            successful_recovery_strategy = recovery_strategy;
            if (vision_mode != .required) configured_first_tool_choice_pending = false;
            break;
        }
        defer if (stream_result_set) {
            if (stream_result.err_body) |b| mem_utils.free(arena, b);
        };

        var completion = stream_result.completion;
        const filtered_provider_calls = try filterMaterializedProviderCalls(
            arena,
            within_turn_suffix.items,
            completion.tool_calls,
        );
        completion.tool_calls = filtered_provider_calls.calls;
        if (filtered_provider_calls.removed > 0) {
            debug_trace.eventf(
                "agent",
                "provider_tool_recovery_duplicate_suppressed",
                step_ctx,
                "tool_call_count={d}",
                .{filtered_provider_calls.removed},
            );
            if (completion.tool_calls.len == 0 and
                completion.finish_reason == .tool_calls)
            {
                const has_novel_content = std.mem.trim(
                    u8,
                    stream_ctx.raw_text.items,
                    " \t\r\n",
                ).len > 0;
                if (!has_novel_content) {
                    if (successful_recovery_strategy != null) {
                        try pushAutoRecoveredStatus(deps, semantic_attempt, semantic_limit);
                    }
                    latest_recovery_diagnostic = null;
                    recovery_strategy = null;
                    recovery_cause = .transport_interrupted;
                    preserved_tool_evidence = .none;
                    continue;
                }
                completion.finish_reason = .stop;
            }
        }
        const current_partial_assistant = if (stream_ctx.raw_text.items.len > 0)
            stream_ctx.raw_text.items
        else if (completion.content) |content|
            content
        else
            "";
        const partial_assistant = current_partial_assistant;

        if (stream_result.status != .ok) {
            const detail = if (stream_result.err_body) |b| std.mem.trim(u8, b, " \r\n\t") else "";
            const clipped = detail[0..@min(detail.len, http_error_detail_max_bytes)];
            const http_detail = try runtime_gateway_step.gatewayHttpErrorDetail(
                arena,
                stream_result.status,
                clipped,
                job.model,
                request_capabilities,
            );
            try deps.push_http_error(deps.ctx, stream_result.status, http_detail, job.credential_source);
            if (stop_state.retained_candidate != null) {
                stop_state.terminal_materializing = true;
                const assistant_text = try hooks.prompt.joinVisibleSegments(
                    arena,
                    stop_state.retained_candidate,
                    stop_state.latest_partial,
                );
                try finishCommonAssistantTerminal(
                    deps,
                    finalization,
                    arena,
                    job,
                    within_turn_suffix.items,
                    &summary_accumulator,
                    assistant_text,
                    .failed,
                    null,
                    &finish_trace,
                    "http_error",
                );
                return;
            }
            if (std.mem.trim(u8, partial_assistant, " \t\r\n").len > 0) {
                stop_state.terminal_materializing = true;
                try finishCommonAssistantTerminal(
                    deps,
                    finalization,
                    arena,
                    job,
                    within_turn_suffix.items,
                    &summary_accumulator,
                    partial_assistant,
                    .failed,
                    null,
                    &finish_trace,
                    "http_error",
                );
                return;
            }
            if (try runtime_finalization.finishExecutionOnlyFailureIfNeeded(
                deps,
                finalization,
                arena,
                job,
                within_turn_suffix.items,
                &summary_accumulator,
                &finish_trace,
                &stop_state.terminal_materializing,
                "http_error",
            )) return;
            try finalization.finish(.failed, null, null);
            finish_trace.finish("http_error");
            return;
        }

        const disposition = types.classifyProviderCompletion(completion);
        switch (disposition) {
            .completed, .length_limited => {},
            .interrupted => {
                try pushTerminalAutoRetryStatusIfNeeded(
                    deps,
                    successful_recovery_strategy != null,
                    semantic_attempt,
                    semantic_limit,
                    types.ModelFailureDiagnostic.init("StreamInterrupted"),
                );
                debug_trace.eventf("agent", "provider_finish_missing", step_ctx, "content_bytes={d} tool_call_count={d}", .{
                    if (completion.content) |content| content.len else 0,
                    completion.tool_calls.len,
                });
                finish_trace.finish("stream_interrupted");
                return error.StreamInterrupted;
            },
            .provider_failure => {
                const finish_reason = completion.finish_reason.?;
                debug_trace.eventf("agent", "provider_completion_failed", step_ctx, "finish_reason={s} content_bytes={d} tool_call_count={d}", .{
                    finish_reason.label(),
                    if (completion.content) |content| content.len else 0,
                    completion.tool_calls.len,
                });
                finish_trace.finish(if (finish_reason == .provider_error) "provider_error" else "content_filter");
                return error.ModelError;
            },
            .invalid_completion => {
                try pushTerminalAutoRetryStatusIfNeeded(
                    deps,
                    successful_recovery_strategy != null,
                    semantic_attempt,
                    semantic_limit,
                    types.ModelFailureDiagnostic.init("InvalidProviderCompletion"),
                );
                const finish_reason = completion.finish_reason.?;
                if (completion.tool_calls.len > 0) {
                    debug_trace.eventf("agent", "provider_tool_calls_rejected", step_ctx, "finish_reason={s} tool_call_count={d}", .{
                        finish_reason.label(),
                        completion.tool_calls.len,
                    });
                } else {
                    debug_trace.eventf("agent", "provider_tool_finish_missing_calls", step_ctx, "finish_reason={s}", .{finish_reason.label()});
                }
                finish_trace.finish("invalid_tool_finish");
                return error.ModelError;
            },
        }
        if (successful_vision_mode == .required and completion.tool_calls.len == 0) {
            try pushTerminalAutoRetryStatusIfNeeded(
                deps,
                successful_recovery_strategy != null,
                semantic_attempt,
                semantic_limit,
                types.ModelFailureDiagnostic.init("RequiredVisionToolCallMissing"),
            );
            debug_trace.eventf(
                "agent",
                "required_vision_call_missing",
                step_ctx,
                "pending_images={d}",
                .{pending_image_ids.len},
            );
            finish_trace.finish("required_vision_call_missing");
            return error.RequiredVisionToolCallMissing;
        }
        if (recovery_has_unexecuted_tool_start) {
            try stream_ctx.provisional_statuses.finishUnmatchedRecoveryStarts(
                deps,
                stream_ctx.alloc,
                arena,
                turn_id,
                completion.tool_calls,
            );
            recovery_has_unexecuted_tool_start = false;
        }
        const finish_reason = completion.finish_reason.?;
        if (successful_recovery_strategy != null) {
            try pushAutoRecoveredStatus(deps, semantic_attempt, semantic_limit);
        }
        latest_recovery_diagnostic = null;
        recovery_strategy = null;
        recovery_cause = .transport_interrupted;
        retry_pacing = .idle;
        preserved_tool_evidence = .none;

        if (deps.report_usage) |report_fn| {
            if (completion.usage.input_tokens != null or completion.usage.output_tokens != null) {
                report_fn(deps.ctx, completion.usage);
            }
        }

        if (disposition == .completed and completion.tool_calls.len > 0) {
            const admission = types.authoritativeToolAdmission(completion);
            switch (admission) {
                .admitted => {},
                .reject_duplicate_identity => {
                    try stream_ctx.provisional_statuses.finishRejectedCompletions(deps, arena, turn_id, completion.tool_calls, advertised_dynamic_tool_names);
                    debug_trace.eventf("agent", "authoritative_tool_admission_rejected", step_ctx, "failure=duplicate", .{});
                    finish_trace.finish("duplicate_tool_identity");
                    return error.MalformedAuthoritativeToolIdentity;
                },
                .reject_malformed_identity => |failure| {
                    try stream_ctx.provisional_statuses.finishRejectedCompletions(deps, arena, turn_id, completion.tool_calls, advertised_dynamic_tool_names);
                    debug_trace.eventf("agent", "authoritative_tool_admission_rejected", step_ctx, "failure={s} provenance=fx_local", .{@tagName(failure)});
                    finish_trace.finish("malformed_tool_identity");
                    return error.MalformedAuthoritativeToolIdentity;
                },
                .reject_malformed_provider_result => |failure| {
                    try stream_ctx.provisional_statuses.finishRejectedCompletions(deps, arena, turn_id, completion.tool_calls, advertised_dynamic_tool_names);
                    debug_trace.eventf("agent", "authoritative_tool_admission_rejected", step_ctx, "failure={s} provenance=provider_executed", .{@tagName(failure)});
                    finish_trace.finish("malformed_provider_result");
                    return error.MalformedProviderResultIdentity;
                },
                .reject_malformed_provider_arguments => {
                    try stream_ctx.provisional_statuses.finishMalformedProviderToolArguments(
                        deps,
                        arena,
                        turn_id,
                        completion.tool_calls,
                    );
                    debug_trace.eventf(
                        "agent",
                        "provider_tool_arguments_rejected",
                        step_ctx,
                        "failure=malformed_json provenance=provider_executed",
                        .{},
                    );
                    finish_trace.finish("malformed_provider_tool_arguments");
                    return error.MalformedProviderToolArguments;
                },
            }
        }
        var step_has_visible_tool_calls = false;
        for (completion.tool_calls) |call| {
            if (runtime_tool_presentation.activityKindForCall(arena, deps.tool_registry, call) == .ask) continue;
            step_has_visible_tool_calls = true;
            break;
        }
        const step_has_visible_text =
            stream_ctx.saw_visible_text or
            (completion.content != null and
                std.mem.trim(u8, completion.content.?, " \t\r\n").len > 0);
        const presentation_group_transition =
            runtime_tool_presentation.transitionPresentationGroup(
                active_presentation_group_id,
                stream_ctx.provisional_statuses.presentation_group_id,
                turn_id,
                step_ctx.step_id,
                .{
                    .has_visible_tool_calls = step_has_visible_tool_calls,
                    .has_visible_text = step_has_visible_text,
                    .saw_tool_start = stream_ctx.saw_tool_start,
                    .saw_visible_text_after_tool_start = stream_ctx.saw_visible_text_after_tool_start,
                },
            );
        stream_ctx.provisional_statuses.presentation_group_id =
            presentation_group_transition.tool_group_id;
        active_presentation_group_id =
            presentation_group_transition.active_group_id;
        debug_trace.eventf(
            "agent",
            "tool_presentation_group",
            step_ctx,
            "anchor_step_id={d} visible_tool_calls={s} saw_tool_start={s} visible_text={s} saw_visible_text_after_tool_start={s}",
            .{
                if (active_presentation_group_id) |group| group.anchor_step_id else 0,
                if (step_has_visible_tool_calls) "true" else "false",
                if (stream_ctx.saw_tool_start) "true" else "false",
                if (step_has_visible_text) "true" else "false",
                if (stream_ctx.saw_visible_text_after_tool_start) "true" else "false",
            },
        );

        debug_trace.logf(
            "agent",
            "step completion step={d} content_bytes={d} tool_calls={d} finish_reason={s}",
            .{
                step + 1,
                if (completion.content) |content| content.len else 0,
                completion.tool_calls.len,
                finish_reason.label(),
            },
        );
        debug_trace.eventf(
            "agent",
            "assistant_completion",
            step_ctx,
            "content_bytes={d} tool_call_count={d} finish_reason={s}",
            .{
                if (completion.content) |content| content.len else 0,
                completion.tool_calls.len,
                finish_reason.label(),
            },
        );
        try runtime_telemetry.traceReturnedToolCalls(arena, step_ctx, completion.tool_calls);
        try runtime_assistant_stream.emitProviderLengthNotice(deps, arena, disposition);
        const terminal_provider_completion = isTerminalProviderExecutedCompletion(completion);

        if (disposition == .length_limited and completion.tool_calls.len > 0) {
            const assistant_text = try runtime_assistant_stream.finishLengthLimitedToolCallCompletion(deps, arena, completion, stream_ctx.raw_text.items.len);
            debug_trace.eventf("agent", "provider_completion_blocked", step_ctx, "finish_reason={s} tool_calls={d}", .{
                finish_reason.label(),
                completion.tool_calls.len,
            });
            if (stop_state.retained_candidate != null) {
                const persisted_text = try hooks.prompt.joinVisibleSegments(
                    arena,
                    stop_state.retained_candidate,
                    assistant_text,
                );
                stop_state.terminal_materializing = true;
                try finishCommonAssistantTerminal(
                    deps,
                    finalization,
                    arena,
                    job,
                    within_turn_suffix.items,
                    &summary_accumulator,
                    persisted_text,
                    .failed,
                    .length_limited,
                    &finish_trace,
                    "provider_length",
                );
                return;
            }
            const finish_execution = try runtime_execution_memory.buildExecutionMemory(arena, within_turn_suffix.items);
            const turn: HistoryTurn = .{ .assistant = .{
                .user = .{ .text = job.prompt, .images = job.images },
                .assistant = @constCast(assistant_text),
                .execution = finish_execution,
            } };
            try deps.propagate_history_turn(deps.ctx, turn);
            try finalization.finish(.failed, .length_limited, .{
                .turn = try types.dupeHistoryTurn(std.heap.c_allocator, turn),
                .summary = summary_accumulator.finish(),
            });
            finish_trace.finish("provider_length");
            return;
        }

        if (completion.tool_calls.len == 0) {
            const has_content =
                std.mem.trim(u8, partial_assistant, " \t\r\n").len > 0;
            const needs_continuation =
                disposition == .completed and
                !continuation_injected and
                silent_tool_steps >= 2 and
                !has_content;

            if (needs_continuation) {
                continuation_injected = true;
                const continuation_prompt = "Summarize what you just did.";
                debug_trace.logf("agent", "injecting continuation after {d} silent tool steps", .{silent_tool_steps});
                try within_turn_suffix.append(arena, .{ .role = .assistant, .content = completion.content });
                try within_turn_suffix.append(arena, .{ .role = .user, .content = continuation_prompt });
                continue;
            }

            const raw_final = if (has_content) partial_assistant else "Done.";
            const final_text = try runtime_assistant_stream.normalizeAssistantTextForDisplay(arena, raw_final);
            const rendered = if (final_text.len > 0) final_text else "Done.";
            const history_text = runtime_assistant_stream.historyTextForCompletedStream(
                raw_final,
                rendered,
            );

            if (!lifecycle.view.hasStop() or stop_state.dispatched) {
                if (!has_content) {
                    try deps.push_text(deps.ctx, .{ .operational = rendered });
                }
                try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });

                const persisted_text = try hooks.prompt.joinVisibleSegments(
                    arena,
                    stop_state.retained_candidate,
                    history_text,
                );
                stop_state.terminal_materializing =
                    stop_state.retained_candidate != null;
                try finishCommonAssistantTerminal(
                    deps,
                    finalization,
                    arena,
                    job,
                    within_turn_suffix.items,
                    &summary_accumulator,
                    persisted_text,
                    .completed,
                    if (disposition == .length_limited)
                        .length_limited
                    else
                        null,
                    &finish_trace,
                    "assistant",
                );
                return;
            }

            stop_state.retained_candidate = history_text;
            stop_state.latest_partial = null;
            if (!has_content) {
                try deps.push_text(deps.ctx, .{ .operational = rendered });
            }
            try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });

            var stop_outcome = runtime_lifecycle.dispatchStopCheckpoint(
                lifecycle,
                config.cancel_flag,
                .{
                    .turn_id = turn_id,
                    .step_index = current_step_index,
                    .assistant_text = rendered,
                    .provider_disposition = disposition,
                    .can_continue = agent_steps.allowsStep(config.agent_step_limit, step + 1),
                },
            ) catch |err| switch (err) {
                error.Cancelled => {
                    runtime_telemetry.traceCancelObserved(step_ctx, false);
                    try runtime_interruption.persistInterruptedTurnOnce(
                        deps,
                        finalization,
                        job,
                        null,
                        null,
                        completed_tool_names.items,
                        &interrupted_persisted,
                        step_ctx,
                        within_turn_suffix.items,
                        stop_state.retained_candidate,
                        &stop_state.terminal_materializing,
                    );
                    finish_trace.finish("interrupted");
                    return;
                },
            };
            defer stop_outcome.deinit(lifecycle.outcome_allocator);

            stop_state.dispatched = true;
            switch (stop_outcome) {
                .allow => {
                    stop_state.terminal_materializing = true;
                    try finishCommonAssistantTerminal(
                        deps,
                        finalization,
                        arena,
                        job,
                        within_turn_suffix.items,
                        &summary_accumulator,
                        history_text,
                        .completed,
                        if (disposition == .length_limited)
                            .length_limited
                        else
                            null,
                        &finish_trace,
                        "assistant",
                    );
                    return;
                },
                .continue_once => |context| {
                    try within_turn_suffix.append(arena, .{
                        .role = .assistant,
                        .content = history_text,
                    });
                    const synthetic = try hooks.prompt.buildContinuationMessage(
                        arena,
                        context,
                    );
                    try within_turn_suffix.append(arena, .{
                        .role = .user,
                        .content = synthetic,
                    });
                    continue;
                },
            }
        }

        const prepared_tool_calls = try arena.alloc(
            PreparedToolCall,
            completion.tool_calls.len,
        );
        for (completion.tool_calls, 0..) |tool_call, tool_call_index| {
            if (successful_vision_mode == .required and
                !std.mem.eql(u8, tool_call.name, "vision"))
            {
                const owned_call = try types.dupeToolCall(arena, tool_call);
                errdefer types.freeToolCall(arena, owned_call);
                prepared_tool_calls[tool_call_index] = .{ .blocked = .{
                    .call = owned_call,
                    .model_output = try tool_result_errors.toolExecutionFailureJson(
                        arena,
                        .{
                            .tool_name = tool_call.name,
                            .message = "Only Vision can be called while attached images are pending.",
                            .suggestion = "Call Vision for the pending images before using other tools.",
                        },
                    ),
                    .kind = .required_vision,
                } };
                continue;
            }
            if (std.mem.eql(u8, tool_call.name, "vision") and
                successful_vision_route != .text_only and
                !try visionCallUsesPaths(arena, tool_call))
            {
                const owned_call = try types.dupeToolCall(arena, tool_call);
                errdefer types.freeToolCall(arena, owned_call);
                prepared_tool_calls[tool_call_index] = .{ .blocked = .{
                    .call = owned_call,
                    .model_output = try tool_result_errors.toolExecutionFailureJson(
                        arena,
                        .{
                            .tool_name = "vision",
                            .message = runtime_vision_contracts.native_route_unavailable_message,
                            .suggestion = "Continue using the model's native image input without Vision.",
                        },
                    ),
                    .kind = .route_unavailable,
                } };
                continue;
            }
            prepared_tool_calls[tool_call_index] = runtime_lifecycle.prepareToolCallForLifecycle(
                arena,
                lifecycle,
                config.cancel_flag,
                turn_id,
                current_step_index,
                tool_call,
            ) catch |err| {
                if (err == error.Cancelled and config.cancel_flag.load(.seq_cst)) {
                    runtime_telemetry.traceCancelObserved(step_ctx, true);
                    try finishPreparedCallsOnCancellation(
                        deps,
                        &stream_ctx.provisional_statuses,
                        stream_ctx.alloc,
                        arena,
                        config,
                        turn_id,
                        prepared_tool_calls[0..tool_call_index],
                        &.{},
                        advertised_dynamic_tool_names,
                    );
                    try finishPendingCancelledCalls(
                        deps,
                        &stream_ctx.provisional_statuses,
                        stream_ctx.alloc,
                        arena,
                        config,
                        turn_id,
                        completion.tool_calls[tool_call_index..],
                        advertised_dynamic_tool_names,
                    );
                    try runtime_interruption.persistInterruptedTurnOnce(
                        deps,
                        finalization,
                        job,
                        partial_assistant,
                        tool_call,
                        completed_tool_names.items,
                        &interrupted_persisted,
                        step_ctx,
                        within_turn_suffix.items,
                        stop_state.retained_candidate,
                        &stop_state.terminal_materializing,
                    );
                    finish_trace.finish("interrupted");
                    return;
                }
                return err;
            };
        }
        const effective_tool_calls = try arena.alloc(
            ToolCall,
            prepared_tool_calls.len,
        );
        for (prepared_tool_calls, 0..) |prepared_call, i| {
            effective_tool_calls[i] = prepared_call.call();
        }
        const pending_assistant: ChatMessage = .{
            .role = .assistant,
            .content = if (terminal_provider_completion or partial_assistant.len == 0)
                null
            else
                partial_assistant,
            .tool_calls = effective_tool_calls,
            .provider_state_json = completion.provider_state_json,
        };

        var preparation_batch = tool_preparation.ReadyCallBatch.init(
            arena,
            prepared_tool_calls.len,
        ) catch |err| {
            return settleFailedContextGate(
                deps,
                &stream_ctx.provisional_statuses,
                stream_ctx.alloc,
                turn_id,
                effective_tool_calls,
                advertised_dynamic_tool_names,
                err,
            );
        };
        defer preparation_batch.deinit(arena, arena);
        var classifier_ctx: PreparationClassifierContext = .{
            .deps = deps,
        };
        if (deps.context_enabled) {
            for (prepared_tool_calls, 0..) |prepared_call, i| {
                switch (prepared_call) {
                    .ready => {},
                    .blocked, .provider_executed => continue,
                }
                const tool_call = prepared_call.call();
                preparation_batch.prepare(arena, i, tool_call, .{
                    .tool_registry = deps.tool_registry,
                    .workspace_root = config.workspace_root,
                    .access_scope = config.access_scope,
                    .advertised_dynamic_tool_names = advertised_dynamic_tool_names,
                    .cancel_flag = config.cancel_flag,
                    .classifiers = .{
                        .ctx = @ptrCast(&classifier_ctx),
                        .idempotent = prepareNoIdempotentTerminal,
                        .validation = prepareValidationTerminal,
                        .availability = prepareAvailabilityTerminal,
                        .stop_policy = prepareNoIdempotentTerminal,
                        .deferred_dynamic = prepareDeferredDynamicCandidate,
                    },
                }) catch |err| {
                    if (err == error.Cancelled and config.cancel_flag.load(.seq_cst)) {
                        runtime_telemetry.traceCancelObserved(step_ctx, true);
                        try finishPreparedCallsOnCancellation(
                            deps,
                            &stream_ctx.provisional_statuses,
                            stream_ctx.alloc,
                            arena,
                            config,
                            turn_id,
                            prepared_tool_calls,
                            preparation_batch.preparations,
                            advertised_dynamic_tool_names,
                        );
                        try runtime_interruption.persistInterruptedTurnOnce(
                            deps,
                            finalization,
                            job,
                            partial_assistant,
                            tool_call,
                            completed_tool_names.items,
                            &interrupted_persisted,
                            step_ctx,
                            within_turn_suffix.items,
                            stop_state.retained_candidate,
                            &stop_state.terminal_materializing,
                        );
                        finish_trace.finish("interrupted");
                        return;
                    }
                    return settleFailedContextGate(
                        deps,
                        &stream_ctx.provisional_statuses,
                        stream_ctx.alloc,
                        turn_id,
                        effective_tool_calls,
                        advertised_dynamic_tool_names,
                        err,
                    );
                };
            }
        }

        const context_deferred_calls = arena.alloc(bool, prepared_tool_calls.len) catch |err| {
            return settleFailedContextGate(
                deps,
                &stream_ctx.provisional_statuses,
                stream_ctx.alloc,
                turn_id,
                effective_tool_calls,
                advertised_dynamic_tool_names,
                err,
            );
        };
        @memset(context_deferred_calls, false);
        var context_delta = false;
        if (deps.context_enabled and preparation_batch.applicable_targets.items.len > 0) {
            const context_registry = deps.context_registry orelse
                return error.ContextRegistryUnavailable;
            var selected = context_registry.selectDefaultApplicableContext(arena, .{
                .workspace_root = config.workspace_root,
                .access_scope = config.access_scope,
                .targets = preparation_batch.applicable_targets.items,
                .delivered_sources = context_delivery_state.delivered_sources.items,
                .evaluated_endpoints = context_delivery_state.evaluated_endpoints.items,
                .context_limits = config.context_limits,
            }) catch |err| {
                return settleFailedContextGate(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    turn_id,
                    effective_tool_calls,
                    advertised_dynamic_tool_names,
                    err,
                );
            };
            defer selected.deinit(arena);
            for (selected.notices) |notice| try deps.pushContextNotice(notice);

            context_delta = selected.content != null;
            if (context_delta) {
                if (prepared_tool_calls.len == 1) {
                    if (!runtime_parallel_execution.isReadOnlyCall(
                        deps.tool_registry,
                        effective_tool_calls[0],
                    )) {
                        if (preparation_batch.preparations[0]) |preparation| {
                            context_deferred_calls[0] = preparation == .candidate;
                        }
                    }
                } else if (!config.cancel_flag.load(.seq_cst)) context_probes: {
                    for (preparation_batch.preparations, effective_tool_calls, 0..) |maybe_preparation, tool_call, index| {
                        if (runtime_parallel_execution.isReadOnlyCall(
                            deps.tool_registry,
                            tool_call,
                        )) continue;
                        const preparation = maybe_preparation orelse continue;
                        const candidate = switch (preparation) {
                            .terminal => continue,
                            .candidate => |candidate| candidate,
                        };
                        context_deferred_calls[index] = candidateHasApplicableContextDelta(
                            arena,
                            context_registry,
                            config,
                            &context_delivery_state,
                            candidate,
                        ) catch |err| {
                            if (config.cancel_flag.load(.seq_cst)) break :context_probes;
                            return settleFailedContextGate(
                                deps,
                                &stream_ctx.provisional_statuses,
                                stream_ctx.alloc,
                                turn_id,
                                effective_tool_calls,
                                advertised_dynamic_tool_names,
                                err,
                            );
                        };
                        if (config.cancel_flag.load(.seq_cst)) break :context_probes;
                    }
                }
            }

            if (config.cancel_flag.load(.seq_cst)) {
                var cancelled_call: ?ToolCall = null;
                find_scoped_candidate: for (preparation_batch.preparations, effective_tool_calls) |maybe_preparation, tool_call| {
                    const preparation = maybe_preparation orelse continue;
                    switch (preparation) {
                        .candidate => |candidate| {
                            if (candidate.applicable_targets.len == 0) continue;
                            cancelled_call = tool_call;
                            break :find_scoped_candidate;
                        },
                        .terminal => {},
                    }
                }
                std.debug.assert(cancelled_call != null);
                runtime_telemetry.traceCancelObserved(step_ctx, true);
                try finishPreparedCallsOnCancellation(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    arena,
                    config,
                    turn_id,
                    prepared_tool_calls,
                    preparation_batch.preparations,
                    advertised_dynamic_tool_names,
                );
                try runtime_interruption.persistInterruptedTurnOnce(
                    deps,
                    finalization,
                    job,
                    partial_assistant,
                    cancelled_call,
                    completed_tool_names.items,
                    &interrupted_persisted,
                    step_ctx,
                    within_turn_suffix.items,
                    stop_state.retained_candidate,
                    &stop_state.terminal_materializing,
                );
                finish_trace.finish("interrupted");
                return;
            }

            commitSelectedContext(
                arena,
                &stable_prefix,
                &context_delivery_state,
                &selected,
            ) catch |err| {
                return settleFailedContextGate(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    turn_id,
                    effective_tool_calls,
                    advertised_dynamic_tool_names,
                    err,
                );
            };
        }
        try runtime_tool_batch.appendAssistantToolCallStep(
            arena,
            &within_turn_suffix,
            if (terminal_provider_completion) null else completion.content,
            effective_tool_calls,
            completion.provider_state_json,
        );

        const step_has_content = !terminal_provider_completion and completion.content != null and completion.content.?.len > 0;
        if (step_has_content) {
            const first_tool_is_ask = effective_tool_calls.len > 0 and
                runtime_tool_presentation.activityKindForCall(arena, deps.tool_registry, effective_tool_calls[0]) == .ask;
            if (!first_tool_is_ask) try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });
            silent_tool_steps = 0;
        } else {
            silent_tool_steps += 1;
        }

        var step_batch = runtime_tool_batch.StepBatchState{};
        terminal_validation_retry.beginBatch();
        malformed_arguments_retry.beginBatch();
        for (effective_tool_calls) |tool_call| {
            malformed_arguments_retry.observe(tool_call);
        }
        var settled_vision_ids: std.ArrayList(usize) = .empty;
        defer mem_utils.deinitList(arena, &settled_vision_ids);
        var parallel_skip_until: usize = 0;
        for (prepared_tool_calls, 0..) |prepared_tool_call, tool_call_index| {
            if (tool_call_index < parallel_skip_until) continue;
            const tool_call = prepared_tool_call.call();

            const parallel_candidate_len = if (successful_vision_mode != .required and
                !context_delta and
                (job.permission_mode == .auto or job.permission_mode == .yolo) and
                deps.live_tool_authority == null)
                runtime_parallel_execution.parallelReadOnlyPrefixLen(deps.tool_registry, effective_tool_calls[tool_call_index..])
            else
                0;
            const parallel_len = if (parallel_candidate_len > 1) parallel: {
                const applicable_targets_fresh = parallelApplicableTargetsFresh(
                    arena,
                    deps,
                    config,
                    effective_tool_calls[tool_call_index .. tool_call_index + parallel_candidate_len],
                    preparation_batch.preparations[tool_call_index .. tool_call_index + parallel_candidate_len],
                ) catch |err| {
                    return settleFailedContextGate(
                        deps,
                        &stream_ctx.provisional_statuses,
                        stream_ctx.alloc,
                        turn_id,
                        effective_tool_calls[tool_call_index..],
                        advertised_dynamic_tool_names,
                        err,
                    );
                };
                break :parallel if (applicable_targets_fresh) parallel_candidate_len else 0;
            } else 0;
            if (parallel_len > 1) {
                const parallel_calls = effective_tool_calls[tool_call_index .. tool_call_index + parallel_len];
                const parallel_prepared = prepared_tool_calls[tool_call_index .. tool_call_index + parallel_len];
                const precomputed_results = try arena.alloc(?ToolExecutionResult, parallel_calls.len);
                @memset(precomputed_results, null);
                const parallel_status_started = try arena.alloc(bool, parallel_calls.len);
                @memset(parallel_status_started, false);
                const parallel_status_terminalized = try arena.alloc(bool, parallel_calls.len);
                @memset(parallel_status_terminalized, false);
                for (parallel_prepared, 0..) |parallel_prepared_call, group_index| {
                    const parallel_call = parallel_prepared_call.call();
                    last_tool_call_name = parallel_call.name;
                    last_tool_call_id = parallel_call.id;
                    debug_trace.eventf("tool", "tool_call", step_ctx, "call_id={s} name={s}", .{ parallel_call.id, parallel_call.name });
                    switch (parallel_prepared_call) {
                        .blocked => |blocked| {
                            precomputed_results[group_index] = .{
                                .status = .failure,
                                .model_output = blocked.model_output.?,
                            };
                            continue;
                        },
                        .provider_executed => unreachable,
                        .ready => {},
                    }
                    if (config.cancel_flag.load(.seq_cst)) {
                        runtime_telemetry.traceCancelObserved(step_ctx, true);
                        try finishPendingParallelCancelled(
                            deps,
                            &stream_ctx.provisional_statuses,
                            stream_ctx.alloc,
                            arena,
                            config,
                            turn_id,
                            parallel_calls,
                            precomputed_results,
                            parallel_status_started,
                            parallel_status_terminalized,
                            advertised_dynamic_tool_names,
                        );
                        try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                        try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, parallel_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                        finish_trace.finish("interrupted");
                        return;
                    }
                    if (try runtime_tool_admission.repeatedDynamicMcpFailure(
                        arena,
                        within_turn_suffix.items,
                        parallel_call,
                        advertised_dynamic_tool_names,
                    )) |failure| {
                        precomputed_results[group_index] = failure;
                        continue;
                    }
                    if (preparation_batch.preparations[tool_call_index + group_index]) |preparation| {
                        switch (preparation) {
                            .candidate => |candidate| {
                                if (preparedCandidateClassificationComplete(candidate)) {
                                    continue;
                                }
                            },
                            .terminal => |terminal| {
                                const model_output = try preparedTerminalModelOutput(
                                    arena,
                                    parallel_call,
                                    terminal,
                                );
                                precomputed_results[group_index] = .{
                                    .status = switch (terminal.status) {
                                        .success => .success,
                                        .failure => .failure,
                                    },
                                    .model_output = model_output,
                                };
                                continue;
                            },
                        }
                    }
                    if (try runtime_tool_admission.registeredToolValidationFailure(deps, arena, parallel_call)) |failure| {
                        precomputed_results[group_index] = failure;
                        continue;
                    }
                    if (try runtime_tool_admission.toolAvailabilityFailure(deps, arena, parallel_call)) |failure| {
                        precomputed_results[group_index] = failure;
                        continue;
                    }
                }

                var executable_calls: std.ArrayList(ToolCall) = .empty;
                defer mem_utils.deinitList(arena, &executable_calls);
                var executable_classification_complete: std.ArrayList(bool) = .empty;
                defer mem_utils.deinitList(arena, &executable_classification_complete);
                for (parallel_calls, precomputed_results, 0..) |parallel_call, precomputed, group_index| {
                    if (precomputed != null) continue;
                    if (config.cancel_flag.load(.seq_cst)) {
                        runtime_telemetry.traceCancelObserved(step_ctx, true);
                        try finishPendingParallelCancelled(
                            deps,
                            &stream_ctx.provisional_statuses,
                            stream_ctx.alloc,
                            arena,
                            config,
                            turn_id,
                            parallel_calls,
                            precomputed_results,
                            parallel_status_started,
                            parallel_status_terminalized,
                            advertised_dynamic_tool_names,
                        );
                        try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                        try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, parallel_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                        finish_trace.finish("interrupted");
                        return;
                    }
                    if (!runtime_tool_admission.deferVisibleLifecycleUntilAfterPermission(parallel_call.name)) {
                        parallel_status_started[group_index] = try runtime_tool_presentation.startToolVisibleLifecycle(deps, arena, turn_id, stream_ctx.provisional_statuses.presentation_group_id, parallel_call, null, advertised_dynamic_tool_names);
                    }

                    const parallel_review_context = buildReviewTurnContext(
                        config,
                        successful_gateway_model,
                        job.prompt,
                        root_user_intent_context,
                        pending_assistant,
                        parallel_call.id,
                        auto_permission_phase,
                    );
                    const maybe_parallel_permission: ?command_admission.PermissionOutcome = runtime_tool_admission.requestToolPermissionTraced(deps, arena, parallel_call, parallel_review_context, job.permission_mode, local_grants.items, null, null, advertised_dynamic_tool_names, config.workspace_root, step_ctx) catch |err| blk: {
                        if (err != error.Cancelled or !config.cancel_flag.load(.seq_cst)) return err;
                        break :blk null;
                    };
                    if (maybe_parallel_permission == null or config.cancel_flag.load(.seq_cst)) {
                        runtime_telemetry.traceCancelObserved(step_ctx, true);
                        try finishPendingParallelCancelled(
                            deps,
                            &stream_ctx.provisional_statuses,
                            stream_ctx.alloc,
                            arena,
                            config,
                            turn_id,
                            parallel_calls,
                            precomputed_results,
                            parallel_status_started,
                            parallel_status_terminalized,
                            advertised_dynamic_tool_names,
                        );
                        try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                        try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, parallel_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                        finish_trace.finish("interrupted");
                        return;
                    }
                    const permission_outcome = maybe_parallel_permission.?;
                    if (permission_outcome.tool_failure) |failure_output| {
                        const failure: ToolExecutionResult = .{
                            .status = .failure,
                            .model_output = failure_output,
                            .status_detail = "preflight failed",
                        };
                        precomputed_results[group_index] = failure;
                        continue;
                    }
                    const decision = permission_outcome.decision;
                    if (decision.isDenied()) {
                        const reason = permission_outcome.denial_reason orelse
                            decision.denialReason() orelse .user_denied;
                        const denied_output = try tool_result_errors.toolPermissionDeniedJson(arena, parallel_call.name, reason);
                        parallel_status_terminalized[group_index] = try stream_ctx.provisional_statuses.finishDeniedCall(
                            deps,
                            stream_ctx.alloc,
                            arena,
                            turn_id,
                            parallel_call,
                            parallel_status_started[group_index],
                            null,
                            runtime_tool_admission.permissionDeniedStatusLabel(reason),
                            advertised_dynamic_tool_names,
                        );
                        tool_dispatch.traceDeniedWebSearch(step_ctx, parallel_call, reason);
                        debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind=permission_denied reason={s} model_output_bytes={d}", .{ parallel_call.id, parallel_call.name, @tagName(reason), denied_output.len });
                        precomputed_results[group_index] = .{ .status = .failure, .model_output = denied_output };
                        continue;
                    }

                    if (decision == .always) {
                        const target_path = try deps.permission_target_for_call(deps.ctx, arena, parallel_call, advertised_dynamic_tool_names);
                        try runtime_tool_admission.applyInitialSessionGrants(deps, arena, &local_grants, config.workspace_root, parallel_call, target_path);
                    }

                    if (!parallel_status_started[group_index]) {
                        parallel_status_started[group_index] = try runtime_tool_presentation.startToolVisibleLifecycle(deps, arena, turn_id, stream_ctx.provisional_statuses.presentation_group_id, parallel_call, null, advertised_dynamic_tool_names);
                    }
                    const parallel_authority = permission_outcome.execution_authority orelse
                        return error.MissingToolExecutionAuthority;
                    if (parallel_authority != .ordinary) {
                        return error.UnexpectedCommandExecutionAuthority;
                    }
                    try executable_calls.append(arena, parallel_call);
                    const classification_complete = if (preparation_batch.preparations[tool_call_index + group_index]) |preparation|
                        switch (preparation) {
                            .candidate => |candidate| preparedCandidateClassificationComplete(candidate),
                            .terminal => false,
                        }
                    else
                        false;
                    try executable_classification_complete.append(
                        arena,
                        classification_complete,
                    );
                }

                var parallel_run: ?runtime_parallel_execution.ParallelRunResult = null;
                if (executable_calls.items.len > 0) {
                    if (config.cancel_flag.load(.seq_cst)) {
                        runtime_telemetry.traceCancelObserved(step_ctx, true);
                        try finishPendingParallelCancelled(
                            deps,
                            &stream_ctx.provisional_statuses,
                            stream_ctx.alloc,
                            arena,
                            config,
                            turn_id,
                            parallel_calls,
                            precomputed_results,
                            parallel_status_started,
                            parallel_status_terminalized,
                            advertised_dynamic_tool_names,
                        );
                        try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                        try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, executable_calls.items[0], completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                        finish_trace.finish("interrupted");
                        return;
                    }
                    for (executable_calls.items) |executable_call| {
                        debug_trace.eventf(
                            "tool",
                            "before_tool_execution",
                            step_ctx,
                            "call_id={s} name={s}",
                            .{ executable_call.id, executable_call.name },
                        );
                        debug_trace.eventf(
                            "tool",
                            "execution_start",
                            step_ctx,
                            "call_id={s} name={s}",
                            .{ executable_call.id, executable_call.name },
                        );
                        if (deps.tool_activity_recorder) |recorder| {
                            recorder.record(
                                executable_call.id,
                                executable_call.name,
                                .started,
                            ) catch |err| {
                                debug_trace.eventf(
                                    "subagent",
                                    "tool_activity_projection_lag",
                                    step_ctx,
                                    "call_id={s} tool_name={s} phase=started outcome={s}",
                                    .{
                                        executable_call.id,
                                        executable_call.name,
                                        @errorName(err),
                                    },
                                );
                            };
                        }
                    }
                    debug_trace.eventf("tool", "parallel_read_only_start", step_ctx, "count={d}", .{executable_calls.items.len});
                    const parallel_execution_root_user_context = try buildToolExecutionRootUserContext(
                        arena,
                        root_user_intent_context,
                        within_turn_suffix.items,
                        step_batch.pending_user_suffix.items,
                    );
                    var parallel_exec_ctx = runtime_parallel_execution.ParallelHookExecContext{
                        .hooks = deps,
                        .turn_id = turn_id,
                        .root_user_intent_context = parallel_execution_root_user_context,
                        .current_turn_messages = within_turn_suffix.items,
                        .session_grants = local_grants.items,
                        .advertised_dynamic_tool_names = advertised_dynamic_tool_names,
                        .max_tool_result_bytes = config.max_tool_result_bytes,
                        .classification_complete = executable_classification_complete.items,
                    };
                    if (comptime host_target.is_wasm) {
                        parallel_run = try runtime_parallel_execution.runSequentialReadOnlyCalls(arena, executable_calls.items, .{
                            .exec_ctx = &parallel_exec_ctx,
                            .execute = runtime_parallel_execution.parallelHookExecute,
                            .format_ctx = &parallel_exec_ctx,
                            .format_error = runtime_parallel_execution.parallelHookFormatError,
                            .cancel_flag = config.cancel_flag,
                        });
                    } else {
                        parallel_run = try runtime_parallel_execution.runParallelReadOnlyCalls(arena, executable_calls.items, .{
                            .exec_ctx = &parallel_exec_ctx,
                            .execute = runtime_parallel_execution.parallelHookExecute,
                            .format_ctx = &parallel_exec_ctx,
                            .format_error = runtime_parallel_execution.parallelHookFormatError,
                            .cancel_flag = config.cancel_flag,
                        });
                    }
                }
                defer if (parallel_run) |*run| run.deinit(arena);

                const admitted_parallel_calls = parallel_calls;
                const admitted_precomputed_results = precomputed_results;
                const admitted_status_started = parallel_status_started;
                for (
                    admitted_parallel_calls,
                    admitted_precomputed_results,
                ) |parallel_call, precomputed| {
                    const execution = precomputed orelse continue;
                    if (parallel_call.argument_integrity == .malformed_json) continue;
                    try runtime_tool_admission.recordRejectedToolCall(
                        deps,
                        arena,
                        parallel_call,
                        execution.model_output,
                        null,
                    );
                }
                const cancelled_call = try runtime_tool_batch.assembleParallelToolResults(
                    arena,
                    deps,
                    config,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    admitted_parallel_calls,
                    admitted_precomputed_results,
                    if (parallel_run) |run| run.attempts else &.{},
                    admitted_status_started,
                    parallel_status_terminalized,
                    turn_id,
                    advertised_dynamic_tool_names,
                    step_ctx,
                );
                debug_trace.eventf(
                    "tool",
                    "parallel_read_only_finish",
                    step_ctx,
                    "count={d}",
                    .{if (parallel_run) |run| run.attempts.len else 0},
                );
                if (config.cancel_flag.load(.seq_cst)) {
                    runtime_telemetry.traceCancelObserved(step_ctx, true);
                    try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                    try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, cancelled_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                    finish_trace.finish("interrupted");
                    return;
                }

                parallel_skip_until = tool_call_index + parallel_len;
                continue;
            }

            var tool_display_target = if (deps.resolve_tool_action_display_target) |resolve|
                try resolve(deps.ctx, arena, tool_call)
            else
                null;
            last_tool_call_name = tool_call.name;
            last_tool_call_id = tool_call.id;
            debug_trace.eventf("tool", "tool_call", step_ctx, "call_id={s} name={s}", .{ tool_call.id, tool_call.name });
            switch (prepared_tool_call) {
                .blocked => |blocked| {
                    if (blocked.kind == .malformed_arguments) {
                        try stream_ctx.provisional_statuses.finishMalformedToolArguments(
                            deps,
                            arena,
                            turn_id,
                            tool_call,
                        );
                        debug_trace.eventf(
                            "tool",
                            "argument_integrity_rejected",
                            step_ctx,
                            "call_id={s} name={s} failure=malformed_json provenance=fx_local",
                            .{ tool_call.id, tool_call.name },
                        );
                    } else if (blocked.kind == .route_unavailable) {
                        debug_trace.eventf(
                            "tool",
                            "route_tool_unavailable",
                            step_ctx,
                            "call_id={s} name={s}",
                            .{ tool_call.id, tool_call.name },
                        );
                    } else if (blocked.kind == .required_vision) {
                        debug_trace.eventf(
                            "tool",
                            "required_vision_tool_rejected",
                            step_ctx,
                            "call_id={s} name={s}",
                            .{ tool_call.id, tool_call.name },
                        );
                    } else {
                        debug_trace.eventf(
                            "tool",
                            "pre_tool_use_blocked",
                            step_ctx,
                            "call_id={s} name={s} kind={s}",
                            .{ tool_call.id, tool_call.name, @tagName(blocked.kind) },
                        );
                    }
                    const execution: ToolExecutionResult = .{
                        .status = .failure,
                        .model_output = blocked.model_output.?,
                    };
                    const prepared = try runtime_execution_memory.prepareToolModelOutput(
                        arena,
                        config,
                        tool_call,
                        execution.model_output,
                    );
                    if (blocked.kind != .malformed_arguments and
                        blocked.kind != .route_unavailable and
                        blocked.kind != .required_vision)
                    {
                        _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                            deps,
                            stream_ctx.alloc,
                            arena,
                            turn_id,
                            tool_call,
                            false,
                            tool_display_target,
                            execution,
                            prepared.model_output,
                            prepared.memory,
                            null,
                            advertised_dynamic_tool_names,
                        );
                    }
                    try runtime_tool_admission.recordRejectedToolCall(
                        deps,
                        arena,
                        tool_call,
                        prepared.model_output,
                        null,
                    );
                    debug_trace.eventf(
                        "tool",
                        "execution_result",
                        step_ctx,
                        "call_id={s} name={s} result_kind={s} model_output_bytes={d}",
                        .{
                            tool_call.id,
                            tool_call.name,
                            @tagName(blocked.kind),
                            prepared.model_output.len,
                        },
                    );
                    try runtime_tool_batch.appendToolResultContent(
                        arena,
                        &within_turn_suffix,
                        &completed_tool_names,
                        &step_batch,
                        tool_call,
                        prepared.model_output,
                        prepared.memory,
                        .{ .increment_error = true },
                    );
                    continue;
                },
                .provider_executed, .ready => {},
            }
            if (tool_call.argument_integrity == .malformed_json) {
                unreachable;
            }
            if (config.cancel_flag.load(.seq_cst)) {
                runtime_telemetry.traceCancelObserved(step_ctx, true);
                try finishPendingCancelledCalls(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    arena,
                    config,
                    turn_id,
                    effective_tool_calls[tool_call_index..],
                    advertised_dynamic_tool_names,
                );
                try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, tool_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                finish_trace.finish("interrupted");
                return;
            }
            if (tool_call.provenance == .provider_executed) {
                try appendProviderExecutedToolResult(
                    deps,
                    &stream_ctx,
                    arena,
                    config,
                    turn_id,
                    tool_call,
                    advertised_dynamic_tool_names,
                    step_ctx,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                );
                continue;
            }
            if (context_deferred_calls[tool_call_index]) {
                if (preparation_batch.preparations[tool_call_index]) |preparation| {
                    if (preparation == .candidate) {
                        try appendContextDeferredToolResult(
                            deps,
                            &stream_ctx.provisional_statuses,
                            stream_ctx.alloc,
                            arena,
                            turn_id,
                            tool_call,
                            advertised_dynamic_tool_names,
                            step_ctx,
                            &within_turn_suffix,
                            &completed_tool_names,
                            &step_batch,
                        );
                        continue;
                    }
                }
            }
            if (preparation_batch.preparations[tool_call_index]) |preparation| {
                switch (preparation) {
                    .candidate => {},
                    .terminal => |terminal| {
                        const model_output = try preparedTerminalModelOutput(
                            arena,
                            tool_call,
                            terminal,
                        );
                        const prepared_terminal = try runtime_execution_memory.prepareToolModelOutput(
                            arena,
                            config,
                            tool_call,
                            model_output,
                        );
                        const safe_output = prepared_terminal.model_output;
                        switch (terminal.kind) {
                            .idempotent_skip => {
                                const execution: ToolExecutionResult = .{
                                    .status = if (terminal.status == .success) .success else .failure,
                                    .model_output = safe_output,
                                };
                                _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                                    deps,
                                    stream_ctx.alloc,
                                    arena,
                                    turn_id,
                                    tool_call,
                                    false,
                                    tool_display_target,
                                    execution,
                                    safe_output,
                                    prepared_terminal.memory,
                                    null,
                                    advertised_dynamic_tool_names,
                                );
                                try runtime_tool_batch.appendToolResultContent(
                                    arena,
                                    &within_turn_suffix,
                                    &completed_tool_names,
                                    &step_batch,
                                    tool_call,
                                    safe_output,
                                    prepared_terminal.memory,
                                    .{
                                        .increment_error = terminal.status == .failure or
                                            tool_result_errors.isToolOutputError(safe_output),
                                        .record_completion = true,
                                    },
                                );
                            },
                            .validation_failure, .availability_failure => {
                                if (terminal.kind == .validation_failure) {
                                    try terminal_validation_retry.observe(
                                        arena,
                                        tool_call,
                                        model_output,
                                    );
                                }
                                const execution: ToolExecutionResult = .{
                                    .status = .failure,
                                    .model_output = safe_output,
                                };
                                _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                                    deps,
                                    stream_ctx.alloc,
                                    arena,
                                    turn_id,
                                    tool_call,
                                    false,
                                    tool_display_target,
                                    execution,
                                    safe_output,
                                    prepared_terminal.memory,
                                    null,
                                    advertised_dynamic_tool_names,
                                );
                                try runtime_tool_admission.recordRejectedToolCall(
                                    deps,
                                    arena,
                                    tool_call,
                                    safe_output,
                                    null,
                                );
                                try runtime_tool_batch.appendToolResultContent(
                                    arena,
                                    &within_turn_suffix,
                                    &completed_tool_names,
                                    &step_batch,
                                    tool_call,
                                    safe_output,
                                    prepared_terminal.memory,
                                    .{ .increment_error = true },
                                );
                            },
                            .stop_policy => {
                                const defer_auto_lifecycle = try runtime_tool_admission.deferCapturedCommandLifecycleForAutoPermissionNotice(
                                    deps.tool_registry,
                                    arena,
                                    tool_call,
                                    job.permission_mode,
                                    lifecycle.scope.kind == .interactive,
                                );
                                const status_started = if (runtime_tool_admission.deferVisibleLifecycleUntilAfterPermission(tool_call.name) and
                                    !defer_auto_lifecycle)
                                    false
                                else
                                    try runtime_tool_presentation.startToolVisibleLifecycle(
                                        deps,
                                        arena,
                                        turn_id,
                                        stream_ctx.provisional_statuses.presentation_group_id,
                                        tool_call,
                                        tool_display_target,
                                        advertised_dynamic_tool_names,
                                    );
                                _ = try stream_ctx.provisional_statuses.finishDeniedCall(
                                    deps,
                                    stream_ctx.alloc,
                                    arena,
                                    turn_id,
                                    tool_call,
                                    status_started,
                                    tool_display_target,
                                    "Blocked",
                                    advertised_dynamic_tool_names,
                                );
                                try runtime_tool_batch.appendToolResultContent(
                                    arena,
                                    &within_turn_suffix,
                                    &completed_tool_names,
                                    &step_batch,
                                    tool_call,
                                    safe_output,
                                    null,
                                    .{ .increment_error = true },
                                );
                            },
                            .file_mutation_failure => {
                                const status_started = try runtime_tool_presentation.startToolVisibleLifecycle(
                                    deps,
                                    arena,
                                    turn_id,
                                    stream_ctx.provisional_statuses.presentation_group_id,
                                    tool_call,
                                    tool_display_target,
                                    advertised_dynamic_tool_names,
                                );
                                const execution: ToolExecutionResult = .{
                                    .status = .failure,
                                    .model_output = safe_output,
                                    .status_detail = "preflight failed",
                                };
                                _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                                    deps,
                                    stream_ctx.alloc,
                                    arena,
                                    turn_id,
                                    tool_call,
                                    status_started,
                                    tool_display_target,
                                    execution,
                                    safe_output,
                                    prepared_terminal.memory,
                                    null,
                                    advertised_dynamic_tool_names,
                                );
                                try runtime_tool_batch.appendToolResultContent(
                                    arena,
                                    &within_turn_suffix,
                                    &completed_tool_names,
                                    &step_batch,
                                    tool_call,
                                    safe_output,
                                    prepared_terminal.memory,
                                    .{ .increment_error = true },
                                );
                                try runtime_tool_admission.recordRejectedToolCall(
                                    deps,
                                    arena,
                                    tool_call,
                                    safe_output,
                                    null,
                                );
                            },
                            .unsupported => {
                                const execution: ToolExecutionResult = .{
                                    .status = .failure,
                                    .model_output = safe_output,
                                };
                                _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                                    deps,
                                    stream_ctx.alloc,
                                    arena,
                                    turn_id,
                                    tool_call,
                                    false,
                                    tool_display_target,
                                    execution,
                                    safe_output,
                                    prepared_terminal.memory,
                                    null,
                                    advertised_dynamic_tool_names,
                                );
                                try runtime_tool_batch.appendToolResultContent(
                                    arena,
                                    &within_turn_suffix,
                                    &completed_tool_names,
                                    &step_batch,
                                    tool_call,
                                    safe_output,
                                    prepared_terminal.memory,
                                    .{
                                        .increment_error = true,
                                        .record_completion = true,
                                        .status = runtime_execution_memory.persistedStatusForCurrentFxLocalResult(
                                            .failure,
                                            safe_output,
                                        ),
                                    },
                                );
                            },
                        }
                        debug_trace.eventf(
                            "tool",
                            "execution_result",
                            step_ctx,
                            "call_id={s} name={s} result_kind={s} model_output_bytes={d}",
                            .{ tool_call.id, tool_call.name, @tagName(terminal.kind), safe_output.len },
                        );
                        continue;
                    },
                }
            }
            if (try runtime_tool_admission.repeatedDynamicMcpFailure(
                arena,
                within_turn_suffix.items,
                tool_call,
                advertised_dynamic_tool_names,
            )) |execution| {
                const prepared = try runtime_execution_memory.prepareToolModelOutput(
                    arena,
                    config,
                    tool_call,
                    execution.model_output,
                );
                const safe_tool_output = prepared.model_output;
                _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                    deps,
                    stream_ctx.alloc,
                    arena,
                    turn_id,
                    tool_call,
                    false,
                    tool_display_target,
                    execution,
                    safe_tool_output,
                    prepared.memory,
                    null,
                    advertised_dynamic_tool_names,
                );
                try runtime_tool_admission.recordRejectedToolCall(
                    deps,
                    arena,
                    tool_call,
                    safe_tool_output,
                    null,
                );
                debug_trace.eventf(
                    "tool",
                    "execution_result",
                    step_ctx,
                    "call_id={s} name={s} result_kind=repeated_mcp_failure model_output_bytes={d}",
                    .{ tool_call.id, tool_call.name, safe_tool_output.len },
                );
                try runtime_tool_batch.appendToolResultContent(
                    arena,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                    tool_call,
                    safe_tool_output,
                    prepared.memory,
                    .{ .increment_error = true },
                );
                continue;
            }
            const requires_legacy_classification = if (preparation_batch.preparations[tool_call_index]) |preparation|
                switch (preparation) {
                    .candidate => |candidate| !preparedCandidateClassificationComplete(candidate),
                    .terminal => false,
                }
            else
                true;
            if (requires_legacy_classification) {
                if (try runtime_tool_admission.registeredToolValidationFailure(deps, arena, tool_call)) |execution| {
                    try terminal_validation_retry.observe(
                        arena,
                        tool_call,
                        execution.model_output,
                    );
                    const prepared = try runtime_execution_memory.prepareToolModelOutput(arena, config, tool_call, execution.model_output);
                    const safe_tool_output = prepared.model_output;
                    _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                        deps,
                        stream_ctx.alloc,
                        arena,
                        turn_id,
                        tool_call,
                        false,
                        tool_display_target,
                        execution,
                        safe_tool_output,
                        prepared.memory,
                        null,
                        advertised_dynamic_tool_names,
                    );
                    try runtime_tool_admission.recordRejectedToolCall(
                        deps,
                        arena,
                        tool_call,
                        safe_tool_output,
                        null,
                    );
                    debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind=validation_failure model_output_bytes={d}", .{ tool_call.id, tool_call.name, safe_tool_output.len });
                    try runtime_tool_batch.appendToolResultContent(
                        arena,
                        &within_turn_suffix,
                        &completed_tool_names,
                        &step_batch,
                        tool_call,
                        safe_tool_output,
                        prepared.memory,
                        .{ .increment_error = true },
                    );
                    continue;
                }
                if (try runtime_tool_admission.toolAvailabilityFailure(deps, arena, tool_call)) |execution| {
                    const prepared = try runtime_execution_memory.prepareToolModelOutput(arena, config, tool_call, execution.model_output);
                    const safe_tool_output = prepared.model_output;
                    _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                        deps,
                        stream_ctx.alloc,
                        arena,
                        turn_id,
                        tool_call,
                        false,
                        tool_display_target,
                        execution,
                        safe_tool_output,
                        prepared.memory,
                        null,
                        advertised_dynamic_tool_names,
                    );
                    try runtime_tool_admission.recordRejectedToolCall(
                        deps,
                        arena,
                        tool_call,
                        safe_tool_output,
                        null,
                    );
                    debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind=availability_failure model_output_bytes={d}", .{ tool_call.id, tool_call.name, safe_tool_output.len });
                    try runtime_tool_batch.appendToolResultContent(
                        arena,
                        &within_turn_suffix,
                        &completed_tool_names,
                        &step_batch,
                        tool_call,
                        safe_tool_output,
                        prepared.memory,
                        .{ .increment_error = true },
                    );
                    continue;
                }
            }
            const is_file_mutation = file_mutation_contract.isToolName(tool_call.name);
            var prepared_file_mutation: ?tooling_tool_admission.PreparedFileMutationCall = null;
            defer if (prepared_file_mutation) |*prepared| prepared.deinit(arena);

            const applicable_targets_fresh = if (is_file_mutation and
                preparation_batch.preparations[tool_call_index] != null)
            fresh: {
                const admission = tooling_tool_admission.prepareFileMutationCall(
                    arena,
                    tool_call,
                    .{
                        .tool_registry = deps.tool_registry,
                        .workspace_root = config.workspace_root,
                        .access_scope = config.access_scope,
                    },
                ) catch |err| {
                    return settleFailedContextGate(
                        deps,
                        &stream_ctx.provisional_statuses,
                        stream_ctx.alloc,
                        turn_id,
                        effective_tool_calls[tool_call_index..],
                        advertised_dynamic_tool_names,
                        err,
                    );
                };
                switch (admission) {
                    .tool_failure => break :fresh false,
                    .prepared => |prepared| {
                        prepared_file_mutation = prepared;
                        break :fresh preparedFileMutationTargetMatches(
                            if (preparation_batch.preparations[tool_call_index]) |*preparation|
                                preparation
                            else
                                null,
                            prepared,
                        );
                    },
                }
            } else if (preparation_batch.preparations[tool_call_index]) |*preparation|
                preparedCallApplicableTargetsFresh(
                    arena,
                    deps,
                    config,
                    tool_call,
                    preparation,
                ) catch |err| {
                    return settleFailedContextGate(
                        deps,
                        &stream_ctx.provisional_statuses,
                        stream_ctx.alloc,
                        turn_id,
                        effective_tool_calls[tool_call_index..],
                        advertised_dynamic_tool_names,
                        err,
                    );
                }
            else
                true;
            if (!applicable_targets_fresh) {
                try appendNotExecutedToolResult(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    arena,
                    turn_id,
                    tool_call,
                    advertised_dynamic_tool_names,
                    step_ctx,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                    "applicable_targets_changed",
                );
                continue;
            }
            const external_file_action_identity = if (prepared_file_mutation) |prepared|
                prepared.externalActionIdentity()
            else
                null;
            const live_authority_target = if (prepared_file_mutation) |prepared|
                try arena.dupe(u8, prepared.targetPath())
            else
                null;
            var live_authority = if (deps.live_tool_authority != null) live: {
                const resolved = try resolveLiveToolAuthority(
                    deps,
                    arena,
                    tool_call,
                    config.workspace_root,
                    advertised_dynamic_tool_names,
                    live_authority_target,
                );
                if (liveAuthorityRejectsExecution(resolved)) {
                    const outcome: []const u8 = if (resolved.decision == .deny)
                        "denied"
                    else
                        "unavailable";
                    debug_trace.eventf(
                        "subagent",
                        "live_authority_rejected",
                        step_ctx,
                        "call_id={s} tool_name={s} generation={d} outcome={s}",
                        .{ tool_call.id, tool_call.name, resolved.authority.generation, outcome },
                    );
                    if (deps.tool_activity_recorder) |recorder| {
                        recorder.record(tool_call.id, tool_call.name, .denied) catch |err| {
                            debug_trace.eventf(
                                "subagent",
                                "tool_activity_projection_lag",
                                step_ctx,
                                "call_id={s} tool_name={s} phase=denied outcome={s}",
                                .{ tool_call.id, tool_call.name, @errorName(err) },
                            );
                        };
                    }
                    try appendNotExecutedToolResult(
                        deps,
                        &stream_ctx.provisional_statuses,
                        stream_ctx.alloc,
                        arena,
                        turn_id,
                        tool_call,
                        advertised_dynamic_tool_names,
                        step_ctx,
                        &within_turn_suffix,
                        &completed_tool_names,
                        &step_batch,
                        if (resolved.decision == .deny)
                            "live_authority_denied"
                        else
                            "live_authority_unavailable",
                    );
                    continue;
                }
                break :live resolved;
            } else null;
            const action_permission_mode: types.PermissionMode = if (live_authority != null)
                live_authority.?.authority.permission_mode
            else
                job.permission_mode;
            const action_grants: []const PermissionGrant = if (live_authority) |resolved|
                resolved.authority.grants
            else
                local_grants.items;
            var status_started = false;
            const defer_auto_command_lifecycle = try runtime_tool_admission.deferCapturedCommandLifecycleForAutoPermissionNotice(
                deps.tool_registry,
                arena,
                tool_call,
                action_permission_mode,
                lifecycle.scope.kind == .interactive,
            );
            if (!runtime_tool_admission.deferVisibleLifecycleUntilAfterPermission(tool_call.name) and
                !defer_auto_command_lifecycle)
            {
                status_started = try runtime_tool_presentation.startToolVisibleLifecycle(deps, arena, turn_id, stream_ctx.provisional_statuses.presentation_group_id, tool_call, tool_display_target, advertised_dynamic_tool_names);
            }

            if (try runtime_stop_policy.blockedNonLiveBackgroundRestart(
                arena,
                successful_source_messages,
                tool_call,
                job.prompt,
            )) |blocked_output| {
                _ = try stream_ctx.provisional_statuses.finishDeniedCall(
                    deps,
                    stream_ctx.alloc,
                    arena,
                    turn_id,
                    tool_call,
                    status_started,
                    tool_display_target,
                    "Blocked",
                    advertised_dynamic_tool_names,
                );
                debug_trace.eventf(
                    "tool",
                    "execution_result",
                    step_ctx,
                    "call_id={s} name={s} result_kind=blocked_non_live_background_restart model_output_bytes={d}",
                    .{ tool_call.id, tool_call.name, blocked_output.len },
                );
                try runtime_tool_batch.appendToolResultContent(
                    arena,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                    tool_call,
                    blocked_output,
                    null,
                    .{ .increment_error = true },
                );
                continue;
            }

            var file_call_arena_state: std.heap.ArenaAllocator = undefined;
            if (is_file_mutation) {
                file_call_arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            }
            defer if (is_file_mutation) file_call_arena_state.deinit();
            const call_allocator = if (is_file_mutation)
                file_call_arena_state.allocator()
            else
                arena;
            const execution_call = if (is_file_mutation)
                try types.dupeToolCall(call_allocator, tool_call)
            else
                tool_call;
            const review_context = buildReviewTurnContext(
                config,
                successful_gateway_model,
                job.prompt,
                root_user_intent_context,
                pending_assistant,
                execution_call.id,
                auto_permission_phase,
            );
            const tool_execution_root_user_context = try buildToolExecutionRootUserContext(
                call_allocator,
                root_user_intent_context,
                within_turn_suffix.items,
                step_batch.pending_user_suffix.items,
            );
            const permission_authority_generation = if (live_authority) |resolved|
                resolved.authority.generation
            else
                0;
            const preserved_denial = if (external_file_action_identity) |identity|
                turn_file_mutation_denials.preservedOutcome(identity)
            else
                null;
            const approved_revalidation = turn_permission_recovery.takeApproval(
                execution_call,
            );
            const preserved_automatic_denial = if (approved_revalidation == null and
                auto_permission_phase == .automatic_review)
                try turn_permission_recovery.preservedOutcome(
                    call_allocator,
                    config.workspace_root,
                    execution_call,
                )
            else
                null;
            const effective_preserved_denial = preserved_denial orelse
                preserved_automatic_denial;
            if (effective_preserved_denial != null) {
                debug_trace.eventf(
                    "permission",
                    "turn_permission_denial_preserved",
                    step_ctx,
                    "call_id={s} tool_name={s}",
                    .{ tool_call.id, tool_call.name },
                );
            }
            const maybe_permission: ?command_admission.PermissionOutcome = if (approved_revalidation) |revalidation|
                try runtime_tool_admission.requestToolPermissionTraced(
                    deps,
                    call_allocator,
                    execution_call,
                    review_context,
                    action_permission_mode,
                    action_grants,
                    if (live_authority) |resolved| resolved.authority else null,
                    revalidation,
                    advertised_dynamic_tool_names,
                    config.workspace_root,
                    step_ctx,
                )
            else if (effective_preserved_denial) |outcome|
                outcome
            else
                (if (prepared_file_mutation) |*prepared|
                    runtime_tool_admission.requestPreparedFileMutationPermissionTraced(
                        deps,
                        arena,
                        execution_call,
                        prepared,
                        review_context,
                        action_permission_mode,
                        action_grants,
                        if (live_authority) |resolved| resolved.authority else null,
                        advertised_dynamic_tool_names,
                        config.workspace_root,
                        step_ctx,
                    )
                else
                    runtime_tool_admission.requestToolPermissionTraced(
                        deps,
                        call_allocator,
                        execution_call,
                        review_context,
                        action_permission_mode,
                        action_grants,
                        if (live_authority) |resolved| resolved.authority else null,
                        null,
                        advertised_dynamic_tool_names,
                        config.workspace_root,
                        step_ctx,
                    )) catch |err| blk: {
                    if (err != error.Cancelled or !config.cancel_flag.load(.seq_cst)) return err;
                    break :blk null;
                };
            if (maybe_permission == null or config.cancel_flag.load(.seq_cst)) {
                runtime_telemetry.traceCancelObserved(step_ctx, true);
                if (!status_started and (is_file_mutation or defer_auto_command_lifecycle)) {
                    status_started = try runtime_tool_presentation.startToolVisibleLifecycle(
                        deps,
                        call_allocator,
                        turn_id,
                        stream_ctx.provisional_statuses.presentation_group_id,
                        execution_call,
                        tool_display_target,
                        advertised_dynamic_tool_names,
                    );
                }
                _ = try stream_ctx.provisional_statuses.finishDeniedCall(
                    deps,
                    stream_ctx.alloc,
                    call_allocator,
                    turn_id,
                    execution_call,
                    status_started,
                    tool_display_target,
                    "Cancelled",
                    advertised_dynamic_tool_names,
                );
                try finishPendingCancelledCalls(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    arena,
                    config,
                    turn_id,
                    effective_tool_calls[tool_call_index + 1 ..],
                    advertised_dynamic_tool_names,
                );
                try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, tool_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                finish_trace.finish("interrupted");
                return;
            }
            var permission_result = maybe_permission.?;
            var validated_permission_generation = permission_authority_generation;
            var exact_human_approval = permission_result.human_approval;
            while (permission_result.tool_failure == null and
                !permission_result.decision.isDenied() and
                deps.live_tool_authority != null)
            {
                const refreshed = try resolveLiveToolAuthority(
                    deps,
                    arena,
                    tool_call,
                    config.workspace_root,
                    advertised_dynamic_tool_names,
                    live_authority_target,
                );
                live_authority = refreshed;
                if (refreshed.authority.generation == validated_permission_generation) {
                    if (liveAuthorityUnavailable(refreshed)) {
                        debug_trace.eventf(
                            "subagent",
                            "live_authority_rejected",
                            step_ctx,
                            "call_id={s} tool_name={s} generation={d} outcome=unavailable",
                            .{ tool_call.id, tool_call.name, refreshed.authority.generation },
                        );
                        rejectPermissionForLiveAuthority(&permission_result);
                    }
                    break;
                }

                validated_permission_generation = refreshed.authority.generation;
                const prepared_authority = permission_result.execution_authority orelse
                    return error.MissingToolExecutionAuthority;
                const maybe_revalidated: ?command_admission.PermissionOutcome = runtime_tool_admission.requestToolPermissionTraced(
                    deps,
                    call_allocator,
                    execution_call,
                    review_context,
                    refreshed.authority.permission_mode,
                    refreshed.authority.grants,
                    refreshed.authority,
                    .{ .action = .{
                        .authority = prepared_authority,
                        .human_approval = exact_human_approval,
                    } },
                    advertised_dynamic_tool_names,
                    config.workspace_root,
                    step_ctx,
                ) catch |err| blk: {
                    if (err != error.Cancelled or !config.cancel_flag.load(.seq_cst)) return err;
                    break :blk null;
                };
                if (maybe_revalidated == null or config.cancel_flag.load(.seq_cst)) {
                    runtime_telemetry.traceCancelObserved(step_ctx, true);
                    if (!status_started and (is_file_mutation or defer_auto_command_lifecycle)) {
                        status_started = try runtime_tool_presentation.startToolVisibleLifecycle(
                            deps,
                            call_allocator,
                            turn_id,
                            null,
                            execution_call,
                            tool_display_target,
                            advertised_dynamic_tool_names,
                        );
                    }
                    try runtime_tool_presentation.finishDeniedToolStatus(
                        deps,
                        call_allocator,
                        turn_id,
                        execution_call,
                        status_started,
                        tool_display_target,
                        "Cancelled",
                        advertised_dynamic_tool_names,
                    );
                    try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                    try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, tool_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                    finish_trace.finish("interrupted");
                    return;
                }
                permission_result = maybe_revalidated.?;
                if (exact_human_approval != .once) {
                    exact_human_approval = permission_result.human_approval;
                }
            }
            if (external_file_action_identity) |identity| {
                try turn_file_mutation_denials.rememberHumanDenial(
                    arena,
                    identity,
                    permission_result,
                );
            }
            if (permission_result.tool_failure) |failure_output| {
                if (!status_started) {
                    status_started = try runtime_tool_presentation.startToolVisibleLifecycle(
                        deps,
                        call_allocator,
                        turn_id,
                        stream_ctx.provisional_statuses.presentation_group_id,
                        execution_call,
                        tool_display_target,
                        advertised_dynamic_tool_names,
                    );
                }
                const failure: ToolExecutionResult = .{
                    .status = .failure,
                    .model_output = failure_output,
                    .status_detail = "preflight failed",
                };
                const prepared_failure = try runtime_execution_memory.prepareToolModelOutput(
                    arena,
                    config,
                    tool_call,
                    failure_output,
                );
                _ = try stream_ctx.provisional_statuses.finishExecutedCall(
                    deps,
                    stream_ctx.alloc,
                    call_allocator,
                    turn_id,
                    execution_call,
                    status_started,
                    tool_display_target,
                    failure,
                    prepared_failure.model_output,
                    prepared_failure.memory,
                    null,
                    advertised_dynamic_tool_names,
                );
                try runtime_tool_batch.appendToolResultContent(
                    arena,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                    tool_call,
                    prepared_failure.model_output,
                    prepared_failure.memory,
                    .{ .increment_error = true },
                );
                try runtime_tool_admission.recordRejectedToolCall(
                    deps,
                    arena,
                    tool_call,
                    prepared_failure.model_output,
                    null,
                );
                debug_trace.eventf(
                    "tool",
                    "execution_result",
                    step_ctx,
                    "call_id={s} name={s} result_kind=permission_preflight_failure model_output_bytes={d}",
                    .{ tool_call.id, tool_call.name, prepared_failure.model_output.len },
                );
                continue;
            }
            const permission_outcome = permission_result;
            const decision = permission_outcome.decision;
            if (decision.isDenied()) {
                if (successful_vision_route == .text_only) {
                    _ = try appendAuthorizedVisionAttemptIds(
                        arena,
                        &settled_vision_ids,
                        tool_call,
                        job.authorized_image_catalog,
                    );
                }
                const reason = permission_outcome.denial_reason orelse
                    decision.denialReason() orelse .user_denied;
                const approval_request_id = try turn_permission_recovery.rememberAutoDenial(
                    arena,
                    config.workspace_root,
                    tool_call,
                    permission_outcome,
                );
                const denied_output = if (approval_request_id) |request_id| blk: {
                    const request_hex = std.fmt.bytesToHex(request_id, .lower);
                    break :blk try tool_result_errors.toolPermissionDeniedJsonWithRequestId(
                        arena,
                        tool_call.name,
                        reason,
                        &request_hex,
                    );
                } else try tool_result_errors.toolPermissionDeniedJson(
                    arena,
                    tool_call.name,
                    reason,
                );
                if (!status_started and (is_file_mutation or defer_auto_command_lifecycle)) {
                    status_started = try runtime_tool_presentation.startToolVisibleLifecycle(
                        deps,
                        call_allocator,
                        turn_id,
                        stream_ctx.provisional_statuses.presentation_group_id,
                        execution_call,
                        tool_display_target,
                        advertised_dynamic_tool_names,
                    );
                }
                _ = try stream_ctx.provisional_statuses.finishDeniedCall(
                    deps,
                    stream_ctx.alloc,
                    call_allocator,
                    turn_id,
                    execution_call,
                    status_started,
                    tool_display_target,
                    runtime_tool_admission.permissionDeniedStatusLabel(reason),
                    advertised_dynamic_tool_names,
                );
                tool_dispatch.traceDeniedWebSearch(step_ctx, tool_call, reason);
                debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind=permission_denied reason={s} model_output_bytes={d}", .{ tool_call.id, tool_call.name, @tagName(reason), denied_output.len });
                try runtime_tool_batch.appendToolResultContent(
                    arena,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                    tool_call,
                    denied_output,
                    null,
                    .{
                        .increment_total = false,
                        .status = .failure,
                    },
                );
                if (permission_outcome.feedback) |feedback| {
                    try appendPermissionFeedbackAfterToolResult(
                        deps,
                        arena,
                        &step_batch,
                        tool_call.id,
                        &.{feedback},
                    );
                }
                try runtime_tool_admission.recordRejectedToolCall(
                    deps,
                    arena,
                    tool_call,
                    denied_output,
                    null,
                );
                if (deps.tool_activity_recorder) |recorder| {
                    recorder.record(tool_call.id, tool_call.name, .denied) catch |err| {
                        debug_trace.eventf(
                            "subagent",
                            "tool_activity_projection_lag",
                            step_ctx,
                            "call_id={s} tool_name={s} phase=denied outcome={s}",
                            .{ tool_call.id, tool_call.name, @errorName(err) },
                        );
                    };
                }
                continue;
            }

            const execution_authority = permission_outcome.execution_authority orelse {
                debug_trace.eventf(
                    "permission",
                    "missing_execution_authority",
                    step_ctx,
                    "call_id={s} tool_name={s}",
                    .{ tool_call.id, tool_call.name },
                );
                return error.MissingToolExecutionAuthority;
            };
            if (try tooling_tool_admission.callUsesCommandAuthority(
                deps.tool_registry,
                call_allocator,
                tool_call,
            )) {
                if (execution_authority != .run_command) return error.InvalidRunCommandExecutionAuthority;
            } else if (is_file_mutation) {
                if (execution_authority != .file_mutation) {
                    return error.InvalidFileMutationExecutionAuthority;
                }
            } else if (std.mem.eql(u8, tool_call.name, "vision")) {
                switch (execution_authority) {
                    .ordinary, .vision_paths => {},
                    .run_command, .file_mutation => return error.InvalidVisionExecutionAuthority,
                }
            } else if (execution_authority != .ordinary) {
                return error.UnexpectedCommandExecutionAuthority;
            }
            const file_display_path = try runtime_tool_presentation.fileMutationDisplayPath(
                call_allocator,
                execution_authority,
            );
            if (file_display_path) |display_path| {
                tool_display_target = display_path;
            }

            if (!status_started) {
                status_started = try runtime_tool_presentation.startToolVisibleLifecycle(
                    deps,
                    call_allocator,
                    turn_id,
                    stream_ctx.provisional_statuses.presentation_group_id,
                    execution_call,
                    tool_display_target,
                    advertised_dynamic_tool_names,
                );
            }

            if (decision == .always and live_authority == null) {
                if (execution_authority == .file_mutation) {
                    const offer = execution_authority.file_mutation.grant_offer orelse
                        return error.MissingToolExecutionAuthority;
                    try runtime_tool_admission.applyFrozenFileMutationSessionGrants(
                        arena,
                        deps,
                        &local_grants,
                        offer.grants,
                    );
                } else if (execution_authority == .vision_paths) {
                    for (execution_authority.vision_paths.targets) |target| {
                        try runtime_tool_admission.applyInitialSessionGrants(
                            deps,
                            arena,
                            &local_grants,
                            config.workspace_root,
                            tool_call,
                            target.canonical_path,
                        );
                    }
                } else {
                    const target_path = try deps.permission_target_for_call(deps.ctx, arena, tool_call, advertised_dynamic_tool_names);
                    try runtime_tool_admission.applyInitialSessionGrants(deps, arena, &local_grants, config.workspace_root, tool_call, target_path);
                }
            }

            var one_time_execution_grants: std.ArrayList(PermissionGrant) = .empty;
            defer mem_utils.deinitList(arena, &one_time_execution_grants);
            var execution_grants: []const PermissionGrant = if (live_authority) |resolved|
                resolved.authority.grants
            else
                local_grants.items;
            if (decision == .once and execution_authority == .file_mutation) {
                if (execution_authority.file_mutation.grant_offer) |offer| {
                    try one_time_execution_grants.appendSlice(
                        arena,
                        execution_grants,
                    );
                    try runtime_tool_admission.appendFrozenFileMutationGrants(
                        arena,
                        &one_time_execution_grants,
                        offer.grants,
                    );
                    if (one_time_execution_grants.items.len > execution_grants.len) {
                        execution_grants = one_time_execution_grants.items;
                    }
                }
            }

            if (config.cancel_flag.load(.seq_cst)) {
                runtime_telemetry.traceCancelObserved(step_ctx, true);
                _ = try stream_ctx.provisional_statuses.finishDeniedCall(
                    deps,
                    stream_ctx.alloc,
                    call_allocator,
                    turn_id,
                    execution_call,
                    status_started,
                    tool_display_target,
                    "Cancelled",
                    advertised_dynamic_tool_names,
                );
                try finishPendingCancelledCalls(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    arena,
                    config,
                    turn_id,
                    effective_tool_calls[tool_call_index + 1 ..],
                    advertised_dynamic_tool_names,
                );
                try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, tool_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                finish_trace.finish("interrupted");
                return;
            }

            const committed_file_tool_name = if (is_file_mutation)
                try runtime_tool_batch.reserveCommittedFileBookkeeping(arena, &within_turn_suffix, &completed_tool_names, tool_call.name)
            else
                null;

            debug_trace.eventf("tool", "before_tool_execution", step_ctx, "call_id={s} name={s}", .{ tool_call.id, tool_call.name });
            debug_trace.eventf("tool", "execution_start", step_ctx, "call_id={s} name={s}", .{ tool_call.id, tool_call.name });
            if (deps.tool_activity_recorder) |recorder| {
                recorder.record(tool_call.id, tool_call.name, .started) catch |err| {
                    debug_trace.eventf(
                        "subagent",
                        "tool_activity_projection_lag",
                        step_ctx,
                        "call_id={s} tool_name={s} phase=started outcome={s}",
                        .{ tool_call.id, tool_call.name, @errorName(err) },
                    );
                };
            }
            const execution_lifecycle_id = types.ToolLifecycleId{ .turn_id = turn_id, .call_id = execution_call.id };
            const execution_is_command = runtime_tool_presentation.activityKindForCall(arena, deps.tool_registry, tool_call) == .command;
            var execution = (try executeActionBoundPermissionRequest(
                deps,
                arena,
                &turn_permission_recovery,
                execution_call,
                review_context,
                local_grants.items,
                advertised_dynamic_tool_names,
                config.workspace_root,
                step_ctx,
            )) orelse deps.execute_tool_call(deps.ctx, .{
                .call_allocator = call_allocator,
                .result_allocator = arena,
                .call = execution_call,
                .authority = execution_authority,
                .root_user_intent_context = tool_execution_root_user_context,
                .root_user_messages = &.{},
                .root_user_evidence_complete = true,
                .authorized_image_catalog = job.authorized_image_catalog,
                .current_turn_messages = within_turn_suffix.items,
                .session_grants = execution_grants,
                .live_authority = if (live_authority) |resolved| resolved.authority else null,
                .advertised_dynamic_tool_names = advertised_dynamic_tool_names,
                .max_tool_result_bytes = config.max_tool_result_bytes,
                .classification_complete = if (preparation_batch.preparations[tool_call_index]) |preparation|
                    switch (preparation) {
                        .candidate => |candidate| preparedCandidateClassificationComplete(candidate),
                        .terminal => false,
                    }
                else
                    false,
                .lifecycle_id = execution_lifecycle_id,
            }) catch |err| blk: {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (err == error.Cancelled and config.cancel_flag.load(.seq_cst)) {
                    break :blk ToolExecutionResult{
                        .status = .failure,
                        .cancelled = true,
                        .model_output = "command cancelled\n",
                    };
                }
                debug_trace.eventf("tool", "after_tool_execution", step_ctx, "call_id={s} name={s} result_kind=error err={s}", .{ tool_call.id, tool_call.name, @errorName(err) });
                debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind=error err={s}", .{ tool_call.id, tool_call.name, @errorName(err) });
                break :blk ToolExecutionResult{ .status = .failure, .model_output = try deps.format_tool_execution_error(deps.ctx, arena, tool_call.name, err) };
            };

            if (execution.cancelled and config.cancel_flag.load(.seq_cst)) {
                runtime_telemetry.traceCancelObserved(step_ctx, true);
                defer if (execution.command_replay_capture) |capture| capture.discard(arena);
                _ = try stream_ctx.provisional_statuses.finishCancelledCall(
                    deps,
                    stream_ctx.alloc,
                    call_allocator,
                    turn_id,
                    execution_call,
                    status_started,
                    tool_display_target,
                    execution,
                    advertised_dynamic_tool_names,
                );
                try finishPendingCancelledCalls(
                    deps,
                    &stream_ctx.provisional_statuses,
                    stream_ctx.alloc,
                    arena,
                    config,
                    turn_id,
                    effective_tool_calls[tool_call_index + 1 ..],
                    advertised_dynamic_tool_names,
                );
                if (execution_is_command) {
                    try deps.push_command_output_complete(deps.ctx, execution_lifecycle_id);
                }
                try runtime_tool_batch.drainPendingUserSuffix(arena, &step_batch, &within_turn_suffix);
                try runtime_interruption.persistInterruptedTurnOnce(deps, finalization, job, partial_assistant, tool_call, completed_tool_names.items, &interrupted_persisted, step_ctx, within_turn_suffix.items, stop_state.retained_candidate, &stop_state.terminal_materializing);
                finish_trace.finish("interrupted");
                return;
            }

            if (deps.tool_activity_recorder) |recorder| {
                recorder.record(
                    tool_call.id,
                    tool_call.name,
                    if (execution.status == .success) .succeeded else .failed,
                ) catch |err| {
                    debug_trace.eventf(
                        "subagent",
                        "tool_activity_projection_lag",
                        step_ctx,
                        "call_id={s} tool_name={s} phase={s} outcome={s}",
                        .{
                            tool_call.id,
                            tool_call.name,
                            if (execution.status == .success) "succeeded" else "failed",
                            @errorName(err),
                        },
                    );
                };
            }

            if (execution.committed_file_handoff != null) {
                try runtime_tool_batch.processCommittedFileResult(
                    deps,
                    call_allocator,
                    arena,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                    tool_call,
                    execution_call,
                    execution,
                    committed_file_tool_name.?,
                    status_started,
                    file_display_path,
                    is_file_mutation,
                    turn_id,
                    advertised_dynamic_tool_names,
                    step_ctx,
                );
                if (permission_outcome.feedback) |feedback| {
                    try appendPermissionFeedbackAfterToolResult(
                        deps,
                        arena,
                        &step_batch,
                        tool_call.id,
                        &.{feedback},
                    );
                }
                continue;
            }
            if (execution.prepared_result_memory != null or
                execution.deferred_tool_completion != null)
            {
                return error.InvalidPreparedToolExecutionResult;
            }
            if (successful_vision_route == .text_only) {
                _ = try appendAuthorizedVisionAttemptIds(
                    arena,
                    &settled_vision_ids,
                    tool_call,
                    job.authorized_image_catalog,
                );
            }

            runtime_parallel_execution.reportInnerToolUsage(deps, tool_call.name, execution);
            if (execution.diff_entry) |payload| {
                try deps.push_diff_block(deps.ctx, payload);
            } else if (execution.display_output) |display| {
                try deps.push_text(deps.ctx, .{ .operational = display });
            }
            var replay_handed_off = execution.command_replay_capture == null;
            defer if (!replay_handed_off) {
                execution.command_replay_capture.?.discard(arena);
            };
            var prepared = try runtime_execution_memory.prepareToolModelOutput(arena, config, tool_call, execution.model_output);
            runtime_execution_memory.applyToolResultMemory(
                &prepared.memory,
                execution.tool_result_memory,
            );
            runtime_execution_memory.finalizeCommandReplay(
                arena,
                tool_call,
                &prepared,
                config.session_child_capability,
                execution.command_replay_capture,
            );
            const safe_tool_output = prepared.model_output;
            try runtime_tool_presentation.finishExecutedToolStatus(
                deps,
                call_allocator,
                turn_id,
                execution_call,
                status_started,
                tool_display_target,
                execution,
                safe_tool_output,
                prepared.memory,
                execution.diff_entry,
                advertised_dynamic_tool_names,
            );
            if (status_started) replay_handed_off = true;
            if (execution_is_command) {
                try deps.push_command_output_complete(deps.ctx, execution_lifecycle_id);
            }
            for (execution.context_notices) |notice| {
                try deps.pushContextNotice(notice);
            }

            if (execution.finish_turn) {
                try runtime_tool_batch.appendToolResultContent(
                    arena,
                    &within_turn_suffix,
                    &completed_tool_names,
                    &step_batch,
                    tool_call,
                    safe_tool_output,
                    prepared.memory,
                    .{
                        .increment_error = execution.status == .failure or
                            tool_result_errors.isToolOutputError(safe_tool_output),
                        .record_completion = execution.status == .success,
                        .status = runtime_execution_memory.persistedStatusForCurrentFxLocalResult(
                            execution.status,
                            safe_tool_output,
                        ),
                    },
                );
                replay_handed_off = true;
                if (permission_outcome.feedback) |feedback| {
                    try appendPermissionFeedbackAfterToolResult(
                        deps,
                        arena,
                        &step_batch,
                        tool_call.id,
                        &.{feedback},
                    );
                }
                try runtime_tool_batch.drainPendingUserSuffix(
                    arena,
                    &step_batch,
                    &within_turn_suffix,
                );
                var pushed_interactive_notice = false;
                if (execution.interactive_notice) |notice| {
                    if (deps.push_interactive_notice) |push_notice| {
                        try push_notice(deps.ctx, notice);
                        pushed_interactive_notice = true;
                    }
                }
                if (!pushed_interactive_notice) {
                    if (execution.system_notice) |notice| {
                        try deps.push_system_notice(deps.ctx, notice);
                    }
                }
                const assistant_text = if (stop_state.retained_candidate != null)
                    try hooks.prompt.joinVisibleSegments(
                        arena,
                        stop_state.retained_candidate,
                        stop_state.latest_partial,
                    )
                else
                    "";
                stop_state.terminal_materializing = true;
                if (execution.background_command) |background| {
                    try finishCommonBackgroundTerminal(
                        deps,
                        finalization,
                        arena,
                        job,
                        within_turn_suffix.items,
                        &summary_accumulator,
                        assistant_text,
                        background,
                        &finish_trace,
                    );
                    debug_trace.eventf("tool", "after_tool_execution", step_ctx, "call_id={s} name={s} result_kind=background model_output_bytes={d}", .{ tool_call.id, tool_call.name, safe_tool_output.len });
                    debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind=background model_output_bytes={d}", .{ tool_call.id, tool_call.name, safe_tool_output.len });
                } else {
                    try finishCommonAssistantTerminal(
                        deps,
                        finalization,
                        arena,
                        job,
                        within_turn_suffix.items,
                        &summary_accumulator,
                        assistant_text,
                        .completed,
                        null,
                        &finish_trace,
                        "tool",
                    );
                    debug_trace.eventf("tool", "after_tool_execution", step_ctx, "call_id={s} name={s} result_kind=finish_turn model_output_bytes={d}", .{ tool_call.id, tool_call.name, safe_tool_output.len });
                    debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind=finish_turn model_output_bytes={d}", .{ tool_call.id, tool_call.name, safe_tool_output.len });
                }
                return;
            }

            debug_trace.eventf("tool", "after_tool_execution", step_ctx, "call_id={s} name={s} result_kind={s} model_output_bytes={d}", .{ tool_call.id, tool_call.name, runtime_telemetry.toolExecutionResultKind(execution), safe_tool_output.len });
            debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind={s} model_output_bytes={d}", .{ tool_call.id, tool_call.name, runtime_telemetry.toolExecutionResultKind(execution), safe_tool_output.len });
            try runtime_gateway_step.recordSelectedDynamicTool(arena, &selected_dynamic_tool_names, &selected_dynamic_tool_schemas, execution);
            try runtime_tool_batch.appendOrdinaryExecutedResult(
                deps.tool_registry,
                arena,
                &within_turn_suffix,
                &completed_tool_names,
                &step_batch,
                tool_call,
                safe_tool_output,
                prepared.memory,
                execution,
            );
            replay_handed_off = true;
            if (execution.system_notice) |notice| {
                try within_turn_suffix.append(arena, .{ .role = .system, .content = notice });
            }
            if (execution.interactive_notice) |notice| {
                if (deps.push_interactive_notice) |push_notice| {
                    try push_notice(deps.ctx, notice);
                } else {
                    try deps.push_system_notice(deps.ctx, notice.body);
                }
            }
            if (permission_outcome.feedback) |feedback| {
                try appendPermissionFeedbackAfterToolResult(
                    deps,
                    arena,
                    &step_batch,
                    tool_call.id,
                    &.{feedback},
                );
            }
        }

        try runtime_tool_batch.drainPendingUserSuffix(
            arena,
            &step_batch,
            &within_turn_suffix,
        );
        if (successful_vision_route == .text_only and settled_vision_ids.items.len > 0) {
            const transition = try runtime_vision_contracts.transition_pending_images(
                arena,
                .text_only,
                pending_image_ids,
                .{ .valid = settled_vision_ids.items },
            );
            pending_image_ids = transition.pending_ids;
        }
        try runtime_tool_batch.appendReviewContinuationSuffix(
            config.review_enabled,
            arena,
            &within_turn_suffix,
            &step_batch,
        );
        if (malformed_arguments_retry.finishBatch()) {
            debug_trace.eventf(
                "agent",
                "repeated_malformed_tool_arguments",
                step_ctx,
                "tool_call_count={d}",
                .{effective_tool_calls.len},
            );
            try finishFailedTurnWithNotice(
                deps,
                finalization,
                arena,
                job,
                within_turn_suffix.items,
                &summary_accumulator,
                stop_state,
                &finish_trace,
                repeated_malformed_arguments_notice,
                "repeated_malformed_tool_arguments",
            );
            return;
        }
        if (terminal_validation_retry.finishBatch()) {
            try deps.push_system_notice(
                deps.ctx,
                repeated_terminal_validation_notice,
            );
            const assistant_text = if (stop_state.retained_candidate != null)
                try hooks.prompt.joinVisibleSegments(
                    arena,
                    stop_state.retained_candidate,
                    stop_state.latest_partial,
                )
            else
                "";
            stop_state.terminal_materializing = true;
            try finishCommonAssistantTerminal(
                deps,
                finalization,
                arena,
                job,
                within_turn_suffix.items,
                &summary_accumulator,
                assistant_text,
                .completed,
                null,
                &finish_trace,
                "terminal_validation_retry",
            );
            return;
        }
        if (terminal_provider_completion) {
            const raw_final = completion.content.?;
            const final_text = try runtime_assistant_stream.normalizeAssistantTextForDisplay(arena, raw_final);
            const rendered = if (final_text.len > 0) final_text else "Done.";

            if (!lifecycle.view.hasStop() or stop_state.dispatched) {
                try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });

                const history_text = runtime_assistant_stream.historyTextForCompletedStream(
                    stream_ctx.raw_text.items,
                    rendered,
                );
                const persisted_text = try hooks.prompt.joinVisibleSegments(
                    arena,
                    stop_state.retained_candidate,
                    history_text,
                );
                stop_state.terminal_materializing =
                    stop_state.retained_candidate != null;
                try finishCommonAssistantTerminal(
                    deps,
                    finalization,
                    arena,
                    job,
                    within_turn_suffix.items,
                    &summary_accumulator,
                    persisted_text,
                    .completed,
                    null,
                    &finish_trace,
                    "assistant",
                );
                return;
            }

            stop_state.retained_candidate = rendered;
            stop_state.latest_partial = null;
            try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });

            var stop_outcome = runtime_lifecycle.dispatchStopCheckpoint(
                lifecycle,
                config.cancel_flag,
                .{
                    .turn_id = turn_id,
                    .step_index = current_step_index,
                    .assistant_text = rendered,
                    .provider_disposition = disposition,
                    .can_continue = agent_steps.allowsStep(config.agent_step_limit, step + 1),
                },
            ) catch |err| switch (err) {
                error.Cancelled => {
                    runtime_telemetry.traceCancelObserved(step_ctx, false);
                    try runtime_interruption.persistInterruptedTurnOnce(
                        deps,
                        finalization,
                        job,
                        null,
                        null,
                        completed_tool_names.items,
                        &interrupted_persisted,
                        step_ctx,
                        within_turn_suffix.items,
                        stop_state.retained_candidate,
                        &stop_state.terminal_materializing,
                    );
                    finish_trace.finish("interrupted");
                    return;
                },
            };
            defer stop_outcome.deinit(lifecycle.outcome_allocator);

            stop_state.dispatched = true;
            switch (stop_outcome) {
                .allow => {
                    stop_state.terminal_materializing = true;
                    try finishCommonAssistantTerminal(
                        deps,
                        finalization,
                        arena,
                        job,
                        within_turn_suffix.items,
                        &summary_accumulator,
                        rendered,
                        .completed,
                        null,
                        &finish_trace,
                        "assistant",
                    );
                    return;
                },
                .continue_once => |context| {
                    try within_turn_suffix.append(arena, .{
                        .role = .assistant,
                        .content = rendered,
                    });
                    const synthetic = try hooks.prompt.buildContinuationMessage(
                        arena,
                        context,
                    );
                    try within_turn_suffix.append(arena, .{
                        .role = .user,
                        .content = synthetic,
                    });
                    continue;
                },
            }
        }
    }

    if (automatic_recovery_disposition(within_turn_suffix.items) == .finish_with_normal_blocker) {
        if (config.cancel_flag.load(.seq_cst)) {
            runtime_telemetry.traceCancelObserved(last_step_ctx, false);
            try runtime_interruption.persistInterruptedTurnOnce(
                deps,
                finalization,
                job,
                null,
                null,
                completed_tool_names.items,
                &interrupted_persisted,
                last_step_ctx,
                within_turn_suffix.items,
                stop_state.retained_candidate,
                &stop_state.terminal_materializing,
            );
            finish_trace.finish("interrupted");
            return;
        }
        try finish_automatic_permission_recovery(
            deps,
            finalization,
            arena,
            job,
            within_turn_suffix.items,
            &summary_accumulator,
            stop_state,
            &finish_trace,
            last_step_ctx,
        );
        return;
    }

    runtime_telemetry.traceStepLimitReached(.{
        .ctx = last_step_ctx,
        .step_index = current_step_index,
        .step_limit = config.agent_step_limit,
        .gateway_message_count = last_gateway_message_count,
        .completed_tool_names = completed_tool_names.items,
        .last_tool_call_name = last_tool_call_name,
        .last_tool_call_id = last_tool_call_id,
    });
    try finishFailedTurnWithNotice(
        deps,
        finalization,
        arena,
        job,
        within_turn_suffix.items,
        &summary_accumulator,
        stop_state,
        &finish_trace,
        config.step_limit_notice,
        "step_limit",
    );
}

fn finish_automatic_permission_recovery(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    summary_accumulator: *runtime_telemetry.TurnSummaryAccumulator,
    stop_state: *CommonStopState,
    finish_trace: *PromptFinishTrace,
    trace_ctx: TraceContext,
) !void {
    debug_trace.eventf(
        "permission",
        "automatic_recovery_exhausted",
        trace_ctx,
        "blocked_response_groups={d}",
        .{max_automatic_denial_response_groups},
    );
    try deps.push_text(
        deps.ctx,
        .{ .assistant_source = automatic_permission_recovery_fallback },
    );
    try deps.push_text(
        deps.ctx,
        .{ .assistant_rendered = automatic_permission_recovery_fallback },
    );
    try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });

    const assistant_text = try hooks.prompt.joinVisibleSegments(
        arena,
        stop_state.retained_candidate,
        automatic_permission_recovery_fallback,
    );
    stop_state.terminal_materializing = stop_state.retained_candidate != null;
    try finishCommonAssistantTerminal(
        deps,
        finalization,
        arena,
        job,
        current_turn_messages,
        summary_accumulator,
        assistant_text,
        .completed,
        null,
        finish_trace,
        "automatic_permission_recovery",
    );
}

fn finishFailedTurnWithNotice(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    summary_accumulator: *runtime_telemetry.TurnSummaryAccumulator,
    stop_state: *CommonStopState,
    finish_trace: *PromptFinishTrace,
    notice: []const u8,
    trace_outcome: []const u8,
) !void {
    try deps.push_text(deps.ctx, .{ .operational = notice });
    try deps.push_text(deps.ctx, .{ .operational = "\n" });
    if (stop_state.retained_candidate != null) {
        const assistant_text = try hooks.prompt.joinVisibleSegments(
            arena,
            stop_state.retained_candidate,
            notice,
        );
        stop_state.terminal_materializing = true;
        try finishCommonAssistantTerminal(
            deps,
            finalization,
            arena,
            job,
            current_turn_messages,
            summary_accumulator,
            assistant_text,
            .failed,
            null,
            finish_trace,
            trace_outcome,
        );
        return;
    }
    const execution_memory = try runtime_execution_memory.buildExecutionMemory(
        arena,
        current_turn_messages,
    );
    const turn: HistoryTurn = .{ .assistant = .{
        .user = .{ .text = job.prompt, .images = job.images },
        .assistant = @constCast(notice),
        .execution = execution_memory,
    } };
    try deps.propagate_history_turn(deps.ctx, turn);
    try finalization.finish(.failed, null, .{
        .turn = try types.dupeHistoryTurn(std.heap.c_allocator, turn),
        .summary = summary_accumulator.finish(),
    });
    finish_trace.finish(trace_outcome);
}

pub fn finishCommonAssistantTerminal(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    summary_accumulator: *runtime_telemetry.TurnSummaryAccumulator,
    assistant_text: []const u8,
    outcome: types.TurnPresentationOutcome,
    disposition: ?types.ProviderCompletionDisposition,
    finish_trace: *PromptFinishTrace,
    trace_outcome: []const u8,
) !void {
    const execution_memory = try runtime_execution_memory.buildExecutionMemory(
        arena,
        current_turn_messages,
    );
    try finishCommonAssistantTerminalWithExecution(
        deps,
        finalization,
        job,
        execution_memory,
        summary_accumulator,
        assistant_text,
        outcome,
        disposition,
        finish_trace,
        trace_outcome,
    );
}

fn finishCommonAssistantTerminalWithExecution(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    execution_memory: types.ExecutionMemory,
    summary_accumulator: *runtime_telemetry.TurnSummaryAccumulator,
    assistant_text: []const u8,
    outcome: types.TurnPresentationOutcome,
    disposition: ?types.ProviderCompletionDisposition,
    finish_trace: *PromptFinishTrace,
    trace_outcome: []const u8,
) !void {
    try runtime_finalization.finishAssistantTerminalWithExecution(
        deps,
        finalization,
        job,
        execution_memory,
        summary_accumulator,
        assistant_text,
        outcome,
        disposition,
        finish_trace,
        trace_outcome,
    );
}

fn finishCommonBackgroundTerminal(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    summary_accumulator: *runtime_telemetry.TurnSummaryAccumulator,
    assistant_text: []const u8,
    background: command_contract.BackgroundCommand,
    finish_trace: *PromptFinishTrace,
) !void {
    const execution_memory = try runtime_execution_memory.buildExecutionMemory(
        arena,
        current_turn_messages,
    );
    const turn: HistoryTurn = .{ .background_command = .{
        .user = .{ .text = job.prompt, .images = job.images },
        .assistant = @constCast(assistant_text),
        .execution = execution_memory,
        .log_path = @constCast(background.log_path),
        .expect_url = background.expect_url,
        .url = if (background.url) |url| @constCast(url) else null,
        .background_record_id = background.background_record_id,
    } };
    const finished = try types.dupeFinishedPrompt(
        std.heap.c_allocator,
        .{
            .turn = turn,
            .summary = summary_accumulator.finish(),
        },
    );

    var propagation_error: ?anyerror = null;
    deps.propagate_history_turn(deps.ctx, turn) catch |err| {
        propagation_error = err;
    };
    try finalization.finish(.completed, null, finished);
    finish_trace.finish("background");
    if (propagation_error) |err| return err;
}

pub fn copyLatestStopPartial(
    alloc: Allocator,
    stop_state: *CommonStopState,
    partial: []const u8,
) Allocator.Error!void {
    stop_state.latest_partial = if (partial.len == 0)
        null
    else
        try alloc.dupe(u8, partial);
}

test "malformed duplicate unauthorized and path Vision calls settle no image ids" {
    const catalog = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/authorized.png"),
        .media_type = @constCast("image/png"),
    }};
    var settled_ids: std.ArrayList(usize) = .empty;
    defer settled_ids.deinit(std.testing.allocator);

    const malformed = ToolCall{
        .id = "vision-malformed",
        .name = "vision",
        .arguments_json = "{\"image_ids\":[1]",
        .argument_integrity = .malformed_json,
        .provenance = .fx_local,
    };
    try std.testing.expect(!try appendAuthorizedVisionAttemptIds(
        std.testing.allocator,
        &settled_ids,
        malformed,
        &catalog,
    ));

    const duplicate = ToolCall{
        .id = "vision-duplicate",
        .name = "vision",
        .arguments_json = "{\"image_ids\":[1,1],\"focus\":\"inspect\"}",
        .provenance = .fx_local,
    };
    try std.testing.expect(!try appendAuthorizedVisionAttemptIds(
        std.testing.allocator,
        &settled_ids,
        duplicate,
        &catalog,
    ));

    const unauthorized = ToolCall{
        .id = "vision-unauthorized",
        .name = "vision",
        .arguments_json = "{\"image_ids\":[2],\"focus\":\"inspect\"}",
        .provenance = .fx_local,
    };
    try std.testing.expect(!try appendAuthorizedVisionAttemptIds(
        std.testing.allocator,
        &settled_ids,
        unauthorized,
        &catalog,
    ));

    const path_source = ToolCall{
        .id = "vision-path",
        .name = "vision",
        .arguments_json = "{\"paths\":[\"photo.png\"],\"focus\":\"inspect\"}",
        .provenance = .fx_local,
    };
    try std.testing.expect(!try appendAuthorizedVisionAttemptIds(
        std.testing.allocator,
        &settled_ids,
        path_source,
        &catalog,
    ));
    try std.testing.expectEqual(@as(usize, 0), settled_ids.items.len);
}
