//! Counting and slicing a conversation's saved turns around a context cut,
//! shared by the session and context compaction.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;

/// The saved turns of `history`, leaving out compaction checkpoints.
pub fn rawHistoryTurnCount(history: []const HistoryTurn) usize {
    var count: usize = 0;
    for (history) |turn| if (turn != .compacted_summary) {
        count += 1;
    };
    return count;
}

/// Borrows payloads. Only descriptors and rebased steering are arena-owned.
pub fn contextHistoryRange(
    arena: Allocator,
    history: []const HistoryTurn,
    start: types.ContextHistoryCut,
    end: ?types.ContextHistoryCut,
) ![]HistoryTurn {
    var view: std.ArrayList(HistoryTurn) = .empty;
    var raw_index: usize = 0;
    for (history) |original| {
        if (original == .compacted_summary) continue;
        const index = raw_index;
        raw_index += 1;
        if (index < start.turns) continue;
        if (end) |limit| {
            if (index > limit.turns or (index == limit.turns and limit.tool_steps == 0 and limit.steering == 0)) break;
        }
        var turn = original;
        const execution = switch (turn) {
            .assistant => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
            .compacted_summary => unreachable,
        };
        const first_step = if (index == start.turns) start.tool_steps else 0;
        const first_steering = if (index == start.turns) start.steering else 0;
        const partial_end = if (end) |limit| index == limit.turns else false;
        const last_step = if (partial_end) end.?.tool_steps else execution.tool_steps.len;
        const last_steering = if (partial_end) end.?.steering else execution.steering.len;
        if (first_step > last_step or last_step > execution.tool_steps.len or
            first_steering > last_steering or last_steering > execution.steering.len)
            return error.InvalidContextHistoryStart;
        execution.tool_steps = execution.tool_steps[first_step..last_step];
        execution.steering = execution.steering[first_steering..last_steering];
        if (first_step > 0 and execution.steering.len > 0) {
            execution.steering = try arena.dupe(types.PersistedSteering, execution.steering);
            for (execution.steering) |*item| {
                if (item.after_tool_step_count < first_step) return error.InvalidContextHistoryStart;
                item.after_tool_step_count -= first_step;
            }
        }
        if (partial_end) {
            execution.files = &.{};
            execution.turn_summary = null;
            switch (turn) {
                .assistant => |*entry| {
                    entry.assistant = @constCast("");
                    entry.provider_replay = null;
                },
                .interrupted => |*entry| {
                    entry.assistant = null;
                    entry.tool_call = null;
                    entry.completed_tool_names = &.{};
                    entry.cancelled_command = null;
                },
                .compacted_summary => unreachable,
            }
        }
        try view.append(arena, turn);
    }
    return view.toOwnedSlice(arena);
}
