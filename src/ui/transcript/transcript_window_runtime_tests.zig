//! The transcript window driving a real transcript runtime
//! (`transcript_window_shell.zig`): what a compaction leaves in memory, and
//! what stays while it is still on screen.

const std = @import("std");
const runtime_mod = @import("runtime.zig");
const transcript_store = @import("store.zig");
const source_preparation = @import("source_preparation.zig");
const frozen_prefix = @import("frozen_prefix.zig");
const types = @import("../../core/shared/types.zig");

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
    _ = try runtime.writeUserPromptCard(alloc, metrics, .{ .text = text }, runtime.entries.items.len > 0, &.{});
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "● Read notes.txt\n", .tool_status);
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, metrics, answer);
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });
}

fn holds(runtime: *const TranscriptRuntime, needle: []const u8) bool {
    for (runtime.entries.items) |entry| switch (entry) {
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
    try std.testing.expectEqual(runtime.entries.items.len, window.finished.items.len + window.pending_drops.items.len);
    var index: usize = 0;
    for (runtime.entries.items) |entry| {
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

test "the transcript window removes a compaction's closed cycle once the session log holds it" {
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

    // Between turns, with both turns saved and nothing on screen, the closed
    // cycle leaves at the compaction itself.
    try runtime.transcriptWindowCompacted(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);

    try runTurn(alloc, &runtime, &metrics, "THIRD_PROMPT", "THIRD_ANSWER\n");
    try std.testing.expect(!holds(&runtime, "FIRST_PROMPT") and !holds(&runtime, "SECOND_ANSWER"));
    try std.testing.expect(holds(&runtime, "THIRD_PROMPT") and holds(&runtime, "THIRD_ANSWER"));
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "FIRST_ANSWER") == null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "THIRD_ANSWER") != null);
    try expectPreparedMatchesFull(alloc, &runtime);
    try expectWindowMatchesEntries(&runtime);
}

test "the transcript window keeps a dropped entry while a row of it is still on screen" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "ON_SCREEN_PROMPT", "ON_SCREEN_ANSWER\n");
    try commitStableFrame(alloc, &runtime);

    try runtime.transcriptWindowCompacted(alloc);
    try std.testing.expect(holds(&runtime, "ON_SCREEN_PROMPT") and holds(&runtime, "ON_SCREEN_ANSWER"));
    try std.testing.expectEqual(runtime.entries.items.len, runtime.transcript_window.?.pending_drops.items.len);
    try expectWindowMatchesEntries(&runtime);

    // The rows scroll into terminal history: the next sync removes them.
    const anchor = &runtime.transcript_commit_state.stable;
    anchor.history_visual_offset = anchor.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(!holds(&runtime, "ON_SCREEN_PROMPT"));
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.pending_drops.items.len);
    try expectWindowMatchesEntries(&runtime);
}

test "a cleared transcript starts the transcript window over" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_CLEAR", "ANSWER\n");
    transcript_store.clearTranscript(&runtime, alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.finished.items.len);
    try runTurn(alloc, &runtime, &metrics, "AFTER_CLEAR", "ANSWER\n");
    try runTurn(alloc, &runtime, &metrics, "STILL_HELD", "ANSWER\n");
    try runtime.transcriptWindowCompacted(alloc);
    try runTurn(alloc, &runtime, &metrics, "NEXT", "ANSWER\n");
    try std.testing.expect(!holds(&runtime, "AFTER_CLEAR") and !holds(&runtime, "STILL_HELD"));
    try std.testing.expect(holds(&runtime, "NEXT"));
    try expectWindowMatchesEntries(&runtime);
}

test "a transcript window drop never removes a pinned tool line" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    const done = try runtime.appendRawTranscriptEntryClassified(alloc, "● Read done.txt\n", .tool_status);
    const pinned = try runtime.appendRawTranscriptEntryClassified(alloc, "● Running\n", .tool_status);
    for (runtime.entries.items) |*entry| {
        if (entry.id() == pinned) entry.raw_bytes.lifecycle_pinned = true;
    }
    try std.testing.expect(try transcript_store.dropEntriesAtomic(&runtime, alloc, &.{ done, pinned }));
    try std.testing.expect(!holds(&runtime, "done.txt"));
    try std.testing.expect(holds(&runtime, "Running"));
}

test "the transcript window releases its held drops when the screen is cleared for a replay" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "HELD_PROMPT", "HELD_ANSWER\n");
    try commitStableFrame(alloc, &runtime);
    try runtime.transcriptWindowCompacted(alloc);
    try std.testing.expect(holds(&runtime, "HELD_PROMPT"));
    // A resize clears the screen and replays the entries.
    try runtime.transcriptWindowScreenCleared(alloc);
    try std.testing.expect(!holds(&runtime, "HELD_PROMPT"));
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript_window.?.pending_drops.items.len);
    try expectWindowMatchesEntries(&runtime);
}

const full_transcript_page = @import("../../core/output/full_transcript_page.zig");

fn rawEntries(alloc: Allocator, runtime: *TranscriptRuntime, texts: []const []const u8) !void {
    for (texts) |text| _ = try runtime.appendRawTranscriptEntryClassified(alloc, text, .tool_status);
}

fn archivedCycle(alloc: Allocator, back: u32, texts: []const []const u8) !TranscriptRuntime {
    var archived = testRuntime(alloc);
    archived.next_entry_id = runtime_mod.archiveEntryIdBase(back);
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

    // The newest pages need the cycle before the compaction from the log.
    try std.testing.expectError(error.TranscriptArchiveNotLoaded, runtime.snapshotFullTranscriptPage(.{ .anchor = .tail, .content_revision = 0, .cols = 80 }, null, null));
    runtime.moveToFullTranscriptPage(.{ .entry_index = 0 }, .first);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);

    // Once it is installed the newest page shows both cycles, older first.
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{ "older one\n", "older two\n", "older three\n" }));
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
    try runtime.installTranscriptArchive(alloc, 2, false, try archivedCycle(alloc, 2, &.{"oldest\n"}));
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
    try runtime.installTranscriptArchive(alloc, 1, true, try archivedCycle(alloc, 1, &.{ "older one\n", "older two\n", "older three\n" }));
    try std.testing.expectEqual(@as(usize, 0), runtime.full_transcript_page_anchor.entry_index);
    try std.testing.expectEqual(@as(?u32, runtime_mod.archiveEntryIdBase(1)), runtime.full_transcript.bookmark_entry_id);

    // A failed load returns Ctrl+O to the held entries; closing frees the cycle.
    runtime.moveToFullTranscriptPage(further, .last);
    runtime.failTranscriptArchive();
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    try std.testing.expectEqual(@as(usize, 0), runtime.full_transcript_page_anchor.entry_index);
    runtime.closeFullTranscriptState();
    try std.testing.expect(runtime.transcript_archive == null);
    try std.testing.expect(runtime.full_transcript_page_anchor == .tail);
}

test "transcript window: Ctrl+O pages the cycles before one the window still holds" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    try rawEntries(alloc, &runtime, &.{ "previous cycle\n", "new cycle\n" });
    runtime.transcript_archive_available = true;
    // Until the turn across the compaction ends, the window holds both cycles.
    runtime.transcript_window.?.state.prev_first = 0;
    try std.testing.expect(!runtime.ctrlOJoinsPreviousCycle());
    const held = try pageTexts(alloc, &runtime, .tail);
    defer alloc.free(held);
    try std.testing.expectEqualStrings("previous cycle\nnew cycle\n", held);
    const held_range: full_transcript_page.SourceRange = .{ .start = 0, .end = 2 };
    const older = runtime.olderPageAnchor(.{ .entry_index = 0 }, held_range).?;
    try std.testing.expectEqual(@as(u32, 1), older.archive.back);
    runtime.moveToFullTranscriptPage(older, .last);
    try runtime.installTranscriptArchive(alloc, 1, false, try archivedCycle(alloc, 1, &.{"before both\n"}));
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
    try window.pending_drops.append(alloc, runtime.entries.items[0].id());
    var source = try runtime.snapshotFullTranscriptPage(.{ .anchor = .tail, .content_revision = 0, .cols = 80 }, null, null);
    defer source.deinit(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 1), source.entries.items.len);
    try std.testing.expectEqual(runtime.entries.items[1].id(), source.entries.items[0].id());
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
        .max_transcript_bytes = 4096,
        .command_output_block_cap = cap,
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
        try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, try std.fmt.bufPrint(&line, "line-{d:0>2}\n", .{index}), true);
    }
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    const first = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 40), first.total_lines);
    try std.testing.expect(first.retention_overflow);
    try std.testing.expect(first.lines.items.len < first.total_lines);

    // The next command keeps all of its output though the transcript holds
    // more than the cap.
    for (0..3) |index| {
        try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, try std.fmt.bufPrint(&line, "next-{d}\n", .{index}), true);
    }
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items.len);
    const second = runtime.command_output_blocks.items[1];
    try std.testing.expect(!second.retention_overflow);
    try std.testing.expectEqual(@as(usize, 3), second.total_lines);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) > cap);
}

test "transcript window: Ctrl+O reads the log only while it is open, and forgets on compaction" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    try runtime.enableTranscriptWindow(alloc, true);
    try rawEntries(alloc, &runtime, &.{"held\n"});
    runtime.transcript_archive_available = true;

    // Closed: preparing the newest page reads nothing from the log.
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, null), runtime.transcript_archive_request);
    // Opening: it asks for the cycle the page joins.
    _ = runtime.requestFullTranscriptOpen();
    try runtime.prewarmFullTranscriptPage(null, null);
    try std.testing.expectEqual(@as(?u32, 1), runtime.transcript_archive_request);

    // A compaction makes that cycle two back, so it is let go.
    try runtime.installTranscriptArchive(alloc, 1, false, try archivedCycle(alloc, 1, &.{"older\n"}));
    try std.testing.expect(runtime.transcript_archive != null);
    try runtime.transcriptWindowCompacted(alloc);
    try std.testing.expect(runtime.transcript_archive == null);
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
        const dropped_count = runtime.entries.items.len;
        try runTurn(alloc, &runtime, &metrics, "KEPT_PROMPT", "KEPT_ANSWER\n");
        try commitStableFrame(alloc, &runtime);
        // The drop takes the atomic path: a copy, then one commit.
        const identity = runtime.committedRetentionIdentity() orelse return error.TestExpectedCommittedSource;
        try std.testing.expect(identity.lines.len > 0 and runtime.retentionSourceCols() != null);

        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(backing);
        for (runtime.entries.items) |entry| try ids.append(backing, entry.id());
        const transcript_before = try backing.dupe(u8, runtime.transcript.items);
        defer backing.free(transcript_before);

        failing.fail_index = failing.alloc_index + fail_after;
        const result = transcript_store.dropEntriesAtomic(&runtime, alloc, ids.items[0..dropped_count]);
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (result) |changed| {
            try std.testing.expect(!induced);
            try std.testing.expect(changed);
            try std.testing.expect(!holds(&runtime, "DROPPED_PROMPT") and holds(&runtime, "KEPT_PROMPT"));
            try std.testing.expectEqual(ids.items.len - dropped_count, runtime.entries.items.len);
            break;
        } else |err| {
            // A writer over a growing buffer reports a failed allocation as
            // WriteFailed.
            try std.testing.expect(induced);
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
            try std.testing.expectEqual(ids.items.len, runtime.entries.items.len);
            for (ids.items, runtime.entries.items) |id, entry| try std.testing.expectEqual(id, entry.id());
        }
    }
    // The drop allocates, so some of the runs above failed inside it.
    try std.testing.expect(fail_after > 0);
}

test "a resume that brings back the cycle before the newest compaction keeps it until it is painted" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime(alloc);
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    try runtime.enableTranscriptWindow(alloc, true);
    try runTurn(alloc, &runtime, &metrics, "BEFORE_COMPACT", "ANSWER\n");
    // As the resume path leaves it: the replayed entries, prepared and not
    // painted yet.
    runtime.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, runtime.transcript.items),
    );
    try runtime.transcriptWindowResumed(alloc, true);
    // The compaction applied as a live one: the window lets the cycle go, and
    // the screen keeps it.
    try std.testing.expect(!runtime.transcriptWindowHoldsPreviousCycle());
    try std.testing.expect(holds(&runtime, "BEFORE_COMPACT"));
    // Painted, then scrolled into terminal history: the next sync drops it.
    if (runtime.pending_resume_source) |*source| source.deinit(alloc);
    runtime.pending_resume_source = null;
    try commitStableFrame(alloc, &runtime);
    const anchor = &runtime.transcript_commit_state.stable;
    anchor.history_visual_offset = anchor.total_visual_rows;
    try runtime.syncTranscriptWindow(alloc);
    try std.testing.expect(!holds(&runtime, "BEFORE_COMPACT"));
    try expectWindowMatchesEntries(&runtime);
}
