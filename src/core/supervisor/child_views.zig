//! What a session's viewers read about its subagents: the children list and
//! one child's transcript after a cursor. Both read the host, so only the
//! session's executor calls them.
const std = @import("std");
const acp = @import("../../acp/server.zig");
const child_state = @import("../subagent/child_state.zig");
const live_presentation = @import("../subagent/live_presentation.zig");
const types = @import("../shared/types.zig");
const protocol = @import("protocol.zig");
const Allocator = std.mem.Allocator;

pub fn children(arena: Allocator, host: *acp.PersistentHost, session_id: []const u8) ![]const u8 {
    var rows: std.ArrayList(protocol.Child) = .empty;
    if (host.state.subagent_v2_children) |registry_children| {
        const store = child_state.Store{ .children = registry_children, .parent_id = session_id };
        const registry = try store.load(arena);
        for (registry.children) |*child| {
            try rows.append(arena, .{
                .id = child.id,
                .parent_id = session_id,
                .name = child.agentName() orelse "subagent",
                .status = childStatus(child, false),
                .detail = if (child.active) |active| active.message else child.instructions(),
            });
        }
    }
    return protocol.encode(arena, protocol.Children{ .children = rows.items });
}

fn childStatus(child: *const child_state.Child, live_active: bool) []const u8 {
    if (live_active and child.phase == .idle) return "running";
    if (child.phase == .finished) if (child.last_outcome) |outcome| return @tagName(outcome);
    return @tagName(child.phase);
}

/// One child's transcript after the cursor in `request`.
pub fn childView(arena: Allocator, host: *acp.PersistentHost, session_id: []const u8, request: protocol.History) !protocol.ChildHistory(protocol.RawJson) {
    const child_id = request.child_id orelse return error.ChildNotFound;
    const registry_children = host.state.subagent_v2_children orelse return error.ChildNotFound;
    const store = child_state.Store{ .children = registry_children, .parent_id = session_id };
    const registry = try store.load(arena);
    for (registry.children) |*row| {
        if (!std.mem.eql(u8, row.id, child_id)) continue;
        const work_id = if (row.active) |active| active.id else row.last_work_id orelse "";
        const changed_work = !std.mem.eql(u8, request.work_id orelse "", work_id);
        const live = if (host.state.subagent_host) |child_host|
            try child_host.managed.snapshotPresentation(arena, child_id, work_id, request.after_live_sequence, request.include_history or changed_work)
        else
            null;
        const live_active = live != null or row.phase == .running or row.phase == .awaiting_approval;
        const tail: live_presentation.Snapshot = live orelse .{};
        const live_reset = request.include_history or changed_work or tail.reset or request.live_active != live_active;
        var turns: ?[]const types.HistoryTurn = null;
        if (live_reset) {
            // Current-work commits and compaction can race this read.
            // Work identity keeps them out of the immutable prior history
            // until settlement replaces the live tail.
            const saved: []types.HistoryTurn = host.state.sessions_v2.?.childHistory(arena, child_id) catch |err| switch (err) {
                error.NotFound, error.FileNotFound => if (live_active) &.{} else return err,
                else => return err,
            };
            var kept: std.ArrayList(types.HistoryTurn) = .empty;
            for (saved) |turn| {
                if (live_active and historyBelongsToWork(turn, work_id)) continue;
                try kept.append(arena, turn);
            }
            turns = kept.items;
        }
        return .{
            .child_id = child_id,
            .work_id = work_id,
            .live_active = live_active,
            .live_sequence = tail.sequence,
            .oldest_live_sequence = tail.oldest_sequence,
            .live_reset = live_reset,
            .name = row.agentName() orelse "subagent",
            .status = childStatus(row, live_active),
            .last_outcome = if (row.last_outcome) |outcome| @tagName(outcome) else null,
            .last_failure = if (row.last_failure) |*failure| failure.view() else null,
            .active_prompt = if (live_active) if (row.active) |active| active.message else null else null,
            .history = turns,
            .live_events = .{ .bytes = tail.events_json },
        };
    }
    return error.ChildNotFound;
}

fn historyBelongsToWork(turn: types.HistoryTurn, work_id: []const u8) bool {
    const saved_work = switch (turn) {
        .assistant => |entry| entry.user.work_id,
        .interrupted => |entry| entry.user.work_id,
        .compacted_summary => null,
    } orelse return false;
    return std.mem.eql(u8, saved_work, work_id);
}
