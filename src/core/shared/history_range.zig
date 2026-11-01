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
        const first_note = coveredContextNotes(execution.*, first_step, first_steering);
        const last_note = if (partial_end) coveredContextNotes(execution.*, last_step, last_steering) else execution.context_notes.len;
        execution.tool_steps = execution.tool_steps[first_step..last_step];
        execution.steering = execution.steering[first_steering..last_steering];
        execution.context_notes = try rebasedContextNotes(arena, execution.context_notes[first_note..last_note], first_step);
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

/// How many of `execution`'s context notes a cut after `tool_steps` steps and
/// `steering` steering messages covers (D93). A note sits at a step boundary,
/// before that boundary's steering, so the cut covers every note before its
/// own boundary, and the notes at that boundary too when it covers a steering
/// message there.
pub fn coveredContextNotes(execution: types.ExecutionMemory, tool_steps: usize, steering: usize) usize {
    var steering_before: usize = 0;
    for (execution.steering) |item| {
        if (item.after_tool_step_count >= tool_steps) break;
        steering_before += 1;
    }
    const covers_boundary = steering > steering_before;
    var covered: usize = 0;
    for (execution.context_notes) |note| {
        if (note.after_tool_step_count > tool_steps or
            (note.after_tool_step_count == tool_steps and !covers_boundary)) break;
        covered += 1;
    }
    return covered;
}

/// `notes` counted from `first_step`: borrowed when it is 0 or there are no
/// notes, otherwise an arena copy. Every note must sit at or after it.
pub fn rebasedContextNotes(
    arena: Allocator,
    notes: []types.PersistedContextNote,
    first_step: usize,
) error{ OutOfMemory, InvalidContextHistoryStart }![]types.PersistedContextNote {
    if (first_step == 0 or notes.len == 0) return notes;
    const rebased = try arena.dupe(types.PersistedContextNote, notes);
    for (rebased) |*note| {
        if (note.after_tool_step_count < first_step) return error.InvalidContextHistoryStart;
        note.after_tool_step_count -= first_step;
    }
    return rebased;
}

test "a cut covers the notes before its boundary and keeps the rest" {
    var notes = [_]types.PersistedContextNote{
        .{ .text = @constCast("at start"), .after_tool_step_count = 0 },
        .{ .text = @constCast("after one"), .after_tool_step_count = 1 },
        .{ .text = @constCast("after two"), .after_tool_step_count = 2 },
    };
    var steering = [_]types.PersistedSteering{.{ .text = @constCast("steer"), .after_tool_step_count = 2 }};
    const execution: types.ExecutionMemory = .{ .steering = &steering, .context_notes = &notes };
    try std.testing.expectEqual(@as(usize, 0), coveredContextNotes(execution, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), coveredContextNotes(execution, 1, 0));
    // A cut at a boundary keeps that boundary's notes and its steering...
    try std.testing.expectEqual(@as(usize, 2), coveredContextNotes(execution, 2, 0));
    // ...unless it covers that steering, which follows them.
    try std.testing.expectEqual(@as(usize, 3), coveredContextNotes(execution, 2, 1));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const kept = try rebasedContextNotes(arena_state.allocator(), notes[2..], 2);
    try std.testing.expectEqual(@as(usize, 0), kept[0].after_tool_step_count);
    try std.testing.expectEqual(@as(usize, 2), notes[2].after_tool_step_count);
    try std.testing.expectError(error.InvalidContextHistoryStart, rebasedContextNotes(arena_state.allocator(), notes[0..1], 1));
}
