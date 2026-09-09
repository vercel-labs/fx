//! The one-time native history base. It carries no invented request identities;
//! future turns use ordinary execution records after this checkpoint.
const std = @import("std");
const codec = @import("execution_journal_codec.zig");
const session_codec = @import("session_codec.zig");
const types = @import("../shared/types.zig");

pub fn encode(alloc: std.mem.Allocator, source: session_codec.DurableSessionState) !codec.OwnedEntry {
    const context = try legacyContext(alloc, source.history, source.context_history_start);
    defer alloc.free(context);
    return encodeWithContext(alloc, source, context);
}

pub fn encodeWithContext(alloc: std.mem.Allocator, source: session_codec.DurableSessionState, history: []const types.HistoryTurn) !codec.OwnedEntry {
    if (source.recovery_checkpoint != null) return error.PendingTurnError;
    try session_codec.validateState(source);
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    _ = session_codec.encodeState(source, &encoded.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var context_state = source;
    context_state.history = @constCast(history);
    context_state.context_history_start = 0;
    var context: std.Io.Writer.Allocating = .init(alloc);
    defer context.deinit();
    _ = session_codec.encodeState(context_state, &context.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    std.json.Stringify.value(.{
        .v = 2,
        .kind = "checkpoint",
        .lastIncludedSeq = 0,
        .nativeBase = .{ .v = 1, .id = source.id, .stateJson = encoded.written(), .contextJson = context.written() },
        .records = .{},
    }, .{}, &writer.writer) catch return error.OutOfMemory;
    return codec.create(alloc, 1, .checkpoint, writer.written());
}

/// Pure decoding. The native store separately validates/rebinds artifact roots
/// and supplies current authority; this historical base grants no permissions.
pub fn decodeBase(alloc: std.mem.Allocator, value: std.json.Value) !session_codec.DurableSessionState {
    var context = try decodePart(alloc, value, "contextJson");
    defer context.deinit(alloc);
    if (context.context_history_start != 0) return error.InvalidJournalRecord;
    return decodePart(alloc, value, "stateJson");
}

pub fn decodeContext(alloc: std.mem.Allocator, value: std.json.Value) !session_codec.DurableSessionState {
    var context = try decodePart(alloc, value, "contextJson");
    errdefer context.deinit(alloc);
    if (context.context_history_start != 0) return error.InvalidJournalRecord;
    return context;
}

fn decodePart(alloc: std.mem.Allocator, value: std.json.Value, key: []const u8) !session_codec.DurableSessionState {
    if (value != .object or value.object.count() != 4) return error.InvalidJournalRecord;
    const version = value.object.get("v") orelse return error.InvalidJournalRecord;
    if (version != .integer or version.integer != 1) return error.InvalidJournalRecord;
    const state = value.object.get(key) orelse return error.InvalidJournalRecord;
    const id = value.object.get("id") orelse return error.InvalidJournalRecord;
    if (state != .string or id != .string) return error.InvalidJournalRecord;
    const bytes = state.string;
    try codec.validateJsonBounds(bytes);
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try session_codec.decodeState(alloc, &reader, .{
        .max_history_turns = 16_384,
        .max_value_bytes = codec.max_entry_bytes,
    });
    errdefer decoded.deinit(alloc);
    if (!std.mem.eql(u8, decoded.id, id.string)) return error.JournalConflict;
    if (decoded.recovery_checkpoint != null) return error.PendingTurnError;
    return decoded;
}

/// Snapshot formats before v4 retain a turn boundary. The event-log owner
/// supplies its exact hydrated model window through encodeWithContext instead.
pub fn legacyContext(alloc: std.mem.Allocator, history: []const types.HistoryTurn, start: usize) ![]types.HistoryTurn {
    if (start == 0) return alloc.dupe(types.HistoryTurn, history);
    if (start >= history.len or history[start] != .compacted_summary) return error.InvalidContextHistoryStart;
    var before: usize = 0;
    for (history[0..start]) |turn| if (turn != .compacted_summary) {
        before += 1;
    };
    const removed = history[start].compacted_summary.removed_turn_count;
    if (removed > before) return error.InvalidContextHistoryStart;
    var keep = before - removed;
    var retained_start = start;
    while (retained_start > 0 and keep > 0) {
        retained_start -= 1;
        if (history[retained_start] != .compacted_summary) keep -= 1;
    }
    var result: std.ArrayList(types.HistoryTurn) = .empty;
    errdefer result.deinit(alloc);
    try result.append(alloc, history[start]);
    for (history[retained_start..start]) |turn| if (turn != .compacted_summary) try result.append(alloc, turn);
    try result.appendSlice(alloc, history[start + 1 ..]);
    return result.toOwnedSlice(alloc);
}

test "journal witness native genesis retains history and metadata without request IDs" {
    const alloc = std.testing.allocator;
    const source: session_codec.DurableSessionState = .{
        .id = @constCast("0123456789abcdef0123456789abcdef"),
        .origin_workspace_root = @constCast("/tmp/journal-origin"),
        .workspace_root = @constCast("/tmp/journal-origin"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = try session_codec.parseConversationLanguage("en"),
        .preferences = .{ .model = @constCast("fixture/model"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 11,
        .total_output_tokens = 12,
    };
    var entry = try encode(alloc, source);
    defer entry.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 1), entry.entry.seq);
    try std.testing.expectEqual(codec.Kind.checkpoint, entry.entry.kind);
    try std.testing.expectEqual(@as(usize, 0), entry.payload.value.object.get("records").?.array.items.len);
    var decoded = try decodeBase(alloc, entry.payload.value.object.get("nativeBase").?);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings(source.id, decoded.id);
    try std.testing.expectEqualStrings(source.preferences.model, decoded.preferences.model);
    try std.testing.expectEqual(source.total_input_tokens, decoded.total_input_tokens);
    try std.testing.expectEqual(source.total_output_tokens, decoded.total_output_tokens);
}

test "journal witness native genesis preserves the archived transcript and exact retained model window" {
    const alloc = std.testing.allocator;
    const history = [_]types.HistoryTurn{
        .{ .assistant = .{ .user = .{ .text = @constCast("removed question") }, .assistant = @constCast("removed answer") } },
        .{ .compacted_summary = .{ .summary = @constCast("earlier summary"), .removed_turn_count = 1, .compaction_count = 1 } },
        .{ .assistant = .{ .user = .{ .text = @constCast("retained question") }, .assistant = @constCast("retained answer") } },
        .{ .compacted_summary = .{ .summary = @constCast("<context_handoff>active summary</context_handoff>"), .removed_turn_count = 1, .compaction_count = 2 } },
        .{ .assistant = .{ .user = .{ .text = @constCast("later question") }, .assistant = @constCast("later answer") } },
    };
    const source: session_codec.DurableSessionState = .{
        .id = @constCast("native-context"),
        .origin_workspace_root = @constCast("/tmp/original-workspace"),
        .workspace_root = @constCast("/tmp/current-workspace"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = .literal("en"),
        .preferences = .{ .model = @constCast("fixture/model"), .effort = .auto, .fast_mode = false },
        .history = @constCast(&history),
        .context_history_start = 3,
        .total_input_tokens = std.math.maxInt(u64),
        .total_output_tokens = 9_007_199_254_740_993,
    };
    var entry = try encode(alloc, source);
    defer entry.deinit(alloc);
    const base = entry.payload.value.object.get("nativeBase").?;
    var decoded = try decodeBase(alloc, base);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(source.total_input_tokens, decoded.total_input_tokens);
    try std.testing.expectEqual(source.total_output_tokens, decoded.total_output_tokens);
    try std.testing.expectEqualStrings(source.origin_workspace_root, decoded.origin_workspace_root);
    try std.testing.expectEqualStrings(source.workspace_root, decoded.workspace_root);
    try std.testing.expectEqual(history.len, decoded.history.len);
    try std.testing.expectEqualStrings("removed answer", decoded.history[0].assistant.assistant);
    var context = try decodeContext(alloc, base);
    defer context.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), context.history.len);
    try std.testing.expectEqualStrings(history[3].compacted_summary.summary, context.history[0].compacted_summary.summary);
    try std.testing.expectEqualStrings("retained answer", context.history[1].assistant.assistant);
    try std.testing.expectEqualStrings("later answer", context.history[2].assistant.assistant);

    const execution = @import("execution_journal.zig");
    const runtime = @import("../agent/runtime/journal_runtime.zig");
    var restored: execution.State = .{};
    defer restored.deinit(alloc);
    try restored.restore(alloc, entry.entry.seq, "checkpoint", entry.entry.bytes, &entry.entry.hash);
    try runtime.validateIncoming(alloc, &restored, entry.payload.value);
    const model_history = try runtime.restoreHistory(alloc, &restored);
    defer types.freeHistoryTurnSlice(alloc, model_history);
    const archive = try runtime.restoreArchiveHistory(alloc, &restored);
    defer types.freeHistoryTurnSlice(alloc, archive);
    try std.testing.expectEqual(context.history.len, model_history.len);
    try std.testing.expectEqual(history.len, archive.len);
    try std.testing.expectEqualStrings("removed question", archive[0].assistant.user.text);
    try std.testing.expectEqualStrings("retained question", model_history[1].assistant.user.text);

    const session = @import("session.zig");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var before: std.ArrayList(types.ChatMessage) = .empty;
    var after: std.ArrayList(types.ChatMessage) = .empty;
    try session.appendActiveContextHistoryChatMessages(arena.allocator(), &before, &history, 3);
    try session.appendHistoryChatMessages(arena.allocator(), &after, context.history);
    try std.testing.expectEqualStrings(
        try std.json.Stringify.valueAlloc(arena.allocator(), before.items, .{}),
        try std.json.Stringify.valueAlloc(arena.allocator(), after.items, .{}),
    );

    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn check(a: std.mem.Allocator, original: session_codec.DurableSessionState) !void {
            var encoded = try encode(a, original);
            defer encoded.deinit(a);
            var decoded_copy = try decodeBase(a, encoded.payload.value.object.get("nativeBase").?);
            decoded_copy.deinit(a);
        }
    }.check, .{source});
}
