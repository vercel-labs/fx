const std = @import("std");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const diff = @import("../../output/diff.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");

const runtime_config = @import("config.zig");
const runtime_execution_memory = @import("execution_memory.zig");
const runtime_deps = @import("deps.zig");
const runtime_interruption = @import("interruption.zig");
const runtime_parallel_execution = @import("parallel_execution.zig");
const runtime_telemetry = @import("telemetry.zig");
const runtime_tool_admission = @import("tool_admission.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");
const runtime_tool_presentation = @import("tool_presentation.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const TraceContext = debug_trace.TraceContext;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

pub const StepBatchState = struct {
    step_error_count: usize = 0,
    step_total_count: usize = 0,
    step_had_writes: bool = false,
    pending_user_suffix: std.ArrayList(ChatMessage) = .empty,

    pub fn allToolResultsFailed(self: StepBatchState) bool {
        return self.step_total_count > 0 and self.step_error_count == self.step_total_count;
    }
};

pub const ToolResultAccounting = struct {
    increment_total: bool = true,
    increment_error: bool = false,
    record_completion: bool = false,
    mark_write: bool = false,
    status: ?types.PersistedToolStatus = null,
};

pub fn appendAssistantToolCallStep(
    arena: Allocator,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    content: ?[]const u8,
    tool_calls: []const ToolCall,
    provider_replay: ?types.ProviderReplay,
) !void {
    try within_turn_suffix.append(arena, .{
        .role = .assistant,
        .content = content,
        .tool_calls = tool_calls,
        .provider_replay = provider_replay,
    });
}

pub fn appendToolResultContent(
    arena: Allocator,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
    batch: *StepBatchState,
    tool_call: ToolCall,
    model_output: []const u8,
    memory: ?types.ToolResultMemory,
    accounting: ToolResultAccounting,
) !void {
    if (accounting.increment_total) batch.step_total_count += 1;
    if (accounting.increment_error) batch.step_error_count += 1;
    if (accounting.mark_write) batch.step_had_writes = true;
    try within_turn_suffix.append(arena, .{
        .role = .tool,
        .content = model_output,
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .tool_result_status = accounting.status orelse
            if (accounting.increment_error) .failure else .success,
        .tool_result_memory = memory,
    });
    if (accounting.record_completion) {
        try runtime_interruption.recordCompletedToolName(arena, completed_tool_names, tool_call.name);
    }
}

pub fn appendPermissionFeedback(
    arena: Allocator,
    batch: *StepBatchState,
    source_tool_call_id: []const u8,
    feedback: []const []const u8,
) !void {
    for (feedback) |text| {
        if (text.len == 0) continue;
        const owned = try arena.dupe(u8, text);
        try batch.pending_user_suffix.append(arena, .{
            .role = .user,
            .content = owned,
            .tool_call_id = source_tool_call_id,
            .permission_feedback = true,
        });
    }
}

pub fn drainPendingUserSuffix(
    arena: Allocator,
    batch: *StepBatchState,
    within_turn_suffix: *std.ArrayList(ChatMessage),
) !void {
    try within_turn_suffix.appendSlice(arena, batch.pending_user_suffix.items);
    batch.pending_user_suffix.clearRetainingCapacity();
}

pub fn reserveCommittedFileBookkeeping(
    arena: Allocator,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
    tool_name: []const u8,
) ![]u8 {
    try within_turn_suffix.ensureUnusedCapacity(arena, 1);
    try completed_tool_names.ensureUnusedCapacity(arena, 1);
    return try arena.dupe(u8, tool_name);
}

pub fn assembleParallelToolResults(
    arena: Allocator,
    hooks: *const AgentRuntimeDeps,
    config: runtime_config.Config,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
    batch: *StepBatchState,
    provisional_statuses: *runtime_tool_presentation.ProvisionalToolStatuses,
    provisional_alloc: Allocator,
    parallel_calls: []const ToolCall,
    precomputed_results: []const ?ToolExecutionResult,
    parallel_attempts: []const runtime_parallel_execution.ParallelToolAttempt,
    parallel_status_started: []const bool,
    parallel_status_terminalized: []const bool,
    turn_id: u64,
    advertised_dynamic_tool_names: []const []const u8,
    step_ctx: TraceContext,
) !?ToolCall {
    var parallel_result_index: usize = 0;
    var cancelled_call: ?ToolCall = null;
    for (parallel_calls, precomputed_results, 0..) |original_call, precomputed, original_index| {
        const execution = precomputed orelse blk: {
            const attempt = parallel_attempts[parallel_result_index];
            parallel_result_index += 1;
            switch (attempt) {
                .completed => |result| break :blk result.execution,
                .cancelled => {
                    if (cancelled_call == null) cancelled_call = original_call;
                    _ = try provisional_statuses.finishDeniedCall(
                        hooks,
                        provisional_alloc,
                        arena,
                        turn_id,
                        original_call,
                        parallel_status_started[original_index],
                        null,
                        "Cancelled",
                        advertised_dynamic_tool_names,
                    );
                    continue;
                },
            }
        };
        var prepared = try runtime_execution_memory.prepareToolExecutionOutput(arena, config, original_call, execution, null);
        runtime_execution_memory.applyToolResultMemory(
            &prepared.memory,
            execution.tool_result_memory,
        );
        try runtime_execution_memory.retainToolImages(arena, config, original_call, &prepared);
        const safe_tool_output = prepared.model_output;
        if (precomputed == null) {
            runtime_parallel_execution.reportInnerToolUsage(hooks, original_call.name, execution);
            _ = try provisional_statuses.finishExecutedCall(
                hooks,
                provisional_alloc,
                arena,
                turn_id,
                original_call,
                parallel_status_started[original_index],
                null,
                execution,
                safe_tool_output,
                prepared.memory,
                null,
                advertised_dynamic_tool_names,
            );
            debug_trace.eventf("tool", "after_tool_execution", step_ctx, "call_id={s} name={s} result_kind={s} model_output_bytes={d}", .{ original_call.id, original_call.name, runtime_telemetry.toolExecutionResultKind(execution), safe_tool_output.len });
            if (hooks.tool_activity_recorder) |recorder| {
                const phase: runtime_deps.ToolActivityPhase = if (execution.status == .success)
                    .succeeded
                else
                    .failed;
                recorder.record(original_call.id, original_call.name, phase) catch |err| {
                    debug_trace.eventf(
                        "subagent",
                        "tool_activity_projection_lag",
                        step_ctx,
                        "call_id={s} tool_name={s} phase={s} outcome={s}",
                        .{
                            original_call.id,
                            original_call.name,
                            @tagName(phase),
                            @errorName(err),
                        },
                    );
                };
            }
        } else if (original_call.argument_integrity != .valid) {
            try provisional_statuses.finishMalformedToolArguments(
                hooks,
                arena,
                turn_id,
                original_call,
            );
            debug_trace.eventf(
                "tool",
                "argument_integrity_rejected",
                step_ctx,
                "call_id={s} name={s} failure={s} provenance=fx_local",
                .{ original_call.id, original_call.name, @tagName(original_call.argument_integrity) },
            );
            try runtime_tool_admission.recordRejectedToolCall(
                hooks,
                arena,
                original_call,
                safe_tool_output,
                null,
            );
        } else if (!parallel_status_terminalized[original_index]) {
            _ = try provisional_statuses.finishExecutedCall(
                hooks,
                provisional_alloc,
                arena,
                turn_id,
                original_call,
                parallel_status_started[original_index],
                null,
                execution,
                safe_tool_output,
                prepared.memory,
                null,
                advertised_dynamic_tool_names,
            );
        }
        for (execution.context_notices) |notice| {
            try hooks.pushContextNotice(notice);
        }
        debug_trace.eventf("tool", "execution_result", step_ctx, "call_id={s} name={s} result_kind={s} model_output_bytes={d}", .{ original_call.id, original_call.name, runtime_telemetry.toolExecutionResultKind(execution), safe_tool_output.len });
        try appendToolResultContent(
            arena,
            within_turn_suffix,
            completed_tool_names,
            batch,
            original_call,
            safe_tool_output,
            prepared.memory,
            .{
                .increment_error = execution.status == .failure or tool_result_errors.isToolOutputError(safe_tool_output),
                .record_completion = execution.status == .success,
                .status = runtime_execution_memory.persistedStatusForCurrentFxLocalResult(
                    execution.status,
                    safe_tool_output,
                ),
            },
        );
    }
    return cancelled_call;
}

pub fn processCommittedFileResult(
    hooks: *const AgentRuntimeDeps,
    presentation_allocator: Allocator,
    history_allocator: Allocator,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
    batch: *StepBatchState,
    tool_call: ToolCall,
    execution_call: ToolCall,
    execution: ToolExecutionResult,
    model_output: []const u8,
    result_memory: types.ToolResultMemory,
    committed_file_tool_name: []u8,
    status_started: bool,
    display_target: ?[]const u8,
    is_file_mutation: bool,
    turn_id: u64,
    advertised_dynamic_tool_names: []const []const u8,
    step_ctx: TraceContext,
) !void {
    if (!is_file_mutation) {
        return error.InvalidCommittedFileExecutionResult;
    }
    const handoff = execution.committed_file_handoff orelse unreachable;
    if (hooks.usage) |usage| {
        usage.recordCommittedLines(
            handoff.preview.additions,
            handoff.preview.deletions,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "usage code accounting failed additions={d} deletions={d} reason={s}",
                .{
                    handoff.preview.additions,
                    handoff.preview.deletions,
                    @errorName(err),
                },
            );
            usage.markCodeIncomplete();
        };
        if (!usage.persistCheckpoint()) usage.markCodeIncomplete();
    }
    const committed_contract_degraded =
        execution.status != .success or
        !execution.tool_result_memory_prepared or
        execution.tool_result_memory == null or
        execution.diff_entry != null or
        execution.finish_turn;
    if (committed_contract_degraded) {
        debug_trace.eventf(
            "tool",
            "committed_result_contract_degraded",
            step_ctx,
            "call_id={s} name={s} status={s} memory={s} diff={s} finish_turn={s}",
            .{
                tool_call.id,
                tool_call.name,
                @tagName(execution.status),
                if (execution.tool_result_memory_prepared and
                    execution.tool_result_memory != null) "true" else "false",
                if (execution.diff_entry != null) "true" else "false",
                if (execution.finish_turn) "true" else "false",
            },
        );
        if (execution.diff_entry) |payload| {
            diff.freeDiffEntryPayload(std.heap.c_allocator, payload);
        }
    }

    var prepared_memory = result_memory;
    prepared_memory.committed_file_presentation = runtime_execution_memory.captureCommittedFilePresentation(
        history_allocator,
        handoff,
    ) catch |err| blk: {
        debug_trace.logf(
            "session",
            "committed file resume presentation unavailable call_id={s} err={s}",
            .{ tool_call.id, @errorName(err) },
        );
        break :blk null;
    };
    within_turn_suffix.appendAssumeCapacity(.{
        .role = .tool,
        .content = model_output,
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .tool_result_status = runtime_execution_memory.persistedStatusForCurrentFxLocalResult(
            execution.status,
            model_output,
        ),
        .tool_result_memory = prepared_memory,
    });
    debug_trace.eventf(
        "tool",
        "committed_result_appended",
        step_ctx,
        "call_id={s} name={s} model_output_bytes={d}",
        .{ tool_call.id, tool_call.name, model_output.len },
    );

    const publication = hooks.publish_committed_file_handoff(
        hooks.ctx,
        handoff,
    );
    debug_trace.eventf(
        "tool",
        "committed_secondary_publication",
        step_ctx,
        "call_id={s} name={s} diff={s} tracker={s}",
        .{
            tool_call.id,
            tool_call.name,
            @tagName(publication.diff),
            @tagName(publication.tracker),
        },
    );
    var reporting_degraded =
        publication.degraded() or committed_contract_degraded;
    runtime_tool_presentation.finishCommittedFileStatus(
        hooks,
        presentation_allocator,
        turn_id,
        execution_call,
        status_started,
        display_target,
        handoff.preview,
        advertised_dynamic_tool_names,
    ) catch |err| {
        reporting_degraded = true;
        debug_trace.eventf(
            "tool",
            "committed_status_publication_failed",
            step_ctx,
            "call_id={s} name={s} err={s}",
            .{ tool_call.id, tool_call.name, @errorName(err) },
        );
    };
    if (execution.deferred_tool_completion) |deferred_completion| {
        if (hooks.publish_deferred_tool_completion) |publish_deferred| {
            const outcome = publish_deferred(
                hooks.ctx,
                deferred_completion,
            );
            if (outcome == .failed) reporting_degraded = true;
            debug_trace.eventf(
                "tool",
                "deferred_tool_completion_publication",
                step_ctx,
                "call_id={s} name={s} outcome={s}",
                .{ tool_call.id, tool_call.name, @tagName(outcome) },
            );
        } else {
            reporting_degraded = true;
            debug_trace.eventf(
                "tool",
                "deferred_tool_completion_publication",
                step_ctx,
                "call_id={s} name={s} outcome=missing_publisher",
                .{ tool_call.id, tool_call.name },
            );
        }
    }
    if (reporting_degraded) {
        hooks.push_system_notice(
            hooks.ctx,
            "File change committed, but some secondary reporting failed.",
        ) catch |err| {
            debug_trace.eventf(
                "tool",
                "committed_reporting_warning_failed",
                step_ctx,
                "call_id={s} name={s} err={s}",
                .{ tool_call.id, tool_call.name, @errorName(err) },
            );
        };
    }

    debug_trace.eventf(
        "tool",
        "after_tool_execution",
        step_ctx,
        "call_id={s} name={s} result_kind=committed_file model_output_bytes={d}",
        .{ tool_call.id, tool_call.name, model_output.len },
    );
    debug_trace.eventf(
        "tool",
        "execution_result",
        step_ctx,
        "call_id={s} name={s} result_kind=committed_file model_output_bytes={d}",
        .{ tool_call.id, tool_call.name, model_output.len },
    );
    batch.step_total_count += 1;
    batch.step_had_writes = true;
    completed_tool_names.appendAssumeCapacity(committed_file_tool_name);
}

pub fn appendOrdinaryExecutedResult(
    tool_registry: tool_dispatch.Registry,
    arena: Allocator,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    completed_tool_names: *std.ArrayList([]u8),
    batch: *StepBatchState,
    tool_call: ToolCall,
    model_output: []const u8,
    memory: types.ToolResultMemory,
    execution: ToolExecutionResult,
) !void {
    const activity = runtime_tool_presentation.activityKindForCall(arena, tool_registry, tool_call);
    try appendToolResultContent(
        arena,
        within_turn_suffix,
        completed_tool_names,
        batch,
        tool_call,
        model_output,
        memory,
        .{
            .increment_error = execution.status == .failure or tool_result_errors.isToolOutputError(model_output),
            .record_completion = true,
            .mark_write = activity == .write or activity == .edit,
            .status = runtime_execution_memory.persistedStatusForCurrentFxLocalResult(
                execution.status,
                model_output,
            ),
        },
    );
}

pub fn appendReviewContinuationSuffix(
    review_enabled: bool,
    arena: Allocator,
    within_turn_suffix: *std.ArrayList(ChatMessage),
    batch: *const StepBatchState,
) !void {
    if (review_enabled and batch.step_had_writes) {
        const review_prompt = "Review the changes you just made. Re-read any modified files and briefly note any issues (syntax errors, missing imports, logic bugs). If everything looks correct, say so.";
        try within_turn_suffix.append(arena, .{ .role = .user, .content = review_prompt });
    }
}

test "appendPermissionFeedback marks typed approval feedback" {
    const alloc = std.testing.allocator;
    var batch = StepBatchState{};
    defer {
        for (batch.pending_user_suffix.items) |message| {
            if (message.content) |text| alloc.free(@constCast(text));
        }
        batch.pending_user_suffix.deinit(alloc);
    }
    try appendPermissionFeedback(
        alloc,
        &batch,
        "call_permission",
        &.{ "", "read it after writing" },
    );

    try std.testing.expectEqual(@as(usize, 1), batch.pending_user_suffix.items.len);
    try std.testing.expect(batch.pending_user_suffix.items[0].permission_feedback);
    try std.testing.expectEqualStrings(
        "call_permission",
        batch.pending_user_suffix.items[0].tool_call_id.?,
    );
}

test "drained batch feedback follows all tool results and keeps its source call" {
    const alloc = std.testing.allocator;
    var batch = StepBatchState{};
    var suffix: std.ArrayList(ChatMessage) = .empty;
    defer {
        for (suffix.items) |message| {
            if (message.role == .user) {
                if (message.content) |text| alloc.free(@constCast(text));
            }
        }
        suffix.deinit(alloc);
        batch.pending_user_suffix.deinit(alloc);
    }
    var completed_tool_names: std.ArrayList([]u8) = .empty;
    defer completed_tool_names.deinit(alloc);
    const calls = [_]ToolCall{
        .{ .id = "call_first", .name = "run_command", .arguments_json = "{}" },
        .{ .id = "call_second", .name = "run_command", .arguments_json = "{}" },
    };

    try appendAssistantToolCallStep(alloc, &suffix, null, &calls, null);
    try appendToolResultContent(
        alloc,
        &suffix,
        &completed_tool_names,
        &batch,
        calls[0],
        "first command completed",
        null,
        .{},
    );
    try appendPermissionFeedback(
        alloc,
        &batch,
        calls[0].id,
        &.{"first command feedback marker"},
    );
    try appendToolResultContent(
        alloc,
        &suffix,
        &completed_tool_names,
        &batch,
        calls[1],
        "second command completed",
        null,
        .{},
    );
    try drainPendingUserSuffix(alloc, &batch, &suffix);

    try std.testing.expectEqual(@as(usize, 4), suffix.items.len);
    try std.testing.expectEqual(.assistant, suffix.items[0].role);
    try std.testing.expectEqual(.tool, suffix.items[1].role);
    try std.testing.expectEqual(.tool, suffix.items[2].role);
    try std.testing.expectEqual(.user, suffix.items[3].role);
    try std.testing.expectEqualStrings("call_first", suffix.items[3].tool_call_id.?);
    try std.testing.expect(suffix.items[3].permission_feedback);
}
