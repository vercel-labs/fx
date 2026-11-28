//! The transcript window driving a real transcript runtime
//! (`transcript_window_shell.zig`): what a compaction leaves in memory, and
//! what stays while it is still on screen.

const std = @import("std");
const runtime_mod = @import("runtime.zig");
const transcript_store = @import("store.zig");
const source_preparation = @import("source_preparation.zig");
const frozen_prefix = @import("frozen_prefix.zig");
const types = @import("../../core/shared/types.zig");
const render_engine = @import("../render_engine.zig");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const full_transcript_screen = @import("../full_transcript_screen.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const result_store = @import("../../core/session/result_store.zig");
const session_adapter = @import("../../core/session/session_adapter.zig");

const TranscriptRuntime = runtime_mod.TranscriptRuntime;
const Allocator = std.mem.Allocator;

fn testRuntime(alloc: Allocator) TranscriptRuntime {
    return .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .owned_top_row = 1,
        .has_committed_frame = true,
        .detached_commit_alloc = alloc,
        .committed_frame_layout = .{ .terminal_cols = 80, .terminal_rows = 24 },
    };
}

fn runTurn(alloc: Allocator, runtime: *TranscriptRuntime, metrics: *types.Metrics, prompt: []const u8, answer: []const u8) !void {
    const text = try alloc.dupe(u8, prompt);
    defer alloc.free(text);
    _ = try runtime.writeUserPromptCard(alloc, metrics, .{ .text = text }, runtime.notebook.entries.items.len > 0, &.{});
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "● Read notes.txt\n", .tool_status);
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, metrics, answer);
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });
}

fn holds(runtime: *const TranscriptRuntime, needle: []const u8) bool {
    for (runtime.notebook.entries.items) |entry| switch (entry) {
        .user_turn => |value| if (std.mem.find(u8, value.turn.text, needle) != null) return true,
        .assistant_turn => |value| if (std.mem.find(u8, value.segments.text.items, needle) != null) return true,
        .raw_bytes => |value| if (std.mem.find(u8, value.bytes, needle) != null) return true,
        else => {},
    };
    return false;
}

/// The runtime's prepared source equals a full render of what it holds.
fn expectPreparedMatchesFull(alloc: Allocator, runtime: *TranscriptRuntime) !void {
    var resumed = try source_preparation.prepareTranscriptSource(runtime, alloc, null);
    defer resumed.deinit(alloc);
    var empty: frozen_prefix.FrozenPrefix = .{};
    defer empty.deinit();
    const previous = runtime.frozen_prefix_source;
    runtime.frozen_prefix_source = &empty;
    defer runtime.frozen_prefix_source = previous;
    var full = try source_preparation.prepareTranscriptSource(runtime, alloc, null);
    defer full.deinit(alloc);
    try std.testing.expectEqualDeep(full, resumed);
}

/// The window and the runtime agree on what is held.
fn expectWindowMatchesEntries(runtime: *const TranscriptRuntime) !void {
    const window = &runtime.transcript_window.?;
    try std.testing.expectEqual(runtime.notebook.entries.items.len, window.finished.items.len + window.pending_drops.items.len);
    var index: usize = 0;
    for (runtime.notebook.entries.items) |entry| {
        if (std.mem.findScalar(u32, window.pending_drops.items, entry.id()) != null) continue;
        try std.testing.expectEqual(window.finished.items[index], entry.id());
        index += 1;
    }
}

/// Commits the runtime's current transcript as a stable frame with no row
/// released into terminal history yet.
fn commitStableFrame(alloc: Allocator, runtime: *TranscriptRuntime) !void {
    std.debug.assert(runtime.transcript_commit_state == .invalid);
    var metrics: types.Metrics = .{};
    var flow = try source_preparation.prepareRetentionSource(runtime, alloc);
    defer flow.deinit(alloc);
    try flow.ensureLineIndex(alloc);
    var identity = try source_preparation.RetentionIdentity.capture(runtime, alloc, &flow);
    errdefer identity.deinit(alloc);
    const total = flow.transcript_visual_row_offsets[flow.transcript_visual_row_offsets.len - 1];
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(alloc, &metrics, &flow, .{ .top = 1, .bottom = 20 });
    defer prepared.deinit(alloc);
    const owned_flow = try alloc.dupe(u8, flow.bytes);
    errdefer alloc.free(owned_flow);
    runtime.transcript_commit_state = .{ .stable = .{
        .selection = prepared.selection,
        .visual_offset = total,
        .history_visual_offset = 0,
        .total_visual_rows = total,
        .flow = owned_flow,
        .retention_identity = identity,
        .cursor_row = prepared.cursor.cursor_row,
        .cursor_col = prepared.cursor.cursor_col,
        .occupied_last_row = prepared.selection.last_visible_row,
        .occupied_last_row_blank = prepared.selection.last_visible_row_blank,
        .layout_id = 1,
    } };
}

/// A frame the terminal accepted without scrolling.
fn committedFrameResult() render_engine.terminal_diff.FrameCommitResult {
    return .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = 1,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    };
}

/// How many of a frame's rows the terminal history holds after it.
const ReleasedRows = enum { none, all };

/// A frame that paints the runtime's entries. It paints `resume_flow`, the
/// pending resume source it borrows, or with null the entries' own flow.
fn transcriptFrame(
    alloc: Allocator,
    runtime: *TranscriptRuntime,
    resume_flow: ?[]u8,
    released: ReleasedRows,
) !runtime_mod.TranscriptTransition {
    var metrics: types.Metrics = .{};
    var flow = try source_preparation.prepareRetentionSource(runtime, alloc);
    defer flow.deinit(alloc);
    try flow.ensureLineIndex(alloc);
    const total = flow.transcript_visual_row_offsets[flow.transcript_visual_row_offsets.len - 1];
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(alloc, &metrics, &flow, .{ .top = 1, .bottom = 20 });
    defer prepared.deinit(alloc);
    var transition: runtime_mod.TranscriptTransition = .{
        .scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(24, 1),
        .document_append = .{},
        .materialized_without_append = .{},
        .target_flow = &.{},
        .target_cache = .empty,
        .target_cache_unchanged = true,
        .folded_summary_indices = &.{},
        .target_layout = .{ .terminal_rows = 24, .terminal_cols = 80 },
        .selection = prepared.selection,
        .visual_offset = total,
        .history_visual_offset = switch (released) {
            .none => 0,
            .all => total,
        },
        .total_visual_rows = total,
        .cursor_row = prepared.cursor.cursor_row,
        .cursor_col = prepared.cursor.cursor_col,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 1,
        .trace_transcript_frame = false,
        .trace_visible_rows = 1,
    };
    if (resume_flow) |bytes| {
        transition.target_flow = bytes;
        transition.target_flow_owned = false;
        return transition;
    }
    transition.target_flow = try alloc.dupe(u8, flow.bytes);
    errdefer alloc.free(transition.target_flow);
    transition.retention_identity = try source_preparation.RetentionIdentity.capture(runtime, alloc, &flow);
    return transition;
}

/// Gives the turn one `read_file` row per name, with the tool detail the
/// recap counts.
fn readFiles(alloc: Allocator, runtime: *TranscriptRuntime, metrics: *types.Metrics, names: []const []const u8) !void {
    for (names) |name| {
        const label = try alloc.print("Read {s}", .{name});
        defer alloc.free(label);
        const arguments_json = try alloc.print("{{\"path\":\"{s}\"}}", .{name});
        defer alloc.free(arguments_json);
        const entry_id = try runtime.writeCompletedToolStatusReturningEntryId(alloc, metrics, .completed, label, true);
        try runtime.attachHistoricalToolDetail(alloc, entry_id, .{
            .id = name,
            .name = "read_file",
            .arguments_json = arguments_json,
        }, .read, .{
            .tool_call_id = @constCast(name),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("file contents\n"),
            .output_bytes = 14,
            .stored_output_bytes = 14,
            .created_at_ms = 123,
        });
    }
}

test "the transcript window keeps all turns across compactions and turn ends" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    try runTurn(alloc, &runtime, &metrics, "FIRST_PROMPT", "FIRST_ANSWER\n");
    try runTurn(alloc, &runtime, &metrics, "SECOND_PROMPT", "SECOND_ANSWER\n");
    try std.testing.expect(holds(&runtime, "FIRST_PROMPT") and holds(&runtime, "SECOND_ANSWER"));
    try expectPreparedMatchesFull(alloc, &runtime);
    try expectWindowMatchesEntries(&runtime);

    // Between turns, a compaction keeps every turn in the current session held
    // across later turns and resizes.
    try runtime.transcriptWindowCompacted(alloc);
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try std.testing.expect(holds(&runtime, "FIRST_PROMPT") and holds(&runtime, "SECOND_ANSWER"));
    try expectWindowMatchesEntries(&runtime);

    try runTurn(alloc, &runtime, &metrics, "THIRD_PROMPT", "THIRD_ANSWER\n");
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try std.testing.expect(holds(&runtime, "FIRST_PROMPT") and holds(&runtime, "SECOND_ANSWER"));
    try std.testing.expect(holds(&runtime, "THIRD_PROMPT") and holds(&runtime, "THIRD_ANSWER"));
    try std.testing.expect(std.mem.find(u8, runtime.notebook.transcript.items, "FIRST_ANSWER") != null);
    try std.testing.expect(std.mem.find(u8, runtime.notebook.transcript.items, "THIRD_ANSWER") != null);
    try expectPreparedMatchesFull(alloc, &runtime);
    try expectWindowMatchesEntries(&runtime);
    try runtime.transcriptWindowScreenCleared(alloc);
    var reprinted = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer reprinted.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, reprinted.bytes, "FIRST_PROMPT") != null);
    try std.testing.expect(std.mem.find(u8, reprinted.bytes, "THIRD_ANSWER") != null);
}

test "the transcript window keeps entries on screen and after scrolling into terminal history across compactions" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "ON_SCREEN_PROMPT", "ON_SCREEN_ANSWER\n");
    try commitStableFrame(alloc, &runtime);
    const closed_cycle = runtime.notebook.entries.items.len;

    try runtime.transcriptWindowCompacted(alloc);
    try runTurn(alloc, &runtime, &metrics, "NEXT_PROMPT", "NEXT_ANSWER\n");
    try std.testing.expect(holds(&runtime, "ON_SCREEN_PROMPT") and holds(&runtime, "ON_SCREEN_ANSWER"));
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.pending_drops.items.len);
    try std.testing.expectEqual(closed_cycle * 2, runtime.notebook.entries.items.len);
    try expectWindowMatchesEntries(&runtime);

    const anchor = &runtime.transcript_commit_state.stable;
    anchor.history_visual_offset = anchor.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "ON_SCREEN_PROMPT"));
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.pending_drops.items.len);
    try expectWindowMatchesEntries(&runtime);
    var reprinted = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer reprinted.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, reprinted.bytes, "ON_SCREEN_PROMPT") != null);
}

test "a turn summary keeps its stored recap across compactions and scrolling into history" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    // Turn 1 reads three files. Each read's status row carries the tool
    // detail the recap counts, attached the way the app attaches it.
    const prompt = try alloc.dupe(u8, "READS_PROMPT");
    defer alloc.free(prompt);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
    const reads = [_]struct { call_id: []const u8, label: []const u8, arguments_json: []const u8 }{
        .{ .call_id = "read-a", .label = "Read a.txt", .arguments_json = "{\"path\":\"a.txt\"}" },
        .{ .call_id = "read-b", .label = "Read b.txt", .arguments_json = "{\"path\":\"b.txt\"}" },
        .{ .call_id = "read-c", .label = "Read c.txt", .arguments_json = "{\"path\":\"c.txt\"}" },
    };
    for (reads) |read| {
        const entry_id = try runtime.writeCompletedToolStatusReturningEntryId(alloc, &metrics, .completed, read.label, true);
        try runtime.attachHistoricalToolDetail(alloc, entry_id, .{
            .id = read.call_id,
            .name = "read_file",
            .arguments_json = read.arguments_json,
        }, .read, .{
            .tool_call_id = @constCast(read.call_id),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("file contents\n"),
            .output_bytes = 14,
            .stored_output_bytes = 14,
            .created_at_ms = 123,
        });
    }
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "READS_ANSWER\n");
    const summary_id = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });
    {
        var before = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
        defer before.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, before.bytes, "Explored 3 files") != null);
    }

    // The summary's first row is the history edge of the committed frame.
    // Rows above it go to terminal history; the summary's row stays on screen.
    try commitStableFrame(alloc, &runtime);
    var flow = try source_preparation.prepareRetentionSource(&runtime, alloc);
    defer flow.deinit(alloc);
    var summary_first_row: ?u32 = null;
    var owner: ?u32 = null;
    for (flow.line_provenance, 0..) |line, index| {
        owner = source_preparation.publication_owner(owner, line);
        if (owner == summary_id and summary_first_row == null) summary_first_row = flow.transcript_visual_row_offsets[index];
    }
    try std.testing.expect(summary_first_row != null);
    const anchor = &runtime.transcript_commit_state.stable;
    anchor.history_visual_offset = summary_first_row.?;

    // A compaction, then a turn that ends. Both the turn's entries and the
    // summary stay held, and the summary's stored recap keeps all three reads.
    try runtime.transcriptWindowCompacted(alloc);
    try runTurn(alloc, &runtime, &metrics, "NEXT_PROMPT", "NEXT_ANSWER\n");
    try std.testing.expect(holds(&runtime, "READS_PROMPT") and holds(&runtime, "Read a.txt"));
    var summary_held = false;
    for (runtime.notebook.entries.items) |entry| {
        if (entry.id() == summary_id) summary_held = true;
    }
    try std.testing.expect(summary_held);

    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, after.bytes, "Explored 3 files") != null);

    const later = &runtime.transcript_commit_state.stable;
    later.history_visual_offset = later.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "READS_PROMPT") and holds(&runtime, "Read a.txt"));
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.pending_drops.items.len);
    try expectWindowMatchesEntries(&runtime);
}

test "a compaction inside a turn leaves the turn summary's recap counting every file the turn read" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    const prompt = try alloc.dupe(u8, "SPLIT_PROMPT");
    defer alloc.free(prompt);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
    try readFiles(alloc, &runtime, &metrics, &.{ "a.txt", "b.txt", "c.txt" });
    try commitStableFrame(alloc, &runtime);
    const history_rows = runtime.transcript_commit_state.stable.total_visual_rows;
    runtime.transcript_commit_state.stable.history_visual_offset = history_rows;

    try runtime.transcriptWindowCompacted(alloc);
    try readFiles(alloc, &runtime, &metrics, &.{ "d.txt", "e.txt" });
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "SPLIT_ANSWER\n");
    try commitStableFrame(alloc, &runtime);
    runtime.transcript_commit_state.stable.history_visual_offset = history_rows;
    try std.testing.expect(holds(&runtime, "SPLIT_PROMPT") and holds(&runtime, "Read a.txt"));
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });

    try std.testing.expect(holds(&runtime, "SPLIT_PROMPT") and holds(&runtime, "Read a.txt"));
    try std.testing.expect(holds(&runtime, "Read d.txt") and holds(&runtime, "SPLIT_ANSWER"));
    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, after.bytes, "Explored 5 files") != null);
    try expectWindowMatchesEntries(&runtime);
}

test "a resize after a compaction inside a turn keeps all entries and the summary's recap" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    const prompt = try alloc.dupe(u8, "SPLIT_PROMPT");
    defer alloc.free(prompt);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
    try readFiles(alloc, &runtime, &metrics, &.{ "a.txt", "b.txt", "c.txt" });
    try commitStableFrame(alloc, &runtime);
    const history_rows = runtime.transcript_commit_state.stable.total_visual_rows;
    runtime.transcript_commit_state.stable.history_visual_offset = history_rows;

    try runtime.transcriptWindowCompacted(alloc);
    try readFiles(alloc, &runtime, &metrics, &.{ "d.txt", "e.txt" });
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "SPLIT_ANSWER\n");
    try commitStableFrame(alloc, &runtime);
    runtime.transcript_commit_state.stable.history_visual_offset = history_rows;
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });

    try runtime.transcriptWindowScreenCleared(alloc);
    try std.testing.expect(holds(&runtime, "SPLIT_PROMPT") and holds(&runtime, "Read a.txt"));
    try std.testing.expect(holds(&runtime, "Read d.txt") and holds(&runtime, "SPLIT_ANSWER"));
    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, after.bytes, "Explored 5 files") != null);
    try expectWindowMatchesEntries(&runtime);

    runtime.resetTranscriptAnchor("transcript_window_test_screen_reset");
    try commitStableFrame(alloc, &runtime);
    const later = &runtime.transcript_commit_state.stable;
    later.history_visual_offset = later.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "SPLIT_PROMPT") and holds(&runtime, "Read a.txt"));
    try std.testing.expect(holds(&runtime, "Read d.txt") and holds(&runtime, "SPLIT_ANSWER"));
    var whole = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer whole.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, whole.bytes, "Explored 5 files") != null);
    try expectWindowMatchesEntries(&runtime);

    try runtime.transcriptWindowCompacted(alloc);
    try runTurn(alloc, &runtime, &metrics, "LATER_PROMPT", "LATER_ANSWER\n");
    runtime.resetTranscriptAnchor("transcript_window_test_screen_reset");
    try commitStableFrame(alloc, &runtime);
    const closed = &runtime.transcript_commit_state.stable;
    closed.history_visual_offset = closed.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "SPLIT_PROMPT") and holds(&runtime, "Read a.txt") and holds(&runtime, "Read d.txt"));
    try std.testing.expect(holds(&runtime, "LATER_PROMPT"));
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.pending_drops.items.len);
    try expectWindowMatchesEntries(&runtime);
}

test "a turn that ends before its frame commits keeps all entries and its summary's recap" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    const prompt = try alloc.dupe(u8, "SPLIT_PROMPT");
    defer alloc.free(prompt);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
    try readFiles(alloc, &runtime, &metrics, &.{ "a.txt", "b.txt", "c.txt" });
    try commitStableFrame(alloc, &runtime);
    const history_rows = runtime.transcript_commit_state.stable.total_visual_rows;
    runtime.transcript_commit_state.stable.history_visual_offset = history_rows;

    try runtime.transcriptWindowCompacted(alloc);
    try readFiles(alloc, &runtime, &metrics, &.{ "d.txt", "e.txt" });
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "SPLIT_ANSWER\n");
    try std.testing.expect(runtime.transcript_commit_state == .invalid);
    try std.testing.expect(holds(&runtime, "SPLIT_PROMPT") and holds(&runtime, "Read a.txt"));
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });

    try std.testing.expect(holds(&runtime, "SPLIT_PROMPT") and holds(&runtime, "Read a.txt"));
    try std.testing.expect(holds(&runtime, "Read d.txt") and holds(&runtime, "SPLIT_ANSWER"));
    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, after.bytes, "Explored 5 files") != null);
    try expectWindowMatchesEntries(&runtime);
}

test "a turn that compacts mid-turn keeps its pre-compaction entries when it ends" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    const prompt = try alloc.dupe(u8, "COMPACT_PROMPT");
    defer alloc.free(prompt);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
    try readFiles(alloc, &runtime, &metrics, &.{ "a.txt", "b.txt", "c.txt" });
    try commitStableFrame(alloc, &runtime);
    const history_rows = runtime.transcript_commit_state.stable.total_visual_rows;
    runtime.transcript_commit_state.stable.history_visual_offset = history_rows;

    try runtime.transcriptWindowCompacted(alloc);
    try readFiles(alloc, &runtime, &metrics, &.{ "d.txt", "e.txt" });
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "COMPACT_ANSWER\n");
    try commitStableFrame(alloc, &runtime);
    runtime.transcript_commit_state.stable.history_visual_offset = history_rows;

    const entries_before_end = runtime.notebook.entries.items.len;
    try std.testing.expect(holds(&runtime, "COMPACT_PROMPT") and holds(&runtime, "Read a.txt"));

    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });

    try std.testing.expect(holds(&runtime, "COMPACT_PROMPT") and holds(&runtime, "Read a.txt"));
    try std.testing.expect(holds(&runtime, "Read d.txt") and holds(&runtime, "COMPACT_ANSWER"));
    try std.testing.expectEqual(entries_before_end + 1, runtime.notebook.entries.items.len);
    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, after.bytes, "COMPACT_PROMPT") != null);
    try std.testing.expect(std.mem.find(u8, after.bytes, "Explored 5 files") != null);
    try expectWindowMatchesEntries(&runtime);
}

test "a turn summary keeps its recap identical across compactions and screen scrolling" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    const prompt = try alloc.dupe(u8, "RECAP_PROMPT");
    defer alloc.free(prompt);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
    try readFiles(alloc, &runtime, &metrics, &.{"a.txt"});
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "MID_ANSWER\n");
    try runtime.transcriptWindowCompacted(alloc);
    try readFiles(alloc, &runtime, &metrics, &.{ "b.txt", "c.txt" });
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "RECAP_ANSWER\n");
    try commitStableFrame(alloc, &runtime);
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });
    try std.testing.expect(holds(&runtime, "RECAP_PROMPT") and holds(&runtime, "Read a.txt"));

    var before = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer before.deinit(alloc);
    const summary_before = findLineContaining(before.bytes, "Explored 3 files") orelse return error.MissingSummaryLine;

    const anchor = &runtime.transcript_commit_state.stable;
    anchor.history_visual_offset = anchor.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "RECAP_PROMPT") and holds(&runtime, "Read a.txt"));
    try std.testing.expect(holds(&runtime, "Read c.txt"));

    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    const summary_after = findLineContaining(after.bytes, "Explored 3 files") orelse return error.MissingSummaryLine;
    try std.testing.expectEqualStrings(summary_before, summary_after);
    try expectWindowMatchesEntries(&runtime);
}

fn findLineContaining(bytes: []const u8, needle: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, needle) != null) return line;
    }
    return null;
}

/// The window holds every entry it has reported (`seen_through`), once each,
/// in `finished` or `pending_drops`. Entries after `seen_through` are not
/// reported yet, so they are not counted.
fn expectReportedEntriesHeld(runtime: *const TranscriptRuntime) !void {
    const window = &runtime.transcript_window.?;
    var reported: usize = 0;
    for (runtime.notebook.entries.items) |entry| {
        if (entry.id() <= window.seen_through) reported += 1;
    }
    try std.testing.expectEqual(reported, window.finished.items.len + window.pending_drops.items.len);
}

test "a failed allocation when a turn summary is added frees its bytes once" {
    // A failed allocation at any point of appendTurnSummaryEntry must free the
    // summary's bytes once. std.testing's allocator panics on a double free and
    // reports leaks, so the sweep fails if either happens.
    const backing = testing_allocator.no_resize;
    var induced_failures: usize = 0;
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const alloc = failing.allocator();
        var runtime = testRuntime(alloc);
        defer runtime.deinit(alloc);
        var metrics: types.Metrics = .{};
        try runtime.enableTranscriptWindow(alloc, true);

        // A turn that is split by a compaction and ends before any frame
        // commits, so the commit state is invalid when its summary is appended.
        const prompt = try alloc.dupe(u8, "OOM_PROMPT");
        defer alloc.free(prompt);
        _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
        try readFiles(alloc, &runtime, &metrics, &.{ "a.txt", "b.txt" });
        try runtime.transcriptWindowCompacted(alloc);
        try readFiles(alloc, &runtime, &metrics, &.{ "d.txt", "e.txt" });
        _ = try runtime.appendAssistantTurnEntry(alloc);
        _ = try runtime.streamAssistantChunk(alloc, &metrics, "OOM_ANSWER\n");
        // The window reports the turn's entries before the summary is appended.
        try runtime.syncTranscriptWindow(alloc);
        try expectReportedEntriesHeld(&runtime);
        try std.testing.expect(runtime.transcript_commit_state == .invalid);

        failing.fail_index = failing.alloc_index + fail_after;
        const result = runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (induced) {
            induced_failures += 1;
        }
        if (result) |_| {
            if (!induced) {
                try expectWindowMatchesEntries(&runtime);
                break;
            }
        } else |err| {
            if (!induced) return err;
        }
    }
    try std.testing.expect(induced_failures > 0);
}

test "a failed allocation when a turn summary is added keeps the window in step with the transcript" {
    // A summary whose sync fails partway leaves the window in step with the
    // entries, so the next sync brings both to the same state.
    const backing = testing_allocator.no_resize;
    var induced_failures: usize = 0;
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const alloc = failing.allocator();
        var runtime = testRuntime(alloc);
        defer runtime.deinit(alloc);
        var metrics: types.Metrics = .{};
        try runtime.enableTranscriptWindow(alloc, true);

        // A turn that is split by a compaction and ends before any frame
        // commits, so the commit state is invalid when its summary is appended.
        const prompt = try alloc.dupe(u8, "OOM_PROMPT");
        defer alloc.free(prompt);
        _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
        try readFiles(alloc, &runtime, &metrics, &.{ "a.txt", "b.txt" });
        try runtime.transcriptWindowCompacted(alloc);
        try readFiles(alloc, &runtime, &metrics, &.{ "d.txt", "e.txt" });
        _ = try runtime.appendAssistantTurnEntry(alloc);
        _ = try runtime.streamAssistantChunk(alloc, &metrics, "OOM_ANSWER\n");
        // The window reports the turn's entries before the summary is appended.
        try runtime.syncTranscriptWindow(alloc);
        try expectReportedEntriesHeld(&runtime);
        try std.testing.expect(runtime.transcript_commit_state == .invalid);

        failing.fail_index = failing.alloc_index + fail_after;
        const result = runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (!induced) {
            _ = try result;
            try expectWindowMatchesEntries(&runtime);
            break;
        }
        induced_failures += 1;
        // The caller's error is not checked here: the window must match the entries after it either way.
        _ = result catch {};
        try expectReportedEntriesHeld(&runtime);
        try runtime.syncTranscriptWindow(alloc);
        try expectWindowMatchesEntries(&runtime);
    }
    try std.testing.expect(induced_failures > 0);
}

test "a failed allocation when the screen clears keeps every held drop" {
    // A screen clear that fails keeps each held drop either in the window's
    // pending list or out of the entries, so none is lost.
    const backing = testing_allocator.no_resize;
    var induced_failures: usize = 0;
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const alloc = failing.allocator();
        var runtime = testRuntime(alloc);
        defer runtime.deinit(alloc);
        var metrics: types.Metrics = .{};
        try runtime.enableTranscriptWindow(alloc, true);
        try runTurn(alloc, &runtime, &metrics, "HELD_PROMPT", "HELD_ANSWER\n");
        try commitStableFrame(alloc, &runtime);
        try runtime.transcriptWindowCompacted(alloc);
        try runTurn(alloc, &runtime, &metrics, "NEXT_PROMPT", "NEXT_ANSWER\n");
        const window = &runtime.transcript_window.?;
        const move_count = @min(@as(usize, 4), window.finished.items.len);
        for (0..move_count) |_| {
            try window.pending_drops.append(alloc, window.finished.orderedRemove(0));
            window.base += 1;
        }
        try std.testing.expect(window.pending_drops.items.len > 0);
        const pending_before = try alloc.dupe(u32, window.pending_drops.items);
        defer alloc.free(pending_before);

        failing.fail_index = failing.alloc_index + fail_after;
        const result = runtime.transcriptWindowScreenCleared(alloc);
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (!induced) {
            try result;
            try std.testing.expectEqual(@as(usize, 0), window.pending_drops.items.len);
            try expectWindowMatchesEntries(&runtime);
            break;
        }
        induced_failures += 1;
        // The caller's error is not checked here: every held drop must still be accounted for either way.
        _ = result catch {};
        try expectWindowMatchesEntries(&runtime);
        for (pending_before) |id| {
            const still_held = std.mem.findScalar(u32, window.pending_drops.items, id) != null;
            const in_notebook = for (runtime.notebook.entries.items) |entry| {
                if (entry.id() == id) break true;
            } else false;
            try std.testing.expect(still_held or !in_notebook);
        }
    }
    try std.testing.expect(induced_failures > 0);
}

test "a cleared transcript starts the transcript window over" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_CLEAR", "ANSWER\n");
    transcript_store.clearTranscript(&runtime, alloc);
    try std.testing.expect(!holds(&runtime, "BEFORE_CLEAR"));
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.finished.items.len);
    try runTurn(alloc, &runtime, &metrics, "AFTER_CLEAR", "ANSWER\n");
    try runTurn(alloc, &runtime, &metrics, "STILL_HELD", "ANSWER\n");
    try runtime.transcriptWindowCompacted(alloc);
    try runTurn(alloc, &runtime, &metrics, "NEXT", "ANSWER\n");
    try std.testing.expect(holds(&runtime, "AFTER_CLEAR") and holds(&runtime, "STILL_HELD"));
    try std.testing.expect(holds(&runtime, "NEXT"));
    try expectWindowMatchesEntries(&runtime);
}

test "a transcript window drop never removes a pinned tool line" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    const done = try runtime.appendRawTranscriptEntryClassified(alloc, "● Read done.txt\n", .tool_status);
    const pinned = try runtime.appendRawTranscriptEntryClassified(alloc, "● Running\n", .tool_status);
    for (runtime.notebook.entries.items) |*entry| {
        if (entry.id() == pinned) entry.raw_bytes.lifecycle_pinned = true;
    }
    try std.testing.expect(try transcript_store.dropEntriesAtomic(&runtime, alloc, &.{ done, pinned }));
    try std.testing.expect(!holds(&runtime, "done.txt"));
    try std.testing.expect(holds(&runtime, "Running"));
}

test "a screen clear for resize replays every held entry of the current session" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "HELD_PROMPT", "HELD_ANSWER\n");
    try commitStableFrame(alloc, &runtime);
    try runtime.transcriptWindowCompacted(alloc);
    try runTurn(alloc, &runtime, &metrics, "NEXT_PROMPT", "NEXT_ANSWER\n");
    try std.testing.expect(holds(&runtime, "HELD_PROMPT"));
    try runtime.transcriptWindowScreenCleared(alloc);
    try std.testing.expect(holds(&runtime, "HELD_PROMPT"));
    try std.testing.expect(holds(&runtime, "NEXT_PROMPT"));
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.pending_drops.items.len);
    try expectWindowMatchesEntries(&runtime);
}

test "a resize between a compaction and the next turn end replays the closed cycle" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "CLOSED_PROMPT", "CLOSED_ANSWER\n");
    try commitStableFrame(alloc, &runtime);
    try runtime.transcriptWindowCompacted(alloc);
    try runtime.transcriptWindowScreenCleared(alloc);
    try std.testing.expect(holds(&runtime, "CLOSED_PROMPT") and holds(&runtime, "CLOSED_ANSWER"));
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try expectWindowMatchesEntries(&runtime);
}

const full_transcript_page = @import("../../core/output/full_transcript_page.zig");

fn rawEntries(alloc: Allocator, runtime: *TranscriptRuntime, texts: []const []const u8) !void {
    for (texts) |text| _ = try runtime.appendRawTranscriptEntryClassified(alloc, text, .tool_status);
}

fn archivedCycle(alloc: Allocator, back: u32, texts: []const []const u8) !TranscriptRuntime {
    var archived = testRuntime(alloc);
    archived.notebook.next_entry_id = runtime_mod.archiveEntryIdBase(back);
    try rawEntries(alloc, &archived, texts);
    return archived;
}

fn pageTexts(alloc: Allocator, runtime: *TranscriptRuntime, anchor: full_transcript_page.Anchor) ![]const u8 {
    var source = try runtime.snapshotFullTranscriptPage(.{ .anchor = anchor, .content_revision = 0, .cols = 80 }, null, null);
    defer source.deinit(std.heap.c_allocator);
    var text: std.ArrayList(u8) = .empty;
    for (source.entries.items) |entry| try text.appendSlice(alloc, entry.raw_bytes.bytes);
    return text.toOwnedSlice(alloc);
}

test "transcript window: Ctrl+O shows the cycle before the compaction with the new one" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try rawEntries(alloc, &runtime, &.{ "held one\n", "held two\n" });
    runtime.transcript_archive_available = true;
    try std.testing.expect(runtime.ctrlOJoinsPreviousCycle());
    // Ctrl+O is opening, so the cycles it reads stay whole.
    _ = runtime.requestFullTranscriptOpen();

    // The newest pages need the cycle before the compaction from the log.
    try std.testing.expectError(error.TranscriptArchiveNotLoaded, runtime.snapshotFullTranscriptPage(.{ .anchor = .tail, .content_revision = 0, .cols = 80 }, null, null));
    runtime.moveToFullTranscriptPage(.{ .entry_index = 0 }, .first);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);

    // Once it is installed the newest page shows both cycles, older first.
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{ "older one\n", "older two\n", "older three\n" }), false);
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    try std.testing.expectEqual(@as(usize, 0), runtime.full_transcript_page_anchor.entry_index);
    const joined = try pageTexts(alloc, &runtime, .tail);
    defer alloc.free(joined);
    try std.testing.expectEqualStrings("older one\nolder two\nolder three\nheld one\nheld two\n", joined);
    const joined_range: full_transcript_page.SourceRange = .{ .start = 0, .end = 5 };

    // Above it, the cycles before come one at a time; the oldest has nothing
    // above; below each is the next newer one and then the joined view.
    const further = runtime.olderPageAnchor(.{ .entry_index = 0 }, joined_range).?;
    try std.testing.expectEqual(@as(u32, 2), further.archive.back);
    runtime.moveToFullTranscriptPage(further, .last);
    try std.testing.expectEqual(@as(?u32, 2), runtime.transcript_archive_request);
    try runtime.installTranscriptArchive(alloc, 2, false, try archivedCycle(alloc, 2, &.{"oldest\n"}), false);
    try std.testing.expectEqual(@as(u32, 2), runtime.transcript_archive.?.back);
    const oldest_range: full_transcript_page.SourceRange = .{ .start = 0, .end = 1 };
    try std.testing.expectEqual(@as(?full_transcript_page.Anchor, null), runtime.olderPageAnchor(runtime.full_transcript_page_anchor, oldest_range));
    const oldest = try pageTexts(alloc, &runtime, runtime.full_transcript_page_anchor);
    defer alloc.free(oldest);
    try std.testing.expectEqualStrings("oldest\n", oldest);
    const back_down = runtime.newerPageAnchor(runtime.full_transcript_page_anchor, oldest_range).?;
    try std.testing.expectEqual(@as(usize, 0), back_down.entry_index);

    // Back down, the joined view loads its cycle again and lands on its top.
    runtime.moveToFullTranscriptPage(back_down, .first);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{ "older one\n", "older two\n", "older three\n" }), false);
    try std.testing.expectEqual(@as(usize, 0), runtime.full_transcript_page_anchor.entry_index);
    try std.testing.expectEqual(@as(?u32, runtime_mod.archiveEntryIdBase(1)), runtime.full_transcript.bookmark_entry_id);

    // A failed load returns Ctrl+O to the held entries; closing frees the cycle.
    runtime.moveToFullTranscriptPage(further, .last);
    runtime.failTranscriptArchive();
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    try std.testing.expectEqual(@as(usize, 0), runtime.full_transcript_page_anchor.entry_index);
    try std.testing.expect(runtime.transcript_archive_failed);
    // The next cycle that loads takes the notice away, and so does closing.
    runtime.moveToFullTranscriptPage(back_down, .first);
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{ "older one\n", "older two\n", "older three\n" }), false);
    try std.testing.expect(!runtime.transcript_archive_failed);
    // A cycle read across a damaged log line says so from then on, even
    // after an undamaged cycle loads.
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{ "older one\n", "older two\n", "older three\n" }), true);
    try std.testing.expect(runtime.transcript_archive_damaged);
    try std.testing.expect(!runtime.transcript_archive_failed);
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{ "older one\n", "older two\n", "older three\n" }), false);
    try std.testing.expect(runtime.transcript_archive_damaged);
    // Damage that hides the requested cycle ends the request, as a failed
    // load does, but without the retry.
    runtime.moveToFullTranscriptPage(further, .last);
    try std.testing.expectEqual(@as(?u32, 2), runtime.transcript_archive_request);
    runtime.damageTranscriptArchive();
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    try std.testing.expectEqual(@as(usize, 0), runtime.full_transcript_page_anchor.entry_index);
    try std.testing.expect(runtime.transcript_archive_damaged);
    try std.testing.expect(!runtime.transcript_archive_failed);
    // Closing takes the failed-load notice away, but the damaged line is
    // still in the log, so the damage notice stays until the transcript is
    // cleared.
    runtime.moveToFullTranscriptPage(further, .last);
    runtime.failTranscriptArchive();
    runtime.closeFullTranscriptState();
    try std.testing.expect(!runtime.transcript_archive_failed);
    try std.testing.expect(runtime.transcript_archive_damaged);
    // The cycle the newest pages join stays for the next open.
    try std.testing.expectEqual(@as(u32, 1), runtime.transcript_archive.?.back);
    try std.testing.expect(runtime.full_transcript_page_anchor == .tail);
    runtime.clearFullTranscriptDetails(alloc);
    try std.testing.expect(!runtime.transcript_archive_damaged);
    try std.testing.expect(runtime.transcript_archive == null);
}

test "transcript window: Ctrl+O pages older cycles from the log in a resumed session" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    try rawEntries(alloc, &runtime, &.{ "previous cycle\n", "new cycle\n" });
    try runtime.transcriptWindowResumed(alloc, false);
    runtime.transcript_archive_available = true;
    try std.testing.expect(runtime.ctrlOJoinsPreviousCycle());
    _ = runtime.requestFullTranscriptOpen();
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{"joined cycle\n"}), false);
    const held = try pageTexts(alloc, &runtime, .tail);
    defer alloc.free(held);
    try std.testing.expectEqualStrings("joined cycle\nprevious cycle\nnew cycle\n", held);
    const held_range: full_transcript_page.SourceRange = .{ .start = 0, .end = 3 };
    const older = runtime.olderPageAnchor(.{ .entry_index = 0 }, held_range).?;
    try std.testing.expectEqual(@as(u32, 2), older.archive.back);
    runtime.moveToFullTranscriptPage(older, .last);
    try runtime.installTranscriptArchive(alloc, 2, false, try archivedCycle(alloc, 2, &.{"before both\n"}), false);
    try std.testing.expectEqual(@as(usize, 0), runtime.full_transcript_page_anchor.archive.entry_index);
    const below = runtime.newerPageAnchor(runtime.full_transcript_page_anchor, .{ .start = 0, .end = 1 }).?;
    try std.testing.expectEqual(@as(usize, 0), below.entry_index);
}

test "transcript window: Ctrl+O pages leave out entries still held only for the screen" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    try rawEntries(alloc, &runtime, &.{ "older cycle\n", "newer cycle\n" });
    const window = &runtime.transcript_window.?;
    try window.pending_drops.append(alloc, runtime.notebook.entries.items[0].id());
    var source = try runtime.snapshotFullTranscriptPage(.{ .anchor = .tail, .content_revision = 0, .cols = 80 }, null, null);
    defer source.deinit(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 1), source.entries.items.len);
    try std.testing.expectEqual(runtime.notebook.entries.items[1].id(), source.entries.items[0].id());
}

const io_mod = @import("../../core/shared/io.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const command_output_runtime = @import("command_output_runtime.zig");

test "transcript window: each command's output is bounded on its own" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());
    const alloc = std.testing.allocator;
    // Room for six short lines per command.
    const cap = 6 * command_output_runtime.commandOutputLineRetainedBytes("line-00".len);
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .notebook = .{ .max_transcript_bytes = 4096, .command_output_block_cap = cap },
    };
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);

    var metrics = types.Metrics{};
    const styles: transcript_blocks.Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var line: [16]u8 = undefined;
    for (0..40) |index| {
        try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, try std.mem.print(&line, "line-{d:0>2}\n", .{index}), true);
    }
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    const first = runtime.notebook.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 40), first.total_lines);
    try std.testing.expect(first.retention_overflow);
    try std.testing.expect(first.lines.items.len < first.total_lines);

    // The next command keeps all of its output though the transcript holds
    // more than the cap.
    for (0..3) |index| {
        try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, try std.mem.print(&line, "next-{d}\n", .{index}), true);
    }
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    try std.testing.expectEqual(@as(usize, 2), runtime.notebook.command_output_blocks.items.len);
    const second = runtime.notebook.command_output_blocks.items[1];
    try std.testing.expect(!second.retention_overflow);
    try std.testing.expectEqual(@as(usize, 3), second.total_lines);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) > cap);
}

/// An older cycle of `count` entries, `older 0` first.
fn numberedCycle(alloc: Allocator, count: usize) !TranscriptRuntime {
    var archived = testRuntime(alloc);
    errdefer archived.deinit(alloc);
    archived.notebook.next_entry_id = runtime_mod.archiveEntryIdBase(1);
    var buf: [32]u8 = undefined;
    for (0..count) |index| {
        _ = try archived.appendRawTranscriptEntryClassified(alloc, try std.mem.print(&buf, "older {d}\n", .{index}), .tool_status);
    }
    return archived;
}

test "transcript window: between turns the newest Ctrl+O page reads the cycle it joins, and keeps only what it shows" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    try rawEntries(alloc, &runtime, &.{"held\n"});
    runtime.transcript_archive_available = true;

    // During a turn, a closed Ctrl+O reads nothing from the log.
    runtime.transcript_window.?.state.turn_open = true;
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    // Between turns it asks for the cycle the newest page joins, so the
    // next Ctrl+O opens without reading the log.
    runtime.transcript_window.?.state.turn_open = false;
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);

    // Read while closed, the cycle keeps only what the newest page shows:
    // a page of 256 entries, which the held one ends.
    try runtime.installTranscriptArchive(alloc, 1, true, try numberedCycle(alloc, 300), false);
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    try std.testing.expectEqual(@as(usize, 255), runtime.transcript_archive.?.runtime.notebook.entries.items.len);
    try std.testing.expectEqual(@as(usize, 45), runtime.transcript_archive.?.trimmed);
    const newest = try pageTexts(alloc, &runtime, .tail);
    defer alloc.free(newest);
    try std.testing.expect(std.mem.startsWith(u8, newest, "older 45\nolder 46\n"));
    try std.testing.expect(std.mem.endsWith(u8, newest, "older 299\nheld\n"));

    // A page that reaches into what was let go reads the whole cycle again,
    // whose indexes are the same, and lands on the entry it asked for.
    _ = runtime.requestFullTranscriptOpen();
    try std.testing.expectError(error.TranscriptArchiveNotLoaded, runtime.snapshotFullTranscriptPage(.{ .anchor = .{ .entry_index = 44 }, .content_revision = 0, .cols = 80 }, null, null));
    runtime.moveToFullTranscriptPage(.{ .entry_index = 44 }, .last);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);
    try runtime.installTranscriptArchive(alloc, 1, true, try numberedCycle(alloc, 300), false);
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_archive.?.trimmed);
    try std.testing.expectEqual(@as(?u32, runtime_mod.archiveEntryIdBase(1) + 44), runtime.full_transcript.bookmark_entry_id);
    const above = try pageTexts(alloc, &runtime, .{ .entry_index = 44 });
    defer alloc.free(above);
    try std.testing.expect(std.mem.startsWith(u8, above, "older 0\n"));

    // Closing trims it again.
    runtime.closeFullTranscriptState();
    try std.testing.expectEqual(@as(usize, 45), runtime.transcript_archive.?.trimmed);

    // A compaction makes that cycle two back: it goes, and a read started
    // before it is stale.
    const generation = runtime.transcript_archive_generation;
    try runtime.transcriptWindowCompacted(alloc);
    try std.testing.expect(runtime.transcript_archive == null);
    try std.testing.expect(runtime.transcript_archive_generation != generation);
}

test "transcript window: when the held entries fill the newest page, the joined cycle keeps none of its entries" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    var buf: [32]u8 = undefined;
    for (0..full_transcript_page.max_source_entries) |index| {
        _ = try runtime.appendRawTranscriptEntryClassified(alloc, try std.mem.print(&buf, "held {d}\n", .{index}), .tool_status);
    }
    runtime.transcript_archive_available = true;
    try runtime.installTranscriptArchive(alloc, 1, true, try numberedCycle(alloc, 3), false);
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_archive.?.runtime.notebook.entries.items.len);
    try std.testing.expectEqual(@as(usize, 3), runtime.transcript_archive.?.trimmed);
    const newest = try pageTexts(alloc, &runtime, .tail);
    defer alloc.free(newest);
    try std.testing.expect(std.mem.startsWith(u8, newest, "held 0\n"));
    try std.testing.expect(std.mem.endsWith(u8, newest, "held 255\n"));
    // The page above reaches the cycle, which then loads whole.
    _ = runtime.requestFullTranscriptOpen();
    runtime.moveToFullTranscriptPage(.{ .entry_index = 2 }, .last);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);
}

test "transcript window: a joined cycle that cannot keep a clean newest page goes, and is not read again until it changes" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    try rawEntries(alloc, &runtime, &.{"held\n"});
    runtime.transcript_archive_available = true;
    // A pinned entry stays through a drop, so trimming would leave a gap.
    var archived = try numberedCycle(alloc, 300);
    archived.notebook.entries.items[0].raw_bytes.lifecycle_pinned = true;
    try runtime.installTranscriptArchive(alloc, 1, true, archived, false);
    try std.testing.expect(runtime.transcript_archive == null);
    // Reading it again would trim it the same way: the newest page waits
    // for Ctrl+O to open.
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    _ = runtime.requestFullTranscriptOpen();
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);
    runtime.closeFullTranscriptState();
    // In a resumed session, a new cycle in memory still allows joining the archive.
    try runtime.transcriptWindowResumed(alloc, false);
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);
}

test "transcript window: a cycle read for a Ctrl+O that closed since stays only when the newest page joins it" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    try rawEntries(alloc, &runtime, &.{"held\n"});
    try runtime.transcriptWindowResumed(alloc, false);
    runtime.transcript_archive_available = true;
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{"joined\n"}), false);
    // An older page's cycle that finished reading after the close goes, and
    // the joined one stays.
    try runtime.installTranscriptArchive(alloc, 2, false, try archivedCycle(alloc, 2, &.{"oldest\n"}), false);
    try std.testing.expectEqual(@as(u32, 1), runtime.transcript_archive.?.back);
    // A failed read for a closed Ctrl+O says nothing, and the newest page
    // stops asking until the cycle changes.
    runtime.discardTranscriptArchive();
    runtime.failTranscriptArchive();
    try std.testing.expect(!runtime.transcript_archive_failed);
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    try runtime.transcriptWindowResumed(alloc, false);
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);
}

test "transcript window: the cycle Ctrl+O read moves with its transcript when another agent's takes the screen" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try rawEntries(alloc, &runtime, &.{"held\n"});
    runtime.transcript_archive_available = true;
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{"mine\n"}), false);
    var hidden: runtime_mod.TranscriptSlot = .{};
    defer TranscriptRuntime.deinitSlot(&hidden, alloc);
    runtime.swapSlot(&hidden);
    try std.testing.expect(runtime.transcript_archive == null);
    runtime.swapSlot(&hidden);
    try std.testing.expectEqual(@as(u32, 1), runtime.transcript_archive.?.back);
}

test "a transcript window drop that runs out of memory leaves the transcript as it was" {
    const backing = std.testing.allocator;
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const alloc = failing.allocator();
        var runtime = testRuntime(alloc);
        defer runtime.deinit(alloc);
        var metrics: types.Metrics = .{};
        try runTurn(alloc, &runtime, &metrics, "DROPPED_PROMPT", "DROPPED_ANSWER\n");
        const dropped_count = runtime.notebook.entries.items.len;
        try runTurn(alloc, &runtime, &metrics, "KEPT_PROMPT", "KEPT_ANSWER\n");
        try commitStableFrame(alloc, &runtime);
        // The drop takes the atomic path: a copy, then one commit.
        const identity = runtime.committedRetentionIdentity() orelse return error.TestExpectedCommittedSource;
        try std.testing.expect(identity.lines.len > 0 and runtime.retentionSourceCols() != null);

        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(backing);
        for (runtime.notebook.entries.items) |entry| try ids.append(backing, entry.id());
        const transcript_before = try backing.dupe(u8, runtime.notebook.transcript.items);
        defer backing.free(transcript_before);

        failing.fail_index = failing.alloc_index + fail_after;
        const result = transcript_store.dropEntriesAtomic(&runtime, alloc, ids.items[0..dropped_count]);
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (result) |changed| {
            try std.testing.expect(!induced);
            try std.testing.expect(changed);
            try std.testing.expect(!holds(&runtime, "DROPPED_PROMPT") and holds(&runtime, "KEPT_PROMPT"));
            try std.testing.expectEqual(ids.items.len - dropped_count, runtime.notebook.entries.items.len);
            break;
        } else |err| {
            // A writer over a growing buffer reports a failed allocation as
            // WriteFailed.
            try std.testing.expect(induced);
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            try std.testing.expectEqualStrings(transcript_before, runtime.notebook.transcript.items);
            try std.testing.expectEqual(ids.items.len, runtime.notebook.entries.items.len);
            for (ids.items, runtime.notebook.entries.items) |id, entry| try std.testing.expectEqual(id, entry.id());
        }
    }
    // The drop allocates, so some of the runs above failed inside it.
    try std.testing.expect(fail_after > 0);
}

test "a transcript window drop that runs out of memory before a frame commits leaves the transcript as it was" {
    // No frame has committed, so there is no committed source to rebase onto, and a
    // failed allocation must still leave the transcript and its entries as they were.
    const backing = testing_allocator.no_resize;
    var induced_failures: usize = 0;
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const alloc = failing.allocator();
        var runtime = testRuntime(alloc);
        defer runtime.deinit(alloc);
        var metrics: types.Metrics = .{};
        try runTurn(alloc, &runtime, &metrics, "DROPPED_PROMPT", "DROPPED_ANSWER\n");
        const dropped_count = runtime.notebook.entries.items.len;
        try runTurn(alloc, &runtime, &metrics, "KEPT_PROMPT", "KEPT_ANSWER\n");
        try std.testing.expect(runtime.transcript_commit_state == .invalid);

        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(backing);
        for (runtime.notebook.entries.items) |entry| try ids.append(backing, entry.id());
        const transcript_before = try backing.dupe(u8, runtime.notebook.transcript.items);
        defer backing.free(transcript_before);

        failing.fail_index = failing.alloc_index + fail_after;
        const result = transcript_store.dropEntriesAtomic(&runtime, alloc, ids.items[0..dropped_count]);
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (induced) induced_failures += 1;
        if (result) |changed| {
            try std.testing.expect(!induced);
            try std.testing.expect(changed);
            try std.testing.expect(!holds(&runtime, "DROPPED_PROMPT") and holds(&runtime, "KEPT_PROMPT"));
            try std.testing.expect(!std.mem.eql(u8, transcript_before, runtime.notebook.transcript.items));
            try std.testing.expectEqual(ids.items.len - dropped_count, runtime.notebook.entries.items.len);
            break;
        } else |err| {
            try std.testing.expect(induced);
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            try std.testing.expectEqualStrings(transcript_before, runtime.notebook.transcript.items);
            try std.testing.expectEqual(ids.items.len, runtime.notebook.entries.items.len);
            for (ids.items, runtime.notebook.entries.items) |id, entry| try std.testing.expectEqual(id, entry.id());
        }
    }
    try std.testing.expect(induced_failures > 0);
}

test "a resume that brings back the cycle before the newest compaction keeps it across later turns and resizes" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_COMPACT", "ANSWER\n");
    runtime.notebook.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, runtime.notebook.transcript.items),
    );
    try runtime.transcriptWindowResumed(alloc, true);
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    if (runtime.notebook.pending_resume_source) |*source| source.deinit(alloc);
    runtime.notebook.pending_resume_source = null;
    try commitStableFrame(alloc, &runtime);
    const anchor = &runtime.transcript_commit_state.stable;
    anchor.history_visual_offset = anchor.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try runtime.transcriptWindowScreenCleared(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try runTurn(alloc, &runtime, &metrics, "AFTER_RESUME", "REPLY\n");
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try std.testing.expect(holds(&runtime, "AFTER_RESUME"));
    try expectWindowMatchesEntries(&runtime);
    var reprinted = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer reprinted.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, reprinted.bytes, "BEFORE_COMPACT") != null);
}

test "a resume from the session picker keeps the cycle before the newest compaction through its screen reset and later turns" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_COMPACT", "ANSWER\n");
    runtime.notebook.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, runtime.notebook.transcript.items),
    );
    try runtime.transcriptWindowResumed(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "AFTER_RESUME", "REPLY\n");
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try runtime.transcriptWindowScreenCleared(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try expectWindowMatchesEntries(&runtime);
    if (runtime.notebook.pending_resume_source) |*source| source.deinit(alloc);
    runtime.notebook.pending_resume_source = null;
    try commitStableFrame(alloc, &runtime);
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    const anchor = &runtime.transcript_commit_state.stable;
    anchor.history_visual_offset = anchor.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try expectWindowMatchesEntries(&runtime);
}

test "a resumed transcript keeps the rows it painted across later turns and repaints" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_COMPACT", "ANSWER\n");
    runtime.notebook.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, runtime.notebook.transcript.items),
    );
    try runtime.transcriptWindowResumed(alloc, true);

    var handoff = try transcriptFrame(alloc, &runtime, runtime.notebook.pending_resume_source.?.bytes, .none);
    defer handoff.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &handoff, committedFrameResult());
    try std.testing.expectEqual(@as(usize, 0), runtime.pendingResumeFlow().len);
    try std.testing.expect(runtime.transcript_commit_state == .stable);
    try runTurn(alloc, &runtime, &metrics, "AFTER_RESUME", "REPLY\n");
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));

    var repaint = try transcriptFrame(alloc, &runtime, null, .all);
    defer repaint.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &repaint, committedFrameResult());
    try std.testing.expect(runtime.transcript_commit_state == .stable);
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try expectWindowMatchesEntries(&runtime);
}

test "a resumed transcript that leaves the screen keeps its current-session entries across turns" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_COMPACT", "ANSWER\n");
    runtime.notebook.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, runtime.notebook.transcript.items),
    );
    try runtime.transcriptWindowResumed(alloc, true);
    var handoff = try transcriptFrame(alloc, &runtime, runtime.notebook.pending_resume_source.?.bytes, .none);
    defer handoff.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &handoff, committedFrameResult());

    var hidden: runtime_mod.TranscriptSlot = .{};
    defer TranscriptRuntime.deinitSlot(&hidden, alloc);
    runtime.swapSlot(&hidden);
    TranscriptRuntime.slotLeftScreen(&hidden);
    runtime.swapSlot(&hidden);
    try runTurn(alloc, &runtime, &metrics, "HIDDEN_TURN", "REPLY\n");
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try std.testing.expect(holds(&runtime, "HIDDEN_TURN"));
    try expectWindowMatchesEntries(&runtime);
}

test "a resumed transcript released before its first paint keeps its entries across paint and later turns" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_COMPACT", "ANSWER\n");
    runtime.notebook.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, runtime.notebook.transcript.items),
    );
    try runtime.transcriptWindowResumed(alloc, true);

    try std.testing.expect(runtime.releaseUnpaintedResumeSource(alloc) > 0);
    try std.testing.expect(runtime.notebook.pending_resume_source == null);
    try std.testing.expect(runtime.unpainted_resume_hold);

    try runTurn(alloc, &runtime, &metrics, "HIDDEN_TURN", "REPLY\n");
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try std.testing.expect(holds(&runtime, "HIDDEN_TURN"));

    try runtime.transcriptWindowScreenCleared(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));

    var first_paint = try transcriptFrame(alloc, &runtime, null, .all);
    defer first_paint.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &first_paint, committedFrameResult());
    try std.testing.expect(runtime.transcript_commit_state == .stable);
    try std.testing.expect(!runtime.unpainted_resume_hold);

    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));

    try runTurn(alloc, &runtime, &metrics, "NEXT_TURN", "REPLY\n");
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try std.testing.expect(holds(&runtime, "NEXT_TURN"));
    try expectWindowMatchesEntries(&runtime);
}

test "a resumed transcript released before its first paint keeps its entries through a visual epoch reset" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_COMPACT", "ANSWER\n");
    runtime.notebook.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, runtime.notebook.transcript.items),
    );
    try runtime.transcriptWindowResumed(alloc, true);

    try std.testing.expect(runtime.releaseUnpaintedResumeSource(alloc) > 0);
    try runTurn(alloc, &runtime, &metrics, "HIDDEN_TURN", "REPLY\n");
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));

    try runtime.resetVisualEpoch(alloc, "welcome\n");
    try std.testing.expect(runtime.unpainted_resume_hold);
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));

    var first_paint = try transcriptFrame(alloc, &runtime, null, .all);
    defer first_paint.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &first_paint, committedFrameResult());
    try std.testing.expect(!runtime.unpainted_resume_hold);
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    try expectWindowMatchesEntries(&runtime);
}

test "a turn with 3 mid-turn compactions keeps every entry including the prompt and reprints them on resize" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    const prompt = try alloc.dupe(u8, "THREE_COMPACT_PROMPT");
    defer alloc.free(prompt);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
    try readFiles(alloc, &runtime, &metrics, &.{"s1.txt"});
    try commitStableFrame(alloc, &runtime);
    const history_rows = runtime.transcript_commit_state.stable.total_visual_rows;
    runtime.transcript_commit_state.stable.history_visual_offset = history_rows;

    try runtime.transcriptWindowCompacted(alloc);
    try readFiles(alloc, &runtime, &metrics, &.{"s2.txt"});
    try runtime.transcriptWindowCompacted(alloc);
    try readFiles(alloc, &runtime, &metrics, &.{"s3.txt"});
    try runtime.transcriptWindowCompacted(alloc);
    try readFiles(alloc, &runtime, &metrics, &.{"s4.txt"});
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "THREE_COMPACT_ANSWER\n");
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });

    try std.testing.expect(holds(&runtime, "THREE_COMPACT_PROMPT"));
    try std.testing.expect(holds(&runtime, "Read s1.txt"));
    try std.testing.expect(holds(&runtime, "Read s2.txt"));
    try std.testing.expect(holds(&runtime, "Read s3.txt"));
    try std.testing.expect(holds(&runtime, "Read s4.txt"));
    try std.testing.expect(holds(&runtime, "THREE_COMPACT_ANSWER"));
    try expectWindowMatchesEntries(&runtime);

    try runtime.transcriptWindowScreenCleared(alloc);
    var reprinted = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer reprinted.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, reprinted.bytes, "THREE_COMPACT_PROMPT") != null);
    try std.testing.expect(std.mem.find(u8, reprinted.bytes, "Read s1.txt") != null);
    try std.testing.expect(std.mem.find(u8, reprinted.bytes, "Explored 4 files") != null);
}

test "freed command output lines beyond compact head keep resize reprint byte-identical and Ctrl+O shows full 200 lines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var capture_arena = std.heap.ArenaAllocator.init(alloc);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    const capture = try command_replay_store.Capture.create(capture_alloc, 1, &capability);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    for (1..201) |line_no| {
        const line = try alloc.print("cmd-line-{d:0>3}\n", .{line_no});
        defer alloc.free(line);
        try output.appendSlice(alloc, line);
    }
    capture.appendAccepted(capture_alloc, .stdout, output.items);
    const replay = capture.retain(capture_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedAvailableReplay,
    };
    defer capability.delete(.command_artifacts, descriptor.handle) catch {};

    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    const styles: runtime_mod.Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };

    const id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "cmd-200" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"seq 1 200\"}",
    } });
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, id, .stdout, output.items, true);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, id, true);

    var unsaved_runtime = testRuntime(alloc);
    defer unsaved_runtime.deinit(alloc);
    const unsaved_id = types.ToolLifecycleId{ .turn_id = 2, .call_id = "cmd-unsaved" };
    _ = try unsaved_runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = unsaved_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"seq 1 200\"}",
    } });
    try unsaved_runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, unsaved_id, .stdout, output.items, true);
    try unsaved_runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, unsaved_id, true);
    _ = try unsaved_runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = unsaved_id,
        .outcome = .{ .kind = .completed, .summary = "Ran seq 1 200" },
    } });
    try std.testing.expectEqual(@as(usize, 200), unsaved_runtime.notebook.command_output_blocks.items[0].lines.items.len);

    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran seq 1 200" },
        .result_memory = .{ .command_output_replay = replay },
    } });

    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    var unsaved_after = try source_preparation.prepareTranscriptSource(&unsaved_runtime, alloc, null);
    defer unsaved_after.deinit(alloc);
    try std.testing.expectEqualStrings(unsaved_after.bytes, after.bytes);

    const block = runtime.notebook.command_output_blocks.items[0];
    try std.testing.expect(block.lines.items.len <= command_output_runtime.compact_output_row_limit);
    try std.testing.expectEqual(@as(usize, 200), block.total_lines);

    var compact_saved = try command_output_runtime.renderCompactCommandOutputWithProcessPresentation(
        alloc,
        block,
        .{ .styles = styles },
        80,
        command_output_runtime.processPresentationForBlock(&runtime, block),
    );
    defer compact_saved.deinit(alloc);
    var compact_unsaved = try command_output_runtime.renderCompactCommandOutputWithProcessPresentation(
        alloc,
        unsaved_runtime.notebook.command_output_blocks.items[0],
        .{ .styles = styles },
        80,
        command_output_runtime.processPresentationForBlock(&unsaved_runtime, unsaved_runtime.notebook.command_output_blocks.items[0]),
    );
    defer compact_unsaved.deinit(alloc);
    try std.testing.expectEqualStrings(compact_unsaved.bytes.items, compact_saved.bytes.items);
    try std.testing.expect(std.mem.find(u8, compact_saved.bytes.items, "cmd-line-001") != null);
    try std.testing.expect(std.mem.find(u8, compact_saved.bytes.items, "cmd-line-005") != null);
    try std.testing.expect(std.mem.find(u8, compact_saved.bytes.items, "cmd-line-006") == null);
    try std.testing.expect(std.mem.find(u8, compact_saved.bytes.items, "195 lines more") != null);

    var projection = try full_transcript_screen.buildProjection(
        alloc,
        runtime.notebook.entries.items,
        runtime.notebook.tool_details.items,
        runtime.notebook.command_output_blocks.items,
        styles,
        80,
        null,
    );
    defer projection.deinit(alloc);
    const measurement = try full_transcript_screen.measureProjectionInterruptible(alloc, &projection, &capability, 80, null);
    const rendered = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        &capability,
        80,
        @intCast(measurement.total_rows),
        0,
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "cmd-line-001") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "cmd-line-200") != null);
}

test "freed tool_details.result with result_handle keeps resize reprint and rare wordings byte-identical and Ctrl+O shows full result" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "results");
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "results");
    defer alloc.free(result_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        result_dir,
        .tool_results,
        .writable,
    );
    defer capability.deinit();

    const full_body = "FULL_RESULT_HEAD\n" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "\nFULL_RESULT_TAIL\n";
    const handle = try result_store.storeLargeResultManaged(alloc, &capability, "read-stored", "read_file", full_body);
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var saved_rt = testRuntime(alloc);
    defer saved_rt.deinit(alloc);

    var unsaved_rt = testRuntime(alloc);
    defer unsaved_rt.deinit(alloc);

    const Case = struct {
        id: []const u8,
        name: []const u8,
        kind: types.ToolActivityKind,
        args: []const u8,
        label: []const u8,
        status: types.ToolOutcomeKind,
        outcome: types.ToolOutcomeKind,
        result: []const u8,
    };
    const cases = [_]Case{
        .{
            .id = "c-read",
            .name = "read_file",
            .kind = .read,
            .args = "{\"path\":\"notes.txt\"}",
            .label = "Read notes.txt",
            .status = .completed,
            .outcome = .completed,
            .result = full_body,
        },
        .{
            .id = "c-ask",
            .name = "ask_user_question",
            .kind = .ask,
            .args = "{\"questions\":[{\"question\":\"Ship?\"}]}",
            .label = "Failed",
            .status = .failed,
            .outcome = .failed,
            .result = session_adapter.unfinished_tool_output,
        },
        .{
            .id = "c-toolbox",
            .name = "toolbox",
            .kind = .read,
            .args = "{\"open\":\"ste-english\"}",
            .label = "Opened ste-english",
            .status = .completed,
            .outcome = .completed,
            .result = "<skill_content name=\"ste-english\" resource=\"SKILL.md\">\n---\nname: ste-english\n",
        },
        .{
            .id = "c-subagent",
            .name = "subagent",
            .kind = .subagent,
            .args = "{\"action\":\"message\",\"agent\":\"helper\"}",
            .label = "Messaged helper",
            .status = .completed,
            .outcome = .completed,
            .result = "helper starts with no history",
        },
        .{
            .id = "c-shell-err",
            .name = "run_command",
            .kind = .command,
            .args = "{\"command\":\"echo hi\",\"profile\":\"user\",\"shell\":\"zsh\"}",
            .label = "Command failed",
            .status = .failed,
            .outcome = .failed,
            .result = "{\"error\":{\"message\":\"invalid fields\",\"invalid_fields\":[\"profile\",\"shell\"]}}",
        },
        .{
            .id = "c-mcp",
            .name = "mcp_github_get_issue",
            .kind = .mcp,
            .args = "{}",
            .label = "Ran MCP mcp_github_get_issue",
            .status = .completed,
            .outcome = .completed,
            .result = "{\"server\":\"github\",\"output\":\"ok\"}",
        },
    };

    var saved_read_entry_id: u32 = 0;
    for (cases, 0..) |case, idx| {
        const s_id = try saved_rt.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = .{ .turn_id = 1, .call_id = case.id },
            .reconciles_provisional_call_id = null,
            .tool_name = case.name,
            .activity_kind = case.kind,
            .arguments_json = case.args,
        } });
        _ = s_id;
        const s_entry_id = saved_rt.toolActivityRecord(.{ .turn_id = 1, .call_id = case.id }).?.entry_id;
        if (idx == 0) saved_read_entry_id = s_entry_id;
        _ = try saved_rt.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = .{ .turn_id = 1, .call_id = case.id },
            .outcome = .{ .kind = case.outcome, .summary = case.label },
            .result = case.result,
            .result_memory = .{
                .output_handle = handle,
                .output_bytes = case.result.len,
                .stored_output_bytes = case.result.len,
            },
        } });

        _ = try unsaved_rt.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = .{ .turn_id = 1, .call_id = case.id },
            .reconciles_provisional_call_id = null,
            .tool_name = case.name,
            .activity_kind = case.kind,
            .arguments_json = case.args,
        } });
        _ = try unsaved_rt.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = .{ .turn_id = 1, .call_id = case.id },
            .outcome = .{ .kind = case.outcome, .summary = case.label },
            .result = case.result,
            .result_memory = .{
                .output_handle = null,
                .output_bytes = case.result.len,
                .stored_output_bytes = case.result.len,
            },
        } });
    }

    var saved_reprint = try source_preparation.prepareTranscriptSource(&saved_rt, alloc, null);
    defer saved_reprint.deinit(alloc);
    var unsaved_reprint = try source_preparation.prepareTranscriptSource(&unsaved_rt, alloc, null);
    defer unsaved_reprint.deinit(alloc);

    try std.testing.expectEqualStrings(unsaved_reprint.bytes, saved_reprint.bytes);

    for (saved_rt.notebook.tool_details.items) |detail| {
        try std.testing.expect(detail.result == null);
    }
    for (unsaved_rt.notebook.tool_details.items) |detail| {
        try std.testing.expect(detail.result != null);
    }

    const read_entry = saved_rt.notebook.entries.items[0..1];
    const read_detail = saved_rt.toolDetailForEntry(saved_read_entry_id).?.*;
    var projection = try full_transcript_screen.buildProjection(
        alloc,
        read_entry,
        &.{read_detail},
        &.{},
        .{
            .system_notice_label_style = "",
            .system_notice_text_style = "",
            .reset_style = "",
            .dim_style = "",
            .red_style = "",
        },
        80,
        null,
    );
    defer projection.deinit(alloc);
    const measurement = try full_transcript_screen.measureProjectionInterruptible(alloc, &projection, &capability, 80, null);
    const rendered = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        &capability,
        80,
        @intCast(measurement.total_rows),
        0,
        null,
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "FULL_RESULT_HEAD") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "FULL_RESULT_TAIL") != null);
}

test "empty transcript archive releases spare capacity when Ctrl+O is closed and keeps resize reprint byte-identical" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    for (0..full_transcript_page.max_source_entries) |index| {
        var buf: [32]u8 = undefined;
        _ = try runtime.appendRawTranscriptEntryClassified(alloc, try std.mem.print(&buf, "held {d}\n", .{index}), .tool_status);
    }
    var before = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer before.deinit(alloc);

    runtime.transcript_archive_available = true;
    var archived = try numberedCycle(alloc, 300);
    try archived.notebook.transcript.ensureTotalCapacity(alloc, 4096);
    try runtime.installTranscriptArchive(alloc, 1, true, archived, false);
    runtime.closeFullTranscriptState();

    const held = runtime.transcript_archive orelse return error.TestExpectedArchive;
    try std.testing.expectEqual(@as(usize, 0), held.runtime.notebook.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), held.runtime.notebook.entries.capacity);
    try std.testing.expectEqual(@as(usize, 0), held.runtime.notebook.transcript.capacity);
    try std.testing.expectEqual(@as(usize, 0), held.runtime.notebook.tool_details.capacity);

    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    try std.testing.expectEqualStrings(before.bytes, after.bytes);
}

test "shrinking spare entries capacity keeps resize reprint byte-identical" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    const prompt = try alloc.dupe(u8, "CAP_PROMPT");
    defer alloc.free(prompt);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = prompt }, false, &.{});
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "CAP_ANSWER\n");
    try runtime.notebook.entries.ensureTotalCapacity(alloc, 2048);

    var before = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer before.deinit(alloc);

    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 500 });

    var after = try source_preparation.prepareTranscriptSource(&runtime, alloc, null);
    defer after.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, after.bytes, "CAP_PROMPT") != null);
    try std.testing.expect(std.mem.find(u8, after.bytes, "CAP_ANSWER") != null);
    try std.testing.expectEqualStrings(
        before.bytes,
        after.bytes[0..before.bytes.len],
    );
    try std.testing.expectEqual(runtime.notebook.entries.items.len, runtime.notebook.entries.capacity);
}

test "full transcript page stays bounded over many trimmed command blocks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);

    const styles: runtime_mod.Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };

    const assistant_pad = try alloc.alloc(u8, 12_000);
    defer alloc.free(assistant_pad);
    @memset(assistant_pad, 'A');

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    for (0..200) |line_idx| {
        const line = try alloc.print("line{d:03} ", .{line_idx + 1});
        defer alloc.free(line);
        try output.appendSlice(alloc, line);
        try output.appendNTimes(alloc, 'x', 980);
        try output.append(alloc, '\n');
    }

    var capture_arena = std.heap.ArenaAllocator.init(alloc);
    defer capture_arena.deinit();
    const cap_alloc = capture_arena.allocator();
    var capture = try command_replay_store.Capture.create(cap_alloc, 8, &capability);
    capture.appendAccepted(cap_alloc, .stdout, output.items);
    const replay = capture.retain(cap_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedAvailableReplay,
    };
    defer capability.delete(.command_artifacts, descriptor.handle) catch {};

    for (0..40) |step| {
        _ = try runtime.appendAssistantTurnEntry(alloc);
        const step_text = try alloc.print("Step {d}: {s}\n", .{ step + 1, assistant_pad });
        defer alloc.free(step_text);
        _ = try runtime.streamAssistantChunk(alloc, &metrics, step_text);

        const call_id = try alloc.print("cmd-{d}", .{step});
        defer alloc.free(call_id);
        const id = types.ToolLifecycleId{ .turn_id = 1, .call_id = call_id };
        _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = id,
            .reconciles_provisional_call_id = null,
            .tool_name = "run_command",
            .activity_kind = .command,
            .arguments_json = "{\"command\":\"seq 1 200\"}",
        } });
        try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, id, .stdout, output.items, true);
        try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, id, true);
        _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = id,
            .outcome = .{ .kind = .completed, .summary = "Ran seq 1 200" },
            .result_memory = .{ .command_output_replay = replay },
        } });
    }

    var source = try runtime.snapshotFullTranscriptPage(.{
        .content_revision = runtime.notebook.full_transcript_content_revision,
        .cols = 120,
        .anchor = .tail,
    }, &capability, null);
    defer source.deinit(std.heap.c_allocator);

    try std.testing.expect(source.command_blocks.items.len <= 8);
    try std.testing.expect(source.entries.items.len <= 64);

    var projection = try full_transcript_screen.buildProjection(
        std.heap.c_allocator,
        source.entries.items,
        source.details.items,
        source.command_blocks.items,
        source.styles,
        120,
        null,
    );
    defer projection.deinit(std.heap.c_allocator);
    _ = try full_transcript_screen.measureProjectionInterruptible(
        std.heap.c_allocator,
        &projection,
        &capability,
        120,
        null,
    );

    var segment_bytes: usize = 0;
    for (projection.segments.items) |segment| switch (segment) {
        .static => |bytes| segment_bytes +|= bytes.len,
        .stored_result => |stored| if (stored.retained_command_fallback) |fallback| {
            segment_bytes +|= fallback.len;
        },
    };
    try std.testing.expect(segment_bytes <= 581_000);
}
