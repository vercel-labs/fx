const std = @import("std");
const hooks = @import("../../hooks/hooks.zig");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const deps_mod = @import("deps.zig");
const execution_memory = @import("execution_memory.zig");
const lifecycle_runtime = @import("lifecycle.zig");
const telemetry = @import("telemetry.zig");
const worker_runtime = @import("../worker_runtime.zig");

const Allocator = std.mem.Allocator;
const AgentRuntimeDeps = deps_mod.AgentRuntimeDeps;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const LifecycleContext = lifecycle_runtime.LifecycleContext;
const QueuedPrompt = worker_runtime.QueuedPrompt;
const TraceContext = debug_trace.TraceContext;
const TurnSummaryAccumulator = telemetry.TurnSummaryAccumulator;

pub const PromptFinishTrace = struct {
    ctx: TraceContext,
    emitted: bool = false,

    pub fn finish(self: *PromptFinishTrace, outcome: []const u8) void {
        if (self.emitted) return;
        self.emitted = true;
        debug_trace.eventf("agent", "prompt_finish", self.ctx, "outcome_kind={s}", .{outcome});
    }
};

pub const TurnFinalizationGuard = struct {
    pub const State = enum {
        open,
        emitted,
        fatal,
    };

    deps: *const AgentRuntimeDeps,
    turn_id: u64,
    lifecycle: LifecycleContext,
    state: State = .open,
    outcome: ?types.TurnPresentationOutcome = null,
    compacted_execution: execution_memory.CompactedExecutionBoundary = .{},
    lease_allocator: Allocator = std.heap.c_allocator,
    agent_terminal_leases: std.ArrayList([]u8) = .empty,

    pub fn init(
        deps: *const AgentRuntimeDeps,
        turn_id: u64,
        lifecycle_context: LifecycleContext,
    ) TurnFinalizationGuard {
        std.debug.assert(turn_id != 0);
        return .{
            .deps = deps,
            .turn_id = turn_id,
            .lifecycle = lifecycle_context,
        };
    }

    pub fn deinit(self: *TurnFinalizationGuard) void {
        for (self.agent_terminal_leases.items) |session_id| {
            self.lease_allocator.free(session_id);
        }
        self.agent_terminal_leases.deinit(self.lease_allocator);
        self.* = undefined;
    }

    pub fn track_agent_terminal_lease(
        self: *TurnFinalizationGuard,
        session_id: []const u8,
    ) Allocator.Error!void {
        for (self.agent_terminal_leases.items) |tracked| {
            if (std.mem.eql(u8, tracked, session_id)) return;
        }
        const owned = try self.lease_allocator.dupe(u8, session_id);
        errdefer self.lease_allocator.free(owned);
        try self.agent_terminal_leases.append(self.lease_allocator, owned);
    }

    pub fn remove_agent_terminal_lease(
        self: *TurnFinalizationGuard,
        session_id: []const u8,
    ) void {
        for (self.agent_terminal_leases.items, 0..) |tracked, index| {
            if (!std.mem.eql(u8, tracked, session_id)) continue;
            const removed = self.agent_terminal_leases.swapRemove(index);
            self.lease_allocator.free(removed);
            return;
        }
    }

    fn cleanup_agent_terminal_leases(self: *TurnFinalizationGuard) void {
        for (self.agent_terminal_leases.items) |session_id| {
            self.deps.release_agent_terminal_lease(
                self.deps.ctx,
                session_id,
            ) catch |err| {
                debug_trace.logf(
                    "terminal",
                    "turn lease cleanup failed turn_id={d} session_id={s} err={s}",
                    .{ self.turn_id, session_id, @errorName(err) },
                );
            };
        }
    }

    pub fn finish(
        self: *TurnFinalizationGuard,
        outcome: types.TurnPresentationOutcome,
        disposition: ?types.ProviderCompletionDisposition,
        finished_prompt: ?types.FinishedPrompt,
    ) !void {
        if (self.state != .open) {
            if (finished_prompt) |finished| {
                types.freeFinishedPrompt(std.heap.c_allocator, finished);
            }
            debug_trace.logf(
                "agent",
                "duplicate turn finalization ignored turn_id={d} state={s}",
                .{ self.turn_id, @tagName(self.state) },
            );
            return;
        }

        self.cleanup_agent_terminal_leases();

        self.deps.finalize_turn(self.deps.ctx, self.turn_id, outcome, disposition) catch |err| {
            self.state = .fatal;
            if (finished_prompt) |finished| {
                types.freeFinishedPrompt(std.heap.c_allocator, finished);
            }
            return err;
        };
        self.state = .emitted;
        self.outcome = outcome;

        defer lifecycle_runtime.dispatchPostTurnEndCheckpoint(self.lifecycle, .{
            .turn_id = self.turn_id,
            .outcome = outcome,
            .provider_disposition = disposition,
        });

        if (finished_prompt) |finished| {
            var qualified_finished = finished;
            qualified_finished.terminal_outcome = outcome;
            try self.deps.push_event(self.deps.ctx, .{ .finish_prompt = qualified_finished });
        }
    }
};

pub const TerminalText = struct {
    history: []const u8,
    presentation: ?[]const u8 = null,
};

/// The candidate is already retained as an original response. History borrows
/// only current text; the caller owns the joined presentation.
pub fn stopTerminalText(
    alloc: std.mem.Allocator,
    candidate: ?[]const u8,
    current: ?[]const u8,
) Allocator.Error!TerminalText {
    const presentation = try hooks.prompt.joinVisibleSegments(alloc, candidate, current);
    return .{
        .history = current orelse "",
        .presentation = presentation,
    };
}

pub fn finishAssistantTerminalWithExecution(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    execution: types.ExecutionMemory,
    summary: *TurnSummaryAccumulator,
    assistant_text: []const u8,
    outcome: types.TurnPresentationOutcome,
    disposition: ?types.ProviderCompletionDisposition,
    finish_trace: *PromptFinishTrace,
    trace_outcome: []const u8,
    replay: ?types.ProviderReplay,
    presentation_text: ?[]const u8,
) !void {
    var projection_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer projection_arena.deinit();
    const context_execution = try finalization.compacted_execution.project(projection_arena.allocator(), execution);
    const completed_summary = summary.finish();
    var turn: HistoryTurn = .{ .assistant = .{
        .user = .{ .text = job.prompt, .images = job.images },
        .assistant = @constCast(assistant_text),
        .provider_replay = replay,
        .execution = context_execution,
    } };
    types.setHistoryTurnSummary(&turn, completed_summary);
    const finished = try types.dupeFinishedPrompt(
        std.heap.c_allocator,
        .{
            .turn = turn,
            .summary = completed_summary,
            .presentation_text = presentation_text,
        },
    );

    var propagation_error: ?anyerror = null;
    deps.propagate_history_turn(deps.ctx, turn) catch |err| {
        propagation_error = err;
    };
    try finalization.finish(outcome, disposition, finished);
    finish_trace.finish(trace_outcome);
    if (propagation_error) |err| return err;
}

pub fn finishExecutionOnlyFailureIfNeeded(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    summary: *TurnSummaryAccumulator,
    finish_trace: *PromptFinishTrace,
    terminal_materializing: *bool,
    trace_outcome: []const u8,
) !bool {
    const execution = try execution_memory.buildExecutionMemory(
        arena,
        current_turn_messages,
    );
    if (execution.isEmpty()) return false;

    terminal_materializing.* = true;
    try finishAssistantTerminalWithExecution(
        deps,
        finalization,
        job,
        execution,
        summary,
        "",
        .failed,
        null,
        finish_trace,
        trace_outcome,
        null,
        null,
    );
    return true;
}

pub fn finalizeRetainedCandidateFailure(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    summary: *TurnSummaryAccumulator,
    finish_trace: *PromptFinishTrace,
    retained_candidate: ?[]const u8,
    latest_partial: ?[]const u8,
    terminal_materializing: *bool,
) !void {
    terminal_materializing.* = true;
    const assistant_text = try stopTerminalText(
        arena,
        retained_candidate,
        latest_partial,
    );
    const execution = try execution_memory.buildExecutionMemory(
        arena,
        current_turn_messages,
    );
    try finishAssistantTerminalWithExecution(
        deps,
        finalization,
        job,
        execution,
        summary,
        assistant_text.history,
        .failed,
        null,
        finish_trace,
        "error",
        null,
        assistant_text.presentation,
    );
}
