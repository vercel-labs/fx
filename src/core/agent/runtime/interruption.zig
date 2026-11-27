const std = @import("std");
const lifecycle_hooks = @import("../../hooks/hooks.zig");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const execution_memory_helpers = @import("../execution_memory.zig");

const runtime_execution_memory = @import("execution_memory.zig");
const runtime_finalization = @import("finalization.zig");
const runtime_deps = @import("deps.zig");
const runtime_telemetry = @import("telemetry.zig");
const worker_runtime = @import("../worker_runtime.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;
const ToolCall = types.ToolCall;
const TraceContext = debug_trace.TraceContext;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const TurnFinalizationGuard = runtime_finalization.TurnFinalizationGuard;
const QueuedPrompt = worker_runtime.QueuedPrompt;

pub fn persistInterruptedTurnOnce(
    hooks: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    partial_assistant: ?[]const u8,
    active_tool_call: ?ToolCall,
    completed_tool_names: [][]u8,
    persisted: *bool,
    trace_ctx: TraceContext,
    current_turn_messages: []const types.ChatMessage,
    retained_candidate: ?[]const u8,
    terminal_materializing: *bool,
) !void {
    return persistInterruptedTurnWithPresentation(
        hooks,
        finalization,
        job,
        partial_assistant,
        active_tool_call,
        completed_tool_names,
        persisted,
        trace_ctx,
        current_turn_messages,
        retained_candidate,
        terminal_materializing,
        null,
        null,
        .turn,
    );
}

pub fn persistCompactionInterruptedTurnOnce(
    hooks: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    completed_tool_names: [][]u8,
    persisted: *bool,
    trace_ctx: TraceContext,
    current_turn_messages: []const types.ChatMessage,
    retained_candidate: ?[]const u8,
    terminal_materializing: *bool,
) !void {
    return persistInterruptedTurnWithPresentation(
        hooks,
        finalization,
        job,
        null,
        null,
        completed_tool_names,
        persisted,
        trace_ctx,
        current_turn_messages,
        retained_candidate,
        terminal_materializing,
        null,
        null,
        .compaction,
    );
}

pub fn persistInterruptedCommandTurnOnce(
    hooks: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    partial_assistant: ?[]const u8,
    active_tool_call: ToolCall,
    completed_tool_names: [][]u8,
    persisted: *bool,
    trace_ctx: TraceContext,
    current_turn_messages: []const types.ChatMessage,
    retained_candidate: ?[]const u8,
    terminal_materializing: *bool,
    cancelled_command: ?types.CancelledCommandPresentation,
) !void {
    return persistInterruptedTurnWithPresentation(
        hooks,
        finalization,
        job,
        partial_assistant,
        active_tool_call,
        completed_tool_names,
        persisted,
        trace_ctx,
        current_turn_messages,
        retained_candidate,
        terminal_materializing,
        cancelled_command,
        null,
        .turn,
    );
}

/// Persists a turn cancelled while its `subagent` wait `active_tool_call`
/// waited, with the subagents its row named, so a resume shows the row
/// (D102).
pub fn persistInterruptedWaitTurnOnce(
    hooks: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    partial_assistant: ?[]const u8,
    active_tool_call: ToolCall,
    completed_tool_names: [][]u8,
    persisted: *bool,
    trace_ctx: TraceContext,
    current_turn_messages: []const types.ChatMessage,
    retained_candidate: ?[]const u8,
    terminal_materializing: *bool,
    cancelled_wait: types.CancelledWaitPresentation,
) !void {
    return persistInterruptedTurnWithPresentation(
        hooks,
        finalization,
        job,
        partial_assistant,
        active_tool_call,
        completed_tool_names,
        persisted,
        trace_ctx,
        current_turn_messages,
        retained_candidate,
        terminal_materializing,
        null,
        cancelled_wait,
        .turn,
    );
}

fn persistInterruptedTurnWithPresentation(
    hooks: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    partial_assistant: ?[]const u8,
    active_tool_call: ?ToolCall,
    completed_tool_names: [][]u8,
    persisted: *bool,
    trace_ctx: TraceContext,
    current_turn_messages: []const types.ChatMessage,
    retained_candidate: ?[]const u8,
    terminal_materializing: *bool,
    cancelled_command: ?types.CancelledCommandPresentation,
    cancelled_wait: ?types.CancelledWaitPresentation,
    cancellation_origin: types.CancellationOrigin,
) !void {
    if (persisted.*) return;

    const durable_active_tool_call = if (active_tool_call) |call|
        try execution_memory_helpers.dupePersistedToolCall(
            std.heap.c_allocator,
            call,
        )
    else
        null;
    defer if (durable_active_tool_call) |call| {
        types.freeToolCall(std.heap.c_allocator, call);
    };
    const full_execution = try runtime_execution_memory.buildInterruptedExecutionMemory(
        std.heap.c_allocator,
        current_turn_messages,
        active_tool_call,
    );
    defer types.freeExecutionMemory(std.heap.c_allocator, full_execution);
    var projection_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer projection_arena.deinit();
    const execution = try finalization.persistedExecution(projection_arena.allocator(), full_execution);
    terminal_materializing.* = true;

    if (retained_candidate) |candidate| {
        const assistant = try runtime_finalization.stopTerminalText(
            std.heap.c_allocator,
            candidate,
            partial_assistant,
        );
        defer if (assistant.presentation) |text| std.heap.c_allocator.free(text);
        const turn: HistoryTurn = .{ .interrupted = .{
            .user = .{ .text = job.prompt, .images = job.images, .work_id = job.work_id, .author = job.author, .input_id = job.input_id },
            .assistant = @constCast(assistant.history),
            .tool_call = durable_active_tool_call,
            .completed_tool_names = completed_tool_names,
            .execution = execution,
            .cancelled_command = cancelled_command,
            .cancelled_wait = cancelled_wait,
            .cancellation_origin = cancellation_origin,
            .saved_execution = finalization.savedExecution(full_execution),
        } };
        const finished = try types.dupeFinishedPrompt(
            std.heap.c_allocator,
            .{
                .turn = turn,
                .terminal_projection = .assistant_text,
                .presentation_text = assistant.presentation,
            },
        );

        persisted.* = true;
        var propagation_error: ?anyerror = null;
        hooks.propagate_history_turn(hooks.ctx, turn) catch |err| {
            propagation_error = err;
        };
        try traceInterruptedPersistence(
            job,
            assistant.history,
            active_tool_call,
            completed_tool_names,
            trace_ctx,
        );
        try finalization.finish(.interrupted, null, finished);
        debug_trace.eventf(
            "interrupt",
            "finish_event_emitted",
            trace_ctx,
            "outcome_kind=interrupted",
            .{},
        );
        if (propagation_error) |err| return err;
        return;
    }

    persisted.* = true;
    const turn: HistoryTurn = .{ .interrupted = .{
        .user = .{ .text = job.prompt, .images = job.images, .work_id = job.work_id, .author = job.author, .input_id = job.input_id },
        .assistant = if (partial_assistant) |text| if (text.len > 0) @constCast(text) else null else null,
        .tool_call = durable_active_tool_call,
        .completed_tool_names = completed_tool_names,
        .execution = execution,
        .cancelled_command = cancelled_command,
        .cancelled_wait = cancelled_wait,
        .cancellation_origin = cancellation_origin,
        .saved_execution = finalization.savedExecution(full_execution),
    } };

    var propagation_error: ?anyerror = null;
    hooks.propagate_history_turn(hooks.ctx, turn) catch |err| {
        propagation_error = err;
    };
    try traceInterruptedPersistence(
        job,
        partial_assistant,
        active_tool_call,
        completed_tool_names,
        trace_ctx,
    );
    try finalization.finish(.interrupted, null, .{
        .turn = try types.dupeHistoryTurn(std.heap.c_allocator, turn),
    });
    debug_trace.eventf("interrupt", "finish_event_emitted", trace_ctx, "outcome_kind=interrupted", .{});
    if (propagation_error) |err| return err;
}

pub fn persistFailedPartialTurnOnce(
    hooks: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    partial_assistant: []const u8,
    persisted: *bool,
    trace_ctx: TraceContext,
    current_turn_messages: []const types.ChatMessage,
    terminal_materializing: *bool,
) !void {
    if (persisted.*) return;
    if (partial_assistant.len == 0) return;

    const full_execution = try runtime_execution_memory.buildInterruptedExecutionMemory(
        std.heap.c_allocator,
        current_turn_messages,
        null,
    );
    defer types.freeExecutionMemory(std.heap.c_allocator, full_execution);
    try persistFailedTurn(
        hooks,
        finalization,
        job,
        partial_assistant,
        persisted,
        trace_ctx,
        full_execution,
        terminal_materializing,
    );
}

/// Borrows `full_execution`; the caller keeps ownership.
fn persistFailedTurn(
    hooks: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    partial_assistant: []const u8,
    persisted: *bool,
    trace_ctx: TraceContext,
    full_execution: types.ExecutionMemory,
    terminal_materializing: *bool,
) !void {
    var projection_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer projection_arena.deinit();
    const execution = try finalization.persistedExecution(projection_arena.allocator(), full_execution);
    terminal_materializing.* = true;

    const turn: HistoryTurn = .{ .interrupted = .{
        .user = .{ .text = job.prompt, .images = job.images, .work_id = job.work_id, .author = job.author, .input_id = job.input_id },
        .assistant = if (std.mem.trim(u8, partial_assistant, " \t\r\n").len > 0) @constCast(partial_assistant) else null,
        .execution = execution,
        .terminal_reason = .failed,
        .saved_execution = finalization.savedExecution(full_execution),
    } };
    const finished = try types.dupeFinishedPrompt(
        std.heap.c_allocator,
        .{
            .turn = turn,
            .terminal_projection = .assistant_text,
        },
    );

    persisted.* = true;
    var propagation_error: ?anyerror = null;
    hooks.propagate_history_turn(hooks.ctx, turn) catch |err| {
        propagation_error = err;
    };
    debug_trace.eventf(
        "gateway",
        "stream_failure_history_persisted",
        trace_ctx,
        "prompt_bytes={d} partial_assistant_bytes={d}",
        .{ job.prompt.len, partial_assistant.len },
    );
    try finalization.finish(.failed, null, finished);
    debug_trace.eventf(
        "gateway",
        "stream_failure_finish_event_emitted",
        trace_ctx,
        "outcome_kind=failed",
        .{},
    );
    if (propagation_error) |err| return err;
}

fn traceInterruptedPersistence(
    job: QueuedPrompt,
    partial_assistant: ?[]const u8,
    active_tool_call: ?ToolCall,
    completed_tool_names: [][]u8,
    trace_ctx: TraceContext,
) !void {
    const completed_tool_names_text = try runtime_telemetry.formatCompletedToolNamesCompact(std.heap.c_allocator, completed_tool_names);
    defer std.heap.c_allocator.free(completed_tool_names_text);
    debug_trace.logf("agent", "interrupted marker persisted prompt_bytes={d} partial_assistant_bytes={d} active_tool={s} completed_tool_count={d} completed_tool_names={s}", .{
        job.prompt.len,
        if (partial_assistant) |text| text.len else 0,
        if (active_tool_call != null) "true" else "false",
        completed_tool_names.len,
        completed_tool_names_text,
    });
    debug_trace.eventf("interrupt", "interrupted_history_persisted", trace_ctx, "prompt_bytes={d} partial_assistant_bytes={d} active_tool_known={s} completed_tool_count={d} completed_tool_names={s}", .{
        job.prompt.len,
        if (partial_assistant) |text| text.len else 0,
        if (active_tool_call != null) "true" else "false",
        completed_tool_names.len,
        completed_tool_names_text,
    });
    debug_trace.eventf("interrupt", "interrupt_persisted", trace_ctx, "prompt_bytes={d} partial_assistant_bytes={d} active_tool={s} completed_tool_count={d} completed_tool_names={s} active_tool_reason={s}", .{
        job.prompt.len,
        if (partial_assistant) |text| text.len else 0,
        if (active_tool_call != null) "true" else "false",
        completed_tool_names.len,
        completed_tool_names_text,
        interruptPersistenceReason(partial_assistant, active_tool_call, completed_tool_names),
    });
    if (active_tool_call) |tool_call| {
        debug_trace.logf("agent", "aborted tool output persisted call_id={s} name={s}", .{ tool_call.id, tool_call.name });
        debug_trace.eventf("interrupt", "aborted_tool_persisted", trace_ctx, "call_id={s} name={s}", .{ tool_call.id, tool_call.name });
    }
}

pub fn recordCompletedToolName(arena: Allocator, completed_tool_names: *std.ArrayList([]u8), name: []const u8) !void {
    try completed_tool_names.append(arena, try arena.dupe(u8, name));
}

pub fn countInterruptedHistory(history: []const HistoryTurn) usize {
    var count: usize = 0;
    for (history) |turn| {
        if (turn == .interrupted) count += 1;
    }
    return count;
}

pub fn countPartialTextInterruptedClosures(history: []const HistoryTurn) usize {
    var count: usize = 0;
    for (history) |turn| {
        const entry = switch (turn) {
            .interrupted => |value| value,
            else => continue,
        };
        if (entry.tool_call != null) continue;
        if (entry.completed_tool_names.len > 0) continue;
        if (entry.assistant) |assistant| {
            if (assistant.len > 0) count += 1;
        }
    }
    return count;
}

fn interruptPersistenceReason(partial_assistant: ?[]const u8, active_tool_call: ?ToolCall, completed_tool_names: []const []u8) []const u8 {
    if (active_tool_call != null) return "active_tool_call_present";
    if (completed_tool_names.len > 0) return "completed_tools_present";
    if (partial_assistant) |text| {
        if (text.len > 0) return "partial_assistant_only";
    }
    return "no_assistant_output";
}

test "eb03: persistInterruptedTurnOnce and persistFailedPartialTurnOnce carry job.input_id to UserTurn.input_id" {
    const support = @import("tests/support.zig");
    const alloc = std.testing.allocator;
    var fake = support.FakeAgentRuntimeDeps.init(alloc);
    defer fake.deinit();
    const deps = fake.deps();

    const job: QueuedPrompt = .{
        .turn_id = 1,
        .input_id = 91,
        .prompt = @constCast("interrupted prompt"),
        .images = &.{},
        .model = @constCast("model"),
        .api_key = @constCast("key"),
        .permission_mode = .auto,
        .history = &.{},
        .grants = &.{},
    };
    const lc = support.testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, "/tmp");

    // 1. retained_candidate branch
    {
        var guard = TurnFinalizationGuard.init(&deps, 1, lc);
        defer guard.deinit();
        var persisted = false;
        var materializing = false;
        try persistInterruptedTurnOnce(&deps, &guard, job, "partial", null, &.{}, &persisted, .{}, &.{}, "candidate", &materializing);
    }
    // 2. fallback branch (no retained_candidate)
    {
        var guard = TurnFinalizationGuard.init(&deps, 2, lc);
        defer guard.deinit();
        var persisted = false;
        var materializing = false;
        try persistInterruptedTurnOnce(&deps, &guard, job, "partial", null, &.{}, &persisted, .{}, &.{}, null, &materializing);
    }
    // 3. persistFailedPartialTurnOnce
    {
        var guard = TurnFinalizationGuard.init(&deps, 3, lc);
        defer guard.deinit();
        var persisted = false;
        var materializing = false;
        try persistFailedPartialTurnOnce(&deps, &guard, job, "partial", &persisted, .{}, &.{}, &materializing);
    }

    try std.testing.expectEqual(@as(usize, 3), fake.history_turns.items.len);
    for (fake.history_turns.items) |turn| {
        try std.testing.expectEqual(@as(?u64, 91), turn.interrupted.user.input_id);
    }
    try std.testing.expectEqual(@as(usize, 3), fake.finish_event_count);
    try std.testing.expectEqual(@as(?u64, 91), fake.finish_user_input_id);
}
