//! The model's `checkpoint` and `rewind` (D120). A checkpoint belongs to the
//! running turn, and its state is read from that turn's own messages, so it
//! survives whatever keeps the turn: a detached client, or a turn that
//! resumes from its saved pieces. A turn holds at most one open checkpoint.
//! A rewind drops the turn's messages after the checkpoint's step and before
//! the rewind's own step, which keeps the call and the report in its result
//! (`tests/tla/session_manager/Checkpoint.tla`).
const std = @import("std");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const runtime_deps = @import("deps.zig");
const execution_memory = @import("execution_memory.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const checkpoint_tool = "checkpoint";
pub const rewind_tool = "rewind";

/// Hidden reminders a turn gets to call `rewind` before it may end with its
/// checkpoint open (`tests/tla/session_manager/Checkpoint.tla` RemindersBounded).
pub const reminder_cap = 3;

pub const State = union(enum) {
    none,
    /// A checkpoint is open: what it explores, and the index of the first
    /// message after its step, where a rewind starts dropping.
    open: struct { goal: []const u8, cut: usize },
    /// The newest checkpoint was rewound.
    rewound,
};

/// The checkpoint state after `messages`, the running turn's messages so
/// far. `goal` is allocated in `alloc`.
pub fn scan(alloc: Allocator, messages: []const ChatMessage) Allocator.Error!State {
    var state: State = .none;
    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        const step = messages[index];
        if (step.role != .assistant or step.tool_calls.len == 0) continue;
        var end = index + 1;
        while (end < messages.len and messages[end].role == .tool) : (end += 1) {}
        const results = messages[index + 1 .. end];
        for (step.tool_calls) |call| {
            if (!succeeded(results, call.id)) continue;
            if (std.mem.eql(u8, call.name, checkpoint_tool)) {
                state = .{ .open = .{ .goal = try stringArg(alloc, call.arguments_json, "goal") orelse "", .cut = end } };
            } else if (std.mem.eql(u8, call.name, rewind_tool)) {
                state = .rewound;
            }
        }
        index = end - 1;
    }
    return state;
}

/// What the newest step's rewind drops: messages `start` up to `end`, the
/// rewind's step. Null when that step has no successful rewind, or nothing
/// lies between the checkpoint's step and it, as after the rewind applied.
pub const Pending = struct { start: usize, end: usize, goal: []const u8 };

pub fn pendingRewind(alloc: Allocator, messages: []const ChatMessage) Allocator.Error!?Pending {
    var last: ?usize = null;
    for (messages, 0..) |message, index| {
        if (message.role == .assistant and message.tool_calls.len > 0) last = index;
    }
    const step = last orelse return null;
    var end = step + 1;
    while (end < messages.len and messages[end].role == .tool) : (end += 1) {}
    const rewinds = for (messages[step].tool_calls) |call| {
        if (std.mem.eql(u8, call.name, rewind_tool) and succeeded(messages[step + 1 .. end], call.id)) break true;
    } else false;
    if (!rewinds) return null;
    return switch (try scan(alloc, messages[0..step])) {
        .open => |open| if (open.cut < step) .{ .start = open.cut, .end = step, .goal = open.goal } else null,
        .none, .rewound => null,
    };
}

/// Removes `pending`'s messages from the running turn.
pub fn drop(messages: *std.ArrayList(ChatMessage), pending: Pending) void {
    const items = messages.items;
    const tail = items.len - pending.end;
    @memmove(items[pending.start..][0..tail], items[pending.end..]);
    messages.shrinkRetainingCapacity(pending.start + tail);
}

/// Replaces the content of the newest step's rewind result, as when its
/// rewind cannot drop anything.
pub fn replaceRewindResult(messages: []ChatMessage, text: []const u8) void {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        const message = &messages[index];
        if (message.role != .tool) continue;
        const name = message.tool_name orelse continue;
        if (std.mem.eql(u8, name, rewind_tool)) {
            message.content = text;
            return;
        }
    }
}

fn succeeded(results: []const ChatMessage, call_id: []const u8) bool {
    for (results) |result| {
        const id = result.tool_call_id orelse continue;
        if (!std.mem.eql(u8, id, call_id)) continue;
        return (result.tool_result_status orelse .success) == .success;
    }
    return false;
}

/// String field `name` of a call's arguments, or null.
pub fn stringArg(alloc: Allocator, arguments_json: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, arguments_json, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    if (parsed != .object) return null;
    const value = parsed.object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

// -- The agent loop's part ---------------------------------------------------

/// Applies the rewind the last step ended with, if any (D120): the saved
/// turn drops the exploration first, then the turn's messages do. When a
/// compaction came after the checkpoint, or the save fails, nothing is
/// dropped and the rewind's result says so, which still closes the
/// checkpoint. `projector` has `project(arena, execution)`, as the turn's
/// compaction boundary does.
pub fn applyPending(
    deps: *const runtime_deps.AgentRuntimeDeps,
    messages: *std.ArrayList(ChatMessage),
    compacted_len: usize,
    user: types.UserTurn,
    projector: anytype,
) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const pending = try pendingRewind(sa, messages.items) orelse return;
    if (pending.start < compacted_len) {
        replaceRewindResult(messages.items, compacted_since);
        return;
    }
    if (deps.rewind_to_checkpoint) |rewind| {
        const kept = try execution_memory.buildExecutionMemory(sa, messages.items[0..pending.start]);
        rewind(deps.ctx, user, try projector.project(sa, kept)) catch |err| {
            debug_trace.logf("agent", "checkpoint rewind not saved err={s}", .{@errorName(err)});
            replaceRewindResult(messages.items, if (err == error.RewindPastCompaction) compacted_since else not_saved);
            return;
        };
    }
    drop(messages, pending);
    debug_trace.logf("agent", "checkpoint rewound dropped_messages={d}", .{pending.end - pending.start});
}

/// Keeps the turn going while its checkpoint is open: the reply stays in
/// the turn and a hidden reminder, which is never saved, asks for `rewind`,
/// up to `reminder_cap` times. Then the turn may end, and the person is told
/// once. Returns whether the turn goes on.
pub fn remind(
    deps: *const runtime_deps.AgentRuntimeDeps,
    arena: Allocator,
    messages: *std.ArrayList(ChatMessage),
    reminders: *usize,
    reply: []const u8,
    replay: ?types.ProviderReplay,
) !bool {
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    if (try scan(scratch.allocator(), messages.items) != .open) return false;
    if (reminders.* >= reminder_cap) {
        if (reminders.* == reminder_cap) try deps.push_system_notice(deps.ctx, left_open_notice);
        reminders.* = reminder_cap + 1;
        return false;
    }
    reminders.* += 1;
    try messages.append(arena, .{ .role = .assistant, .content = reply, .provider_replay = replay, .standalone_response = true });
    try messages.append(arena, .{ .role = .user, .content = try reminder(arena, reminders.*) });
    try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });
    return true;
}

// -- What the model reads ----------------------------------------------------

pub const already_open = "Checkpoint already active. Call rewind with your findings before opening another.";
pub const no_checkpoint = "No active checkpoint. Create a checkpoint before calling rewind.";
pub const already_rewound = "Checkpoint already completed; continue from the retained rewind report instead of calling rewind again.";
pub const empty_goal = "Goal cannot be empty.";
pub const empty_report = "Report cannot be empty.";
pub const subtree_busy = "A worker or child node of this session is still running, and a rewind needs them settled. Wait for it with fleet, or terminate it, then call rewind again.";
pub const not_saved = "Checkpoint closed without a rewind: the session could not save it, so the exploration stays in context. Continue from here.";
pub const compacted_since = "Checkpoint closed without a rewind: context was compacted after the checkpoint, so the exploration is already summarized. Continue from here.";

pub fn checkpointResult(alloc: Allocator, goal: []const u8) Allocator.Error![]u8 {
    return alloc.print("Checkpoint: {s}\nFinish exploration and formulate findings, then call rewind with them before you reply.", .{goal});
}

pub fn rewindResult(alloc: Allocator, goal: []const u8, report: []const u8) Allocator.Error![]u8 {
    return alloc.print(
        "Checkpoint called and rewound: the exploration since checkpoint \"{s}\" is gone from your context, and this report replaces it. Python variables, the proto_fx store and files keep what the exploration left. Need explore again → new `checkpoint`.\n\nReport:\n{s}",
        .{ goal, report },
    );
}

/// The hidden reminder `attempt` (1-based) of `reminder_cap`.
pub fn reminder(alloc: Allocator, attempt: usize) Allocator.Error![]u8 {
    return alloc.print(
        "<system-warning>\nYou are in an active checkpoint. You MUST call rewind with your investigation findings before yielding. Do NOT yield without completing the checkpoint. (Reminder {d} of {d}.){s}\n</system-warning>",
        .{
            attempt,
            reminder_cap,
            if (attempt >= reminder_cap) "\nThis is the final reminder: if you do not call rewind now, the turn ends with the checkpoint still open and your findings unreported." else "",
        },
    );
}

/// What the person sees when a turn ends with its checkpoint still open.
pub const left_open_notice = std.fmt.comptimePrint(
    "Checkpoint left open: the agent ignored {d} reminders to call rewind, so the turn ended with its exploration still in context.",
    .{reminder_cap},
);

// -- Tests -------------------------------------------------------------------

const testing = std.testing;

fn testCall(id: []const u8, name: []const u8, args: []const u8) types.ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}

fn testResult(id: []const u8, name: []const u8, status: types.PersistedToolStatus) ChatMessage {
    return .{ .role = .tool, .tool_call_id = id, .tool_name = name, .content = "r", .tool_result_status = status };
}

test "a checkpoint opens on its step and a rewind closes it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const open = [_]types.ToolCall{testCall("c1", checkpoint_tool, "{\"goal\":\"find the cache bug\"}")};
    const read = [_]types.ToolCall{testCall("r1", "read_file", "{}")};
    const rewind = [_]types.ToolCall{testCall("w1", rewind_tool, "{\"report\":\"it is in lru.zig\"}")};
    var messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &open },
        testResult("c1", checkpoint_tool, .success),
        .{ .role = .assistant, .tool_calls = &read },
        testResult("r1", "read_file", .success),
        .{ .role = .assistant, .content = "done?", .standalone_response = true },
        .{ .role = .assistant, .tool_calls = &rewind },
        testResult("w1", rewind_tool, .success),
    };
    try testing.expectEqual(State.none, try scan(a, messages[0..1]));
    const state = try scan(a, messages[0..4]);
    try testing.expectEqualStrings("find the cache bug", state.open.goal);
    try testing.expectEqual(@as(usize, 2), state.open.cut);
    try testing.expectEqual(State.rewound, try scan(a, &messages));

    const pending = (try pendingRewind(a, &messages)).?;
    try testing.expectEqual(@as(usize, 2), pending.start);
    try testing.expectEqual(@as(usize, 5), pending.end);
    var list: std.ArrayList(ChatMessage) = .empty;
    try list.appendSlice(a, &messages);
    drop(&list, pending);
    try testing.expectEqual(@as(usize, 4), list.items.len);
    try testing.expectEqualStrings(rewind_tool, list.items[2].tool_calls[0].name);
    // Applying it again drops nothing.
    try testing.expectEqual(@as(?Pending, null), try pendingRewind(a, list.items));
}

test "a failed checkpoint or rewind changes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const open = [_]types.ToolCall{testCall("c1", checkpoint_tool, "{\"goal\":\"g\"}")};
    const rewind = [_]types.ToolCall{testCall("w1", rewind_tool, "{\"report\":\"\"}")};
    const failed = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &open },
        testResult("c1", checkpoint_tool, .failure),
    };
    try testing.expectEqual(State.none, try scan(a, &failed));
    const refused = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &open },
        testResult("c1", checkpoint_tool, .success),
        .{ .role = .assistant, .tool_calls = &rewind },
        testResult("w1", rewind_tool, .failure),
    };
    try testing.expect((try scan(a, &refused)) == .open);
    try testing.expectEqual(@as(?Pending, null), try pendingRewind(a, &refused));
}

test "the reminders count up to the cap and say when they are the last" {
    const first = try reminder(testing.allocator, 1);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.find(u8, first, "(Reminder 1 of 3.)") != null);
    try testing.expect(std.mem.find(u8, first, "final reminder") == null);
    const last = try reminder(testing.allocator, reminder_cap);
    defer testing.allocator.free(last);
    try testing.expect(std.mem.find(u8, last, "final reminder") != null);
}
