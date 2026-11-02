//! The runtime context is what a host adds to every request ahead of the
//! history (`append_runtime_context`): the turn context with its date and git
//! branch, the permission mode and the other runtime notes. A session sends
//! one copy of it, unchanged, on every request, resumed ones included, so the
//! cached history stays intact. The turn that captures the copy saves it
//! with its execution memory. When the current runtime context differs from
//! what the model last saw, an update note with the whole current context
//! joins the conversation at the step boundary where fx noticed it: on that
//! turn's user message, or on the tool result of the step that changed it
//! (D94, `tests/tla/prompt_context/PromptCache.tla` "outside" and "switch").

const std = @import("std");
const types = @import("../../shared/types.zig");
const model_context_encoding = @import("../../shared/model_context_encoding.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

/// Opens an update note. Tool output cannot open one: the request escapes
/// the tag there (`model_context_encoding.writeCarriedEscaped`).
pub const update_open_tag = "<" ++ model_context_encoding.context_update_tag ++ ">";
const update_close_tag = "</" ++ model_context_encoding.context_update_tag ++ ">";
const update_preface =
    "The runtime context changed during this session. These blocks replace the turn context and runtime notes in the instructions above, and any earlier update:\n";

pub const State = struct {
    /// Sent ahead of the history on every request of the turn; null until
    /// the first step captures it, when no retained turn saved one.
    frozen: ?[]const ChatMessage,
    /// The texts this turn captured, which every save of the turn records;
    /// null when an earlier turn's copy applies or there is nothing to save.
    captured: ?[][]u8 = null,
    /// The newest update note the conversation holds, or null when the model
    /// has seen only `frozen`.
    known_update: ?[]const u8,

    /// Restores the copy the newest retained turn saved, with the newest
    /// update after it. A compaction summary ends the search: the turns before
    /// it are not sent. `checkpoint` is this turn's own earlier attempt, when
    /// it is being recovered. Without a saved copy, the first `refresh`
    /// captures one. Everything the result holds is allocated in `arena`.
    pub fn init(
        arena: Allocator,
        history: []const types.HistoryTurn,
        checkpoint: ?types.ExecutionMemory,
    ) Allocator.Error!State {
        var known_update: ?[]const u8 = null;
        if (checkpoint) |execution| {
            known_update = newestUpdate(execution);
            if (execution.runtime_context) |texts| {
                // This turn captured it before it was interrupted, so its
                // saves keep it.
                const captured = try types.dupeRuntimeContext(arena, texts);
                return .{ .frozen = try messagesFrom(arena, captured), .captured = captured, .known_update = known_update };
            }
        }
        var index = history.len;
        while (index > 0) {
            index -= 1;
            const execution = switch (history[index]) {
                .compacted_summary => break,
                .assistant => |entry| entry.execution,
                .interrupted => |entry| entry.execution,
            };
            if (known_update == null) known_update = newestUpdate(execution);
            if (execution.runtime_context) |texts| {
                return .{ .frozen = try messagesFrom(arena, texts), .known_update = known_update };
            }
        }
        return .{ .frozen = null, .known_update = known_update };
    }

    /// The runtime context to send ahead of the history. Valid after the
    /// first `refresh`.
    pub fn messages(self: State) []const ChatMessage {
        return self.frozen orelse &.{};
    }

    /// Captures `current` on the turn's first step when no retained turn
    /// saved a copy, then compares it with what the model last saw. Returns
    /// the update note to add at this boundary, allocated in `arena` for the
    /// rest of the turn, or null when the model already has the current
    /// context. The comparison uses `scratch`.
    pub fn refresh(self: *State, arena: Allocator, scratch: Allocator, current: []const ChatMessage) Allocator.Error!?[]const u8 {
        if (self.frozen == null) {
            const texts = try scratch.alloc([]const u8, current.len);
            defer scratch.free(texts);
            for (current, texts) |message, *text| text.* = message.content orelse "";
            const captured = try types.dupeRuntimeContext(arena, texts);
            self.frozen = try messagesFrom(arena, captured);
            if (captured.len > 0) self.captured = captured;
        }
        if (self.known_update) |known| {
            if (try matchesUpdate(scratch, current, known)) return null;
        } else if (sameTexts(current, self.frozen.?)) {
            return null;
        }
        const note = try renderUpdate(arena, current);
        self.known_update = note;
        return note;
    }
};

/// The update note for `current`: every runtime context message, in order.
/// Caller owns the result.
pub fn renderUpdate(alloc: Allocator, current: []const ChatMessage) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    renderUpdateTo(&out.writer, current) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn renderUpdateTo(writer: *std.Io.Writer, current: []const ChatMessage) std.Io.Writer.Error!void {
    try writer.writeAll(update_open_tag ++ "\n" ++ update_preface);
    for (current) |message| {
        try writer.writeByte('\n');
        try writer.writeAll(message.content orelse "");
        try writer.writeByte('\n');
    }
    try writer.writeAll(update_close_tag);
}

fn matchesUpdate(scratch: Allocator, current: []const ChatMessage, known: []const u8) Allocator.Error!bool {
    const rendered = try renderUpdate(scratch, current);
    defer scratch.free(rendered);
    return std.mem.eql(u8, rendered, known);
}

fn sameTexts(current: []const ChatMessage, frozen: []const ChatMessage) bool {
    if (current.len != frozen.len) return false;
    for (current, frozen) |a, b| {
        if (!std.mem.eql(u8, a.content orelse "", b.content orelse "")) return false;
    }
    return true;
}

fn newestUpdate(execution: types.ExecutionMemory) ?[]const u8 {
    var index = execution.context_notes.len;
    while (index > 0) {
        index -= 1;
        const text = execution.context_notes[index].text;
        if (std.mem.startsWith(u8, text, update_open_tag)) return text;
    }
    return null;
}

fn messagesFrom(arena: Allocator, texts: []const []const u8) Allocator.Error![]ChatMessage {
    const messages = try arena.alloc(ChatMessage, texts.len);
    for (texts, messages) |text, *message| message.* = .{ .role = .system, .content = text };
    return messages;
}

fn systemMessages(comptime texts: []const []const u8) [texts.len]ChatMessage {
    var messages: [texts.len]ChatMessage = undefined;
    for (texts, &messages) |text, *message| message.* = .{ .role = .system, .content = text };
    return messages;
}

fn assistantTurn(execution: types.ExecutionMemory) types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = @constCast("question") },
        .assistant = @constCast("answer"),
        .execution = execution,
    } };
}

test "a session without a saved runtime context captures the current one and sends it as it is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const current = systemMessages(&.{ "<fx-turn-context>\ngit_branch: main\n</fx-turn-context>", "Runtime context: permission mode is ask." });

    var state = try State.init(arena, &.{}, null);
    try std.testing.expect(state.frozen == null);
    try std.testing.expect(try state.refresh(arena, arena, &current) == null);
    try std.testing.expectEqual(@as(usize, 2), state.captured.?.len);
    try std.testing.expectEqual(@as(usize, 2), state.messages().len);
    for (current, state.messages()) |want, got| {
        try std.testing.expectEqual(types.ChatRole.system, got.role);
        try std.testing.expectEqualStrings(want.content.?, got.content.?);
    }
    try std.testing.expect(try state.refresh(arena, arena, &current) == null);
}

test "a later turn sends the saved runtime context and notes a change once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var saved = [_][]u8{ @constCast("<fx-turn-context>\ngit_branch: main\n</fx-turn-context>"), @constCast("Runtime context: permission mode is ask.") };
    const history = [_]types.HistoryTurn{assistantTurn(.{ .runtime_context = &saved })};
    const current = systemMessages(&.{ "<fx-turn-context>\ngit_branch: feature\n</fx-turn-context>", "Runtime context: permission mode is ask." });

    var state = try State.init(arena, &history, null);
    try std.testing.expect(state.captured == null);
    try std.testing.expectEqualStrings(saved[0], state.messages()[0].content.?);

    const note = (try state.refresh(arena, arena, &current)).?;
    try std.testing.expectEqualStrings(
        "<fx-context-update>\nThe runtime context changed during this session. These blocks replace the turn context and runtime notes in the instructions above, and any earlier update:\n" ++
            "\n<fx-turn-context>\ngit_branch: feature\n</fx-turn-context>\n\nRuntime context: permission mode is ask.\n</fx-context-update>",
        note,
    );
    try std.testing.expect(try state.refresh(arena, arena, &current) == null);
    try std.testing.expect(state.captured == null);
    try std.testing.expectEqualStrings(saved[0], state.messages()[0].content.?);
}

test "the newest saved update counts as seen, and a change back to the saved copy is noted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var saved = [_][]u8{@constCast("Runtime context: permission mode is ask.")};
    const auto = systemMessages(&.{"Runtime context: permission mode is auto."});
    const ask = systemMessages(&.{"Runtime context: permission mode is ask."});
    const update = try renderUpdate(arena, &auto);
    var notes = [_]types.PersistedContextNote{
        .{ .text = @constCast("<scoped-rules from=\"sub/AGENTS.md\" scope=\"sub\">\nrule\n</scoped-rules>"), .after_tool_step_count = 0 },
        .{ .text = update, .after_tool_step_count = 1 },
    };
    const history = [_]types.HistoryTurn{
        assistantTurn(.{ .runtime_context = &saved }),
        assistantTurn(.{ .context_notes = &notes }),
    };

    var state = try State.init(arena, &history, null);
    try std.testing.expect(try state.refresh(arena, arena, &auto) == null);
    const back = (try state.refresh(arena, arena, &ask)).?;
    try std.testing.expect(std.mem.endsWith(u8, back, "\nRuntime context: permission mode is ask.\n</fx-context-update>"));
}

test "a compaction summary ends the search, and an update kept after it still counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var saved = [_][]u8{@constCast("Runtime context: permission mode is ask.")};
    const auto = systemMessages(&.{"Runtime context: permission mode is auto."});
    const full = systemMessages(&.{"Runtime context: permission mode is full access."});
    var notes = [_]types.PersistedContextNote{.{ .text = try renderUpdate(arena, &auto), .after_tool_step_count = 0 }};
    const history = [_]types.HistoryTurn{
        assistantTurn(.{ .runtime_context = &saved }),
        .{ .compacted_summary = .{ .summary = @constCast("summary"), .removed_turn_count = 1, .compaction_count = 1 } },
        assistantTurn(.{ .context_notes = &notes }),
    };

    var state = try State.init(arena, &history, null);
    try std.testing.expect(state.frozen == null);
    // The kept update says auto after the new copy in the request, so the
    // model hears the current mode once more.
    const note = (try state.refresh(arena, arena, &full)).?;
    try std.testing.expectEqualStrings(full[0].content.?, state.captured.?[0]);
    try std.testing.expectEqualStrings(full[0].content.?, state.messages()[0].content.?);
    try std.testing.expect(std.mem.endsWith(u8, note, "\nRuntime context: permission mode is full access.\n</fx-context-update>"));
}

test "a recovered turn keeps the runtime context its first attempt captured" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var older = [_][]u8{@constCast("Runtime context: permission mode is ask.")};
    var attempt = [_][]u8{@constCast("Runtime context: permission mode is auto.")};
    const history = [_]types.HistoryTurn{assistantTurn(.{ .runtime_context = &older })};
    const auto = systemMessages(&.{"Runtime context: permission mode is auto."});

    var state = try State.init(arena, &history, .{ .runtime_context = &attempt });
    try std.testing.expectEqualStrings(attempt[0], state.captured.?[0]);
    try std.testing.expect(try state.refresh(arena, arena, &auto) == null);
}

test "an empty runtime context is sent as nothing and not saved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try State.init(arena, &.{}, null);
    try std.testing.expect(try state.refresh(arena, arena, &.{}) == null);
    try std.testing.expect(state.captured == null);
    try std.testing.expectEqual(@as(usize, 0), state.messages().len);
}
